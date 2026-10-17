# ONNX ASR runtime — implementation plan

Spec: `docs/specs/cross-platform-onnx-asr-spec.md` (rev. 2). Branch:
`feat/onnx-asr-runtime`. Primary model: Parakeet Ultra int8
(`mldecode/parakeet-ultra-onnx-int8@3282a6e`). ONNX Runtime pinned to 1.23.2.

Environment note: the development box for W1–W3 is Linux x64 (no Swift);
the Intel Mac is required for W4–W6. Everything in W1–W3 is plain C++17 +
CMake and is built/tested on Linux first, then on macOS.

## W1 — native core skeleton

1. `scripts/fetch-onnxruntime.sh <linux-x64|osx-x86_64|osx-arm64|win-x64>`:
   pinned URL + SHA-256 table (spec §2.1), download to temp, verify,
   extract to `native/asr-runtime/third_party/onnxruntime/<platform>/`.
   `.gitignore` the extraction root.
2. `native/asr-runtime/CMakeLists.txt`: `SD_ASR_ORT_ROOT` (defaults to the
   fetched platform dir), targets `sd_asr` (static), `sd_asr_cli`,
   `SuperDictateOnnxHost`, `sd_asr_tests`; CTest registration; rpath
   `@executable_path/../Frameworks` on macOS, `$ORIGIN` on Linux.
3. Vendored `third_party/nlohmann/json.hpp` (v3.11.3, MIT, pinned hash).
4. `include/sd_asr.h` — C ABI exactly per spec §4.1.
5. `src/manifest.{h,cpp}` — manifest parsing + validation (§7).
6. `src/audio.{h,cpp}` — canonicalization (§5 steps 1–3) with warnings.
7. `src/ort_session.{h,cpp}` — Ort::Env singleton, session options
   (threads policy, spinning off, ORT_ENABLE_ALL), provider resolution
   (§6), UTF-8 → wide path on Windows.
8. `src/sd_asr.cpp` — ABI glue: error JSON, status JSON, BUSY guard
   (atomic flag), cancel via RunOptions terminate, `sd_asr_free`.
9. `tests/contract_tests.cpp` — spec §11.1 cases, no model required.

## W2 — Parakeet TDT family

1. `assets/nemo128.onnx` (onnx-asr 0.12.0, MIT) + `NOTICE.md` entry.
2. `src/families/nemo_tdt.{h,cpp}` — preprocessor → encoder → greedy TDT
   (§5.5) → tokens (softmax conf, t = frame × 0.08 s) → words → text.
3. `tools/sd_asr_cli.cpp` — `sd_asr_cli <model_dir> <wav>...` (16-bit/
   float WAV reader, mono, 16 kHz), prints result JSON.
4. `tools/make_manifest.py` (dev only) writes `manifest.json` for a model
   dir from the catalog; `catalog/onnx-models.json` holds the pins (also
   consumed by the Swift downloader in W4).
5. `tools/reference_tdt.py` (dev only, Python + onnxruntime==1.23.2) —
   the reference implementation; writes goldens.
6. `tests/model_tests.cpp` — gated on `SD_ASR_TEST_MODEL_DIR` +
   `SD_ASR_TEST_GOLDEN_DIR`: exact text parity, BUSY, cancel, timestamps
   monotonic, words concatenate to text.

## W3 — helper host + IPC v1

1. `src/ipc.{h,cpp}` — frame encode/decode with bounds (§8).
2. `host/onnx_host_main.cpp` — reader thread, single worker, CANCEL,
   STATUS, SHUTDOWN, EOF + re-parent exit.
3. `tests/ipc_tests.cpp` — framing unit tests; `tests/host_tests.py`
   (dev only) — spawn host: create/transcribe/cancel/oversize/EOF.

## W4–W7

Per spec §12. W4 begins with a grep of every `SpeechModelProfile` switch
and `== .parakeetTDTv3` site; the ONNX engine is a new
`LoadedEngine.onnx(OnnxAsrEngine)` case whose `transcribeWithTokens`
returns the same `TokenTranscription` JSON shape.
