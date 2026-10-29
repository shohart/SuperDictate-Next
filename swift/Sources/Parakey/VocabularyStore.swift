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
    /// Per-entry ASR hotword decision (spec asr-hotwords §6): nil =
    /// automatic (AsrHotwordSelection), true = always, false = never.
    var asrHint: Bool? = nil
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

    /// True only for the in-memory fallback created by inMemoryFallback().
    /// Callers (see Settings.migrateLegacyTranscriptCorrectionsIfNeeded)
    /// use this to avoid ever treating data written into an ephemeral
    /// store as durably migrated — see C2 in the final-review fix report.
    let isEphemeral: Bool

    /// False only when the `asr_hint` migration could not run (e.g. the
    /// other process held the write lock past the busy timeout). Reads
    /// then select NULL in its place, so the store keeps working with
    /// automatic hints, and `setAsrHint` reports the failure.
    private var hasAsrHintColumn = false

    /// Called (on the writing thread, after the write committed) whenever
    /// a local edit changed the store: manual edits, learning, cleanup,
    /// replace-all, hints. Never for `applyRemote` — a synced change must
    /// not look locally changed (spec vocabulary-sync §4.2). The app wires
    /// this to the vocabulary-changed notification and the sync debounce.
    var onLocalChange: (@Sendable () -> Void)? {
        get { changeHandlerLock.withLock { changeHandler } }
        set { changeHandlerLock.withLock { changeHandler = newValue } }
    }
    private var changeHandler: (@Sendable () -> Void)?
    private let changeHandlerLock = NSLock()

    private func notifyLocalChange() {
        onLocalChange?()
    }

    /// `updated_at` / `deleted_at` format: ISO-8601 UTC with seconds,
    /// `YYYY-MM-DDTHH:MM:SSZ`, compared as a string by the sync merge.
    static func timestamp(_ date: Date = Date()) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    convenience init(fileURL: URL) throws {
        try self.init(sqlitePath: fileURL.path, isEphemeral: false)
    }

    /// Last-resort constructor for the (expected-never) case where even
    /// FileManager.default.temporaryDirectory isn't writable. SQLite's
    /// special ":memory:" filename opens a private in-memory database
    /// instead of touching disk at all, so this cannot fail the way
    /// init(fileURL:) can.
    static func inMemoryFallback() -> VocabularyStore {
        // Force-unwrap is safe: ":memory:" always succeeds in SQLite,
        // and createSchema() against a fresh in-memory DB cannot fail.
        try! VocabularyStore(sqlitePath: ":memory:", isEphemeral: true)
    }

    /// Designated initializer, keyed off a raw SQLite path/filename
    /// string rather than a URL. SQLite's special ":memory:" sentinel
    /// must reach sqlite3_open_v2 verbatim — round-tripping it through
    /// URL(fileURLWithPath:) resolves it against the current working
    /// directory (e.g. "/Users/me/:memory:"), which would silently turn
    /// "in-memory" into "write a file literally named :memory: to disk".
    /// Going through a plain String sidesteps that entirely.
    private init(sqlitePath: String, isEphemeral: Bool) throws {
        self.isEphemeral = isEphemeral
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
        // The main app and the separate Control Panel process both open
        // their own connection to the same on-disk corrections.sqlite, so
        // SQLITE_BUSY from a concurrent writer is a real, expected event —
        // give SQLite's own retry-on-lock behavior a real window instead
        // of failing (and being silently swallowed by try?) instantly.
        sqlite3_busy_timeout(handle, 3000)
        // Same two-process access pattern: WAL mode lets a reader not
        // block the writer and vice versa, eliminating most of the
        // SQLITE_BUSY contention above. journal_mode is persistent in
        // the database file, so this needs to succeed only once for all
        // future connections. Best-effort: a transient failure (busy,
        // read-only directory) must not prevent the store from opening
        // in rollback-journal mode as before.
        if sqlitePath != ":memory:" {
            var walError: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(handle, "PRAGMA journal_mode=WAL;", nil, nil, &walError) != SQLITE_OK {
                let message = walError.map { String(cString: $0) } ?? "unknown error"
                log("VocabularyStore: WAL mode not enabled (continuing with rollback journal): \(message)")
            }
            if let walError { sqlite3_free(walError) }
        }
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
        CREATE TABLE IF NOT EXISTS deleted_corrections (
            key TEXT PRIMARY KEY,
            source TEXT NOT NULL,
            deleted_at TEXT NOT NULL
        );
        """
        try execute(sql)
        migrateAsrHintColumnIfNeeded()
    }

    /// Idempotent: adds `asr_hint INTEGER` (NULL auto / 1 on / 0 off) once.
    /// Both the agent and the Control Panel open this file, so a
    /// "duplicate column" failure from a concurrent ALTER is re-checked
    /// rather than treated as an error.
    private func migrateAsrHintColumnIfNeeded() {
        guard let db else { return }
        if columnExistsLocked(db: db, table: "corrections", column: "asr_hint") {
            hasAsrHintColumn = true
            return
        }
        do {
            try execute("ALTER TABLE corrections ADD COLUMN asr_hint INTEGER;")
        } catch {
            if !columnExistsLocked(db: db, table: "corrections", column: "asr_hint") {
                log("VocabularyStore: asr_hint migration failed (ASR hints stay automatic this session): \(error)")
                return
            }
        }
        hasAsrHintColumn = true
    }

    private func columnExistsLocked(db: OpaquePointer, table: String, column: String) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1), String(cString: name) == column {
                return true
            }
        }
        return false
    }

    /// The column list every read and RETURNING clause uses; `record(from:)`
    /// decodes it by position.
    private var recordColumns: String {
        "id, source, replacement, origin, created_at, updated_at, " + (hasAsrHintColumn ? "asr_hint" : "NULL")
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
        let sql = "SELECT \(recordColumns) FROM corrections ORDER BY source COLLATE NOCASE ASC;"
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
        let record = try queue.sync {
            guard let db else { throw VocabularyStoreError.sqlError("database closed") }
            return try upsertLocked(db: db, source: source, replacement: replacement, origin: origin)
        }
        notifyLocalChange()
        return record
    }

    /// Dedup lookup is done here in Swift (via
    /// `normalizedTranscriptCorrectionSource`, ModelDownload.swift) rather
    /// than leaning on SQLite's `COLLATE NOCASE`/unique index: SQLite's
    /// built-in NOCASE collation only folds ASCII A-Z — it leaves non-ASCII
    /// text (Cyrillic, Greek, accented Latin, etc.) untouched, so "Инглиш"
    /// and "инглиш" would compare unequal and the ON CONFLICT dedup would
    /// silently insert a second row instead of updating the first one.
    /// `normalizedTranscriptCorrectionSource` is Unicode-aware (via
    /// `.lowercased()`) *and* collapses internal whitespace, matching the
    /// canonical correction-identity key the rest of the app (import
    /// summaries, merge logic) already assumes — using a weaker key here
    /// let whitespace-variant duplicates slip into the store that those
    /// call sites then choke on. See C1 in the final-review fix report.
    private func upsertLocked(db: OpaquePointer, source: String, replacement: String, origin: VocabularyOrigin) throws -> VocabularyRecord {
        let now = Self.timestamp()
        if let existing = findRowLocked(db: db, sourceCaseInsensitive: source) {
            // An unchanged replacement is not an edit: keeping updated_at
            // stops a replace-all (import, folder sync) from marking every
            // row as changed for the account sync.
            if existing.replacement == replacement { return existing }
            let sql = """
            UPDATE corrections SET replacement = ?, updated_at = ?
            WHERE id = ?
            RETURNING \(recordColumns);
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
        RETURNING \(recordColumns);
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
        // Re-adding a key clears its tombstone (spec §4.1).
        removeTombstoneLocked(db: db, source: source)
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
            guard let db else {
                log("VocabularyStore: recordLearned dropped — database connection is closed")
                return nil
            }
            if findRowLocked(db: db, sourceCaseInsensitive: source) != nil { return nil }
            guard countLocked(db: db) < MAX_TRANSCRIPT_CORRECTIONS else { return nil }
            do {
                let record = try insertLocked(db: db, source: source, replacement: replacement, origin: .learned)
                notifyLocalChange()
                return record
            } catch {
                // Never mask an actual SQLite failure (busy, disk, ...)
                // behind "already known / cap reached": a silently
                // dropped auto-learn is indistinguishable from a real
                // decline to the caller, so the real reason must be
                // visible in the log.
                log("VocabularyStore: recordLearned insert failed for \"\(source)\": \(error)")
                return nil
            }
        }
    }

    /// Unicode-aware case-insensitive lookup — see the note on
    /// `upsertLocked` for why this can't just be a SQL `WHERE source = ?`
    /// against the NOCASE-collated column. Row counts here are capped at
    /// MAX_TRANSCRIPT_CORRECTIONS (512), so a linear scan is cheap.
    private func findRowLocked(db: OpaquePointer, sourceCaseInsensitive source: String) -> VocabularyRecord? {
        let target = normalizedTranscriptCorrectionSource(source)
        return allLocked(db: db).first { normalizedTranscriptCorrectionSource($0.source) == target }
    }

    /// Full-array replace matching the semantics the old UserDefaults-array
    /// setter had: any source not in `corrections` is removed, every
    /// source in `corrections` is present afterward. Existing rows keep
    /// their `origin`/`created_at` (so re-saving the same manual list from
    /// the menu doesn't downgrade a learned entry's origin badge back to
    /// nothing, and vice versa a manual edit of a learned row's
    /// replacement text keeps it tagged `learned`).
    /// Wrapped in a single transaction: this method issues a sequence of
    /// deletes and upserts, and every one of them is used on the exact
    /// path a menu-bar corrections save, import, or folder-sync apply
    /// goes through. Without a transaction, a mid-sequence failure (e.g.
    /// SQLITE_BUSY once the busy-timeout window expires) would leave the
    /// store partially updated — some rows deleted, not yet replaced. See
    /// I4 in the final-review fix report.
    func replaceAllPreservingOrigin(_ corrections: [TranscriptCorrection]) {
        queue.sync {
            guard let db else { return }

            guard (try? execute("BEGIN IMMEDIATE;")) != nil else {
                log("vocabulary: replaceAllPreservingOrigin could not start a transaction (store likely busy); leaving the store untouched")
                return
            }

            do {
                // Keyed with the same canonical normalizer findRowLocked
                // uses, so this stays consistent with upsertLocked's own
                // dedup key — see C1 in the final-review fix report.
                let wantedSources = Set(corrections.map { normalizedTranscriptCorrectionSource($0.source) })
                let existing = allLocked(db: db)
                for row in existing where !wantedSources.contains(normalizedTranscriptCorrectionSource(row.source)) {
                    guard deleteLocked(db: db, record: row) else {
                        throw VocabularyStoreError.sqlError("failed to delete row \(row.id) during replaceAllPreservingOrigin")
                    }
                }
                let existingBySource = Dictionary(
                    existing.map { (normalizedTranscriptCorrectionSource($0.source), $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                for correction in corrections {
                    let origin = existingBySource[normalizedTranscriptCorrectionSource(correction.source)]?.origin ?? .manual
                    _ = try upsertLocked(db: db, source: correction.source, replacement: correction.replacement, origin: origin)
                }
                try execute("COMMIT;")
                notifyLocalChange()
            } catch {
                try? execute("ROLLBACK;")
                log("vocabulary: replaceAllPreservingOrigin failed, rolled back to the pre-call state: \(error)")
            }
        }
    }

    /// Every local delete goes through here so it leaves a tombstone for
    /// the account sync (spec §4.1). `deletedAt` is now for local deletes
    /// and the remote stamp for a synced tombstone.
    @discardableResult
    private func deleteLocked(db: OpaquePointer, record: VocabularyRecord, deletedAt: String? = nil) -> Bool {
        let sql = "DELETE FROM corrections WHERE id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, record.id)
        guard sqlite3_step(statement) == SQLITE_DONE else { return false }
        return writeTombstoneLocked(db: db, source: record.source, deletedAt: deletedAt ?? Self.timestamp())
    }

    func delete(id: Int64) {
        let deleted: Bool = queue.sync {
            guard let db else { return false }
            guard let existing = allLocked(db: db).first(where: { $0.id == id }) else { return false }
            return deleteLocked(db: db, record: existing)
        }
        if deleted { notifyLocalChange() }
    }

    func deleteWhere(sourceCaseInsensitive source: String) {
        let deleted: Bool = queue.sync {
            guard let db else { return false }
            guard let existing = findRowLocked(db: db, sourceCaseInsensitive: source) else { return false }
            return deleteLocked(db: db, record: existing)
        }
        if deleted { notifyLocalChange() }
    }

    /// Sets the per-entry ASR hint: nil = automatic, true/false = explicit.
    /// Bumps `updated_at`: the hint travels with the entry in the account
    /// sync, whose last-writer-wins merge and push selection both key off
    /// `updated_at` (spec vocabulary-sync §4).
    func setAsrHint(id: Int64, hint: Bool?) throws {
        try queue.sync {
            guard let db else { throw VocabularyStoreError.sqlError("database closed") }
            guard hasAsrHintColumn else {
                throw VocabularyStoreError.sqlError("the asr_hint column is unavailable")
            }
            let sql = "UPDATE corrections SET asr_hint = ?, updated_at = ? WHERE id = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw VocabularyStoreError.sqlError(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }
            if let hint {
                sqlite3_bind_int64(statement, 1, hint ? 1 : 0)
            } else {
                sqlite3_bind_null(statement, 1)
            }
            bindText(statement, 2, Self.timestamp())
            sqlite3_bind_int64(statement, 3, id)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw VocabularyStoreError.sqlError(String(cString: sqlite3_errmsg(db)))
            }
        }
        notifyLocalChange()
    }

    // MARK: - Tombstones (spec vocabulary-sync §4.1)

    struct Tombstone: Equatable, Sendable {
        let key: String
        let source: String
        let deletedAt: String
    }

    /// Records (or advances) the tombstone for `source`'s key. An older
    /// stamp never overwrites a newer one.
    @discardableResult
    private func writeTombstoneLocked(db: OpaquePointer, source: String, deletedAt: String) -> Bool {
        let sql = """
        INSERT INTO deleted_corrections (key, source, deleted_at) VALUES (?, ?, ?)
        ON CONFLICT (key) DO UPDATE SET source = excluded.source, deleted_at = excluded.deleted_at
        WHERE excluded.deleted_at > deleted_corrections.deleted_at;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, normalizedTranscriptCorrectionSource(source))
        bindText(statement, 2, source)
        bindText(statement, 3, deletedAt)
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func removeTombstoneLocked(db: OpaquePointer, source: String) {
        let sql = "DELETE FROM deleted_corrections WHERE key = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, normalizedTranscriptCorrectionSource(source))
        _ = sqlite3_step(statement)
    }

    func tombstones() -> [Tombstone] {
        queue.sync {
            guard let db else { return [] }
            return tombstonesLocked(db: db)
        }
    }

    private func tombstonesLocked(db: OpaquePointer) -> [Tombstone] {
        let sql = "SELECT key, source, deleted_at FROM deleted_corrections ORDER BY deleted_at;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [Tombstone] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let key = sqlite3_column_text(statement, 0),
                  let source = sqlite3_column_text(statement, 1),
                  let deletedAt = sqlite3_column_text(statement, 2) else { continue }
            result.append(Tombstone(key: String(cString: key), source: String(cString: source),
                                    deletedAt: String(cString: deletedAt)))
        }
        return result
    }

    // MARK: - Learning with hygiene (spec vocabulary-hygiene §2)

    enum LearnCommitOutcome: Equatable {
        case learned(VocabularyRecord)
        case rejected(VocabularyHygiene.RejectReason)
        /// The candidate reverted this entry, which is now deleted.
        case undone(VocabularyRecord)
        /// Already known, cap reached, or a SQLite failure (logged).
        case declined(String)
    }

    /// The learn path used by PostInsertionEditWatcher: re-runs
    /// VocabularyHygiene.review against the current rows and applies the
    /// verdict (insert + chain rewrites + case unification, or the undo
    /// delete) in one transaction. Like `recordLearned`, a source that is
    /// already known is never overwritten.
    func commitLearned(source: String, replacement: String) -> LearnCommitOutcome {
        let outcome: LearnCommitOutcome = queue.sync {
            guard let db else { return .declined("database connection is closed") }
            guard (try? execute("BEGIN IMMEDIATE;")) != nil else {
                return .declined("could not start a transaction (store busy)")
            }
            do {
                let rows = allLocked(db: db)
                switch VocabularyHygiene.review(source: source, replacement: replacement, existing: rows) {
                case .reject(let reason):
                    try execute("ROLLBACK;")
                    return .rejected(reason)
                case .undo(let id):
                    guard let reverted = rows.first(where: { $0.id == id }),
                          deleteLocked(db: db, record: reverted) else {
                        throw VocabularyStoreError.sqlError("could not delete the reverted entry \(id)")
                    }
                    try execute("COMMIT;")
                    return .undone(reverted)
                case .accept(let source, let replacement, let rewrites):
                    if findRowLocked(db: db, sourceCaseInsensitive: source) != nil {
                        try execute("ROLLBACK;")
                        return .declined("source already known")
                    }
                    guard rows.count < MAX_TRANSCRIPT_CORRECTIONS else {
                        try execute("ROLLBACK;")
                        return .declined("vocabulary cap reached")
                    }
                    let record = try insertLocked(db: db, source: source, replacement: replacement, origin: .learned)
                    for rewrite in rewrites {
                        try updateRowLocked(db: db, id: rewrite.id, source: nil, replacement: rewrite.replacement)
                    }
                    try execute("COMMIT;")
                    return .learned(record)
                }
            } catch {
                try? execute("ROLLBACK;")
                return .declined("\(error)")
            }
        }
        switch outcome {
        case .learned, .undone: notifyLocalChange()
        case .rejected, .declined: break
        }
        return outcome
    }

    /// In-place edit of an existing row (cleanup, chain rewrites): keeps
    /// id, origin, created_at and asr_hint, bumps updated_at. A changed
    /// key tombstones the old one and clears any tombstone of the new one.
    private func updateRowLocked(db: OpaquePointer, id: Int64, source: String?, replacement: String) throws {
        guard let existing = allLocked(db: db).first(where: { $0.id == id }) else {
            throw VocabularyStoreError.sqlError("row \(id) disappeared")
        }
        let newSource = source ?? existing.source
        let sql = "UPDATE corrections SET source = ?, replacement = ?, updated_at = ? WHERE id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw VocabularyStoreError.sqlError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        let now = Self.timestamp()
        bindText(statement, 1, newSource)
        bindText(statement, 2, replacement)
        bindText(statement, 3, now)
        sqlite3_bind_int64(statement, 4, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw VocabularyStoreError.sqlError(String(cString: sqlite3_errmsg(db)))
        }
        if normalizedTranscriptCorrectionSource(newSource) != normalizedTranscriptCorrectionSource(existing.source) {
            writeTombstoneLocked(db: db, source: existing.source, deletedAt: now)
            removeTombstoneLocked(db: db, source: newSource)
        }
    }

    // MARK: - Cleanup (spec vocabulary-hygiene §3)

    func cleanupPlan() -> VocabularyHygiene.CleanupPlan {
        VocabularyHygiene.cleanupPlan(for: all())
    }

    enum CleanupError: Error, LocalizedError {
        case storeChanged
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .storeChanged: return "The vocabulary changed since the preview was built."
            case .failed(let message): return message
            }
        }
    }

    /// Applies a plan from `cleanupPlan()` in one transaction. Refuses
    /// (`storeChanged`) when any planned row was edited since the plan was
    /// computed, so a preview never applies to rows the user did not see.
    func applyCleanup(_ plan: VocabularyHygiene.CleanupPlan) throws {
        guard !plan.isEmpty else { return }
        try queue.sync {
            guard let db else { throw CleanupError.failed("database connection is closed") }
            guard (try? execute("BEGIN IMMEDIATE;")) != nil else {
                throw CleanupError.failed("could not start a transaction (store busy)")
            }
            do {
                let current = Dictionary(allLocked(db: db).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let planned = plan.deletions.map(\.record) + plan.rewrites.map(\.record)
                for record in planned where current[record.id] != record {
                    throw CleanupError.storeChanged
                }
                for deletion in plan.deletions {
                    guard deleteLocked(db: db, record: deletion.record) else {
                        throw CleanupError.failed("could not delete row \(deletion.record.id)")
                    }
                }
                for rewrite in plan.rewrites {
                    try updateRowLocked(db: db, id: rewrite.record.id, source: rewrite.source,
                                        replacement: rewrite.replacement)
                }
                try execute("COMMIT;")
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        }
        notifyLocalChange()
    }

    // MARK: - Account sync (spec vocabulary-sync §4)

    /// One entry as the sync server sends it.
    struct RemoteEntry: Equatable, Sendable {
        let source: String
        let replacement: String
        let origin: VocabularyOrigin
        let asrHint: Bool?
        let deleted: Bool
        let updatedAt: String
    }

    /// Local rows changed at or after `stamp` and tombstones written at or
    /// after it (an empty stamp selects everything). `>=` rather than `>`:
    /// stamps have one-second resolution, and re-pushing an entry from the
    /// cursor's own second is harmless (a tie keeps the server copy).
    func syncChanges(since stamp: String) -> (entries: [VocabularyRecord], tombstones: [Tombstone]) {
        queue.sync {
            guard let db else { return ([], []) }
            let entries = allLocked(db: db).filter { $0.updatedAt >= stamp }
            let tombstones = tombstonesLocked(db: db).filter { $0.deletedAt >= stamp }
            return (entries, tombstones)
        }
    }

    /// Applies server entries by last-writer-wins on `updated_at` (a tie
    /// keeps the local copy, which equals the server's). Rows keep the
    /// remote `updated_at`, origin and asr_hint, so an applied entry does
    /// not look locally changed, and `onLocalChange` is not called.
    /// Returns how many rows changed.
    @discardableResult
    func applyRemote(_ entries: [RemoteEntry]) throws -> Int {
        guard !entries.isEmpty else { return 0 }
        return try queue.sync {
            guard let db else { throw VocabularyStoreError.sqlError("database closed") }
            guard (try? execute("BEGIN IMMEDIATE;")) != nil else {
                throw VocabularyStoreError.sqlError("could not start a transaction (store busy)")
            }
            do {
                var rows: [String: VocabularyRecord] = [:]
                for row in allLocked(db: db) { rows[normalizedTranscriptCorrectionSource(row.source)] = row }
                var tombstones: [String: Tombstone] = [:]
                for tombstone in tombstonesLocked(db: db) { tombstones[tombstone.key] = tombstone }
                var changed = 0
                for entry in entries {
                    let key = normalizedTranscriptCorrectionSource(entry.source)
                    guard !key.isEmpty else { continue }
                    if entry.deleted {
                        if let local = rows[key] {
                            guard entry.updatedAt > local.updatedAt else { continue }
                            guard deleteLocked(db: db, record: local, deletedAt: entry.updatedAt) else {
                                throw VocabularyStoreError.sqlError(String(cString: sqlite3_errmsg(db)))
                            }
                            rows[key] = nil
                            changed += 1
                        } else {
                            writeTombstoneLocked(db: db, source: entry.source, deletedAt: entry.updatedAt)
                        }
                        tombstones[key] = Tombstone(key: key, source: entry.source, deletedAt: entry.updatedAt)
                        continue
                    }
                    if let local = rows[key] {
                        guard entry.updatedAt > local.updatedAt else { continue }
                        rows[key] = try writeRemoteRowLocked(db: db, entry: entry, existingId: local.id)
                    } else {
                        if let tombstone = tombstones[key], tombstone.deletedAt >= entry.updatedAt { continue }
                        guard rows.count < MAX_TRANSCRIPT_CORRECTIONS else {
                            log("vocabulary sync: local cap of \(MAX_TRANSCRIPT_CORRECTIONS) reached; remote entry not stored")
                            continue
                        }
                        rows[key] = try writeRemoteRowLocked(db: db, entry: entry, existingId: nil)
                    }
                    removeTombstoneLocked(db: db, source: entry.source)
                    tombstones[key] = nil
                    changed += 1
                }
                try execute("COMMIT;")
                return changed
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        }
    }

    private func writeRemoteRowLocked(db: OpaquePointer, entry: RemoteEntry, existingId: Int64?) throws -> VocabularyRecord {
        let hintColumn = hasAsrHintColumn ? ", asr_hint" : ""
        let sql: String
        if existingId != nil {
            sql = """
            UPDATE corrections SET source = ?, replacement = ?, origin = ?, updated_at = ?\(hasAsrHintColumn ? ", asr_hint = ?" : "")
            WHERE id = ? RETURNING \(recordColumns);
            """
        } else {
            sql = """
            INSERT INTO corrections (source, replacement, origin, updated_at\(hintColumn), created_at)
            VALUES (?, ?, ?, ?\(hasAsrHintColumn ? ", ?" : ""), ?) RETURNING \(recordColumns);
            """
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw VocabularyStoreError.sqlError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, entry.source)
        bindText(statement, 2, entry.replacement)
        bindText(statement, 3, entry.origin.rawValue)
        bindText(statement, 4, entry.updatedAt)
        var index: Int32 = 5
        if hasAsrHintColumn {
            if let hint = entry.asrHint {
                sqlite3_bind_int64(statement, index, hint ? 1 : 0)
            } else {
                sqlite3_bind_null(statement, index)
            }
            index += 1
        }
        if let existingId {
            sqlite3_bind_int64(statement, index, existingId)
        } else {
            bindText(statement, index, Self.timestamp())
        }
        guard sqlite3_step(statement) == SQLITE_ROW, let record = record(from: statement) else {
            throw VocabularyStoreError.sqlError(String(cString: sqlite3_errmsg(db)))
        }
        return record
    }

    /// The ASR hotword list (spec asr-hotwords §6) for the current
    /// contents of the store.
    func asrHotwordPhrases() -> [String] {
        AsrHotwordSelection.phrases(from: all())
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
        let asrHint: Bool? = sqlite3_column_type(statement, 6) == SQLITE_NULL
            ? nil
            : sqlite3_column_int64(statement, 6) != 0
        return VocabularyRecord(
            id: id,
            source: String(cString: sourceCString),
            replacement: String(cString: replacementCString),
            origin: origin,
            createdAt: String(cString: createdCString),
            updatedAt: String(cString: updatedCString),
            asrHint: asrHint
        )
    }
}
