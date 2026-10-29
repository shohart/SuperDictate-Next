# SuperDictate Next — vocabulary hygiene and account sync

Status: implementation-ready, revision 1 (2026-10-29). Platforms: macOS
(`swift/Sources/Parakey`) and Windows (`windows/superdictate`). The two apps
keep the same SQLite schema and must apply the same rules.

## 1. Problem

Auto-learning (`LearnCandidateDetector` / `vocabulary.learn_candidate`) stores
every short contiguous edit made after a dictation. A real dictionary with 120
entries (105 learned) shows the garbage this produces:

| Kind | Examples |
|---|---|
| Punctuation-only edit | «оплатил → оплатил.», «соусом. → соусом!!», «инструменты. → инструменты?» |
| Replacement has no letters | «интернейшнл. → .», «S. → 1» |
| Grammar / inflection edit | «Запомню → Запомни», «дополню, → дополни,», «пробиваю. → пробивает.», «капюшонном, → капюшоном,», «погонял → погоняло», «сторониной → стороной» |
| Content rewrite | «Смотри. → Задайте вопрос ChatGPT», «тридцать семь. А → 37А» |
| Chain / typo of a typo | «Pypline. → Pipline.» next to «Pipline. → Pipeline.» |
| Case conflict for one target | «Github» vs manual «GitHub», «Zip» vs «ZIP», «international» vs «International» |
| Edge punctuation baked into the source | «Гетхаб. → Github.», which only matches a sentence-final «Гетхаб.» |

Several sources mapping to one target («докx», «DogX», «док икс» → «docx») is
**correct** and must stay.

## 2. Learn-time hygiene (both platforms, one shared rule set)

The rules live in a pure function, `VocabularyHygiene.review(source:replacement:existing:)`
on macOS and `vocabulary_hygiene.review(...)` on Windows. It returns one of
`accept(source, replacement)` (possibly rewritten), `reject(reason)` or
`undo(existingId)`.

The rules apply in this order:

1. **Trim shared edge punctuation.** Leading and trailing characters from
   `.,!?;:…—–-«»"'()` that are identical on both sides are removed, so
   «Pipline. → Pipeline.» becomes «Pipline → Pipeline». Edge punctuation
   present only on one side is also trimmed from that side. Learning is about
   words, and the corrector keeps the dictated punctuation.
2. **Reject punctuation-only or case-only edits of ordinary words.** Reject
   when the two sides are equal after removing all punctuation and
   whitespace and lowercasing, and the replacement is not term-like. Reason:
   `punctuation`.

   *Term-like* means the replacement contains a Latin letter or a digit, or
   has at least 2 uppercase letters. This is the same predicate as the ASR
   hotword selection.

   Formatting fixes of terms stay: «IS60 → IS-60», «Metal Fish → MetalFish»,
   «NH C14S → NH-C14S», «Амирханян Ц → АмирханянЦ», «Х 99 → Х99». Edits such
   as «оплатил → оплатил.» and «инструменты. → инструменты?» go.
3. **Reject junk replacements.** Reject when the replacement has fewer than 2
   characters or contains no letter. Reason: `no-letters`.
4. **Reject Russian inflection edits.** Applies when both sides are a single
   word of Cyrillic letters (no Latin, no digits), the replacement has fewer
   than 2 uppercase letters (so «Егр → ЕГРЮЛ» stays), and the lowercased
   forms
   share a common prefix `p` such that:
   - `p ≥ 3`, and
   - `p ≥ 0.6 × min(len)`, and
   - both remaining tails are at most 4 characters.

   Reason: `inflection`. This rejects «Запомню → Запомни», «пробиваю →
   пробивает», «капюшонном → капюшоном», «сторониной → стороной» and
   «черноиск → черновик» (an ordinary word, not vocabulary). It
   keeps «Нечепуренко → Ничипуренко», «красненькову → Красникову»,
   «паникший → поникший» and «снуху → слуху».
5. **Reject content rewrites.** Transliterate both sides to Latin lowercase
   letters only (a simple GOST-like Cyrillic map; digits kept). Compute the
   similarity `1 - levenshtein / max(len)` and reject when it is below 0.3.
   Reason: `rewrite`.

   This rejects «Смотри → Задайте вопрос ChatGPT» (≈0.1) and
   «тридцать семь. А → 37А». It keeps:
   - «Эмсипи → MCP» and «Эс эйч → ssh»: an acronym written in Latin capitals,
     or a short lowercase Latin acronym of at most 5 characters, is exempt;
   - «Comment → Command», «Юзу ВМ → УВМ» and «Кад Сендер → kad sender».
6. **Undo.** If an entry `replacement → source` exists, the user has reverted
   an earlier correction. Delete that entry, store nothing and log
   `undo(existingId)`.
7. **Chains.**
   - If an entry `replacement → Z` exists, store `source → Z`. This turns
     «Pypline → Pipline» into «Pypline → Pipeline».
   - If entries `X → source` exist, rewrite them to `X → replacement`, so the
     whole chain collapses onto the newest target.
   - Comparisons use the normalized form (casefold, whitespace collapsed,
     edge punctuation trimmed).
8. **Case unification.** If another entry's replacement equals the new
   replacement case-insensitively but differs in case, keep the existing
   casing of a `manual` entry. Otherwise keep the existing casing of the most
   recently updated entry, and store the new entry with that casing.

A rejected candidate produces no pending toast and no store write; it is
logged with its reason. The manual editor in the vocabulary window applies
only rule 1 and rule 3 (no inflection or rewrite rejection: the user is
explicit there).

## 3. Cleaning an existing dictionary

The vocabulary window gets a button «Почистить словарь…» ("Clean up…"). It
runs rules 1–5 and 7–8 over **learned** entries (manual entries are never
touched) and shows a preview:

- entries to delete, each with its reason;
- entries to rewrite (trimmed punctuation, chain target, unified case);
- duplicates that collapse into one key after trimming.

The user confirms, and the changes apply in one transaction. Deletions write
tombstones for sync (§4). A self-test covers the real-world example table in
§1.

## 4. Account sync (both platforms)

Server: `server/vocab-sync` (FastAPI + SQLite), at
`https://superdictate.bykovlegal.ru`. API:

- `POST /v1/auth`. Request:
  `{"email","password","client":{"platform","version"}}`.
  Responses:
  - 200 `{"token","created","email"}`. The first sign-in with an unknown
    e-mail creates the account; `created` = true.
  - 401: wrong password.
  - 422: bad e-mail, or a password shorter than 8 characters.
  - 429: too many failed sign-ins.
- `DELETE /v1/auth`: sign out (revokes the token).
- `GET /v1/vocabulary?since=N` → `{"revision", "entries":[{source,
  replacement, origin, asr_hint, deleted, updated_at, revision}]}`.
- `POST /v1/vocabulary` with `{"since": N, "changes":[{source, replacement,
  origin, asr_hint, deleted, updated_at}], "client":{…}}`. The response has
  the same shape as GET: everything above `since`, after the push is merged.

Every authenticated request carries `Authorization: Bearer <token>`.

Merge rules:
- **Key:** the normalized source (NFC, casefold, whitespace collapsed), the
  same rule as the local dedup.
- **Last writer wins** on `updated_at`, the ISO-8601 UTC string
  `YYYY-MM-DDTHH:MM:SSZ`, compared as a string. A tie keeps the server copy.
- Deletions are tombstones (`deleted: true`, `replacement: ""`).
- The server caps an account at 5000 live entries.

### 4.1 Client state

- **Settings:** `vocabularySyncEnabled` (default off), the server URL
  (default `https://superdictate.bykovlegal.ru`, hidden; override via
  defaults or settings key only), the account e-mail, `lastServerRevision`
  and `lastPushedLocalStamp`.
- **Token:** macOS keeps it in the Keychain (generic password, service
  `com.local.superdictate.vocab-sync`). Windows keeps it in the Credential
  Manager via `keyring` if it is already a dependency, otherwise as a
  DPAPI-protected file in the app data folder. The password is never stored.
- **Tombstones:** a new table
  `deleted_corrections(key TEXT PRIMARY KEY, source TEXT NOT NULL, deleted_at TEXT NOT NULL)`.
  Every local delete (manual, cleanup, undo, replace-all) writes one.
  Re-adding the key removes the tombstone.

### 4.2 Sync pass

The sync runs serially, one pass at a time, as follows:

1. **Push.** Send every local entry with `updated_at > lastPushedLocalStamp`,
   and every tombstone with `deleted_at > lastPushedLocalStamp`, in batches
   of at most 1000 changes. Send `since = lastServerRevision`.
2. **Apply the response entries.** For each remote entry:
   - a live entry is upserted by key when its `updated_at` is newer than the
     local row; the row keeps the remote `updated_at`, origin and asr_hint;
   - a tombstone deletes the local row when it is newer, and records the
     tombstone locally.

   Applying a remote entry must not make it look locally changed. It keeps
   the remote `updated_at`; a re-push of it is harmless, because a tie keeps
   the server copy.
3. **Update the cursors.** Set `lastServerRevision = response.revision` and
   `lastPushedLocalStamp = max(pushed stamps)`.
4. **Notify.** Post the vocabulary-changed notification so the open UI and
   the corrector caches reload.

The first sign-in on a device runs a full sync: `since = 0` and every local
entry is pushed. This merges two existing dictionaries.

Triggers:
- app launch, when signed in;
- 5 s after any local vocabulary change (debounced);
- every 15 minutes;
- the «Синхронизировать сейчас» button.

Failure handling:
- on network errors, back off and retry on the next trigger;
- a 401 drops the token and shows «Войдите снова».

### 4.3 UI (Settings → vocabulary block)

The block is titled «Синхронизация словаря». It contains:

1. Fields «Эл. почта» and «Пароль», and the button «Войти». If this e-mail
   has no account yet, the button creates one.
2. Consent text, always visible above the button:
   «Словарь будет храниться на сервере SuperDictate и использоваться для
   улучшения распознавания речи.» / "Your vocabulary is stored on the
   SuperDictate server and used to improve speech recognition."
3. When signed in, the e-mail is shown with the last-sync time and the
   status, plus the buttons «Синхронизировать сейчас» and «Выйти».
4. Errors appear inline: wrong password, too many attempts, no connection.

The macOS UI lives in `ControlPanel` next to the vocabulary rows. The
Windows UI lives in the matching settings page.

## 5. Tests

- **Hygiene:** a table-driven self-test with every example from §1, plus
  the keep-cases from §2, on both platforms with identical expectations.
- **Sync:** a client test against a local instance of the server (start
  `server/vocab-sync` with uvicorn on 127.0.0.1 in a temp directory). It
  covers:
  - two simulated devices: two temporary stores with the same account;
  - an add on A appearing on B;
  - a delete on B removing the entry on A;
  - a conflict won by the newer `updated_at`;
  - asr_hint travelling with the entry;
  - a 401 clearing the token.
- **No regressions:** every existing vocabulary self-test passes.
