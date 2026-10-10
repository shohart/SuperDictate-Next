# 📜 Attribution

SuperDictate is derived from
[Parakey](https://github.com/rcourtman/parakey), originally created by
Richard Courtman and distributed under the MIT License.

The original copyright notice and license are preserved in `LICENSE`.
SuperDictate includes substantial product, interface, service-management,
history, statistics, and dictation-workflow modifications by the SuperDictate
contributors.

Speech recognition (NVIDIA Parakeet TDT 0.6B v3, GGUF q8_0) is performed
locally through [parakeet.cpp](https://github.com/mudler/parakeet.cpp)
(pinned commit `e747acdaee69b916cef62263ae5f718bda9ff3f3`), which is
statically vendored into `swift/Sources/parakeet_cpp/upstream/` by
`scripts/vendor-parakeet-cpp.sh` and distributed under the MIT License.
parakeet.cpp itself vendors [ggml](https://github.com/ggml-org/ggml)
(pinned submodule `e705c5fed490514458bdd2eaddc43bd098fcce9b`, tag
`v0.13.0`), also MIT-licensed. Exact upstream license texts, captured at
the pinned commits, are checked in at
`swift/Sources/parakeet_cpp/upstream/LICENSE-parakeet-cpp.txt` and
`swift/Sources/parakeet_cpp/upstream/LICENSE-ggml.txt`. Third-party Swift
package licenses remain available through their respective upstream
projects.


## ONNX ASR runtime (`native/asr-runtime/`, experimental)

- [ONNX Runtime](https://github.com/microsoft/onnxruntime) 1.23.2 (MIT),
  fetched as a pinned, hash-verified prebuilt by
  `scripts/fetch-onnxruntime.sh`; its own `ThirdPartyNotices.txt` ships
  alongside the library.
- `native/asr-runtime/assets/nemo128.onnx` — NeMo-compatible 128-bin log-mel
  feature graph from [onnx-asr](https://github.com/istupakov/onnx-asr) 0.12.0
  by Ilya Stupakov (MIT).
- `native/asr-runtime/third_party/nlohmann/json.hpp` —
  [nlohmann/json](https://github.com/nlohmann/json) 3.11.3 (MIT).
- Parakeet Ultra ONNX int8 weights (downloaded at runtime, not bundled):
  [mldecode/parakeet-ultra-onnx-int8](https://huggingface.co/mldecode/parakeet-ultra-onnx-int8),
  CC-BY-4.0 — based on [moondream/parakeet-ultra](https://huggingface.co/moondream/parakeet-ultra),
  a retrain of NVIDIA [parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3).
