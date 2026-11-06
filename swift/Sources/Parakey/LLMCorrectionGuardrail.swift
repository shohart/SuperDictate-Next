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

    // MARK: - Word-level faithfulness
    //
    // The corrector sometimes swaps a word it does not know for a real term
    // that merely sounds similar: «хотвордов» -> «Hotjar», «хотворды» ->
    // «HuggingFace». The output still has the right length and first word, so
    // the whole-text checks let it pass. Each changed word is therefore
    // compared with the word it replaced, and an unfaithful one goes back to
    // what recognition wrote; the rest of the correction stays. Same rules as
    // the Windows port; the "word_guard" section of
    // fixtures/llm-correction-guardrail.json holds the shared verdicts.

    static let minClosenessToLatin = 0.5
    static let minClosenessSameScript = 0.4
    private static let allCapsTermMinLetters = 6
    private static let numeralStems = [
        "ноль", "нул", "один", "одн", "перв", "два", "две", "двух", "двум", "втор", "три", "трех", "трём",
        "трем", "трет", "четыр", "четвер", "пят", "шест", "сем", "седьм", "восем", "восьм", "девя", "десят",
        "двадцат", "тридцат", "сорок", "пятьдесят", "шестьдесят", "семьдесят", "восемьдесят", "девяност",
        "сто", "ста", "двест", "двести", "триста", "четырест", "пятьсот", "шестьсот", "семьсот", "восемьсот",
        "девятьсот", "тысяч", "миллион", "миллиард", "полтор", "точка", "запятая",
    ]

    private static func wordCore(_ token: String) -> (lead: String, core: String, trail: String) {
        let characters = Array(token)
        var start = 0, end = characters.count
        while start < end, !(characters[start].isLetter || characters[start].isNumber) { start += 1 }
        while end > start, !(characters[end - 1].isLetter || characters[end - 1].isNumber) { end -= 1 }
        return (String(characters[..<start]), String(characters[start..<end]), String(characters[end...]))
    }

    private static func fold(_ word: String) -> String {
        word.lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    private static func soundKey(_ text: String) -> String {
        var key = VocabularyHygiene.transliterated(text)
        for (old, new) in [("kh", "h"), ("ck", "k"), ("ph", "f"), ("c", "k"), ("q", "k"), ("w", "v"),
                           ("x", "ks"), ("y", "i"), ("j", "zh")] {
            key = key.replacingOccurrences(of: old, with: new)
        }
        var collapsed = ""
        for character in key where collapsed.last != character { collapsed.append(character) }
        return collapsed
    }

    private static func closeness(_ old: String, _ new: String) -> Double {
        let a = soundKey(old), b = soundKey(new)
        let longest = max(a.count, b.count)
        return longest == 0 ? 1 : 1 - Double(editDistance(a, b)) / Double(longest)
    }

    private static func isLatin(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value) }
    }

    /// `old` and `new` are word cores, possibly several joined by spaces.
    private static func isFaithful(old: String, new: String) -> Bool {
        guard new.contains(where: { $0.isLetter || $0.isNumber }) else { return true }
        if new.contains(where: \.isNumber), !old.contains(where: \.isNumber) {
            return old.split(separator: " ").allSatisfy { word in
                numeralStems.contains { fold(String(word)).hasPrefix($0) }
            }
        }
        if isLatin(new), !isLatin(old) {
            let letters = new.filter(\.isLetter)
            if letters.count >= allCapsTermMinLetters, letters.allSatisfy(\.isUppercase) {
                return false  // «ARBITRAJNSKII»: a Russian word spelled in Latin capitals
            }
            return closeness(old, new) >= minClosenessToLatin
        }
        return closeness(old, new) >= minClosenessSameScript
    }

    /// The proper words of the user's vocabulary, which the corrector must
    /// not change: anything capitalized or Latin, of at least three letters.
    static func protectedWords(from phrases: [String]) -> Set<String> {
        var words = Set<String>()
        for phrase in phrases {
            for token in phrase.split(whereSeparator: { $0.isWhitespace }) {
                let core = wordCore(String(token)).core
                if core.count >= 3, core.first?.isUppercase == true || isLatin(core) {
                    words.insert(fold(core))
                }
            }
        }
        return words
    }

    /// Longest common subsequence; what lies between its matches.
    private static func alignedGaps(_ left: [String], _ right: [String]) -> [(oldRange: Range<Int>, newRange: Range<Int>)] {
        let rows = left.count, cols = right.count
        var table = [[Int]](repeating: [Int](repeating: 0, count: cols + 1), count: rows + 1)
        for i in stride(from: rows - 1, through: 0, by: -1) {
            for j in stride(from: cols - 1, through: 0, by: -1) {
                table[i][j] = left[i] == right[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var gaps: [(oldRange: Range<Int>, newRange: Range<Int>)] = []
        var i = 0, j = 0, gapI = 0, gapJ = 0
        while i < rows, j < cols {
            if left[i] == right[j] {
                if gapI < i || gapJ < j { gaps.append((gapI..<i, gapJ..<j)) }
                i += 1
                j += 1
                gapI = i
                gapJ = j
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        if gapI < rows || gapJ < cols { gaps.append((gapI..<rows, gapJ..<cols)) }
        return gaps
    }

    /// `output` with every unfaithful word put back as in `input`.
    static func faithfulWords(input: String, output: String, protected: Set<String> = []) -> String {
        let oldTokens = input.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let newTokens = output.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let oldCores = oldTokens.map { fold(wordCore($0).core) }
        let newCores = newTokens.map { fold(wordCore($0).core) }
        var edits: [(range: Range<Int>, tokens: [String])] = []
        for gap in alignedGaps(oldCores, newCores) {
            let olds = Array(oldTokens[gap.oldRange])
            let news = Array(newTokens[gap.newRange])
            let guarded = gap.oldRange.contains { protected.contains(oldCores[$0]) }
            if olds.isEmpty { continue }
            if news.isEmpty {
                if guarded { edits.append((gap.newRange, olds)) }
                continue
            }
            if olds.count == news.count {
                for offset in olds.indices {
                    let oldCore = wordCore(olds[offset]).core
                    let new = wordCore(news[offset])
                    if protected.contains(fold(oldCore)) || !isFaithful(old: oldCore, new: new.core) {
                        let at = gap.newRange.lowerBound + offset
                        var restored = oldCore
                        if at == 0, new.core.first?.isUppercase == true, restored.first?.isLowercase == true {
                            restored = restored.prefix(1).uppercased() + restored.dropFirst()
                        }
                        edits.append((at..<(at + 1), [new.lead + restored + new.trail]))
                    }
                }
                continue
            }
            let joinedOld = olds.map { wordCore($0).core }.joined(separator: " ")
            let joinedNew = news.map { wordCore($0).core }.joined(separator: " ")
            if guarded || !isFaithful(old: joinedOld, new: joinedNew) {
                edits.append((gap.newRange, olds))
            }
        }
        guard !edits.isEmpty else { return output }
        var result = newTokens
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            log("LLM postprocessing: guardrail restored \(edit.range.count) word(s) the corrector replaced")
            result.replaceSubrange(edit.range, with: edit.tokens)
        }
        return result.joined(separator: " ")
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
