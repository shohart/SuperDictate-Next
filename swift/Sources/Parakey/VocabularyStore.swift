// SuperDictate — local SQLite store for text corrections (manual and
// auto-learned). Single source of truth for TranscriptCorrection pairs;
// Settings.transcriptCorrections bridges to this store (see Settings.swift)
// so every existing consumer of that property keeps working unchanged.

import Foundation
import SQLite3

enum VocabularyOrigin: String {
    case manual
    case learned
}

struct VocabularyRecord: Equatable {
    let id: Int64
    let source: String
    let replacement: String
    let origin: VocabularyOrigin
    let createdAt: String
    let updatedAt: String
}

enum VocabularyStoreError: Error, LocalizedError {
    case openFailed(String)
    case sqlError(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message): return "Could not open the vocabulary database: \(message)"
        case .sqlError(let message): return "Vocabulary database error: \(message)"
        }
    }
}

/// Not @MainActor: called from both UI code (main actor) and the
/// background transcription pipeline (TranscriptCorrector.apply, called
/// off-main during processing). SQLite connections are not thread-safe
/// for concurrent use from multiple threads by default, so every call
/// is funneled through a private serial queue.
final class VocabularyStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.local.superdictate.vocabulary-store")

    convenience init(fileURL: URL) throws {
        try self.init(sqlitePath: fileURL.path)
    }

    /// Last-resort constructor for the (expected-never) case where even
    /// FileManager.default.temporaryDirectory isn't writable. SQLite's
    /// special ":memory:" filename opens a private in-memory database
    /// instead of touching disk at all, so this cannot fail the way
    /// init(fileURL:) can.
    static func inMemoryFallback() -> VocabularyStore {
        // Force-unwrap is safe: ":memory:" always succeeds in SQLite,
        // and createSchema() against a fresh in-memory DB cannot fail.
        try! VocabularyStore(sqlitePath: ":memory:")
    }

    /// Designated initializer, keyed off a raw SQLite path/filename
    /// string rather than a URL. SQLite's special ":memory:" sentinel
    /// must reach sqlite3_open_v2 verbatim — round-tripping it through
    /// URL(fileURLWithPath:) resolves it against the current working
    /// directory (e.g. "/Users/me/:memory:"), which would silently turn
    /// "in-memory" into "write a file literally named :memory: to disk".
    /// Going through a plain String sidesteps that entirely.
    private init(sqlitePath: String) throws {
        // ":memory:" (used only by inMemoryFallback() above) has no parent
        // directory to create — skip the directory step for it so this
        // doesn't try to create "/" on disk.
        if sqlitePath != ":memory:" {
            let directory = (sqlitePath as NSString).deletingLastPathComponent
            if !directory.isEmpty {
                try FileManager.default.createDirectory(
                    atPath: directory,
                    withIntermediateDirectories: true
                )
            }
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(sqlitePath, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle { sqlite3_close(handle) }
            throw VocabularyStoreError.openFailed(message)
        }
        self.db = handle
        try queue.sync { try createSchema() }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func createSchema() throws {
        // `source` declares COLLATE NOCASE at the column level, and there's
        // a unique index below to match — but note this index only catches
        // ASCII-case duplicates (SQLite's built-in NOCASE collation doesn't
        // fold non-ASCII scripts like Cyrillic). It's kept as a defense-in-
        // depth constraint against exact/ASCII-case dupes; the actual
        // Unicode-aware case-insensitive dedup logic lives in Swift, in
        // findRowLocked(db:sourceCaseInsensitive:), which upsertLocked,
        // recordLearned, and deleteWhere all route through.
        let sql = """
        CREATE TABLE IF NOT EXISTS corrections (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source TEXT NOT NULL COLLATE NOCASE,
            replacement TEXT NOT NULL,
            origin TEXT NOT NULL DEFAULT 'manual',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_corrections_source_nocase
            ON corrections (source);
        """
        try execute(sql)
    }

    private func execute(_ sql: String) throws {
        guard let db else { throw VocabularyStoreError.sqlError("database closed") }
        var errorPointer: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorPointer)
            throw VocabularyStoreError.sqlError(message)
        }
    }

    func all() -> [VocabularyRecord] {
        queue.sync {
            guard let db else { return [] }
            return allLocked(db: db)
        }
    }

    private func allLocked(db: OpaquePointer) -> [VocabularyRecord] {
        let sql = "SELECT id, source, replacement, origin, created_at, updated_at FROM corrections ORDER BY source COLLATE NOCASE ASC;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var results: [VocabularyRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let record = record(from: statement) {
                results.append(record)
            }
        }
        return results
    }

    func count() -> Int {
        queue.sync {
            guard let db else { return 0 }
            return countLocked(db: db)
        }
    }

    private func countLocked(db: OpaquePointer) -> Int {
        let sql = "SELECT COUNT(*) FROM corrections;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    @discardableResult
    func upsert(source: String, replacement: String, origin: VocabularyOrigin) throws -> VocabularyRecord {
        try queue.sync {
            guard let db else { throw VocabularyStoreError.sqlError("database closed") }
            return try upsertLocked(db: db, source: source, replacement: replacement, origin: origin)
        }
    }

    /// Dedup lookup is done here in Swift (via `.lowercased()`) rather than
    /// leaning on SQLite's `COLLATE NOCASE`/unique index: SQLite's built-in
    /// NOCASE collation only folds ASCII A-Z — it leaves non-ASCII text
    /// (Cyrillic, Greek, accented Latin, etc.) untouched, so "Инглиш" and
    /// "инглиш" would compare unequal and the ON CONFLICT dedup would
    /// silently insert a second row instead of updating the first one.
    /// `String.lowercased()` is Unicode-aware and does the right thing for
    /// all scripts this app's users actually dictate in.
    private func upsertLocked(db: OpaquePointer, source: String, replacement: String, origin: VocabularyOrigin) throws -> VocabularyRecord {
        let now = ISO8601DateFormatter().string(from: Date())
        if let existing = findRowLocked(db: db, sourceCaseInsensitive: source) {
            let sql = """
            UPDATE corrections SET replacement = ?, updated_at = ?
            WHERE id = ?
            RETURNING id, source, replacement, origin, created_at, updated_at;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw VocabularyStoreError.sqlError(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            bindText(statement, 1, replacement)
            bindText(statement, 2, now)
            sqlite3_bind_int64(statement, 3, existing.id)

            guard sqlite3_step(statement) == SQLITE_ROW, let record = record(from: statement) else {
                throw VocabularyStoreError.sqlError(String(cString: sqlite3_errmsg(db)))
            }
            return record
        }

        let sql = """
        INSERT INTO corrections (source, replacement, origin, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?)
        RETURNING id, source, replacement, origin, created_at, updated_at;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw VocabularyStoreError.sqlError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        bindText(statement, 1, source)
        bindText(statement, 2, replacement)
        bindText(statement, 3, origin.rawValue)
        bindText(statement, 4, now)
        bindText(statement, 5, now)

        guard sqlite3_step(statement) == SQLITE_ROW, let record = record(from: statement) else {
            throw VocabularyStoreError.sqlError(String(cString: sqlite3_errmsg(db)))
        }
        return record
    }

    private func insertLocked(db: OpaquePointer, source: String, replacement: String, origin: VocabularyOrigin) throws -> VocabularyRecord {
        try upsertLocked(db: db, source: source, replacement: replacement, origin: origin)
    }

    /// Used by PostInsertionEditWatcher. Never evicts existing rows and
    /// never overwrites an existing correction for the same source
    /// (manual or previously-learned) — if the source is already known,
    /// this is a no-op so a manual correction can never be silently
    /// clobbered by auto-learning.
    func recordLearned(source: String, replacement: String) -> VocabularyRecord? {
        queue.sync {
            guard let db else { return nil }
            if findRowLocked(db: db, sourceCaseInsensitive: source) != nil { return nil }
            guard countLocked(db: db) < MAX_TRANSCRIPT_CORRECTIONS else { return nil }
            return try? insertLocked(db: db, source: source, replacement: replacement, origin: .learned)
        }
    }

    /// Unicode-aware case-insensitive lookup — see the note on
    /// `upsertLocked` for why this can't just be a SQL `WHERE source = ?`
    /// against the NOCASE-collated column. Row counts here are capped at
    /// MAX_TRANSCRIPT_CORRECTIONS (512), so a linear scan is cheap.
    private func findRowLocked(db: OpaquePointer, sourceCaseInsensitive source: String) -> VocabularyRecord? {
        let target = source.lowercased()
        return allLocked(db: db).first { $0.source.lowercased() == target }
    }

    /// Full-array replace matching the semantics the old UserDefaults-array
    /// setter had: any source not in `corrections` is removed, every
    /// source in `corrections` is present afterward. Existing rows keep
    /// their `origin`/`created_at` (so re-saving the same manual list from
    /// the menu doesn't downgrade a learned entry's origin badge back to
    /// nothing, and vice versa a manual edit of a learned row's
    /// replacement text keeps it tagged `learned`).
    func replaceAllPreservingOrigin(_ corrections: [TranscriptCorrection]) {
        queue.sync {
            guard let db else { return }
            let wantedSources = Set(corrections.map { $0.source.lowercased() })
            let existing = allLocked(db: db)
            for row in existing where !wantedSources.contains(row.source.lowercased()) {
                deleteLocked(db: db, id: row.id)
            }
            let existingBySource = Dictionary(uniqueKeysWithValues: existing.map { ($0.source.lowercased(), $0) })
            for correction in corrections {
                let origin = existingBySource[correction.source.lowercased()]?.origin ?? .manual
                _ = try? upsertLocked(db: db, source: correction.source, replacement: correction.replacement, origin: origin)
            }
        }
    }

    private func deleteLocked(db: OpaquePointer, id: Int64) {
        let sql = "DELETE FROM corrections WHERE id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        _ = sqlite3_step(statement)
    }

    func delete(id: Int64) {
        queue.sync {
            guard let db else { return }
            let sql = "DELETE FROM corrections WHERE id = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, id)
            _ = sqlite3_step(statement)
        }
    }

    func deleteWhere(sourceCaseInsensitive source: String) {
        queue.sync {
            guard let db else { return }
            guard let existing = findRowLocked(db: db, sourceCaseInsensitive: source) else { return }
            deleteLocked(db: db, id: existing.id)
        }
    }

    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func record(from statement: OpaquePointer?) -> VocabularyRecord? {
        guard let statement else { return nil }
        let id = sqlite3_column_int64(statement, 0)
        guard let sourceCString = sqlite3_column_text(statement, 1),
              let replacementCString = sqlite3_column_text(statement, 2),
              let originCString = sqlite3_column_text(statement, 3),
              let createdCString = sqlite3_column_text(statement, 4),
              let updatedCString = sqlite3_column_text(statement, 5),
              let origin = VocabularyOrigin(rawValue: String(cString: originCString)) else {
            return nil
        }
        return VocabularyRecord(
            id: id,
            source: String(cString: sourceCString),
            replacement: String(cString: replacementCString),
            origin: origin,
            createdAt: String(cString: createdCString),
            updatedAt: String(cString: updatedCString)
        )
    }
}
