# User hotword vocabulary - specification

**Status:** Waves 0–4 implemented and verified (§9.1–§9.4); the sync server is deployed (2026-11-06)
**Working branch:** `feat/user-hotword-vocabulary`  
**Base:** `origin/feat/asr-hotwords` at `4b69556` (v0.9.3)  
**Scope:** SuperDictate Next first. The later ASR-server transfer is explicitly out of scope for this branch.

## 1. Problem

SuperDictate currently learns a replacement only after a user corrects recognized text:

```text
recognized source -> corrected replacement
```

This remains valuable and must remain unchanged: it deterministically repairs known recognition errors during post-processing. On the hotwords branch, some `replacement` values are also selected as ASR hotwords.

That mechanism is insufficient for words users know in advance: debtor names, counterparties, court names, legal terms, place names, product names, abbreviations and other domain vocabulary. Those words may never first appear as a correction, yet the ASR decoder benefits from receiving them before recognition.

## 2. Product goal

Add a separate, persistent, user-managed **hotword vocabulary**. It stores phrases as correct words or expressions, rather than rewrite pairs.

At ASR start, SuperDictate builds one phrase list from both sources:

1. enabled phrases from the new user hotword vocabulary;
2. eligible correction-derived phrases from the existing `corrections` table.

The list is passed unchanged to the existing native trie/rollback hotword decoder. No decoder changes are part of this work.

## 3. Non-goals and invariants

- Do **not** remove or change correction-to-replacement learning.
- Do **not** convert user hotwords into replacement rules: an explicit hotword alone never changes text during post-processing.
- Do **not** modify `hotwords.cpp`, greedy decoding, trie rollback, or score semantics.
- When both sources are empty, `AsrHotwordsConfiguration` must be `.disabled`; decoder output must stay bit-identical to the no-hotword baseline.
- Existing ASR-hint controls on correction rows remain intact.
- macOS and Windows use the same SQLite schema, selection semantics and sync protocol.
- A phrase is sent to ASR exactly as the user entered it; do not lowercase or case-fold phrase output.

## 4. Data model

Add a second local SQLite table. The corrections table remains untouched except for existing migrations.

```sql
CREATE TABLE IF NOT EXISTS hotword_phrases (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    phrase     TEXT NOT NULL,
    enabled    INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL,   -- ISO-8601 UTC, VocabularyStore.timestamp()
    updated_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS hotword_phrases_phrase_unique
    ON hotword_phrases(phrase);

-- Local deletion markers for the account sync (mirrors deleted_corrections).
CREATE TABLE IF NOT EXISTS deleted_hotwords (
    key        TEXT PRIMARY KEY,   -- AsrHotwordSelection.customPhraseKey(phrase)
    phrase     TEXT NOT NULL,
    deleted_at TEXT NOT NULL       -- ISO-8601 UTC; an older stamp never overwrites a newer one
);
```

Timestamps are ISO-8601 text (not REAL) so they compare as strings in the last-writer-wins merge exactly like `corrections.updated_at`. Wave 1 created the table with REAL columns on development builds only; `CREATE TABLE IF NOT EXISTS` does not rewrite such a database (delete the hotword rows or the dev database; no released build had the REAL schema).

### 4.1 Phrase input rules

On create/update:

- trim leading and trailing whitespace;
- reject empty or punctuation-only values;
- retain original casing and internal spacing for stored/output phrase;
- reject more than four whitespace-separated words;
- reject phrases exceeding the decoder token limit after tokenization at the ASR boundary;
- deduplicate according to an explicit canonical comparison key (trim, collapse whitespace, case-insensitive). The first accepted spelling remains the stored/output spelling.

`enabled` permits retaining a phrase in the synchronized vocabulary while temporarily excluding it from ASR.

## 5. Selection and priority

Introduce one pure selection funnel, replacing the correction-only call site:

```swift
AsrHotwordSelection.combinedPhrases(
  corrections: [VocabularyRecord],
  custom: [HotwordPhraseRecord]
) -> [String]
```

Selection order:

1. enabled custom phrases, in stable user-record order;
2. eligible correction-derived hotwords using the existing `AsrHotwordSelection.phrases(from:)` policy;
3. deduplicate using the canonical comparison key; the first custom spelling wins against a correction-derived case/spacing variant. The legacy correction-only selector retains its existing exact-duplicate behavior; canonical folding is restricted to this combined funnel.
4. retain at most 1000 phrases.

A custom phrase does not have to satisfy the correction-specific `termLike` heuristic. It must meet the generic phrase hygiene rules. Custom phrases take priority at the 1000-phrase cap so a user-added debtor or legal term cannot be evicted by automatically learned data.

## 6. Store API (macOS first)

`VocabularyStore` gains a serial-queue-backed hotword API:

```swift
struct HotwordPhraseRecord: Equatable, Identifiable, Sendable {
    let id: Int64
    let phrase: String
    let enabled: Bool
    let createdAt: String   // ISO-8601 UTC
    let updatedAt: String
}

func hotwordPhrases() -> [HotwordPhraseRecord]
func addHotwordPhrase(_ phrase: String) throws -> HotwordPhraseRecord
func updateHotwordPhrase(id: Int64, phrase: String, enabled: Bool) throws -> HotwordPhraseRecord
func setHotwordPhraseEnabled(id: Int64, enabled: Bool) throws -> Bool
func deleteHotwordPhrase(id: Int64) throws -> Bool
func asrHotwordPhrases() -> [String] // now combines both sources
```

The migration must be idempotent for a fresh database, a database created before hotwords, and a database created after ASR hints were added. Store-open failure must retain the existing graceful fallback behavior.

## 7. UX

In `VocabularyManagerWindow`, add a distinct **ASR Hotwords** section/tab:

- add one phrase;
- import many phrases from a file;
- show phrase and enabled state;
- enable/disable without deleting;
- delete;
- explain that entries guide recognition but do not automatically replace text;
- explain the import file format.

Import format: a UTF-8 plain-text file, one phrase per line. Blank lines and lines starting with `#` are skipped; duplicates (already present or repeated in the file) are ignored. Each phrase is subject to the §4.1 input rules (a letter or digit, at most four words).

The existing corrections table/editor and its ASR-hint column are not repurposed.

## 8. Synchronization

The custom list must synchronize through the same account, trigger cadence, lock, backoff, and manual sync pathway as corrections:

- launch;
- five seconds after an edit;
- every 15 minutes;
- manual action.

The sync protocol receives a second collection of row changes inside the same payload (decided: a named second collection, no endpoint version bump):

- Request `POST /v1/vocabulary`: `{since, changes: [...], hotwords: [{phrase, enabled, deleted, updated_at}], client}`.
- Response (push and pull): `{revision, entries: [...], hotwords: [{phrase, enabled, deleted, updated_at, revision}]}`.
- **Same revision counter.** Hotword changes consume numbers from the account's single `revision`; one cursor (`vocabularySyncLastServerRevision`) covers both collections. Server table `hotword_entries(account_id, key, phrase, enabled, deleted, updated_at, revision)`, key = `normalized_key(phrase)` (NFC, casefold, collapsed whitespace; the client key is `customPhraseKey`).
- **Last writer wins** per key on the client-supplied `updated_at` (string compare); a tie keeps the existing copy (idempotent re-push). Remote apply preserves the remote `updated_at` and never calls `onLocalChange`.
- **Tombstones.** A local delete writes `deleted_hotwords` and travels as `deleted: true`; a rename tombstones the old key; re-adding clears the tombstone. A tombstone blocks an older-or-equal live entry and yields to a newer one. The server keeps deleted rows as `deleted = 1`.
- **Compatibility.** `hotwords` is optional in requests and defaults to `[]` in responses, so old clients (which ignore the field) and a new client against an old server (field absent, decoded as `[]`; an old server ignores the unknown request field) keep working. Hotwords are not appended to the server `events` log.
- **Caps.** The server limits live hotword rows per account to `VOCAB_SYNC_MAX_HOTWORD_ENTRIES` (default 5000, `MAX_HOTWORD_ENTRIES`). This is a storage cap, independent of the 1000-phrase ASR exposure cap, which still applies only to the list built for the decoder. The client has no local sync row cap.
- Pushes carry at most 1000 hotword changes per request, like corrections.

Server and Windows changes are separate follow-up waves, but their payload/schema must be designed before the macOS store API is frozen.

## 9. Delivery waves

### Wave 1 - macOS foundation

- SQLite schema/migration and `VocabularyStore` CRUD;
- pure combined selector;
- settings funnel uses the combined selector;
- self-tests for migration, CRUD, selection/dedup/cap and disabled-empty invariant.

#### 9.1 Wave 1 status (2026-11-05)

Implemented in `swift/Sources/Parakey/`: `VocabularyStore.swift` (`HotwordPhraseRecord`, `hotword_phrases` table created idempotently in `createSchema`, non-fatal on failure, CRUD API, `asrHotwordPhrases()` now combined; new `invalidPhrase`/`duplicatePhrase` errors), `AsrHotwordSelection.swift` (`customPhraseKey`, `normalizedCustomPhrase`, `combinedPhrases`, custom-first cap; correction-only `phrases(from:)` unchanged in behavior), `SelfTest.swift` (new block in `asr-hotwords`: migration, CRUD, dedup, disabled, cap, `.disabled`). `Settings.swift` needed no change: `asrHotwordsConfiguration` already calls `asrHotwordPhrases()`.

Known gaps: the decoder token-limit check (§4.1) is left to the ASR boundary and not implemented here; hotword edits call `onLocalChange` but were not synced until Wave 3 (§9.3).

Verification: passed on the remote Intel Mac Pro (macOS 26.7.1, Swift 6.3.2) from an isolated scratch copy of this worktree: `cd swift && swift run Parakey --self-test asr-hotwords` -> `PASS asr-hotwords`; `cd swift && swift run Parakey --self-test vocabulary-store` -> `PASS vocabulary-store`. The build completed successfully; only pre-existing Swift 6 concurrency and existing duplicate-case warnings were emitted. Local `git diff --check` is also clean.

### Wave 2 - macOS UX

- manager UI for the separate list;
- configuration refresh after add/edit/delete/enable;
- accessibility labels and UI smoke/self-tests where available.

#### 9.2 Wave 2 status (2026-11-05)

Implemented in `swift/Sources/Parakey/VocabularyManagerWindow.swift` only: the window content is now an `NSTabView` with the unchanged corrections editor (including its ASR-hint column) on the **Corrections** tab and a new **ASR Hotwords** tab. The tab has an explanation that hotwords only guide recognition and never replace text, a format note for file import, a table (enabled checkbox + phrase), an add field (Return or Add button), Delete, and an Import button that reads a UTF-8 text file (one phrase per line, `#` comments and blank lines skipped, duplicates ignored) and adds the phrases via `addHotwordPhrase`. Operations call `VocabularyStore.addHotwordPhrase` / `setHotwordPhraseEnabled` / `deleteHotwordPhrase`, which fire the existing `onLocalChange` themselves (nothing extra is wired in the UI); the lists are reloaded after every operation and on `VOCABULARY_CHANGED_NOTIFICATION`. Store errors (invalid/duplicate phrase, unavailable table) are shown via the existing alert; import reports an added/skipped summary. Controls carry accessibility labels. No edit-in-place (`updateHotwordPhrase` unused: delete + add). No new self-test: the window is AppKit-only and the repo has no UI self-test harness; store behavior is covered by Wave 1 tests. Configuration refresh needs no UI code: `Settings.asrHotwordsConfiguration` reads `asrHotwordPhrases()` on demand.

Verification (2026-11-05): passed on the remote Intel Mac Pro (macOS 26.7.1, Swift 6.3.2) from an isolated scratch copy: `cd swift && swift build` -> success; `swift run Parakey --self-test vocabulary-store` -> PASS; `swift run Parakey --self-test asr-hotwords` -> PASS. Existing project warnings about Swift concurrency and an existing duplicate self-test switch case remain, but no new build diagnostics were introduced. Manual interaction remains the release-gate check: via `scripts/install-local.sh` only (never a copied/test bundle), open the vocabulary window; add `Дунималова Анаида Георгиевна`; toggle it off/on; add a duplicate (expect alert); import a small UTF-8 file (expect an added-count summary and that `#` comments and duplicates are skipped); delete; confirm the Corrections tab and ASR-hint checkboxes behave as before.

### Wave 3 - synchronization contract

- extend `VocabularySync` and `server/vocab-sync` with custom-hotword changes;
- server round-trip/conflict tests;
- document request/response compatibility.

#### 9.3 Wave 3 status (2026-11-05)

Implemented, committed in this wave (§10 below):

- `swift/Sources/Parakey/VocabularyStore.swift`: hotword timestamps are ISO-8601 TEXT (`HotwordPhraseRecord.createdAt/updatedAt: String`); `deleted_hotwords` table, `HotwordTombstone`, `HotwordRemoteEntry`; `deleteHotwordPhrase` writes the tombstone and deletes the row in one transaction inside `queue.sync`; rename tombstones the old key, add clears the tombstone; `hotwordTombstones()`, `hotwordSyncChanges(since:)`, `applyRemoteHotwords(_:)` (last-writer-wins, tombstones respected, remote `updated_at` kept, no `onLocalChange`; remote phrases failing the §4.1 rules are skipped).
- `swift/Sources/Parakey/VocabularySync.swift`: `VocabularySyncHotwordEntry`; `VocabularySyncResponse.hotwords` (decoded as `[]` when absent); `push(..., hotwords:)`; `pass()` builds hotword changes (entries + tombstones) beside corrections, shares `since`, the cursor stamp and `newestPushed`; `apply()` applies both collections and sums the count. `pull()` is unchanged and still returns hotwords through the response.
- `server/vocab-sync/app.py`: `hotword_entries` table + revision index, `HotwordEntry`/`RemoteHotwordEntry`, `PushRequest.hotwords`, `SyncResponse.hotwords`, `MAX_HOTWORD_ENTRIES`, push/pull handling with the shared revision.
- Tests: `server/vocab-sync/test_app.py` (hotword push/update/disable/delete, pull, last-writer-wins, shared revision, no events, validation and cap, old client); `SelfTest.swift` suite `hotword-sync` (also in `all`).

Verification (2026-11-05): server tests passed on Linux from a throwaway venv (`python -m pytest test_app.py` -> 13 passed). Swift verified on the remote Intel Mac Pro (macOS 26.7.1, Swift 6.3.2) from an isolated scratch copy: `cd swift && swift build` -> success; `swift run Parakey --self-test hotword-sync` -> PASS; `... vocabulary-store` -> PASS; `... asr-hotwords` -> PASS. Known gap: the networked `vocabulary-sync` self-test has no hotword round-trip step yet (a local server integration test), so the end-to-end client-server hotword flow is covered by the store-level and server-level tests separately, not yet by one networked test.

### Wave 4 - Windows parity

- equivalent SQLite table/store/migration;
- equivalent `combined_phrases` selector;
- settings UI and sync parity tests.

#### 9.4 Wave 4 status (2026-11-06)

Implemented in `windows/superdictate/`: `asr_hotwords.py` (`custom_phrase_key`, `normalized_custom_phrase`, `phrases_from_text`, `combined_phrases`), `vocabulary.py` (the same two tables, CRUD, `import_hotword_phrases`, `hotword_changes_since`, `apply_remote_hotwords`), `vocabulary_sync.py` (the `hotwords` collection, the same cursor rule for a server without it), `ui/settings_window.py` (an «ASR-термины» section in the corrections tab; changes are saved at once). Unlike macOS, Windows stamps go through `_after`, so an add and a toggle in one second still order correctly.

### Wave 5 - ASR-server migration

- independently map the finalized, synced hotword snapshot into the server ASR contour;
- do not couple this feature branch to the server deployment.

## 10. Acceptance criteria

1. A user can add `Дунималова Анаида Георгиевна` before any recognition mistake occurs.
2. That phrase reaches `AsrHotwordsConfiguration` while producing no post-processing replacement by itself.
3. Learned/manual correction behavior remains unchanged.
4. A disabled custom phrase is stored but absent from ASR input.
5. Duplicate custom/correction phrases appear once, preserving the custom spelling and precedence.
6. A list over 1000 phrases retains custom phrases before lower-priority correction-derived phrases.
7. An empty custom list plus no eligible correction phrases produces `.disabled` and preserves no-hotword decoder output.
8. Existing macOS and Windows vocabulary behavior remains compatible until their explicit parity work is completed.

## 11. Verification plan

- `cd swift && swift run Parakey --self-test vocabulary-store`
- `cd swift && swift run Parakey --self-test asr-hotwords`
- Existing all-suite/self-test command documented in `AGENTS.md` after inspecting the current branch.
- For later server work: `cd server/vocab-sync && python -m pytest test_app.py`.
- For later Windows work: `python windows/superdictate/selftest_vocab.py`.

## 12. Open design decisions

- Sync payload extension should be backward compatible: decide whether it is a named second collection inside the existing payload (preferred) or an endpoint version bump.
- UI may use a tab or an adjacent section; choose the smallest accessible design consistent with `VocabularyManagerWindow`.
- Final DB cap for persistent custom phrases is not yet set. The ASR exposure cap is fixed at 1000; storage should not silently discard user data merely because it is not currently sent to ASR.
