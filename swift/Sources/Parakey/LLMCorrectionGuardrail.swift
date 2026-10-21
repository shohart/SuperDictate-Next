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
//
// The corrector also DELETES fillers by design (its model card: "remove
// filler (эм/ну/типа/короче) ... preserve all meaning"), so «ну короче
// завтра…» → «Завтра…» is an edit, not a lost word. Both checks therefore
// also accept the output against the input with `modelRemovedFillers`
// taken out. The list and every guardrail case are shared with the Windows
// port through fixtures/llm-correction-guardrail.json.

enum LLMCorrectionGuardrail {

    /// Returns `output` trimmed, unless it fails the leading-word
    /// preservation check — in which case returns `input` unchanged.
    /// Log-only on rejection; never throws, never blocks.
    static func sanitizedCorrection(input: String, output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return input }
        // Compared with the model-removed fillers gone, but either form
        // counts: the model may also leave a filler in.
        let stripped = withoutModelRemovedFillers(input)
        let candidates = stripped.isEmpty ? [input] : [stripped, input]
        guard candidates.contains(where: { correctionPreservesLeadingWord(input: $0, output: trimmed) }) else {
            log("LLM postprocessing: guardrail rejected correction (leading word lost); keeping original text")
            return input
        }
        guard candidates.contains(where: { correctionPreservesWordCount(input: $0, output: trimmed) }) else {
            log("LLM postprocessing: guardrail rejected correction (word count \(normalizedWords(input).count) → \(normalizedWords(trimmed).count)); keeping original text")
            return input
        }
        return trimmed
    }

    /// Fillers the VoiceScribe corrector deletes by design — the model
    /// card's own list plus what a probe of the real model with this app's
    /// prompt dropped (fixtures/llm-correction-guardrail.json says which is
    /// which). Words the model keeps and that are often real words («вот»,
    /// «это», «просто», «слушай», «в общем»…) are deliberately absent.
    /// Same list as the Windows port's guardrail.MODEL_REMOVED_FILLERS.
    static let modelRemovedFillers: [String] = [
        "э", "ээ", "эм", "м", "мм", "ам", "аа",
        "ну", "типа", "короче", "короче говоря", "так сказать", "значит",
        "um", "uh", "ah", "er", "erm", "hm",
    ]

    /// `text` as the corrector is expected to leave it, filler-wise. Words
    /// with a preset use the preset's pattern («э+», «um+»), as the Windows
    /// port's remover does; the rest match literally.
    static func withoutModelRemovedFillers(_ text: String) -> String {
        let presets = FillerWordRemover.presets.filter { modelRemovedFillers.contains($0.displayText) }
        let presetWords = Set(presets.map(\.displayText))
        return FillerWordRemover.apply(to: text,
                                       enabledPresetKeys: Set(presets.map(\.key)),
                                       customWords: modelRemovedFillers.filter { !presetWords.contains($0) }).text
    }

    /// True when `output` has roughly as many words as `input`: within
    /// `max(2, 10 %)` either way. The correction prompt forbids adding or
    /// removing words, so a larger drift is never a legitimate edit — it is
    /// the model's long-input failure: silently dropping a tail or a middle
    /// (an observed 70 s dictation came back 825 → 663 chars), echoing a
    /// few-shot answer («Сочини рассказ про кота») or a fragment of its own
    /// input instead of the whole text. The floor of 2 words absorbs
    /// legitimate term merges («гит хаб» → «GitHub», «пул реквест» →
    /// «pull request») on short inputs.
    static func correctionPreservesWordCount(input: String, output: String) -> Bool {
        let inputCount = normalizedWords(input).count
        let outputCount = normalizedWords(output).count
        let tolerance = max(2, inputCount / 10)
        return abs(outputCount - inputCount) <= tolerance
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

    /// Splits a dictation into sentence-bounded pieces of at most
    /// `maxCharacters` each, for one correction request per piece. The
    /// corrector adapter was trained on short utterances; on long inputs it
    /// fails far more often (measured on a 4-minute dictation: 0 rejected
    /// pieces at 500 chars vs whole-text garbage at 1500), and a failed
    /// piece falls back to its own raw text instead of the whole
    /// dictation's. A single sentence longer than the limit is cut at the
    /// last space before it. Joining the pieces with " " restores the text
    /// up to whitespace runs.
    static func correctionChunks(_ text: String, maxCharacters: Int = 500) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else { return trimmed.isEmpty ? [] : [trimmed] }

        var sentences: [String] = []
        var sentence = ""
        var previous: Character?
        for character in trimmed {
            if character.isWhitespace, let previous, ".!?…".contains(previous) {
                sentences.append(sentence)
                sentence = ""
            } else if !(character.isWhitespace && sentence.isEmpty) {
                sentence.append(character)
            }
            previous = character
        }
        if !sentence.isEmpty { sentences.append(sentence) }

        var chunks: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { chunks.append(current) }
            current = ""
        }
        for var piece in sentences {
            while piece.count > maxCharacters {
                flush()
                let limit = piece.index(piece.startIndex, offsetBy: maxCharacters)
                let cut = piece[..<limit].lastIndex(where: { $0.isWhitespace }) ?? limit
                chunks.append(String(piece[..<cut]).trimmingCharacters(in: .whitespaces))
                piece = String(piece[cut...]).trimmingCharacters(in: .whitespaces)
            }
            if current.isEmpty {
                current = piece
            } else if current.count + 1 + piece.count <= maxCharacters {
                current += " " + piece
            } else {
                flush()
                current = piece
            }
        }
        flush()
        return chunks.filter { !$0.isEmpty }
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
