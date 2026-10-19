# GigaAM v3 e2e RNN-T as a second ONNX speech model — plan

Date: 2026-10-19. Spec: `docs/specs/cross-platform-onnx-asr-spec.md` (§5 lists
GigaAM v3 as P1; this plan implements its **e2e RNN-T** variant instead of
e2e CTC — measured below). Repo rules: `AGENTS.md` (never launch .app
bundles; self-tests only on the `swift build` debug binary; after any
self-test check the production LaunchAgent).

## Why

User dictation (real voice) through Parakeet Ultra produced Russian
word-form errors («растрома», «Подготов», «междуугороднюю») that the
LLM corrector cannot fix. A quick check on this Mac (onnx-asr 0.12.0,
CPU, int8, 8 threads):

| Model | WER, 4-min RU TTS (`ref.txt`) | 4 min audio |
|---|---|---|
| Parakeet Ultra (app, segmented) | 0.075 | 30 s |
| GigaAM v3 e2e RNN-T | **0.015** | 18 s |
| GigaAM v3 e2e CTC | 0.025 | 17 s |

e2e = punctuation, capitalization, ё, digits («пунктом 50»). Goal: the user
picks the speech model in Settings: Parakeet Ultra (multilingual) or GigaAM
v3 (Russian). Parakeet Ultra stays the default.

## Model

`istupakov/gigaam-v3-onnx` @ `322c3b29492673eb7d0b434bfa9dfb8653e34d02`, MIT
(LICENSE.txt in the repo; upstream ai-sage/GigaAM, MIT).
`https://huggingface.co/istupakov/gigaam-v3-onnx/resolve/<rev>/<file>`:

| role | file | size | sha256 |
|---|---|---|---|
| encoder | v3_e2e_rnnt_encoder.int8.onnx | 224570477 | 4e0e076a6076cd110277e529b8ac8f32cd5297f7fbebad5341ae8ddb7d00817b |
| decoder | v3_e2e_rnnt_decoder.int8.onnx | 1159170 | 89014e134865615b91e037157e46e389b1271e6072460efc010ea08e61e23146 |
| joiner | v3_e2e_rnnt_joint.int8.onnx | 687791 | ade116563dbf66e503b0994efab6b5861412743e52bf31c39fc3fffa3783d5d1 |
| tokens | v3_e2e_rnnt_vocab.txt | 13354 | (compute after download) |

Preprocessor (bundled, like nemo128): `gigaam_v3.onnx` from the onnx-asr
0.12.0 wheel (`onnx_asr/preprocessors/data/gigaam_v3.onnx`, MIT, sha256
`919c3bc8a434b6e733e5fe5dcd247974d0a7b1f2bc5b6995b6ad55f7225e014d`). Copy it
to `native/asr-runtime/assets/gigaam_v3.onnx`; record provenance + MIT
licence text in `native/asr-runtime/assets/` (and ThirdPartyNotices if the
bundle has one for ORT).

Local copies already downloaded and SHA-verified:
`$SCRATCH/gigaam/` (all four e2e files + vocabs, yaml, config, LICENSE) and
the preprocessor in `$SCRATCH/punct/venv/lib/python3.12/site-packages/onnx_asr/preprocessors/data/`.
A Python 3.12 venv with onnxruntime 1.23.2 + onnx-asr 0.12.0 + numpy is at
`$SCRATCH/punct/venv` (use `-I`; force `providers=["CPUExecutionProvider"]`
— CoreML is picked by default on this Mac and returns garbage).

### Graph I/O

- `gigaam_v3.onnx`: waveforms f32[1,N] (16 kHz, [-1,1]), waveforms_lens
  i64[1] → features f32[1,64,T], features_lens i64[1].
- encoder: audio_signal f32[1,64,T], length i64[1] → encoded f32[1,768,T'],
  encoded_len **int32**[1]. Subsampling 4, hop 10 ms → frame_sec 0.04.
- decoder: x i64[1,1], h.1 f32[1,1,320], c.1 f32[1,1,320] → dec f32[1,1,320],
  h, c. Initial state zeros; initial x = blank.
- joint: enc f32[1,768,1] (encoder frame t), dec f32[1,320,1] (dec
  transposed) → joint f32[1,1,1,1025] logits.
- vocab: lines `<token> <id>`, `▁` = word start, `<blk>` = 1024 (blank),
  `<unk>` = 0.

### Greedy RNN-T (onnx-asr `_AsrWithTransducerDecoding`, max_tokens_per_step 3)

```
state = zeros; tokens = []; t = 0; emitted = 0
dec_out cached for (last token, state) — recompute only after an emission
while t < T':
    logits = joint(enc[t], dec_out(prev token or blank, state))
    k = argmax(logits)
    if k != blank: emit k at frame t; state = new state; emitted += 1
    if k == blank or emitted == 3: t += 1; emitted = 0
```

Text: concatenate tokens with `▁`→space, then apply onnx-asr's
`DECODE_SPACE_PATTERN = r"\A\s|\s\B|(\s)\b"` (Unicode-aware Python `re`):
drop a leading space; drop a space not followed by a word boundary (e.g.
before punctuation); keep a space before a word. Hand-implement with a
Unicode word-char test (letters/digits/underscore incl. Cyrillic) — no
`std::regex`. Token time = frame × 0.04 s; confidence = softmax prob of the
chosen token. Words = runs starting at a `▁` token (same rule as nemo_tdt),
word conf = min token conf. Result JSON identical in shape to nemo_tdt
(`text`, `frame_sec`, `tokens[{id,t,conf}]`, `words[{w,start,end,conf}]`) so
the Swift overlap path (`transcribeWithTokens`) works unchanged.

## Task 1 — native family `gigaam_rnnt` (C++)

1. `src/families/gigaam_rnnt.cpp` implementing `ModelFamily` (look at
   `nemo_tdt.cpp` for session creation via `SessionFactory`, cancellation via
   `RunContext`, threading, error codes). Move/extend `create_model_family`
   dispatch so `manifest.family == "gigaam_rnnt"` builds it.
2. Catalog entry `gigaam-v3-e2e-rnnt-int8` in
   `native/asr-runtime/catalog/onnx-models.json` (family `gigaam_rnnt`,
   languages ["ru"], capabilities punctuation+capitalization+timestamps,
   files above + preprocessor `{bundled: gigaam_v3.onnx, sha256}`, params:
   feature_dim 64, subsampling_factor 4, hop_seconds 0.01, vocab_size 1025,
   blank_id 1024, max_symbols_per_frame 3, pred_hidden 320). Make sure
   `tools/make_manifest.py` and the C++ manifest validation accept it.
3. CMake: add the source; assets dir gets `gigaam_v3.onnx`.
4. `tools/reference_gigaam.py`: independent numpy twin (mirror of
   onnx-asr's algorithm) writing goldens; cross-check its text equals
   `onnx_asr.load_model("gigaam-v3-e2e-rnnt", dir, quantization="int8")`
   output on the fixtures.
5. Tests: model_tests must run per model dir (SD_ASR_TEST_MODEL_DIR may point
   at the GigaAM dir; goldens dir per model). Exact parity with the
   reference on `~/scratch/onnx-golden/ru_example.wav`, `ru_long_example.wav`
   (split ≤ 25 s if the encoder needs it — check), plus the existing
   silence/short/BUSY/cancel cases. Contract tests stay green for Parakeet.
6. Build: `export PATH=/usr/local/opt/cmake/bin:/usr/local/bin:$PATH;
   cmake --build native/asr-runtime/build && ctest ...` (see
   SESSION_HANDOFF-onnx.md "Шаг 0"). Install the model for tests with
   `tools/make_manifest.py ... --verify` into a scratch dir.
7. `sd_asr_cli` on a GigaAM model dir prints sane Russian text.

## Task 2 — Swift + packaging

1. `SpeechModelProfile.gigaamV3Onnx = "gigaam_v3_onnx"`: displayName
   "GigaAM v3 (ONNX, русский)", about text with MIT attribution (SberDevices
   GigaAM, istupakov ONNX export), size ≈ 215 MB, cache dir
   `speechModelCacheBaseDirectory()/onnx/gigaam-v3-e2e-rnnt-int8/`.
   Handle every `switch` over the profile; `OnnxModelDownload` /
   `TranscriptionWorker.loadOnnxEngine` must take the model id from the
   profile (today they default to `PARAKEET_ULTRA_ONNX_MODEL_ID`).
   Parakeet Ultra stays `productionDefault`.
2. The Settings popup already lists `SpeechModelProfile.allCases` and a
   change triggers the agent restart (`settingsRestartRequired`) — verify
   the new profile downloads, verifies, loads and shows progress.
3. `--benchmark-transcribe [onnx|gigaam] cpu <threads> <wav...>`: pick the
   profile (keep `onnx` = Parakeet Ultra for compatibility).
4. `scripts/build-onnx-host.sh`: also copy `assets/gigaam_v3.onnx` (+ its
   licence/provenance) into `Contents/Resources/onnx-asr/`. Same for
   `build-test-app.sh` if it stages separately.
5. Self-tests: extend `onnx-asr` (hermetic) for catalog parsing of the new
   entry; `onnx-asr-real` should accept a GigaAM model dir via env.
6. `swift build`, relevant `--self-test` groups, then the LaunchAgent safety
   check. Do NOT install or launch any .app — the coordinator does that.

## Done when

- ctest green for both models; reference parity exact for GigaAM.
- `/Applications`-style bundle (built by the coordinator via
  `scripts/install-local.sh`) transcribes `contract16k.wav` / `tts16k.wav`
  with `--benchmark-transcribe gigaam cpu 8` at WER ≈ the onnx-asr numbers.
- Spec §5/§12/§13 updated (P1 = e2e RNN-T, numbers above).
