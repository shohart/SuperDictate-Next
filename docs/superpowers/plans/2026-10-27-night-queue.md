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

## Stage 3 results (2026-10-27, GAMING-PC1, RTX 4070, driver 617.14)

The host is built with `build-engines.ps1 -ExperimentalLlmHost -Vulkan`. Each probe sends one
chat request, or the app's own rewrite prompts (`rwbench.py`), and compares
GPU (`--gpu-layers 99`) with CPU (`--gpu-layers 0`).

| Model | GPU (Vulkan) | GPU time | CPU time |
|---|---|---|---|
| Qwen3.5-0.8B Q6_K (correction) | correct, same text as CPU | 0.15 s | 0.8 s |
| Qwen3.5-4B Q6_K | correct, same text as CPU | 0.27 s | 3.0 s |
| QVikhr-3-4B Q6_K (Qwen3) | sane; 2 of 8 rewrites identical to CPU | p50 1.1 s | p50 17 s |
| **YandexGPT-5-Lite-8B Q4_K_M** | **NaN logits (HTTP 503)** | — | p50 ~12 s |
| YandexGPT-5-Lite-8B Q6_K | garbage tokens | — | 2.0 s (short answer) |

The VRAM-mode fix worked: the small and 4B models that used to give garbage
are now correct. YandexGPT still fails on this card, in every one of these
setups:
- with any `GGML_VK_*` precision, async or allocation flag, or all of the
  precision flags at once;
- in upstream llama.cpp b11927 on Vulkan, with flash attention on, off or
  auto;
- in upstream llama.cpp b11927 on CUDA 13.4;
- with the graphics clock locked to 2000 MHz or the memory clock lowered (both
  reset afterwards).

Offloading the last 7 layers is fine; offloading the last 8 breaks, and so
does keeping layers 20–31 on the CPU with the rest on the GPU. The error
accumulates across layers. The only GPU setup that gives correct output is
`GGML_VK_PREFER_HOST_MEMORY=1`, which in effect computes on the CPU (5.7 s).

Qwen3-8B Q4_K_M also gives NaN logits on the GPU (0 of 8 rewrites; the CPU
answers all 8). Every 8B model breaks and every model of 4B or smaller works.

**Root cause: faulty VRAM.** `memtest_vulkan` v0.5.0 finds errors in its
first pass: 0x80 errors out of 0x38000000 words, always in the same address
range (0x4CAA1510..0x4CAEEFF3 of its test buffer). The errors are
reproducible, they sit in one place, and they are not bit-flip noise. Models
whose weights or KV cache land on those cells compute garbage on CUDA and on
Vulkan alike. Small models fit below the bad range. MSI Afterburner runs on
this PC, so a memory overclock is the first suspect. Next steps: reset
Afterburner to stock and rerun memtest_vulkan. If the errors stay at the same
addresses, the card is defective.

The local rewrite on the GPU itself works where the VRAM is good: QVikhr-3-4B
takes 0.5–2 s per rewrite on the RTX 4070, against 10–22 s on the CPU. The
8B rewrite models have to be checked again on a healthy GPU, such as the
Intel Arc laptop or this card once the errors are fixed.
