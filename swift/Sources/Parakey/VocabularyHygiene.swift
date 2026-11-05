// SuperDictate — learn-time vocabulary hygiene and dictionary cleanup
// (docs/specs/vocabulary-hygiene-and-sync-spec.md §2–§3). Pure functions
// only: PostInsertionEditWatcher (before the pending toast), the store
// (VocabularyStore.commitLearned / cleanupPlan, inside its transaction),
// the vocabulary window's manual editor and the `vocabulary-hygiene`
// self-test all go through these rules. The Windows app implements the
// same rules in `vocabulary_hygiene.py`; keep the two in step.

import Foundation

enum VocabularyHygiene {
    enum RejectReason: String, Equatable, Sendable {
        case punctuation
        case noLetters = "no-letters"
        case inflection
        case rewrite
    }

    /// Another entry whose replacement the accepted candidate changes
    /// (rule 7, chain collapse).
    struct Rewrite: Equatable, Sendable {
        let id: Int64
        let replacement: String
    }

    enum Verdict: Equatable, Sendable {
        /// Store `source → replacement` (possibly trimmed, chain-resolved
        /// or case-unified) and apply `rewrites` to existing entries.
        case accept(source: String, replacement: String, rewrites: [Rewrite])
        case reject(RejectReason)
        /// The candidate reverts entry `existingId`: delete it, store nothing.
        case undo(existingId: Int64)
    }

    /// Rule 1's edge set, together with whitespace.
    static let edgeCharacters = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: ".,!?;:…—–-«»\"'()"))

    /// The learn-time review (spec §2, rules 1–8).
    ///
    /// Deviation from the spec's listed order: the undo check (rule 6)
    /// runs right after trimming (rule 1), before the rejection rules.
    /// Reverting a garbage entry such as «Запомню → Запомни» produces the
    /// candidate «Запомни → Запомню», which rule 4 would otherwise reject
    /// before the undo could delete the bad entry.
    static func review(source: String, replacement: String, existing: [VocabularyRecord]) -> Verdict {
        let source = trimEdges(source)
        var replacement = trimEdges(replacement)

        // Rule 6: undo.
        let sourceKey = key(source)
        let replacementKey = key(replacement)
        if let reverted = existing.first(where: {
            key($0.source) == replacementKey && key($0.replacement) == sourceKey
        }) {
            return .undo(existingId: reverted.id)
        }

        if let reason = rejection(source: source, replacement: replacement) {
            return .reject(reason)
        }

        // Rule 7a: `replacement → Z` exists → store `source → Z`.
        var visited: Set<String> = [sourceKey]
        var currentKey = key(replacement)
        while !visited.contains(currentKey),
              let next = existing.first(where: { key($0.source) == currentKey }) {
            visited.insert(currentKey)
            let target = trimEdges(next.replacement)
            let targetKey = key(target)
            // A chain that leads back to the new source would store an
            // identity mapping; keep the candidate's own replacement.
            guard targetKey != sourceKey, !target.isEmpty else { break }
            replacement = target
            currentKey = targetKey
        }

        // Rule 8: case unification against the other entries' replacements.
        // A case fix of the source itself («Github → GitHub») is the user
        // choosing the casing, so it is kept as typed.
        if source.lowercased() != replacement.lowercased() {
            replacement = unifiedCase(of: replacement, among: existing.filter { key($0.source) != sourceKey })
        }

        // Rule 7b: entries `X → source` now point at the final replacement.
        let rewrites = existing
            .filter { key($0.replacement) == sourceKey && key($0.source) != sourceKey }
            .map { Rewrite(id: $0.id, replacement: replacement) }

        return .accept(source: source, replacement: replacement, rewrites: rewrites)
    }

    /// The manual editor applies only rules 1 and 3 (spec §2: the user is
    /// explicit there). Returns the trimmed pair, or nil when the
    /// replacement (or source) is empty or has no letter after trimming.
    static func reviewManual(source: String, replacement: String) -> (source: String, replacement: String)? {
        let source = trimEdges(source)
        let replacement = trimEdges(replacement)
        guard !source.isEmpty, !isJunkReplacement(replacement) else { return nil }
        return (source, replacement)
    }

    /// Rules 2–5 on an already trimmed pair; nil = no objection.
    static func rejection(source: String, replacement: String) -> RejectReason? {
        // Rule 2: punctuation-, whitespace- or case-only edit of an
        // ordinary word.
        if AsrHotwordSelection.comparisonKey(source) == AsrHotwordSelection.comparisonKey(replacement),
           !AsrHotwordSelection.isTermLike(replacement) {
            return .punctuation
        }
        // Rule 3: junk replacement (an empty source is junk too).
        if source.isEmpty || isJunkReplacement(replacement) {
            return .noLetters
        }
        // Rule 4: Russian inflection edit.
        if isInflectionEdit(source: source, replacement: replacement) {
            return .inflection
        }
        // Rule 5: content rewrite.
        if !isExemptAcronym(replacement),
           similarity(transliterated(source), transliterated(replacement)) < 0.3 {
            return .rewrite
        }
        return nil
    }

    // MARK: - Rule helpers

    static func trimEdges(_ text: String) -> String {
        text.trimmingCharacters(in: edgeCharacters)
    }

    /// Rule 7's comparison form: casefolded, whitespace collapsed, edge
    /// punctuation trimmed.
    static func key(_ text: String) -> String {
        normalizedTranscriptCorrectionSource(trimEdges(text))
    }

    static func isJunkReplacement(_ replacement: String) -> Bool {
        replacement.count < 2 || !replacement.contains(where: { $0.isLetter })
    }

    /// Rule 4. One word: the loose prefix test, which also catches
    /// ordinary-word typos («сторониной → стороной»). Several words: every
    /// changed word is another grammatical form by its ending
    /// («финансовая управляющая → финансового управляющего»); the right case
    /// belongs to one sentence, so it is never a rule for the next one. A
    /// spelling fix in a phrase stays learnable («Бюллеттени Нилова →
    /// Бюллетени Нилова»).
    static func isInflectionEdit(source: String, replacement: String) -> Bool {
        let lhs = source.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let rhs = replacement.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !lhs.isEmpty, lhs.count == rhs.count else { return false }
        if lhs.count == 1 {
            return lhs != rhs && isInflectedByHyphenPart(lhs[0], rhs[0], test: isLooselyInflected)
        }
        var inflected = false
        for (old, new) in zip(lhs, rhs) where old != new {
            guard isSameWordInflected(old, new) else { return false }
            inflected = true
        }
        return inflected
    }

    /// The strict word test: same stem, both tails are grammatical endings.
    /// Also what the watcher's diff uses to drop re-inflected neighbours of
    /// a real fix.
    static func isSameWordInflected(_ old: String, _ new: String) -> Bool {
        isInflectedByHyphenPart(old, new, test: isInflectedByEnding)
    }

    /// Edge punctuation ignored, hyphenated parts compared one by one
    /// («Санкт-Петербурга → Санкт-Петербургу»).
    private static func isInflectedByHyphenPart(_ old: String, _ new: String,
                                                test: (String, String) -> Bool) -> Bool {
        let lhs = trimEdges(old).components(separatedBy: "-")
        let rhs = trimEdges(new).components(separatedBy: "-")
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { $0 == $1 || test($0, $1) }
    }

    private static func isInflectionComparable(_ source: String, _ replacement: String) -> Bool {
        guard isSingleCyrillicWord(source), isSingleCyrillicWord(replacement) else { return false }
        return replacement.unicodeScalars.filter { $0.properties.isUppercase }.count < 2
    }

    private static func isLooselyInflected(_ source: String, _ replacement: String) -> Bool {
        guard isInflectionComparable(source, replacement) else { return false }
        let lhs = inflectionFolded(source)
        let rhs = inflectionFolded(replacement)
        var prefix = 0
        while prefix < lhs.count, prefix < rhs.count, lhs[prefix] == rhs[prefix] {
            prefix += 1
        }
        let shorter = Double(min(lhs.count, rhs.count))
        if prefix >= 3, Double(prefix) >= 0.6 * shorter, lhs.count - prefix <= 4, rhs.count - prefix <= 4 {
            return true
        }
        // Short stems the prefix test cannot see: «бой → боя», «день → дня».
        return isInflectedByEnding(source, replacement)
    }

    private static func isInflectedByEnding(_ source: String, _ replacement: String) -> Bool {
        guard isInflectionComparable(source, replacement) else { return false }
        let lhs = inflectionFolded(source)
        let rhs = inflectionFolded(replacement)
        guard lhs.count >= 3, rhs.count >= 3 else { return false }
        return endingsMatch(lhs, rhs)
    }

    private static func inflectionFolded(_ word: String) -> [Character] {
        word.lowercased().map { $0 == "ё" ? "е" : $0 }
    }

    /// Noun and adjective endings.
    private static let caseEndings: Set<String> = [
        "", "а", "я", "о", "е", "и", "ы", "у", "ю", "й", "ь",
        "ом", "ем", "ой", "ей", "ов", "ев", "ам", "ям", "ах", "ях", "ами", "ями",
        "ие", "ия", "ию", "ии", "их", "им", "ым", "ых", "ая", "ое", "ую", "ые", "ый", "ий",
        "ью", "ья", "ье", "ьи",
        "яя", "ее", "юю", "ого", "его", "ому", "ему", "ыми", "ими", "ени", "ери",
    ]
    /// Verb endings count only with a stem of three letters or more:
    /// «сделал → сделала», «делает → делают».
    private static let verbEndings: Set<String> = [
        "л", "ла", "ло", "ли", "ть", "ет", "ют", "ит", "ят", "ут", "ат",
        "ешь", "ишь", "ете", "ите",
    ]
    /// Endings of the form that lost its fleeting vowel. No «о»: it would
    /// turn «кто» into a form of «кот».
    private static let fleetingLostEndings: Set<String> = [
        "а", "я", "у", "ю", "е", "и", "ы", "ом", "ем", "ов", "ев", "ей",
        "ам", "ям", "ах", "ях", "ами", "ями",
    ]

    private static func endingsMatch(_ lhs: [Character], _ rhs: [Character]) -> Bool {
        func splits(_ word: [Character]) -> [(stem: [Character], ending: String)] {
            (0...min(3, word.count - 2)).compactMap { length in
                let ending = String(word.suffix(length))
                let stem = Array(word.dropLast(length))
                let known = caseEndings.contains(ending) || (stem.count >= 3 && verbEndings.contains(ending))
                return known ? (stem, ending) : nil
            }
        }
        let left = splits(lhs), right = splits(rhs)
        for l in left {
            for r in right {
                if l.stem == r.stem { return true }
                if hasFleetingVowel(l.stem, l.ending, lost: r.stem, r.ending)
                    || hasFleetingVowel(r.stem, r.ending, lost: l.stem, l.ending) { return true }
            }
        }
        return false
    }

    /// «отец/отца», «день/дня», «лев/льва»: the vowel before the last stem
    /// consonant exists only with a zero ending (or «ь»).
    private static func hasFleetingVowel(_ full: [Character], _ fullEnding: String,
                                         lost: [Character], _ lostEnding: String) -> Bool {
        guard fullEnding.isEmpty || fullEnding == "ь", fleetingLostEndings.contains(lostEnding),
              full.count >= 3, full.last == lost.last,
              full.prefix(full.count - 2).elementsEqual(lost.prefix(full.count - 2)) else { return false }
        let vowel = full[full.count - 2]
        if lost.count == full.count - 1 { return vowel == "о" || vowel == "е" }
        if lost.count == full.count {
            let soft = lost[lost.count - 2]
            return vowel == "е" && (soft == "ь" || soft == "й")
        }
        return false
    }

    private static func isSingleCyrillicWord(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            scalar.properties.isAlphabetic && (0x0400...0x04FF).contains(scalar.value)
        }
    }

    /// «Эмсипи → MCP», «Эс эйч → ssh»: Latin capitals (digits and hyphens
    /// allowed), or a short lowercase Latin acronym.
    static func isExemptAcronym(_ replacement: String) -> Bool {
        let scalars = replacement.unicodeScalars
        let capitals = scalars.count >= 2
            && scalars.contains { (0x41...0x5A).contains($0.value) }
            && scalars.allSatisfy { (0x41...0x5A).contains($0.value) || (0x30...0x39).contains($0.value) || $0 == "-" }
        let lowercase = (2...5).contains(scalars.count)
            && scalars.allSatisfy { (0x61...0x7A).contains($0.value) }
        return capitals || lowercase
    }

    private static let cyrillicToLatin: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e",
        "ж": "zh", "з": "z", "и": "i", "й": "y", "к": "k", "л": "l", "м": "m",
        "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
        "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "sch",
        "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
    ]

    /// Lowercase letters and digits only, Cyrillic mapped to Latin.
    static func transliterated(_ text: String) -> String {
        var result = ""
        for character in text.lowercased() where character.isLetter || character.isNumber {
            result += cyrillicToLatin[character] ?? String(character)
        }
        return result
    }

    /// `1 - levenshtein / max(len)`; two empty strings are identical.
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let a = Array(lhs), b = Array(rhs)
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 1 }
        return 1 - Double(levenshtein(a, b)) / Double(longest)
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var current = [i + 1]
            current.reserveCapacity(b.count + 1)
            for (j, cb) in b.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (ca == cb ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }

    /// Rule 8: when another entry's replacement equals `replacement` up to
    /// case, the casing of a manual entry wins, otherwise the casing of the
    /// most recently updated entry.
    static func unifiedCase(of replacement: String, among entries: [VocabularyRecord]) -> String {
        let folded = replacement.lowercased()
        let matches = entries.filter { trimEdges($0.replacement).lowercased() == folded }
        guard matches.contains(where: { trimEdges($0.replacement) != replacement }) else { return replacement }
        let manual = matches.filter { $0.origin == .manual }
        let pool = manual.isEmpty ? matches : manual
        guard let winner = pool.max(by: { $0.updatedAt < $1.updatedAt }) else { return replacement }
        return trimEdges(winner.replacement)
    }

    // MARK: - Cleanup (§3)

    enum CleanupDeletionReason: Equatable, Sendable {
        case rejected(RejectReason)
        /// After trimming, the entry's source collides with entry `keptId`.
        case duplicate(keptId: Int64)
    }

    struct CleanupDeletion: Equatable, Sendable {
        let record: VocabularyRecord
        let reason: CleanupDeletionReason
    }

    enum CleanupRewriteKind: String, Equatable, Sendable, CaseIterable {
        case trimmed
        case chain
        case caseUnified = "case"
    }

    struct CleanupRewrite: Equatable, Sendable {
        let record: VocabularyRecord
        let source: String
        let replacement: String
        let kinds: [CleanupRewriteKind]
    }

    struct CleanupMerge: Equatable, Sendable {
        let keptId: Int64
        let keptSource: String
        let removed: [VocabularyRecord]
    }

    struct CleanupPlan: Equatable, Sendable {
        var deletions: [CleanupDeletion] = []
        var rewrites: [CleanupRewrite] = []
        var merges: [CleanupMerge] = []

        var isEmpty: Bool { deletions.isEmpty && rewrites.isEmpty }
    }

    /// Rules 1–5 and 7–8 over the learned entries of `records`; manual
    /// entries are never touched (they only serve as chain targets, case
    /// references and duplicate keepers).
    static func cleanupPlan(for records: [VocabularyRecord]) -> CleanupPlan {
        var plan = CleanupPlan()
        let manual = records.filter { $0.origin == .manual }

        // Rules 1–5.
        struct Candidate {
            let record: VocabularyRecord
            var source: String
            var replacement: String
            var kinds: [CleanupRewriteKind]
        }
        var survivors: [Candidate] = []
        for record in records where record.origin == .learned {
            let source = trimEdges(record.source)
            let replacement = trimEdges(record.replacement)
            if let reason = rejection(source: source, replacement: replacement) {
                plan.deletions.append(CleanupDeletion(record: record, reason: .rejected(reason)))
                continue
            }
            let trimmed = source != record.source || replacement != record.replacement
            survivors.append(Candidate(record: record, source: source, replacement: replacement,
                                       kinds: trimmed ? [.trimmed] : []))
        }

        // Duplicates after trimming: a manual entry keeps its key; among
        // learned entries the most recently updated one survives.
        let manualByKey = Dictionary(manual.map { (key($0.source), $0) }, uniquingKeysWith: { first, _ in first })
        var groups: [String: [Int]] = [:]
        var groupOrder: [String] = []
        for (index, candidate) in survivors.enumerated() {
            let candidateKey = key(candidate.source)
            if groups[candidateKey] == nil { groupOrder.append(candidateKey) }
            groups[candidateKey, default: []].append(index)
        }
        var dropped = Set<Int>()
        for groupKey in groupOrder {
            let indices = groups[groupKey] ?? []
            let keeper: (id: Int64, source: String)
            let losers: [Int]
            if let manualEntry = manualByKey[groupKey] {
                keeper = (manualEntry.id, manualEntry.source)
                losers = indices
            } else {
                guard indices.count > 1,
                      let best = indices.max(by: { survivors[$0].record.updatedAt < survivors[$1].record.updatedAt })
                else { continue }
                keeper = (survivors[best].record.id, survivors[best].source)
                losers = indices.filter { $0 != best }
            }
            guard !losers.isEmpty else { continue }
            for loser in losers {
                dropped.insert(loser)
                plan.deletions.append(CleanupDeletion(record: survivors[loser].record,
                                                      reason: .duplicate(keptId: keeper.id)))
            }
            plan.merges.append(CleanupMerge(keptId: keeper.id, keptSource: keeper.source,
                                            removed: losers.map { survivors[$0].record }))
        }
        survivors = survivors.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)

        // Rule 7: chains over manual + surviving learned entries.
        var targetByKey: [String: String] = [:]
        for entry in manual { targetByKey[key(entry.source)] = trimEdges(entry.replacement) }
        for candidate in survivors { targetByKey[key(candidate.source)] = candidate.replacement }
        for index in survivors.indices {
            let ownKey = key(survivors[index].source)
            var visited: Set<String> = [ownKey]
            var current = survivors[index].replacement
            while true {
                let currentKey = key(current)
                guard !visited.contains(currentKey), let next = targetByKey[currentKey] else { break }
                visited.insert(currentKey)
                guard key(next) != ownKey, !next.isEmpty else { break }
                current = next
            }
            if current != survivors[index].replacement {
                survivors[index].replacement = current
                survivors[index].kinds.append(.chain)
            }
        }

        // Rule 8: one casing per replacement, manual first, then the most
        // recently updated entry.
        var references = manual.map { VocabularyRecord(id: $0.id, source: $0.source, replacement: trimEdges($0.replacement),
                                                       origin: .manual, createdAt: $0.createdAt, updatedAt: $0.updatedAt) }
        // Case fixes («Github → GitHub») are the user's explicit casing:
        // they neither vote nor change.
        let isCaseFix = { (survivor: (source: String, replacement: String)) in
            survivor.source.lowercased() == survivor.replacement.lowercased()
        }
        references += survivors.filter { !isCaseFix(($0.source, $0.replacement)) }.map {
            VocabularyRecord(id: $0.record.id, source: $0.source, replacement: $0.replacement,
                             origin: .learned, createdAt: $0.record.createdAt, updatedAt: $0.record.updatedAt)
        }
        for index in survivors.indices where !isCaseFix((survivors[index].source, survivors[index].replacement)) {
            let unified = unifiedCase(of: survivors[index].replacement, among: references)
            if unified != survivors[index].replacement {
                survivors[index].replacement = unified
                survivors[index].kinds.append(.caseUnified)
            }
        }

        for candidate in survivors
        where candidate.source != candidate.record.source || candidate.replacement != candidate.record.replacement {
            plan.rewrites.append(CleanupRewrite(record: candidate.record, source: candidate.source,
                                                replacement: candidate.replacement, kinds: candidate.kinds))
        }
        return plan
    }
}
