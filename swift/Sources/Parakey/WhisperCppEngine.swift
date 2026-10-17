import Foundation
import Metal

enum WhisperCppEngineError: LocalizedError {
    case helperUnavailable
    case helperExited(Int32)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .helperUnavailable: return "whisper.cpp helper is unavailable"
        case .helperExited(let code): return "whisper.cpp helper exited with code \(code)"
        case .invalidResponse: return "whisper.cpp helper returned an invalid response"
        }
    }
}

/// Whisper runs only on a discrete GPU (a Metal device without unified
/// memory: no Apple Silicon, no Intel iGPU) with "Use GPU" enabled. On CPU,
/// large-v3-turbo saturates every core of a many-core Mac for minutes and
/// froze the whole machine during a benchmark (2026-10-16). The helper
/// enforces the same rule against ggml's own device list.
func discreteGPUAvailable() -> Bool {
    MTLCopyAllDevices().contains { !$0.hasUnifiedMemory }
}

/// Why a Whisper profile cannot run right now, or nil when it can.
func whisperUnavailableReason(useGPUSetting: Bool, vulkanFailedThisSession: Bool) -> String? {
    if !useGPUSetting { return "Use GPU (Vulkan) is off" }
    if vulkanFailedThisSession { return "Vulkan already failed this session" }
    if !discreteGPUAvailable() { return "no discrete GPU" }
    if !parakeetVulkanAvailable() { return "no Vulkan device" }
    return nil
}

struct WhisperCppTranscription: Sendable {
    let text: String
    let processingSeconds: Double
}

/// Owns one persistent SuperDictateWhisperHost subprocess running
/// whisper.cpp (Vulkan on a discrete GPU only — see discreteGPUAvailable()). Same stdio PCM
/// protocol and crash-safety rules as the retired Python faster-whisper
/// host: strict read loops, throwing-only IO (no ObjC exceptions — see the
/// 2026-08-27 agent SIGABRT incident), and a pipe-EOF death contract so a
/// crashed parent never leaves an orphaned GPU-holding helper behind.
actor WhisperCppEngine {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle

    init(modelPath: String, language: String) throws {
        guard let helper = Self.resolvedHelperBinaryURL(),
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw WhisperCppEngineError.helperUnavailable
        }
        let process = Process()
        process.executableURL = helper
        process.arguments = [modelPath, language, "gpu"]
        var environment = ProcessInfo.processInfo.environment
        // Tier-1 of the shader loader's 3-tier fallback: point whisper.cpp's
        // ggml-vulkan at ITS OWN shader corpus (a different ggml pin than
        // parakeet's — never share the two). Only when it actually exists,
        // so dev builds fall through to the source-relative tier 3.
        if let resources = Bundle.main.resourceURL {
            let whisperShaders = resources.appendingPathComponent("whisper-vulkan-shaders", isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: whisperShaders.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                environment["SUPERDICTATE_VULKAN_SHADER_DIR"] = whisperShaders.path
            }
        }
        process.environment = environment
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.standardError
        try process.run()
        self.process = process
        self.input = inputPipe.fileHandleForWriting
        self.output = outputPipe.fileHandleForReading
    }

    /// Same resolution chain as LLMHostProcess.resolvedHelperBinaryURL():
    /// packaged .app first (Contents/Helpers/), then a SwiftPM .build
    /// sibling for `swift run`/self-test dev builds.
    private static func resolvedHelperBinaryURL() -> URL? {
        let name = "SuperDictateWhisperHost"
        let packaged = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/\(name)")
        if FileManager.default.isExecutableFile(atPath: packaged.path) {
            return packaged
        }
        if let selfURL = Bundle.main.executableURL {
            let sibling = selfURL.deletingLastPathComponent().appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: sibling.path) {
                return sibling
            }
        }
        return nil
    }

    func transcribe(samples: [Float]) throws -> WhisperCppTranscription {
        let started = ProcessInfo.processInfo.systemUptime
        var payload = Data(capacity: 4 + samples.count * 4)
        var header = UInt32(samples.count).littleEndian
        withUnsafeBytes(of: &header) { payload.append(contentsOf: $0) }
        samples.withUnsafeBytes { payload.append(contentsOf: $0) }
        do {
            try input.write(contentsOf: payload)
        } catch {
            throw WhisperCppEngineError.helperExited(process.terminationStatus)
        }
        let responseHeader = try readExactly(4)
        let length = responseHeader.withUnsafeBytes { UInt32(littleEndian: $0.load(as: UInt32.self)) }
        guard length <= 1_000_000 else {
            throw WhisperCppEngineError.invalidResponse
        }
        let data = try readExactly(Int(length))
        guard let text = String(data: data, encoding: .utf8) else {
            throw WhisperCppEngineError.invalidResponse
        }
        return WhisperCppTranscription(text: text,
                                       processingSeconds: ProcessInfo.processInfo.systemUptime - started)
    }

    func shutdown() {
        try? input.close()
        if process.isRunning { process.terminate() }
    }

    /// Reads exactly `count` bytes from the helper's stdout. Short reads on
    /// pipes are normal; an empty read is EOF (helper died) and surfaces as
    /// `helperExited`. Never uses `synchronizeFile()`/legacy `write(_:)`:
    /// fsync on a pipe raises an uncatchable NSFileHandleOperationException
    /// (the SIGABRT crash-loop root cause of the 2026-08-27 incident).
    private func readExactly(_ count: Int) throws -> Data {
        var data = Data(capacity: count)
        while data.count < count {
            guard let chunk = try output.read(upToCount: count - data.count), !chunk.isEmpty else {
                throw WhisperCppEngineError.helperExited(process.terminationStatus)
            }
            data.append(chunk)
        }
        return data
    }

    deinit {
        try? input.close()
        try? output.close()
        if process.isRunning { process.terminate() }
    }
}
