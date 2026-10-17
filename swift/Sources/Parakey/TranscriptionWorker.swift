// SuperDictate — extracted from the monolithic main.swift
// during the refactor/split-main refactor.
//

import AppKit
import AVFoundation
import AudioToolbox
import Foundation
import CoreGraphics
import parakeet_cpp
import CryptoKit
import Darwin
import ApplicationServices
import IOKit
import QuartzCore
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Transcription worker
//
// Owns the single loaded `ParakeetEngine`. parakeet.cpp's loaded context
// doesn't tolerate concurrent inference calls — but the actor alone does
// NOT keep that contract. Actors are reentrant at suspension points: while
// `await engine.transcribe(...)` is suspended, a second transcribe() call
// would enter the actor and start a concurrent inference against the same
// context. The real guard is ParakeyApp.isBusy, which ensures the app never
// issues a second transcribe while one is in flight. The `inFlight` flag
// below is a cheap defensive backstop should that invariant ever break: it
// refuses (and, in DEBUG, asserts on) a re-entrant call instead of
// corrupting engine state. (The native bridge itself adds a THIRD,
// independent guard — see `SD_PARAKEET_ERR_BUSY` in
// swift/Sources/parakeet_cpp/bridge/superdictate_parakeet.cpp.)
//
// Per docs/parakeet-intel-backend.md §9, this is a single `ParakeetEngine?`
// field, not an engine-picker enum — there is exactly one production ASR
// engine (spec §2.1), so `LoadedSpeechEngine` (the old
// `.whisperLargeV3Turbo(WhisperEngine)` single-case enum this replaces) is
// gone entirely rather than gaining a second case.

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

/// Runtime ASR backend status for diagnostics/UI (spec §11.4). Distinct
/// from the *setting* (`Settings.shared.useGPU`) — this reflects what is
/// ACTUALLY running right now.
enum ParakeetRuntimeStatus: Sendable, Equatable {
    case cpu
    /// `deviceDescription` is e.g. "AMD Radeon RX 6600 (MoltenVK)".
    case vulkan(deviceDescription: String)
    /// GPU was requested and Vulkan init/warm-up (or a later mid-session
    /// inference call) failed; this session has fallen back to CPU and will
    /// not retry Vulkan again until the app restarts.
    case cpuFallbackAfterVulkanError
    /// GPU is enabled in the saved preference, but no engine has attempted
    /// to load it yet in this session (e.g. before the first `load()`
    /// call) — distinguishes "not yet tried" from an actual fallback.
    case gpuRequestedNotYetLoaded

    func localizedDescription(language: InterfaceLanguage) -> String {
        switch self {
        case .cpu:
            return localizedText("CPU", "CPU", language: language)
        case .vulkan(let deviceDescription):
            return "Vulkan — \(deviceDescription)"
        case .cpuFallbackAfterVulkanError:
            return localizedText(
                "CPU (переключено после ошибки Vulkan)",
                "CPU fallback after Vulkan error",
                language: language
            )
        case .gpuRequestedNotYetLoaded:
            return localizedText(
                "GPU включён в настройках, но используется CPU",
                "GPU requested, CPU fallback active",
                language: language
            )
        }
    }
}

/// Thin `TaskGroup`-based timeout wrapper (spec §11.3: warm-up must
/// complete within "a defined timeout"). Races `operation` against a sleep
/// of `seconds`; whichever finishes first wins and the loser is cancelled.
/// `operation` is expected to be cooperatively cancellable (parakeet.cpp's
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

/// Thread-safe cache of the last-known ASR runtime status, so synchronous
/// UI code (menu construction, which cannot `await` across the
/// `TranscriptionWorker` actor without restructuring the whole menu-build
/// path) can read a recent snapshot. `TranscriptionWorker` pushes every
/// `runtimeStatus` change here; this is a diagnostic mirror, never the
/// source of truth (that's always `TranscriptionWorker.runtimeStatus`
/// itself, read via `await` wherever an async context is already available,
/// e.g. `diagnosticsText()`).
final class ParakeetRuntimeStatusCache: @unchecked Sendable {
    static let shared = ParakeetRuntimeStatusCache()
    private let lock = NSLock()
    private var status: ParakeetRuntimeStatus = .gpuRequestedNotYetLoaded

    func update(_ newStatus: ParakeetRuntimeStatus) {
        lock.lock()
        status = newStatus
        lock.unlock()
    }

    func current() -> ParakeetRuntimeStatus {
        lock.lock()
        defer { lock.unlock() }
        return status
    }
}

/// Synchronous convenience for menu construction: the last-known ASR
/// backend status, localized. Falls back to
/// `.gpuRequestedNotYetLoaded`/`.cpu`-equivalent wording before the first
/// `TranscriptionWorker.load()` call has completed.
func lastKnownParakeetRuntimeStatusDescription(language: InterfaceLanguage) -> String {
    ParakeetRuntimeStatusCache.shared.current().localizedDescription(language: language)
}

actor TranscriptionWorker {
    private enum LoadedEngine {
        case parakeet(ParakeetEngine)
        case whisperCpp(WhisperCppEngine)
        case onnx(OnnxAsrEngine)
    }

    private var engine: LoadedEngine?
    /// The profile actually running, which differs from the requested one
    /// when a GPU-only Whisper profile fell back to Parakeet.
    private(set) var loadedProfile: SpeechModelProfile?
    /// The "Use GPU (Vulkan)" preference. The app reads the saved setting;
    /// `--benchmark-transcribe` passes its own device choice so it never
    /// has to write the user's settings.
    private let useGPUPreference: @Sendable () -> Bool

    init(useGPUPreference: @escaping @Sendable () -> Bool = { Settings.shared.useGPU }) {
        self.useGPUPreference = useGPUPreference
    }
    private var loadedUseGPU: Bool?
    private(set) var ready = false
    /// Reentrancy backstop — see the comment above. True for the full
    /// duration of transcribe(), including across its await.
    private var inFlight = false

    /// Current actual runtime backend (spec §11.4) — distinct from the
    /// saved `Settings.shared.useGPU` preference. Updated by `load()` and by
    /// the mid-session Vulkan-inference-failure fallback in `transcribe()`.
    /// Every change is mirrored into `ParakeetRuntimeStatusCache` for
    /// synchronous UI reads (see that type's doc comment).
    private(set) var runtimeStatus: ParakeetRuntimeStatus = .cpu {
        didSet { ParakeetRuntimeStatusCache.shared.update(runtimeStatus) }
    }

    /// Set once per app session the first time a Vulkan attempt fails
    /// (init/warm-up OR a later mid-session inference call) while GPU is
    /// enabled in Settings. Per spec §9.3: never retry Vulkan again within
    /// the same session once this is set, regardless of how many more
    /// times `load()` is called (e.g. after a settings change unrelated to
    /// GPU) — only a full app restart may attempt Vulkan again. Reset only
    /// by `unload()` immediately followed by process exit; NOT reset by a
    /// normal `load()` call, and never mutates the persisted
    /// `Settings.shared.useGPU` preference.
    private var vulkanFailedThisSession = false
    private var vulkanFailureReason: String?

    /// Default thread policy from docs/parakeet-intel-backend.md §10:
    /// `max(2, min(8, activeProcessorCount / 2))`, with an optional
    /// `SUPERDICTATE_ASR_THREADS` diagnostic override validated to `1...32`.
    /// An out-of-range or non-numeric override is ignored (falls back to the
    /// computed default) rather than crashing a debug/test run.
    static func resolvedParakeetThreadCount(
        activeProcessorCount: Int = ProcessInfo.processInfo.activeProcessorCount,
        environmentOverride: String? = ProcessInfo.processInfo.environment["SUPERDICTATE_ASR_THREADS"]
    ) -> Int {
        let defaultCount = max(2, min(8, activeProcessorCount / 2))
        guard let environmentOverride, let parsed = Int(environmentOverride), (1...32).contains(parsed) else {
            return defaultCount
        }
        return parsed
    }

    func load(profile requestedProfile: SpeechModelProfile,
              progressHandler: SpeechModelDownloadProgressHandler? = nil) async throws {
        var profile = requestedProfile.productionProfile
        if requestedProfile != profile {
            log("ASR: ignoring unsupported speech model \(requestedProfile.shortName); using \(profile.shortName)")
        }
        // Whisper is GPU-only (WhisperCppEngine.swift): without a usable
        // discrete GPU this session runs the default Parakeet profile
        // instead. The saved choice is left untouched.
        if profile.requiresDiscreteGPU,
           let reason = whisperUnavailableReason(useGPUSetting: useGPUPreference(),
                                                 vulkanFailedThisSession: vulkanFailedThisSession) {
            log("ASR: \(profile.shortName) runs only on a discrete GPU (\(reason)) — using \(SpeechModelProfile.productionDefault.shortName) instead")
            profile = .productionDefault
        }
        // spec §9.1 loading algorithm: read the GPU preference, and only
        // actually attempt Vulkan if (a) it's enabled AND (b) Vulkan hasn't
        // already failed once this session (§9.3 — never retry Vulkan again
        // within the same session; only a full app restart may attempt it
        // again, since the persisted preference is never auto-mutated).
        // The ONNX backend is CPU-only (spec §6): the GPU preference does
        // not apply to it and must not trigger Vulkan fallback bookkeeping.
        let requestedGPU = useGPUPreference() && !profile.usesOnnxRuntime
        let attemptVulkan = requestedGPU && !vulkanFailedThisSession
        if requestedGPU && vulkanFailedThisSession {
            log("ASR: Use GPU (Vulkan) is enabled in Settings, but Vulkan already failed once this session (\(vulkanFailureReason ?? "unknown reason")) — staying on CPU for the rest of this session")
        }
        var useGPU = attemptVulkan
        if ready, engine != nil, loadedProfile == profile, loadedUseGPU == useGPU {
            log("ASR: \(profile.shortName) already ready")
            return
        }

        if engine != nil {
            await unload()
        }

        if speechModelCacheExists(for: profile) {
            log("ASR: verifying + loading cached \(profile.shortName) weights…")
        } else {
            log("ASR: downloading + verifying + loading \(profile.shortName) weights…")
        }
        let t0 = Date()
        let loaded: LoadedEngine
        switch profile {
        case .parakeetTDTv3:
            let result = try await loadParakeetEngine(attemptVulkan: attemptVulkan, progressHandler: progressHandler)
            loaded = .parakeet(result.engine)
            runtimeStatus = result.status
        case .parakeetUltraOnnx:
            loaded = .onnx(try await loadOnnxEngine(progressHandler: progressHandler))
            runtimeStatus = .cpu
        case .whisperRussian, .whisperRussianCodeSwitch:
            let modelURL = try await downloadWhisperGGUFModelIfNeeded()
            let language = profile == .whisperRussian ? "ru" : "auto"
            do {
                let whisper = try WhisperCppEngine(modelPath: modelURL.path, language: language)
                _ = try await whisper.transcribe(samples: [Float](repeating: 0, count: Int(SAMPLE_RATE * 0.4)))
                loaded = .whisperCpp(whisper)
                runtimeStatus = .vulkan(deviceDescription: parakeetVulkanDeviceDescription())
            } catch {
                // GPU init/warm-up failed. Never Whisper on CPU: count it as
                // this session's Vulkan failure and run Parakeet on CPU.
                log("ASR: whisper.cpp GPU engine failed to start (\(error.localizedDescription)) — using \(SpeechModelProfile.productionDefault.shortName) on CPU for the rest of this session")
                vulkanFailedThisSession = true
                vulkanFailureReason = error.localizedDescription
                profile = .productionDefault
                useGPU = false
                let result = try await loadParakeetEngine(attemptVulkan: false, progressHandler: progressHandler)
                loaded = .parakeet(result.engine)
                runtimeStatus = .cpuFallbackAfterVulkanError
            }
        }
        engine = loaded
        loadedProfile = profile
        loadedUseGPU = useGPU
        ready = true
        log("ASR: \(profile.shortName) ready in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
        log("ASR model: \(profile.displayName)")
        switch loaded {
        case .parakeet:
            log("ASR runtime: parakeet.cpp \(parakeetRuntimeVersion())")
        case .whisperCpp:
            log("ASR runtime: whisper.cpp (GGUF)")
        case .onnx:
            log("ASR runtime: ONNX Runtime (SuperDictateOnnxHost)")
        }
        log("ASR device requested: \(requestedGPU ? "Vulkan" : "CPU")")
        if case .parakeet(let parakeet) = loaded {
            let loadedDeviceIsVulkan = parakeet.device == .vulkan
            log("ASR device selected: \(loadedDeviceIsVulkan ? "Vulkan" : "CPU")\(runtimeStatus == .cpuFallbackAfterVulkanError ? " (fallback after Vulkan error)" : "")")
        } else if case .whisperCpp = loaded {
            log("ASR device selected: Vulkan")
        } else if case .onnx(let onnx) = loaded {
            let reason = await onnx.providerFallbackReason
            log("ASR device selected: \(await onnx.providerActual)\(reason.isEmpty ? "" : " (\(reason))")")
        }
        // Best-effort legacy cleanup, only after Parakeet has itself
        // succeeded (spec §4.3/§4.4) — never blocks readiness on failure.
        if profile == .parakeetTDTv3 {
            removeLegacyWhisperModelFileIfPresent()
        }
    }

    private func loadParakeetEngine(
        attemptVulkan: Bool,
        progressHandler: SpeechModelDownloadProgressHandler?
    ) async throws -> (engine: ParakeetEngine, status: ParakeetRuntimeStatus) {
        if !speechModelCacheExists(for: .parakeetTDTv3) {
            try assertSufficientDiskSpaceForSpeechModelDownload(profile: .parakeetTDTv3)
        }
        let modelPath = try await downloadParakeetModelIfNeeded()
        let threadCount = Self.resolvedParakeetThreadCount()
        log("ASR threads: \(threadCount)")

        if attemptVulkan {
            do {
                let vulkanEngine = try ParakeetEngine(modelPath: modelPath.path, device: .vulkan, threadCount: threadCount)
                // Warm-up with a defined timeout (spec §11.3: warm-up must
                // complete within "a defined timeout" — no numeric value is
                // specified upstream; 30s is chosen here as generous
                // relative to the measured ~1.2s cold Vulkan/MoltenVK
                // pipeline-compile cost from the Phase 5 pre-spike, while
                // still bounding a genuinely hung/broken driver rather than
                // blocking app startup indefinitely).
                let warmUpStartedAt = ProcessInfo.processInfo.systemUptime
                try await withTimeout(seconds: 30) {
                    try await vulkanEngine.warmUp()
                }
                let warmUpSeconds = ProcessInfo.processInfo.systemUptime - warmUpStartedAt
                log("ASR warm-up (Vulkan): \(String(format: "%.2f", warmUpSeconds)) s")
                let deviceDescription = parakeetVulkanDeviceDescription()
                log("ASR device: Vulkan — \(deviceDescription.isEmpty ? await vulkanEngine.backendDescription() : deviceDescription)")
                return (vulkanEngine, .vulkan(deviceDescription: deviceDescription.isEmpty ? await vulkanEngine.backendDescription() : deviceDescription))
            } catch {
                // Any failure — init, capability probe, warm-up timeout, or
                // the post-init "actually selected CPU" check — destroys
                // the partial Vulkan attempt and falls back to a fresh CPU
                // engine. Never retried again this session (spec §9.3).
                log("ASR: Vulkan init/warm-up failed (\(error.localizedDescription)) — falling back to Parakeet CPU for the rest of this session")
                vulkanFailedThisSession = true
                vulkanFailureReason = error.localizedDescription
            }
        }

        let cpuEngine = try ParakeetEngine(modelPath: modelPath.path, device: .cpu, threadCount: threadCount)
        let warmUpStartedAt = ProcessInfo.processInfo.systemUptime
        try await cpuEngine.warmUp()
        let warmUpSeconds = ProcessInfo.processInfo.systemUptime - warmUpStartedAt
        log("ASR warm-up (CPU): \(String(format: "%.2f", warmUpSeconds)) s")
        return (cpuEngine, requestedGPUButFellBackStatus(attemptedVulkan: attemptVulkan))
    }

    private func loadOnnxEngine(progressHandler: SpeechModelDownloadProgressHandler?) async throws -> OnnxAsrEngine {
        let modelDirectory = try await downloadOnnxModelIfNeeded(progressHandler: progressHandler)
        let threadCount = Self.resolvedParakeetThreadCount()
        log("ASR threads: \(threadCount)")
        let engine = try await OnnxAsrEngine.launch(modelDirectory: modelDirectory, threadCount: threadCount)
        log("ASR ONNX model load: \(String(format: "%.2f", await engine.loadSeconds)) s")
        let warmUpStartedAt = ProcessInfo.processInfo.systemUptime
        _ = try await engine.transcribe(samples: [Float](repeating: 0, count: Int(SAMPLE_RATE * 0.4)))
        log("ASR warm-up (ONNX CPU): \(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - warmUpStartedAt)) s")
        return engine
    }

    /// The ONNX helper is killed on a hard timeout or dies on a crash; the
    /// next request gets a fresh one (spec §8) instead of a dead engine.
    private func liveOnnxEngine(_ onnx: OnnxAsrEngine) async throws -> OnnxAsrEngine {
        if await onnx.isAlive { return onnx }
        log("ASR: ONNX helper is gone — relaunching")
        let fresh = try await loadOnnxEngine(progressHandler: nil)
        engine = .onnx(fresh)
        return fresh
    }

    /// `.cpuFallbackAfterVulkanError` iff this CPU load happened AFTER a
    /// Vulkan attempt just failed in the same call; plain `.cpu` if GPU was
    /// never requested at all this session.
    private func requestedGPUButFellBackStatus(attemptedVulkan: Bool) -> ParakeetRuntimeStatus {
        attemptedVulkan ? .cpuFallbackAfterVulkanError : .cpu
    }

    func transcribe(samples: [Float],
                               language: DictationLanguage? = nil,
                               resolveViaKeyboard: Bool = true,
                               requestedAt: TimeInterval) async throws -> TranscriptionWorkerResult {
        let workerEnteredAt = ProcessInfo.processInfo.systemUptime
        guard let engine else { throw NSError(domain: "Parakey", code: -2) }
        guard !inFlight else {
            log("ASR: transcribe re-entered while another transcription is in flight — refusing (ParakeyApp.isBusy should make this impossible)")
            assertionFailure("TranscriptionWorker.transcribe re-entered across a suspension point")
            throw NSError(domain: "Parakey", code: -3)
        }
        inFlight = true
        defer { inFlight = false }

        // `resolveEffectiveDictationLanguage` is only used for deterministic
        // post-processing today (see `DictationLanguage`'s doc comment) —
        // parakeet.cpp's plain PCM entry point this bridge wraps does not
        // accept a forced-language parameter, unlike whisper.cpp's
        // `params.language`. `TranscriptionWorker` is an actor, so this
        // method runs on its executor, not the main thread — hop explicitly
        // for the Carbon TIS call inside `resolveEffectiveDictationLanguage`,
        // which (like the rest of AppKit/Carbon) is only main-thread-safe.
        // `resolveViaKeyboard` is false for recovered (previous-session)
        // audio: the *current* keyboard layout has no bearing on what
        // language a stale recording was spoken in.
        if resolveViaKeyboard {
            _ = await MainActor.run {
                resolveEffectiveDictationLanguage(setting: language ?? .auto)
            }
        }

        let engineCallStartedAt = ProcessInfo.processInfo.systemUptime
        let isVulkanEngine: Bool
        let result: ParakeetTranscriptionResult
        do {
            switch engine {
            case .parakeet(let parakeet):
                isVulkanEngine = parakeet.device == .vulkan
                result = try await parakeet.transcribe(samples: samples)
            case .whisperCpp(let whisper):
                isVulkanEngine = true
                let transcription = try await whisper.transcribe(samples: samples)
                result = ParakeetTranscriptionResult(text: transcription.text,
                                                     totalSeconds: transcription.processingSeconds,
                                                     inferenceSeconds: transcription.processingSeconds,
                                                     usedGPU: true)
            case .onnx(let onnx):
                isVulkanEngine = false
                let live = try await liveOnnxEngine(onnx)
                let transcription = try await live.transcribe(samples: samples)
                result = ParakeetTranscriptionResult(text: transcription.text,
                                                     totalSeconds: transcription.processingSeconds,
                                                     inferenceSeconds: transcription.processingSeconds,
                                                     usedGPU: false)
            }
        } catch where isVulkanEngine {
            // spec §9.3: a Vulkan engine that initialized fine but fails
            // DURING a real transcription — retain the captured PCM
            // (`samples`, already in hand), destroy the Vulkan engine,
            // create a fresh CPU engine, warm it up, and retry THIS SAME
            // dictation exactly once on CPU. Never retry Vulkan again this
            // session; never fall back to Whisper (removed); never mutate
            // the persisted `useGPU` preference.
            log("ASR: Vulkan inference failed mid-session (\(error.localizedDescription)) — falling back to CPU and retrying this dictation once")
            vulkanFailedThisSession = true
            vulkanFailureReason = error.localizedDescription
            if case .parakeet(let parakeet) = engine {
                await parakeet.shutdown()
                let threadCount = Self.resolvedParakeetThreadCount()
                let cpuEngine: ParakeetEngine
                do {
                    guard let modelPath = try? await downloadParakeetModelIfNeeded() else {
                        throw ParakeetEngineError.inferenceFailed("model path unavailable during mid-session CPU fallback")
                    }
                    cpuEngine = try ParakeetEngine(modelPath: modelPath.path, device: .cpu, threadCount: threadCount)
                    try await cpuEngine.warmUp()
                } catch {
                    // The engine is now unusable and no CPU replacement could
                    // be constructed either — leave `self.engine` nil so the
                    // next `load()` call rebuilds from scratch, and surface the
                    // ORIGINAL Vulkan failure (more informative than the
                    // fallback-construction failure) to the caller.
                    self.engine = nil
                    ready = false
                    throw error
                }
                self.engine = .parakeet(cpuEngine)
                loadedUseGPU = false
                runtimeStatus = .cpuFallbackAfterVulkanError
                result = try await cpuEngine.transcribe(samples: samples)
            } else if case .whisperCpp(let deadEngine) = engine {
                // Same §9.3 contract for the whisper.cpp helper, except that
                // Whisper never runs on CPU: shut the dead GPU helper down
                // and retry THIS dictation once on Parakeet CPU, which then
                // serves the rest of the session.
                await deadEngine.shutdown()
                let cpuEngine: ParakeetEngine
                do {
                    cpuEngine = try await loadParakeetEngine(attemptVulkan: false, progressHandler: nil).engine
                } catch {
                    self.engine = nil
                    ready = false
                    throw error
                }
                self.engine = .parakeet(cpuEngine)
                loadedProfile = .productionDefault
                loadedUseGPU = false
                runtimeStatus = .cpuFallbackAfterVulkanError
                result = try await cpuEngine.transcribe(samples: samples)
            } else {
                throw error
            }
        }
        let engineCallCompletedAt = ProcessInfo.processInfo.systemUptime
        return TranscriptionWorkerResult(
            text: result.text,
            workerQueueSeconds: workerEnteredAt - requestedAt,
            decoderPreparationSeconds: 0,
            engineCallSeconds: engineCallCompletedAt - engineCallStartedAt,
            engineProcessingSeconds: result.inferenceSeconds
        )
    }

    /// Token/word-timestamp sibling of `transcribe(...)`, used ONLY by the
    /// overlap-window path in `transcribeSegmented`. Mirrors `transcribe`'s
    /// engine-presence check, `inFlight` reentrancy backstop (including the
    /// `defer` that clears it, so a throw out of here leaves the worker
    /// usable for the plain-path fallback that immediately follows) and
    /// timing accounting.
    ///
    /// Deliberately does NOT reimplement `transcribe`'s mid-session
    /// Vulkan-inference-failure CPU fallback: a Vulkan failure here throws,
    /// `transcribeSegmented` catches it and re-runs the whole dictation on
    /// the plain path, and THAT path's `transcribe(...)` performs the real
    /// fallback exactly as it does today. One fallback implementation, one
    /// site mutating `vulkanFailedThisSession`/`runtimeStatus`/`engine`.
    /// See task-9-report.md for the full reasoning.
    func transcribeWithTokens(samples: [Float],
                                          requestedAt: TimeInterval) async throws -> TokenTranscriptionWorkerResult {
        let workerEnteredAt = ProcessInfo.processInfo.systemUptime
        guard let engine else { throw NSError(domain: "Parakey", code: -2) }
        guard !inFlight else {
            log("ASR: transcribeWithTokens re-entered while another transcription is in flight — refusing")
            throw NSError(domain: "Parakey", code: -3)
        }
        inFlight = true
        defer { inFlight = false }

        let engineCallStartedAt = ProcessInfo.processInfo.systemUptime
        let transcription: TokenTranscription
        switch engine {
        case .parakeet(let parakeet):
            transcription = try await parakeet.transcribeWithTokens(samples: samples)
        case .onnx(let onnx):
            transcription = try await liveOnnxEngine(onnx).transcribeWithTokens(samples: samples)
        case .whisperCpp:
            throw NSError(domain: "Parakey", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "Token timestamps are only available for Parakeet"])
        }
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
        switch engine {
        case .parakeet(let parakeet):
            await parakeet.shutdown()
        case .onnx(let onnx):
            await onnx.shutdown()
        case .whisperCpp, nil:
            break
        }
        engine = nil
        loadedProfile = nil
        loadedUseGPU = nil
        ready = false
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
    requestedAt: TimeInterval
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
                requestedAt: requestedAt
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
    requestedAt: TimeInterval
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

    for (index, window) in windows.enumerated() {
        let result = try await worker.transcribeWithTokens(samples: window.samples, requestedAt: requestedAt)
        if index == 0 { firstWorkerQueueSeconds = result.workerQueueSeconds }
        totalEngineCallSeconds += result.engineCallSeconds
        totalEngineProcessingSeconds += result.engineProcessingSeconds
        perWindowWords.append(result.transcription.words)
    }

    // --- Phase B: synchronous, model-lifetime-scoped assembly ----------
    let assembled = try assembleOverlapWindows(windows: windows,
                                               perWindowWords: perWindowWords,
                                               fullSamples: samples)
    log("overlap transcription: \(windows.count) windows, seam splits \(assembled.seamSplitSamples), \(assembled.droppedAtSeams) word(s) deduped at seams")

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
        hadSegmentFailure: false
    )
}

/// Where the Silero VAD model file would live if it were staged. There is
/// deliberately NO download wiring for it yet (see
/// scripts/vendor-silero-vad.sh's PROVENANCE notes), so on a normal install
/// this file is absent, `SileroVadEngine` is never constructed, and the
/// oracle chain runs mel-energy → midpoint. That is a fully supported
/// configuration, not a degraded one.
private func sileroVadModelPath() -> String {
    if let override = ProcessInfo.processInfo.environment["SUPERDICTATE_SILERO_VAD_MODEL"], !override.isEmpty {
        return override
    }
    return parakeetModelCacheDirectory()
        .appendingPathComponent("ggml-silero-v6.2.0.bin", isDirectory: false).path
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
