# SuperDictate Next — ASR hotwords (vocabulary biasing) specification

Status: implementation-ready, revision 1 (2026-10-29). Scope: the native ONNX
core (`native/asr-runtime`, families `nemo_tdt` and `gigaam_rnnt`) and the
macOS app. The Windows frontend is out of scope for this release; it gets the
core changes automatically and is wired up later.

## 1. Goal

Make the speech model itself prefer the user's own terms: product names,
acronyms, Latin spellings and surnames from the vocabulary. Today these are
fixed only after recognition, by `TranscriptCorrector` exact replacements and
the LLM correction. The ASR change catches the variants the corrector has
never seen, for example «Краснякову» → «Красникову», «ЕСИ» → «ЕСИА» and
«DDR4 DM» → «DDR4 DIMM».

Hard requirement: **with no hotwords the output is bit-identical to today**.
Every existing golden and parity test stays as it is.

## 2. Background: sherpa-onnx v2.0.0 evaluated, not adopted

- Linking sherpa-onnx brings no gain: the same speed, a slightly worse
  transcript on our model, and a second (unofficial) ONNX Runtime 1.28.2 next
  to ours. ORT 1.28.2 is not faster for our models either.
- Its hotwords (TDT `modified_beam_search` plus `ContextGraph`) measured weak
  on Parakeet Ultra, for three reasons:
  - the boost is counted twice;
  - the beam keeps duplicate hypotheses;
  - TDT hypotheses on different frames compete in one sort.
- We port the *idea*, Aho-Corasick-style phrase boosting
  (sherpa `context-graph.cc`, Apache-2.0; NeMo GPU-PB), but into our **greedy**
  decoders, with a rollback rule instead of score cancellation (§4).

## 3. Prototype results (2026-10-29, scratch prototypes)

The test sets:
- 15 synthetic sentences (macOS `say -v Milena`) with terms from the user's
  real vocabulary;
- 5 plain control sentences and 15 "trap" sentences with similar words
  («Красникова», «коммит», «хром», «Макс», «пайплайн», «есть идея»);
- the golden fixtures and 5 minutes of real user audio.

The hotword list is the user's filtered vocabulary: 80 phrases (§6), plus 3
surnames.

| Model | Weight | Terms fixed | Regressions |
|---|---|---|---|
| GigaAM v3 | 2.0 | DIMM, Красникову, ЕСИА | 1 («зип-пакеты» → «ZIP-пакеты», ZIP is in the list) |
| GigaAM v3 | 3.0 | + Ничипуренко, ZIP | same, plus «ЕГРН.» inserted where the base model had dropped the tail |
| Parakeet Ultra | 2.0 | Ничипуренко, DDR4 DIMM, Gmail watcher, Красникову | 0 |

- The golden transcripts (RU 11 s, RU 71 s, EN 11 s) do not change at any
  weight.
- Without rollback (plain shallow fusion) the greedy decoder dropped the rest
  of an utterance after a broken partial match. The rollback rule in §4.3
  removes this failure.
- Case variants («ssh» → «Ssh») hurt, so phrases are used exactly as written.

Default weight **2.0** ("normal"); **3.0** is offered as "strong".

## 4. Algorithm (both families)

### 4.1 Boosting trie

- Each phrase is tokenized into the model's own pieces (§5) and inserted into
  a trie of token ids.
- Every edge carries `token_score = weight`.
- A node is `is_end` when a phrase ends there.
- Phrases that fail to tokenize (characters outside the vocabulary) are
  skipped and reported (§7).
- Duplicate phrases are merged.
- Limits: at most 1000 phrases and 32 tokens per phrase. Longer phrases are
  skipped.

### 4.2 Biased greedy step

At every joiner step with hotwords active:

1. Take `lp = log_softmax(token_logits)` over the token part only (vocab
   incl. blank; TDT duration logits are untouched).
2. For each child `k` of the current trie node, add `lp[k] += token_score`.
   At the root this means the first tokens of all phrases, unless the root
   boost is suppressed at this exact position (§4.3). Blank is never boosted.
3. `token = argmax(lp)`. The TDT duration is still `argmax(duration_logits)`.
   The reported confidence is the *unbiased* softmax probability of the
   chosen token, as today.

### 4.3 Match bookkeeping and rollback

The decoder keeps the following state:
- `node`: the current trie node (root when idle);
- `snapshot`: the full decoder state when the current match began. That is
  `t`, `emitted_this_frame`, `h`, `c`, `dec_out`, `h_next`, `c_next` and the
  token count;
- `pending`: the match reached an `is_end` node and waits for a word boundary;
- `suppress`: the `(t, token_count)` position where the root boost is
  disabled.

For each emitted non-blank `token`, define
`boundary(token) := piece starts with U+2581, or its first code point is not
a letter or digit`. Then apply these rules in order:

1. If `pending` and `token ∉ node.children`:
   - when `boundary(token)` holds, **commit**: `node = root`,
     `snapshot = none`, `pending = false`, and continue with rule 2 for the
     same token;
   - otherwise, **roll back** (rule 4).
2. If `token ∈ node.children`, and not (`node == root` and the position
   equals `suppress`):
   - if `node == root`, take the snapshot;
   - set `node = child` and `pending = child.is_end`.
3. Else, if `node != root`, **roll back**.
4. **Rollback:**
   - restore the snapshot;
   - truncate the emitted tokens;
   - set `suppress = (snapshot.t, snapshot.token_count)`, `node = root`,
     `pending = false`, `snapshot = none`;
   - re-run the step at that position without the root boost.

   This yields exactly what the unbiased decoder would emit there. Boosted
   continuations deeper in the trie no longer apply, because the node is
   root.
5. At the end of the frames: a `pending` match commits; an unfinished match
   rolls back, and decoding continues from the snapshot.

Termination: every rollback moves the suppression point to the snapshot
position. The re-run at that position takes the unboosted path, so decoding
always progresses. Cancellation (`check_cancelled`) is polled as before.

Cost: one log-softmax per step (cheap, versus the joiner run) and a few
`O(children)` additions. Rollbacks replay at most one phrase worth of steps.

## 5. Tokenizing phrases

The phrase text is normalized as follows: whitespace runs are collapsed to
U+2581, a leading U+2581 is added, and there is no case folding.

| Family | Model | Tokenizer | Data |
|---|---|---|---|
| `nemo_tdt` | Parakeet Ultra | SentencePiece **BPE**. Repeatedly merge the adjacent pair whose concatenation is a vocab piece with the **lowest id**. Single characters must be in the vocab. | `tokens.txt` alone. Verified identical to the HF `tokenizers` reference (`moondream/parakeet-ultra` `tokenizer.json`) on 168 words. |
| `gigaam_rnnt` | GigaAM v3 e2e | SentencePiece **unigram**. Viterbi segmentation that maximises the sum of piece scores. | Bundled asset `gigaam_v3_spm.tsv` (`piece<TAB>score`, 1024 lines, in vocab order). Derived from `ai-sage/GigaAM-v3@7655ad717f8122257385bb4b2f373db3697e8680/tokenizer.model` (sha256 `828c12c9…0a18a`, MIT) by `tools/spm_to_tsv.py`. |

For GigaAM, the asset is found through the manifest role
`hotword_tokenizer` (bundled) when present. Otherwise it is looked up under
the name `gigaam_v3_spm.tsv` next to the bundled preprocessor, so existing
installs work without a re-download. The catalog gets the role for new
installs. If the asset is missing, GigaAM hotwords are disabled with a
reason, and transcription still works.

Control pieces (`<...>`) are never part of a phrase.

## 6. Which vocabulary entries become hotwords (macOS)

The phrase is the entry's **replacement**, with surrounding whitespace and
punctuation `.,!?;:—–-«»"'` trimmed. An entry is skipped when any of these
holds:
- the phrase has fewer than 2 characters, or no letter;
- it has more than 4 words;
- it equals the source, ignoring case, punctuation and whitespace (a
  punctuation-only edit).

The decision is a per-entry `asr_hint`: NULL = automatic, 1 = always, 0 =
never. A new column `asr_hint INTEGER` is added to `corrections` by an
idempotent migration. Automatic means:
- `manual` entries: yes;
- `learned` entries: yes when "term-like", i.e. the phrase contains a Latin
  letter or a digit, or has at least 2 uppercase letters (ЕГРЮЛ, DDR4,
  TickTick).

Ordinary Russian words learned from edits («Запомни», «стороной») are not
boosted. Surnames such as «Ничипуренко» are opted in with the per-entry
checkbox.

The list is deduplicated (exact string match) and capped at 1000 phrases.

## 7. IPC / C ABI

`TRANSCRIBE` options (JSON) gain two fields:

- `"hotwords": ["DDR4 DIMM", "ЕСИА", …]`. Optional; absent or empty means
  the unbiased path, bit-identical to today.
- `"hotwords_score": 2.0`. Optional, default 2.0, clamped to [0.5, 5.0].

The handle caches the compiled trie, keyed by the exact list plus the score.
The overlap-window path sends the same list on every request and pays the
build cost only once.

The result JSON gains these fields when hotwords were supplied:

- `"hotwords_used": <phrases in the trie>`;
- `"hotwords_skipped": [<phrases that could not be tokenized>]`, omitted when
  empty;
- `"hotwords_disabled_reason": "…"`, when the family cannot do hotwords at
  all (for example a missing GigaAM asset).

The punctuation family ignores the fields. No new message type is added, and
the IPC version stays 1.

## 8. macOS app

- `Settings`:
  - `asrHotwordsEnabled` (default **on**);
  - `asrHotwordsStrength` (`normal` = 2.0, `strong` = 3.0).
- `VocabularyStore`:
  - the `asr_hint` migration;
  - `setAsrHint(id:hint:)`;
  - `asrHotwordPhrases() -> [String]`, which applies §6.
- The selection rule is a pure function, `AsrHotwordSelection`, with
  self-tests.
- `OnnxAsrEngine` holds the current list and score (set by
  `TranscriptionWorker` when a dictation starts) and adds them to every
  `TRANSCRIBE` options object. An empty list adds nothing.
- `ControlPanel`, in the vocabulary block: a toggle «Подсказывать
  распознаванию термины из словаря» and a strength picker
  («Обычно» / «Сильнее»).
- The vocabulary manager gets a checkbox column «Подсказка ASR». It shows the
  effective state; a click sets 1 or 0 explicitly.
- Diagnostics: `--benchmark-transcribe-onnx` accepts
  `--hotwords <file> [--hotwords-score x]`.
- Self-tests:
  - `asr-hotwords`: the selection rule, IPC options, and an empty list leaving
    the output unchanged;
  - `onnx-asr-real`: also checks that a hotword fixes a synthetic `say`
    sample.

## 9. Native tests

- The Python references `reference_tdt.py` and `reference_gigaam.py` gain
  `--hotwords <file> --hotwords-score x`. They implement §4–§5 independently
  of the C++ code.
- `model_tests` gets these cases:
  - golden fixtures with an empty list are unchanged;
  - exact parity with the references on the hotword fixtures, for both
    families;
  - the rollback case (a phrase whose prefix matches, then diverges) does not
    lose the tail.
- `contract_tests` gets unit tests for:
  - the trie and the two tokenizers, including known segmentations;
  - the options validation (types, clamp, the limits).

## 10. Out of scope

- Windows frontend wiring.
- Hotwords for the OpenVINO path.
- Beam search.
- Learning hotwords from audio.
