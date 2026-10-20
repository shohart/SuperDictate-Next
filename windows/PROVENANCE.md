# Windows port — provenance

This directory is the Windows port of SuperDictate Next. It is a separate
application, not a build variant of the macOS app in `swift/`: the two share
model files, setting names, data-file layouts and behaviour, but no source.

## Import base

The starting point was the pre-existing Windows fork, imported wholesale:

| | |
| --- | --- |
| Upstream | https://github.com/metawka/SuperDictate-win |
| Commit | `326b1272b14eea390bef7b5c87aafbdd5736b025` |
| Date | 2026-07-22 |
| Version at import | 2.4.0 |
| Licence | MIT (see `LICENSE`, attribution chain in `NOTICE.md`) |

Imported verbatim minus `.git/` and `__pycache__/`. Everything added since
is this repository's own work, tracked in this repository's history.

## Why an import and not a submodule

The port's whole purpose is to diverge: the macOS app has subsystems the
fork never had (LLM post-processing, a second ASR engine, SQLite-backed
vocabulary learning, VAD-driven segmentation), and closing that gap means
editing existing modules, not adding new ones alongside them. A submodule
would put every one of those edits in a tree we do not control, and the
fork is MIT-licensed precisely so this is allowed. `NOTICE.md` keeps the
authorship chain intact.

## Relationship to `swift/`

Shared by construction, and deliberately kept in sync:

- **Model files.** The same weights, pinned to the same repositories and
  revisions, verified by the same SHA-256 digests: the LLM GGUFs as in
  `swift/Sources/Parakey/ModelDownload.swift`, the speech models through the
  shared ONNX catalog (below).
- **Setting names.** Where a setting exists on both platforms it carries
  the same key, so behaviour is comparable and support answers transfer.
- **Prompts.** The correction and rewrite prompts are carried over
  verbatim from `swift/Sources/Parakey/LLMPostprocessingPrompts.swift`.
  They were tuned empirically against these exact models; changing one on
  one platform without the other silently forks the product's behaviour.

Not shared: the LLM host and the Silero VAD (`engines\`) are built from
upstream llama.cpp / whisper.cpp rather than the vendored copies under
`swift/Sources/`. The speech host is shared source (below).

## Speech recognition: shared, not diverged

Earlier revisions of the port ran Parakeet TDT v3 through the Python
`onnx-asr` package, or through whisper.cpp's in-tree Parakeet with a
different GGUF container than the macOS build. Both are gone. Since the
macOS 0.7.0 switch to ONNX, both platforms run the same native host,
`SuperDictateOnnxHost` (`native/asr-runtime`, C++ over ONNX Runtime
1.23.2), with the same models from the same pinned catalog
(`native/asr-runtime/catalog/onnx-models.json`) and the same CPU-only
policy. The Python side only speaks the host's framed IPC
(`superdictate/onnx_host.py`), as the Swift `OnnxAsrEngine` does.
