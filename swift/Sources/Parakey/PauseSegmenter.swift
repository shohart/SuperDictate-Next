import Foundation

/// One contiguous slice of a captured recording, produced by
/// `PauseSegmenter.segment(...)`. `hasSignal` is true iff at least
/// `signalMinWindows` analysis windows inside this segment were NOT judged
/// silent — a single non-silent window (a breath, a mic bump, a keyboard
/// click) is deliberately NOT enough, since that would flag a spurious
/// failure on a dictation that actually succeeded. Used
/// downstream (see `SegmentedTranscription.swift`) to tell "the model
/// returned nothing because this really was silence" apart from "the
/// model returned nothing despite real speech being present," which is
/// the failure mode this whole feature exists to catch.
struct AudioSegment: Sendable, Equatable {
    let samples: [Float]
    let hasSignal: Bool
    /// This segment's absolute offset (in samples) within the original
    /// captured buffer `PauseSegmenter.segment(...)` was given. Defaults to
    /// 0 for source compatibility with existing single-segment test
    /// literals that don't care about absolute position; real segments
    /// produced by `segment(...)` always set this correctly.
    let startSample: Int
    init(samples: [Float], hasSignal: Bool, startSample: Int = 0) {
        self.samples = samples
        self.hasSignal = hasSignal
        self.startSample = startSample
    }
}

/// Splits a captured mono PCM buffer into segments cut only at natural
/// pauses in speech (never mid-phrase), with a hard safety cap so a
/// single unbroken run of speech can't grow long enough to hit the
/// Parakeet encoder's superlinear-cost regime (see
/// docs/superpowers/specs/2026-07-30-long-dictation-pause-segmentation-design.md).
/// Pure and synchronous — no I/O, no audio-hardware or model dependency,
/// safe to unit test directly.
enum PauseSegmenter {
    static let defaultMaxSegmentSeconds: Double = 25.0
    /// How much audio the current segment must already hold before a pause
    /// is even *considered* as a cut point. Deliberately large: an ordinary
    /// short dictation (a couple of sentences with normal inter-sentence
    /// pauses) must go through ASR as ONE segment, exactly as before this
    /// feature existed — cutting it up would reintroduce the clause-splitting
    /// punctuation damage that fixed-size chunking was rejected for. Only a
    /// genuinely long dictation (the case this feature targets) reaches this
    /// threshold and starts cutting at its natural pauses.
    static let defaultMinSegmentSeconds: Double = 15.0
    static let defaultPauseThresholdSeconds: Double = 0.4
    static let defaultWindowSeconds: Double = 0.02
    static let defaultSilenceRMSThreshold: Float = 0.02
    /// Minimum number of non-silent analysis windows (~100ms at the default
    /// 20ms window) a segment needs before it counts as carrying real
    /// signal. One stray window is a click or a breath, not speech.
    static let defaultSignalMinWindows: Int = 5

    static func segment(
        samples: [Float],
        sampleRate: Double,
        maxSegmentSeconds: Double = defaultMaxSegmentSeconds,
        minSegmentSeconds: Double = defaultMinSegmentSeconds,
        pauseThresholdSeconds: Double = defaultPauseThresholdSeconds,
        windowSeconds: Double = defaultWindowSeconds,
        silenceRMSThreshold: Float = defaultSilenceRMSThreshold,
        signalMinWindows: Int = defaultSignalMinWindows
    ) -> [AudioSegment] {
        segmentWithPendingPause(samples: samples,
                                sampleRate: sampleRate,
                                maxSegmentSeconds: maxSegmentSeconds,
                                minSegmentSeconds: minSegmentSeconds,
                                pauseThresholdSeconds: pauseThresholdSeconds,
                                windowSeconds: windowSeconds,
                                silenceRMSThreshold: silenceRMSThreshold,
                                signalMinWindows: signalMinWindows).segments
    }

    /// `segment(...)` plus the one piece of loop state the recording-time
    /// path (IncrementalTranscription.swift) needs: the absolute sample
    /// where the silent run still open at the END of `samples` began (nil
    /// when the buffer ends on a non-silent window or right after a cut).
    /// A later pause cut of the trailing segment can land there at the
    /// earliest — never before it — so it bounds how short that segment
    /// can still become once more audio arrives. The cuts themselves are
    /// exactly `segment(...)`'s: this IS that function's body.
    static func segmentWithPendingPause(
        samples: [Float],
        sampleRate: Double,
        maxSegmentSeconds: Double = defaultMaxSegmentSeconds,
        minSegmentSeconds: Double = defaultMinSegmentSeconds,
        pauseThresholdSeconds: Double = defaultPauseThresholdSeconds,
        windowSeconds: Double = defaultWindowSeconds,
        silenceRMSThreshold: Float = defaultSilenceRMSThreshold,
        signalMinWindows: Int = defaultSignalMinWindows
    ) -> (segments: [AudioSegment], pendingSilentRunStartSample: Int?) {
        guard !samples.isEmpty else { return ([], nil) }

        let windowSize = max(1, Int(windowSeconds * sampleRate))
        let maxSegmentSamples = max(windowSize, Int(maxSegmentSeconds * sampleRate))
        let minSegmentSamples = max(0, Int(minSegmentSeconds * sampleRate))
        let pauseWindowCount = max(1, Int((pauseThresholdSeconds / windowSeconds).rounded()))

        // Per-window silence flags across the whole buffer, computed once
        // up front so both the cut logic and the later hasSignal check can
        // reuse them without recomputing RMS.
        var windowIsSilent: [Bool] = []
        windowIsSilent.reserveCapacity(samples.count / windowSize + 1)
        var scanOffset = 0
        while scanOffset < samples.count {
            let end = min(scanOffset + windowSize, samples.count)
            var sumSquares: Double = 0
            for i in scanOffset..<end {
                let v = Double(samples[i])
                sumSquares += v * v
            }
            let rms = Float(sqrt(sumSquares / Double(end - scanOffset)))
            windowIsSilent.append(rms < silenceRMSThreshold)
            scanOffset = end
        }

        func sampleIndex(forWindow w: Int) -> Int { w * windowSize }

        /// True iff the range contains at least `signalMinWindows` non-silent
        /// analysis windows — see `defaultSignalMinWindows`.
        func hasSignal(in range: Range<Int>) -> Bool {
            guard range.lowerBound < range.upperBound else { return false }
            let startWindow = range.lowerBound / windowSize
            let endWindow = min(windowIsSilent.count, (range.upperBound + windowSize - 1) / windowSize)
            guard startWindow < endWindow else { return false }
            let nonSilentCount = windowIsSilent[startWindow..<endWindow].reduce(0) { $0 + ($1 ? 0 : 1) }
            return nonSilentCount >= max(1, signalMinWindows)
        }

        var segments: [AudioSegment] = []
        var segmentStartSample = 0

        func makeSegment(endSample: Int) -> Bool {
            let end = min(endSample, samples.count)
            guard end > segmentStartSample else { return false }
            let range = segmentStartSample..<end
            segments.append(AudioSegment(samples: Array(samples[range]),
                                         hasSignal: hasSignal(in: range),
                                         startSample: segmentStartSample))
            segmentStartSample = end
            return true
        }

        var windowIndex = 0
        var silentRunStart: Int?

        while windowIndex < windowIsSilent.count {
            if windowIsSilent[windowIndex] {
                if silentRunStart == nil { silentRunStart = windowIndex }
            } else {
                silentRunStart = nil
            }

            let currentSegmentLength = sampleIndex(forWindow: windowIndex + 1) - segmentStartSample

            var madeAnyCut = false

            if let runStart = silentRunStart,
               (windowIndex - runStart + 1) >= pauseWindowCount,
               currentSegmentLength >= minSegmentSamples {
                // A long-enough pause, and the segment so far is already
                // substantial — cut at the START of the silent run, so the
                // segment that just ended carries no trailing silence and
                // the pause itself becomes the leading silence of the NEXT
                // segment (harmless there; ASR ignores leading quiet).
                if makeSegment(endSample: sampleIndex(forWindow: runStart)) {
                    silentRunStart = nil
                    madeAnyCut = true
                }
            }

            if !madeAnyCut && currentSegmentLength >= maxSegmentSamples {
                // No qualifying pause arrived before the safety cap — force
                // a cut here so a single unbroken run of speech can never
                // exceed the cap.
                if makeSegment(endSample: sampleIndex(forWindow: windowIndex + 1)) {
                    silentRunStart = nil
                    madeAnyCut = true
                }
            }

            windowIndex += 1
        }

        _ = makeSegment(endSample: samples.count)
        return (segments, silentRunStart.map(sampleIndex(forWindow:)))
    }
}
