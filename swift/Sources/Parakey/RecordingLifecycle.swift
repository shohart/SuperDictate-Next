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

// MARK: - Recording lifecycle decisions

enum RecordingReleaseAction: Equatable {
    case discardTooShort(duration: Double)
    case transcribe(duration: Double)
}

func recordingReleaseAction(capturedSampleCount: Int,
                                    sampleRate: Double = SAMPLE_RATE,
                                    minimumClipSeconds: Double = MIN_CLIP_SECONDS) -> RecordingReleaseAction {
    let duration = sampleRate > 0 ? Double(max(0, capturedSampleCount)) / sampleRate : 0
    return duration < minimumClipSeconds
        ? .discardTooShort(duration: duration)
        : .transcribe(duration: duration)
}

struct DictationTextProcessingResult: Equatable {
    let text: String
    let appliedCorrectionCount: Int
    let removedFillerWordCount: Int
}

/// Optional final-period removal (ported from upstream shlgd/SuperDictate
/// v0.2.40's `remove_final_period` setting). Only a single trailing "." is
/// dropped; a text ending in ".." (i.e. an ellipsis "...") is kept as-is —
/// the user's punctuation intent there is explicit.
func removingFinalPeriod(from text: String) -> String {
    guard text.last == "." else { return text }
    let withoutFinalPeriod = text.dropLast()
    guard withoutFinalPeriod.last != "." else { return text }
    return String(withoutFinalPeriod)
}

func processedDictationText(rawTranscript: String,
                                    corrections: [TranscriptCorrection],
                                    removeFillerWords: Bool,
                                    removeFinalPeriod: Bool = false,
                                    normalizeNumbersToDigits: Bool = false,
                                    language: DictationLanguage = .auto,
                                    enabledFillerPresetKeys: Set<String> = FillerWordRemover.defaultEnabledPresetKeys,
                                    customFillerWords: [String] = []) -> DictationTextProcessingResult {
    let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    let repaired = ParakeetTranscriptRepair.apply(to: trimmed, language: language)

    let numberNormalized: String
    switch language {
    case .auto, .russian:
        numberNormalized = normalizeNumbersToDigits ? RussianNumberNormalizer.normalize(repaired) : repaired
    default:
        numberNormalized = repaired
    }

    let corrected = TranscriptCorrector.apply(to: numberNormalized, corrections: corrections)

    let textAfterFillers: String
    let removedFillerWordCount: Int
    if removeFillerWords {
        let stripped = FillerWordRemover.apply(to: corrected.text,
                                               enabledPresetKeys: enabledFillerPresetKeys,
                                               customWords: customFillerWords)
        textAfterFillers = stripped.text
        removedFillerWordCount = stripped.removedCount
    } else {
        textAfterFillers = corrected.text
        removedFillerWordCount = 0
    }

    // Final-period removal runs LAST (same as upstream): the toggle drops the
    // trailing dot of the finished, corrected, filler-stripped text.
    let finalText = removeFinalPeriod
        ? removingFinalPeriod(from: textAfterFillers)
        : textAfterFillers
    return DictationTextProcessingResult(text: finalText,
                                         appliedCorrectionCount: corrected.appliedCount,
                                         removedFillerWordCount: removedFillerWordCount)
}

