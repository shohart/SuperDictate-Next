# sd_asr — cross-platform ONNX ASR runtime

Spec: `docs/specs/cross-platform-onnx-asr-spec.md`. Plain C++17 + CMake, no
Swift, no Python at runtime. Builds on macOS (x86_64/arm64), Windows x64 and
Linux x64 (development/CI).

```
include/sd_asr.h          C ABI v1 (the only exported surface)
src/                      manifest, audio canonicalization, ORT sessions, ABI glue, IPC framing
src/families/nemo_tdt.cpp Parakeet (FastConformer + TDT) family
host/onnx_host_main.cpp   SuperDictateOnnxHost helper process (framed IPC v1)
tools/sd_asr_cli.cpp      transcribe WAV files through the C ABI
tools/make_manifest.py    install manifest.json for a hand-downloaded model (dev)
tools/reference_tdt.py    Python reference implementation -> golden transcripts (dev)
catalog/onnx-models.json  pinned model catalog (URLs, sizes, SHA-256, licence)
assets/nemo128.onnx       bundled NeMo log-mel feature graph (onnx-asr, MIT)
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

Goldens were produced on an AVX2-only x86_64 CPU. On a different CPU class
int8 kernels may flip a rare argmax; use `SD_ASR_TEST_PARITY=cer:0.02` there.

Manual transcription:

```sh
native/asr-runtime/build/sd_asr_cli --model "$MODEL" --assets native/asr-runtime/assets --text-only file.wav
```
