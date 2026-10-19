import Foundation

// MARK: - Transcribe while recording
//
// A long dictation is cut into ≤ 25 s segments at pauses (PauseSegmenter)
// and transcribed as overlapping windows (transcribeWithOverlapWindows).
// Most of those windows are fixed long before the hotkey is released, so
// `IncrementalOverlapTranscriber` transcribes them DURING the recording and
// the release path only has the last one or two left to do.
//
// The recording-time results are an exact-match CACHE, never a second
// algorithm. At release the segments and windows are computed from the
// FULL buffer exactly as before; a window's words are taken from the cache
// only when its start sample, sample count and audio checksum all match
// (and the ASR engine was not reloaded in between); every other window is
// transcribed again. Phase B assembly then runs unchanged. So the final
// text is byte-identical to the batch path for the same buffer, and the
// stability rule below only decides how much recording-time work is
// wasted, never what the text says.
//
// The cache holds words only. Nothing here produces text, and nothing
// here can reach the LLM: correction/rewrite (`finalizedText`) still runs
// once per dictation, on the fully assembled text, after release.

/// FNV-1a over the samples' bit patterns. Not cryptographic: it only has
/// to tell "this window is the same audio" from a different one in the
/// same recording, alongside the exact start/count match.
func speculativeWindowChecksum(_ samples: [Float]) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    samples.withUnsafeBufferPointer { buffer in
        for sample in buffer {
            hash ^= UInt64(sample.bitPattern)
            hash &*= 0x0000_0100_0000_01b3
        }
    }
    return hash
}

/// One window transcribed while the recording was still running.
struct SpeculativeWindowResult: Sendable {
    let startSample: Int
    let sampleCount: Int
    let checksum: UInt64
    let words: [TranscribedWord]
    let engineCallSeconds: Double
}

/// Recording-time window results for ONE recording, keyed by
/// `(startSample, sampleCount)`. `engineGeneration` is the
/// `TranscriptionWorker.engineGeneration` the windows were transcribed
/// with; a reload since then (model switch, restart) invalidates the
/// whole cache.
struct SpeculativeWindowCache: Sendable {
    struct Key: Hashable, Sendable {
        let startSample: Int
        let sampleCount: Int
    }

    let engineGeneration: UInt64
    private(set) var entries: [Key: SpeculativeWindowResult] = [:]

    init(engineGeneration: UInt64) {
        self.engineGeneration = engineGeneration
    }

    var count: Int { entries.count }

    /// ASR seconds spent during the recording on every cached window.
    var totalEngineCallSeconds: Double {
        entries.values.reduce(0) { $0 + $1.engineCallSeconds }
    }

    func contains(_ window: AudioWindow) -> Bool {
        entries[Key(startSample: window.startSample, sampleCount: window.samples.count)] != nil
    }

    mutating func insert(_ result: SpeculativeWindowResult) {
        entries[Key(startSample: result.startSample, sampleCount: result.sampleCount)] = result
    }

    /// The cached result for `window` ONLY if it is the very same audio
    /// transcribed by the very same loaded engine; nil means "transcribe
    /// it again".
    func result(for window: AudioWindow, engineGeneration currentGeneration: UInt64) -> SpeculativeWindowResult? {
        guard currentGeneration == engineGeneration,
              let entry = entries[Key(startSample: window.startSample, sampleCount: window.samples.count)],
              entry.checksum == speculativeWindowChecksum(window.samples) else {
            return nil
        }
        return entry
    }
}

enum SpeculativeWindowPlanner {
    /// Overlap windows of the growing recording that are guaranteed to come
    /// out identical (same start, same samples) when the FULL buffer is
    /// windowed at release.
    ///
    /// Why a window is stable:
    /// - `PauseSegmenter` is one greedy left-to-right pass over fixed 20 ms
    ///   analysis windows aligned at sample 0. Its decision at window w
    ///   depends only on windows ≤ w, and every cut lands on a window
    ///   boundary. Run on the prefix trimmed to whole analysis windows (the
    ///   trailing partial window's RMS could still change), it makes
    ///   exactly the full buffer's cuts up to that point. So every segment
    ///   but the last (still open) one is final: same start, same samples,
    ///   same `hasSignal`.
    /// - `OverlapWindower` gives window i `overlapBefore = min(4 s,
    ///   halfBudget(i), count(i-1))` and `overlapAfter = min(4 s,
    ///   halfBudget(i), count(i+1))`, where halfBudget depends only on
    ///   segment i's own length. Window i is therefore fixed once segments
    ///   i-1, i are final and segment i+1 is either final too or can no
    ///   longer end up shorter than `min(4 s, halfBudget(i))`.
    /// - The open segment can still be cut at a later pause, but never
    ///   before the silent run that is open at the end of the prefix (if
    ///   any) — `pendingSilentRunStartSample` — and never before the end of
    ///   the trimmed prefix otherwise.
    /// A window that is final has a segment after it, so the full buffer
    /// always has ≥ 2 segments and really takes the overlap path.
    static func stableWindows(prefix: [Float],
                              sampleRate: Double = SAMPLE_RATE) -> [AudioWindow] {
        let analysisWindowSize = max(1, Int(PauseSegmenter.defaultWindowSeconds * sampleRate))
        let usableCount = (prefix.count / analysisWindowSize) * analysisWindowSize
        guard usableCount > 0 else { return [] }
        let trimmed = usableCount == prefix.count ? prefix : Array(prefix[0..<usableCount])
        let segmented = PauseSegmenter.segmentWithPendingPause(samples: trimmed, sampleRate: sampleRate)
        let segments = segmented.segments
        guard segments.count >= 2 else { return [] }

        let windows = OverlapWindower.addOverlap(to: segments, sampleRate: sampleRate)
        let open = segments[segments.count - 1]
        let earliestOpenEnd = min(segmented.pendingSilentRunStartSample ?? usableCount, usableCount)
        let openMinimumCount = max(0, earliestOpenEnd - open.startSample)
        let maxSegmentSamples = Int(PauseSegmenter.defaultMaxSegmentSeconds * sampleRate)
        let requestedOverlapSamples = Int(OverlapWindower.defaultOverlapSeconds * sampleRate)

        var stable: [AudioWindow] = []
        for index in 0..<(segments.count - 1) {
            if index + 1 < segments.count - 1 {
                stable.append(windows[index])
                continue
            }
            let halfBudget = max(0, maxSegmentSamples - segments[index].samples.count) / 2
            guard openMinimumCount >= min(requestedOverlapSamples, halfBudget) else { break }
            stable.append(windows[index])
        }
        return stable
    }
}

/// Drives recording-time transcription for ONE recording: every
/// `pollInterval` it snapshots the samples captured so far, finds the
/// stable windows (`SpeculativeWindowPlanner`) and transcribes the next one
/// not yet cached, one ASR call at a time. Nothing at all happens below
/// `PauseSegmenter.defaultMinSegmentSeconds` of audio — a short dictation
/// is never segmented, so it never gets recording-time work.
///
/// `finish()` (release) and `cancel()` stop the loop and AWAIT the
/// in-flight window before returning, so the caller can use the worker
/// next without tripping its `inFlight` guard. The in-flight call is never
/// cancelled — the native call cannot be interrupted anyway, and its
/// result is a stable window the release path will reuse. Any failure
/// (a throw from ASR) ends recording-time work and drops the cache; the
/// release path still has the full buffer and every existing fallback.
actor IncrementalOverlapTranscriber {
    typealias Snapshot = @Sendable () -> [Float]?
    typealias SampleCount = @Sendable () -> Int?
    typealias TranscribeWindow = @Sendable ([Float]) async throws -> TokenTranscriptionWorkerResult

    private let snapshot: Snapshot
    private let sampleCount: SampleCount
    private let transcribeWindow: TranscribeWindow
    private let pollNanoseconds: UInt64
    private let minimumSamples: Int
    private var cache: SpeculativeWindowCache
    private var loopTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var stopRequested = false
    private var failed = false

    /// - Parameters:
    ///   - snapshot: samples captured so far, nil once the recording ended.
    ///   - sampleCount: cheap count of the same, nil once it ended.
    ///   - engineGeneration: the worker's engine generation at start; the
    ///     release path drops the cache if it has changed.
    init(engineGeneration: UInt64,
         pollInterval: TimeInterval = 1.5,
         sampleRate: Double = SAMPLE_RATE,
         snapshot: @escaping Snapshot,
         sampleCount: @escaping SampleCount,
         transcribeWindow: @escaping TranscribeWindow) {
        self.cache = SpeculativeWindowCache(engineGeneration: engineGeneration)
        self.pollNanoseconds = UInt64(max(0.01, pollInterval) * 1_000_000_000)
        self.minimumSamples = Int(PauseSegmenter.defaultMinSegmentSeconds * sampleRate)
        self.snapshot = snapshot
        self.sampleCount = sampleCount
        self.transcribeWindow = transcribeWindow
    }

    /// The production wiring: the live recording of `audio` identified by
    /// `generation`, transcribed through `worker`'s token call.
    static func forRecording(audio: AudioCapture,
                             generation: UInt64,
                             worker: TranscriptionWorker) async -> IncrementalOverlapTranscriber {
        let engineGeneration = await worker.engineGeneration
        let transcriber = IncrementalOverlapTranscriber(
            engineGeneration: engineGeneration,
            snapshot: { audio.activeRecordingSnapshot(generation: generation) },
            sampleCount: { audio.activeRecordingSampleCount(generation: generation) },
            transcribeWindow: { samples in
                try await worker.transcribeWithTokens(samples: samples,
                                                      requestedAt: ProcessInfo.processInfo.systemUptime)
            }
        )
        await transcriber.start()
        return transcriber
    }

    func start() {
        guard loopTask == nil, !stopRequested else { return }
        loopTask = Task(priority: .utility) { await self.runLoop() }
    }

    /// Release: stop, await the in-flight window, hand over the cache (nil
    /// when recording-time work failed or produced nothing).
    func finish() async -> SpeculativeWindowCache? {
        await stopAndWait()
        guard !failed, cache.count > 0 else { return nil }
        return cache
    }

    /// Cancelled or abandoned recording: stop, await the in-flight window,
    /// discard everything.
    func cancel() async {
        await stopAndWait()
        cache = SpeculativeWindowCache(engineGeneration: cache.engineGeneration)
    }

    private func stopAndWait() async {
        stopRequested = true
        sleepTask?.cancel()
        let running = loopTask
        loopTask = nil
        await running?.value
    }

    private func runLoop() async {
        var moreWorkReady = false
        while !stopRequested {
            if !moreWorkReady {
                let nanoseconds = pollNanoseconds
                let sleeper = Task { _ = try? await Task.sleep(nanoseconds: nanoseconds) }
                sleepTask = sleeper
                await sleeper.value
                sleepTask = nil
                guard !stopRequested else { return }
            }
            moreWorkReady = false

            guard let count = sampleCount() else { return }
            guard count >= minimumSamples else { continue }
            guard let prefix = snapshot() else { return }
            let stable = SpeculativeWindowPlanner.stableWindows(prefix: prefix)
            guard let next = stable.first(where: { !cache.contains($0) }) else { continue }
            guard !stopRequested else { return }

            do {
                let result = try await transcribeWindow(next.samples)
                cache.insert(SpeculativeWindowResult(startSample: next.startSample,
                                                     sampleCount: next.samples.count,
                                                     checksum: speculativeWindowChecksum(next.samples),
                                                     words: result.transcription.words,
                                                     engineCallSeconds: result.engineCallSeconds))
                moreWorkReady = stable.contains { !cache.contains($0) }
            } catch {
                log("recording-time transcription stopped (\(error.localizedDescription)); release transcribes the whole buffer")
                failed = true
                return
            }
        }
    }
}

/// Release-side ASR for a dictation that may have had recording-time work:
/// stop the driver and await its in-flight window FIRST (one ASR call at a
/// time), then run the normal path on the FULL buffer with the cache. The
/// returned result's `speculative*` fields keep the latency line honest.
func transcribeSegmentedAfterRecording(
    samples: [Float],
    speculative: IncrementalOverlapTranscriber?,
    worker: TranscriptionWorker,
    language: DictationLanguage?,
    resolveViaKeyboard: Bool,
    requestedAt: TimeInterval
) async throws -> TranscriptionWorkerResult {
    try await transcribeAfterRecording(speculative: speculative) { cache in
        try await transcribeSegmented(samples: samples,
                                      worker: worker,
                                      language: language,
                                      resolveViaKeyboard: resolveViaKeyboard,
                                      requestedAt: requestedAt,
                                      speculativeCache: cache)
    }
}

/// The ordering half of `transcribeSegmentedAfterRecording`, with the
/// full-buffer transcription injected (the `incremental-transcription`
/// self-test drives it with a fake ASR).
func transcribeAfterRecording(
    speculative: IncrementalOverlapTranscriber?,
    transcribeFullBuffer: (SpeculativeWindowCache?) async throws -> TranscriptionWorkerResult
) async throws -> TranscriptionWorkerResult {
    let waitStartedAt = ProcessInfo.processInfo.systemUptime
    let cache = await speculative?.finish()
    let waitSeconds = ProcessInfo.processInfo.systemUptime - waitStartedAt
    var result = try await transcribeFullBuffer(cache)
    result.speculativeWaitSeconds = waitSeconds
    return result
}
