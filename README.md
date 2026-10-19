# 🎙️ SuperDictate Next

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: macOS](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)](#-one-minute-install)
[![Latest release](https://img.shields.io/github/v/release/shohart/SuperDictate-Next?label=release)](https://github.com/shohart/SuperDictate-Next/releases/latest)
[![100% local](https://img.shields.io/badge/speech%20processing-100%25%20local-success.svg)](#-privacy--data)

**Fast, private, local dictation for macOS — including the Intel Macs other
projects left behind.** Hold a hotkey, speak, and your words are typed into
whatever field is focused. No cloud, no account, no audio ever leaving your
Mac.

**[Читать по-русски](README.ru.md)**

## 🌱 Why this project exists

SuperDictate Next is an independent continuation of the
[SuperDictate](https://github.com/shlgd/SuperDictate) project — itself based
on [Parakey](https://github.com/rcourtman/parakey) by Richard Courtman —
forked in July 2026. It is **not** a mirror: 170+ commits of original work,
its own speech engine, its own release channel, its own update checker.

Three things were missing upstream, and they are the reason this project
exists:

1. **Intel Macs.** Upstream development and CI target Apple Silicon only.
   Plenty of still-capable Intel machines (this project is built and tested
   on a Xeon E5-2678 v3 with an AMD Radeon RX 6600) were untested territory
   there. Here they are a first-class target.
2. **A different speech engine.** Upstream stayed on whisper.cpp. SuperDictate
   Next runs NVIDIA Parakeet (TDT 0.6B, multilingual) through ONNX Runtime,
   on the CPU only — it beat both whisper.cpp and the earlier GGUF
   parakeet.cpp build, GPU included, on accuracy and speed. The GPU (Vulkan
   via MoltenVK) is used only for the local LLM correction/rewrite model.
3. **Room to iterate on dictation ergonomics** for a Russian+English daily
   workflow: filler-word management, auto-stop on silence, a proper settings
   window, Russian number normalization, long-dictation segmentation.

## 🔀 How it differs from upstream SuperDictate

| Area | Upstream (at fork point) | SuperDictate Next |
|---|---|---|
| Speech engine | whisper.cpp, large-v3-turbo | Parakeet Ultra 0.6B (ONNX int8) on ONNX Runtime, CPU only — whisper removed entirely |
| GPU acceleration | none in this path | only for the local LLM correction/rewrite model (Vulkan, ggml + MoltenVK) |
| Intel Macs | untested | first-class target, verified on real hardware |
| Filler words | single on/off toggle | per-word checklist: 27 curated RU/EN presets in 4 columns + your own words/phrases |
| Auto-stop | — | ends dictation after 1–10 s of silence (optional) |
| Settings window | partial | adds Launch at Login, mute-while-recording, adaptive **Contrast** HUD color, capsule size, indicator modes (level bars / elapsed-timer outline) |
| Russian numbers | words | optional ITN: dictated numbers written as digits (25, not двадцать пять) |
| Long dictations | single pass | pause-based segmentation with overlap seam deduplication |
| Pause detection | — | Silero VAD (local ggml port, downloaded automatically) for smarter seam placement |
| Vocabulary learning | — | automatic: hand-correct a word right after dictation and it's remembered — with an Undo toast and a SQLite-backed manager |
| Corrections | — | vocabulary manager (Settings → Text): add/edit/delete, JSON import/export, cross-Mac folder sync |

## 🚀 One-minute install

**Requires a Mac on macOS 14+ — Apple Silicon or Intel.**

1. Open the **Terminal** app.
2. Paste this command and press Enter:

```bash
curl -fsSL https://raw.githubusercontent.com/shohart/SuperDictate-Next/main/install.sh | /bin/bash
```

3. When SuperDictate opens, click `Allow` for **Microphone**,
   **Accessibility**, and **Input Monitoring**.
4. Wait for the status to read `Ready`, press **right Command**, and speak.
   Press **right Command** again to insert the text.

On first launch, SuperDictate downloads a local speech-recognition model once
(Parakeet Ultra 0.6B, ONNX int8). It takes about 630 MB on disk; plan for at
least 1.5 GB of free space during installation. After the
download completes, dictation works fully offline.

## ⬆️ Updating

**If SuperDictate already shows an `Update` button:** open the app from the
Applications folder and click it. The app downloads and verifies the new
version, replaces the old one, and relaunches on its own.

**If SuperDictate was installed before the update button existed:** don't
delete anything. Open Terminal and run the same command again:

```bash
curl -fsSL https://raw.githubusercontent.com/shohart/SuperDictate-Next/main/install.sh | /bin/bash
```

The command only replaces `/Applications/SuperDictate.app`. Your history,
settings, and already-downloaded model stay in place. After this, future
updates can be installed straight from the app.

The latest published version is always visible on the
[GitHub Releases](https://github.com/shohart/SuperDictate-Next/releases/latest)
page.

## ⌨️ Hotkeys

- **Right Command** — start dictating; press again to stop the recording.
- Settings let you choose what a second press does: just insert the text, or
  insert the text and then press Enter.
- **Right Option + right Command** (default; fully re-recordable) — an
  alternate way to stop the active recording. It does the opposite of the
  primary hotkey: if the primary key presses Enter, this one stops without
  Enter, and vice versa. Any combination works, including modifier-only
  chords such as `Control + Command` — record it by holding the chord and
  releasing either key. The alternate hotkey can be turned off.
- **Right Shift + right Command** — open or close the quick history.
- All three shortcuts can be changed independently. Single keys, function
  keys, regular combinations, and modifier-only combinations (e.g.
  `Option + Command`) are all supported.
- Left and right variants of a modifier are distinct: a right-Command
  shortcut will not fire from the left Command key.
- While the shortcut-recording window is open, global dictation is
  temporarily paused. Keys you press are only recorded as the new hotkey and
  don't trigger anything else.
- Open `SuperDictate` from Applications to check the background service,
  permissions, and updates. Settings open via the gear button.

## 🖥️ Control panel and settings

The main panel is compact: it shows the background service status, any
missing permissions, and an available update. Service controls sit to the
right of the status; hovering shows a tooltip for each button.

The gear button opens the Settings window, organized into five compact tabs:

- **Dictation** — the three shortcuts and the stop-action behavior (insert,
  or insert + Enter).
- **Text** — filler words, Russian number formatting, vocabulary learning.
- **Audio** — microphone picker, auto-stop on silence, mute while recording.
- **Appearance** — capsule size, recording/transcribing colors, indicator
  mode, background.
- **System** — Launch at Login, privacy info.

The `RU / EN` toggle instantly switches the language of both panels. Changes
stay as a draft first; the `Save and Restart` button applies them together
and restarts only the background service — history and the model are left
untouched.

The panel can be closed entirely. The background service keeps running
separately and launches automatically after the next macOS login.

## 🧹 Filler-word removal

Settings → `Remove filler words` opens a four-column checklist:

- **27 curated presets** — hesitation sounds (`um`, `uh`, `ah`, `эм`, `м`,
  `аа`…, on by default) and verbal-tic phrases (`как бы`, `типа`, `короче`,
  `это самое`, `знаешь`, `you know`, `basically`…, off until you tick them,
  because they can be real words).
- **Your own words and phrases**: type one, press Enter — it joins the same
  list, already ticked. Untick to keep it on the list but unused; the `×`
  button deletes it.

## 📖 Vocabulary learning

When you hand-correct a short word or phrase right after SuperDictate
inserts a dictation (the classic case: an English word dictated
phonetically in Cyrillic), the app notices the fix and remembers it as a
text correction — the next time the same word is dictated, it is replaced
automatically.

- Only short edits count (up to three words swapped). Pure deletions,
  half-finished trims, and casing-only touch-ups are ignored.
- A small pill-shaped toast appears near the field, confirming what was
  learned. Press **Escape** (or click the toast) to undo it immediately.
- You can keep correcting: multiple fixes in the same dictated passage are
  each learned independently.
- Automatic learning can be turned off in Settings → Text.
- Corrections live in a local SQLite database
  (`~/Library/Application Support/SuperDictate/corrections.sqlite`), with a
  full manager — add, edit, delete, JSON import/export — and optional
  folder-based sync between your Macs.

## ⏸️ Auto-stop on silence

Optional: dictation ends itself after a chosen stretch of continuous silence
(1–10 seconds, default 5). Silence is measured from the last voiced sample,
exactly as you perceive it.

## 🔐 Why the permissions are needed

macOS doesn't let an app grant these to itself:

- **Microphone** — records your voice while dictation is active.
- **Accessibility** — locates the focused field and inserts the finished
  text.
- **Input Monitoring** — detects the global hotkey.

If the status doesn't change to `Ready` after granting permissions, open
SuperDictate and click `Restart` on the background service. If the app
doesn't show up in the system list, click `Try Again` next to the relevant
permission.

## 📦 What the installer does

The installer:

1. Downloads `SuperDictate.zip` from
   [GitHub Releases](https://github.com/shohart/SuperDictate-Next/releases).
2. Verifies a pinned SHA-256, version, bundle ID, architecture (Apple Silicon
   or Intel), code signature, and microphone entitlements.
3. Safely replaces `/Applications/SuperDictate.app` and opens the panel.

Xcode and the Command Line Tools are not required for a normal install.
History, settings, and the already-downloaded model are preserved across
updates.

## 🛠️ Building from source

### The easiest way

This command downloads the open-source code, builds it locally, and installs
the result into `/Applications`:

```bash
curl -fsSL https://raw.githubusercontent.com/shohart/SuperDictate-Next/main/install.sh | SUPERDICTATE_BUILD_FROM_SOURCE=1 /bin/bash
```

You'll need the free Apple Command Line Tools. If they're missing, the
installer opens the standard installation dialog; run the command again once
that finishes. A clean first build usually takes a few minutes.

By default, building from source downloads the exact release source commit
and verifies it against GitHub. For development, you can pass your own
`SUPERDICTATE_REF` and `SUPERDICTATE_SOURCE_COMMIT`; without a matching
commit, the installer won't run the downloaded `scripts/build-app.sh`.

### Manual build for development

```bash
xcode-select --install
git clone https://github.com/shohart/SuperDictate-Next.git
cd SuperDictate-Next
swift run -c debug --package-path swift Parakey --self-test all
./scripts/build-app.sh ./dist/SuperDictate.app
open ./dist/SuperDictate.app
```

By default, a local build is signed ad-hoc. To use your own certificate, pass
its name:

```bash
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/build-app.sh ./dist/SuperDictate.app
```

Don't move or delete `dist/SuperDictate.app` while the background service is
running from that build. For regular use, prefer the
`SUPERDICTATE_BUILD_FROM_SOURCE=1` command, which installs the app into
`/Applications`.

## 🗣️ Speech recognition: Parakeet on ONNX Runtime, CPU only

SuperDictate Next recognizes speech with Parakeet Ultra 0.6B (a fine-tune of
NVIDIA Parakeet TDT 0.6B v3, ONNX int8) running in ONNX Runtime inside the
`SuperDictateOnnxHost` helper process. Recognition runs **on the CPU only**;
there is no GPU option for it. The GPU (Vulkan) is reserved for the local
LLM that corrects and rewrites text — see the `LLM on GPU (Vulkan)` toggle.

Why CPU only: on the reference Intel Mac (Xeon E5-2696 v3, AMD Radeon Vega),
through the app's real dictation path (pause segmentation, overlap windows,
seam dedup), 8 clips from 1.7 s to 52 s, 8 threads, no LLM correction:

| Engine | Mean WER | Mean punctuation F1 | Mean RTF | Load, s |
|---|---:|---:|---:|---:|
| **ONNX, CPU** | **0.079** | **0.965** | **0.119** | 3.7 |
| parakeet.cpp GGUF q8_0, CPU | 0.084 | 0.909 | 0.182 | 5.5 |
| parakeet.cpp GGUF q8_0, Vulkan | 0.084 | 0.909 | 0.133 | 6.0 |
| whisper.cpp large-v3-turbo q8_0, Vulkan | — | — | 0.63–6.4 | 17 |

whisper.cpp spends about 11 s on every call whatever the clip length (it
pads input to a 30 s window), so a 2 s command took 11 s; its run was
stopped there, so its accuracy is not scored. The GGUF and
Whisper engines were removed on 2026-10-17; details in
`docs/specs/cross-platform-onnx-asr-spec.md` §12.

## 🎚️ Pause detection (Silero VAD)

Long dictations are split into segments at pauses (a lightweight
mel-energy heuristic), recognized in overlapping windows and stitched back
together. Seams between windows are placed with
[Silero VAD](https://github.com/snakers4/silero-vad) — the ggml build,
`ggml-silero-v6.2.0.bin` (885 KB, MIT), which SuperDictate downloads in the
background into `~/Library/Application Support/SuperDictate/Models/` after
the speech model loads (pinned revision, size and SHA-256 verified). The VAD
runs locally on the CPU; until the file is there (or offline), seams fall
back to the mel-energy heuristic and everything keeps working.

## ✅ Checks before a pull request

```bash
bash -n install.sh uninstall.sh scripts/*.sh
plutil -lint swift/Info.plist entitlements.plist
swift run -c debug --package-path swift Parakey --self-test all
./scripts/build-app.sh ./dist/SuperDictate.app
codesign --verify --deep --strict ./dist/SuperDictate.app
otool -L ./dist/SuperDictate.app/Contents/MacOS/SuperDictate
file ./dist/SuperDictate.app/Contents/MacOS/SuperDictate
lipo -info ./dist/SuperDictate.app/Contents/MacOS/SuperDictate
```

`otool -L` must not list `/usr/local`, `/opt/homebrew`, `Cellar`,
`MoltenVK.dylib`, or `libvulkan`: the app executable carries only a CPU ggml
core for the Silero VAD and no GPU code at all, and the LLM helper
(`Contents/Helpers/SuperDictateLLMHost`) links MoltenVK statically — the
only runtime dependencies are Apple's system frameworks.

GitHub Actions repeats the self-tests, builds the bundle, runs the installer
on a clean macOS runner, and verifies uninstallation.

### Speech recognition benchmark

`scripts/benchmark-asr.sh` is a persistent, re-runnable script: it
synthesizes a fixed corpus via `say`/`afconvert` (RU/EN/mixed, short
commands, numbers, technical terms, ~30 s and ~120 s segments), runs each
clip through the real `--benchmark-transcribe onnx cpu <threads>` entry
point (checked before `NSApplication` is created, so it never falls through
to a normal app launch) and the app's own segmented dictation path, and
writes a report with WER, CER, punctuation F1, cold load, warm-up, first
transcription, warm median/p95 latency, RTF and peak RSS. It needs a
packaged bundle (`scripts/build-test-app.sh`), because the ONNX helper lives
in `Contents/Helpers`.

## ⚠️ Limitations

- Apple Silicon and Intel Macs on macOS 14 or newer are supported. Windows
  and Linux are not supported yet. Intel support has only been manually
  tested on one specific machine (Xeon E5-2678 v3 + AMD Radeon RX 6600,
  macOS 15.7.7), not through CI: hosted GitHub macOS runners are only
  available on Apple Silicon, so there's no automated coverage of this path
  yet.
- The published `SuperDictate.zip` is built for Intel (x86_64). On Apple
  Silicon, install with the build-from-source command instead — the
  installer verifies the architecture and will tell you.
- The public build is signed ad-hoc and not notarized by Apple. Installing
  via the command above is verified, but a ZIP downloaded manually through a
  browser may trigger a Gatekeeper warning.
- Because there's no stable Developer ID signature, macOS sometimes
  re-prompts for permissions after an update. Notarization requires a paid
  Apple Developer account.
- The first launch needs internet access to download the model. The panel
  checks for updates when opened; the background auto-check, if enabled,
  hits the public GitHub API once every six hours.
- A single recording ends automatically after 20 minutes. If the app crashes,
  an unfinished recording is saved for history recovery.
- Protected password fields and apps that hide Accessibility data may not
  expose caret coordinates. This affects the animation's position but doesn't
  always prevent text insertion.
- Resource footprint on the current build: about 630 MB on disk for the
  speech model (ONNX int8, CPU). The ONNX helper process peaks at about
  2.2 GB resident (mapped model pages included); the app process itself
  stays around 40–60 MB.

## 🔒 Privacy & data

- History and settings: `~/Library/Application Support/SuperDictate`.
- The speech model: `~/Library/Application Support/SuperDictate/onnx`.
  (GGUF Parakeet and whisper.cpp files left over from earlier versions, in
  `~/Library/Application Support/SuperDictate/Models` and
  `~/Library/Application Support/Whisper/Models`, are no longer used and can
  be deleted.)
- LaunchAgent: `~/Library/LaunchAgents/com.local.superdictate.agent.plist`.
- Logs: `~/Library/Logs/SuperDictate*`.
- No analytics, accounts, or telemetry.

More details: [PRIVACY.md](PRIVACY.md).

## 🗑️ Uninstalling

```bash
curl -fsSL https://raw.githubusercontent.com/shohart/SuperDictate-Next/main/uninstall.sh | bash
```

The app and the background service are removed. History, settings, and the
model are kept, so you don't lose data or need to re-download the model by
accident.

## 📜 Origin and license

SuperDictate Next is a fork of
[SuperDictate](https://github.com/shlgd/SuperDictate), which is based on the
open-source [Parakey](https://github.com/rcourtman/parakey) project by
Richard Courtman. The original and modified code is distributed under the
MIT License. See [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md).

The project was formerly named **SuperDictate-Intel**; it was renamed to
SuperDictate Next with the v0.5.0 release. Old repository URLs redirect.

## 🤝 Contributing

Issues and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md)
for the checks to run before opening one, and
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for community guidelines.
