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

- **Model files.** The same GGUF weights, pinned to the same repositories
  and revisions as `swift/Sources/Parakey/ModelDownload.swift`, verified by
  the same SHA-256 digests. One exception, forced by the engine (below).
- **Setting names.** Where a setting exists on both platforms it carries
  the same key, so behaviour is comparable and support answers transfer.
- **Prompts.** The correction and rewrite prompts are carried over
  verbatim from `swift/Sources/Parakey/LLMPostprocessingPrompts.swift`.
  They were tuned empirically against these exact models; changing one on
  one platform without the other silently forks the product's behaviour.

Not shared: the engine hosts are built from upstream C++ rather than the
vendored copies under `swift/Sources/`. See `docs/engine-layer.md` for what
that costs and why it is nonetheless the cheaper side.

## Engine model divergence

The macOS app loads Parakeet through the vendored `parakeet.cpp` fork and
its GGUF container (`mudler/parakeet-cpp-gguf`, `tdt-0.6b-v3-q8_0.gguf`).
The Windows port loads it through whisper.cpp's own in-tree Parakeet
implementation, which rejects that file with "bad magic" — a different
container around the same NVIDIA TDT 0.6B v3 checkpoint. Windows therefore
pins `ggml-org/parakeet-GGUF` / `ggml-parakeet-tdt-0.6b-v3-f16.bin`.

Same weights, same 25 languages, same vocabulary; different wrapper.
