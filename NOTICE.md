# 📜 Attribution

SuperDictate is derived from
[Parakey](https://github.com/rcourtman/parakey), originally created by
Richard Courtman and distributed under the MIT License.

The original copyright notice and license are preserved in `LICENSE`.
SuperDictate includes substantial product, interface, service-management,
history, statistics, and dictation-workflow modifications by the SuperDictate
contributors.

Speech recognition runs locally through ONNX Runtime (see the ONNX ASR
runtime section below). Pause detection uses the Silero VAD port from
[whisper.cpp](https://github.com/ggml-org/whisper.cpp) over a CPU-only
[ggml](https://github.com/ggml-org/ggml) core (commit
`e705c5fed490514458bdd2eaddc43bd098fcce9b`, tag `v0.13.0`), vendored into
`swift/Sources/silero_vad/` by `scripts/vendor-silero-vad.sh` and
`scripts/vendor-ggml-core.sh`; all three are MIT-licensed, with the exact
license texts in `swift/Sources/silero_vad/upstream/LICENSE-ggml.txt`,
`swift/Sources/silero_vad/upstream-vad/LICENSE-whisper-cpp.txt` and
`swift/Sources/silero_vad/upstream-vad/LICENSE-silero-vad.txt`. Text
correction and rewrite run through
[llama.cpp](https://github.com/ggml-org/llama.cpp) (MIT), vendored into
`swift/Sources/llama_cpp_host/` by `scripts/vendor-llama-cpp.sh` (license
text in `swift/Sources/llama_cpp_host/upstream/LICENSE-llama-cpp.txt`).
Third-party Swift package licenses remain available through their
respective upstream projects.


## ONNX ASR runtime (`native/asr-runtime/`)

- [ONNX Runtime](https://github.com/microsoft/onnxruntime) 1.23.2 (MIT),
  fetched as a pinned, hash-verified prebuilt by
  `scripts/fetch-onnxruntime.sh`; its own `ThirdPartyNotices.txt` ships
  alongside the library.
- `native/asr-runtime/assets/nemo128.onnx` — NeMo-compatible 128-bin log-mel
  feature graph from [onnx-asr](https://github.com/istupakov/onnx-asr) 0.12.0
  by Ilya Stupakov (MIT).
- `native/asr-runtime/assets/gigaam_v3.onnx` — GigaAM v3 64-bin log-mel
  feature graph from the same onnx-asr 0.12.0 wheel
  (`onnx_asr/preprocessors/data/gigaam_v3.onnx`, sha256
  `919c3bc8a434b6e733e5fe5dcd247974d0a7b1f2bc5b6995b6ad55f7225e014d`), MIT;
  licence text in `native/asr-runtime/assets/onnx-asr-LICENSE.txt`.
- `native/asr-runtime/assets/gigaam_v3_spm.tsv` — the GigaAM v3 SentencePiece
  piece scores (hotword tokenizer), converted by
  `native/asr-runtime/tools/spm_to_tsv.py` from
  [ai-sage/GigaAM-v3](https://huggingface.co/ai-sage/GigaAM-v3) revision
  `7655ad717f8122257385bb4b2f373db3697e8680`, `tokenizer.model` (sha256
  `828c12c991019eef952a960661f25a92d6ad279591e2ea466b4aeddf1d20a18a`),
  MIT, SberDevices / GigaChat Team.
- `native/asr-runtime/third_party/nlohmann/json.hpp` —
  [nlohmann/json](https://github.com/nlohmann/json) 3.11.3 (MIT).
- Parakeet Ultra ONNX int8 weights (downloaded at runtime, not bundled):
  [mldecode/parakeet-ultra-onnx-int8](https://huggingface.co/mldecode/parakeet-ultra-onnx-int8),
  CC-BY-4.0 — based on [moondream/parakeet-ultra](https://huggingface.co/moondream/parakeet-ultra),
  a retrain of NVIDIA [parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3).
- GigaAM v3 e2e RNN-T ONNX int8 weights (downloaded at runtime, not bundled):
  [istupakov/gigaam-v3-onnx](https://huggingface.co/istupakov/gigaam-v3-onnx)
  (MIT), an ONNX export of [GigaAM](https://github.com/salute-developers/GigaAM)
  v3 by SberDevices / GigaChat Team (MIT).
- Punctuation restoration weights (downloaded at runtime, not bundled):
  [Horizon-Labs/punctuation-restoration-small](https://huggingface.co/Horizon-Labs/punctuation-restoration-small)
  and [-base](https://huggingface.co/Horizon-Labs/punctuation-restoration-base)
  (Apache-2.0), fine-tunes of [mmBERT](https://huggingface.co/jhu-clsp/mmBERT-base)
  by JHU CLSP (MIT).
