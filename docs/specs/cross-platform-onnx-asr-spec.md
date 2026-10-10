# SuperDictate Next — Cross-platform ONNX Runtime ASR Specification

Status: implementation-ready, revision 2 (2026-10-10). Scope: macOS x86_64 /
arm64 and Windows x64; ONNX speech recognition, not ONNX-based LLM
correction. Revision 2 replaces the "CTC first" milestone with **Parakeet
Ultra (TDT) as the primary ONNX model** at the user's request, and records
facts verified during the initial spike (§2). The original proposal text is
preserved in substance; everything marked **[verified]** was checked against
primary artifacts on 2026-10-10.

## 1. Motivation and repository context (as of `ef9c4ec`, v0.6.0)

- The app is Swift/AppKit (`swift/Sources/Parakey`), macOS 14+, built by
  SwiftPM; the shipping target machine is an Intel Mac (Xeon E5-2678 v3,
  AMD RX 6600 via MoltenVK/Vulkan).
- ASR today: `parakeet_cpp` (vendored parakeet.cpp + ggml, GGUF q8_0,
  CPU or Vulkan) **linked directly into the app**, plus whisper.cpp in a
  **helper process** `SuperDictateWhisperHost` (unversioned stdio framing:
  `u32 sample count + f32 PCM` in, `u32 length + UTF-8 text` out).
  LLM correction runs in `SuperDictateLLMHost` (llama.cpp, loopback HTTP).
- `TranscriptionWorker` (actor) owns a `LoadedEngine` enum
  (`.parakeet` / `.whisperCpp`), the Vulkan→CPU fallback policy (never
  retried in-session), the plain segmented path and the overlap-window
  path (`transcribeWithTokens`, Parakeet-only today).
- `SpeechModelProfile` (`ConfigModels.swift`) has three cases; many
  helpers are written as `profile == .parakeetTDTv3 ? … : whisper…`, so a
  new case **must** be handled explicitly at every such site.
- `ModelDownload.swift` pins every model as a single file
  (URL + revision + SHA-256 + size). `ModelRegistry.swift` is only an
  environment-hardening check.
- No Windows frontend exists in this repository. Windows is a target of
  the shared native core only, until a frontend is identified.

## 2. Verified facts from the spike [verified]

### 2.1 ONNX Runtime availability

| Version | linux-x64 | osx-x86_64 | osx-arm64 | win-x64 |
|---|---|---|---|---|
| 1.23.2 | yes | **yes** | yes | yes |
| 1.24.4 | yes | **no** | yes | yes |

ONNX Runtime 1.24 dropped the Intel macOS prebuilt. **Pin ONNX Runtime
1.23.2 on every platform** (one version everywhere, one ABI). Release
digests (GitHub release metadata):

| Archive | SHA-256 |
|---|---|
| `onnxruntime-osx-x86_64-1.23.2.tgz` | `d10359e16347b57d9959f7e80a225a5b4a66ed7d7e007274a15cae86836485a6` |
| `onnxruntime-osx-arm64-1.23.2.tgz` | `b4d513ab2b26f088c66891dbbc1408166708773d7cc4163de7bdca0e9bbb7856` |
| `onnxruntime-win-x64-1.23.2.zip` | `0b38df9af21834e41e73d602d90db5cb06dbd1ca618948b8f1d66d607ac9f3cd` |
| `onnxruntime-linux-x64-1.23.2.tgz` (dev/CI only) | `1fa4dcaef22f6f7d5cd81b28c2800414350c10116f5fdd46a2160082551c5f9b` |

The stock win-x64 archive does not contain the DirectML EP (that ships as a
separate `Microsoft.ML.OnnxRuntime.DirectML` package with its own ABI);
DirectML is therefore a compile-time-gated optional build, never mixed with
the CPU archive.

### 2.2 Primary model: Parakeet Ultra int8 (sherpa-onnx layout)

Repository `mldecode/parakeet-ultra-onnx-int8`, revision
`3282a6e32885b431c1543d58c7710e6e3412eac0`, license **CC-BY-4.0**
(attribution: NVIDIA, Moondream; base `moondream/parakeet-ultra`, a retrain
of `nvidia/parakeet-tdt-0.6b-v3`).

| File | Size | SHA-256 |
|---|---|---|
| `encoder.int8.onnx` | 611 879 344 | `181382735a719c75076d13658dc4418de4b566aef39935ca0f8f55da16928f4e` |
| `decoder.int8.onnx` | 12 257 685 | `0ba8ace2de04bb2d9a6b20ed2d67138c23df4a385f268438df0ff200502de77a` |
| `joiner.int8.onnx` | 5 281 747 | `20ae4350c2484ba607d94f08ef25ae3ead762d8aaf70753758ffcc504e255ebb` |
| `tokens.txt` | 93 939 | `d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d` |

Graph signatures (ORT 1.23.2):

- encoder: `audio_signal f32[B,128,T]`, `length i64[B]` →
  `outputs f32[B,640,T']`, `encoded_lengths i32[B]`. Metadata:
  `feat_dim=128, subsampling_factor=8, normalize_type=per_feature,
  vocab_size=8192, pred_hidden=640, pred_rnn_layers=2`.
- decoder (2-layer LSTM): `targets i32[B,1]`, `target_lengths i32[B]`,
  `h f32[2,B,640]`, `c f32[2,B,640]` → `decoder_out f32[B,640,1]`,
  `decoder_out_length`, `h_next`, `c_next`.
- joiner: `encoder_out f32[B,640,1]`, `decoder_out f32[B,640,1]` →
  `logits f32[B,1,1,8198]` = 8192 BPE + blank (id 8192) + 5 TDT
  durations `{0,1,2,3,4}`.
- `tokens.txt`: `<token> <id>` per line, `▁` marks a word start;
  token-identical to parakeet-tdt-0.6b-v3.

The bundle contains **no feature extractor**. Feature extraction is our
responsibility and is a model-specific preprocessing step (§4).

### 2.3 Feature extraction

`nemo128.onnx` from the `onnx-asr` 0.12.0 wheel (MIT, author Ilya Stupakov,
SHA-256 `5b4a84c52eeaa615dc46d781cc7e4598f9b432184831d57493c48adcd01371a9`,
139 KB) implements NeMo's 128-bin log-mel with per-feature normalization:
`waveforms f32[B,N]`, `waveforms_lens i64[B]` → `features f32[B,128,T]`,
`features_lens i64[B]`. Running it through ORT gives a feature path that
is identical on every platform with no hand-written DSP. It is vendored
into `native/asr-runtime/assets/` with a NOTICE entry.

### 2.4 Spike results (Python reference, ORT 1.23.2, 8 threads, Linux x64)

| Audio | sherpa-onnx 1.13.8 | nemo128 + greedy TDT | Text |
|---|---|---|---|
| EN JFK 11 s | 0.72 s | 0.95 s | identical |
| RU 11 s | 0.87 s | 0.94 s | 3 word-level differences |
| RU 71 s | 5.83 s | 6.32 s | ~8 word-level differences |

The decoding loop is proven (exact match on EN). The RU differences come
from feature extraction (sherpa uses kaldi-fbank, not NeMo's exact
preprocessing); neither side is uniformly better (e.g. ours gets
"на одр убогий", sherpa gets "к вечной гибели"). Decision: **NeMo-exact
features (`nemo128.onnx`) are canonical**; the C++ implementation must
match the Python reference (`nemo128 + greedy TDT`) **exactly**, and sherpa
output is a secondary sanity check (small CER delta, not equality).

## 3. Decision

Build ONE cross-platform native ASR runtime with a narrow, versioned C ABI,
ONNX Runtime as the inference provider and **model-family adapters**. An
ONNX graph is not an ASR model: TDT, CTC, RNN-T and encoder-decoder models
differ in preprocessing, decoder loops, tokenization and streaming.

```
macOS Swift app                     Windows frontend (future)
      |                                       |
      |  framed IPC v1 (stdin/stdout)          |  C ABI (in-process) or IPC
      v                                       v
SuperDictateOnnxHost  ------------>  libsd_asr (C++17, C ABI sd_asr.h)
                                       |-- ORT env/session factory, providers
                                       |-- audio canonicalization
                                       |-- families/nemo_tdt   (P0: Parakeet Ultra)
                                       |-- families/ctc        (later: GigaAM v3)
                                       `-- ONNX Runtime 1.23.2 C/C++ API
```

- The GGUF path (parakeet.cpp, whisper.cpp) stays intact and remains the
  default. ONNX is opt-in until §10 gates pass.
- On macOS the app does **not** link ONNX Runtime. It talks to a helper
  process `SuperDictateOnnxHost` (crash isolation, bounded shutdown by
  killing the process, no SwiftPM binary target, no ggml/ORT co-residence).
- The ORT C++ header (`onnxruntime_cxx_api.h`) is the header-only C++
  wrapper over the ORT C API; it is used internally only. The exported
  surface is plain C.

## 4. Contract

### 4.1 C ABI (`native/asr-runtime/include/sd_asr.h`)

```c
uint32_t sd_asr_api_version(void);                       /* == SD_ASR_API_VERSION (1) */
sd_asr_status sd_asr_create(const char *config_json, sd_asr_handle **out, char **error_json);
sd_asr_status sd_asr_get_status(sd_asr_handle *h, char **status_json);
sd_asr_status sd_asr_transcribe_pcm_f32(sd_asr_handle *h, const float *mono, uint64_t count,
                                        uint32_t sample_rate, const char *options_json,
                                        char **result_json, char **error_json);
sd_asr_status sd_asr_cancel(sd_asr_handle *h, const char *request_id);   /* "*" = any */
void          sd_asr_destroy(sd_asr_handle *h);
void          sd_asr_free(char *p);
```

- Every `char**` out-parameter is either NULL or a NUL-terminated UTF-8
  buffer allocated by the library; the caller releases it with
  `sd_asr_free` and nothing else. Out-parameters may be NULL if the caller
  does not want them.
- `sd_asr_status` values = error categories: `OK`, `INVALID_ARGUMENT`,
  `INVALID_MODEL`, `UNSUPPORTED_MODEL_FAMILY`, `INVALID_AUDIO`,
  `PROVIDER_UNAVAILABLE`, `MODEL_LOAD_FAILED`, `INFERENCE_FAILED`,
  `CANCELLED`, `TIMEOUT`, `RUNTIME_CRASHED`, `BUSY`. `error_json` is
  `{"category":"invalid_audio","message":"…"}`.
- A handle runs **one inference at a time**; a concurrent call returns
  `BUSY` (never queues, never corrupts state). `sd_asr_cancel` is the only
  function safe to call concurrently with a running transcription.
  `TIMEOUT` and `RUNTIME_CRASHED` are produced by the host/IPC layer.

### 4.2 Config (create)

```json
{ "engine": "onnxruntime", "model_directory": "/…/parakeet-ultra-int8",
  "provider": "auto|cpu|coreml|directml", "language": "auto|ru|en",
  "assets_directory": "/…/Contents/Resources/onnx-asr",
  "intra_op_threads": 0, "inter_op_threads": 1, "allow_spinning": true,
  "verify_checksums": false, "allow_unvalidated_providers": false }
```

`model_id`, `model_family`, quantization and file list come from the model
directory's `manifest.json` (§7) — the caller cannot claim a family the
manifest does not declare. `intra_op_threads: 0` = default policy
`max(2, min(8, cores/2))` (same as the GGUF engine). The per-step graphs
(preprocessor, decoder, joiner) always run single-threaded. ORT thread
spinning stays enabled for the encoder by default: it is bounded (measured
0.00 s CPU over 3 s idle after an inference) and disabling it costs ~25 %
encoder throughput (8 threads, Linux x64). `allow_spinning: false` is the
low-power escape hatch.

### 4.3 Result (transcribe)

```json
{ "text": "…", "language": "auto", "model_id": "parakeet-ultra-int8",
  "request_id": "…", "processing_seconds": 0.41, "audio_seconds": 5.2, "rtf": 0.079,
  "provider_requested": "auto", "provider_actual": "cpu",
  "provider_fallback_reason": "…", "frame_sec": 0.08,
  "tokens": [{"id": 412, "t": 0.48, "conf": 0.98}],
  "words":  [{"w": "Привет", "start": 0.48, "end": 0.72, "conf": 0.97}],
  "warnings": ["non_finite_samples_replaced"] }
```

`text`, `frame_sec`, `tokens`, `words` deliberately match the existing
parakeet.cpp bridge JSON (`TokenTranscription.swift`), so the overlap-window
path works unchanged. `tokens`/`words` are capabilities (`timestamps` in
the manifest); options `{"timestamps": false}` omit them.

### 4.4 Internal types

`ASRModelDescriptor { id, family, graph_files, auxiliary_files,
sample_rate, language_support, provider_support, streaming_support,
punctuation, capitalization, timestamps, manifest_revision }` and an
`ExecutionProvider` enum kept separate from `ModelFamily`. No provider
implies support for a family; the manifest lists validated providers.

## 5. Audio and decoding

Canonical input: mono float32 PCM at the model rate (16 kHz).

1. `count == 0` → `INVALID_AUDIO`. `sample_rate != 16000` → `INVALID_AUDIO`
   in API v1 (the app always captures 16 kHz; a resampler is a later,
   additive capability). Duration > 30 min → `INVALID_AUDIO`.
2. Non-finite samples → replaced by 0 with warning
   `non_finite_samples_replaced`; samples clipped to [-1, 1] with warning
   `samples_clipped`. Channel mixing is the caller's job (input is mono).
3. Shorter than 0.25 s → zero-padded to 0.25 s (the conformer needs a
   minimum number of frames); warning `padded_short_audio`.
4. Features: `nemo128.onnx` (Parakeet family). Frame stride: 10 ms hop ×
   subsampling 8 = 80 ms per encoder frame.
5. TDT greedy decoding (Parakeet family): decoder primed with blank; at
   frame `t` run joiner, `token = argmax(logits[0..8192])`,
   `skip = durations[argmax(logits[8193..])]`; on a non-blank token emit
   it and advance the LSTM state; advance `t += skip` if `skip > 0`, else
   `t += 1` on blank or after `max_symbols_per_frame` (10) emissions.
6. Detokenization: concatenate tokens, `▁` → space, trim leading space.
   Words = token runs starting at a `▁` token. Token confidence = softmax
   probability of the chosen token.

Downstream stays unchanged: pause segmentation, overlap seam dedup,
Russian number normalization, vocabulary corrections, LLM correction and
rewrite. Mixed RU/EN output is evaluated, not transliterated.

Families, incrementally:

- **P0 — Parakeet Ultra int8 (TDT)**, exact parity with the Python
  reference, sanity versus sherpa-onnx, quality comparison versus GGUF
  parakeet-tdt-0.6b-v3 q8_0 on the RU corpus before it may become default.
- **P1 — GigaAM v3 e2e CTC** (`istupakov/gigaam-v3-onnx`, MIT;
  `gigaam_v3.onnx` preprocessor; the CTC join regex is Unicode-word-aware
  and must be hand-implemented, not ported to `std::regex`).
- **P2 — cache-aware streaming RNN-T** as a separate API extension.

## 6. Platform provider policy

| Platform | Required | Optional, gated |
|---|---|---|
| macOS x86_64 | CPU | CoreML EP only per-model verified; never promise AMD GPU offload |
| macOS arm64 | CPU | CoreML EP after per-model tests |
| Windows x64 | CPU | DirectML EP (separate DirectML build) after device/driver/op tests |

- Discovery at runtime (`OrtGetAvailableProviders`).
- `provider=auto` resolves to CPU in API v1 (no accelerator is validated
  for Parakeet Ultra yet) and reports
  `provider_fallback_reason="accelerators not validated for this model"`.
- Explicit `coreml`/`directml` that is unavailable → `PROVIDER_UNAVAILABLE`,
  never a silent CPU run labelled as GPU. When an accelerator EP is
  registered, `provider_actual` is `"coreml+cpu"` / `"directml+cpu"`
  because ORT may place unsupported nodes on CPU.
- Metal is not an ORT EP.

## 7. Model manifest and cache

Each ONNX model directory contains a `manifest.json` written by the
downloader from the app's pinned catalog:

```json
{ "schema": 1, "model_id": "parakeet-ultra-int8", "family": "nemo_tdt",
  "revision": "3282a6e…", "license": "CC-BY-4.0", "quantization": "int8",
  "sample_rate": 16000, "languages": ["en","de",…,"ru","uk"],
  "capabilities": {"timestamps": true, "punctuation": true, "capitalization": true, "streaming": false},
  "providers": ["cpu"],
  "files": { "encoder": {"path": "encoder.int8.onnx", "size": 611879344, "sha256": "…"}, … },
  "params": { "feature_dim": 128, "subsampling_factor": 8, "blank_id": 8192,
              "durations": [0,1,2,3,4], "max_symbols_per_frame": 10,
              "pred_hidden": 640, "pred_rnn_layers": 2, "hop_seconds": 0.01 } }
```

- The native loader rejects: missing files, size mismatch, symlinks /
  non-regular files, paths that are absolute or contain `..` / separators,
  unknown family. `verify_checksums: true` also re-hashes (used by tests
  and diagnostics, not every launch; the downloader already verified).
- The preprocessor graph `nemo128.onnx` ships inside the app bundle
  (`Contents/Resources/onnx-asr/`), referenced from the manifest as
  `{"bundled": "nemo128.onnx"}`, so it is versioned with the code.
- Download: same-volume temp file, SHA-256 + size check, then atomic
  rename; manifest written last (its presence marks a complete install).
  macOS cache: the existing `speechModelCacheBaseDirectory()` convention,
  subdirectory `onnx/<model_id>/`. Windows: `%LOCALAPPDATA%/SuperDictate/models/onnx/<model_id>/`.
- Model selection is separate from backend selection
  (`parakeet_tdt_v3` = GGUF, `parakeet_ultra_onnx` = ONNX). Existing GGUF
  downloads and settings are untouched; nobody is redirected silently.

## 8. Process lifetime, IPC, concurrency

`SuperDictateOnnxHost` holds one model per process. Framing v1 (all
little-endian), **not** the unversioned Whisper framing:

```
request : "SDAQ" | u16 version=1 | u16 type | u64 request_id | u32 json_len | u64 pcm_bytes | json | pcm(f32)
response: "SDAR" | u16 version=1 | u16 status | u64 request_id | u32 json_len | json
types   : 1 CREATE(json=config)  2 TRANSCRIBE(json=options, pcm)  3 STATUS
          4 CANCEL(json={"target": <request_id>})  5 SHUTDOWN
```

TRANSCRIBE options may carry `"sample_rate"` (default 16000); the host sets
`request_id` to the frame's id. A CANCEL frame has its own request id (its
acknowledgement) and names the victim in `target`; the cancelled request
then answers with status `CANCELLED` under its own id.

- Bounds: `json_len ≤ 1 MiB`, `pcm_bytes ≤ 30 min × 16 kHz × 4`, `pcm_bytes % 4 == 0`.
  Violations → error response + host exits (stream is no longer trustworthy).
- Exact read loops; EOF on stdin → clean exit (parent-death contract);
  POSIX hosts also exit when re-parented (`getppid()` changes).
- A reader thread keeps reading while a TRANSCRIBE runs, so CANCEL is
  honoured via `RunOptions::SetTerminate`; a second TRANSCRIBE while busy
  gets `BUSY`. Hard timeout = the Swift side kills the process and
  restarts it on the next request.
- Swift `OnnxAsrEngine` mirrors `WhisperCppEngine`'s safety rules
  (throwing-only IO, no `synchronizeFile`, helper resolved from
  `Contents/Helpers`). A failed segment keeps already completed segments
  and propagates `hadSegmentFailure` through the existing segmentation code.

## 9. UI and diagnostics

Expose model, backend, provider requested/actual, quantization, language,
model size, warm-up and inference latency, RTF. Statuses: Loading, Ready,
Inference, CPU fallback, Error, Unsupported. All inference stays local.
The ONNX model appears as a separate, clearly experimental entry until the
gates pass; existing Parakeet/GPU preferences are preserved.

## 10. Build and packaging

- `native/asr-runtime/` — CMake (≥ 3.20), C++17, targets `sd_asr` (static
  lib + C ABI), `SuperDictateOnnxHost`, `sd_asr_cli`, tests. Platforms:
  `macos-x86_64`, `macos-arm64`, `windows-x64`; `linux-x64` for dev/CI.
- `scripts/fetch-onnxruntime.sh <platform>` downloads the pinned archive,
  verifies SHA-256, extracts to `native/asr-runtime/third_party/onnxruntime/<platform>/`
  (git-ignored).
- macOS bundle: `Contents/Helpers/SuperDictateOnnxHost`,
  `Contents/Frameworks/libonnxruntime.1.23.2.dylib`, host rpath
  `@executable_path/../Frameworks`; signed with the same identity as the
  rest of the bundle (AGENTS.md); `otool -L` must show no Homebrew paths.
- Windows: host + `onnxruntime.dll` side by side; MSVC release; VC runtime check.
- No vendor ggml tree is modified; ORT and ggml never share a binary.

## 11. Testing and release gates

1. C ABI contract tests (no model): version, bad JSON, missing/forged
   manifest, symlink/traversal, empty/NaN/wrong-rate audio, NULL out
   params, `sd_asr_free(NULL)`.
2. Model tests (model dir via `SD_ASR_TEST_MODEL_DIR`): exact text parity
   with the Python reference goldens; BUSY on concurrent call; cancel.
3. IPC tests: round-trip, oversize frame, bad magic, EOF exit, cancel.
4. Russian dictation corpus: WER/CER, names, Cyrillic/Latin script
   precision/recall (`GitHub`, `Debian`, `Docker`, `CarPlay`, `OpenAI`,
   `llama.cpp`); compared against GGUF Parakeet v3.
5. Regression of segmentation, seam dedup, vocabulary learning, correction.
6. CPU RTF, peak RSS, warm-up on Intel macOS and Windows x64.
7. Clean-machine packaging checks; no network after model install.

**Acceptance (first release):** GGUF default unchanged; Parakeet Ultra ONNX
loads and transcribes on macOS Intel CPU (and Windows CPU via the CLI host);
pinned multi-file download; honest provider reporting; clean packaging;
no regressions in long dictation and correction.

## 12. Implementation status (2026-10-10)

W1–W3 are implemented in `native/asr-runtime/` and verified on Linux x64
with ONNX Runtime 1.23.2: contract tests (12 cases), IPC framing tests,
model tests (exact text parity with `tools/reference_tdt.py` on EN 11 s,
RU 11 s and RU 71 s; BUSY; cancel), and the host integration test
(`tests/host_test.py`). Measured on a 44-core Xeon, 8 intra-op threads:
RU 71 s in 6.2 s (RTF 0.087), RU 11 s in 0.9 s; peak RSS ≈ 1.0 GB.
Not yet verified on macOS or Windows (no toolchain on the dev box).

## 13. Waves

| Wave | Content | Verifiable where |
|---|---|---|
| W0 | This spec + plan | — |
| W1 | `native/asr-runtime` skeleton: CMake, ORT fetch (pinned), C ABI, JSON, manifest validation, audio canonicalization, provider policy, contract tests | Linux (here), macOS, Windows |
| W2 | `nemo_tdt` family (nemo128 + encoder + TDT greedy + detok + words), `sd_asr_cli`, golden parity tests vs Python reference | Linux, macOS |
| W3 | `SuperDictateOnnxHost` + framing v1 + IPC tests | Linux, macOS |
| W4 | Swift: catalog + multi-file downloader, `OnnxAsrEngine`, new `SpeechModelProfile.parakeetUltraOnnx` (every `==` site handled), TranscriptionWorker wiring, diagnostics | Intel Mac only |
| W5 | Packaging: `build-app.sh` builds host via CMake, embeds dylib, signs, `otool` check; CI job | Intel Mac / CI |
| W6 | Quality & perf gates vs GGUF; optional CoreML/DirectML behind flags | Intel Mac, Windows |
| W7 | GigaAM v3 CTC family; consolidation of selectors/diagnostics | all |

## 14. Non-goals

No LLM migration to ONNX; no Python at runtime (Python is used only to
produce test goldens); no assumption that `.onnx` files share a decoder; no
silent "GPU" label on CPU execution; no removal of GGUF or Whisper; no
streaming in the first release.
