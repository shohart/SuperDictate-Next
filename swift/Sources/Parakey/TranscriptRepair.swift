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

// MARK: - Transcript corrections
//
// Deterministic local rewrite pass for words or phrases the model
// consistently mishears. Corrections are applied to the transcript
// text before paste/history, never to audio, and replacement text is
// used exactly as the user typed it.

// Originated as a port of the OLD CoreML/ANE/FluidAudio Parakeet stack's
// `<unk>`-for-Cyrillic-"ё" repair (a different runtime than parakeet.cpp —
// NeMo-derived ANE inference, not GGUF/ggml). Re-verified empirically
// against the REAL parakeet.cpp CPU pipeline during Phase 3 of the
// parakeet.cpp migration (see
// .superpowers/sdd/2026-07-28-parakeet-cpp-migration/phase-3-integration-report.md
// for what was actually observed) rather than assumed to carry over
// unchanged. The guard at the top of `apply` (`localizedCaseInsensitiveContains("<unk>")`)
// makes this a no-op whenever the token doesn't appear, so keeping the logic
// wired into the live post-processing pipeline is safe regardless of how
// often the real runtime emits it.
enum ParakeetTranscriptRepair {
    /// If/when parakeet.cpp emits `<unk>` for Cyrillic "ё" in Russian text
    /// (a known quirk of NeMo-derived vocabularies more broadly — see the
    /// Phase 3 report for this build's own empirical finding), replace it
    /// with "ё"/"Ё" for Russian and auto-detect (the app's default
    /// audience). For every other language the token is genuinely unknown
    /// and is removed entirely so a stray Cyrillic character doesn't appear
    /// in English/French/etc. text.
    static func apply(to text: String,
                      language: DictationLanguage = .auto) -> String {
        guard text.localizedCaseInsensitiveContains("<unk>") else { return text }

        let replaceWithYo: Bool
        switch language {
        case .auto, .russian:
            replaceWithYo = true
        default:
            replaceWithYo = false
        }

        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex

        while index < text.endIndex {
            if matchesUnknownToken(in: text, at: index) {
                if replaceWithYo {
                    result.append(shouldCapitalizeYo(before: result) ? "Ё" : "ё")
                }
                index = text.index(index, offsetBy: 5)
            } else {
                result.append(text[index])
                index = text.index(after: index)
            }
        }

        if !replaceWithYo {
            result = result
                .replacingOccurrences(of: #"\s+([.,!?;:])"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private static func matchesUnknownToken(in text: String, at index: String.Index) -> Bool {
        let token = "<unk>"
        guard let end = text.index(index, offsetBy: token.count, limitedBy: text.endIndex) else {
            return false
        }
        return text[index..<end].lowercased() == token
    }

    private static func shouldCapitalizeYo(before prefix: String) -> Bool {
        guard let last = prefix.last(where: { !$0.isWhitespace }) else { return true }
        return ".!?".contains(last)
    }
}

enum TranscriptCorrector {
    private struct Match {
        let range: NSRange
        let replacement: String
    }

    static func apply(to text: String, corrections: [TranscriptCorrection]) -> (text: String, appliedCount: Int) {
        let active = normalizedTranscriptCorrections(corrections)
            .sorted { lhs, rhs in
                if lhs.source.count != rhs.source.count { return lhs.source.count > rhs.source.count }
                return lhs.source.localizedCaseInsensitiveCompare(rhs.source) == .orderedAscending
            }

        guard !text.isEmpty, !active.isEmpty else { return (text, 0) }

        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var matches: [Match] = []

        for correction in active {
            guard let pattern = pattern(for: correction.source),
                  let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            else { continue }

            regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let range = match?.range, range.location != NSNotFound else { return }
                guard !matches.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else { return }
                matches.append(Match(range: range, replacement: correction.replacement))
            }
        }

        guard !matches.isEmpty else { return (text, 0) }

        let rewritten = NSMutableString(string: text)
        for match in matches.sorted(by: { $0.range.location > $1.range.location }) {
            rewritten.replaceCharacters(in: match.range, with: match.replacement)
        }
        return (rewritten as String, matches.count)
    }

    private static func pattern(for source: String) -> String? {
        let parts = source
            .split(whereSeparator: { $0.isWhitespace })
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !parts.isEmpty else { return nil }
        return #"(?<![\p{L}\p{N}_])"# + parts.joined(separator: #"\s+"#) + #"(?![\p{L}\p{N}_])"#
    }
}

// MARK: - Filler word removal
//
// Deterministic regex pass that strips standalone non-word fillers
// ("um", "uh", "ah", "er", "erm", "hmm") and cleans up the punctuation
// artifacts left behind. Intentionally conservative: skips ambiguous
// fillers ("like", "you know") that have legitimate non-filler uses,
// and only fires when the user explicitly enables it via Settings →
// Remove filler words. Applied *after* TranscriptCorrector so explicit
// user corrections always win over filler stripping.

enum FillerWordRemover {
    private enum CapitalizationRepairTarget: Hashable {
        case start
        case afterSentenceTerminator(Int)
    }

    struct FillerWordPreset {
        let key: String
        let displayText: String
        let pattern: String
        let defaultEnabled: Bool
    }

    /// Mirrors the Windows port's `PRESET_FILLERS`: unambiguous hesitation
    /// sounds default on, real words/phrases that only sometimes serve as
    /// fillers default off (never delete real words without consent).
    static let presets: [FillerWordPreset] = [
        // English hesitations (existing patterns, now data-driven)
        FillerWordPreset(key: "en_um", displayText: "um", pattern: "um+", defaultEnabled: true),
        FillerWordPreset(key: "en_uh", displayText: "uh", pattern: "uh+", defaultEnabled: true),
        FillerWordPreset(key: "en_ah", displayText: "ah", pattern: "ah+", defaultEnabled: true),
        FillerWordPreset(key: "en_er", displayText: "er", pattern: "er", defaultEnabled: true),
        FillerWordPreset(key: "en_erm", displayText: "erm", pattern: "erm", defaultEnabled: true),
        FillerWordPreset(key: "en_hm", displayText: "hm", pattern: "hm+", defaultEnabled: true),
        // Russian hesitations
        FillerWordPreset(key: "ru_e", displayText: "э", pattern: "э+", defaultEnabled: true),
        FillerWordPreset(key: "ru_em", displayText: "эм", pattern: "эм+", defaultEnabled: true),
        FillerWordPreset(key: "ru_m", displayText: "м", pattern: "м+", defaultEnabled: true),
        FillerWordPreset(key: "ru_am", displayText: "ам", pattern: "ам+", defaultEnabled: true),
        FillerWordPreset(key: "ru_aa", displayText: "аа", pattern: "аа+", defaultEnabled: true),
        // Russian verbal-tic phrases (default OFF -- real words/phrases)
        FillerWordPreset(key: "ru_kak_by", displayText: "как бы", pattern: #"как\s+бы"#, defaultEnabled: false),
        FillerWordPreset(key: "ru_tipa", displayText: "типа", pattern: "типа", defaultEnabled: false),
        FillerWordPreset(key: "ru_koroche", displayText: "короче", pattern: "короче", defaultEnabled: false),
        FillerWordPreset(key: "ru_eto_samoe", displayText: "это самое", pattern: #"это\s+самое"#, defaultEnabled: false),
        FillerWordPreset(key: "ru_tak_skazat", displayText: "так сказать", pattern: #"так\s+сказать"#, defaultEnabled: false),
        FillerWordPreset(key: "ru_v_obshchem", displayText: "в общем", pattern: #"в\s+общем"#, defaultEnabled: false),
        FillerWordPreset(key: "ru_sobstvenno", displayText: "собственно", pattern: "собственно", defaultEnabled: false),
        FillerWordPreset(key: "ru_dopustim", displayText: "допустим", pattern: "допустим", defaultEnabled: false),
        FillerWordPreset(key: "ru_slushay", displayText: "слушай", pattern: "слушай", defaultEnabled: false),
        FillerWordPreset(key: "ru_ponimaesh", displayText: "понимаешь", pattern: "понимаешь", defaultEnabled: false),
        FillerWordPreset(key: "ru_znaesh", displayText: "знаешь", pattern: "знаешь", defaultEnabled: false),
        // English verbal-tic phrases (default OFF)
        FillerWordPreset(key: "en_like", displayText: "like", pattern: "like", defaultEnabled: false),
        FillerWordPreset(key: "en_you_know", displayText: "you know", pattern: #"you\s+know"#, defaultEnabled: false),
        FillerWordPreset(key: "en_i_mean", displayText: "i mean", pattern: #"i\s+mean"#, defaultEnabled: false),
        FillerWordPreset(key: "en_actually", displayText: "actually", pattern: "actually", defaultEnabled: false),
        FillerWordPreset(key: "en_basically", displayText: "basically", pattern: "basically", defaultEnabled: false),
    ]

    static let defaultEnabledPresetKeys: Set<String> = Set(presets.filter(\.defaultEnabled).map(\.key))

    /// Non-word interjections only. "like" and "you know" are excluded
    /// because they have valid non-filler meanings ("I like cats", "you
    /// know who"). Most entries are regex fragments that allow the
    /// trailing letter to repeat, since real-world fillers stretch out
    /// ("ummm", "uhhhh", "ahhh", "hmmm") and the word-boundary lookahead
    /// would otherwise reject them. "er" and "erm" deliberately have no
    /// repeat quantifier: "er+" would also match the real word "err".
    static func apply(to text: String,
                       enabledPresetKeys: Set<String> = defaultEnabledPresetKeys,
                       customWords: [String] = []) -> (text: String, removedCount: Int) {
        guard !text.isEmpty else { return (text, 0) }

        let presetPatterns = presets
            .filter { enabledPresetKeys.contains($0.key) }
            .map { (source: $0.displayText, pattern: $0.pattern) }
        let customPatterns = customWords.compactMap { word -> (source: String, pattern: String)? in
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let escapedTokens = trimmed
                .split(whereSeparator: { $0.isWhitespace })
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
            return (source: trimmed, pattern: escapedTokens.joined(separator: #"\s+"#))
        }
        // Longest source text first, so a multi-word phrase is tried before any
        // shorter pattern that could otherwise partially match inside it.
        let orderedPatterns = (presetPatterns + customPatterns)
            .sorted { $0.source.count > $1.source.count }
            .map(\.pattern)

        guard !orderedPatterns.isEmpty else { return (text, 0) }

        // Word-boundary lookarounds include `'` (so "it's" stays one
        // token) and `-` (so "uh-huh", "uh-oh" don't get split apart).
        let alternation = orderedPatterns.joined(separator: "|")
        let pattern = #"(?i)(?<![\p{L}\p{N}'\-])("# + alternation + #")(?![\p{L}\p{N}'\-])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (text, 0)
        }

        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return (text, 0) }

        // Preserve sentence-start casing when the removed filler carried
        // the capital ("Um, hello." and "First. Um hello.").
        let capitalizationRepairTargets = capitalizationRepairTargets(for: matches,
                                                                      in: text)

        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            mutable.replaceCharacters(in: match.range, with: "")
        }
        var result = mutable as String

        // Clean up artifacts left behind by removal:
        //   1. Comma runs left by consecutive fillers: "x, , , y" →
        //      "x, y". Quantified so a run of ANY length collapses in
        //      one pass — a non-overlapping ",\s*," pattern consumed
        //      pairs and left ",," behind for two-plus fillers.
        //   2. Whitespace before punctuation: "x ." → "x."
        //   3. Orphan comma glued onto terminal punctuation by pass 2:
        //      "x,." → "x." ("That's all, um." must not end ",.")
        //   4. Multiple consecutive spaces → single space
        //   5. Leading punctuation / whitespace, including "?" and "!"
        //      so a removed sentence-initial filler takes its terminal
        //      punctuation with it ("Um? What?" → "What?")
        //   6. Orphan punctuation after an existing sentence terminator:
        //      "x. , y" → "x. y" when removing "Um," after the period.
        //   7. Trailing whitespace
        result = result.replacingOccurrences(of: #"\s*,(?:\s*,)+"#, with: ",", options: .regularExpression)
        result = result.replacingOccurrences(of: #"([.!?])\s+[,.;:!?]+\s*"#, with: "$1 ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+([.,!?;:])"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #",+([.!?;:])"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"^[\s,.;:!?]+"#, with: "", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        result = restoringCapitalization(in: result,
                                         targets: capitalizationRepairTargets)

        return (result, matches.count)
    }

    private static func capitalizationRepairTargets(for matches: [NSTextCheckingResult],
                                                     in text: String) -> Set<CapitalizationRepairTarget> {
        Set(matches.compactMap { match in
            guard let range = Range(match.range, in: text),
                  text[range].first?.isUppercase == true else {
                return nil
            }
            return capitalizationRepairTarget(for: range, in: text)
        })
    }

    private static func capitalizationRepairTarget(for range: Range<String.Index>,
                                                   in text: String) -> CapitalizationRepairTarget? {
        var index = range.lowerBound
        while index > text.startIndex {
            let previous = text.index(before: index)
            let character = text[previous]
            if character.isWhitespace || isBoundaryWrapper(character) {
                index = previous
                continue
            }
            guard isSentenceTerminator(character) else { return nil }
            return .afterSentenceTerminator(sentenceTerminatorOrdinal(at: previous,
                                                                      in: text))
        }
        return .start
    }

    private static func sentenceTerminatorOrdinal(at target: String.Index,
                                                  in text: String) -> Int {
        var ordinal = 0
        var index = text.startIndex
        while index <= target {
            if isSentenceTerminator(text[index]) {
                ordinal += 1
            }
            index = text.index(after: index)
        }
        return ordinal
    }

    private static func restoringCapitalization(in text: String,
                                                targets: Set<CapitalizationRepairTarget>) -> String {
        guard !targets.isEmpty, !text.isEmpty else { return text }

        let sentenceTargets = Set(targets.compactMap { target -> Int? in
            guard case .afterSentenceTerminator(let ordinal) = target else { return nil }
            return ordinal
        })
        var result = ""
        result.reserveCapacity(text.count)
        var sentenceTerminatorOrdinal = 0
        var shouldCapitalizeNextWord = targets.contains(.start)

        for character in text {
            if shouldCapitalizeNextWord {
                if character.isLowercase {
                    result += character.uppercased()
                    shouldCapitalizeNextWord = false
                    continue
                }
                if character.isLetter || character.isNumber {
                    shouldCapitalizeNextWord = false
                }
            }

            result.append(character)

            if isSentenceTerminator(character) {
                sentenceTerminatorOrdinal += 1
                if sentenceTargets.contains(sentenceTerminatorOrdinal) {
                    shouldCapitalizeNextWord = true
                }
            } else if shouldCapitalizeNextWord,
                      !character.isWhitespace,
                      !isBoundaryWrapper(character),
                      !isOrphanSeparator(character) {
                shouldCapitalizeNextWord = false
            }
        }

        return result
    }

    private static func isSentenceTerminator(_ character: Character) -> Bool {
        character == "." || character == "!" || character == "?"
    }

    private static func isBoundaryWrapper(_ character: Character) -> Bool {
        "\"'“”‘’([{".contains(character)
    }

    private static func isOrphanSeparator(_ character: Character) -> Bool {
        ",.;:!?".contains(character)
    }
}

/// Tracks continuous silence during a live recording and reports when a
/// configured duration has been reached, for auto-stopping the recording.
/// Pure and clock-injected (no wall-clock reads inside) so it can be
/// driven deterministically by a test.
struct SilenceAutoStopTracker {
    static let liveSilenceLevelThreshold: Float = 0.02

    private var silenceStartedAt: TimeInterval?
    private var fired = false
    let thresholdSeconds: TimeInterval

    init(thresholdSeconds: TimeInterval) {
        self.thresholdSeconds = thresholdSeconds
    }

    /// Call once per level-timer tick. Returns true exactly once, on the
    /// tick where continuous silence first reaches `thresholdSeconds`;
    /// false on every other tick, including all subsequent silent ticks
    /// after firing once (call `reset()` when starting a new recording).
    mutating func update(level: Float, now: TimeInterval) -> Bool {
        guard !fired else { return false }
        if level >= Self.liveSilenceLevelThreshold {
            // Voice interrupts ongoing silence, but anchors the *next*
            // potential silence at this voiced tick, so the measured
            // duration matches how a user perceives "I stopped talking X
            // seconds ago" -- counted from the last voiced sample, not
            // from the first silent one after it.
            silenceStartedAt = now
            return false
        }
        let startedAt = silenceStartedAt ?? now
        silenceStartedAt = startedAt
        guard now - startedAt >= thresholdSeconds else { return false }
        fired = true
        return true
    }

    mutating func reset() {
        silenceStartedAt = nil
        fired = false
    }
}

