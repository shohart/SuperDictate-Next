# ggml / parakeet.cpp capability-regression plan

**Status:** experimental branch — no production code changes

**Date:** 2026-08-18

## Scope lock

The model is explicitly **out of scope** for this track. Production remains on
the existing multilingual `tdt-0.6b-v3-q8_0.gguf`; no model download, model
path, model revision, or model default will be changed here. The 1.1B research
below is retained only as background and will not be implemented in this
branch.

This branch updates and tests only parakeet.cpp together with the exact ggml
submodule revision selected by the parakeet.cpp maintainer. We will not merge
an unrelated newer ggml into parakeet.cpp manually. Silero VAD and the Vulkan
toolchain are deferred until this runtime pair has been validated.

Each component update must remain independently bisectable.

## Executive summary

The current application uses `tdt-0.6b-v3-q8_0.gguf`, a multilingual TDT
model. The candidate `tdt-1.1b-q8_0.gguf` is larger, but it is not a safe
drop-in quality upgrade: the published GGUF catalogue presents the 1.1B TDT
family separately from the multilingual v3 checkpoint. A larger English model
can be worse than the current 0.6B v3 model on Russian speech.

The 1.1B model is not being adopted. All runtime comparisons in this branch
keep the current 0.6B v3 model fixed.

## Current pins

| Component | Current pin | Notes |
| --- | --- | --- |
| parakeet.cpp | `1bfbebfaaf493866f49597cd3b7901959d395c60` | current upstream v0.5.0 commit |
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

## Initial capability run on the Intel Mac

The exact `tdt-1.1b-q8_0.gguf` was downloaded to a temporary path and tested
without changing the production model or application. Its SHA-256 was
`1f0f112a7b30771ff5a01033562118e72f1146f0659fdd5cbba4bd1ac201aade`.

The test used the existing bridge, eight threads, the real AMD RX 6600 Vulkan
backend, and the existing CPU backend. The inference clip was the synthetic
near-silence clip used by the integration self-tests, so these numbers measure
compatibility and resource cost, **not recognition quality**.

| Model/backend | Peak RSS | Warm inference in self-test | Result |
| --- | ---: | ---: | --- |
| 0.6B v3 Q8 / CPU | ~0.99 GB | 1.17 s | PASS |
| 1.1B Q8 / CPU | ~1.60 GB | 1.76 s | PASS |
| 0.6B v3 Q8 / Vulkan | ~1.05 GB | 0.20 s | PASS |
| 1.1B Q8 / Vulkan | ~1.63 GB | 0.18 s | PASS |

The Vulkan timings are close enough that the short synthetic clip should not
be used to claim a 1.1B speedup; a real repeated speech corpus is required.
The meaningful early result is that 1.1B Q8 loads and runs on this Mac, while
using roughly 55–62% more resident memory and being about 1.5× slower on CPU.

## What upstream changed

## Production release comparison

The production v0.5.2 release binary and the capability release binary were
run against the same eight-clip synthetic RU/EN/mixed corpus, with three
repeats per clip, the same `tdt-0.6b-v3-q8_0.gguf` model, and eight threads.
The production binary was `/Applications/SuperDictate.app`; the capability
binary was built in release mode from this branch.

| Metric | Production v0.5.2 | Capability branch | Result |
| --- | ---: | ---: | --- |
| CPU median RTF | 0.1411 | 0.1339 | ~5% faster |
| Vulkan median RTF | 0.0941 | 0.0905 | ~5% faster |
| CPU median load | 0.692 s | 0.565 s | faster |
| Vulkan median load | 1.281 s | 1.150 s | faster |
| CPU median warm-up | 0.114 s | 0.102 s | comparable/faster |
| Vulkan median warm-up | 0.219 s | 0.228 s | comparable |

All 16 corresponding transcripts (8 clips × CPU/Vulkan) were identical. Peak
RSS stayed effectively unchanged: roughly 0.95–1.43 GB depending on clip and
backend. The updated pair therefore shows no observed functional regression
and a small performance improvement, but the gain is not large enough to
justify changing the model or making broader ggml changes on its own.

## VAD compatibility fix

The real Silero VAD test exposed an Intel/Accelerate edge case in the pinned
ggml tinyBLAS fast path: an otherwise valid generic matmul shape could reach
`llamafile_sgemm` with `ldb < k`, causing an assertion instead of falling back
to the normal CPU kernel. The fix makes that optional fast path return `false`
for unsupported layouts and keeps Silero VAD on the CPU scheduler rather than
registering the ACCEL/BLAS backend for this small segmentation graph.

The pinned `ggml-silero-v6.2.0.bin` model is unchanged. After the fix:

- `silero-vad-real`: PASS;
- `vad-boundary-oracle-real`: PASS;
- full self-test: PASS;
- Parakeet Vulkan integration: PASS.

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

Upstream ggml has released v0.20.1, while the current parakeet.cpp maintainer
pin remains ggml v0.13.0. We will follow the maintainer's tested submodule
pair rather than manually mixing ggml v0.20.1 into parakeet.cpp. A future
parakeet.cpp release that moves its own submodule can be evaluated as a single
unit. Manually mixing a newer ggml could invalidate:

- the C++ bridge assumptions;
- backend registry/device lifecycle code;
- the custom Vulkan shader runtime;
- generated SPIR-V shader compatibility;
- Intel compiler flags and Accelerate/BLAS integration.

No independent ggml update is planned in this branch.

### MoltenVK and Vulkan toolchain

Recent MoltenVK upstream work includes fixes for `memoryTypeBits` on input
attachments and support for newer Vulkan extensions. Homebrew currently has
newer Vulkan headers/loader than installed on this Mac. This is a useful
separate capability experiment, but should not be mixed with the ggml or VAD
update in the first run.

### Silero VAD

The VAD model bytes are still current and match the pinned SHA. The source
extraction is behind current whisper.cpp by many commits; it may be updated in
its own commit, but the VAD model itself must remain unchanged.

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

### Stage 2 — parakeet.cpp with maintainer-selected ggml

Move parakeet.cpp to the selected upstream commit and regenerate its vendored
tree and shaders. Keep the exact ggml submodule revision pinned by that
parakeet.cpp commit. Keep the old pair available for immediate bisect/revert.

### Stage 3 — deferred VAD/toolchain follow-up

VAD source and Vulkan toolchain updates are intentionally deferred until the
parakeet.cpp/ggml pair passes all regression tests.

### Stage 4 — deferred Vulkan/VAD follow-up

Only after the runtime pair is accepted, evaluate Homebrew Vulkan
headers/loader and VAD source in separate follow-up commits.

### Stage 5 — decision

Promote a candidate only if all of the following hold:

- Current 0.6B v3 quality and post-processing remain unchanged;
- no Vulkan fallback/reload regression;
- peak memory and latency fit the interactive dictation budget;
- long-audio and insertion tests pass;
- the model can be downloaded and verified by an immutable SHA-256 pin.

## Runtime-only recommendation

Start with the parakeet.cpp/ggml pin update only. Then update the VAD source,
then the Vulkan toolchain. Do not combine all three updates in one commit. The
current 0.6B v3 model remains the fixed regression oracle throughout.

## Sources

- [parakeet.cpp pinned-to-current comparison](https://github.com/mudler/parakeet.cpp/compare/e747acdaee69b916cef62263ae5f718bda9ff3f3...master)
- [parakeet.cpp v0.5.0 release](https://github.com/mudler/parakeet.cpp/releases/tag/v0.5.0)
- [Parakeet GGUF catalogue and sizes](https://huggingface.co/mudler/parakeet-cpp-gguf)
- [ggml releases](https://github.com/ggml-org/ggml/releases)
- [MoltenVK recent changes](https://github.com/KhronosGroup/MoltenVK/commits/main)
- [whisper.cpp upstream history](https://github.com/ggml-org/whisper.cpp/commits/master)
