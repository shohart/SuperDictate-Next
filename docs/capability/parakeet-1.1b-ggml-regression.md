# Parakeet 1.1B / ggml capability-regression plan

**Status:** research only — no production code changes

**Date:** 2026-08-18

## Executive summary

The current application uses `tdt-0.6b-v3-q8_0.gguf`, a multilingual TDT
model. The candidate `tdt-1.1b-q8_0.gguf` is larger, but it is not a safe
drop-in quality upgrade: the published GGUF catalogue presents the 1.1B TDT
family separately from the multilingual v3 checkpoint. A larger English model
can be worse than the current 0.6B v3 model on Russian speech.

The experiment must therefore measure Russian and English dictation quality,
not infer quality from parameter count or the catalogue's single WER fixture.

## Current pins

| Component | Current pin | Notes |
| --- | --- | --- |
| parakeet.cpp | `e747acdaee69b916cef62263ae5f718bda9ff3f3` | 28 Jul 2026 |
| parakeet.cpp ggml submodule | `e705c5fed490514458bdd2eaddc43bd098fcce9b` / v0.13.0 | vendored exactly |
| current model | `tdt-0.6b-v3-q8_0.gguf` | 940.7 MB, SHA pinned in `ModelDownload.swift` |
| Silero VAD source | whisper.cpp `4523d0ce373ee4b2176b3251fff29fd4864fcf38` | extracted VAD tree |
| Silero VAD model | v6.2.0 revision `9ffd54a1e1ee413ddf265af9913beaf518d1639b` | SHA pinned |
| local MoltenVK | Homebrew 1.4.2 | current installed stable formula |
| local Vulkan headers/loader | 1.4.350.1 | Homebrew has 1.4.357.0 available |

## Candidate model sizes

From `mudler/parakeet-cpp-gguf`:

| Model | Q8_0 | F16 | Approximate change vs current Q8_0 |
| --- | ---: | ---: | ---: |
| `tdt-0.6b-v3` | 940.7 MB | 1.44 GB | baseline |
| `tdt-1.1b` | 1.55 GB | 2.43 GB | +65% file size |
| `tdt_ctc-1.1b` | 1.56 GB | 2.43 GB | +66% file size |

The current Mac has enough system RAM for a Q8_0 experiment, but the AMD RX
6600 has 8 GB of VRAM/shared graphics budget. Peak allocation, shader buffers,
and CPU fallback buffers must be measured rather than estimated from file
size alone.

## What upstream changed

### parakeet.cpp

The pinned commit is behind the current `v0.5.0` release by two commits:

- CUDA 12 packaging workflow changes;
- CTC logits C-API, which bumps the C-API ABI to v6 and exposes logits/freeing
  functions for external CTC decoders.

The current upstream also documents broader model coverage, including 1.1B
models, cache-aware EOU streaming, and Nemotron multilingual streaming. Those
features are not automatically available in our pinned bridge and do not
justify a blind re-vendor.

### ggml

The project pins ggml v0.13.0 while upstream has released v0.20.1. This is a
large compatibility jump, not a routine patch update. It may improve backend
kernels, allocator behavior, Vulkan support, and CPU operations, but it can
also invalidate:

- the C++ bridge assumptions;
- backend registry/device lifecycle code;
- the custom Vulkan shader runtime;
- generated SPIR-V shader compatibility;
- Intel compiler flags and Accelerate/BLAS integration.

The ggml update must be tested independently before combining it with a model
change.

### MoltenVK and Vulkan toolchain

Recent MoltenVK upstream work includes fixes for `memoryTypeBits` on input
attachments and support for newer Vulkan extensions. Homebrew currently has
newer Vulkan headers/loader than installed on this Mac. This is a useful
separate capability experiment, but should not be mixed with the ggml/model
upgrade in the first run.

### Silero VAD

The VAD model bytes are still current and match the pinned SHA. The source
extraction is behind current whisper.cpp by many commits, but re-vendoring it
would also pull in ggml/API drift. It should remain unchanged during the first
1.1B experiment.

## Regression matrix

Every candidate must be tested against the current production baseline on the
same Mac and same audio corpus:

### Functional

- model load and unload;
- CPU warm-up;
- Vulkan warm-up on AMD RX 6600;
- CPU → Vulkan reload in the same process;
- Vulkan failure → CPU fallback;
- second dictation after fallback;
- long audio segmentation and overlap path;
- text insertion into Telegram, iTerm2, and a standard AppKit text field;
- vocabulary learning and correction toast behavior.

### Performance

Record for each model/backend:

- model load time;
- warm-up time;
- inference time for 5 s, 30 s, and 120 s clips;
- real-time factor;
- peak resident memory;
- Vulkan allocation/reallocation messages;
- CPU utilization and GPU utilization where available;
- output mute and insertion latency.

### Quality

Build a fixed corpus containing:

- Russian conversational dictation;
- English dictation;
- mixed Russian/English phrases;
- names, product names, and technical vocabulary;
- numbers, dates, punctuation, and commands;
- the user's real correction examples.

Measure:

- WER and CER by language;
- word error rate for mixed-language clips;
- punctuation/number normalization after post-processing;
- correction frequency and false correction frequency;
- subjective ranking for the user's daily phrases.

The upstream GGUF catalogue reports WER 0 on its small English fixture for
multiple quantizations. That is useful for format/parity validation, but not a
quality decision for this Russian/English application.

## Experiment stages

### Stage 1 — baseline capture

Freeze the current production binary/model and record all metrics above for
0.6B v3 Q8_0 on CPU and Vulkan.

### Stage 2 — model-only experiment

Keep the current pinned parakeet.cpp and ggml. Add an opt-in model path/profile
for 1.1B Q8_0 only. Do not change the production default. Verify that the
existing bridge can load the model and that the actual backend remains Vulkan.

### Stage 3 — quantization comparison

If Q8_0 is promising, compare 1.1B Q6_K and F16. Stop if Russian quality does
not improve enough to justify the memory/latency cost.

### Stage 4 — ggml upgrade

In a separate experiment commit, move the vendored ggml to a current stable
release. Re-run all C++ bridge and Vulkan tests before combining with the 1.1B
model. Keep the old pin available for immediate bisect/revert.

### Stage 5 — Vulkan toolchain update

Update Homebrew Vulkan headers/loader, rebuild the shader corpus, and compare
Vulkan stability/performance independently of model and ggml changes.

### Stage 6 — decision

Promote a candidate only if all of the following hold:

- Russian quality is no worse than current production and improves the target
  correction cases;
- English quality is no worse;
- no Vulkan fallback/reload regression;
- peak memory and latency fit the interactive dictation budget;
- long-audio and insertion tests pass;
- the model can be downloaded and verified by an immutable SHA-256 pin.

## Preliminary recommendation

Start with a model-only 1.1B Q8_0 capability build. Do **not** update ggml and
parakeet.cpp in the same first commit. The likely outcomes are:

1. 1.1B improves difficult English/proper-noun recognition but gives no Russian
   benefit — keep 0.6B v3 as production and consider a language-aware model
   selector later.
2. 1.1B improves both languages within an acceptable latency budget — proceed
   to ggml/Vulkan experiments.
3. 1.1B is too slow or memory-heavy — test 0.6B v3 F16/Q6_K instead; the
   catalogue reports the same fixture WER but different runtime tradeoffs.

## Sources

- [parakeet.cpp pinned-to-current comparison](https://github.com/mudler/parakeet.cpp/compare/e747acdaee69b916cef62263ae5f718bda9ff3f3...master)
- [parakeet.cpp v0.5.0 release](https://github.com/mudler/parakeet.cpp/releases/tag/v0.5.0)
- [Parakeet GGUF catalogue and sizes](https://huggingface.co/mudler/parakeet-cpp-gguf)
- [ggml releases](https://github.com/ggml-org/ggml/releases)
- [MoltenVK recent changes](https://github.com/KhronosGroup/MoltenVK/commits/main)
- [whisper.cpp upstream history](https://github.com/ggml-org/whisper.cpp/commits/master)
