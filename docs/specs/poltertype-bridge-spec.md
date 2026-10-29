# SuperDictate Next ↔ PolterType bridge specification

Status: revision 1 (2026-10-29). Stage 0 is implemented in the macOS app.
Stages 1–3 are design only and depend on the upstream proposal in
`shohart/PolterType`, branch `proposal/text-providers`,
`docs/proposals/text-providers.md` (the RFC for the PolterType author).

## 1. Goal

[PolterType](https://github.com/Just-Code-NET/PolterType) (MIT, Rust;
Windows, macOS, Linux) watches keyboard input and fixes words typed in
the wrong layout. It already offers per-word spelling suggestions from
Hunspell-derived dictionaries, ranked with keyboard geometry.

SuperDictate already has what a typing assistant lacks: a personal
vocabulary learned from the user's corrections, a punctuation model
(mmBERT, `PunctuationRestoration.swift`) and grammar-correction models
(VoiceScribe 0.8B + LoRA, YandexGPT-5-Lite-8B). The goal is for
PolterType to use them while typing, **without merging the projects**.
Each product keeps working alone, and the two connect through documented
seams.

Constraints taken from PolterType's own design (`docs/ARCHITECTURE.md`,
`docs/AI.md`, `docs/DATA_LAYOUT.md`) and to be respected:

- third-party code never runs inside the process that holds the keyboard
  hook. An extension is a separate process;
- PolterType draws all UI. A plug-in supplies data and text only;
- nothing typed is logged, and nothing leaves the machine unless the user
  configured it. Anything contacted is on loopback;
- a correction that arrives late is corruption. The typing path never
  waits on a model;
- AI is off by default. An offer is shown and confirmed, never applied
  silently.

## 2. What PolterType offers today (v0.38.2)

| Seam | What it can do | Fit for us |
|---|---|---|
| User overlay `<config-dir>/wordlists/<stem>(-extras).txt` | adds words to a layout's dictionary; overlay words are also spelling-suggestion candidates; re-read on tray "Reload Settings" | **stage 0**, works now |
| Data pack `plugins/<id>/` | layouts + their dictionaries; a wordlist is attached to a layout the pack itself defines | cannot *extend* a bundled language without replacing it |
| Extension (`kind = "extension"`) | separate process: service, commands, tray items, a native settings pane, text reports | UI only. **No channel from the engine**, so it never sees a word |
| `[[ai.plugins]] type = "llm"` | HTTP (OpenAI/Ollama/Anthropic shapes) to an endpoint, loopback allowed without `allow_remote` | asks only "which layout is this word?"; not spelling |
| `SuggestionProvider` trait | `is_known` + `suggest` per finished word → tooltip, F1–F9 / chord accept, replacement via absorb → delete → replay | in-process only |
| `WordRewriter` trait | designed in `PLAN.md` (context, mandatory confirmation), **no consumer**: `[[ai.rewriters]]` is ignored | the natural place for our models |

Two details found while building stage 0:

- the overlay stores words in the lossy membership shape
  (`letters_only_lower`), so a suggestion comes out as `github` /
  `ничипуренко` instead of `GitHub` / `Ничипуренко`;
- "Add to dictionary" in PolterType appends to `<stem>.txt`. PolterType
  never writes `<stem>-extras.txt`.

## 3. Stage 0 — vocabulary → PolterType wordlists (implemented, macOS)

`swift/Sources/Parakey/PolterTypeWordlistExport.swift`.

- **What is exported:** the words of every vocabulary *replacement*.
  Sources are never exported: a source is a misrecognition, the spelling
  PolterType should keep treating as a mistake.
- **Tokenizing:** letters with inner `-` / `'` kept (`Нью-Йорк`,
  `O'Reilly`). A token touching a digit or `_` (`37А`, `Alien_skaarj`) is
  dropped whole. Fewer than two letters is dropped.
- **Layout:** all-Latin → `en_us`; all-Cyrillic → `ru_ru`, or `uk_ua` when
  the word has `і ї є ґ`; mixed scripts → none. Deduplicated
  case-insensitively (first spelling wins), sorted.
- **Where:** `~/Library/Application Support/dev.opensource.poltertype/wordlists/<stem>-extras.txt`.
  It is written only if that config directory already exists. SuperDictate
  never creates PolterType's configuration.
- **Ownership:** a file is ours only if its first line starts with
  `# Managed by SuperDictate Next`. A file without it is reported and left
  untouched. Writes are atomic and skipped when the content is unchanged.
  A stem whose words disappeared is rewritten with the header only.
- **When:** setting `polterTypeWordlistExportEnabled` (off by default;
  Settings → Text, "Share the vocabulary with PolterType"). When the
  setting is on, the agent exports at launch and 2 s after any
  `VOCABULARY_CHANGED_NOTIFICATION` (local edits in either process,
  learning, sync passes). Saving the settings with the switch on exports
  at once.
- **Pickup:** PolterType re-reads overlays on its tray "Reload Settings"
  or at restart. There is no watcher yet (see §6).
- **CLI:** `SuperDictate --export-poltertype-wordlists [directory]`
  prints `POLTERTYPE_EXPORT … written=[…] unchanged=[…]`. It exits 1 if an
  unmanaged file was left alone.
- **Self-test:** `--self-test poltertype-export`, part of `all`.
- **Windows:** not yet. The same rules apply to
  `%APPDATA%\opensource\poltertype\config\wordlists\`, to be ported to
  `windows/superdictate/vocabulary.py`.

## 4. Stage 1 — SuperDictate Text Service

A loopback HTTP surface served by the SuperDictate agent:

- bound to `127.0.0.1` on an OS-assigned port;
- the port and a random bearer token are written to
  `<app-support>/text-service.json` with mode `0600`. Only processes of
  the same user can read them;
- no request body or response is ever logged, matching both projects'
  rules.

| Method | Request | Response | Backed by |
|---|---|---|---|
| `GET /v1/health` | — | versions, which capabilities are loaded | — |
| `POST /v1/spell` | `{word, layout, left_context?}` | `{known, candidates[{text, score, source}]}` | vocabulary (exact + source→replacement), surface case kept |
| `POST /v1/punctuate` | `{text, lang}` | `{text, changed}` | `PunctuationRestorer` (Small by default) |
| `POST /v1/correct` | `{text, lang}` | `{text, changed}` | correction stage (fast tier); guarded by `LLMCorrectionGuardrail` |
| `GET /v1/vocabulary` | — | managed words per layout | replaces the stage 0 file export for PolterType ≥ the RFC |
| `POST /v1/vocabulary` | `{source, replacement}` | record | PolterType's "Add to dictionary" flowing back (opt-in) |

Latency targets on this Mac's class of CPU: `spell` < 5 ms, `punctuate`
< 60 ms for a sentence, `correct` hundreds of ms. The last one is only
ever used asynchronously and per sentence (§5).

Our models were trained on **speech-recognition** errors, not keyboard
typos (adjacent keys, transpositions, dropped letters). PolterType's own
keyboard-geometry ranking handles typos better. So `spell` contributes
the user's vocabulary, and the LLM is never asked to fix single typed
words.

## 5. Stages 2–3 — PolterType side (upstream proposal)

The PolterType work is a generic **text-provider** extension contract.
It is not SuperDictate-specific, so the author can accept it on its own
merits. The full RFC is in the fork. In short:

1. **Small PRs first:**
   (a) a data pack may ship `wordlists/<stem>-extras.txt` that extends a
   layout it does not define;
   (b) overlay entries keep their surface form for suggestions;
   (c) the overlay directory is watched, so "Reload Settings" is no
   longer needed.
   (a) or (c) makes stage 0 seamless.
2. **Text providers:** an extension declares `[extension.text_provider]`
   with `suggest` and/or `rewrite` capabilities and a deadline.
   PolterType talks to the running service over a local socket (unix
   socket / named pipe — the service's stdin is null by design), using
   JSON lines.
   - `suggest` merges into `SuggestionProvider` results, same tooltip.
   - `rewrite` becomes the missing `WordRewriter` stage, as a sentence-level
     offer at `. ! ?` / Enter / pause with mandatory confirmation.
   - Like `LlmDetector`'s background mode, a slow answer is dropped,
     never waited for.
3. **Explicit command:** a hotkey "fix the last sentence / selection"
   that asks the provider and replaces only on accept. This is the robust
   first version of sentence-level fixes, since the engine's screen model
   covers one word and its trail, not a sentence.

Our part is the bridge extension `poltertype-superdictate` (own repo,
MIT): a manifest, a small binary that speaks the provider protocol and
forwards to the Text Service, a settings pane (typos / punctuation /
grammar switches), and a status line ("SuperDictate is not running").

## 6. Open items

- Windows port of stage 0.
- PolterType pickup without "Reload Settings" (upstream PR (c)).
- Text Service authentication on Windows (ACL on the JSON file).
- Opt-in only: training data from accepted PolterType suggestions, for
  a future typo LoRA.
