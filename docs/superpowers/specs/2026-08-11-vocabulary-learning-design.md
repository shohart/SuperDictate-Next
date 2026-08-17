# Design: Automatic personal-vocabulary learning (post-insertion edit tracking)

Date: 2026-08-11

## Background

Commercial dictation product Wispr Flow learns a user's vocabulary over time
so it stops mis-transcribing the words that person actually uses. SuperDictate
has no equivalent today. It does have a manual mechanism that is the natural
foundation to build on:

- `TranscriptCorrection` (`source` → `replacement` word/phrase pairs),
  applied post-transcription by `TranscriptCorrector` (`TranscriptRepair.swift`),
  stored as a JSON array in `UserDefaults` (`Settings.swift`,
  `keyTranscriptCorrections`), capped at `MAX_TRANSCRIPT_CORRECTIONS` (512).
- Manual CRUD + import/export/cross-Mac file sync already exists, but only as
  a flat `NSMenu` under the menu-bar icon ("Text Corrections"), backed by
  `TranscriptCorrectionsTransfer` (`CorrectionsTransfer.swift`) — a hardened
  JSON document format (`TranscriptCorrectionsDocument`, schema-versioned,
  size-capped, symlink-safe) used for export, import, and folder-based sync
  (Dropbox/iCloud/Syncthing).

The concrete failure mode motivating this: the ASR model frequently
transcribes English loanwords using Cyrillic phonetic spelling (e.g. writes
"инглиш" instead of "English"). Today the user has to notice this and type a
manual correction pair into the menu. The goal is for SuperDictate to notice
the user *fixing* this in place, right after dictation, and learn the pair
itself — no manual entry required, but never silently: the user always sees
what was learned and can undo it.

### Two mechanisms considered for "learning vocabulary", and why only one is in scope

1. **Post-insertion edit tracking (in scope).** Watch the text field
   SuperDictate just inserted into; if the user immediately hand-corrects a
   short span, save that as a new `TranscriptCorrection`. Pure post-processing,
   reuses the existing, already-hardened correction engine end to end.
2. **ASR-level context biasing / hotwords (explicitly out of scope for this
   branch).** Feeding a hotword list into the decoder so the model gets the
   word right on first pass (NeMo-style shallow fusion / trie-boosted beam
   search, or a context-biasing encoder). This would need to be implemented
   inside `parakeet.cpp`'s decoder (an upstream C++ change, not a Swift-side
   addition) and has real accuracy-regression risk if the bias weight is
   miscalibrated. Deferred to a possible future phase once it's confirmed
   whether the vendored `parakeet.cpp` decoder exposes anything like this.

## Design

### 1. Detection: `PostInsertionEditWatcher`

New file `VocabularyLearning.swift`. Hooked from
`TextInsertionService.insert(_:into:)` (`TextInsertionService.swift`) right
after a successful insertion that went through the AX value/range path (the
`insertUsingKeyboardEvents` simulated-typing fallback has no `AXUIElement` to
observe and is explicitly out of scope — no learning fires for that path).

- Registers an `AXObserver` for `kAXValueChangedNotification` on the target
  element, plus `kAXFocusedUIElementChangedNotification` on the owning
  application to know when focus leaves the field.
- Watch window: 45 seconds, or until focus leaves the field — whichever comes
  first. On expiry, the observer is torn down and nothing further is learned
  from that insertion.
- Value-changed notifications are debounced 800ms so a burst of keystrokes is
  diffed once, after the user's edit has stabilized, not on every keystroke.
- On a stabilized change, the current field value is diffed against the
  exact string that was inserted, anchored at the insertion range recorded by
  `TextInsertionService`. If the diff resolves to exactly one contiguous
  changed span, both the old and new span are ≤3 whitespace-separated words,
  and both are non-empty, it becomes a **learn candidate**: `source` = the
  original span (what the model produced), `replacement` = the user's typed
  span.
- Full undo (Cmd+Z restoring the original text) diffs to no change and
  produces no candidate. Edits spanning more than 3 words, spanning multiple
  non-contiguous ranges, or extending outside the originally-inserted range
  are treated as prose editing, not vocabulary correction, and ignored.
- Fields with a secure-text role/subrole are never observed (checked before
  registering the observer).

### 2. Storage: SQLite, JSON stays as the sync/interchange format

Today's `UserDefaults` JSON-array store is replaced by a local SQLite
database as the live store, per explicit decision: SQLite is the source of
truth for what the app actually applies; the existing JSON document format
(`TranscriptCorrectionsDocument`) remains the *only* format used for
export/import and folder-based cross-Mac sync — it is not replaced, because
a raw `.sqlite` file living in a synced folder is unsafe under concurrent
writers on two Macs (no serialization the sync client understands), while
the JSON path already has that safety worked out (`validateCorrectionSyncPath`,
symlink rejection, size caps, schema versioning).

- New SwiftPM `systemLibrary` target (`CSQLite`) linking the system
  `libsqlite3` via a small modulemap — no third-party dependency, consistent
  with `Package.swift`'s current `dependencies: []`.
- DB file: `~/Library/Application Support/SuperDictate/corrections.sqlite`
  (alongside the existing `APP_SUPPORT_DIR_NAME` directory).
- Schema (single table, no migrations framework needed at this scale):

  ```sql
  CREATE TABLE corrections (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      source TEXT NOT NULL,
      replacement TEXT NOT NULL,
      origin TEXT NOT NULL DEFAULT 'manual',   -- 'manual' | 'learned'
      created_at TEXT NOT NULL,                -- ISO 8601
      updated_at TEXT NOT NULL,
      UNIQUE (source COLLATE NOCASE)
  );
  ```

- `VocabularyStore.swift`: a thin wrapper over the C API (`insert`, `update`,
  `delete`, `list`, `deleteLast` for the toast's undo). No ORM.
- One-time migration on first launch after upgrade: read the existing
  `UserDefaults` `transcript_corrections` array, insert each entry into
  SQLite with `origin = 'manual'`, then clear the old UserDefaults key. Only
  runs once (guarded by a migration-done flag).
- `TranscriptCorrectionsTransfer`'s JSON encode/decode is kept as-is;
  export now reads from `VocabularyStore` instead of the settings array,
  import upserts parsed rows into `VocabularyStore` (imported rows are
  `origin = 'manual'`). All existing size/symlink/schema-version guards are
  reused unchanged.
- `TranscriptCorrector.apply` (the hot path used on every transcription)
  reads from `VocabularyStore` instead of `Settings.transcriptCorrections`.

### 3. UI: new "Vocabulary" tab in Control Panel

`ControlPanel.swift` gains a tab with an `NSTableView` listing all
corrections: source, replacement, origin (with a small badge for
`learned`), created date. Search/filter by substring. Row actions: **Add**,
**Edit**, **Delete**. Toolbar actions: **Import…** (existing JSON format,
existing file picker/merge-mode flow) and **Export…**.

The existing menu-bar "Text Corrections" submenu is kept as a quick-glance
list + shortcut into the new tab; it is no longer the primary place to
manage entries.

### 4. Learn-candidate UX: auto-save + undo toast

When `PostInsertionEditWatcher` produces a learn candidate:

- If a correction with the same `source` (case-insensitive) already exists,
  no-op (already known; the `UNIQUE` constraint would reject a duplicate
  insert anyway).
- If `VocabularyStore` is already at the 512-entry cap, no-op — auto-learning
  never evicts existing entries (manual or learned) to make room.
- Otherwise, insert immediately with `origin = 'learned'`, then show a HUD
  toast (reusing the existing HUD layer in `HUDViews.swift`): `Запомнил:
  "<source>" → "<replacement>"` with a highlighted **Отменить** button.
  Auto-dismisses after ~7 seconds. Clicking **Отменить** within that window
  deletes the just-inserted row (`VocabularyStore.deleteLast` scoped to that
  specific row id, not a generic "last row" that could race with a
  concurrent manual edit).

### 5. Settings toggle

A new toggle in Settings: "Автоматически учить словарь по вашим правкам",
default **on**. Turning it off disables `PostInsertionEditWatcher`
registration entirely (manual corrections and everything else in the
Vocabulary tab keep working). Everything here is local-only; no network
calls are introduced.

## Testing

No XCTest target exists in this project; verification goes through
`SelfTest.swift`'s command-line suites (per `AGENTS.md`, never through a
throwaway installed `.app`). New suites:

- `vocabulary-learning`: pure-function tests for the diff/candidate logic
  (given "inserted text" + "field value after edit" strings, assert the
  correct candidate is/isn't produced) — no real AX focus required.
- `vocabulary-store`: CRUD + migration + cap + dedup behavior against a
  temp SQLite file.
- A live/manual suite (`vocabulary-learning-live`, following the existing
  `insertion-target-live` pattern) for a human to sanity-check the real
  AXObserver path end-to-end on the target Mac.

## Out of scope

- ASR-level context biasing/hotwords in `parakeet.cpp` (see above) — a
  possible later phase, not part of this branch.
- CSV or any import format other than the existing Parakey JSON document.
- Any network sync / server-side account for vocabulary.
