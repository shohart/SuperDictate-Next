import Foundation

// MARK: - ONNX ASR engine (SuperDictateOnnxHost, framed IPC v1)
//
// The app never links ONNX Runtime (spec §3): one SuperDictateOnnxHost
// subprocess holds one model and speaks framed IPC v1 over stdin/stdout
// (native/asr-runtime/src/ipc.h, spec §8):
//
//   request : "SDAQ" | u16 version=1 | u16 type | u64 request_id | u32 json_len | u64 pcm_bytes | json | pcm f32
//   response: "SDAR" | u16 version=1 | u16 status | u64 request_id | u32 json_len | json
//
// Same safety rules as WhisperCppEngine: throwing-only IO, exact read
// loops, never `synchronizeFile()`, helper resolved from Contents/Helpers,
// stdin-EOF death contract. A hard per-request timeout first sends CANCEL
// (honoured between ORT runs via RunOptions::SetTerminate), then kills the
// process; a dead engine reports `isAlive == false` and TranscriptionWorker
// relaunches it on the next request.

enum OnnxAsrEngineError: LocalizedError {
    case helperUnavailable
    case resourcesUnavailable
    case helperExited(Int32)
    case invalidResponse(String)
    case timedOut(Double)
    case native(category: String, message: String)

    var errorDescription: String? {
        switch self {
        case .helperUnavailable: return "SuperDictateOnnxHost helper is unavailable"
        case .resourcesUnavailable: return "ONNX ASR resources are missing from the app bundle"
        case .helperExited(let code): return "SuperDictateOnnxHost exited (status \(code))"
        case .invalidResponse(let detail): return "SuperDictateOnnxHost returned an invalid response: \(detail)"
        case .timedOut(let seconds): return "ONNX transcription timed out after \(Int(seconds)) s"
        case .native(let category, let message): return "ONNX ASR \(category): \(message)"
        }
    }

    /// True when the helper process can no longer be used.
    var killsHelper: Bool {
        switch self {
        case .helperExited, .invalidResponse, .timedOut: return true
        default: return false
        }
    }
}

private enum OnnxIPC {
    static let version: UInt16 = 1
    static let responseHeaderSize = 20
    static let maxJSONBytes: UInt32 = 1 << 20

    enum MessageType: UInt16 {
        case create = 1, transcribe = 2, status = 3, cancel = 4, shutdown = 5, punctuate = 6
    }

    // sd_asr_status values (include/sd_asr.h).
    static let statusOK: UInt16 = 0
    static let statusCancelled: UInt16 = 8

    static func requestFrame(type: MessageType, id: UInt64, json: Data, pcm: [Float] = []) -> Data {
        var frame = Data(capacity: 28 + json.count + pcm.count * 4)
        frame.append(contentsOf: Array("SDAQ".utf8))
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { frame.append(contentsOf: $0) }
        }
        append(version)
        append(type.rawValue)
        append(id)
        append(UInt32(json.count))
        append(UInt64(pcm.count * 4))
        frame.append(json)
        pcm.withUnsafeBytes { frame.append(contentsOf: $0) }
        return frame
    }
}

/// Process + pipes, shared with the timeout watchdog (which runs off the
/// actor while the actor is blocked reading). Writes are serialized by
/// `writeLock`.
private final class OnnxHostConnection: @unchecked Sendable {
    let process: Process
    let input: FileHandle
    let output: FileHandle
    private let writeLock = NSLock()

    init(process: Process, input: FileHandle, output: FileHandle) {
        self.process = process
        self.input = input
        self.output = output
    }

    func write(_ data: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        try input.write(contentsOf: data)
    }

    func kill() {
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    func close() {
        try? input.close()
        if process.isRunning { process.terminate() }
    }
}

struct OnnxAsrTranscription: Sendable {
    let text: String
    let processingSeconds: Double
    let providerActual: String
}

actor OnnxAsrEngine {
    private let connection: OnnxHostConnection
    private var nextRequestID: UInt64 = 1
    private(set) var isAlive = true
    private(set) var providerActual = "cpu"
    private(set) var providerFallbackReason = ""
    private(set) var modelID = ""
    private(set) var loadSeconds = 0.0
    let threadCount: Int
    /// ASR hotwords (spec asr-hotwords §7), sent with every TRANSCRIBE.
    /// Empty = the unbiased path; no hotword keys are sent at all.
    private(set) var hotwords: [String] = []
    private(set) var hotwordsScore = AsrHotwordsStrength.normal.score
    /// Set when the list changes; the next result's hotword report is
    /// logged once and the flag cleared.
    private var hotwordsReportPending = false

    /// Spawns the helper and loads the model (CREATE). `modelDirectory`
    /// must hold a verified install (downloadOnnxModelIfNeeded). A non-nil
    /// `expectedModelID` makes the host refuse a directory whose manifest
    /// names another model.
    static func launch(modelDirectory: URL, threadCount: Int,
                       expectedModelID: String? = nil) async throws -> OnnxAsrEngine {
        guard let resources = resolvedOnnxAsrResources() else {
            throw OnnxAsrEngineError.resourcesUnavailable
        }
        let engine = try OnnxAsrEngine(threadCount: threadCount)
        do {
            try await engine.create(modelDirectory: modelDirectory, assetsDirectory: resources.assetsDirectory,
                                    expectedModelID: expectedModelID)
        } catch {
            await engine.shutdown()
            throw error
        }
        return engine
    }

    private init(threadCount: Int) throws {
        guard let helper = Self.resolvedHelperBinaryURL() else {
            throw OnnxAsrEngineError.helperUnavailable
        }
        let process = Process()
        process.executableURL = helper
        process.arguments = []
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.standardError
        try process.run()
        connection = OnnxHostConnection(process: process,
                                        input: inputPipe.fileHandleForWriting,
                                        output: outputPipe.fileHandleForReading)
        self.threadCount = threadCount
    }

    /// Packaged .app first (Contents/Helpers/), then a sibling of the
    /// executable; DEBUG builds also accept the CMake build tree.
    private static func resolvedHelperBinaryURL() -> URL? {
        let name = "SuperDictateOnnxHost"
        let fm = FileManager.default
        let packaged = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)")
        if fm.isExecutableFile(atPath: packaged.path) { return packaged }
        if let selfURL = Bundle.main.executableURL {
            let sibling = selfURL.deletingLastPathComponent().appendingPathComponent(name)
            if fm.isExecutableFile(atPath: sibling.path) { return sibling }
        }
        #if DEBUG
        let buildTree = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("native/asr-runtime/build/\(name)")
        if fm.isExecutableFile(atPath: buildTree.path) { return buildTree }
        #endif
        return nil
    }

    private func create(modelDirectory: URL, assetsDirectory: URL, expectedModelID: String?) throws {
        var config: [String: Any] = [
            "engine": "onnxruntime",
            "model_directory": modelDirectory.path,
            "assets_directory": assetsDirectory.path,
            "provider": "auto",
            "intra_op_threads": threadCount,
        ]
        if let expectedModelID {
            config["model_id"] = expectedModelID
        }
        let started = ProcessInfo.processInfo.systemUptime
        let status = try roundTrip(type: .create, json: try JSONSerialization.data(withJSONObject: config),
                                   timeoutSeconds: 120)
        loadSeconds = ProcessInfo.processInfo.systemUptime - started
        providerActual = status["provider_actual"] as? String ?? "cpu"
        providerFallbackReason = status["provider_fallback_reason"] as? String ?? ""
        modelID = status["model_id"] as? String ?? ""
    }

    func transcribe(samples: [Float]) throws -> OnnxAsrTranscription {
        let object = try transcribeJSON(samples: samples, timestamps: false)
        guard let text = object.dictionary["text"] as? String else {
            throw OnnxAsrEngineError.invalidResponse("missing text")
        }
        return OnnxAsrTranscription(
            text: text,
            processingSeconds: object.dictionary["processing_seconds"] as? Double ?? 0,
            providerActual: object.dictionary["provider_actual"] as? String ?? providerActual
        )
    }

    /// Result JSON shares `text`/`frame_sec`/`tokens`/`words` with the
    /// parakeet.cpp bridge, so it decodes straight into TokenTranscription
    /// and the overlap-window path works unchanged.
    func transcribeWithTokens(samples: [Float]) throws -> TokenTranscription {
        let object = try transcribeJSON(samples: samples, timestamps: true)
        do {
            return try JSONDecoder().decode(TokenTranscription.self, from: object.data)
        } catch {
            throw ASREngineError.tokenDecodeFailed(error.localizedDescription)
        }
    }

    /// Punctuation restoration with a text model (model_family
    /// "modernbert_punct"); a speech model answers invalid_argument.
    func punctuate(text: String) throws -> (text: String, processingSeconds: Double) {
        let body = try JSONSerialization.data(withJSONObject: ["text": text])
        // ~60 ms per sentence on the CPU; the bound is for a stuck host.
        let object = try roundTrip(type: .punctuate, json: body,
                                   timeoutSeconds: 20 + Double(text.utf8.count) / 500)
        guard let punctuated = object["text"] as? String else {
            throw OnnxAsrEngineError.invalidResponse("missing text")
        }
        return (punctuated, object["processing_seconds"] as? Double ?? 0)
    }

    /// No-op when unchanged, so callers may re-apply the same list before
    /// every request.
    func setHotwords(_ phrases: [String], score: Double) {
        guard phrases != hotwords || score != hotwordsScore else { return }
        hotwords = phrases
        hotwordsScore = score
        hotwordsReportPending = !phrases.isEmpty
        if phrases.isEmpty {
            log("ASR hotwords: off")
        } else {
            log("ASR hotwords: \(phrases.count) phrase(s), score \(score)")
        }
    }

    /// TRANSCRIBE options (spec asr-hotwords §7). The hotword keys are
    /// added only for a non-empty list, so the unbiased request is
    /// byte-for-byte the pre-hotwords one.
    static func transcribeOptions(timestamps: Bool, hotwords: [String], hotwordsScore: Double) -> [String: Any] {
        var options: [String: Any] = ["timestamps": timestamps, "sample_rate": Int(SAMPLE_RATE)]
        if !hotwords.isEmpty {
            options["hotwords"] = hotwords
            options["hotwords_score"] = hotwordsScore
        }
        return options
    }

    /// One log line per list change with what the host made of it.
    private func reportHotwordsIfPending(_ result: [String: Any]) {
        guard hotwordsReportPending else { return }
        hotwordsReportPending = false
        var parts: [String] = []
        if let used = result["hotwords_used"] as? Int {
            parts.append("used \(used)")
        }
        if let skipped = result["hotwords_skipped"] as? [String], !skipped.isEmpty {
            let shown = skipped.prefix(10).map { "\"\($0)\"" }.joined(separator: ", ")
            parts.append("skipped \(skipped.count): \(shown)\(skipped.count > 10 ? ", …" : "")")
        }
        if let reason = result["hotwords_disabled_reason"] as? String, !reason.isEmpty {
            parts.append("disabled: \(reason)")
        }
        log("ASR hotwords (host): \(parts.isEmpty ? "no report (host predates hotwords?)" : parts.joined(separator: "; "))")
    }

    func shutdown() {
        guard isAlive else { return }
        isAlive = false
        // Best effort: SHUTDOWN, then closing stdin (EOF) ends the host anyway.
        try? connection.write(OnnxIPC.requestFrame(type: .shutdown, id: takeRequestID(), json: Data("{}".utf8)))
        connection.close()
    }

    deinit {
        connection.close()
    }

    // MARK: IPC

    private func takeRequestID() -> UInt64 {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    /// Generous bound: model load + ~1× real time on a slow CPU (measured
    /// RTF ≈ 0.13 at 8 threads on the Xeon E5-2696 v3).
    static func timeoutSeconds(sampleCount: Int) -> Double {
        60 + Double(sampleCount) / SAMPLE_RATE
    }

    private func transcribeJSON(samples: [Float], timestamps: Bool) throws -> (dictionary: [String: Any], data: Data) {
        guard !samples.isEmpty else { throw ASREngineError.emptyAudio }
        let options = Self.transcribeOptions(timestamps: timestamps, hotwords: hotwords, hotwordsScore: hotwordsScore)
        let result = try roundTripRaw(type: .transcribe,
                                      json: try JSONSerialization.data(withJSONObject: options),
                                      pcm: samples,
                                      timeoutSeconds: Self.timeoutSeconds(sampleCount: samples.count))
        reportHotwordsIfPending(result.dictionary)
        return result
    }

    private func roundTrip(type: OnnxIPC.MessageType, json: Data, timeoutSeconds: Double) throws -> [String: Any] {
        try roundTripRaw(type: type, json: json, pcm: [], timeoutSeconds: timeoutSeconds).dictionary
    }

    private func roundTripRaw(type: OnnxIPC.MessageType,
                              json: Data,
                              pcm: [Float],
                              timeoutSeconds: Double) throws -> (dictionary: [String: Any], data: Data) {
        guard isAlive else { throw OnnxAsrEngineError.helperExited(-1) }
        let id = takeRequestID()
        let cancelID = takeRequestID()
        do {
            try connection.write(OnnxIPC.requestFrame(type: type, id: id, json: json, pcm: pcm))
        } catch {
            isAlive = false
            throw OnnxAsrEngineError.helperExited(connection.process.isRunning ? -1 : connection.process.terminationStatus)
        }

        // Watchdog: CANCEL at the deadline, SIGKILL after a grace period.
        let timedOut = OnnxTimeoutFlag()
        let connection = self.connection
        let watchdog = DispatchWorkItem {
            timedOut.set()
            let cancelBody = (try? JSONSerialization.data(withJSONObject: ["target": id])) ?? Data()
            try? connection.write(OnnxIPC.requestFrame(type: .cancel, id: cancelID, json: cancelBody))
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if timedOut.isSet && !timedOut.isFinished { connection.kill() }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: watchdog)
        defer {
            watchdog.cancel()
            timedOut.finish()
        }

        do {
            while true {
                let (header, body) = try readResponse()
                // Skip acknowledgements of our own CANCEL frames.
                guard header.requestID == id else { continue }
                if header.status == OnnxIPC.statusOK {
                    guard let dictionary = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                        throw OnnxAsrEngineError.invalidResponse("body is not a JSON object")
                    }
                    return (dictionary, body)
                }
                if header.status == OnnxIPC.statusCancelled && timedOut.isSet {
                    throw OnnxAsrEngineError.timedOut(timeoutSeconds)
                }
                let error = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
                throw OnnxAsrEngineError.native(category: error?["category"] as? String ?? "status \(header.status)",
                                                message: error?["message"] as? String ?? "")
            }
        } catch let error as OnnxAsrEngineError {
            if case .helperExited = error, timedOut.isSet {
                isAlive = false
                throw OnnxAsrEngineError.timedOut(timeoutSeconds)
            }
            if error.killsHelper {
                isAlive = false
                connection.close()
            }
            throw error
        }
    }

    private func readResponse() throws -> (header: (status: UInt16, requestID: UInt64), body: Data) {
        let raw = try readExactly(OnnxIPC.responseHeaderSize)
        let bytes = [UInt8](raw)
        guard bytes[0..<4] == [UInt8]("SDAR".utf8)[0..<4] else {
            throw OnnxAsrEngineError.invalidResponse("bad magic")
        }
        func le<T: FixedWidthInteger>(_ offset: Int, _: T.Type) -> T {
            var value: T = 0
            for i in 0..<MemoryLayout<T>.size { value |= T(bytes[offset + i]) << (8 * i) }
            return value
        }
        let version = le(4, UInt16.self)
        guard version == OnnxIPC.version else {
            throw OnnxAsrEngineError.invalidResponse("version \(version)")
        }
        let status = le(6, UInt16.self)
        let requestID = le(8, UInt64.self)
        let length = le(16, UInt32.self)
        guard length <= OnnxIPC.maxJSONBytes else {
            throw OnnxAsrEngineError.invalidResponse("json_len \(length)")
        }
        let body = length > 0 ? try readExactly(Int(length)) : Data()
        return ((status, requestID), body)
    }

    /// Exact read loop; an empty read is EOF (helper died).
    private func readExactly(_ count: Int) throws -> Data {
        var data = Data(capacity: count)
        while data.count < count {
            guard let chunk = try? connection.output.read(upToCount: count - data.count), !chunk.isEmpty else {
                let process = connection.process
                throw OnnxAsrEngineError.helperExited(process.isRunning ? -1 : process.terminationStatus)
            }
            data.append(chunk)
        }
        return data
    }
}

private final class OnnxTimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var finished = false

    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return fired }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    func set() { lock.lock(); fired = true; lock.unlock() }
    func finish() { lock.lock(); finished = true; lock.unlock() }
}
