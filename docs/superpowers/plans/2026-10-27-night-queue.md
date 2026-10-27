# 2026-10-27 night queue: proxy release, punctuation restoration, local rewrite on Windows GPU

Executed in this order; each stage ends with a release (or a report)
before the next starts.

## Stage 1. System proxy for LLM endpoints → macOS + Windows 0.8.6

- Source: `c693488 fix(llm): use the system proxy for internet endpoints,
  keep LAN direct` (origin/main, the user's own commit).
- Review result: correct on both platforms. LAN/loopback/`.local` always
  direct; internet endpoints follow the system proxy unless the new
  `llm_use_system_proxy_v1` toggle is off (default on).
- Gap fixed on macOS: a base URL that already ends in `/v1`
  (`https://openrouter.ai/api/v1`) became `/v1/v1/chat/completions`;
  Windows already handled it. `chatCompletionsURL` mirrors
  `chat_completions_url`. New self-test `llm-proxy-policy`.
- Release: macOS per `docs/RELEASING.md` (self-tests with real models +
  `scripts/verify-release.sh`), Windows on GAMING-PC1 (`build.ps1`, ISCC).

## Stage 2. Punctuation restoration (last pipeline stage) → 0.9.0

Model: `Horizon-Labs/punctuation-restoration-{small,base}` (Apache-2.0,
mmBERT token classification, 88 languages, RU F1 0.95 cased / 0.92 lower).
Labels after each word: `.` `,` `?` `:` `-` or none; casing untouched.
ONNX: `onnx/model_quantized.onnx` (small 268 MB, base 641 MB),
`tokenizer.json` (Gemma-style, 256k vocab).

Pipeline: ASR → correction → rewrite (if on) → **punctuation**.

Settings (Text tab, next to correction): "Restore punctuation" checkbox
(off by default) + model picker Small / Base (default Base). No backend or
candidate choice. Downloaded on demand into the model cache with SHA-256
checks, like the ASR models.

Text handling:
1. Split into words; strip the marks the model predicts (`. , ? :` and a
   standalone dash) from word ends, keep everything else (`! ; … « »`).
2. Run the model (chunks of ≤ 256 words with overlap, label = word's last
   sub-token).
3. Re-attach marks; capitalise the word after `.`/`?`; keep the original
   end mark of the text if the model gives none at the end.

Runtimes:
- macOS: inside `SuperDictateOnnxHost` (C++ core already links ORT 1.23.2):
  new `punct` model family with a native tokenizer reading `tokenizer.json`.
  CPU only.
- Windows: ONNX Runtime CPU (`tokenizers` for tokenization); NPU via
  OpenVINO as an experiment, kept only if it is faster and gives the same
  labels as CPU.

Tests: tokenizer parity with HF `tokenizers` on a Russian/English corpus;
label parity with the Python reference; self-tests on both platforms; timing
for a 70-word and a 400-word dictation.

## Stage 3. Local rewrite on the Windows GPU (Vulkan) — experiment

- Build the bundled LLM host with Vulkan on GAMING-PC1
  (`build-engines.ps1 -ExperimentalLlmHost -Vulkan`), now that the VRAM
  mode issue is fixed by the user.
- Check: canary answer sane, correction/rewrite output equal to CPU on a
  fixed set, speed, VRAM. Then decide with the user whether it goes into
  the release (Windows LLM is API-only by the 2026-10-21 decision) and how
  to test on the Intel laptop GPU.
