// SuperDictate — extracted from the monolithic main.swift
// during the refactor/split-main refactor.
//

import AppKit
import AVFoundation
import AudioToolbox
import Foundation
import CoreGraphics
import CryptoKit
import Darwin
import ApplicationServices
import IOKit
import QuartzCore
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Transcription worker
//
// Owns the single loaded `OnnxAsrEngine` (the SuperDictateOnnxHost helper,
// CPU only). The helper serves one request at a time — but the actor alone
// does NOT keep that contract. Actors are reentrant at suspension points:
// while `await engine.transcribe(...)` is suspended, a second transcribe()
// call would enter the actor and start a concurrent request. The real guard
// is ParakeyApp.isBusy, which ensures the app never issues a second
// transcribe while one is in flight. The `inFlight` flag below is a cheap
// defensive backstop should that invariant ever break: it refuses (and, in
// DEBUG, asserts on) a re-entrant call. (The helper itself answers a
// concurrent request with BUSY — spec §8.)

struct TranscriptionWorkerResult: Sendable {
    let text: String
    let workerQueueSeconds: Double
    let decoderPreparationSeconds: Double
    let engineCallSeconds: Double
    let engineProcessingSeconds: Double
    /// True iff `transcribeSegmented(...)` had at least one signal-bearing
    /// segment that stayed empty even after a retry (see
    /// SegmentedTranscription.swift). Always false for a plain single-call
    /// `TranscriptionWorker.transcribe(...)` result — only
    /// `transcribeSegmented` ever sets it true.
    var hadSegmentFailure: Bool = false
    /// Overlap windows whose words came from the recording-time cache
    /// (IncrementalTranscription.swift) instead of a post-release ASR call,
    /// and the ASR seconds those calls took DURING the recording. Not part
    /// of `engineCallSeconds`, which is post-release work only.
    var speculativeWindowsReused: Int = 0
    var speculativeEngineCallSeconds: Double = 0
    /// Release-side wait for the recording-time window still in flight.
    var speculativeWaitSeconds: Double = 0

    func timing(totalSeconds: Double) -> ASRTimingBreakdown {
        ASRTimingBreakdown(
            totalSeconds: totalSeconds,
            workerQueueSeconds: workerQueueSeconds,
            decoderPreparationSeconds: decoderPreparationSeconds,
            engineCallSeconds: engineCallSeconds,
            engineProcessingSeconds: engineProcessingSeconds
        )
    }
}

/// `TranscriptionWorkerResult`'s sibling for the token/word-timestamp call
/// (`TranscriptionWorker.transcribeWithTokens`). Carries no
/// `hadSegmentFailure`: the overlap path never produces one (it throws and
/// defers to the plain path instead — see `assembleOverlapTranscript`).
struct TokenTranscriptionWorkerResult: Sendable {
    let transcription: TokenTranscription
    let workerQueueSeconds: Double
    let engineCallSeconds: Double
    let engineProcessingSeconds: Double
}

struct CompletedTranscriptionWorkerResult: Sendable {
    let transcription: TranscriptionWorkerResult
    let completedAt: TimeInterval
}

/// The ASR backend line for diagnostics and the menu. Speech recognition
/// runs only on the CPU; the GPU belongs to the LLM host.
func asrBackendDescription(language: InterfaceLanguage) -> String {
    localizedText("CPU (ONNX Runtime)", "CPU (ONNX Runtime)", language: language)
}

/// Thin `TaskGroup`-based timeout wrapper (spec §11.3: warm-up must
/// complete within "a defined timeout"). Races `operation` against a sleep
/// of `seconds`; whichever finishes first wins and the loser is cancelled.
/// `operation` is expected to be cooperatively cancellable (the native
/// bridge calls are synchronous C calls with no internal cancellation
/// point, so in practice a timeout here means "stop waiting on this Task",
/// not "abort the native call mid-flight" — the underlying native
/// transcribe/warm-up call still runs to completion on its own thread; this
/// is still useful because it bounds how long `TranscriptionWorker.load()`
/// blocks app startup on a hung driver).
struct TimedOutError: LocalizedError {
    var errorDescription: String? { "Operation timed out" }
}

func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @Sendable @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimedOutError()
        }
        defer { group.cancelAll() }
        let result = try await group.next()!
        return result
    }
}

actor TranscriptionWorker {
    private var engine: OnnxAsrEngine?
    private(set) var loadedProfile: SpeechModelProfile?
    private(set) var ready = false
    /// model_id reported by the ONNX host for the loaded engine.
    var loadedModelID: String? {
        get async { await engine?.modelID }
    }
    /// Reentrancy backstop — see the comment above. True for the full
    /// duration of transcribe(), including across its await.
    private var inFlight = false
    /// Bumped on every load/unload: recording-time window results carry
    /// the generation they were made with and are dropped at release if
    /// the engine was replaced in between.
    private(set) var engineGeneration: UInt64 = 0
    #if DEBUG
    /// Self-test hook (`onnx-asr-real`): load this already-installed model
    /// directory instead of the profile's app cache. Never set in the app.
    private var modelDirectoryOverride: URL?

    init(modelDirectoryOverride: URL? = nil) {
        self.modelDirectoryOverride = modelDirectoryOverride
    }
    #endif

    /// Default thread policy: every physical core but two (left for audio
    /// capture and the UI), clamped to `2...16`. ONNX encoder throughput
    /// keeps improving up to the physical core count (GigaAM v3, 4 min RU,
    /// Xeon E5-2696 v3 with 18 cores: 8 threads 18.9 s, 12 → 16.1 s,
    /// 16 → 14.7 s, 18 → 13.6 s) and nothing else needs the CPU while a
    /// dictation is transcribed — the LLM runs on the GPU. Hyper-threads
    /// do not help a matmul-bound encoder, hence physical cores. An
    /// optional `SUPERDICTATE_ASR_THREADS` diagnostic override is
    /// validated to `1...32`; an out-of-range or non-numeric override is
    /// ignored (falls back to the computed default) rather than crashing a
    /// debug/test run.
    static func resolvedASRThreadCount(
        physicalCoreCount: Int = physicalCPUCoreCount(),
        environmentOverride: String? = ProcessInfo.processInfo.environment["SUPERDICTATE_ASR_THREADS"]
    ) -> Int {
        let defaultCount = max(2, min(16, physicalCoreCount - 2))
        guard let environmentOverride, let parsed = Int(environmentOverride), (1...32).contains(parsed) else {
            return defaultCount
        }
        return parsed
    }

    /// `hw.physicalcpu`; half the logical count if sysctl fails.
    static func physicalCPUCoreCount() -> Int {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.physicalcpu", &count, &size, nil, 0) == 0, count > 0 {
            return Int(count)
        }
        return max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
    }

    func load(profile requestedProfile: SpeechModelProfile,
              progressHandler: SpeechModelDownloadProgressHandler? = nil) async throws {
        let profile = requestedProfile.productionProfile
        if requestedProfile != profile {
            log("ASR: ignoring unsupported speech model \(requestedProfile.shortName); using \(profile.shortName)")
        }
        if ready, engine != nil, loadedProfile == profile {
            log("ASR: \(profile.shortName) already ready")
            return
        }

        if engine != nil {
            await unload()
        }

        if modelDirectoryOverrideForLoad != nil || speechModelCacheExists(for: profile) {
            log("ASR: verifying + loading cached \(profile.shortName) weights…")
        } else {
            log("ASR: downloading + verifying + loading \(profile.shortName) weights…")
        }
        let t0 = Date()
        let loaded = try await loadOnnxEngine(profile: profile, progressHandler: progressHandler)
        engine = loaded
        loadedProfile = profile
        ready = true
        engineGeneration &+= 1
        log("ASR: \(profile.shortName) ready in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
        log("ASR model: \(profile.displayName)")
        log("ASR runtime: ONNX Runtime (SuperDictateOnnxHost)")
        let reason = await loaded.providerFallbackReason
        log("ASR device: \(await loaded.providerActual)\(reason.isEmpty ? "" : " (\(reason))")")

        // Best effort, off the load path: a failure only means mel-energy
        // seam placement until the next load retries.
        Task.detached(priority: .utility) {
            do {
                try await downloadSileroVadModelIfNeeded()
                log("Silero VAD model: ready at \(sileroVadModelDefaultPath().path)")
            } catch {
                log("Silero VAD model: download failed (\(error.localizedDescription)); seams use mel-energy placement")
            }
        }
    }

    private var modelDirectoryOverrideForLoad: URL? {
        #if DEBUG
        return modelDirectoryOverride
        #else
        return nil
        #endif
    }

    /// Only the selected profile's model is downloaded and loaded; the other
    /// profile's cache, if any, stays on disk untouched for a later switch.
    private func loadOnnxEngine(profile: SpeechModelProfile,
                                progressHandler: SpeechModelDownloadProgressHandler?) async throws -> OnnxAsrEngine {
        let modelDirectory: URL
        if let override = modelDirectoryOverrideForLoad {
            modelDirectory = override
        } else {
            modelDirectory = try await downloadOnnxModelIfNeeded(profile: profile, progressHandler: progressHandler)
        }
        let threadCount = Self.resolvedASRThreadCount()
        log("ASR threads: \(threadCount)")
        let engine = try await OnnxAsrEngine.launch(modelDirectory: modelDirectory, threadCount: threadCount,
                                                    expectedModelID: profile.onnxModelID)
        log("ASR ONNX model load: \(String(format: "%.2f", await engine.loadSeconds)) s")
        let warmUpStartedAt = ProcessInfo.processInfo.systemUptime
        _ = try await engine.transcribe(samples: [Float](repeating: 0, count: Int(SAMPLE_RATE * 0.4)))
        log("ASR warm-up (ONNX CPU): \(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - warmUpStartedAt)) s")
        return engine
    }

    /// The ONNX helper is killed on a hard timeout or dies on a crash; the
    /// next request gets a fresh one (spec §8) instead of a dead engine.
    private func liveEngine() async throws -> OnnxAsrEngine {
        guard let engine, let loadedProfile else { throw NSError(domain: "Parakey", code: -2) }
        if await engine.isAlive { return engine }
        log("ASR: ONNX helper is gone — relaunching")
        let fresh = try await loadOnnxEngine(profile: loadedProfile, progressHandler: nil)
        self.engine = fresh
        return fresh
    }

    func transcribe(samples: [Float],
                               language: DictationLanguage? = nil,
                               resolveViaKeyboard: Bool = true,
                               requestedAt: TimeInterval) async throws -> TranscriptionWorkerResult {
        let workerEnteredAt = ProcessInfo.processInfo.systemUptime
        guard engine != nil else { throw NSError(domain: "Parakey", code: -2) }
        guard !inFlight else {
            log("ASR: transcribe re-entered while another transcription is in flight — refusing (ParakeyApp.isBusy should make this impossible)")
            assertionFailure("TranscriptionWorker.transcribe re-entered across a suspension point")
            throw NSError(domain: "Parakey", code: -3)
        }
        inFlight = true
        defer { inFlight = false }

        // `resolveEffectiveDictationLanguage` is only used for deterministic
        // post-processing today (see `DictationLanguage`'s doc comment) —
        // the ASR model takes no forced-language parameter.
        // `TranscriptionWorker` is an actor, so this method runs on its
        // executor, not the main thread — hop explicitly for the Carbon TIS
        // call inside `resolveEffectiveDictationLanguage`, which (like the
        // rest of AppKit/Carbon) is only main-thread-safe.
        // `resolveViaKeyboard` is false for recovered (previous-session)
        // audio: the *current* keyboard layout has no bearing on what
        // language a stale recording was spoken in.
        if resolveViaKeyboard {
            _ = await MainActor.run {
                resolveEffectiveDictationLanguage(setting: language ?? .auto)
            }
        }

        let engineCallStartedAt = ProcessInfo.processInfo.systemUptime
        let transcription = try await liveEngine().transcribe(samples: samples)
        let engineCallCompletedAt = ProcessInfo.processInfo.systemUptime
        return TranscriptionWorkerResult(
            text: transcription.text,
            workerQueueSeconds: workerEnteredAt - requestedAt,
            decoderPreparationSeconds: 0,
            engineCallSeconds: engineCallCompletedAt - engineCallStartedAt,
            engineProcessingSeconds: transcription.processingSeconds
        )
    }

    /// Token/word-timestamp sibling of `transcribe(...)`, used ONLY by the
    /// overlap-window path in `transcribeSegmented`. Mirrors `transcribe`'s
    /// engine-presence check, `inFlight` reentrancy backstop (including the
    /// `defer` that clears it, so a throw out of here leaves the worker
    /// usable for the plain-path fallback that immediately follows) and
    /// timing accounting.
    func transcribeWithTokens(samples: [Float],
                                          requestedAt: TimeInterval) async throws -> TokenTranscriptionWorkerResult {
        let workerEnteredAt = ProcessInfo.processInfo.systemUptime
        guard engine != nil else { throw NSError(domain: "Parakey", code: -2) }
        guard !inFlight else {
            log("ASR: transcribeWithTokens re-entered while another transcription is in flight — refusing")
            throw NSError(domain: "Parakey", code: -3)
        }
        inFlight = true
        defer { inFlight = false }

        let engineCallStartedAt = ProcessInfo.processInfo.systemUptime
        let transcription = try await liveEngine().transcribeWithTokens(samples: samples)
        let engineCallCompletedAt = ProcessInfo.processInfo.systemUptime
        return TokenTranscriptionWorkerResult(
            transcription: transcription,
            workerQueueSeconds: workerEnteredAt - requestedAt,
            engineCallSeconds: engineCallCompletedAt - engineCallStartedAt,
            engineProcessingSeconds: engineCallCompletedAt - engineCallStartedAt
        )
    }

    func warmUp() async throws -> ASRTimingBreakdown {
        let samples = [Float](repeating: 0, count: Int(SAMPLE_RATE * 0.4))
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let transcription = try await transcribe(
            samples: samples,
            language: nil,
            requestedAt: requestedAt
        )
        let completedAt = ProcessInfo.processInfo.systemUptime
        return transcription.timing(totalSeconds: completedAt - requestedAt)
    }

    func unload() async {
        await engine?.shutdown()
        engine = nil
        loadedProfile = nil
        ready = false
        engineGeneration &+= 1
        log("ASR: unloaded")
    }
}

/// Adapts `transcribeSegments` (pure orchestration) to the real
/// `TranscriptionWorker`: splits `samples` with `PauseSegmenter`, feeds
/// each piece through `worker.transcribe(...)` in order (the worker's own
/// `inFlight` guard makes concurrent calls impossible anyway, so strictly
/// sequential segment processing costs nothing extra there), and merges
/// the per-segment `TranscriptionWorkerResult`s into one aggregate result
/// with the same shape a single whole-buffer call would have produced —
/// every existing caller of `TranscriptionWorker.transcribe(...)` downstream
/// of this (post-processing, latency logging, history) needs no changes.
/// For a recording short enough to produce exactly one segment (the
/// overwhelming majority of dictations), this is one ASR call, identical
/// to today's behavior.
func transcribeSegmented(
    samples: [Float],
    worker: TranscriptionWorker,
    language: DictationLanguage?,
    resolveViaKeyboard: Bool,
    requestedAt: TimeInterval,
    speculativeCache: SpeculativeWindowCache? = nil
) async throws -> TranscriptionWorkerResult {
    let segments = PauseSegmenter.segment(samples: samples, sampleRate: SAMPLE_RATE)

    // Multi-segment dictations only: try the overlap-window + boundary-oracle
    // + word-timestamp-dedup path first. ANY failure anywhere inside it (a
    // Vulkan throw, a JSON decode failure, a VAD/bridge failure, a
    // signal-bearing window that produced nothing, an empty transcript)
    // falls through to the plain path below — which is byte-for-byte the
    // v0.4.6 behavior, retries included. A 0- or 1-segment dictation (the
    // overwhelming majority) never even evaluates this branch: no
    // `OverlapWindower`, no `BoundaryOracle`, no `SileroVadEngine`, no
    // added latency.
    if segments.count > 1 {
        do {
            let result = try await transcribeWithOverlapWindows(
                samples: samples,
                segments: segments,
                worker: worker,
                requestedAt: requestedAt,
                speculativeCache: speculativeCache
            )
            log("overlap transcription path: succeeded")
            return result
        } catch {
            log("overlap transcription path failed (\(error.localizedDescription)), falling back to plain segmentation")
        }
    }

    var totalDecoderPreparationSeconds = 0.0
    var totalEngineCallSeconds = 0.0
    var totalEngineProcessingSeconds = 0.0
    var firstWorkerQueueSeconds = 0.0
    var haveFirstTiming = false

    let outcome = await transcribeSegments(segments) { segmentSamples in
        let result = try await worker.transcribe(
            samples: segmentSamples,
            language: language,
            resolveViaKeyboard: resolveViaKeyboard,
            requestedAt: requestedAt
        )
        totalDecoderPreparationSeconds += result.decoderPreparationSeconds
        totalEngineCallSeconds += result.engineCallSeconds
        totalEngineProcessingSeconds += result.engineProcessingSeconds
        if !haveFirstTiming {
            firstWorkerQueueSeconds = result.workerQueueSeconds
            haveFirstTiming = true
        }
        return result.text
    }

    // `transcribeSegments` deliberately absorbs per-segment throws so one
    // bad segment can't discard the rest of the dictation, which would
    // otherwise make the underlying engine error unreachable by every
    // caller. Surface it here, once, for all three call sites.
    if let lastErrorDescription = outcome.lastErrorDescription {
        log("segmented transcription ASR error: \(lastErrorDescription)")
    }

    return TranscriptionWorkerResult(
        text: outcome.text,
        workerQueueSeconds: firstWorkerQueueSeconds,
        decoderPreparationSeconds: totalDecoderPreparationSeconds,
        engineCallSeconds: totalEngineCallSeconds,
        engineProcessingSeconds: totalEngineProcessingSeconds,
        hadSegmentFailure: outcome.hadSegmentFailure
    )
}

/// The overlap path, in two deliberately separated phases:
///
/// **Phase A (`async`)** — transcribe every overlap window through the
/// worker, collecting word timestamps. Nothing model-independent happens
/// here.
///
/// **Phase B (fully synchronous, `assembleOverlapWindows` below)** — load
/// the VAD model at most once, run the boundary oracle over every seam,
/// filter by ownership, dedup, join.
///
/// The split is not cosmetic. `SileroVadEngine`/`VadBoundaryOracle` hold
/// non-`Sendable` mutable state and a raw native context; keeping every use
/// of them inside one synchronous function means they are constructed once,
/// never cross an `await`, never touch a second isolation domain, and are
/// destroyed by a `defer` on every exit path including every throw.
///
/// Throws on ANY problem; the sole caller turns that into a plain-path
/// fallback for the whole dictation.
///
/// Takes no `language`/`resolveViaKeyboard`: the plain path's only use of
/// them is a `_ =`-discarded `resolveEffectiveDictationLanguage(...)` call
/// (a pure function — see KeyboardLanguage.swift — whose result that path
/// also discards, since parakeet.cpp's PCM entry point accepts no forced
/// language), so omitting it here changes nothing observable.
func transcribeWithOverlapWindows(
    samples: [Float],
    segments: [AudioSegment],
    worker: TranscriptionWorker,
    requestedAt: TimeInterval,
    speculativeCache: SpeculativeWindowCache? = nil
) async throws -> TranscriptionWorkerResult {
    let engineGeneration = await worker.engineGeneration
    return try await transcribeWithOverlapWindows(
        samples: samples,
        segments: segments,
        speculativeCache: speculativeCache,
        engineGeneration: engineGeneration
    ) { windowSamples in
        try await worker.transcribeWithTokens(samples: windowSamples, requestedAt: requestedAt)
    }
}

/// The overlap path proper, with the window ASR call injected (the
/// `incremental-transcription` self-test drives it with a fake). A window
/// whose exact audio is in `speculativeCache` (same start, count and
/// checksum, same `engineGeneration`) reuses those words; every other
/// window is transcribed here, exactly as without a cache.
func transcribeWithOverlapWindows(
    samples: [Float],
    segments: [AudioSegment],
    speculativeCache: SpeculativeWindowCache?,
    engineGeneration: UInt64,
    transcribeWindow: ([Float]) async throws -> TokenTranscriptionWorkerResult
) async throws -> TranscriptionWorkerResult {
    // `segments` MUST be `PauseSegmenter.segment(...)`'s direct output —
    // never filtered or reordered — or every `AudioSegment.startSample`,
    // and therefore every absolute seam timestamp below, is wrong. The
    // caller passes it straight through; keep it that way.
    let windows = OverlapWindower.addOverlap(to: segments, sampleRate: SAMPLE_RATE)

    // --- Phase A: one token/word-timestamp ASR call per window ---------
    var perWindowWords: [[TranscribedWord]] = []
    perWindowWords.reserveCapacity(windows.count)
    var totalEngineCallSeconds = 0.0
    var totalEngineProcessingSeconds = 0.0
    var firstWorkerQueueSeconds = 0.0
    var haveFirstTiming = false
    var reusedCount = 0
    var speculativeEngineCallSeconds = 0.0

    for window in windows {
        if let cached = speculativeCache?.result(for: window, engineGeneration: engineGeneration) {
            reusedCount += 1
            speculativeEngineCallSeconds += cached.engineCallSeconds
            perWindowWords.append(cached.words)
            continue
        }
        let result = try await transcribeWindow(window.samples)
        if !haveFirstTiming {
            firstWorkerQueueSeconds = result.workerQueueSeconds
            haveFirstTiming = true
        }
        totalEngineCallSeconds += result.engineCallSeconds
        totalEngineProcessingSeconds += result.engineProcessingSeconds
        perWindowWords.append(result.transcription.words)
    }

    // --- Phase B: synchronous, model-lifetime-scoped assembly ----------
    let assembled = try assembleOverlapWindows(windows: windows,
                                               perWindowWords: perWindowWords,
                                               fullSamples: samples)
    log("overlap transcription: \(windows.count) windows (\(reusedCount) from recording-time cache), seam splits \(assembled.seamSplitSamples), \(assembled.droppedAtSeams) word(s) deduped at seams")

    return TranscriptionWorkerResult(
        text: assembled.text,
        workerQueueSeconds: firstWorkerQueueSeconds,
        decoderPreparationSeconds: 0,
        engineCallSeconds: totalEngineCallSeconds,
        engineProcessingSeconds: totalEngineProcessingSeconds,
        // Always false, by construction: `assembleOverlapTranscript` throws
        // (rather than returning) whenever a signal-bearing window produced
        // nothing, so this path only ever RETURNS when nothing was lost.
        // Every real loss is handled by the plain path's shipped
        // retry/`hadSegmentFailure`/retain-on-loss net, untouched here.
        hadSegmentFailure: false,
        speculativeWindowsReused: reusedCount,
        speculativeEngineCallSeconds: speculativeEngineCallSeconds
    )
}

/// The Silero VAD model file. `TranscriptionWorker.load` fetches it in the
/// background (`downloadSileroVadModelIfNeeded`); until it lands — or
/// offline — `SileroVadEngine` is never constructed and the oracle chain
/// runs mel-energy → midpoint, a fully supported configuration.
private func sileroVadModelPath() -> String {
    if let override = ProcessInfo.processInfo.environment["SUPERDICTATE_SILERO_VAD_MODEL"], !override.isEmpty {
        return override
    }
    return sileroVadModelDefaultPath().path
}

/// Phase B of the overlap path — see `transcribeWithOverlapWindows`.
/// Synchronous on purpose: `SileroVadEngine` is created at most once here,
/// used for every seam of this dictation, and torn down by the `defer`
/// before returning or throwing.
private func assembleOverlapWindows(
    windows: [AudioWindow],
    perWindowWords: [[TranscribedWord]],
    fullSamples: [Float]
) throws -> OverlapAssemblyResult {
    var oracles: [BoundaryOracle] = []
    var vadEngine: SileroVadEngine?
    defer { vadEngine?.shutdown() }

    let modelPath = sileroVadModelPath()
    if FileManager.default.fileExists(atPath: modelPath) {
        do {
            let engine = try SileroVadEngine(modelPath: modelPath)
            vadEngine = engine
            oracles.append(VadBoundaryOracle(engine: engine))
        } catch {
            // Never fatal — the design doc is explicit that a missing or
            // broken VAD model degrades seam placement, never the dictation.
            log("overlap transcription: Silero VAD unavailable (\(error.localizedDescription)) — using mel-energy/midpoint seam placement")
        }
    } else {
        log("overlap transcription: no Silero VAD model at \(modelPath) — using mel-energy/midpoint seam placement")
    }
    oracles.append(MelEnergyBoundaryOracle())

    return try assembleOverlapTranscript(windows: windows,
                                         perWindowWords: perWindowWords,
                                         fullSamples: fullSamples,
                                         sampleRate: SAMPLE_RATE,
                                         boundaryOracles: oracles)
}
