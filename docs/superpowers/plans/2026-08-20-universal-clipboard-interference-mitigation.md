# Universal Clipboard Interference Mitigation — Implementation Plan

**Goal:** Mark SuperDictate's ephemeral clipboard-paste write with the
`org.nspasteboard.TransientType` convention so it's not mistaken for a real
user copy by clipboard-history tools and (best-effort, unverifiable from
application code) macOS Continuity's `sharingd`, and add log lines so a
future recurrence can be correlated against SuperDictate's own pasteboard
activity. See `docs/superpowers/specs/2026-08-20-universal-clipboard-
interference-design.md` for full root-cause analysis.

**Architecture:** `ClipboardPasteInserter.write(_:to:)` gains a `transient:
Bool = false` parameter (default keeps the two existing non-ephemeral call
sites unchanged). When `true`, it writes an `NSPasteboardItem` carrying both
`.string` and an empty-data `org.nspasteboard.TransientType` entry via
`writeObjects`, instead of the plain `setString(_:forType:)` path. Only
`insert(_:)`'s own transient write passes `transient: true`. Add success-
path logging to `insert(_:)` and `restorePasteboard`.

**Test harness:** This project does not use `swift test`/XCTest — it has a
custom compiled-in self-test runner (`ParakeySelfTest`, `SelfTest.swift`,
`#if DEBUG` only), invoked as `.build/debug/Parakey --self-test <suite>` or
`--self-test all`. New coverage goes in a new suite function in that same
file, following the existing `testClipboardPasteInserterRestore` pattern
(line 1612).

## Task 1: Mark the transient write, add logging, add test coverage

**Files:**
- Modify: `swift/Sources/Parakey/TextInsertion.swift`
  (`ClipboardPasteInserter.write`, `.insert`, `.restorePasteboard`)
- Modify: `swift/Sources/Parakey/SelfTest.swift` (new suite +
  `testAll()` + `run(arguments:)` switch)

- [ ] **Step 1: Add `transient` parameter to `write(_:to:)`**

  Add a private `transientMarkerType` constant
  (`NSPasteboard.PasteboardType("org.nspasteboard.TransientType")`) and
  change the signature to `write(_ text: String, to pb: NSPasteboard,
  transient: Bool = false) -> Bool`. When `transient`, build an
  `NSPasteboardItem`, `setData(text.data(using:.utf8), forType: .string)`,
  `setData(Data(), forType: transientMarkerType)`, and
  `pb.writeObjects([item])`; fall back to the existing `setString` path if
  UTF-8 encoding somehow fails (it won't for a `String`, but keep the
  return-`Bool`-on-failure contract intact rather than force-unwrapping).

- [ ] **Step 2: Pass `transient: true` from `insert(_:)`**

  `TextInsertion.swift:1065`: `write(text, to: pasteboard, transient:
  true)`. Leave the two other call sites (`ParakeyApp.swift:2382`,
  `SelfTest.swift:1423`) as-is — they get the new default (`false`) for
  free and keep compiling unchanged.

- [ ] **Step 3: Add success-path log lines**

  In `insert(_:)`, after a successful transient write, log e.g. `"clipboard:
  wrote transient dictation text (org.nspasteboard.TransientType)"`. In
  `restorePasteboard`'s main-queue completion: log `"clipboard: restored
  previous contents"` on the success branch, and `"clipboard: restore
  skipped, pasteboard changed during paste wait"` on the guard-failure
  branch (this is the one that currently returns silently).

- [ ] **Step 4: Add a self-test suite for the marking behavior**

  New `testClipboardPasteInserterTransientMarking()` in `SelfTest.swift`,
  modeled on the existing pasteboard-probe pattern (line ~1420) using
  `NSPasteboard(name:)` with a unique test name (never `.general`):
  - `write(_:to:transient: true)` → assert the resulting pasteboard item's
    `types` contains `org.nspasteboard.TransientType` AND
    `pasteboard.string(forType: .string)` still equals the written text.
  - `write(_:to:)` (default / `transient: false`) → assert
    `org.nspasteboard.TransientType` is NOT present, and the existing
    `pasteboardProbe`-style assertions (line 1430-1437) still pass
    unchanged.
  Wire it into `testAll()` and add a `"paste-transient-marking"` case in
  `run(arguments:)`'s switch, next to `"paste-restore"`.

- [ ] **Step 5: Build**

  Run `swift build` from `swift/`. Expect a clean build (incremental —
  `.build/` already exists from a prior build).

- [ ] **Step 6: Run the relevant self-tests**

  Run `.build/debug/Parakey --self-test paste-transient-marking`,
  `--self-test paste-restore`, `--self-test paste-confirmation`, and
  `--self-test paste` (the pre-existing suites this change touches or is
  adjacent to). Expect `OK` for all four. Optionally `--self-test all` for
  a full regression pass if time allows — this is a big binary, so scope
  to the touched suites first.

- [ ] **Step 7: Report back, do not install/commit without asking**

  Per `AGENTS.md`, the only installed bundle is `/Applications/
  SuperDictate.app`, replaced only via `scripts/install-local.sh` (which
  also restarts `com.local.superdictate.agent`) — do not run it
  automatically. Summarize the diff and ask the user whether to install
  locally to actually test against real Universal Clipboard, and whether
  to commit.
