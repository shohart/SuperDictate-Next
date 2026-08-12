# 📋 Changelog

All notable changes to SuperDictate Next are documented here, in reverse
chronological order. This file covers the release history published on
[GitHub Releases](https://github.com/shohart/SuperDictate-Next/releases).

The format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

- **Automatic vocabulary learning**: SuperDictate now notices when you
  hand-correct a short word or phrase right after it inserts a dictation
  (classic case: an English loanword written out phonetically in Cyrillic)
  and remembers the fix on its own — a HUD toast confirms what was learned
  with an "Отменить"/Undo button, no manual entry required. Off switch in
  Settings ("Автоматически учить словарь по вашим правкам").
- New **Vocabulary** manager window (opened from Settings): a full table of
  every text correction — manual and auto-learned — with add/edit/delete,
  plus the existing JSON import/export.
- Text corrections now live in a local SQLite database
  (`~/Library/Application Support/SuperDictate/corrections.sqlite`) instead
  of `UserDefaults`. Existing corrections migrate automatically, once, on
  first launch after upgrading — nothing to do on your end. Cross-Mac
  folder sync (Dropbox/iCloud/etc.) still uses the same JSON file format as
  before.

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
