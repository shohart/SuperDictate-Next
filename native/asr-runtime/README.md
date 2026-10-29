# sd_asr — cross-platform ONNX ASR runtime

Spec: `docs/specs/cross-platform-onnx-asr-spec.md`. Plain C++17 + CMake, no
Swift, no Python at runtime. Builds on macOS (x86_64/arm64), Windows x64 and
Linux x64 (development/CI).

```
include/sd_asr.h          C ABI v1 (the only exported surface)
src/                      manifest, audio canonicalization, ORT sessions, ABI glue, IPC framing
src/families/nemo_tdt.cpp Parakeet (FastConformer + TDT) family
src/families/gigaam_rnnt.cpp GigaAM v3 e2e (Conformer + RNN-T) family
src/families/family_util.* shared family helpers (params, tokens, text/word rules)
src/families/hotwords.*   ASR hotwords: phrase tokenizers, boosting trie, greedy rollback (docs/specs/asr-hotwords-spec.md)
host/onnx_host_main.cpp   SuperDictateOnnxHost helper process (framed IPC v1)
tools/sd_asr_cli.cpp      transcribe WAV files through the C ABI
tools/make_manifest.py    install manifest.json for a hand-downloaded model (dev)
tools/reference_tdt.py    Python reference for nemo_tdt -> golden transcripts (dev)
tools/reference_gigaam.py Python reference for gigaam_rnnt (onnx-asr twin) -> goldens (dev)
tools/reference_hotwords.py Python reference hotwords used by both references (dev)
tools/spm_to_tsv.py       SentencePiece tokenizer.model -> piece/score tsv (dev)
catalog/onnx-models.json  pinned model catalog (URLs, sizes, SHA-256, licence)
assets/nemo128.onnx       bundled NeMo log-mel feature graph (onnx-asr, MIT)
assets/gigaam_v3.onnx     bundled GigaAM v3 log-mel feature graph (onnx-asr 0.12.0, MIT)
assets/onnx-asr-LICENSE.txt licence of both bundled feature graphs
assets/gigaam_v3_spm.tsv  GigaAM v3 SentencePiece piece scores for hotwords (from ai-sage/GigaAM-v3
                          @7655ad717f8122257385bb4b2f373db3697e8680 tokenizer.model, MIT; tools/spm_to_tsv.py)
tests/                    contract, IPC, model-parity and host tests
```

## Build and test

```sh
scripts/fetch-onnxruntime.sh                 # pinned ORT 1.23.2 for this host
cmake -S native/asr-runtime -B native/asr-runtime/build -DCMAKE_BUILD_TYPE=Release
cmake --build native/asr-runtime/build -j
ctest --test-dir native/asr-runtime/build --output-on-failure
```

Model tests run only when a model is installed:

```sh
# 1. download the files listed for parakeet-ultra-int8 in catalog/onnx-models.json into $MODEL
python3 native/asr-runtime/tools/make_manifest.py native/asr-runtime/catalog/onnx-models.json \
    parakeet-ultra-int8 "$MODEL" --verify
# 2. parity audio (pinned SHA-256) + committed goldens into $GOLDEN
native/asr-runtime/tests/fixtures/fetch-audio.sh "$GOLDEN"
#    (regenerate goldens only on purpose: venv with onnxruntime==1.23.2 numpy soundfile)
#    python3 native/asr-runtime/tools/reference_tdt.py "$MODEL" native/asr-runtime/assets \
#        native/asr-runtime/tests/fixtures "$GOLDEN"/*.wav
# 3. parity + host
SD_ASR_TEST_MODEL_DIR="$MODEL" SD_ASR_TEST_GOLDEN_DIR="$GOLDEN" \
    ctest --test-dir native/asr-runtime/build --output-on-failure
python3 native/asr-runtime/tests/host_test.py native/asr-runtime/build/SuperDictateOnnxHost \
    "$MODEL" "$PWD/native/asr-runtime/assets" "$GOLDEN/ru_long_example.wav" "$GOLDEN/ru_long_example.txt"
```

GigaAM v3 (`gigaam-v3-e2e-rnnt-int8`, Russian) is tested the same way with its
own goldens; any 16 kHz WAVs work (no committed goldens yet):

```sh
python3 native/asr-runtime/tools/make_manifest.py native/asr-runtime/catalog/onnx-models.json \
    gigaam-v3-e2e-rnnt-int8 "$GIGAAM" --verify
# venv: onnxruntime==1.23.2 numpy soundfile (+ onnx-asr==0.12.0 for --check-onnx-asr)
python3 native/asr-runtime/tools/reference_gigaam.py --check-onnx-asr "$GIGAAM" native/asr-runtime/assets \
    "$GIGAAM_GOLDEN" "$GIGAAM_GOLDEN"/*.wav      # writes <name>.txt + <name>.tokens.json
SD_ASR_TEST_MODEL_DIR="$GIGAAM" SD_ASR_TEST_GOLDEN_DIR="$GIGAAM_GOLDEN" \
    ctest --test-dir native/asr-runtime/build --output-on-failure
```

Hotwords (docs/specs/asr-hotwords-spec.md §9): put `hotwords.txt` (e.g.
`tests/fixtures/hotwords.txt`) and a few WAVs into the golden directory and
let the family's reference write the biased goldens next to the plain ones
(`<name>.hw.txt` + `<name>.hw.tokens.json`); `model_tests` then checks exact
parity with hotwords, that an empty list changes nothing, and that phrases
which diverge roll back without losing the tail:

```sh
python3 native/asr-runtime/tools/reference_tdt.py --hotwords "$GOLDEN/hotwords.txt" \
    "$MODEL" native/asr-runtime/assets "$GOLDEN" "$GOLDEN"/*.wav
native/asr-runtime/build/sd_asr_cli --model "$MODEL" --assets native/asr-runtime/assets \
    --hotwords "$GOLDEN/hotwords.txt" [--hotwords-score 3] --text-only file.wav
```

The references read 16-bit PCM WAVs with the `wave` module when soundfile is
not installed, and also write `<name>.tokens.json` for token-level parity.

`--check-onnx-asr` compares with onnx-asr run on the same `gigaam_v3.onnx`
graph; onnx-asr's default CPU path uses a numpy feature extractor instead, whose
features differ slightly (a few words differ on long files).

Goldens were produced on an AVX2-only x86_64 CPU. On a different CPU class
int8 kernels may flip a rare argmax; use `SD_ASR_TEST_PARITY=cer:0.02` there.

Manual transcription:

```sh
native/asr-runtime/build/sd_asr_cli --model "$MODEL" --assets native/asr-runtime/assets --text-only file.wav
```

## App integration (macOS)

`scripts/build-onnx-host.sh <staged.app>` (called by `build-app.sh` and
`build-test-app.sh`) builds the host in `build-bundle/` with
`CMAKE_BUILD_WITH_INSTALL_RPATH=ON` and stages `Contents/Helpers/SuperDictateOnnxHost`,
`Contents/Frameworks/libonnxruntime.1.23.2.dylib` and
`Contents/Resources/onnx-asr/` (catalog, `nemo128.onnx`, `gigaam_v3.onnx`,
`gigaam_v3_spm.tsv`, ORT and onnx-asr licences). The Swift side is `OnnxAsrEngine.swift` / `OnnxModelDownload.swift`;
the speech profiles `parakeet_ultra_onnx` (default) and `gigaam_v3_onnx` (Russian)
are CPU-only. Diagnostics without
launching the app:

```sh
SuperDictate --benchmark-transcribe onnx cpu 8 file.wav... # packaged or swift build binary
SuperDictate --benchmark-transcribe gigaam cpu 8 file.wav... # same, GigaAM v3
SUPERDICTATE_ONNX_TEST_WAV=file.wav Parakey --self-test onnx-asr-real   # debug build
SUPERDICTATE_ONNX_TEST_PROFILE=gigaam_v3_onnx SUPERDICTATE_ONNX_TEST_MODEL_DIR=<installed dir> \
  SUPERDICTATE_ONNX_TEST_WAV=file.wav Parakey --self-test onnx-asr-real   # any installed model dir
```
