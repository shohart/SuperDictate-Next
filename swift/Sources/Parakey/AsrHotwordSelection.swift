// SuperDictate — which vocabulary entries become ASR hotwords
// (docs/specs/asr-hotwords-spec.md §6). Pure functions only: the store
// (VocabularyStore.asrHotwordPhrases), the vocabulary manager's "ASR hint"
// column and the `asr-hotwords` self-test all go through this one rule.

import Foundation

/// The two weights offered in the settings (spec §3: 2.0 is the measured
/// sweet spot, 3.0 fixes more terms at a small regression risk).
enum AsrHotwordsStrength: String, CaseIterable {
    case normal
    case strong

    var score: Double {
        switch self {
        case .normal: return 2.0
        case .strong: return 3.0
        }
    }
}

/// What `TranscriptionWorker` hands the ONNX engine for one dictation. An
/// empty `phrases` list means the unbiased path (spec §7).
struct AsrHotwordsConfiguration: Equatable, Sendable {
    let phrases: [String]
    let score: Double

    static let disabled = AsrHotwordsConfiguration(phrases: [], score: AsrHotwordsStrength.normal.score)
}

enum AsrHotwordSelection {
    static let maxPhrases = 1000
    static let maxWords = 4
    static let minCharacters = 2

    /// Trimmed from both ends of a replacement (spec §6), together with
    /// whitespace.
    static let edgeCharacters = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: ".,!?;:—–-«»\"'"))

    /// The replacement as a candidate phrase: edges trimmed, inner text kept
    /// exactly as written (case variants hurt — spec §3).
    static func phrase(fromReplacement replacement: String) -> String {
        replacement.trimmingCharacters(in: edgeCharacters)
    }

    /// The phrase for an entry, or nil when the entry can never be a hotword
    /// (too short, no letter, too many words, punctuation-only edit). An
    /// explicit hint does not override these.
    static func eligiblePhrase(source: String, replacement: String) -> String? {
        let phrase = phrase(fromReplacement: replacement)
        guard phrase.count >= minCharacters,
              phrase.contains(where: { $0.isLetter }) else { return nil }
        let words = phrase.split(whereSeparator: { $0.isWhitespace })
        guard words.count <= maxWords else { return nil }
        guard comparisonKey(phrase) != comparisonKey(source) else { return nil }
        return phrase
    }

    /// "Term-like" (spec §6): a Latin letter or a digit, or at least two
    /// uppercase letters (ЕГРЮЛ, DDR4, TickTick).
    static func isTermLike(_ phrase: String) -> Bool {
        var uppercase = 0
        for scalar in phrase.unicodeScalars {
            if isLatinLetter(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                return true
            }
            if scalar.properties.isUppercase {
                uppercase += 1
                if uppercase >= 2 { return true }
            }
        }
        return false
    }

    /// The automatic decision for an eligible phrase (`asr_hint` NULL).
    static func automaticDecision(phrase: String, origin: VocabularyOrigin) -> Bool {
        switch origin {
        case .manual: return true
        case .learned: return isTermLike(phrase)
        }
    }

    /// Whether the entry is boosted: skip rules first, then the explicit
    /// hint, then the automatic rule.
    static func isEffective(source: String, replacement: String,
                            origin: VocabularyOrigin, hint: Bool?) -> Bool {
        guard let phrase = eligiblePhrase(source: source, replacement: replacement) else { return false }
        return hint ?? automaticDecision(phrase: phrase, origin: origin)
    }

    static func isEffective(_ record: VocabularyRecord) -> Bool {
        isEffective(source: record.source, replacement: record.replacement,
                    origin: record.origin, hint: record.asrHint)
    }

    /// The hotword list for `records`, in their order: exact duplicates
    /// merged, at most `maxPhrases`.
    static func phrases(from records: [VocabularyRecord]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for record in records {
            guard let phrase = eligiblePhrase(source: record.source, replacement: record.replacement),
                  record.asrHint ?? automaticDecision(phrase: phrase, origin: record.origin),
                  seen.insert(phrase).inserted else { continue }
            result.append(phrase)
            if result.count == maxPhrases { break }
        }
        return result
    }

    /// Case, punctuation and whitespace removed: two strings with the same
    /// key differ only by a punctuation/case edit.
    static func comparisonKey(_ text: String) -> String {
        let ignored = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        var scalars = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars where !ignored.contains(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    private static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.properties.isAlphabetic else { return false }
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A: return true          // ASCII
        case 0xC0...0x24F: return scalar.value != 0xD7 && scalar.value != 0xF7  // Latin-1 / Extended-A/B
        case 0x1E00...0x1EFF: return true                     // Latin Extended Additional
        default: return false
        }
    }
}
