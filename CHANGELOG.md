# 📋 Changelog

All notable changes to SuperDictate Next are documented here, in reverse
chronological order. This file covers the release history published on
[GitHub Releases](https://github.com/shohart/SuperDictate-Next/releases).

The format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Windows 0.8.3.1 — 2026-10-23

Windows only, tag `win-v0.8.3.1`. macOS stays on 0.8.0.

### Fixed
- **The dictation shortcut could stop responding** while GigaAM ran on the CPU and its NPU compile went on in the background. Two changes cover a silently removed hook, whatever removed it:
  - The keyboard-hook thread runs at high priority.
  - The hook is re-installed every 30 s. Windows silently removes a low-level hook whose callback misses `LowLevelHooksTimeout`, and that cannot be detected; the new hook goes in before the old one comes out, so no keystroke is lost.
- **The app showed "CPU, compiling" long after the NPU compile was done.** The finished NPU encoder was picked up only by the next dictation, and only that dictation told the app. GigaAM's compile actually ends after 4–7 minutes. Now the host moves to the NPU the moment the compile finishes, between requests. While a compile runs, the app asks the host every 10 s and updates the control panel.
- **The background NPU compile no longer competes with the rest of the machine.** `SuperDictateOvHost` drops to below-normal priority for the duration of the compile and returns to normal afterwards.

### Changed
- **Local correction reuses the shared prompt prefix, on the CPU and the GPU.** The correction prompt is ~295 tokens, ~276 of them the same in every request (system prompt and examples). The local host now keeps a snapshot of that prefix and decodes only the sentence. To do that, the build switches from `llama-server` to the host shared with macOS, with the snapshot added there (PR #3, built by `tools/build-engines.ps1 -ExperimentalLlmHost -Vulkan`). Measured on the Core Ultra 5 225H with the 65-sentence corpus, quality unchanged (63/65 outputs identical to `llama-server`):
  - CPU: p50 0.25 s, p90 0.34 s, against 0.32 / 0.43 s with `llama-server`.
  - GPU: p50 0.44 s, p90 0.52 s, against 0.50 / 0.58 s.
- **The host gets an explicit thread count:** physical cores minus two, at most 8 (`SUPERDICTATE_LLM_THREADS` overrides). With all 14 cores of the 225H (4 P, 8 E, 2 low-power E), the host's own threadpool waits at every barrier for the slowest thread. As soon as other programs used the CPU, a 0.3 s correction became minutes.
- **The correction model loads in the background and primes its prompt cache** when the app becomes ready, when correction is turned on, and after settings change. The first dictation no longer pays ~3 s for the load plus ~1.2 s for the snapshot.
- `--gpu-layers 0` now keeps the host off the GPU completely, with no device and no op offload.

### Validation
- 62 self-tests pass. New checks cover the hook re-installation, the host's thread count and its GPU environment.
- A real `DictationController` in a scratch profile (shortcut on F24) switched from Parakeet to GigaAM on the NPU with an empty compile cache. It started recording on the shortcut while GigaAM ran on the CPU and the NPU compile was in progress.
## 0.8.4 — 2026-10-23

macOS only, tag `mac-v0.8.4`. The version number follows the Windows port (0.8.1–0.8.3 were Windows-only releases).

### Changed
- **Local correction and rewrite are about three times faster.** Every correction request opens with the same system prompt and few-shot turns, 276 of its ~295 tokens. The LLM host now keeps a snapshot of the model state after that shared opening and decodes only the sentence itself. The opening is learned from consecutive requests, with no settings. A changed prompt (custom prompt, a newly learned vocabulary rule) just takes a new snapshot. Pre-warm sends two requests shaped like real ones, so the first dictation after a start is already fast. Rewrite benefits in the same way. Measured on the Mac Pro (Xeon E5-2696 v3, Radeon Instinct MI50) with VoiceScribe and the 65-sentence correction corpus:
  - GPU: 1.28 → 0.44 s median per sentence.
  - CPU: 2.01 → 0.44 s median.
  - Quality unchanged: normalized EM 0.646.
- **The LLM host uses one thread per physical core** (performance cores on Apple silicon) instead of every hyperthread. On the 18-core / 36-thread Xeon this alone takes CPU correction from 2.5 to 0.47 s median, with identical output.

### Fixed
- **A GPU that computes garbage no longer breaks correction.** With MoltenVK on a Radeon Instinct MI50 the model returned NaN logits. The host then crashed on every dictation and was reloaded on the next one, so no correction was ever applied. The host now reports NaN logits as an error instead of aborting. A short canary request checks every fresh GPU host. On a GPU fault, every local model moves to the CPU, with a toast, until the GPU setting is changed.
- **"GPU off" now really means the CPU only.** With zero layers offloaded, llama.cpp still sent the prompt to the GPU and allocated a 688 MiB Vulkan buffer for it.

### Validation
- Self-tests pass: `all`, `llm-guardrail`, `llm-gec` (GPU), `llm-rewrite` (YandexGPT-5-Lite 8B), `full-pipeline` (Parakeet), and the new `llm-prefix-primer` (the first correction after pre-warm reuses 276 prompt tokens, on the GPU and on the CPU).
- macOS 0.8.4 (build 61), bundle id `com.local.superdictate`, macOS 14.0+, x86_64, signed "PolterType Dev". `SuperDictate.zip` SHA-256: `bf5f87b2f13e6b4acd3dd5be70431282771aea5a65ee7d60d26959228e4e42ae`.

## Windows 0.8.3 — 2026-10-22

Windows only, tag `win-v0.8.3`. macOS stays on 0.8.0.

### Added
- **Local text correction on the CPU or the GPU, Intel Arc included.** The build now ships llama.cpp's own `llama-server` (Vulkan build b11826, pinned by SHA-256, staged by `tools/fetch-llama.ps1`) as the local LLM host. Correction runs on it with VoiceScribe (Qwen3.5-0.8B Q6_K + the dictation-corrector LoRA). Benchmarked on a Core Ultra 5 225H (Arc 130T) with the 65-sentence correction corpus:
  - CPU: 0.32 s median per sentence, EM 0.646 (normalized, as in `benchmark/`).
  - GPU: 0.50 s median, with the same result as the CPU on 64 of 65 sentences.
  - Requests are greedy (temperature 0), as on macOS.
  - Local rewrite is not part of this release: rewrite goes to an OpenAI-compatible endpoint, and the local model list offers the small correction model only.
- **Corrections are learned from edits made in place, as on macOS.** For 45 s after a paste the field is watched through UI Automation (`edit_watch.py`, a port of `PostInsertionEditWatcher`). A swap of one to three words that stays unchanged for 4 s is saved as a rule, with the usual toast and undo. Deletions, casing-only edits, edits outside the pasted text and password fields are never learned. The separate transcript-editor shortcut and dialog are gone.
- **Silero VAD downloads itself** (885 KB, pinned and checksummed), as on macOS since 0.8.0. Until now the Windows port never fetched it, so the seams of long dictations always fell back to mel energy.

### Fixed
- **GigaAM on the NPU no longer looks stuck on "preparing".** Its first NPU compile takes 4–10 minutes on this laptop, and an app restart lost it, so the next start began again from zero. The NPU compile now runs in the background. If it is not done within 15 s, the encoder starts on the CPU (same weights, same text) and moves to the NPU between dictations once compiled. A cached compile still starts on the NPU directly.
- **Vulkan on Intel graphics returned empty or garbage corrections.** Its cooperative-matrix shaders break batched prompt processing on driver 32.0.101.6554. The host now turns them off (`GGML_VK_DISABLE_COOPMAT=1`), which is also faster: prompt processing goes from 870 to 1140 tok/s.

### Validation
- Windows 0.8.3: 61 self-tests pass. New ones cover the edit watcher (in place, half-typed, rebase, deletion, focus change, outside edits, password, 45 s window), the background NPU compile (slow, cached, failed), and the llama-server flags. Checked on this laptop:
  - In Notepad, a word fixed by hand after a real Ctrl+V paste was learned 4 s later.
  - Correction ran through the app's pipeline on both the CPU and the GPU.
  - GigaAM was ready on the CPU in 19 s with an empty compile cache.
- Not compared: SYCL, which crashes at device initialisation on this GPU driver; llama.cpp's OpenVINO backend, which does not run Qwen3.5 (graph compute error, with or without the LoRA); and OpenVINO GenAI, left for later.
- Built on the build PC: 61 self-tests, `engines\llama` staged. Installed silently there (exit code 0). `SuperDictate-0.8.3-setup.exe` SHA-256: `cbabd4e12f1346df2b00985d5ba7d411ca0f37126da7c68d888bf0e949f6884f`.

## Windows 0.8.2 — 2026-10-22

Windows only, tag `win-v0.8.2`. macOS stays on 0.8.0.

### Added
- **Speech recognition on the Intel NPU.** On Intel Core Ultra laptops ("Intel AI Boost"), Settings → Advanced → "Recognition runs on" offers the NPU. The option appears only where OpenVINO finds an NPU. Both profiles run there as OpenVINO builds in a second helper, `SuperDictateOvHost.exe`, which speaks the same IPC as the ONNX host:
  - Parakeet runs as [Parakeet TDT 0.6B v3](https://huggingface.co/VoiceScribe/voicescribe-parakeet), ~1.2 GB.
  - GigaAM runs with the [NPU-calibrated GigaAM v3 encoder](https://huggingface.co/VoiceScribe/voicescribe-gigaam-npu), ~220 MB.
  - Downloads are pinned and checksummed like the ONNX models.
  - The first start compiles the model for the NPU: ~20 s for Parakeet, ~4–5 min for GigaAM. After that it loads from the cache in 1–3 s.
  - Compilation uses the NPU compiler bundled with OpenVINO 2026.4.1, not the driver's. Driver 32.0.100.3159 rejects the GigaAM encoder and crashes on its fast-compile option.
  - If the NPU cannot be brought up, recognition stays on the CPU.
- **Long dictations are transcribed while you speak on Windows too**, a port of the macOS recording-time transcription. Overlap windows that are already final are recognised during the recording; the release path reuses them only on an exact match (same start, length, audio checksum and loaded model). The text is identical to transcribing after release.
- `--benchmark-transcribe <profile> --npu file.wav` runs the NPU path. Every benchmark also prints a "streamed" line: a simulated recording with recording-time transcription, compared with the batch text.

### Changed
- **Pause segments fit the model's input.** The NPU Parakeet takes 15 s at a time, so its segments are capped at 15 s; the minimum is scaled to 9 s. Every cut still lands on a pause and every seam is still placed by the VAD. Other models keep the 25 s / 15 s limits.

### Validation
- Windows 0.8.2: 59 self-tests pass, 9 of them new. They cover NPU windows and stitching, word rules, the SentencePiece reader, GigaAM features, the NPU setting and catalog, the OpenVINO host over IPC, stable recording-time windows, streamed = batch, and segment limits.
- Tested on a Core Ultra 5 225H (NPU driver 32.0.100.3159), using Russian (10 s, 58 s) and English (11 s) test speech:
  - Text on the NPU matches the OpenVINO CPU text word for word.
  - The NPU runs 35–55× faster than real time.
  - A 58 s simulated recording leaves 0.2–0.3 s of work after release: 5 of 6 windows (Parakeet) or 3 of 4 (GigaAM) are done while recording, and the text is identical to the batch path.
- On the build PC (CPU, ONNX host), a 71 s recording leaves less work after release with recording-time transcription, and the text is identical to the batch path:
  - Parakeet: 1.41 s instead of 4.92 s.
  - GigaAM: 0.89 s instead of 3.69 s.
- The installer was built on that PC, installed silently there, and its OpenVINO host was run on the NPU laptop. `SuperDictate-0.8.2-setup.exe` SHA-256: `40fceb786fc89457cae23a7a4babcaa32b613d3e47baa88f6bfea70bf025413a`.

## Windows 0.8.1 — 2026-10-21

Windows only, tag `win-v0.8.1`. macOS stays on 0.8.0.

### Fixed
- **Right Alt works as a shortcut on the Russian layout.** Layouts with AltGr (Russian is one, US English is not) send a synthetic Left Ctrl before every Right Alt. The hotkey hook counted it as a real key, so Right Alt was recorded as "Ctrl + Alt", and a Right Alt shortcut worked in English and failed in Russian. The hook and the shortcut recorder now ignore that Ctrl (scan code `0x21D`, or the same timestamp as Right Alt). The recorder also drops modifiers whose key-up it missed, so a stale Ctrl no longer sticks to every shortcut recorded after it.

### Changed
- **The recording capsule switches to the timer after 10 seconds by default.** Installs from 0.8.0 are moved over once. If you then choose "Level bars" in Settings, that choice is kept.

### Validation
- Windows 0.8.1: 50 self-tests pass, two of them new (the AltGr Ctrl, and the timer default with its one-time move). Checked on the test PC: the Russian layout `kbdru.dll` has the AltGr flag, and `kbdus.dll` does not. `SuperDictate-0.8.1-setup.exe` SHA-256: `3f3fc56f9320124442ab9dea38da952688c9f587b83234eb3a0f52a5a7fff659`.

## 0.8.0 — 2026-10-21

macOS: tag `mac-v0.8.0` (also published once as `v0.8.0` for 0.7.0 clients). Windows: tag `win-v0.8.0`.

### Added
- **GigaAM v3 (Russian) as a second speech model** (ONNX, e2e RNN-T, MIT). Pick it in Settings → Speech model. Parakeet Ultra stays the default; only the selected model is downloaded. On 4 minutes of Russian speech its WER is 0.015, against 0.075 for Parakeet.
- **Long dictations are transcribed while you speak.** Overlap windows that are already final are recognised during the recording, so releasing the hotkey after several minutes leaves only the last window or two. The text is byte-identical to the old path. Nothing changes below 15 s of audio.
- **Silero VAD downloads itself** (885 KB, pinned and checksummed), so pause detection no longer falls back to the energy heuristic.
- **Windows port** (`windows/`): the same speech host and models as macOS; correction and rewrite go through an OpenAI-compatible API. In this release:
  - The recording capsule appears at the text caret. The caret comes from the Win32 caret or UI Automation, which covers browsers, Electron, Office and UWP. The capsule follows the caret while you speak.
  - The text goes to the field where the dictation started, even if you switched windows. If that window has closed, the text goes to the clipboard instead of into another app.
  - The macOS capsule animations: reveal, level bars, a timer after 10 s, the transcribing and "improving text" animations, and the error flash. There are light, dark and system backgrounds, a contrast colour, and a colour for the improvement stage.

### Changed
- **macOS and Windows releases have their own tags.** macOS releases are tagged `mac-vX.Y.Z` from now on (up to 0.7.0: `vX.Y.Z`), Windows releases `win-vX.Y.Z`. The update check lists the releases and takes the newest macOS one, so a Windows release can never be offered as a Mac update. The process is in `docs/RELEASING.md`.
- **The correction guardrail lets the corrector drop fillers.** The VoiceScribe corrector deletes fillers by design («ну короче завтра…» → «Завтра…»), and the leading-word check used to revert that as a lost word. Its accept/reject cases now live in `fixtures/llm-correction-guardrail.json`, shared with the Windows port.
- **The local LLM stays loaded from launch**, so the first dictation after a start no longer waits for it. Switching a stage or a model off unloads its host at once.
- **Speech recognition uses all physical cores but two** (at most 16).

### Fixed
- Long dictations are no longer cut by the correction pass. The text is corrected in sentence-sized chunks, and output whose word count drifts more than 10 % is reverted.
- Vocabulary learning works again in Chrome-based editors (ChatGPT and similar), where the edit watch used to abort.
- The LLM host no longer spins on a closed stderr.

### Validation
- macOS 0.8.0 (build 60), bundle id `com.local.superdictate`, macOS 14.0+, x86_64, signed "PolterType Dev". `SuperDictate.zip` SHA-256: `068dd0af1eb711973961a51045558ed39fc172ee7cb28b469dab8de7daf921fc`.
- Windows 0.8.0: 48 self-tests pass. An end-to-end run in a real desktop session found the caret in a Win32 edit control and in Edge (UI Automation), returned to the starting field after a window switch and pasted there, and sent the text to the clipboard once the starting window had closed. `SuperDictate-0.8.0-setup.exe` SHA-256: `399e7e8af6f27cec4dc2795381da9d62076004dfa6e35d4f4e26b9dbd79ff482`.

## v0.7.0 — 2026-10-17

### Changed
- **Speech recognition is ONNX on the CPU.**
  - The model is Parakeet Ultra 0.6B (TDT, ONNX int8), run by ONNX Runtime 1.23.2 in a new `SuperDictateOnnxHost` helper process.
  - It is now the only speech engine. A saved GGUF or Whisper selection switches to it automatically.
  - The model is downloaded once and is about 630 MB.
- **The GPU is used only by the local LLM** (correction and rewrite), through the "LLM on GPU (Vulkan)" toggle.
  - This toggle inherits the old "Use GPU" setting until you change it.
  - It now asks the LLM host itself which Vulkan devices it can see.
- **The app is smaller.**
  - The app process no longer carries Vulkan or MoltenVK. Its executable shrank from 11 MB to 4.4 MB.
  - The release ZIP shrank from 47 MB to 19 MB.
  - Pause detection (Silero VAD) runs on a CPU-only ggml core.

### Removed
- The GGUF parakeet.cpp engine and its Vulkan path.
- whisper.cpp: the Whisper profiles, the `SuperDictateWhisperHost` helper and its model download.
- The ASR "Use GPU (Vulkan)" toggle.

The model files from earlier versions are no longer used and can be deleted:
- `~/Library/Application Support/SuperDictate/Models/tdt-0.6b-v3-q8_0.gguf`
- `~/Library/Application Support/SuperDictate/Models/whisper-cpp/`

### Fixed
- Short dictations no longer come back empty: the ONNX encoder now receives the full feature frame count.
- Side-by-side test bundles get their own LaunchAgent, so they can no longer take over the installed app's agent.

### Why
Benchmark on an Intel Mac (Xeon E5-2696 v3, AMD Radeon Vega). Every clip went through the real dictation path, with no LLM correction. The results are in `docs/specs/cross-platform-onnx-asr-spec.md` §12.

| Engine | Mean WER | Mean RTF |
|---|---:|---:|
| ONNX on the CPU | 0.079 | 0.119 |
| GGUF Parakeet on the CPU | 0.084 | 0.182 |
| GGUF Parakeet on Vulkan | 0.084 | 0.133 |
| whisper.cpp on Vulkan | — | about 11 s per call, whatever the clip length |

### Validation
- Version 0.7.0 (build 59), bundle id `com.local.superdictate`, macOS 14.0+, x86_64.
- Self-test groups passed, plus these real-model runs: ONNX ASR, Silero VAD, LLM correction and rewrite on the GPU, and ONNX followed by LLM correction end to end.
- `SuperDictate.zip` SHA-256: `4c247fbe4aa25bdaef90955549791b4d05681b7d5ad1702af39426cb86c83560`.

## v0.5.5 — 2026-08-19

### Added
- **Final-period removal toggle** in Settings → Text: optionally drop the trailing period from dictated text (ellipses are preserved).
- **Reset Permissions button** in the macOS permissions card: one click revokes Microphone, Accessibility, and Input Monitoring grants, then relaunches the agent so the user can re-grant cleanly.

### Fixed
- Silero VAD no longer crashes on short audio chunks (Intel tinyBLAS `ldb >= k` assertion fixed by making the fast path return `false` for unsupported layouts).
- Removed unsafe VAD startup probing that could trigger the same BLAS assertion.

### Changed
- Updated Vulkan headers/loader to 1.4.357.0 and regenerated SPIR-V shader corpus.

### Validation
- Full self-test suite: PASS
- `silero-vad-real`, `vad-boundary-oracle-real`: PASS
- Parakeet CPU and Vulkan integration: PASS
- Release build: version 0.5.6, build 57
- Bundle identifier: com.local.superdictate
- Release ZIP SHA-256: (to be filled after build)

## v0.5.5 — 2026-08-19

### Changed

- Updated vendored `parakeet.cpp` to the maintainer's current v0.5.0 commit
  while retaining its exact pinned ggml v0.13.0 submodule.
- Updated Vulkan headers and loader to 1.4.357.0 and regenerated the bundled SPIR-V shader corpus.

### Fixed

- Preserved Silero VAD and fixed an Intel tinyBLAS assertion on valid VAD
  matrix layouts by allowing the optional fast path to fall back to the normal
  CPU kernel.
- Removed unsafe VAD startup probing that could trigger the same BLAS assertion.

### Validation
- CPU and Vulkan Parakeet integration pass on AMD RX 6600.
- `silero-vad-real`, `vad-boundary-oracle-real`: PASS
- The existing multilingual `tdt-0.6b-v3-q8_0.gguf` model is unchanged.

## v0.5.4 — 2026-08-19

### Changed

- Split the Settings window into compact thematic tabs: Dictation, Text,
  Audio, Appearance, and System. Each tab has its own scroll area and starts
  at the top of the viewport, making the panel usable on small screens.
- Vocabulary learning now continues watching an insertion after a correction
  is saved, allowing multiple independently corrected words in one dictated
  passage to be learned.
- Corrections saving now surfaces SQLite errors (e.g., `SQLITE_BUSY`) instead
  of silently dropping the row.
- Enabled WAL mode for the corrections SQLite database to reduce contention
  between the agent and the Control Panel processes.

### Fixed

- Prevented deletion-only edits and partial word trimming from being learned
  as corrections.
- Reduced vocabulary-learning debounce and confirmation delays from about
  1.8 seconds total to about 0.85 seconds.
- Removed the unwanted AppKit focus ring around the toast's transparent undo
  control.

### Validation
- CPU and Vulkan Parakeet integration pass on AMD RX 6600.
- `silero-vad-real`, `vad-boundary-oracle-real`: PASS
- The existing multilingual `tdt-0.6b-v3-q8_0.gguf` model is unchanged.

## v0.5.3 — 2026-08-18

### Changed

- Updated vendored `parakeet.cpp` to the maintainer's current v0.5.0 commit
  while retaining its exact pinned ggml v0.13.0 submodule.
- Updated Vulkan headers and loader to 1.4.357.0 and regenerated the bundled
  SPIR-V shader corpus.

### Fixed

- Diagnosed and fixed a stale-singleton bug in the Vulkan backend: after a
  mid-session Vulkan error the process-global `pk::global_backend()` singleton
  was left in a CPU state, causing subsequent Vulkan requests to silently fall
  back to CPU. The fix resets the stale singleton when the device request
  changes and no live contexts exist, so the next warm-up rebuilds the backend
  with the new device.
- Fixed a hotkey-recorder bug where two-modifier chords (e.g. Ctrl+Cmd) could
  never be recorded because the recorder accepted the first modifier press
  and closed immediately. The recorder now captures chords on key release.
- Fixed a recorder bug where the first key release of a modifier chord was
  ignored, preventing two-modifier shortcuts from being recorded.

### Added
- Regression tests for the stale-singleton Vulkan fix and the held-modifier
  hotkey recording fix.

## v0.5.2 — 2026-08-17

### Changed

- Internal refactor: the monolithic `main.swift` was split into per-topic
  source files (constants/config/metrics/models, logger, settings, permissions,
  hotkeys, audio capture, transcription worker, text insertion, HUD, app
  entry, self-test, control panel, diagnostics). No behaviour changes.

### Fixed

- Toast appearing too early (on deletion-only edits) fixed by rejecting
  deletion-only candidates in `LearnCandidateDetector`.
- Hotkey recorder now captures modifier chords on key release, not key press.
- Vulkan backend no longer falls back to CPU after a mid-session error.

### Validation
- Full self-test suite: PASS
- `silero-vad-real`, `vad-boundary-oracle-real`: PASS
- Parakeet CPU and Vulkan integration pass on AMD RX 6600.

## v0.5.1 — 2026-08-17

Internal refactor: the monolithic `main.swift` was split into per-topic
source files (constants/config/metrics/models, logger, settings, permissions,
hotkeys, audio capture, transcription worker, text insertion, HUD, app entry,
self-test, control panel, diagnostics). No behaviour changes — the refactor
preserves the 0.5.0 feature set, and the clean release build now compiles
with zero warnings on this Intel Mac.

## v0.5.1 — 2026-08-07

Internal refactor: the monolithic `main.swift` was split into per-topic
source files (constants/config/metrics/models, logger, settings, permissions,
hotkeys, audio capture, transcription worker, text insertion, HUD, app entry,
self-test, control panel, diagnostics). No behaviour changes — the refactor
preserves the 0.5.0 feature set, and the clean release build now compiles
with zero warnings on this Intel Mac.

## v0.5.0 — 2026-08-07

**SuperDictate Next** — the first release under the new project name
(formerly SuperDictate-Intel), now tracking its own repository for update
checks instead of the upstream project.

- Filler-word manager in Settings: a four-column checklist of 27 curated
  Russian and English presets — hesitation sounds (on by default) and
  verbal-tic phrases like "как бы", "это самое", "знаешь", "you know"
  (off until ticked) — plus your own words and phrases, which join the
  same list already ticked and can be unticked without deleting. The old
  menu-bar toggle moved into Settings.
- Auto-stop on silence: dictation can end itself after 1–10 s of
  continuous silence (off by default), measured from the last voiced
  sample.
- Launch at Login and Mute system audio while recording moved from the
  menu bar into the Settings window; a hint row points to the text-corrections
  manager.
- New adaptive "Contrast" HUD accent color: black on a light capsule
  background, white on dark — fixes the recording indicator being
  invisible on light backgrounds.
- Settings reliability: the filler-word checklist always renders (a
  zero-size scroll document hid it), and periodic panel refreshes no
  longer eat checkbox clicks mid-edit, which had silently dropped saved
  preset ticks.
- Settings reliability: the filler-word checklist always renders (a
  zero-size scroll document hid it), and periodic panel refreshes no
  longer eat checkbox clicks mid-edit, which had silently dropped saved
  preset ticks.
- New adaptive "Contrast" HUD accent color: black on a light capsule
  background, white on dark — fixes the recording indicator being
  invisible on light backgrounds.
- Settings reliability: the filler-word checklist always renders (a
  zero-size scroll document hid it), and periodic panel refreshes no
  longer eat checkbox clicks mid-edit, which had silently dropped saved
  preset ticks.
- New adaptive "Contrast" HUD accent color: black on a light capsule
  background, white on dark — fixes the recording indicator being
  invisible on white backgrounds.
- Settings reliability: the filler-word checklist always renders (a
  zero-size scroll document hid it), and periodic panel refreshes no
  longer eat checkbox clicks mid-edit, which had silently dropped saved
  preset ticks.



### Changed

- Full UI rebrand: every user-visible panel, dialog, tooltip, and document
  type now says "SuperDictate Next" (menu bar, control panel, settings,
  shortcut recorder, update window, permission prompts).
- New app icon: same microphone concept, now on a modern vivid
  indigo-violet-pink gradient with a soft sheen and sound-wave arcs.
  Regenerated deterministically via `icon/generate-appicon.swift`.

### Documentation

- README (EN/RU) now documents Silero VAD pause detection, automatic
  vocabulary learning, the tabbed Settings window, and re-recordable
  modifier-chord shortcuts.


## v0.5.3 — 2026-08-18

### Changed

- Updated vendored `parakeet.cpp` to the maintainer's current v0.5.0 commit
  while retaining its exact pinned ggml v0.13.0 submodule.
- Updated Vulkan headers and loader on the Intel capability Mac to 1.4.357.0
  and regenerated the bundled SPIR-V shader corpus.

### Fixed

- Preserved Silero VAD and fixed an Intel tinyBLAS assertion on valid VAD
  matrix layouts by allowing the optional fast path to fall back to the normal
  CPU kernel.
- Removed unsafe VAD startup probing that could execute a problematic tiny
  internal frame before the real segmentation call.

### Validation

- CPU and Vulkan Parakeet integration pass on AMD RX 6600.
- `silero-vad-real`, `vad-boundary-oracle-real`, and the full self-test pass.
- The existing multilingual `tdt-0.6b-v3-q8_0.gguf` model is unchanged.


## v0.5.2 — 2026-08-17

### Added

- Split the Settings window into compact thematic tabs: Dictation, Text,
  Audio, Appearance, and System. Each tab has its own scroll area and starts
  at the top of the viewport, making the panel usable on small screens.
- Automatic vocabulary learning now continues watching an insertion after a
  correction is saved, allowing multiple independently corrected words in one
  dictated passage to be learned.
- Added a full-surface learning flash and stronger confirmation animation for
  the vocabulary toast.

### Fixed

- Prevented deletion-only edits and partial word trimming from being learned
  as corrections.
- Reduced vocabulary-learning debounce and confirmation delays from about
  1.8 seconds total to about 0.85 seconds.
- Removed the unwanted AppKit focus ring around the toast's transparent undo
  control.
- Fixed two-modifier shortcut capture: the first key release captures the
  complete chord and the trailing release can no longer overwrite it with a
  single modifier.
- Command-based finish shortcuts now work with Control, Option, or Fn even
  when the primary dictation shortcut is Right Command. The settings validator
  no longer rejects this intentional shared-modifier arrangement.
- Fixed the launch-agent restart race that could leave the service stopped
  while switching between configurations or applying settings.
- Fixed Vulkan recovery after a CPU fallback by resetting a stale process-wide
  Parakeet backend when the requested device changes. Vulkan can now be
  re-enabled without restarting the whole user session.
- SQLite vocabulary writes now use WAL where possible, surface manual-save
  errors, and log the actual reason when automatic learning cannot persist a
  correction.

### Validation

- Added regression coverage for deletion-only edits, multiple corrections,
  Command modifier finish shortcuts, multi-modifier recording, stale Vulkan
  backend recovery, and compact settings behavior.

## v0.5.1 — 2026-08-07

Internal refactor: the monolithic `main.swift` was split into
per-topic source files (constants/config/metrics/models, logger,
settings, permissions, hotkeys, audio capture, transcription worker,
text insertion, HUD, app entry, self-test, control panel, diagnostics).
No behaviour changes — the refactor preserves the 0.5.0 feature set, and
the clean release build now compiles with zero warnings on this Intel Mac.

## v0.5.0 — 2026-08-02

**SuperDictate Next** — the first release under the new project name
(formerly SuperDictate-Intel), now tracking its own repository for update
checks instead of the upstream project.

- Filler-word manager in Settings: a four-column checklist of 27 curated
  Russian and English presets — hesitation sounds (on by default) and
  verbal-tic phrases like "как бы", "это самое", "знаешь", "you know"
  (off until ticked) — plus your own words and phrases, which join the
  same list already ticked and can be unticked without deleting. The old
  menu-bar toggle moved into Settings.
- Auto-stop on silence: dictation can end itself after 1–10 s of
  continuous silence (off by default), measured from the last voiced
  sample.
- Launch at Login and Mute system audio while recording moved from the
  menu bar into the Settings window; a hint row points to the
  text-corrections manager.
- New adaptive "Contrast" HUD accent color: black on a light capsule
  background, white on dark — fixes the recording indicator being
  invisible white-on-light.
- Settings reliability: the filler-word checklist always renders (a
  zero-size scroll document hid it), and periodic panel refreshes no
  longer eat checkbox clicks mid-edit, which had silently dropped saved
  preset ticks.

## v0.4.x — 2026-07-28…2026-08-01 (summary)

- v0.4.0: whisper.cpp fully replaced by parakeet.cpp + NVIDIA Parakeet
  TDT 0.6B v3 (GGUF q8_0) as the only speech engine; optional Vulkan GPU
  backend (ggml + MoltenVK) with automatic CPU fallback, verified on
  AMD RX 6600.
- Russian number ITN: dictated numbers written as digits.
- Long-dictation pause segmentation and overlap seam deduplication.
- Recording HUD timer + outline-fill display mode with a 10 s crossfade.
- LaunchAgent no longer relaunches the app after a normal Quit.
- Clipboard race and ITN punctuation-artifact fixes.

## v0.2.38 — 2026-07-26

- Added a microphone picker in settings, including Continuity Microphone from
  an iPhone.
- Fixed a critical failure with explicitly selected devices: `AVAudioEngine`
  no longer reuses a stale sample rate from a different microphone or
  produces an empty recording.
- The control panel and background service now reliably run as a single
  instance; local reinstallation preserves the code signature and macOS
  permissions.
- Startup is clearer: model-preparation stages and download progress are
  shown, and redundant model re-downloads were eliminated.
- Added regression coverage for the CoreAudio route and diagnostics for
  actual audio capture.

## v0.2.37 — 2026-07-23

- Modifier-only shortcuts no longer steal Shift, Option, Control, Fn, or
  Command from the active app. This fixes Shift navigation in Blender while
  SuperDictate runs in the background.
- The fix applies consistently to dictation, alternate completion with
  Enter, and history shortcuts; single-modifier dictation keys still remain
  exclusive.
- Adds a configurable Enter delay, clearer error and busy feedback,
  language-aware `<unk>` handling, download progress, and additional hotkey
  options.
- Improves Apple Silicon installation when Terminal runs through Rosetta and
  pins source builds to the exact release source commit.

## v0.2.36 — 2026-07-20

- Fixes a stuck modifier state after closing the history chord in a
  particular key-release order.
- `Shift + Right Command` no longer fires from `Left Command + Shift` after
  an earlier history activation.
- Adds a regression test covering the exact physical-key sequence.

## v0.2.35 — 2026-07-20

- The main dictation shortcut always starts recording and finishes it on the
  next press.
- Choose whether the main shortcut inserts text, or inserts text and presses
  Enter.
- An optional alternate finish shortcut performs the opposite action and
  only works while recording.
- Clearer, more compact shortcut settings with preserved behavior for
  existing users.

## v0.2.34 — 2026-07-20

Hotkeys are now labeled by what they actually do.

- `Dictation` starts recording and, on the next press, finishes it without
  Enter.
- `Finish + Enter` only finishes an already-running recording, inserts the
  text, and presses Enter.
- `History` opens the recent-transcriptions quick view.
- Fixed the name, tooltip, and recording window for the second shortcut.

## v0.2.33 — 2026-07-20

Hotkey settings got simpler.

- Exactly three rows: dictation, dictation with Enter, and history.
- Each row immediately shows the current shortcut and lets you change it.
- Removed the separate Enter toggle, duplicate buttons, and extra
  descriptions.
- Buttons are aligned in a single column; the window is more compact.
- The bottom hint is no longer clipped.

## v0.2.32 — 2026-07-20

The shortcuts panel became clearer and fully configurable.

- Settings immediately show the keys for dictation, dictation with Enter,
  and history.
- The separate Enter-finish behavior can now be turned off.
- The history-opening shortcut can now also be changed.
- The panel status shows the background service state and no longer
  switches to "Recording".
- Added an explicit hint that the panel can be closed without stopping
  dictation.
- Fixed the layout of the separate settings window.

## v0.2.31 — 2026-07-20

Fully replaced the shortcut-recording mechanism.

- The window uses its own system `CGEventTap` instead of AppKit `NSEvent`.
- Left/Right Command, Option, Control, and Fn are read directly by hardware
  keycode.
- The background interceptor pauses while recording a shortcut, so events no
  longer conflict.
- Added diagnostic logging of real keyboard events.

## v0.2.30 — 2026-07-20

Single system keys are now selected immediately on press.

- Left/Right Command work as independent hotkeys.
- Option, Control, and Fn work as independent hotkeys.
- Pressing a second key after a modifier updates the selection to a
  combination.
- Releasing the modifier is no longer required to record it.

## v0.2.29 — 2026-07-20

Fixed recording of global keyboard shortcuts.

- A single Command press and other modifiers are now recorded correctly.
- Both single keys and combinations are supported.
- The Cancel button, Escape, and the close icon all close the window without
  changes.
- The background hotkey is guaranteed to resume after the window closes.

## v0.2.28 — 2026-07-20

Configurable shortcuts and capsule size.

- Two independent shortcuts: finish without Enter, and finish with Enter.
- Support for modifier-only combinations, including `Option + Command` and
  `Fn`.
- Global dictation is paused while recording a new shortcut.
- Capsule size: compact, normal, or large.
- Settings apply with a single button and a safe background-service restart.

## v0.2.27 — 2026-07-20

- The main panel became a compact, scroll-free control surface.
- Shortcut, Enter, and appearance settings moved to a separate window behind
  the gear icon.
- Added clear tooltips for all controls and settings.
- The panel resizes cleanly when macOS hasn't granted one or more
  permissions.
- README explains one-button updates and migrating from older versions.

Users on v0.2.26 can open SuperDictate and click "Update" in the bottom row
of the panel.

## v0.2.26 — 2026-07-20

- One-button app updates directly from the control panel.
- Automatic verification of SHA-256, bundle ID, version, and signature of
  the release archive.
- Atomic installation with a backup and automatic rollback on error.
- Localized progress window and automatic restart after updating.

## v0.2.25 — 2026-07-20

Fixed custom-hotkey recording.

- The first key pressed no longer closes the window or applies
  automatically.
- The selected key or combination is shown before saving.
- A new hotkey only applies after explicitly clicking "Save".
- You can re-enter a different combination, cancel the change, or close the
  window without changing the current hotkey.
- Added validation for single keys, single modifiers, and key combinations.

## v0.2.24 — 2026-07-20

The control panel became clearer and more informative.

- Russian is the default language, with instant RU / EN switching.
- Separate status blocks for the service, model, hotkey, and permissions.
- Visible progress for starting and restarting the background service.
- Managing the worker no longer blocks the panel's UI.
- Shows the version, process PID, and last-updated time.
- The panel only refreshes what actually changed, reducing system load.

## v0.2.23 — 2026-07-20

Hotfix for custom-shortcut recording.

- A single modifier is saved immediately on release.
- A combination is saved immediately after its last key is pressed.
- Removed the separate confirmation button, so the recorder no longer leaves
  the panel in a confusing state.
- Escape cancels shortcut recording.

## v0.2.22 — 2026-07-20

### What's new

- Added a **Change…** button in the SuperDictate panel to record your own
  dictation hotkey.
- Supports single keys and combinations with Control, Option, Shift, and
  Command.
- The background service automatically restarts after a shortcut change.
- Right Command remains the default shortcut.

### Updating

Re-run the install command from the README. History, settings, and the
local model are preserved.

## v0.2.21 — 2026-07-18

Public build with a hardened installer and a full first-run guide.

- Verifies SHA-256, version, `arm64`, signature, and microphone
  entitlements.
- Safe upgrade that keeps the previous bundle until the replacement
  succeeds.
- App data is stored under `Application Support/SuperDictate`.
- A normal install doesn't require Xcode; building from source remains a
  separate mode.
- On first launch, macOS prompts for Microphone, Accessibility, and Input
  Monitoring.

## v0.2.20 — 2026-07-18

First public build of SuperDictate. Runs fully locally on an Apple Silicon
Mac with macOS 14 or newer. On first launch, macOS asks for Microphone,
Accessibility, and Input Monitoring permissions; a local recognition model
then downloads once.
