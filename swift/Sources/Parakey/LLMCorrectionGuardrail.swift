// SuperDictate — leading-word preservation guardrail for the LLM correction
// pass.
//

import Foundation

// MARK: - LLM correction output guardrail
//
// The bundled dictation-corrector model (see ModelDownload.swift's own
// model-selection history) is fast and excellent at foreign-term/script
// normalization, but has two empirically-observed failure modes inherited
// from its synthetic training data (V15):
//
//   1. Occasionally DROPS the input's leading word -- "я скачал модель..."
//      -> "Скачал модель...", "расскажи как дела" -> "Как дела". For a
//      dictation app this is the worst possible corruption: the user's own
//      words silently disappear.
//   2. Rarely hallucinates an unfamiliar term instead of normalizing it --
//      "кубернейтс" -> "Cerebral" (Kubernetes) was observed once.
//
// Both share one signature: the input's FIRST word does not survive into
// the output. This guardrail checks exactly that (with enough fuzziness to
// let legitimate term replacements through, e.g. "гитхаб" -> "GitHub") and
// falls back to the uncorrected input on failure, per this pipeline's
// never-lose-text policy (LLMPostprocessingPipeline). Everything here is
// deterministic and hermetic -- unit-tested in SelfTest without any model.

enum LLMCorrectionGuardrail {

    /// Returns `output` trimmed, unless it fails the leading-word
    /// preservation check — in which case returns `input` unchanged.
    /// Log-only on rejection; never throws, never blocks.
    static func sanitizedCorrection(input: String, output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return input }
        if correctionPreservesLeadingWord(input: input, output: trimmed) {
            return trimmed
        }
        log("LLM postprocessing: guardrail rejected correction (leading word lost); keeping original text")
        return input
    }

    /// True when the first significant word of `input` survives at the
    /// start of `output` — either verbatim, as a substring (word-splicing
    /// like "хаггинг фейс" -> "HuggingFace"), or as a fuzzy Latin↔Cyrillic
    /// transliteration match within `max(1, len/3)` edits (term
    /// replacement like "гитхаб" -> "GitHub" -> "гитхуб", distance 1).
    static func correctionPreservesLeadingWord(input: String, output: String) -> Bool {
        let inputWords = normalizedWords(input)
        guard let leading = inputWords.first else { return true }
        let outputWords = normalizedWords(output)

        // Single-character leading word ("я", "а", "и"): substring checks
        // are meaningless at this length (it would match inside unrelated
        // words), so require it as one of the first three standalone words.
        if leading.count <= 1 {
            return outputWords.prefix(3).contains(leading)
        }

        // Verbatim leading word ("залей" -> "Залей..."), possibly shifted
        // by one position.
        if outputWords.prefix(2).contains(leading) { return true }

        // Word-splice: the output's first words fused the input's leading
        // word with its SECOND word (ASR-adjacent words merged into one,
        // e.g. «хаггинг фейс» -> «хаггингфейс»). Strictly anchored: the
        // joined output prefix must START with the leading word and the
        // remainder must start with the input's second word (or be empty)
        // — a mere substring match would also admit hallucinated
        // EXTENSIONS of the leading word («золи» -> «Золить...», an
        // observed failure, see LLMPostprocessingPrompts.swift finding 6).
        if inputWords.count >= 2 {
            let joinedPrefix = outputWords.prefix(3).joined()
            if joinedPrefix.hasPrefix(leading) {
                let remainder = String(joinedPrefix.dropFirst(leading.count))
                if remainder.isEmpty || remainder.hasPrefix(inputWords[1]) {
                    return true
                }
            }
        }

        // Cross-script term replacement ONLY: fuzzily compare the leading
        // input word against each of the output's first two LATIN words,
        // after mapping them into an (approximate) Cyrillic form so the
        // edit distance is meaningful ("github" -> "гитхуб").
        //
        // Same-script (Cyrillic) candidates deliberately get NO fuzzy
        // matching: a 1-edit Cyrillic substitution is indistinguishable
        // from the model's hallucinated word forms («золей» -> «Золер»,
        // distance 1, is a real observed failure — see
        // LLMPostprocessingPrompts.swift finding 6), while legitimate
        // cross-script term fixes are exactly the Latin-word case. Cost
        // of this asymmetry: a legit single-letter Russian spelling fix
        // of the leading word falls back to the input — the safe side of
        // this pipeline's never-lose-text policy (the deterministic
        // vocabulary layer owns Russian-term learning anyway).
        let threshold = max(1, leading.count / 3)
        for candidate in outputWords.prefix(2) where !candidate.containsCyrillic {
            let cyrillicCandidate = Transliteration.approximateCyrillic(fromLatin: candidate)
            if editDistance(leading, cyrillicCandidate) <= threshold {
                return true
            }
        }
        return false
    }

    // MARK: - Internals

    /// Lowercased, ё→е, punctuation-stripped words (letters+digits runs).
    static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Classic Levenshtein distance over Character arrays.
    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs), b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}

private extension String {
    var containsCyrillic: Bool {
        // U+0410...U+044F: А-Я а-я (precomposed Cyrillic; normalizedWords
        // already lowercased and mapped ё away).
        unicodeScalars.contains { (0x0410...0x044F).contains($0.value) }
    }
}

/// Deliberately approximate Latin→Cyrillic mapping for FUZZY comparison
/// only (edit distance forgives the approximation; digraphs like "sh"/"ya"
/// are intentionally not special-cased). Never use for display.
private enum Transliteration {
    private static let latinToCyrillic: [Character: String] = [
        "a": "а", "b": "б", "c": "ц", "d": "д", "e": "е", "f": "ф",
        "g": "г", "h": "х", "i": "и", "j": "й", "k": "к", "l": "л",
        "m": "м", "n": "н", "o": "о", "p": "п", "q": "к", "r": "р",
        "s": "с", "t": "т", "u": "у", "v": "в", "w": "в", "x": "кс",
        "y": "й", "z": "з",
    ]

    static func approximateCyrillic(fromLatin word: String) -> String {
        word.lowercased().map { latinToCyrillic[$0] ?? String($0) }.joined()
    }
}
