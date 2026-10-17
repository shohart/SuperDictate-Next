import Foundation
import silero_vad

/// One probability value per Silero VAD analysis window, plus the window
/// size (in samples) those probabilities were computed over -- the
/// Swift-side shape of `sd_silero_vad_speech_probabilities`'s raw
/// `out_probabilities`/`out_count`/`out_window_size_samples` triple, after
/// copying out of the native buffer (see `SileroVadEngine.speechProbabilities`,
/// which frees the native buffer before returning).
struct SpeechProbabilities {
    let values: [Float]
    let windowSizeSamples: Int
}

enum SileroVadEngineError: LocalizedError {
    case modelNotFound(path: String)
    case modelLoadFailed(String)
    case emptyAudio
    case inferenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let path):
            return "Silero VAD model file not found at \(path)"
        case .modelLoadFailed(let detail):
            return "Failed to load Silero VAD model: \(detail)"
        case .emptyAudio:
            return "No audio samples to run VAD over"
        case .inferenceFailed(let detail):
            return "Silero VAD inference failed: \(detail)"
        }
    }
}

/// Minimal seam for `VadBoundaryOracle` to depend on -- lets self-tests
/// inject a synthetic mock (see `main.swift`'s `vad-boundary-oracle` group)
/// instead of a real `SileroVadEngine`/model, the same way `transcribeSegments`
/// is tested against a mock `transcribeOne` closure rather than a real
/// `ParakeetEngine`. `SileroVadEngine` conforms to this below.
protocol SpeechProbabilitySource {
    func speechProbabilities(samples: [Float]) throws -> SpeechProbabilities
}

/// Owns exactly one loaded Silero VAD native context (`SDSileroVadContext`,
/// from the `silero_vad` SwiftPM target's C bridge -- see
/// swift/Sources/silero_vad/include/superdictate_silero_vad.h). Mirrors
/// `ParakeetEngine`'s "load once, keep a live context" shape: the model is
/// loaded exactly once in `init`, and every subsequent `speechProbabilities`
/// call reuses that same context -- callers (namely `VadBoundaryOracle`,
/// constructed once per app session and handed one shared engine instance)
/// must NOT create a fresh `SileroVadEngine` per overlap zone/seam, which
/// would reload the model on every seam of every long dictation.
///
/// A plain `final class`, not an `actor`: `BoundaryOracle.chooseSplit` is a
/// synchronous protocol method (called from the synchronous
/// `chainBoundaryOracle` closure), so `speechProbabilities` must be callable
/// synchronously too. Safety here matches `ParakeetEngine`'s own reasoning
/// for its native pointer: the assembly call site that owns seam placement
/// already runs single-threaded/serialized (mirroring how
/// `TranscriptionWorker` already serializes calls into `ParakeetEngine`), so
/// no additional actor isolation is needed for this synchronous-only type.
final class SileroVadEngine: SpeechProbabilitySource {
    // Set once in `init`, nil'd out by `shutdown()` -- same double-free
    // guard shape as `ParakeetEngine.context`.
    private var context: OpaquePointer?

    /// Loads the pinned Silero VAD model exactly once. Throws (never
    /// crashes) on a missing file or a native load failure -- callers
    /// should treat that as "VAD unavailable" and simply not construct a
    /// `VadBoundaryOracle` this session, letting the chain fall through to
    /// `MelEnergyBoundaryOracle`/`MidpointBoundaryOracle` for every seam.
    init(modelPath: String) throws {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw SileroVadEngineError.modelNotFound(path: modelPath)
        }
        var outContext: OpaquePointer?
        let status = modelPath.withCString { path in
            sd_silero_vad_create(path, &outContext)
        }
        guard status == SD_SILERO_VAD_OK, let created = outContext else {
            throw SileroVadEngineError.modelLoadFailed("bridge status \(status.rawValue)")
        }
        context = created
    }

    /// `samples` must be non-empty mono Float32 PCM at 16kHz (this
    /// project's fixed `SAMPLE_RATE` -- the native bridge does not
    /// resample). Copies the native probabilities array into a Swift
    /// `[Float]` and frees the native buffer before returning, so no raw
    /// pointer outlives this call.
    func speechProbabilities(samples: [Float]) throws -> SpeechProbabilities {
        guard !samples.isEmpty else {
            throw SileroVadEngineError.emptyAudio
        }
        guard let context else {
            throw SileroVadEngineError.inferenceFailed("engine already shut down")
        }

        var outProbabilities: UnsafeMutablePointer<Float>?
        var outCount: UInt64 = 0
        var outWindow: UInt64 = 0
        let status = samples.withUnsafeBufferPointer { buffer -> SDSileroVadStatus in
            sd_silero_vad_speech_probabilities(
                context, buffer.baseAddress, UInt64(buffer.count),
                &outProbabilities, &outCount, &outWindow
            )
        }

        guard status == SD_SILERO_VAD_OK else {
            let message = String(cString: sd_silero_vad_last_error_message(context))
            throw SileroVadEngineError.inferenceFailed(message.isEmpty ? "bridge status \(status.rawValue)" : message)
        }
        guard let probabilitiesPointer = outProbabilities else {
            throw SileroVadEngineError.inferenceFailed("native call succeeded but returned no probabilities")
        }
        defer { sd_silero_vad_free_probabilities(probabilitiesPointer) }

        let values = Array(UnsafeBufferPointer(start: probabilitiesPointer, count: Int(outCount)))
        return SpeechProbabilities(values: values, windowSizeSamples: Int(outWindow))
    }

    /// Deterministic shutdown -- safe to call more than once (a no-op after
    /// the first call), same shape as `ParakeetEngine.shutdown()`.
    func shutdown() {
        Self.destroy(context: &context)
    }

    deinit {
        Self.destroy(context: &context)
    }

    private static func destroy(context: inout OpaquePointer?) {
        guard let toFree = context else { return }
        context = nil
        sd_silero_vad_destroy(toFree)
    }
}

/// Third link in the boundary-oracle chain (Task 9:
/// `chainBoundaryOracle([VadBoundaryOracle(...), MelEnergyBoundaryOracle()])`):
/// runs Silero VAD over the overlap zone and picks the CENTER of the
/// LONGEST run of windows below `silenceProbabilityThreshold`. Declines
/// (returns nil, falling through to mel-energy/midpoint) whenever VAD
/// inference itself fails/is unavailable, or when nothing in the zone reads
/// as silent -- never crashes, never blocks a dictation on a missing/broken
/// VAD model.
struct VadBoundaryOracle: BoundaryOracle {
    /// Below this speech probability, a window counts as "silent" for the
    /// purposes of finding the longest quiet run in the zone -- matches
    /// achetronic's tuned constant (DD-014's vadSilenceThreshold, in the
    /// documented 0.35-0.5 band).
    var silenceProbabilityThreshold: Float = 0.4
    /// `SpeechProbabilitySource`, not a concrete `SileroVadEngine`, so
    /// self-tests can inject a mock probability source and exercise the
    /// pure longest-run decision logic without loading a real model (see
    /// `vad-boundary-oracle` in main.swift).
    let engine: SpeechProbabilitySource

    func chooseSplit(samples: [Float], zoneStartSample: Int, zoneEndSample: Int, sampleRate: Double) -> Int? {
        guard zoneEndSample > zoneStartSample, !samples.isEmpty else { return nil }
        guard let probabilities = try? engine.speechProbabilities(samples: samples) else {
            return nil // VAD unavailable/failed this call -- decline, chain falls through
        }
        let windowSize = probabilities.windowSizeSamples
        guard windowSize > 0 else { return nil }

        // Find the CENTER of the LONGEST run of windows below the silence
        // threshold -- matches DD-014's vadBoundaryOracle exactly.
        var bestRunStart = -1
        var bestRunLength = 0
        var currentRunStart = -1
        var currentRunLength = 0
        for (index, probability) in probabilities.values.enumerated() {
            if probability < silenceProbabilityThreshold {
                if currentRunStart < 0 { currentRunStart = index }
                currentRunLength += 1
                if currentRunLength > bestRunLength {
                    bestRunLength = currentRunLength
                    bestRunStart = currentRunStart
                }
            } else {
                currentRunStart = -1
                currentRunLength = 0
            }
        }
        guard bestRunStart >= 0 else { return nil } // nothing below threshold -- decline
        let centerWindowIndex = bestRunStart + bestRunLength / 2
        return zoneStartSample + centerWindowIndex * windowSize
    }
}
