# Punctuation restoration (macOS + Windows)

Status: implemented in 0.9.0. Plan: `docs/superpowers/plans/2026-10-27-night-queue.md`, stage 2.

## Pipeline

ASR → deterministic post-processing → correction (if on) → rewrite (if on) →
**punctuation restoration (if on)** → insertion.

The stage never loses or blocks the text. If the model is not downloaded,
the host does not start, or a request fails, the text from the previous stage
is inserted unchanged.

## Model

[Horizon-Labs/punctuation-restoration](https://huggingface.co/Horizon-Labs/punctuation-restoration-base)
comes in two sizes, Small (140M) and Base (307M). Both are Apache-2.0
ModernBERT token classifiers fine-tuned from mmBERT, covering 88 languages.
On FLORES the punctuation F1 for Russian is 0.95 on cased text and 0.92 on
lowercased text.

- Labels after each word: none, `.`, `,`, `?`, `-`, `:`. The word's label is
  its last sub-token's. Casing is not predicted.
- Files: `onnx/model_quantized.onnx` (int8 embeddings) and `tokenizer.json`
  (Gemma BPE, 256k vocab). Pinned by revision, size and SHA-256 in
  `native/asr-runtime/catalog/onnx-models.json` as `punct-small-int8` and
  `punct-base-int8` (family `modernbert_punct`, `"kind": "punctuation"`).
- Long texts run in 400-token chunks with a 50-token overlap. CLS is `<bos>`
  (2) and SEP is `<eos>` (1), as in the model card's `punctuate.py`.

## Runtime

The stage runs in `SuperDictateOnnxHost` (C++, ONNX Runtime 1.23.2, CPU) on
both platforms. Each model gets its own host process.

- `src/families/bpe_tokenizer.*` is a native port of the HF `tokenizers` BPE
  subset that the model uses: Replace(" "→▁), Metaspace (prepend always,
  split), and byte fallback. Bytes without a `<0xXX>` token fall back to
  `<unk>`. The 34 MB JSON is parsed with SAX and is never built as a DOM. Any
  other tokenizer configuration is refused.
- `src/families/punct_text.*` merges the labels into the text (see the policy
  below).
- `src/families/modernbert_punct.cpp` is the model family.
- C ABI: `sd_asr_punctuate_utf8`. IPC v1: message type `PUNCTUATE = 6`, with
  body `{"text": ...}` and response `{"text", "processing_seconds", ...}`. A
  speech model refuses PUNCTUATE, and a punctuation model refuses TRANSCRIBE.

## Merge policy

The policy is conservative about what earlier stages decided.

- An existing sentence end (`.`, `!`, `?`, `…`) is kept. A lone `.` becomes
  `?` when the model predicts a question.
- An existing `;` is kept, and so is whatever stands before an existing
  standalone dash.
- Everywhere else, the model's label wins: commas, colons and dashes are
  added or removed, and new sentence ends are added.
- After a new sentence end, the next word is capitalised. After an existing
  one, it is capitalised only when the model agrees, which rules out
  abbreviations such as «т.е.». Nothing is ever lowercased.
- A new dash is `—` in Cyrillic text and `-` otherwise.

## Settings

The toggle is in the Correction tab on macOS and the LLM page on Windows.

| Key | Default | Meaning |
|---|---|---|
| `punctuation_restoration_enabled_v1` | off | run the stage |
| `punctuation_model_v1` | `base` | `small` or `base` |

The model is downloaded from Settings ("Download"). While the stage is
enabled, the model is preloaded at agent start and on a settings save, and it
is unloaded when the stage is switched off.

## Measurements

Intel Mac, Xeon E5-2696 v3, CPU only:

| Model | Load | Per sentence, 4 threads | 400-word text, 4 threads | RSS |
|---|---|---|---|---|
| Small | 2.7 s | 10–35 ms | 0.64 s | 0.7 GB |
| Base | 4–5 s | 20–90 ms | 1.5 s | 1.5 GB |

## Verification

- `ctest` `punct` (`SD_ASR_TEST_PUNCT_MODEL_DIR`) checks the token ids word by
  word against HF `tokenizers`, and the final text against
  `tools/reference_punct.py`, for 16 cases per model. These include byte
  fallback, numbers, abbreviations, quotes and a 1,100-token text, which tests
  chunking. All match exactly for both models.
- `contract` tests cover the merge policy.
- macOS self-tests: `punctuation-settings` (in `all`) and `punctuation-real`.
  `--diagnose-punctuation small|base <text>` is step 5 of
  `scripts/verify-release.sh`.
- Windows self-test: `test_punctuation_*`.
