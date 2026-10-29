// SuperDictate — export the vocabulary into PolterType's user wordlists
// (docs/specs/poltertype-bridge-spec.md, stage 0).
//
// PolterType (a keyboard layout switcher) merges
// `<config-dir>/wordlists/<stem>-extras.txt` into the dictionary of the
// layout `<stem>` (`ru_ru`, `en_us`, …). A word it knows is neither
// "corrected" into the other layout nor flagged by its spelling
// tooltip, and overlay words are offered as spelling suggestions.
// PolterType itself never writes `-extras.txt` — "Add to dictionary"
// appends to `<stem>.txt` — so SuperDictate owns these files outright,
// marked by MANAGED_HEADER on the first line. A file without that line
// is the user's own and is never touched.
//
// Only replacements are exported: a source is a misrecognition, the
// very spelling PolterType should keep treating as a mistake.

import Foundation

enum PolterTypeWordlistExport {
    static let managedMarker = "# Managed by SuperDictate Next"
    static let managedHeader = """
    \(managedMarker): regenerated from the SuperDictate vocabulary.
    # Edits here are overwritten. Add your own words to <layout>.txt instead.

    """

    /// Layout stems this exporter may write, in PolterType's file naming.
    static let stems = ["en_us", "ru_ru", "uk_ua"]

    struct Outcome: Equatable {
        /// Stems whose file now holds a different word list.
        var written: [String] = []
        /// Stems already up to date.
        var unchanged: [String] = []
        /// Stems whose `-extras.txt` exists without the managed header.
        var foreign: [String] = []
        /// Words per stem in the export, written or not.
        var counts: [String: Int] = [:]
    }

    /// `~/Library/Application Support/dev.opensource.poltertype/wordlists`,
    /// or nil when PolterType has never run for this user: the exporter
    /// does not create another application's configuration.
    static func defaultWordlistDirectory() -> URL? {
        let config = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.opensource.poltertype", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: config.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return config.appendingPathComponent("wordlists", isDirectory: true)
    }

    /// Words of every replacement, grouped by the layout that types them.
    /// Sorted and deduplicated case-insensitively (PolterType lowercases
    /// on load), keeping the first spelling met.
    static func wordsByStem(from records: [VocabularyRecord]) -> [String: [String]] {
        var seen: [String: Set<String>] = [:]
        var result: [String: [String]] = [:]
        for record in records {
            for word in words(in: record.replacement) {
                guard let stem = stem(for: word) else { continue }
                let key = word.lowercased()
                guard seen[stem, default: []].insert(key).inserted else { continue }
                result[stem, default: []].append(word)
            }
        }
        return result.mapValues { $0.sorted { $0.lowercased() < $1.lowercased() } }
    }

    /// Tokens of letters, with inner hyphens and apostrophes kept
    /// (`Нью-Йорк`, `O'Reilly`). A token touching a digit or an
    /// underscore (`37А`, `Alien_skaarj`) is not a dictionary word and is
    /// dropped whole rather than cut into fragments.
    static func words(in text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var poisoned = false
        func flush() {
            let trimmed = current.trimmingCharacters(in: CharacterSet(charactersIn: "-'’"))
            if !poisoned, trimmed.filter(\.isLetter).count >= 2 {
                tokens.append(trimmed)
            }
            current = ""
            poisoned = false
        }
        for character in text {
            if character.isLetter || "-'’".contains(character) {
                current.append(character)
            } else if character.isNumber || character == "_" {
                current.append(character)
                poisoned = true
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    /// The layout whose dictionary a word belongs to: Latin → `en_us`,
    /// Cyrillic → `ru_ru`, or `uk_ua` when it has a letter Russian lacks.
    /// Mixed scripts belong to neither.
    static func stem(for word: String) -> String? {
        let letters = word.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return nil }
        let isCyrillic = letters.allSatisfy { (0x0400...0x04FF).contains($0.value) }
        let isLatin = letters.allSatisfy { $0.value < 0x0250 }
        if isLatin { return "en_us" }
        guard isCyrillic else { return nil }
        let ukrainianOnly = Set("іїєґІЇЄҐ".unicodeScalars)
        return letters.contains(where: ukrainianOnly.contains) ? "uk_ua" : "ru_ru"
    }

    static func fileContents(words: [String]) -> String {
        managedHeader + words.map { $0 + "\n" }.joined()
    }

    /// Write one managed `-extras.txt` per stem that has words, and empty
    /// the managed files of stems that no longer do. Writes are atomic
    /// and skipped when the content is already current.
    static func export(records: [VocabularyRecord], to directory: URL) throws -> Outcome {
        let fileManager = FileManager.default
        let grouped = wordsByStem(from: records)
        var outcome = Outcome()
        var createdDirectory = false
        for stem in stems {
            let url = directory.appendingPathComponent("\(stem)-extras.txt", isDirectory: false)
            let words = grouped[stem] ?? []
            outcome.counts[stem] = words.count
            let existing = try? String(contentsOf: url, encoding: .utf8)
            if let existing, !existing.hasPrefix(managedMarker) {
                if !words.isEmpty { outcome.foreign.append(stem) }
                continue
            }
            if existing == nil, words.isEmpty { continue }
            let contents = fileContents(words: words)
            if existing == contents {
                outcome.unchanged.append(stem)
                continue
            }
            if !createdDirectory {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                createdDirectory = true
            }
            try Data(contents.utf8).write(to: url, options: .atomic)
            outcome.written.append(stem)
        }
        return outcome
    }
}

extension PolterTypeWordlistExport {
    /// One export into PolterType's own directory when the setting is on
    /// and PolterType exists. Failures are logged, never surfaced: this
    /// is a convenience for another application.
    static func exportIfEnabled(settings: Settings, trigger: String) {
        guard settings.polterTypeWordlistExportEnabled,
              let directory = defaultWordlistDirectory() else { return }
        do {
            let outcome = try export(records: settings.vocabularyStore.all(), to: directory)
            if !outcome.written.isEmpty || !outcome.foreign.isEmpty {
                log("poltertype export (\(trigger)): written \(outcome.written), foreign \(outcome.foreign)")
            }
        } catch {
            log("poltertype export (\(trigger)) failed: \(error)")
        }
    }
}

/// Agent side: export at launch and after every vocabulary change — a
/// local edit in either process, learning, or a sync pass all post
/// VOCABULARY_CHANGED_NOTIFICATION, the agent's own posts included.
@MainActor
final class PolterTypeWordlistSync {
    private let settings: Settings
    private var pending: Task<Void, Never>?
    private var started = false

    init(settings: Settings) {
        self.settings = settings
    }

    func start() {
        guard !started else { return }
        started = true
        DistributedNotificationCenter.default().addObserver(
            forName: VOCABULARY_CHANGED_NOTIFICATION, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        }
        PolterTypeWordlistExport.exportIfEnabled(settings: settings, trigger: "launch")
    }

    /// Coalesced: an import or a sync pass changes many rows at once.
    private func schedule() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            PolterTypeWordlistExport.exportIfEnabled(settings: self.settings, trigger: "vocabulary change")
        }
    }
}
