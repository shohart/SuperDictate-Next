# Automatic Personal-Vocabulary Learning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** SuperDictate learns word/phrase-level vocabulary corrections automatically by watching what the user types right after a dictation is inserted, stores all corrections (manual and learned) in a local SQLite database, and exposes a full CRUD management window from the Control Panel.

**Architecture:** A new `VocabularyStore` (SQLite, via the system `libsqlite3`) becomes the single source of truth for `TranscriptCorrection` pairs, replacing the existing `UserDefaults`-JSON-array store but keeping `Settings.transcriptCorrections`'s existing `[TranscriptCorrection]` get/set contract unchanged so every existing call site (correction application, menu-bar list, import/export/sync) keeps working without modification. A new `PostInsertionEditWatcher` uses an `AXObserver` to detect a short user edit immediately after text insertion, runs it through a pure-function word-diff (`LearnCandidateDetector`), and if it resolves to a ≤3-word replacement, saves it via `VocabularyStore` and shows an undoable HUD toast. A new `VocabularyManagerWindow` (opened from the existing Settings panel) gives full manual CRUD plus the existing JSON import/export flow, now backed by the store.

**Tech Stack:** Swift 6 / AppKit, system `libsqlite3` via `import SQLite3` (no third-party dependency), `ApplicationServices` (`AXObserver`), existing `SelfTest.swift` command-line test harness (no XCTest target in this project).

## Global Constraints

- Never touch `TranscriptCorrectionsTransfer`'s JSON document format/schema (`CorrectionsTransfer.swift`) — it stays the only format for export/import/cross-Mac folder sync, unchanged.
- `Settings.transcriptCorrections` keeps its existing type (`[TranscriptCorrection]`) and get/set semantics (full-array replace) so no other file in the codebase needs to change to keep compiling and behaving the same.
- All processing stays local — no network calls anywhere in this feature.
- Cap stays `MAX_TRANSCRIPT_CORRECTIONS = 512` total rows (manual + learned combined); auto-learning must never evict existing rows to make room.
- Per-field size caps stay `MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES = 512` / `MAX_TRANSCRIPT_CORRECTION_REPLACEMENT_BYTES = 4096` (`Constants.swift`).
- Learning never touches secure-text fields (`subrole == "AXSecureTextField"`).
- Learning only fires for insertions that went through an AX attribute path (`TextInsertionResult.insertedUsingSelectedText` / `.insertedUsingValueAndRange`); the simulated-keyboard-events fallback (`.insertedUsingKeyboardEvents`) is never watched.
- All new command-line verification goes through `SelfTest.swift`'s `runSuite` pattern (`swift run Parakey --self-test <name>`), per `AGENTS.md` — never through an installed/copied `.app`.
- Build/test commands in every task below assume they run from `swift/` (`cd swift && swift build` etc.) on the real target Mac per `AGENTS.md`/`SESSION_HANDOFF.md` — do not run them against a different installed bundle.

---

### Task 1: Link SQLite and build `VocabularyStore` core CRUD

**Files:**
- Modify: `swift/Package.swift` (executableTarget `Parakey`'s `linkerSettings`)
- Create: `swift/Sources/Parakey/VocabularyStore.swift`
- Test: exercised via `swift run Parakey --self-test vocabulary-store` (wired in Task 10; write the suite body now, call it from `SelfTest.swift` in Task 10)

**Interfaces:**
- Produces:
  - `enum VocabularyOrigin: String { case manual, learned }`
  - `struct VocabularyRecord: Equatable { let id: Int64; let source: String; let replacement: String; let origin: VocabularyOrigin; let createdAt: String; let updatedAt: String }`
  - `enum VocabularyStoreError: Error { case openFailed(String); case sqlError(String) }`
  - `final class VocabularyStore`
    - `init(fileURL: URL) throws`
    - `func all() -> [VocabularyRecord]` (ordered by `source COLLATE NOCASE`)
    - `func count() -> Int`
    - `func upsert(source: String, replacement: String, origin: VocabularyOrigin) throws -> VocabularyRecord`
    - `func delete(id: Int64)`
    - `func deleteWhere(sourceCaseInsensitive source: String)`

- [ ] **Step 0: Confirm the target Mac's system SQLite supports `RETURNING` and column-level `COLLATE`**

`upsertLocked` (Step 2 below) uses an `INSERT ... ON CONFLICT ... RETURNING` statement, which requires SQLite ≥ 3.35 (2021). Confirm the actual version on the real build/target Mac before writing code against it:

Run: `sqlite3 --version`
Expected: a version ≥ 3.35.0. macOS 14 (Sonoma)'s system `libsqlite3` ships well above this (typically 3.43+), so this should pass; if it does not, stop and report back — the schema in Step 2 needs a fallback (`sqlite3_last_insert_rowid()` + a follow-up `SELECT` instead of `RETURNING`) that is not written into this plan.

- [ ] **Step 1: Add the SQLite link flag**

In `swift/Package.swift`, inside the `.executableTarget(name: "Parakey", ...)` block, add a `linkerSettings` array (there isn't one there today — only `dependencies:`):

```swift
        .executableTarget(
            name: "Parakey",
            dependencies: ["parakeet_cpp"],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
            // No `resources:` here on purpose. SwiftPM bundles them as
            // a `<Package>_<Target>.bundle` directory next to the
            // executable, which `codesign --deep` won't accept as a
            // signable component because it lacks Info.plist. Instead,
            // the menubar PNGs are copied into Contents/Resources/ by
            // dev-run.sh and ship-swift.sh — the canonical .app layout
            // where Bundle.main finds them via the standard search
            // path. Source PNGs live in swift/Resources/ at the repo
            // root, NOT in the SwiftPM target, so SwiftPM never sees them.
        ),
```

- [ ] **Step 2: Write `VocabularyStore.swift`**

```swift
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

    init(fileURL: URL) throws {
        // ":memory:" (used only by inMemoryFallback() below) has no parent
        // directory to create — skip the directory step for it so this
        // doesn't try to create "/" on disk.
        if fileURL.path != ":memory:" {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(fileURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
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
        // `source` declares COLLATE NOCASE at the column level (not via a
        // separate collated index expression) so a plain `ON CONFLICT(source)`
        // in upsertLocked's INSERT below resolves against this same unique
        // index without needing to repeat the collation in the conflict
        // target — SQLite's upsert conflict-target matching requires the
        // ON CONFLICT column list to resolve to the exact same index
        // definition, and the simplest way to guarantee that match is to
        // let the column's own declared collation do the work everywhere.
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
    }

    func count() -> Int {
        queue.sync {
            guard let db else { return 0 }
            let sql = "SELECT COUNT(*) FROM corrections;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    @discardableResult
    func upsert(source: String, replacement: String, origin: VocabularyOrigin) throws -> VocabularyRecord {
        try queue.sync {
            guard let db else { throw VocabularyStoreError.sqlError("database closed") }
            let now = ISO8601DateFormatter().string(from: Date())
            let sql = """
            INSERT INTO corrections (source, replacement, origin, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(source) DO UPDATE SET
                replacement = excluded.replacement,
                updated_at = excluded.updated_at
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
            let sql = "DELETE FROM corrections WHERE source = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, source)
            _ = sqlite3_step(statement)
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
```

- [ ] **Step 3: Build to confirm the SQLite link and API surface compile**

Run: `cd swift && swift build`
Expected: builds cleanly (no test runner exists yet for this file — Task 10 wires the self-test suite that actually exercises this class; this step only confirms it compiles and links against `libsqlite3`).

- [ ] **Step 4: Commit**

```bash
git add swift/Package.swift swift/Sources/Parakey/VocabularyStore.swift
git commit -m "feat(vocabulary): add SQLite-backed VocabularyStore core CRUD"
```

---

### Task 2: Add cap/dedup-aware learning API and full-array replace to `VocabularyStore`

**Files:**
- Modify: `swift/Sources/Parakey/VocabularyStore.swift`

**Interfaces:**
- Consumes: `VocabularyStore`, `VocabularyRecord`, `VocabularyOrigin` from Task 1.
- Produces (added to `VocabularyStore`):
  - `func recordLearned(source: String, replacement: String) -> VocabularyRecord?` — returns the new record on success, `nil` if a row for that source already exists (case-insensitively) or the store is already at `MAX_TRANSCRIPT_CORRECTIONS`.
  - `func replaceAllPreservingOrigin(_ corrections: [TranscriptCorrection])` — full-array replace matching the semantics `Settings.transcriptCorrections`'s setter needs (Task 3): every source not present in `corrections` is deleted; every source present is upserted, keeping its existing `origin`/`created_at` if it already existed, else `origin = .manual`.

- [ ] **Step 1: Add `recordLearned`**

Append to `VocabularyStore`:

```swift
    /// Used by PostInsertionEditWatcher. Never evicts existing rows and
    /// never overwrites an existing correction for the same source
    /// (manual or previously-learned) — if the source is already known,
    /// this is a no-op so a manual correction can never be silently
    /// clobbered by auto-learning.
    func recordLearned(source: String, replacement: String) -> VocabularyRecord? {
        queue.sync {
            guard let db else { return nil }
            if rowExists(db: db, sourceCaseInsensitive: source) { return nil }
            guard countLocked(db: db) < MAX_TRANSCRIPT_CORRECTIONS else { return nil }
            return try? insertLocked(db: db, source: source, replacement: replacement, origin: .learned)
        }
    }

    private func rowExists(db: OpaquePointer, sourceCaseInsensitive source: String) -> Bool {
        let sql = "SELECT 1 FROM corrections WHERE source = ? LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, source)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func countLocked(db: OpaquePointer) -> Int {
        let sql = "SELECT COUNT(*) FROM corrections;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }
```

`upsert(source:replacement:origin:)` from Task 1 already runs its own SQL directly against `db` inside the queue, not through a reusable "insert while already on the queue" helper — `recordLearned` above calls a new `insertLocked` that factors the insert-only SQL (no `ON CONFLICT`, since `rowExists` already confirmed there's no conflict) out of `upsert`. Refactor `upsert` to share it:

```swift
    @discardableResult
    func upsert(source: String, replacement: String, origin: VocabularyOrigin) throws -> VocabularyRecord {
        try queue.sync {
            guard let db else { throw VocabularyStoreError.sqlError("database closed") }
            return try upsertLocked(db: db, source: source, replacement: replacement, origin: origin)
        }
    }

    private func upsertLocked(db: OpaquePointer, source: String, replacement: String, origin: VocabularyOrigin) throws -> VocabularyRecord {
        let now = ISO8601DateFormatter().string(from: Date())
        let sql = """
        INSERT INTO corrections (source, replacement, origin, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(source) DO UPDATE SET
            replacement = excluded.replacement,
            updated_at = excluded.updated_at
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
```

(`insertLocked` is a thin alias kept distinct from `upsertLocked` in call sites above for readability — both run the same `INSERT ... ON CONFLICT` statement, which is safe to call even when the caller has already confirmed no conflict exists.)

Delete the old standalone `upsert` and `record(from:)`-adjacent duplicate SQL from Task 1's Step 2 (replaced by the versions above — `record(from:)` itself is unchanged and still used by `upsertLocked` and `all()`).

- [ ] **Step 2: Add `replaceAllPreservingOrigin`**

```swift
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
            let existing = all()
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
```

Note `all()` calls `queue.sync` internally and `replaceAllPreservingOrigin` is itself inside `queue.sync` — `DispatchQueue.sync` is not reentrant-safe when called on itself from the same queue, so calling `all()` (which does its own `queue.sync`) from inside `replaceAllPreservingOrigin`'s `queue.sync` block would deadlock. Fix: factor an `allLocked(db:)` that both `all()` and `replaceAllPreservingOrigin` call, with `all()` wrapping it in `queue.sync` and `replaceAllPreservingOrigin` calling it directly (already on the queue):

```swift
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
```

And change `replaceAllPreservingOrigin`'s body to call `allLocked(db: db)` instead of `all()`. Apply the same fix to `recordLearned` and `count()`/`countLocked` (already using the `*Locked` pattern — leave as is) and to `delete(id:)` / `deleteWhere(sourceCaseInsensitive:)`, which are fine as written since nothing calls another `queue.sync` method from inside them.

- [ ] **Step 3: Build**

Run: `cd swift && swift build`
Expected: builds cleanly.

- [ ] **Step 4: Commit**

```bash
git add swift/Sources/Parakey/VocabularyStore.swift
git commit -m "feat(vocabulary): add learn/cap/dedup and full-array-replace APIs to VocabularyStore"
```

---

### Task 3: Migrate `Settings.transcriptCorrections` onto `VocabularyStore`

**Files:**
- Modify: `swift/Sources/Parakey/Settings.swift`
- Modify: `swift/Sources/Parakey/Logger.swift` (reuse `superDictateApplicationSupportDirectory()`, no change needed — just confirms the path helper this task depends on)

**Interfaces:**
- Consumes: `VocabularyStore`, `VocabularyRecord`, `normalizedTranscriptCorrections` (`ModelDownload.swift:373`), `TranscriptCorrectionsTransfer.decode` (`CorrectionsTransfer.swift`), `superDictateApplicationSupportDirectory() throws -> URL` (`Logger.swift:55`).
- Produces: `Settings.vocabularyStore: VocabularyStore` (new stored property), `Settings.transcriptCorrections` keeps its existing `[TranscriptCorrection]` get/set signature (`Settings.swift:656`) but is now backed by the store; `storeTranscriptCorrections(_:) -> Error?` keeps its existing signature too.

- [ ] **Step 1: Add the store property and one-time migration to `Settings`**

In `Settings.swift`, add a new UserDefaults key near the other `keyTranscriptCorrections*` keys (line 66-67):

```swift
    private static let keyTranscriptCorrections = "transcript_corrections"
    private static let keyTranscriptCorrectionsSyncFile = "transcript_corrections_sync_file"
    private static let keyDidMigrateTranscriptCorrectionsToSQLite = "did_migrate_transcript_corrections_to_sqlite_v1"
```

Add the stored property and migration call to the class, right after `private let defaults: UserDefaults` (line 88):

```swift
    private let defaults: UserDefaults
    let vocabularyStore: VocabularyStore
```

Change `init` (line 92-94) to build the store and run the one-time migration:

```swift
    init(defaults: UserDefaults = .standard, vocabularyStore: VocabularyStore? = nil) {
        self.defaults = defaults
        self.vocabularyStore = vocabularyStore ?? Self.openDefaultVocabularyStore()
        migrateLegacyTranscriptCorrectionsIfNeeded()
    }

    /// A writable Application Support directory is a basic launch
    /// precondition this app already relies on elsewhere (model files,
    /// logs) — not a scenario worth chained fallbacks for. The one
    /// fallback kept here is an in-memory store so a single bad launch
    /// degrades to "corrections don't persist this run" instead of a
    /// crash, since corrections are a convenience feature, not core
    /// dictation functionality.
    private static func openDefaultVocabularyStore() -> VocabularyStore {
        do {
            let dbURL = try superDictateApplicationSupportDirectory()
                .appendingPathComponent("corrections.sqlite", isDirectory: false)
            return try VocabularyStore(fileURL: dbURL)
        } catch {
            log("settings: failed to open vocabulary store at the app support path, falling back to an in-memory store for this run: \(error)")
            return VocabularyStore.inMemoryFallback()
        }
    }

    private func migrateLegacyTranscriptCorrectionsIfNeeded() {
        guard !defaults.bool(forKey: Self.keyDidMigrateTranscriptCorrectionsToSQLite) else { return }
        defer { defaults.set(true, forKey: Self.keyDidMigrateTranscriptCorrectionsToSQLite) }

        guard let data = defaults.data(forKey: Self.keyTranscriptCorrections) else { return }
        do {
            let legacy = try TranscriptCorrectionsTransfer.decode(data)
            for correction in normalizedTranscriptCorrections(legacy) {
                _ = try? vocabularyStore.upsert(source: correction.source, replacement: correction.replacement, origin: .manual)
            }
            defaults.removeObject(forKey: Self.keyTranscriptCorrections)
            log("settings: migrated \(legacy.count) legacy transcript corrections into SQLite")
        } catch {
            log("settings: legacy transcript correction migration failed, leaving UserDefaults copy in place: \(error)")
        }
    }
```

`VocabularyStore.inMemoryFallback()` doesn't exist yet — add it in `VocabularyStore.swift` right after `init(fileURL:)` as a last-resort constructor that can't itself throw, for this one call site:

```swift
    /// Last-resort constructor for the (expected-never) case where even
    /// FileManager.default.temporaryDirectory isn't writable. SQLite's
    /// special ":memory:" filename opens a private in-memory database
    /// instead of touching disk at all, so this cannot fail the way
    /// init(fileURL:) can.
    static func inMemoryFallback() -> VocabularyStore {
        // Force-unwrap is safe: ":memory:" always succeeds in SQLite,
        // and createSchema() against a fresh in-memory DB cannot fail.
        try! VocabularyStore(fileURL: URL(fileURLWithPath: ":memory:"))
    }
```

- [ ] **Step 2: Rewire `transcriptCorrections` and `storeTranscriptCorrections` onto the store**

Replace lines 656-692 (the existing `transcriptCorrections` property and `storeTranscriptCorrections` function shown in the codebase today) with:

```swift
    var transcriptCorrections: [TranscriptCorrection] {
        get {
            vocabularyStore.all().map { TranscriptCorrection(source: $0.source, replacement: $0.replacement) }
        }
        set { storeTranscriptCorrections(newValue) }
    }

    /// Persists corrections and reports failure to the caller instead
    /// of swallowing it, matching the pre-SQLite contract this replaces.
    /// With SQLite there is no encode/size-limit failure mode left (each
    /// row is capped and validated by `normalizedTranscriptCorrections`
    /// before it reaches here), so this always returns nil today; the
    /// `Error?` return type is kept because call sites throughout
    /// ParakeyApp.swift already branch on it.
    @discardableResult
    func storeTranscriptCorrections(_ newValue: [TranscriptCorrection]) -> Error? {
        let corrections = normalizedTranscriptCorrections(newValue)
        vocabularyStore.replaceAllPreservingOrigin(corrections)
        return nil
    }
```

- [ ] **Step 3: Build**

Run: `cd swift && swift build`
Expected: builds cleanly. `TranscriptCorrector.apply`, the menu-bar corrections list, import/export/sync in `ParakeyApp.swift` all keep compiling unchanged since `Settings.transcriptCorrections`'s type didn't change.

- [ ] **Step 4: Manual migration sanity check**

Run: `cd swift && swift run Parakey --self-test corrections` (the existing `testTranscriptCorrections` suite from `SelfTest.swift:71-72`)
Expected: `PASS corrections` — this suite already exercises `Settings.transcriptCorrections` get/set round-tripping and must keep passing unchanged, proving the SQLite-backed property behaves like the old UserDefaults one for the existing test.

- [ ] **Step 5: Commit**

```bash
git add swift/Sources/Parakey/Settings.swift swift/Sources/Parakey/VocabularyStore.swift
git commit -m "feat(vocabulary): back Settings.transcriptCorrections with VocabularyStore, migrate legacy UserDefaults data"
```

---

### Task 4: Pure word-diff learn-candidate detector

**Files:**
- Create: `swift/Sources/Parakey/VocabularyLearning.swift`

**Interfaces:**
- Produces:
  - `struct LearnCandidate: Equatable { let source: String; let replacement: String }`
  - `enum LearnCandidateDetector { static let maxSpanWords: Int; static func candidate(insertedText: String, editedText: String) -> LearnCandidate? }`

- [ ] **Step 1: Write `VocabularyLearning.swift` with the detector**

```swift
// SuperDictate — automatic vocabulary learning from post-insertion edits.
// See docs/superpowers/specs/2026-08-11-vocabulary-learning-design.md.

import Foundation

struct LearnCandidate: Equatable {
    let source: String
    let replacement: String
}

/// Pure word-level diff: given the text SuperDictate inserted and the text
/// now sitting in that same region after the user edited it, decides
/// whether the edit looks like a vocabulary correction (a short,
/// contiguous word/phrase swap) as opposed to a general prose edit.
enum LearnCandidateDetector {
    static let maxSpanWords = 3

    static func candidate(insertedText: String, editedText: String) -> LearnCandidate? {
        let insertedWords = words(in: insertedText)
        let editedWords = words(in: editedText)
        guard !insertedWords.isEmpty, !editedWords.isEmpty else { return nil }

        let commonPrefix = commonPrefixCount(insertedWords, editedWords)
        let commonSuffix = commonSuffixCount(
            insertedWords, editedWords,
            skippingPrefix: commonPrefix
        )

        let oldSpan = Array(insertedWords[commonPrefix..<(insertedWords.count - commonSuffix)])
        let newSpan = Array(editedWords[commonPrefix..<(editedWords.count - commonSuffix)])

        guard !oldSpan.isEmpty, !newSpan.isEmpty else { return nil }
        guard oldSpan.count <= maxSpanWords, newSpan.count <= maxSpanWords else { return nil }

        let source = oldSpan.joined(separator: " ")
        let replacement = newSpan.joined(separator: " ")
        guard source != replacement else { return nil }

        return LearnCandidate(source: source, replacement: replacement)
    }

    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func commonPrefixCount(_ lhs: [String], _ rhs: [String]) -> Int {
        var count = 0
        while count < lhs.count, count < rhs.count, lhs[count] == rhs[count] {
            count += 1
        }
        return count
    }

    private static func commonSuffixCount(_ lhs: [String], _ rhs: [String], skippingPrefix prefix: Int) -> Int {
        var count = 0
        while count < (lhs.count - prefix),
              count < (rhs.count - prefix),
              lhs[lhs.count - 1 - count] == rhs[rhs.count - 1 - count] {
            count += 1
        }
        return count
    }
}
```

- [ ] **Step 2: Write the self-test suite body (called from `SelfTest.swift` in Task 10) in the same file**

```swift
func testLearnCandidateDetector() throws {
    // Single-word transliteration fix: the motivating case.
    guard LearnCandidateDetector.candidate(
        insertedText: "напиши мне на инглиш пожалуйста",
        editedText: "напиши мне на English пожалуйста"
    ) == LearnCandidate(source: "инглиш", replacement: "English") else {
        throw VocabularyLearningTestFailure("single-word transliteration edit not detected")
    }

    // Two-word phrase swap.
    guard LearnCandidateDetector.candidate(
        insertedText: "открой файл сейчас",
        editedText: "открой этот документ сейчас"
    ) == LearnCandidate(source: "файл", replacement: "этот документ") else {
        throw VocabularyLearningTestFailure("phrase-length edit not detected")
    }

    // No edit at all.
    guard LearnCandidateDetector.candidate(
        insertedText: "привет мир",
        editedText: "привет мир"
    ) == nil else {
        throw VocabularyLearningTestFailure("identical text should not produce a candidate")
    }

    // Full undo back to the original text.
    guard LearnCandidateDetector.candidate(
        insertedText: "тестовое сообщение",
        editedText: "тестовое сообщение"
    ) == nil else {
        throw VocabularyLearningTestFailure("undo back to original should not produce a candidate")
    }

    // Too-long edit (more than 3 words changed) is prose editing, not vocabulary.
    guard LearnCandidateDetector.candidate(
        insertedText: "это был очень длинный оригинальный текст",
        editedText: "это был совершенно другой полностью переписанный текст"
    ) == nil else {
        throw VocabularyLearningTestFailure("edits longer than maxSpanWords should not produce a candidate")
    }

    // Pure insertion (nothing removed) is not a vocabulary correction —
    // there is nothing to teach the model to say differently next time.
    guard LearnCandidateDetector.candidate(
        insertedText: "встреча завтра",
        editedText: "встреча ровно завтра"
    ) == nil else {
        throw VocabularyLearningTestFailure("pure insertion (no removed span) should not produce a candidate")
    }
}

struct VocabularyLearningTestFailure: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}
```

- [ ] **Step 3: Build**

Run: `cd swift && swift build`
Expected: builds cleanly.

- [ ] **Step 4: Commit**

```bash
git add swift/Sources/Parakey/VocabularyLearning.swift
git commit -m "feat(vocabulary): add pure word-diff learn-candidate detector"
```

---

### Task 5: `PostInsertionEditWatcher` (AXObserver-driven detection)

**Files:**
- Modify: `swift/Sources/Parakey/VocabularyLearning.swift`
- Modify: `swift/Sources/Parakey/ParakeyApp.swift` (wire the watcher in at the `TextInsertionService.insert` call site, `ParakeyApp.swift:2347` — see Step 2)

**Interfaces:**
- Consumes: `VocabularyStore.recordLearned`, `LearnCandidateDetector.candidate`, `FocusedTextTarget` (`element`, `application`, `elementPID`, `subrole`), `TextInsertionResult` (`TextInsertionService.swift:11-16`).
- Produces: `@MainActor final class PostInsertionEditWatcher { init(store: VocabularyStore, onLearned: @escaping (VocabularyRecord) -> Void); func beginWatching(insertedText: String, target: FocusedTextTarget); func stopWatching() }`

- [ ] **Step 1: Append `PostInsertionEditWatcher` to `VocabularyLearning.swift`**

```swift
import AppKit
import ApplicationServices

/// Watches the field SuperDictate just inserted text into for a short
/// window, and if the user immediately hand-corrects a short span of it,
/// reports a learn candidate. See docs/superpowers/specs/2026-08-11-vocabulary-learning-design.md
/// for the anchoring strategy this implements.
@MainActor
final class PostInsertionEditWatcher {
    static let watchWindowSeconds: TimeInterval = 45
    static let debounceSeconds: TimeInterval = 0.8
    private static let secureSubroles: Set<String> = ["AXSecureTextField"]

    private let store: VocabularyStore
    private let onLearned: (VocabularyRecord) -> Void

    private var observer: AXObserver?
    private var observedElement: AXUIElement?
    private var observedApplication: AXUIElement?
    private var insertedText: String = ""
    private var anchorPrefix: String = ""
    private var anchorSuffix: String = ""
    private var debounceTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?

    init(store: VocabularyStore, onLearned: @escaping (VocabularyRecord) -> Void) {
        self.store = store
        self.onLearned = onLearned
    }

    func beginWatching(insertedText: String, target: FocusedTextTarget) {
        stopWatching()
        guard !insertedText.isEmpty else { return }
        guard !Self.secureSubroles.contains(target.subrole ?? "") else { return }
        guard let anchor = computeAnchor(insertedText: insertedText, element: target.element) else { return }

        var createdObserver: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<PostInsertionEditWatcher>.fromOpaque(refcon).takeUnretainedValue()
            let notificationName = notification as String
            Task { @MainActor in
                watcher.handleNotification(notificationName, element: element)
            }
        }
        guard AXObserverCreate(target.elementPID, callback, &createdObserver) == .success,
              let observer = createdObserver else {
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let valueResult = AXObserverAddNotification(observer, target.element, kAXValueChangedNotification as CFString, refcon)
        guard valueResult == .success else { return }
        _ = AXObserverAddNotification(observer, target.application, kAXFocusedUIElementChangedNotification as CFString, refcon)

        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)

        self.observer = observer
        self.observedElement = target.element
        self.observedApplication = target.application
        self.insertedText = insertedText
        self.anchorPrefix = anchor.prefix
        self.anchorSuffix = anchor.suffix

        expiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.watchWindowSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.stopWatching()
        }
    }

    func stopWatching() {
        expiryTask?.cancel()
        expiryTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedElement = nil
        observedApplication = nil
        insertedText = ""
        anchorPrefix = ""
        anchorSuffix = ""
    }

    /// Reads the field's value and cursor position immediately after
    /// insertion to compute the exact region that was just inserted,
    /// expressed as the surrounding text that must stay unchanged for a
    /// later diff to be trusted. Returns nil if the field's attributes
    /// aren't readable or the math doesn't add up (never guess).
    private func computeAnchor(insertedText: String, element: AXUIElement) -> (prefix: String, suffix: String)? {
        guard let fieldValue = stringAttribute(element, kAXValueAttribute as CFString) else { return nil }
        guard let cursorRange = rangeAttribute(element, kAXSelectedTextRangeAttribute as CFString) else { return nil }

        let fieldNSString = fieldValue as NSString
        let insertedLength = (insertedText as NSString).length
        let insertionEnd = cursorRange.location
        let insertionStart = insertionEnd - insertedLength
        guard insertionStart >= 0, insertionEnd <= fieldNSString.length else { return nil }

        let prefix = fieldNSString.substring(to: insertionStart)
        let suffix = fieldNSString.substring(from: insertionEnd)
        return (prefix, suffix)
    }

    private func handleNotification(_ notification: String, element: AXUIElement) {
        guard observer != nil else { return }
        if notification == (kAXFocusedUIElementChangedNotification as String) {
            stopWatching()
            return
        }
        guard notification == (kAXValueChangedNotification as String) else { return }

        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.debounceSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.evaluateEdit()
        }
    }

    private func evaluateEdit() {
        guard let observedElement else { return }
        defer { stopWatching() }

        guard let currentValue = stringAttribute(observedElement, kAXValueAttribute as CFString) else { return }
        guard currentValue.hasPrefix(anchorPrefix), currentValue.hasSuffix(anchorSuffix) else {
            // The user edited outside the region SuperDictate inserted,
            // or the field's surrounding structure changed — can't
            // safely isolate what changed, so don't guess.
            return
        }

        let currentNSString = currentValue as NSString
        let prefixLength = (anchorPrefix as NSString).length
        let suffixLength = (anchorSuffix as NSString).length
        guard currentNSString.length >= prefixLength + suffixLength else { return }
        let middleRange = NSRange(location: prefixLength, length: currentNSString.length - prefixLength - suffixLength)
        let currentInsertedRegion = currentNSString.substring(with: middleRange)

        guard let candidate = LearnCandidateDetector.candidate(insertedText: insertedText, editedText: currentInsertedRegion) else {
            return
        }
        if let record = store.recordLearned(source: candidate.source, replacement: candidate.replacement) {
            onLearned(record)
        }
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success else { return nil }
        return raw as? String
    }

    private func rangeAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFRange? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success,
              let raw,
              CFGetTypeID(raw) == AXValueGetTypeID() else {
            return nil
        }
        let value = unsafeDowncast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range) else { return nil }
        return range
    }
}
```

- [ ] **Step 2: Locate the production call site**

The only production call to `TextInsertionService.insert(_:into:)` is `ParakeyApp.swift:2347`, inside `ParakeyApp` (`final class ParakeyApp: NSObject, NSApplicationDelegate, NSWindowDelegate`, `@MainActor`, declared at `ParakeyApp.swift:41`):

```swift
                        if let textInsertionTarget {
                            let result = TextInsertionService().insert(textToInsert, into: textInsertionTarget)
                            focusedTargetResult = result
                            route = textInsertionRoute(
                                for: result,
                                targetElementStillValid: isAXElementStillValid(textInsertionTarget.element)
                            )
                        }
```

`textToInsert` is the exact string that was inserted; `textInsertionTarget` is the `FocusedTextTarget` (already unwrapped as non-nil inside this `if let`). This is the only place in the codebase that produces both of the values `PostInsertionEditWatcher.beginWatching` needs together with a live `TextInsertionResult`; self-tests construct `TextInsertionService` separately and are not insertion points to wire this into.

- [ ] **Step 3: Wire `PostInsertionEditWatcher` into that call site**

Add two stored properties to `ParakeyApp` (near wherever it already stores other long-lived service objects, e.g. alongside `pendingTextInsertionTarget`):

```swift
    private let postInsertionWatcher = PostInsertionEditWatcher(store: Settings.shared.vocabularyStore, onLearned: { _ in })
```

The `onLearned` closure above is a temporary placeholder that Task 6 replaces — Swift's stored-property initializer runs before `self` exists, so it cannot capture `self` directly here. Instead, give `PostInsertionEditWatcher` its real callback lazily in `ParakeyApp`'s existing setup/init method (wherever it already wires up other one-time callbacks) rather than in the property initializer:

```swift
    private lazy var postInsertionWatcher = PostInsertionEditWatcher(
        store: settings.vocabularyStore,
        onLearned: { [weak self] record in self?.showVocabularyLearnedToast(record) }
    )
```

(`lazy var` defers construction to first access, by which point `self` and `settings` both exist — use `lazy var`, not a plain stored `let` with the eager placeholder shown first above; that first snippet was illustrating the problem, not the fix.)

Immediately after the `if let textInsertionTarget { ... }` block shown in Step 2, add:

```swift
                        if let textInsertionTarget,
                           settings.autoLearnVocabularyEnabled,
                           focusedTargetResult == .insertedUsingSelectedText || focusedTargetResult == .insertedUsingValueAndRange {
                            postInsertionWatcher.beginWatching(insertedText: textToInsert, target: textInsertionTarget)
                        }
```

(`settings.autoLearnVocabularyEnabled` is added in Task 7 — this task's build step will fail to compile against that one name until Task 7 lands, which is expected and acceptable mid-plan since tasks execute in order; if running this task standalone, temporarily replace it with `true` inline, to be replaced by the real property in Task 7. `showVocabularyLearnedToast` is added to `ParakeyApp` in Task 6; until then, add a temporary private stub `private func showVocabularyLearnedToast(_ record: VocabularyRecord) {}` so the `lazy var` above compiles, and delete the stub once Task 6 supplies the real implementation.)

- [ ] **Step 4: Build**

Run: `cd swift && swift build`
Expected: builds cleanly once the Task 6/7 stubs (or real implementations, if done in order) are in place.

- [ ] **Step 5: Commit**

```bash
git add swift/Sources/Parakey/VocabularyLearning.swift swift/Sources/Parakey/RecordingLifecycle.swift
git commit -m "feat(vocabulary): add PostInsertionEditWatcher and wire it into the insertion path"
```

---

### Task 6: Undo-able HUD toast for learned corrections

**Files:**
- Create: `swift/Sources/Parakey/VocabularyLearnedToast.swift`
- Modify: `swift/Sources/Parakey/ParakeyApp.swift` (owns `postInsertionWatcher` from Task 5; add `showVocabularyLearnedToast(_:)` there, removing the Task 5 stub)

**Interfaces:**
- Consumes: `VocabularyRecord`, `VocabularyStore.delete(id:)`.
- Produces: `@MainActor final class VocabularyLearnedToastController { func show(_ record: VocabularyRecord, store: VocabularyStore) }`

- [ ] **Step 1: Write the toast controller and panel**

```swift
// SuperDictate — small auto-dismissing HUD toast shown right after
// PostInsertionEditWatcher learns a new correction, with an "Undo" button
// that deletes the just-learned row within a short window.

import AppKit

@MainActor
final class VocabularyLearnedToastController {
    private static let autoDismissSeconds: TimeInterval = 7
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    func show(_ record: VocabularyRecord, store: VocabularyStore) {
        dismissTask?.cancel()
        panel?.orderOut(nil)

        let panel = Self.makePanel()
        let content = Self.makeContentView(
            record: record,
            onUndo: { [weak self] in
                store.delete(id: record.id)
                self?.dismiss()
            }
        )
        panel.contentView = content
        Self.positionBottomRight(panel)
        panel.orderFrontRegardless()
        self.panel = panel

        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.autoDismissSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 64),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        return panel
    }

    private static func makeContentView(record: VocabularyRecord, onUndo: @escaping () -> Void) -> NSView {
        let container = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 340, height: 64))
        container.material = .hudWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "Запомнил: «\(record.source)» → «\(record.replacement)»")
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2

        let undoButton = NSButton(title: "Отменить", target: nil, action: nil)
        undoButton.bezelStyle = .rounded
        undoButton.keyEquivalent = "\u{1b}"
        let action = UndoButtonAction(handler: onUndo)
        undoButton.target = action
        undoButton.action = #selector(UndoButtonAction.perform)
        objc_setAssociatedObject(undoButton, &UndoButtonAction.associationKey, action, .OBJC_ASSOCIATION_RETAIN)

        stack.addArrangedSubview(label)
        stack.addArrangedSubview(undoButton)
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    private static func positionBottomRight(_ panel: NSPanel) {
        guard let screenFrame = NSScreen.main?.visibleFrame else { return }
        let origin = NSPoint(
            x: screenFrame.maxX - panel.frame.width - 24,
            y: screenFrame.minY + 24
        )
        panel.setFrameOrigin(origin)
    }
}

/// NSButton's target must be an NSObject; this wraps a Swift closure so
/// the toast controller doesn't need to become one itself.
private final class UndoButtonAction: NSObject {
    static var associationKey: UInt8 = 0
    let handler: () -> Void
    init(handler: @escaping () -> Void) { self.handler = handler }
    @objc func perform() { handler() }
}
```

- [ ] **Step 2: Wire `showVocabularyLearnedToast` at the Task 5 call site**

In `ParakeyApp.swift`, add a stored property `private let vocabularyLearnedToastController = VocabularyLearnedToastController()` and the method:

```swift
    private func showVocabularyLearnedToast(_ record: VocabularyRecord) {
        vocabularyLearnedToastController.show(record, store: settings.vocabularyStore)
    }
```

Remove the temporary empty-stub version of this method added in Task 5 Step 3 if one was left in place.

- [ ] **Step 3: Build**

Run: `cd swift && swift build`
Expected: builds cleanly.

- [ ] **Step 4: Commit**

```bash
git add swift/Sources/Parakey/VocabularyLearnedToast.swift
git commit -m "feat(vocabulary): add undo-able HUD toast for auto-learned corrections"
```

---

### Task 7: Settings toggle to enable/disable auto-learning

**Files:**
- Modify: `swift/Sources/Parakey/Settings.swift`
- Modify: `swift/Sources/Parakey/ControlPanel.swift` (add the toggle row to the existing settings panel `NSStackView`)

**Interfaces:**
- Produces: `Settings.autoLearnVocabularyEnabled: Bool` (default `true`).

- [ ] **Step 1: Add the setting**

In `Settings.swift`, add a key next to `keyDidMigrateTranscriptCorrectionsToSQLite` (from Task 3):

```swift
    private static let keyAutoLearnVocabularyEnabled = "auto_learn_vocabulary_enabled_v1"
```

Add the property near `transcriptCorrections`:

```swift
    var autoLearnVocabularyEnabled: Bool {
        get {
            defaults.object(forKey: Self.keyAutoLearnVocabularyEnabled) as? Bool ?? true
        }
        set { defaults.set(newValue, forKey: Self.keyAutoLearnVocabularyEnabled) }
    }
```

- [ ] **Step 2: Add the row to the Settings panel**

In `ControlPanel.swift`, find `correctionsInfoRow()` (referenced at `ControlPanel.swift:405` in the `root.addArrangedSubview(...)` list and defined at `ControlPanel.swift:1523`). Add a new row function modeled on the existing boolean-toggle rows in that file (e.g. `muteWhileRecordingRow(draft)` or `normalizeNumbersToDigitsRow` — read one of those for the exact `NSSwitch`/`NSButton` + label + binding-to-`draft` pattern already used in this file) named `autoLearnVocabularyRow(_ draft: SettingsDraft)`, with label text `t("Автоматически учить словарь по вашим правкам", "Automatically learn vocabulary from your edits")` (matching the `t(ru, en)` localization helper already used throughout this file — grep `func t(` in `Localization.swift` to confirm its exact signature before using it), bound to `draft.autoLearnVocabularyEnabled` the same way the neighboring toggle rows bind to their `draft` fields.

Add it to the stack right after `correctionsInfoRow()`:

```swift
        root.addArrangedSubview(correctionsInfoRow())
        root.addArrangedSubview(autoLearnVocabularyRow(draft))
```

Follow whatever `SettingsDraft` commit pattern the existing toggle rows use (a `draft` struct mutated in place and persisted on the panel's existing Save/Apply action) so this new field round-trips through the same commit path as every other setting on this panel — do not invent a separate save mechanism for just this one toggle.

- [ ] **Step 3: Gate `PostInsertionEditWatcher` registration on the toggle**

Confirm the `if settings.autoLearnVocabularyEnabled, ...` guard added in Task 5 Step 3 is in place at the insertion call site (it already references this property by name in anticipation of this task).

- [ ] **Step 4: Build**

Run: `cd swift && swift build`
Expected: builds cleanly.

- [ ] **Step 5: Manual check**

Run: `cd swift && swift run Parakey --self-test corrections`
Expected: `PASS corrections` (unaffected by this change, confirms nothing in the settings panel wiring broke the existing corrections suite).

- [ ] **Step 6: Commit**

```bash
git add swift/Sources/Parakey/Settings.swift swift/Sources/Parakey/ControlPanel.swift
git commit -m "feat(vocabulary): add Settings toggle for automatic vocabulary learning"
```

---

### Task 8: `VocabularyManagerWindow` — full CRUD table window

**Files:**
- Create: `swift/Sources/Parakey/VocabularyManagerWindow.swift`
- Modify: `swift/Sources/Parakey/ControlPanel.swift` (open button)

**Interfaces:**
- Consumes: `VocabularyStore` (Task 1-2), `VocabularyRecord`, `showCorrectionEditor(existing:)`-style add/edit dialog pattern already in `ParakeyApp.swift:5684` (reuse its two-text-field `NSAlert` layout rather than inventing a new one — read that function before writing this task's editor dialog so the two match visually).
- Produces: `@MainActor final class VocabularyManagerWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate { func show() }`

- [ ] **Step 1: Write the window controller**

```swift
// SuperDictate — full manual CRUD window for the vocabulary/text-corrections
// store, opened from the Settings panel. Table view over VocabularyStore;
// add/edit/delete operate directly on the store (not through
// Settings.transcriptCorrections, so origin/created_at are preserved
// exactly as VocabularyStore tracks them).

import AppKit

@MainActor
final class VocabularyManagerWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let store: VocabularyStore
    private var window: NSWindow?
    private var tableView: NSTableView?
    private var records: [VocabularyRecord] = []

    init(store: VocabularyStore) {
        self.store = store
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            reload()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Словарь / Text Corrections"
        window.delegate = self
        window.contentView = buildContentView()
        window.center()
        self.window = window
        reload()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        tableView = nil
    }

    private func buildContentView() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        root.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let tableView = NSTableView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true

        let sourceColumn = NSTableColumn(identifier: .init("source"))
        sourceColumn.title = "Оригинал"
        sourceColumn.width = 180
        let replacementColumn = NSTableColumn(identifier: .init("replacement"))
        replacementColumn.title = "Замена"
        replacementColumn.width = 180
        let originColumn = NSTableColumn(identifier: .init("origin"))
        originColumn.title = "Источник"
        originColumn.width = 90
        let dateColumn = NSTableColumn(identifier: .init("date"))
        dateColumn.title = "Добавлено"
        dateColumn.width = 90

        tableView.addTableColumn(sourceColumn)
        tableView.addTableColumn(replacementColumn)
        tableView.addTableColumn(originColumn)
        tableView.addTableColumn(dateColumn)

        scrollView.documentView = tableView
        self.tableView = tableView

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let addButton = makeButton(title: "Добавить", action: #selector(addTapped))
        let editButton = makeButton(title: "Изменить", action: #selector(editTapped))
        let deleteButton = makeButton(title: "Удалить", action: #selector(deleteTapped))
        let importButton = makeButton(title: "Импорт…", action: #selector(importTapped))
        let exportButton = makeButton(title: "Экспорт…", action: #selector(exportTapped))

        [addButton, editButton, deleteButton, importButton, exportButton].forEach { buttonRow.addArrangedSubview($0) }

        root.addArrangedSubview(scrollView)
        root.addArrangedSubview(buttonRow)

        NSLayoutConstraint.activate([
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])

        return root
    }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func reload() {
        records = store.all()
        tableView?.reloadData()
    }

    // MARK: - NSTableViewDataSource / NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int { records.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard records.indices.contains(row), let identifier = tableColumn?.identifier else { return nil }
        let record = records[row]
        let text: String
        switch identifier.rawValue {
        case "source": text = record.source
        case "replacement": text = record.replacement
        case "origin": text = record.origin == .learned ? "выучено" : "вручную"
        case "date": text = String(record.createdAt.prefix(10))
        default: text = ""
        }
        let field = NSTextField(labelWithString: text)
        return field
    }

    // MARK: - Actions

    @objc private func addTapped() {
        guard let pair = promptForCorrection(existingSource: "", existingReplacement: "") else { return }
        _ = try? store.upsert(source: pair.source, replacement: pair.replacement, origin: .manual)
        reload()
    }

    @objc private func editTapped() {
        guard let tableView, tableView.selectedRow >= 0, records.indices.contains(tableView.selectedRow) else { return }
        let record = records[tableView.selectedRow]
        guard let pair = promptForCorrection(existingSource: record.source, existingReplacement: record.replacement) else { return }
        if pair.source.lowercased() != record.source.lowercased() {
            store.delete(id: record.id)
        }
        _ = try? store.upsert(source: pair.source, replacement: pair.replacement, origin: record.origin)
        reload()
    }

    @objc private func deleteTapped() {
        guard let tableView, tableView.selectedRow >= 0, records.indices.contains(tableView.selectedRow) else { return }
        store.delete(id: records[tableView.selectedRow].id)
        reload()
    }

    private func promptForCorrection(existingSource: String, existingReplacement: String) -> (source: String, replacement: String)? {
        let alert = NSAlert()
        alert.messageText = "Text Correction"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 8
        container.frame = NSRect(x: 0, y: 0, width: 280, height: 60)

        let sourceField = NSTextField(string: existingSource)
        sourceField.placeholderString = "Model said…"
        let replacementField = NSTextField(string: existingReplacement)
        replacementField.placeholderString = "Should say…"
        container.addArrangedSubview(sourceField)
        container.addArrangedSubview(replacementField)
        alert.accessoryView = container

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let source = sourceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = replacementField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !replacement.isEmpty else { return nil }
        return (source, replacement)
    }

    @objc private func importTapped() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [TranscriptCorrectionsTransfer.contentType]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let imported = try? TranscriptCorrectionsTransfer.read(from: url) else {
            presentError("Could not read that corrections file.")
            return
        }
        for correction in normalizedTranscriptCorrections(imported) {
            _ = try? store.upsert(source: correction.source, replacement: correction.replacement, origin: .manual)
        }
        reload()
    }

    @objc private func exportTapped() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [TranscriptCorrectionsTransfer.contentType]
        panel.nameFieldStringValue = "corrections"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let corrections = records.map { TranscriptCorrection(source: $0.source, replacement: $0.replacement) }
        do {
            try TranscriptCorrectionsTransfer.write(corrections, to: url)
        } catch {
            presentError("Could not save that corrections file: \(error.localizedDescription)")
        }
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.runModal()
    }
}
```

- [ ] **Step 2: Add the open entry point to `ControlPanel.swift`**

Add a stored property to `SuperDictateControlPanelApp` (near `private var settingsWindow: NSWindow?`, `ControlPanel.swift:127`):

```swift
    private lazy var vocabularyManagerWindowController = VocabularyManagerWindowController(store: Settings.shared.vocabularyStore)
```

Turn `correctionsInfoRow()` (`ControlPanel.swift:1523`) into a clickable row, or — matching this file's existing pattern for action rows — add a button next to its explanatory text with title "Открыть словарь…" wired to an `@objc` action:

```swift
    @objc private func openVocabularyManager() {
        vocabularyManagerWindowController.show()
    }
```

Wire that action to the new button using the same `NSButton(title:target:action:)` pattern the other action rows in this file already use (read one of the existing button-adding rows, e.g. inside `settingsActionsRow(draft:)`, for the exact construction/layout idiom before writing this button so it looks consistent).

- [ ] **Step 3: Build**

Run: `cd swift && swift build`
Expected: builds cleanly.

- [ ] **Step 4: Commit**

```bash
git add swift/Sources/Parakey/VocabularyManagerWindow.swift swift/Sources/Parakey/ControlPanel.swift
git commit -m "feat(vocabulary): add Vocabulary manager window with CRUD, import, and export"
```

---

### Task 9: Self-test suites

**Files:**
- Modify: `swift/Sources/Parakey/SelfTest.swift`

**Interfaces:**
- Consumes: `VocabularyStore` (Task 1-2), `LearnCandidateDetector`/`testLearnCandidateDetector()` (Task 4), `TranscriptCorrection`.

- [ ] **Step 1: Add `vocabulary-store` and `vocabulary-learning` suites to the `case` switch**

Find the `case "corrections":` line (`SelfTest.swift:71-72`) and add two new cases right after it:

```swift
        case "corrections":
            return runSuite("corrections", testTranscriptCorrections)
        case "vocabulary-store":
            return runSuite("vocabulary-store", testVocabularyStore)
        case "vocabulary-learning":
            return runSuite("vocabulary-learning", testLearnCandidateDetector)
```

- [ ] **Step 2: Write `testVocabularyStore()`**

Add this function to `SelfTest.swift` (or a `SelfTestVocabulary.swift` extension file if `SelfTest.swift`'s existing test functions already live split across files that way — grep `func testTranscriptCorrections` first to see which file it's actually defined in today, and put this next to it):

```swift
func testVocabularyStore() throws {
    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("vocabulary-store-selftest-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let store = try VocabularyStore(fileURL: tempURL)

    // Manual upsert + dedup by source (case-insensitive).
    let first = try store.upsert(source: "инглиш", replacement: "English", origin: .manual)
    guard first.origin == .manual else { throw VocabularyLearningTestFailure("expected manual origin") }
    let updated = try store.upsert(source: "Инглиш", replacement: "english", origin: .manual)
    guard store.count() == 1, updated.replacement == "english" else {
        throw VocabularyLearningTestFailure("case-insensitive upsert should update the existing row, not add a second one")
    }

    // recordLearned: no-op when source already known.
    guard store.recordLearned(source: "инглиш", replacement: "English") == nil else {
        throw VocabularyLearningTestFailure("recordLearned should no-op for an already-known source")
    }

    // recordLearned: succeeds for a new source, tagged 'learned'.
    guard let learned = store.recordLearned(source: "кложа", replacement: "closure"), learned.origin == .learned else {
        throw VocabularyLearningTestFailure("recordLearned should insert a new source tagged learned")
    }
    guard store.count() == 2 else { throw VocabularyLearningTestFailure("expected 2 rows after recordLearned") }

    // delete(id:)
    store.delete(id: learned.id)
    guard store.count() == 1 else { throw VocabularyLearningTestFailure("delete(id:) should remove exactly one row") }

    // replaceAllPreservingOrigin: preserves origin/created_at for kept rows, drops missing ones, adds new ones as manual.
    _ = try store.upsert(source: "старое", replacement: "old", origin: .learned)
    store.replaceAllPreservingOrigin([
        TranscriptCorrection(source: "инглиш", replacement: "English (edited)"),
        TranscriptCorrection(source: "новое", replacement: "new"),
    ])
    let all = store.all()
    guard all.count == 2 else { throw VocabularyLearningTestFailure("replaceAllPreservingOrigin should leave exactly the given sources") }
    guard let englishRow = all.first(where: { $0.source.lowercased() == "инглиш" }), englishRow.replacement == "English (edited)" else {
        throw VocabularyLearningTestFailure("replaceAllPreservingOrigin should update the replacement text for a kept source")
    }
    guard let newRow = all.first(where: { $0.source == "новое" }), newRow.origin == .manual else {
        throw VocabularyLearningTestFailure("replaceAllPreservingOrigin should tag brand-new sources as manual")
    }

    // Cap enforcement in recordLearned.
    let capStore = try VocabularyStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("vocabulary-store-cap-\(UUID().uuidString).sqlite"))
    defer { }
    for index in 0..<MAX_TRANSCRIPT_CORRECTIONS {
        _ = try capStore.upsert(source: "src\(index)", replacement: "rep\(index)", origin: .manual)
    }
    guard capStore.recordLearned(source: "one-too-many", replacement: "nope") == nil else {
        throw VocabularyLearningTestFailure("recordLearned must not exceed MAX_TRANSCRIPT_CORRECTIONS")
    }
}
```

- [ ] **Step 3: Run both new suites**

Run: `cd swift && swift run Parakey --self-test vocabulary-store`
Expected: `PASS vocabulary-store`

Run: `cd swift && swift run Parakey --self-test vocabulary-learning`
Expected: `PASS vocabulary-learning`

If either fails, fix the implementation (Task 1/2/4) — do not weaken the assertions.

- [ ] **Step 4: Run the full existing self-test list to confirm no regression**

Run: `cd swift && swift run Parakey --self-test corrections`
Expected: `PASS corrections` (still, per Task 3's Step 4 — re-confirming here after all subsequent tasks landed).

- [ ] **Step 5: Commit**

```bash
git add swift/Sources/Parakey/SelfTest.swift
git commit -m "test(vocabulary): add vocabulary-store and vocabulary-learning self-test suites"
```

---

### Task 10: Manual live verification and CHANGELOG entry

**Files:**
- Modify: `swift/Sources/Parakey/SelfTest.swift` (optional `vocabulary-learning-live` suite, mirroring the existing `insertion-target-live` pattern referenced in the design spec)
- Modify: `CHANGELOG.md`

**Interfaces:** None new — this task closes out the plan with real-machine verification and release notes, no further production code.

- [ ] **Step 1: Local install on the target Mac**

Per `AGENTS.md`, run the project's standard local install script (do not create a copied/test `.app`):

Run: `./scripts/install-local.sh`

- [ ] **Step 2: Manual end-to-end check**

With the real installed app running: dictate a short phrase into a plain-text field (e.g. TextEdit or Notes) that you know the model will render with a Cyrillic-spelled English word, then immediately hand-correct just that one word back to Latin script. Confirm:
1. The undo toast appears within ~1 second of finishing the edit, showing the exact source/replacement pair.
2. Dictating the same phrase again a few seconds later produces the corrected word directly, with no manual fix needed.
3. Opening the Vocabulary window (Task 8) from Settings shows the new row tagged "выучено", editable and deletable like any manual row.
4. Clicking "Отменить" on a *fresh* toast (test this on a second phrase) removes the row — confirm via the Vocabulary window that it's gone.

If any of these fail, use `superpowers:systematic-debugging` before touching code further — do not patch symptoms.

- [ ] **Step 3: Add a CHANGELOG entry**

Read the top of `CHANGELOG.md` for the current unreleased-section format and add an entry under it, in that same format, describing: automatic vocabulary learning from post-insertion edits, the new Vocabulary manager window in Settings, and the move from UserDefaults to a local SQLite store for text corrections (mention the automatic one-time migration, since existing users' manual corrections must visibly survive the upgrade).

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: add changelog entry for automatic vocabulary learning"
```
