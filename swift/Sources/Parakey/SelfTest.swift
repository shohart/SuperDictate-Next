// Parakey — push-to-talk dictation for macOS.
//
// Swift menu-bar app. The runtime covers hotkey capture (`CGEventTap`), audio capture
// (`AVAudioEngine`), transcription (vendored `parakeet.cpp`, CPU by
// default with an opt-in Vulkan GPU backend planned — see the "Use GPU" setting),
// paste-at-cursor (`NSPasteboard` + `CGEvent`),
// system-audio mute (`NSAppleScript`), menu-bar UI, settings,
// rolling history, in-app updater, and permission guidance.
//
// Section comments (`// MARK: -`) tag every major region; Cmd+Ctrl+Up
// in Xcode jumps between them. Keep them honest as you edit.
//
// Architectural invariants the build relies on are documented in
// ../../../AGENTS.md — read that before refactoring concurrency,
// resource loading, or codesigning. In particular:
//   - `AudioCapture` is *not* @MainActor (AVAudioEngine tap fires on
//     an audio thread; main-actor entry would SIGTRAP under Swift 6
//     strict concurrency).
//   - `AVAudioConverter` inputBlock must return .noDataNow, never
//     .endOfStream — the latter puts the converter in a terminal
//     state and every press after the first captures silence.
//   - Resources are loaded via `Bundle.main`, never `Bundle.module`
//     — SwiftPM's auto-generated resource bundle has no Info.plist
//     and breaks `codesign --deep`.

import AppKit
import AVFoundation
import AudioToolbox
import Foundation
import CoreGraphics
import parakeet_cpp
import CryptoKit
import Darwin
import ApplicationServices
import IOKit
import QuartzCore
import ServiceManagement
import UniformTypeIdentifiers

#if DEBUG
private enum SelfTestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

enum ParakeySelfTest {
    static func run(arguments: [String]) -> Int32? {
        guard arguments.count >= 2, arguments[0] == "--self-test" else { return nil }
        guard arguments.count == 2 else { return fail("usage") }

        switch arguments[1] {
        case "hotkey":
            return runSuite("hotkey", testHotkey)
        case "readiness":
            return runSuite("readiness", testReadiness)
        case "paste":
            return runSuite("paste", testPasteSuffixFormatting)
        case "paste-transient-marking":
            return runSuite("paste-transient-marking", testClipboardPasteInserterTransientMarking)
        case "paste-confirmation":
            return runSuite("paste-confirmation", testPasteConfirmationPoller)
        case "paste-restore":
            return runSuite("paste-restore", testClipboardPasteInserterRestore)
        case "history":
            return runSuite("history", testRecentTranscriptLimit)
        case "statistics":
            return runSuite("statistics", testDictationUsageStatistics)
        case "corrections":
            return runSuite("corrections", testTranscriptCorrections)
        case "vocabulary-store":
            return runSuite("vocabulary-store", testVocabularyStore)
        case "vocabulary-learning":
            return runSuite("vocabulary-learning", testLearnCandidateDetector)
        case "fillers":
            return runSuite("fillers", testFillerWordRemoval)
        case "filler-word-presets-custom-words":
            return runSuite("filler-word-presets-custom-words", testFillerWordRemoverPresetsAndCustomWords)
        case "audio-level":
            return runSuite("audio-level", testAudioLevelMetering)
        case "audio-conversion":
            return runSuite("audio-conversion", testAudioConversion)
        case "audio-input":
            return runSuite("audio-input", testAudioInputDeviceFiltering)
        case "audio-input-live":
            return runSuite("audio-input-live", testLiveAudioInputEnumeration)
        case "model-status":
            return runSuite("model-status", testSpeechModelStartupStatus)
        case "audio-route":
            return runSuite("audio-route", testAudioRouteChangeDecision)
        case "recording-lifecycle":
            return runSuite("recording-lifecycle", testRecordingLifecycle)
        case "power-state":
            return runSuite("power-state", testPowerStateRecoveryDecision)
        case "model-integrity":
            return runSuite("model-integrity", testModelIntegrity)
        case "update":
            return runSuite("update", testUpdate)
        case "hostile-env":
            return runSuite("hostile-env", testHostileRegistryEnvDetection)
        case "logging":
            return runSuite("logging", testPrivateLogAppend)
        case "diagnostics":
            return runSuite("diagnostics", testDiagnostics)
        case "insertion-target":
            return runSuite("insertion-target", testInsertionTargetTracking)
        case "insertion-target-live":
            return runSuite("insertion-target-live", testLiveInsertionTargetProbe)
        case "insertion-target-ax-override":
            return runSuite("insertion-target-ax-override", testInsertionTargetAXOverride)
        case "pid-debouncer":
            return runSuite("pid-debouncer", testPIDDebouncer)
        case "text-insertion-target-store":
            return runSuite("text-insertion-target-store", testPendingTextInsertionTargetStore)
        case "text-insertion-routing":
            return runSuite("text-insertion-routing", testTextInsertionRouting)
        case "parakeet-bridge":
            return runSuite("parakeet-bridge", testParakeetBridge)
        case "silero-vad-bridge":
            return runSuite("silero-vad-bridge", testSileroVadBridge)
        case "silero-vad-real":
            return runSuite("silero-vad-real", testSileroVadRealModel)
        case "pause-segmentation":
            return runSuite("pause-segmentation", testPauseSegmentation)
        case "overlap-windowing":
            return runSuite("overlap-windowing", testOverlapWindowing)
        case "segmented-transcription":
            return runSuite("segmented-transcription", testSegmentedTranscription)
        case "seam-dedup":
            return runSuite("seam-dedup", testSeamDedup)
        case "overlap-assembly":
            return runSuite("overlap-assembly", testOverlapAssembly)
        case "overlap-transcription-real":
            return runSuite("overlap-transcription-real", testOverlapTranscriptionRealModel)
        case "boundary-oracle":
            return runSuite("boundary-oracle", testBoundaryOracle)
        case "vad-boundary-oracle":
            return runSuite("vad-boundary-oracle", testVadBoundaryOracle)
        case "vad-boundary-oracle-real":
            return runSuite("vad-boundary-oracle-real", testVadBoundaryOracleRealModel)
        case "parakeet-cpu":
            return runSuite("parakeet-cpu", testParakeetCPUIntegration)
        case "parakeet-text-repair":
            return runSuite("parakeet-text-repair", testParakeetTranscriptRepair)
        case "russian-number-itn-cardinal":
            return runSuite("russian-number-itn-cardinal", testRussianNumberITNCardinal)
        case "russian-number-itn-ordinal":
            return runSuite("russian-number-itn-ordinal", testRussianNumberITNOrdinal)
        case "russian-number-itn-context":
            return runSuite("russian-number-itn-context", testRussianNumberITNContext)
        case "russian-number-itn-punctuation":
            return runSuite("russian-number-itn-punctuation", testRussianNumberITNPunctuation)
        case "russian-number-itn-pipeline":
            return runSuite("russian-number-itn-pipeline", testProcessedDictationTextITN)
        case "parakeet-vulkan":
            return runSuite("parakeet-vulkan", testParakeetVulkanIntegration)
        case "parakeet-vulkan-bench":
            return runSuite("parakeet-vulkan-bench", benchmarkParakeetCPUvsVulkan)
        case "token-transcription-decode":
            return runSuite("token-transcription-decode", testTokenTranscriptionDecode)
        case "recording-hud-display-mode":
            return runSuite("recording-hud-display-mode", testRecordingHUDDisplayMode)
        case "recording-hud-elapsed-format":
            return runSuite("recording-hud-elapsed-format", testFormatRecordingHUDElapsed)
        case "recording-hud-outline-path":
            return runSuite("recording-hud-outline-path", testRecordingHUDOutlineFillPath)
        case "filler-word-preset-defaults":
            return runSuite("filler-word-preset-defaults", testFillerWordPresetDefaults)
        case "enabled-filler-preset-keys-setting":
            return runSuite("enabled-filler-preset-keys-setting", testEnabledFillerPresetKeysSetting)
        case "silence-auto-stop-tracker":
            return runSuite("silence-auto-stop-tracker", testSilenceAutoStopTracker)
        case "disabled-custom-filler-words":
            return runSuite("disabled-custom-filler-words", testDisabledCustomFillerWords)
        case "recording-hud-accent-color-resolved":
            return runSuite("recording-hud-accent-color-resolved", testRecordingHUDAccentColorResolvedColor)
        case "all":
            return runSuite("all", testAll)
        default:
            return fail("unknown")
        }
    }

    private static func runSuite(_ name: String, _ body: () throws -> Void) -> Int32 {
        do {
            try body()
            print("PASS \(name)")
            return EXIT_SUCCESS
        } catch {
            print("FAIL \(name): \(error)")
            return EXIT_FAILURE
        }
    }

    private static func fail(_ message: String) -> Int32 {
        print("FAIL self-test: \(message)")
        return EXIT_FAILURE
    }

    private static func testAll() throws {
        try testHotkey()
        try testReadiness()
        try testPasteSuffixFormatting()
        try testClipboardPasteInserterTransientMarking()
        try testPasteConfirmationPoller()
        try testClipboardPasteInserterRestore()
        try testRecentTranscriptLimit()
        try testRecordingHUDDisplayMode()
        try testFormatRecordingHUDElapsed()
        try testRecordingHUDOutlineFillPath()
        try testDictationUsageStatistics()
        try testTranscriptCorrections()
        try testVocabularyStore()
        try testLearnCandidateDetector()
        try testFillerWordRemoval()
        try testFillerWordRemoverPresetsAndCustomWords()
        try testFillerWordPresetDefaults()
        try testEnabledFillerPresetKeysSetting()
        try testSilenceAutoStopTracker()
        try testDisabledCustomFillerWords()
        try testRecordingHUDAccentColorResolvedColor()
        try testAudioLevelMetering()
        try testAudioConversion()
        try testAudioInputDeviceFiltering()
        try testSpeechModelStartupStatus()
        try testAudioRouteChangeDecision()
        try testRecordingLifecycle()
        try testPowerStateRecoveryDecision()
        try testModelIntegrity()
        try testUpdate()
        try testHostileRegistryEnvDetection()
        try testPrivateLogAppend()
        try testDiagnostics()
        try testInsertionTargetTracking()
        try testPendingTextInsertionTargetStore()
        try testInsertionTargetAXOverride()
        try testPIDDebouncer()
        try testTextInsertionRouting()
        try testParakeetTranscriptRepair()
        try testRussianNumberITNCardinal()
        try testRussianNumberITNOrdinal()
        try testRussianNumberITNContext()
        try testRussianNumberITNPunctuation()
        try testProcessedDictationTextITN()
        try testParakeetBridge()
        try testSileroVadBridge()
        try testPauseSegmentation()
        try testOverlapWindowing()
        try testSegmentedTranscription()
        try testSeamDedup()
        try testOverlapAssembly()
        try testTokenTranscriptionDecode()
        try testBoundaryOracle()
        try testVadBoundaryOracle()
    }

    /// Covers `textInsertionRoute(for:targetElementStillValid:)` — the
    /// actual decision logic handleRelease() runs after trying
    /// TextInsertionService, including the case a prior version of this
    /// integration got wrong: `.noSupportedInsertionMethod` with a dead AX
    /// element (the SwiftBar-popover-closed case, where the *process*
    /// stays alive so `TextInsertionService` itself reports
    /// `.noSupportedInsertionMethod` rather than `.targetNoLongerValid`)
    /// must abort to clipboard, not fall back to the global mechanism —
    /// falling back there would silently insert into whatever app is now
    /// frontmost.
    private static func testTextInsertionRouting() throws {
        try expect(textInsertionRoute(for: nil, targetElementStillValid: true), equals: .fallBackToGlobalInsertion,
                   "no resolved target at all should go straight to the global mechanism")

        for success: TextInsertionResult in [.insertedUsingSelectedText, .insertedUsingValueAndRange, .insertedUsingKeyboardEvents] {
            try expect(textInsertionRoute(for: success, targetElementStillValid: true), equals: .usedFocusedTarget,
                       "a successful tier result should be treated as success regardless of element-liveness")
        }

        try expect(textInsertionRoute(for: .failed(.targetNoLongerValid), targetElementStillValid: true),
                   equals: .abortToClipboard,
                   "TextInsertionService's own targetNoLongerValid (dead process) must abort, not fall back")

        try expect(textInsertionRoute(for: .failed(.noSupportedInsertionMethod), targetElementStillValid: false),
                   equals: .abortToClipboard,
                   "all tiers failing against a dead AX element (process alive, element gone — the SwiftBar popover-closed case) must abort, not fall back")

        try expect(textInsertionRoute(for: .failed(.noSupportedInsertionMethod), targetElementStillValid: true),
                   equals: .fallBackToGlobalInsertion,
                   "all tiers failing against a still-live element (e.g. a read-only field) should fall back, not abort")

        try expect(textInsertionRoute(for: .failed(.accessibilityError(operation: "test", error: .failure)), targetElementStillValid: true),
                   equals: .fallBackToGlobalInsertion,
                   "a live-element AX error other than targetNoLongerValid should fall back")
        try expect(textInsertionRoute(for: .failed(.accessibilityError(operation: "test", error: .failure)), targetElementStillValid: false),
                   equals: .abortToClipboard,
                   "a dead-element AX error other than targetNoLongerValid should still abort")
    }

    /// Covers the press → release lifecycle of `pendingTextInsertionTarget`
    /// (ParakeyApp): captured on hotkey press, consumed exactly once at
    /// insertion time, and cleared afterward so a stale/previous session's
    /// target can never leak into the next dictation. Exercises
    /// `PendingTextInsertionTargetStore` directly rather than going through
    /// `ParakeyApp.handlePress`/`handleRelease`, which pull in the audio
    /// engine, hotkey registration, and menu bar — not something a headless
    /// self-test should stand up. `AXUIElementCreateSystemWide()` needs no
    /// Accessibility permission to construct (only to query attributes on
    /// it), so this runs unconditionally, unlike `insertion-target-live`.
    private static func testPendingTextInsertionTargetStore() throws {
        let systemWide = AXUIElementCreateSystemWide()
        let fakeTarget = FocusedTextTarget(
            application: systemWide,
            element: systemWide,
            applicationPID: 4242,
            elementPID: 4242,
            applicationName: "self-test",
            role: "AXTextArea",
            subrole: nil
        )

        var store = PendingTextInsertionTargetStore()
        try expect(store.target == nil, equals: true,
                   "a freshly constructed store should start empty (nothing captured yet)")

        // handlePress(): resolver succeeds, target captured.
        store.capture(fakeTarget)
        guard let capturedTarget = store.target else {
            throw SelfTestFailure.failed("capture() should store the resolved target for handleRelease() to consume")
        }
        try expect(capturedTarget.applicationPID, equals: fakeTarget.applicationPID,
                   "captured target should match what was passed to capture()")

        // handleRelease(): consume() hands the target to the insertion call
        // site and clears it in the same step — a one-shot use per
        // dictation, per the bug report's explicit requirement not to
        // reuse a stale target for a later, unrelated dictation.
        guard let consumed = store.consume() else {
            throw SelfTestFailure.failed("consume() should return the target captured at press time")
        }
        try expect(consumed.applicationPID, equals: fakeTarget.applicationPID,
                   "consume() should return the same target that was captured")
        try expect(store.target == nil, equals: true,
                   "consume() must clear the store as a side effect")

        // A second consume() (e.g. a stray retry) must not resurrect the
        // already-used target.
        try expect(store.consume() == nil, equals: true,
                   "consuming an already-emptied store should yield nil, not the previous target")

        // handlePress() for the NEXT dictation: capture(nil) is what
        // captureTextInsertionTargetForNextDictation() does immediately,
        // before the async AX resolution completes — simulates the
        // resolver failing/still-in-flight case, which must fall back to
        // the pre-existing global-post mechanism rather than reusing
        // anything from the previous session.
        store.capture(nil)
        try expect(store.consume() == nil, equals: true,
                   "a press with no resolved target must leave nothing for release to consume")
    }

    /// Covers `insertionTargetQueryContext(overriding:withAXFocusedApplication:)`
    /// -- the pure merge decision behind the SwiftBar-popover HUD fix -- with
    /// synthetic pid/name/bundleIdentifier values, so it needs neither real
    /// Accessibility permission nor a live focus-divergent target (that's
    /// what `insertion-target-live` is for). See
    /// `FocusedInsertionTargetTracker.query` for the real caller.
    private static func testInsertionTargetAXOverride() throws {
        func baseContext(pid: pid_t = 111, clickPoint: NSPoint? = NSPoint(x: 10, y: 20)) -> InsertionTargetQueryContext {
            InsertionTargetQueryContext(
                applicationPID: pid,
                applicationName: "Terminal",
                bundleIdentifier: "com.apple.Terminal",
                screens: [],
                coordinateReferenceMaxY: 1_080,
                lastClickPoint: clickPoint
            )
        }

        // No AX resolution available (permission missing, resolver threw,
        // etc.) -- must fall back to the NSWorkspace-derived context
        // completely unchanged, including its lastClickPoint.
        let noResolution = insertionTargetQueryContext(overriding: baseContext(), withAXFocusedApplication: nil)
        try expect(noResolution.applicationPID, equals: 111,
                   "nil AX resolution must leave context untouched")
        try expect(noResolution.lastClickPoint != nil, equals: true,
                   "nil AX resolution must not drop the click-point cache")

        // AX-resolved app agrees with NSWorkspace's frontmost app -- the
        // common, non-popover case. Must also pass through unchanged,
        // confirming this fix cannot alter behavior when there's no
        // divergence to correct.
        let agreeing = insertionTargetQueryContext(
            overriding: baseContext(),
            withAXFocusedApplication: (pid: 111, name: "Terminal", bundleIdentifier: "com.apple.Terminal")
        )
        try expect(agreeing.applicationPID, equals: 111, "agreeing AX resolution must leave context untouched")
        try expect(agreeing.lastClickPoint != nil, equals: true,
                   "agreeing AX resolution must not drop the click-point cache")

        // AX-resolved app DISAGREES with NSWorkspace's frontmost app -- the
        // SwiftBar-popover case: NSWorkspace still reports the previously
        // frontmost app (here, "Terminal", pid 111) while AX focus has
        // moved to the popover (pid 222). The override must win, and the
        // stale click-point cache (captured against pid 111) must be
        // dropped rather than hit-tested against the wrong window.
        let overridden = insertionTargetQueryContext(
            overriding: baseContext(),
            withAXFocusedApplication: (pid: 222, name: "SwiftBar", bundleIdentifier: "com.ameba.SwiftBar")
        )
        try expect(overridden.applicationPID, equals: 222,
                   "diverging AX resolution should override the NSWorkspace-derived pid")
        try expect(overridden.applicationName, equals: "SwiftBar",
                   "diverging AX resolution should override the application name")
        try expect(overridden.bundleIdentifier, equals: "com.ameba.SwiftBar",
                   "diverging AX resolution should override the bundle identifier")
        try expect(overridden.lastClickPoint == nil, equals: true,
                   "an overridden context must drop the click-point cache -- it was captured against the wrong (pre-override) pid")
        try expect(overridden.screens.count, equals: baseContext().screens.count,
                   "overriding application identity must not disturb the screen geometry carried over from context")
        try expect(overridden.coordinateReferenceMaxY, equals: baseContext().coordinateReferenceMaxY,
                   "overriding application identity must not disturb coordinateReferenceMaxY carried over from context")

        // Resolved name/bundleIdentifier can themselves be nil (e.g.
        // NSRunningApplication lookup failed) even though the pid
        // genuinely differs -- must still override the pid, falling back
        // to context's own name/bundleIdentifier for the fields AX/NSRunningApplication
        // couldn't supply, rather than losing the override entirely.
        let partialResolution = insertionTargetQueryContext(
            overriding: baseContext(),
            withAXFocusedApplication: (pid: 222, name: nil, bundleIdentifier: nil)
        )
        try expect(partialResolution.applicationPID, equals: 222,
                   "a pid-only AX resolution should still override, even without name/bundleIdentifier")
        try expect(partialResolution.applicationName, equals: "Terminal",
                   "missing resolved name should fall back to context's own name")
        try expect(partialResolution.bundleIdentifier, equals: "com.apple.Terminal",
                   "missing resolved bundleIdentifier should fall back to context's own bundleIdentifier")
    }

    /// Covers `PIDDebouncer` -- the hysteresis behind
    /// `FocusedInsertionTargetTracker`'s AX-override, which must not react
    /// to a single, transient diverging pid observation (see the review
    /// finding it was added for: without it, a one-off AX focus blip could
    /// yank the HUD away from an already-correct target mid-recording).
    private static func testPIDDebouncer() throws {
        var debouncer = PIDDebouncer(requiredConsecutiveMatches: 2)

        try expect(debouncer.observe(222) == nil, equals: true,
                   "a single observation must not confirm yet -- requires 2 consecutive matches")
        try expect(debouncer.observe(222) == 222, equals: true,
                   "the same pid observed twice in a row should confirm")
        try expect(debouncer.observe(222) == 222, equals: true,
                   "once confirmed, continuing to observe the same pid should keep confirming it")

        // A transient blip to a DIFFERENT pid, then back to the original --
        // must not spuriously confirm the blip, and returning to the
        // original pid afterward must start its confirmation progress
        // over from scratch, not resume from wherever it left off before
        // the blip.
        debouncer.reset()
        try expect(debouncer.observe(111) == nil, equals: true, "first observation of a new pid never confirms immediately")
        try expect(debouncer.observe(333) == nil, equals: true,
                   "a single-tick blip to a different pid must not confirm -- it resets progress toward the original pid too")
        try expect(debouncer.observe(111) == nil, equals: true,
                   "returning to the original pid after a blip is a fresh first observation, not a continuation -- must not confirm immediately")
        try expect(debouncer.observe(111) == 111, equals: true,
                   "the original pid confirms once it's been seen twice in a row again, after the blip")

        // A genuine, sustained switch to a different pid (no return to the
        // original) -- the new pid must confirm after its own 2
        // consecutive observations, exactly like any other pid.
        debouncer.reset()
        try expect(debouncer.observe(444) == nil, equals: true, "first observation before a sustained switch")
        try expect(debouncer.observe(666) == nil, equals: true,
                   "switching to a different pid must not confirm immediately -- it resets progress toward the new pid too")
        try expect(debouncer.observe(666) == 666, equals: true,
                   "the new pid confirms once it's been seen twice in a row")

        // nil observation (AX resolution failed, or agreement with
        // context -- both surfaced as nil by the caller) must reset
        // progress, not be silently ignored.
        debouncer.reset()
        _ = debouncer.observe(444)
        try expect(debouncer.observe(nil) == nil, equals: true, "a nil observation never confirms")
        try expect(debouncer.observe(444) == nil, equals: true,
                   "a nil observation in between must reset progress -- this is the pid's first observation again, not its second")
        try expect(debouncer.observe(444) == 444, equals: true,
                   "444 confirms after being seen twice in a row following the reset")

        // Explicit reset() (called at the start of each new recording)
        // must clear any lingering progress from a previous session.
        debouncer.reset()
        _ = debouncer.observe(555)
        debouncer.reset()
        try expect(debouncer.observe(555) == nil, equals: true,
                   "reset() must clear prior progress -- 555 needs 2 fresh observations, not 1, after a reset")
        try expect(debouncer.observe(555) == 555, equals: true, "555 confirms on its second observation after the reset")
    }

    private static func testInsertionTargetTracking() throws {
        func target(pid: pid_t, window: UInt, element: UInt) -> FocusedInsertionTargetFrame {
            FocusedInsertionTargetFrame(
                frame: NSRect(x: 100, y: 100, width: 2, height: 18),
                visualFrame: NSRect(x: 80, y: 80, width: 300, height: 48),
                resolutionKind: "self-test",
                identity: FocusedInsertionTargetIdentity(
                    applicationPID: pid,
                    windowToken: window,
                    elementToken: element
                )
            )
        }

        let first = target(pid: 10, window: 1, element: 1)
        let secondField = target(pid: 10, window: 1, element: 2)
        let otherApp = target(pid: 20, window: 2, element: 1)
        var stabilizer = RecordingHUDTargetStabilizer()
        stabilizer.reset(initialApplicationPID: 10)

        switch stabilizer.observe(first) {
        case .switchTarget(let accepted):
            try expect(accepted.identity, equals: first.identity,
                       "initial target from the starting app should be accepted immediately")
        default:
            throw SelfTestFailure.failed("initial insertion target was not accepted")
        }

        switch stabilizer.observe(first) {
        case .update(let accepted):
            try expect(accepted.identity, equals: first.identity,
                       "the confirmed insertion target should update without another switch")
        default:
            throw SelfTestFailure.failed("confirmed insertion target did not produce an update")
        }

        if case .none = stabilizer.observe(secondField) {
            // Expected: a new field in the same app needs two matching observations.
        } else {
            throw SelfTestFailure.failed("same-app target switched without confirmation")
        }
        switch stabilizer.observe(secondField) {
        case .switchTarget(let accepted):
            try expect(accepted.identity, equals: secondField.identity,
                       "same-app target should switch after confirmation")
        default:
            throw SelfTestFailure.failed("same-app target did not switch after confirmation")
        }

        for attempt in 1...2 {
            if case .none = stabilizer.observe(otherApp) {
                continue
            }
            throw SelfTestFailure.failed("cross-app target switched on observation \(attempt)")
        }
        switch stabilizer.observe(otherApp) {
        case .switchTarget(let accepted):
            try expect(accepted.identity, equals: otherApp.identity,
                       "cross-app target should switch after three stable observations")
        default:
            throw SelfTestFailure.failed("cross-app target did not switch after confirmation")
        }

        if case .none = stabilizer.observe(nil) {
            // A missing AX sample must not discard the confirmed target.
        } else {
            throw SelfTestFailure.failed("missing target unexpectedly changed HUD ownership")
        }
        switch stabilizer.observe(otherApp) {
        case .update:
            break
        default:
            throw SelfTestFailure.failed("confirmed target was lost after one missing AX sample")
        }

        let screen = InsertionTargetScreenGeometry(
            frame: NSRect(x: 0, y: 0, width: 1_920, height: 1_080),
            visibleFrame: NSRect(x: 0, y: 0, width: 1_920, height: 1_055)
        )
        let context = InsertionTargetQueryContext(
            applicationPID: 10,
            applicationName: "self-test",
            bundleIdentifier: "self-test",
            screens: [screen],
            coordinateReferenceMaxY: screen.frame.maxY,
            lastClickPoint: nil
        )
        let documentFrame = NSRect(x: 560, y: 150, width: 946, height: 698)
        let caretFrame = NSRect(x: 582, y: 419, width: 2, height: 17)
        let documentVisualFrame = FocusedInsertionTargetLocator.visualTargetFrame(
            elementFrame: documentFrame,
            caretFrame: caretFrame,
            context: context
        )
        try expect(documentVisualFrame.minX, equals: documentFrame.minX,
                   "large editors should retain their block's left edge")
        try expect(documentVisualFrame.minY, equals: caretFrame.minY,
                   "large editors should anchor vertically to the caret line")
        try expect(documentVisualFrame.height, equals: caretFrame.height,
                   "large editors should not place the HUD above the whole document")

        let compactFrame = NSRect(x: 700, y: 120, width: 720, height: 96)
        try expect(
            FocusedInsertionTargetLocator.visualTargetFrame(
                elementFrame: compactFrame,
                caretFrame: NSRect(x: 720, y: 150, width: 2, height: 18),
                context: context
            ),
            equals: compactFrame,
            "compact composers should keep the HUD above the whole input block"
        )
    }

    private static func testLiveInsertionTargetProbe() throws {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw SelfTestFailure.failed("frontmost application unavailable")
        }
        let screens = NSScreen.screens.map {
            InsertionTargetScreenGeometry(frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
        let context = InsertionTargetQueryContext(
            applicationPID: app.processIdentifier,
            applicationName: app.localizedName ?? "unknown",
            bundleIdentifier: app.bundleIdentifier ?? "unknown",
            screens: screens,
            coordinateReferenceMaxY: screens.first?.frame.maxY ?? 0,
            lastClickPoint: nil
        )
        let result = FocusedInsertionTargetLocator.query(context: context)
        try expect(result.applicationPID, equals: app.processIdentifier,
                   "live target query should preserve the requested application")
        try expect(result.diagnostic.isEmpty, equals: false,
                   "live target query should always explain its result")
        let targetSummary = result.target.map {
            "\($0.resolutionKind) frame=\(NSStringFromRect($0.frame)) visual=\(NSStringFromRect($0.visualFrame))"
        } ?? "unavailable"
        print("AX_PROBE \(result.applicationName) (\(result.bundleIdentifier)): \(targetSummary); \(result.diagnostic)")
    }

    private static func testPrivateLogAppend() throws {
        try expect(
            privacySafeLogPath("/Users/example/Documents/Parakey Diagnostics.txt"),
            equals: "Parakey Diagnostics.txt",
            "log path labels should omit parent directories"
        )
        try expect(
            privacySafeLogPath("/"),
            equals: "<local path>",
            "log path labels should fall back when no filename is available"
        )
        try expect(
            privacySafeBundlePath("/Applications/SuperDictate.app"),
            equals: "/Applications/SuperDictate.app",
            "bundle path labels should keep the canonical install path"
        )
        try expect(
            privacySafeBundlePath("/Users/example/Downloads/SuperDictate.app"),
            equals: "SuperDictate.app",
            "bundle path labels should omit parent directories for nonstandard installs"
        )

        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parakey-log-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }

        let logFile = root.appendingPathComponent("SuperDictate.log")
        try appendPrivateLogData(Data("one\n".utf8), to: logFile)
        try appendPrivateLogData(Data("two\n".utf8), to: logFile)

        let attrs = try fm.attributesOfItem(atPath: logFile.path)
        let permissions = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        try expect(permissions & 0o777,
                   equals: 0o600,
                   "log file should be private to the current user")
        try expect(
            String(data: try Data(contentsOf: logFile), encoding: .utf8),
            equals: "one\ntwo\n",
            "log appends should preserve existing content"
        )

        let target = root.appendingPathComponent("target.log")
        try Data("target\n".utf8).write(to: target)
        let link = root.appendingPathComponent("link.log")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)

        var symlinkRejected = false
        do {
            try appendPrivateLogData(Data("bad\n".utf8), to: link)
        } catch {
            symlinkRejected = true
        }
        try expect(symlinkRejected,
                   equals: true,
                   "log appends should reject leaf symlinks")
        try expect(
            String(data: try Data(contentsOf: target), encoding: .utf8),
            equals: "target\n",
            "log symlink rejection should leave the target untouched"
        )

        let hardlinkTarget = root.appendingPathComponent("hardlink-target.log")
        try Data("hardlink target\n".utf8).write(to: hardlinkTarget)
        let hardlink = root.appendingPathComponent("hardlink.log")
        guard Darwin.link(hardlinkTarget.path, hardlink.path) == 0 else {
            throw currentPOSIXError()
        }

        var hardlinkRejected = false
        do {
            try appendPrivateLogData(Data("bad\n".utf8), to: hardlink)
        } catch {
            hardlinkRejected = true
        }
        try expect(hardlinkRejected,
                   equals: true,
                   "log appends should reject hard-linked files")
        try expect(
            String(data: try Data(contentsOf: hardlinkTarget), encoding: .utf8),
            equals: "hardlink target\n",
            "log hard-link rejection should leave the target untouched"
        )
    }

    private static func testDiagnostics() throws {
        let transcriptSecret = "secret dictated phrase 58A03D"
        let correctionSecret = "private correction replacement 9F42"
        let report = diagnosticsReportText(
            from: DiagnosticsReportSnapshot(
                generated: "2026-05-28T10:00:00Z",
                appVersion: "9.8.7",
                appBuild: "123",
                macOS: "Version 26.0",
                bundleID: "com.local.superdictate",
                bundlePath: "/Applications/SuperDictate.app",
                installKind: "Applications app",
                status: "Hold Right Option to dictate",
                startup: "Runtime ready",
                speechModelReady: true,
                coreRuntimeReady: true,
                readyForDictation: true,
                recordingActive: false,
                transcribing: false,
                memoryLines: ["Resident: 100 MB"],
                permissionLines: ["Microphone: granted", "Accessibility: granted", "Input Monitoring: granted"],
                settingLines: [
                    "Speech model: Parakeet TDT 0.6B v3",
                    "Language: Auto-detect",
                    "Recent transcripts: Last 5 (1 in memory)",
                    "Text corrections: 1 configured",
                    "Text correction sync: configured",
                ],
                updateLines: ["Pending update: none"],
                microphoneLines: ["Selected: System default", "Available inputs: none reported"],
                logPath: "~/Library/Logs/SuperDictate.log",
                recentLogLines: ["[10:00:00] release: 1.23 s captured, transcribing"]
            )
        )
        try expect(report.contains(transcriptSecret), equals: false,
                   "diagnostics report should not include transcript contents")
        try expect(report.contains(correctionSecret), equals: false,
                   "diagnostics report should not include text correction contents")
        try expect(report.contains("Text corrections: 1 configured"), equals: true,
                   "diagnostics report should include correction counts")
        try expect(report.contains("Speech model: Parakeet TDT 0.6B v3"), equals: true,
                   "diagnostics report should include the speech model")
        try expect(report.contains("Recent log lines:"), equals: true,
                   "diagnostics report should include the recent log section")
        try expect(report.contains("Privacy: transcript text and text-correction contents are not included."),
                   equals: true,
                   "diagnostics report should state the privacy boundary")

        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parakey-diagnostics-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }

        let logFile = root.appendingPathComponent("SuperDictate.log")
        for line in 1...6 {
            try appendPrivateLogData(Data("[10:00:0\(line)] line \(line)\n".utf8), to: logFile)
        }
        try expect(
            try recentDiagnosticLogLines(from: logFile, maxBytes: 4096, maxLines: 3),
            equals: ["[10:00:04] line 4", "[10:00:05] line 5", "[10:00:06] line 6"],
            "diagnostic log tail should return the newest bounded lines"
        )

        let target = root.appendingPathComponent("target.log")
        try Data("[10:00:00] target\n".utf8).write(to: target)
        let symlink = root.appendingPathComponent("symlink.log")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: target)
        var symlinkRejected = false
        do {
            _ = try recentDiagnosticLogLines(from: symlink, maxBytes: 4096, maxLines: 3)
        } catch {
            symlinkRejected = true
        }
        try expect(symlinkRejected, equals: true,
                   "diagnostic log tail should reject leaf symlinks")

        let hardlink = root.appendingPathComponent("hardlink.log")
        guard Darwin.link(target.path, hardlink.path) == 0 else {
            throw currentPOSIXError()
        }
        var hardlinkRejected = false
        do {
            _ = try recentDiagnosticLogLines(from: hardlink, maxBytes: 4096, maxLines: 3)
        } catch {
            hardlinkRejected = true
        }
        try expect(hardlinkRejected, equals: true,
                   "diagnostic log tail should reject hard-linked files")
    }

    private static func testHotkey() throws {
        try testHotkeyPreferenceNormalization()
        try testHotkeyPreferenceUpdateResults()
        try testHotkeyRecorderCaptureFlow()
        try testHotkeyRecorderRestartActions()
        try testHandledHotkeySuppression()
        try testCustomShortcutMatching()
        try testModifierOnlyChordMatching()
        try testConfigurableEnterShortcut()
        try testEnterChordBuiltOnHeldPrimaryModifier()
        try testCommandModifierEnterShortcutWithPrimaryCommand()
        try testFKeyAutoRepeatSuppressesWithoutAction()
        try testRightModifierReleaseWithLeftFlagStillSet()
        try testHistoryChordShowsOverlay()
        try testConfigurableHistoryShortcut()
        try testOptionCommandEnterChordStopsWithEnter()
        try testEnterShortcutModeSelection()
        try testTogglePressFlipsOnceAndReleaseIsNoOp()
        try testToggleGatedPressDoesNotFlipToggleState()
        try testEscapePassesThroughWhenNotRecording()
        try testEscapeSuppressesCancelRepeatAndKeyUpWhileRecording()
    }

    private static func testHotkeyPreferenceNormalization() throws {
        try expect(
            normalizedHotkeyKeycode(storedValue: NSNumber(value: Int(DEFAULT_HOTKEY_KEYCODE))),
            equals: DEFAULT_HOTKEY_KEYCODE,
            "stored hotkey normalization should keep supported numeric keycodes"
        )
        try expect(
            normalizedHotkeyKeycode(storedValue: " 96\n"),
            equals: CGKeyCode(96),
            "stored hotkey normalization should accept legacy string keycodes"
        )
        try expect(
            normalizedHotkeyKeycode(storedValue: NSNumber(value: 98)),
            equals: CGKeyCode(98),
            "stored hotkey normalization should accept recorded F-key keycodes"
        )
        try expect(
            hotkeyChoice(forKeycode: CGKeyCode(98)),
            equals: HotkeyChoice(name: "F7", keycode: 98, isModifier: false, modifierFlag: nil),
            "recorded F-key choices should get a stable display name"
        )
        try expect(
            localizedHotkeyName(hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE),
                                language: .russian),
            equals: "Правый Command",
            "Russian UI should localize a modifier-only shortcut"
        )
        try expect(
            localizedHotkeyName(hotkeyChoice(forKeycode: 49, modifiers: .maskAlternate),
                                language: .russian),
            equals: "⌥Пробел",
            "Russian UI should localize a chord key name"
        )
        try expect(
            normalizedHotkeyKeycode(storedValue: NSNumber(value: 999)),
            equals: nil,
            "stored hotkey normalization should reject unsupported keycodes"
        )
        try expect(
            normalizedHotkeyKeycode(storedValue: NSNumber(value: -1)),
            equals: nil,
            "stored hotkey normalization should reject negative keycodes"
        )
        try expect(
            hotkeyChoice(forKeycode: CGKeyCode(999)),
            equals: hotkeyChoice(forKeycode: DEFAULT_HOTKEY_KEYCODE),
            "unknown hotkey choices should fall back to the default"
        )

        try expect(
            hotkeyRecordingDecision(for: event(.keyDown, keycode: 98)),
            equals: .accept(HotkeyChoice(name: "F7", keycode: 98, isModifier: false, modifierFlag: nil)),
            "hotkey recorder should accept F-key presses outside the quick-pick list"
        )
        try expect(
            hotkeyRecordingDecision(for: event(.keyDown, keycode: 0)),
            equals: .accept(HotkeyChoice(name: "A", keycode: 0, isModifier: false, modifierFlag: nil)),
            "hotkey recorder should accept a single typing key"
        )
        try expect(
            hotkeyRecordingDecision(for: event(.keyDown,
                                               keycode: 40,
                                               flags: CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue)),
            equals: .accept(HotkeyChoice(name: "⇧⌘K",
                                         keycode: 40,
                                         isModifier: false,
                                         modifierFlag: nil,
                                         requiredModifiers: [.maskCommand, .maskShift])),
            "hotkey recorder should accept multi-key shortcuts"
        )
        try expect(
            hotkeyRecordingDecision(for: event(.keyDown, keycode: 98, isAutoRepeat: true)),
            equals: .ignore,
            "hotkey recorder should ignore auto-repeat"
        )
        try expect(
            hotkeyRecordingDecision(for: event(.flagsChanged,
                                               keycode: 61,
                                               flags: CGEventFlags.maskAlternate.rawValue)),
            equals: .ignore,
            "hotkey recorder should not accept a modifier on press (chords capture on release)"
        )
        try expect(
            hotkeyRecordingDecision(for: event(.flagsChanged, keycode: 61)),
            equals: .accept(HotkeyChoice(name: "Right Option",
                                         keycode: 61,
                                         isModifier: true,
                                         modifierFlag: .maskAlternate)),
            "hotkey recorder should accept a bare right-side modifier on release"
        )
        try expect(
            hotkeyRecordingDecision(for: event(
                .flagsChanged,
                keycode: RIGHT_COMMAND_KEYCODE,
                flags: CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue
            )),
            equals: .ignore,
            "hotkey recorder should keep waiting while a modifier chord is still being pressed"
        )
        try expect(
            hotkeyRecordingDecision(for: event(
                .flagsChanged,
                keycode: RIGHT_COMMAND_KEYCODE,
                flags: CGEventFlags.maskAlternate.rawValue
            )),
            equals: .accept(hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE,
                                         modifiers: [.maskAlternate])),
            "hotkey recorder should accept modifier-only chords on release (other chord keys still held)"
        )
    }

    private static func testHotkeyPreferenceUpdateResults() throws {
        let f5 = hotkeyChoice(forKeycode: 96)
        let f7 = hotkeyChoice(forKeycode: 98)
        let invalid = HotkeyChoice(name: "Escape", keycode: ESCAPE_KEYCODE, isModifier: false, modifierFlag: nil)

        try expect(
            hotkeyPreferenceUpdateResult(
                requested: f7,
                previous: f5,
                persisted: f7
            ),
            equals: .saved(f7),
            "hotkey preference update should save supported keys after persistence confirms them"
        )
        try expect(
            hotkeyPreferenceUpdateResult(
                requested: invalid,
                previous: f5,
                persisted: f5
            ),
            equals: .rejected("That key cannot be used for dictation."),
            "hotkey preference update should reject unsupported keys before mutating settings"
        )
        try expect(
            hotkeyPreferenceUpdateResult(
                requested: f7,
                previous: f5,
                persisted: f5
            ),
            equals: .rolledBack(
                previous: f5,
                message: "Parakey could not save that hotkey, so it kept F5."
            ),
            "hotkey preference update should roll back when persisted settings disagree"
        )
    }

    private static func testHotkeyRecorderCaptureFlow() throws {
        try expect(
            hotkeyFlags(from: [.command, .option]),
            equals: [.maskCommand, .maskAlternate],
            "recorder should translate AppKit modifier flags without relying on an optional CGEvent"
        )

        var singleCommand = HotkeyRecorderCaptureState()
        let commandDown = event(.flagsChanged,
                                keycode: RIGHT_COMMAND_KEYCODE,
                                flags: CGEventFlags.maskCommand.rawValue)
        let rightCommand = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE)
        try expect(
            singleCommand.consume(commandDown),
            equals: .ignore,
            "pressing Right Command alone should keep the recorder waiting"
        )
        try expect(
            singleCommand.consume(event(.flagsChanged, keycode: RIGHT_COMMAND_KEYCODE)),
            equals: .candidate(rightCommand),
            "releasing Right Command with nothing else held should select it as a one-key shortcut"
        )

        var singleModifier = HotkeyRecorderCaptureState()
        let optionDown = event(.flagsChanged,
                               keycode: 58,
                               flags: CGEventFlags.maskAlternate.rawValue)
        let leftOption = hotkeyChoice(forKeycode: 58)
        try expect(
            singleModifier.consume(optionDown),
            equals: .ignore,
            "pressing Option alone should keep the recorder waiting"
        )
        try expect(
            singleModifier.consume(event(.flagsChanged, keycode: 58)),
            equals: .candidate(leftOption),
            "releasing Option with nothing else held should select it as a one-key shortcut"
        )

        for (keycode, flags, label) in [
            (CGKeyCode(55), CGEventFlags.maskCommand, "Left Command"),
            (CGKeyCode(59), CGEventFlags.maskControl, "Left Control"),
            (FN_KEYCODE, CGEventFlags.maskSecondaryFn, "Fn"),
        ] {
            var modifier = HotkeyRecorderCaptureState()
            try expect(
                modifier.consume(event(.flagsChanged,
                                       keycode: keycode,
                                       flags: flags.rawValue)),
                equals: .ignore,
                "pressing \(label) should keep the recorder waiting"
            )
            try expect(
                modifier.consume(event(.flagsChanged, keycode: keycode)),
                equals: .candidate(hotkeyChoice(forKeycode: keycode)),
                "releasing \(label) with nothing else held should select it"
            )
        }

        var chord = HotkeyRecorderCaptureState()
        _ = chord.consume(optionDown)
        try expect(
            chord.consume(event(.keyDown,
                                keycode: 40,
                                flags: CGEventFlags.maskAlternate.rawValue)),
            equals: .candidate(hotkeyChoice(forKeycode: 40,
                                            modifiers: .maskAlternate)),
            "pressing a regular key while a modifier is held should select the full chord"
        )

        var modifierChord = HotkeyRecorderCaptureState()
        _ = modifierChord.consume(optionDown)
        _ = modifierChord.consume(event(
            .flagsChanged,
            keycode: RIGHT_COMMAND_KEYCODE,
            flags: CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue
        ))
        try expect(
            modifierChord.consume(event(
                .flagsChanged,
                keycode: RIGHT_COMMAND_KEYCODE,
                flags: CGEventFlags.maskAlternate.rawValue
            )),
            equals: .candidate(hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE,
                                            modifiers: [.maskAlternate, .maskCommand])),
            "releasing one chord key while the other stays held should select the full modifier chord"
        )
        try expect(
            modifierChord.consume(event(.flagsChanged, keycode: 58)),
            equals: .ignore,
            "the trailing release of the remaining chord key must not overwrite the captured chord with a bare key"
        )

        var controlCommandChord = HotkeyRecorderCaptureState()
        _ = controlCommandChord.consume(event(.flagsChanged,
                                              keycode: LEFT_CONTROL_KEYCODE,
                                              flags: CGEventFlags.maskControl.rawValue))
        _ = controlCommandChord.consume(event(.flagsChanged,
                                              keycode: RIGHT_COMMAND_KEYCODE,
                                              flags: CGEventFlags.maskControl.rawValue | CGEventFlags.maskCommand.rawValue))
        try expect(
            controlCommandChord.consume(event(.flagsChanged,
                                              keycode: LEFT_CONTROL_KEYCODE,
                                              flags: CGEventFlags.maskCommand.rawValue)),
            equals: .candidate(hotkeyChoice(forKeycode: LEFT_CONTROL_KEYCODE,
                                            modifiers: [.maskControl, .maskCommand])),
            "Ctrl+Cmd pressed, Ctrl released first: the full chord should be captured"
        )
        try expect(
            controlCommandChord.consume(event(.flagsChanged, keycode: RIGHT_COMMAND_KEYCODE)),
            equals: .ignore,
            "the trailing Right Command release must not overwrite the captured Ctrl+Cmd chord"
        )

        var singleKey = HotkeyRecorderCaptureState()
        try expect(
            singleKey.consume(event(.keyDown, keycode: 96)),
            equals: .candidate(hotkeyChoice(forKeycode: 96)),
            "pressing one regular key should select it for confirmation"
        )

        var canceled = HotkeyRecorderCaptureState()
        try expect(
            canceled.consume(event(.keyDown, keycode: ESCAPE_KEYCODE)),
            equals: .cancel,
            "Escape should cancel shortcut recording"
        )
    }

    private static func testHotkeyRecorderRestartActions() throws {
        try expect(
            hotkeyRecorderRestartAction(
                shouldRestoreHotkeyTap: false,
                isTerminating: false,
                restartSucceeded: false
            ),
            equals: .none,
            "hotkey recorder should not start a listener that was not active"
        )
        try expect(
            hotkeyRecorderRestartAction(
                shouldRestoreHotkeyTap: true,
                isTerminating: true,
                restartSucceeded: false
            ),
            equals: .none,
            "hotkey recorder should not restart the listener during termination"
        )
        try expect(
            hotkeyRecorderRestartAction(
                shouldRestoreHotkeyTap: true,
                isTerminating: false,
                restartSucceeded: true
            ),
            equals: .restoredListener,
            "hotkey recorder should treat a successful restart as recovered"
        )
        try expect(
            hotkeyRecorderRestartAction(
                shouldRestoreHotkeyTap: true,
                isTerminating: false,
                restartSucceeded: false
            ),
            equals: .recordFailure,
            "hotkey recorder should surface restart failure after an active listener was paused"
        )
    }

    private static func testReadiness() throws {
        try expect(
            readinessTransition(isReady: false,
                                isCoreRuntimeReady: false,
                                missingPermissions: []),
            equals: .rebuildMenuOnly,
            "not-ready app without core runtime should wait and rebuild only"
        )
        try expect(
            readinessTransition(isReady: false,
                                isCoreRuntimeReady: true,
                                missingPermissions: [.microphone]),
            equals: .blockForPermissions([.microphone]),
            "core-ready app with missing microphone should block"
        )
        try expect(
            readinessTransition(isReady: true,
                                isCoreRuntimeReady: true,
                                missingPermissions: [.accessibility]),
            equals: .blockForPermissions([.accessibility]),
            "ready app with missing accessibility should block"
        )
        try expect(
            readinessTransition(isReady: false,
                                isCoreRuntimeReady: true,
                                missingPermissions: []),
            equals: .startHotkeyListener,
            "core-ready app with all permissions should start hotkey"
        )
        try expect(
            readinessTransition(isReady: true,
                                isCoreRuntimeReady: true,
                                missingPermissions: []),
            equals: .rebuildMenuOnly,
            "ready app with all permissions should remain ready and rebuild only"
        )

        try expect(
            productionSpeechModelProfile(rawValue: nil),
            equals: .parakeetTDTv3,
            "missing speech model setting should use the production default"
        )
        try expect(
            productionSpeechModelProfile(rawValue: SpeechModelProfile.parakeetTDTv3.rawValue),
            equals: .parakeetTDTv3,
            "stored v3 speech model should remain valid"
        )
        try expect(
            productionSpeechModelProfile(rawValue: "english_unified"),
            equals: .parakeetTDTv3,
            "old deprecated/legacy speech model setting should migrate to Parakeet TDT v3"
        )
        try expect(
            productionSpeechModelProfile(rawValue: "multilingual_v3"),
            equals: .parakeetTDTv3,
            "old pre-migration Whisper speech model setting should migrate to Parakeet TDT v3"
        )
        try expect(
            productionSpeechModelProfile(rawValue: "unknown_model"),
            equals: .parakeetTDTv3,
            "unknown speech model setting should migrate to Parakeet TDT v3"
        )

        try expect(
            speechModelSetupRowState(profile: .parakeetTDTv3,
                                     isSpeechModelReady: false,
                                     isStartupInProgress: true,
                                     startupStatusTitle: "Downloading speech model… 50%",
                                     failure: nil),
            equals: SetupChecklistRowState(detail: "Downloading speech model… 50%",
                                           status: "Loading",
                                           buttonTitle: nil),
            "setup checklist should show speech model progress"
        )
        try expect(
            speechModelSetupRowState(profile: .parakeetTDTv3,
                                     isSpeechModelReady: false,
                                     isStartupInProgress: false,
                                     startupStatusTitle: "Loading speech model…",
                                     failure: StartupFailure(stage: .speechModel, detail: "download failed")),
            equals: SetupChecklistRowState(detail: "download failed",
                                           status: "Needs retry",
                                           buttonTitle: "Retry"),
            "setup checklist should offer retry for speech model failures"
        )
        try expect(
            speechModelSetupRowState(profile: .parakeetTDTv3,
                                     isSpeechModelReady: true,
                                     isStartupInProgress: false,
                                     startupStatusTitle: "Loading speech model…",
                                     failure: nil),
            equals: SetupChecklistRowState(detail: "Parakeet TDT 0.6B v3 is loaded locally.",
                                           status: "Ready",
                                           buttonTitle: nil),
            "setup checklist should show the speech model when ready"
        )
        try expect(
            audioInputSetupRowState(isSpeechModelReady: true,
                                    isCoreRuntimeReady: false,
                                    isStartupInProgress: false,
                                    failure: StartupFailure(stage: .audioInput, detail: "no input device")),
            equals: SetupChecklistRowState(detail: "no input device",
                                           status: "Needs retry",
                                           buttonTitle: "Retry"),
            "setup checklist should offer retry for audio input failures"
        )
        try expect(
            audioInputSetupRowState(isSpeechModelReady: false,
                                    isCoreRuntimeReady: false,
                                    isStartupInProgress: true,
                                    failure: nil),
            equals: SetupChecklistRowState(detail: "Available after the speech model loads.",
                                           status: "Waiting",
                                           buttonTitle: nil),
            "setup checklist should not start audio before the speech model is ready"
        )
        try expect(
            hotkeySetupRowState(isReady: false,
                                hotkeyTestSucceeded: false,
                                triggerMode: .hold,
                                hotkeyName: "Right Option",
                                failure: StartupFailure(stage: .hotkeyListener, detail: "event tap failed")),
            equals: SetupChecklistRowState(detail: "event tap failed",
                                           status: "Needs retry",
                                           buttonTitle: "Retry"),
            "setup checklist should offer retry for hotkey listener failures"
        )
        try expect(
            hotkeySetupRowState(isReady: true,
                                hotkeyTestSucceeded: true,
                                triggerMode: .toggle,
                                hotkeyName: "F5",
                                failure: nil),
            equals: SetupChecklistRowState(detail: "Press F5 to dictate.",
                                           status: "Detected",
                                           buttonTitle: nil),
            "setup checklist should show detected hotkey state"
        )

        try expect(
            previousExitNoticeAction(previousRunWasActive: false),
            equals: .none,
            "clean previous exits should not show the abnormal-exit notice"
        )
        try expect(
            previousExitNoticeAction(previousRunWasActive: true),
            equals: .showNotice,
            "active run markers should show the abnormal-exit notice on next launch"
        )
        try expect(
            speechModelFailureDetail(errorDescription: "SHA-256 mismatch").contains("Reset Speech Model Cache"),
            equals: true,
            "speech model integrity failures should point to cache reset"
        )
        try expect(
            speechModelFailureDetail(errorDescription: "download timed out").contains("audio is not uploaded"),
            equals: true,
            "speech model download failures should preserve the local-audio privacy boundary"
        )
        try expect(
            speechModelFailureDetail(errorDescription: "Free some disk space, then retry loading the speech model."),
            equals: "Free some disk space, then retry loading the speech model.",
            "disk-space failures should not add unrelated reset-cache guidance"
        )
        try expect(
            startupFailureDetail(stage: .audioInput, errorDescription: "no input device"),
            equals: "no input device",
            "non-model startup failures should keep their original detail"
        )

        let coreAudioStopError = NSError(
            domain: "com.apple.coreaudio.avfaudio",
            code: 1_937_010_544,
            userInfo: ["failed call": "PerformCommand(*ioNode, kAUStartIO, NULL, 0)"]
        )
        let coreAudioErrorDescription = audioStartupErrorDescription(coreAudioStopError)
        try expect(
            coreAudioErrorDescription.contains("OSStatus 1937010544"),
            equals: true,
            "CoreAudio startup errors should include the decimal OSStatus"
        )
        try expect(
            coreAudioErrorDescription.contains("0x73746f70"),
            equals: true,
            "CoreAudio startup errors should include the hex OSStatus"
        )
        try expect(
            coreAudioErrorDescription.contains("'stop'"),
            equals: true,
            "CoreAudio startup errors should include printable four-character codes"
        )
        try expect(
            coreAudioErrorDescription.contains("PerformCommand(*ioNode, kAUStartIO, NULL, 0)"),
            equals: true,
            "CoreAudio startup errors should preserve the failed AVFAudio call"
        )
        try expect(
            startupFailureDetail(stage: .audioInput, error: coreAudioStopError).contains("restart CoreAudio"),
            equals: true,
            "exhausted CoreAudio startup failures should give OS recovery guidance"
        )
    }

    private static func testPasteSuffixFormatting() throws {
        try expect(
            pastedText(from: "hello world", suffix: .appendSpace),
            equals: "hello world ",
            "append-space suffix should preserve the existing default"
        )
        try expect(
            pastedText(from: "hello world", suffix: .none),
            equals: "hello world",
            "no suffix should paste corrected transcript unchanged"
        )
        try expect(
            pastedText(from: "hello world", suffix: .appendNewline),
            equals: "hello world\n",
            "append-newline suffix should add a single newline"
        )
        try expect(
            pastedText(from: "hello world ", suffix: .appendSpace),
            equals: "hello world  ",
            "suffix formatting should not trim or rewrite corrected text"
        )
        try expect(
            TextInserter.defaultStrategy,
            equals: .clipboardPaste,
            "clipboard paste should remain the default insertion strategy"
        )
        try expect(
            textInsertionStrategyChain(primary: .clipboardPaste),
            equals: [.clipboardPaste, .directUnicode],
            "clipboard paste should fall back to direct Unicode insertion"
        )
        try expect(
            textInsertionStrategyChain(primary: .directUnicode),
            equals: [.directUnicode],
            "direct Unicode insertion should not loop back to clipboard paste"
        )
        try expect(
            TextInserter.defaultStrategyDescription,
            equals: "Clipboard paste with Direct Unicode typing fallback",
            "diagnostics should describe the insertion fallback chain"
        )
        let unicodeChunks = unicodeInsertionChunks(for: "ab👩‍💻cd", maxUTF16UnitsPerEvent: 4)
            .map { String(decoding: $0, as: UTF16.self) }
        try expect(
            unicodeChunks,
            equals: ["ab", "👩‍💻", "cd"],
            "direct Unicode insertion should keep extended grapheme clusters together while chunking"
        )
        try expect(
            unicodeInsertionChunks(for: "abc", maxUTF16UnitsPerEvent: 0),
            equals: [],
            "direct Unicode chunking should reject invalid chunk sizes"
        )
        try expect(
            clipboardPasteKeyboardEventSteps(commandKey: 0x37, pasteKey: 0x09),
            equals: [
                KeyboardEventStep(virtualKey: 0x37, keyDown: true, flags: .maskCommand),
                KeyboardEventStep(virtualKey: 0x09, keyDown: true, flags: .maskCommand),
                KeyboardEventStep(virtualKey: 0x09, keyDown: false, flags: .maskCommand),
                KeyboardEventStep(virtualKey: 0x37, keyDown: false, flags: []),
            ],
            "clipboard paste should synthesize a full Command+V key sequence"
        )

        let pasteboardProbe = MainActor.assumeIsolated {
            let pasteboardName = NSPasteboard.Name("com.local.superdictate.self-test.\(UUID().uuidString)")
            let pasteboard = NSPasteboard(name: pasteboardName)
            let wrote = ClipboardPasteInserter.write("pasteboard probe", to: pasteboard)
            let snapshot = PasteboardSnapshot.capture(from: pasteboard)
            _ = ClipboardPasteInserter.write("temporary dictation", to: pasteboard)
            snapshot.restore(to: pasteboard)
            return (wrote: wrote, stored: pasteboard.string(forType: .string))
        }
        try expect(
            pasteboardProbe.wrote,
            equals: true,
            "clipboard paste should report pasteboard write success"
        )
        try expect(
            pasteboardProbe.stored,
            equals: "pasteboard probe",
            "clipboard paste should write the intended string before posting Cmd+V"
        )
    }

    // Covers the org.nspasteboard.TransientType marking added to mitigate
    // Universal Clipboard interference (docs/superpowers/specs/2026-08-20-
    // universal-clipboard-interference-design.md): a `transient: true`
    // write must carry the marker type without disturbing the readable
    // .string payload, and the default (non-transient) write — used by the
    // "save transcript after target disappeared" safety net and this
    // suite's own probe above — must never carry it.
    private static func testClipboardPasteInserterTransientMarking() throws {
        let probe = MainActor.assumeIsolated { () -> (transientTypes: [NSPasteboard.PasteboardType], transientString: String?, permanentTypes: [NSPasteboard.PasteboardType], permanentString: String?) in
            let pasteboardName = NSPasteboard.Name("com.local.superdictate.self-test.transient.\(UUID().uuidString)")
            let pasteboard = NSPasteboard(name: pasteboardName)

            _ = ClipboardPasteInserter.write("dictated text", to: pasteboard, transient: true)
            let transientTypes = pasteboard.pasteboardItems?.first?.types ?? []
            let transientString = pasteboard.string(forType: .string)

            _ = ClipboardPasteInserter.write("saved transcript", to: pasteboard)
            let permanentTypes = pasteboard.pasteboardItems?.first?.types ?? []
            let permanentString = pasteboard.string(forType: .string)

            return (transientTypes, transientString, permanentTypes, permanentString)
        }
        let markerType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

        try expect(
            probe.transientTypes.contains(markerType),
            equals: true,
            "a transient: true write should carry org.nspasteboard.TransientType"
        )
        try expect(
            probe.transientString,
            equals: "dictated text",
            "a transient: true write should still expose its text via the standard .string type"
        )
        try expect(
            probe.permanentTypes.contains(markerType),
            equals: false,
            "the default (non-transient) write must not carry org.nspasteboard.TransientType"
        )
        try expect(
            probe.permanentString,
            equals: "saved transcript",
            "the default (non-transient) write should still write the intended text"
        )
    }

    // Covers PasteConfirmationPoller.waitForPasteConfirmation's pure polling
    // logic with injected valueReaders, so this suite needs neither real AX
    // permission nor a real paste event.
    private static func testPasteConfirmationPoller() throws {
        // A plain captured `var` closure isn't convertible to
        // waitForPasteConfirmation's `@Sendable` valueReader parameter
        // (verified with a real Swift 6 compiler in a Docker
        // swift:6.0-jammy container: "converting non-sendable function
        // value to '@Sendable () -> String?' may introduce data races").
        // A reference-type counter sidesteps that, same pattern as
        // RestoreTestState below.
        final class CallCountBox: @unchecked Sendable {
            var count = 0
        }
        let callCountBox = CallCountBox()
        let values = ["", "старое ", "старое текст"]
        let appearsEventually: @Sendable () -> String? = {
            defer { callCountBox.count += 1 }
            let callCount = callCountBox.count
            return callCount < values.count ? values[callCount] : values.last
        }
        let confirmedWhenAppears = PasteConfirmationPoller.waitForPasteConfirmation(
            expectedSubstring: "текст",
            baselineValue: "",
            pollInterval: 0.001,
            timeout: 1.0,
            valueReader: appearsEventually
        )
        try expect(confirmedWhenAppears, equals: true,
                   "poller should confirm as soon as the expected substring appears")
        try expect(callCountBox.count < values.count + 1, equals: true,
                   "poller should stop polling once confirmed instead of running to the timeout")

        let confirmedOnTimeout = PasteConfirmationPoller.waitForPasteConfirmation(
            expectedSubstring: "текст",
            baselineValue: nil,
            pollInterval: 0.005,
            timeout: 0.05,
            valueReader: { "unrelated value" }
        )
        try expect(confirmedOnTimeout, equals: false,
                   "poller should give up and report false once the timeout elapses")

        let confirmedWithNilReader = PasteConfirmationPoller.waitForPasteConfirmation(
            expectedSubstring: "текст",
            baselineValue: nil,
            pollInterval: 0.005,
            timeout: 0.05,
            valueReader: { nil }
        )
        try expect(confirmedWithNilReader, equals: false,
                   "poller should treat a reader that always returns nil as never-confirmed")

        let confirmedWithEmptyExpectation = PasteConfirmationPoller.waitForPasteConfirmation(
            expectedSubstring: "",
            baselineValue: nil,
            pollInterval: 0.005,
            timeout: 0.05,
            valueReader: { nil }
        )
        try expect(confirmedWithEmptyExpectation, equals: true,
                   "an empty expected substring should confirm immediately without polling")

        // Regression test for the premature-restore race: a field that
        // ALREADY contains the expected substring before this paste's poll
        // even starts (e.g. dictating the same short phrase twice into the
        // same field) must not confirm on tick one just because
        // `contains(expectedSubstring)` is trivially true against the
        // pre-existing baseline -- it must wait for the value to actually
        // change away from that baseline.
        final class ChangeAfterFewTicksBox: @unchecked Sendable {
            var tick = 0
        }
        let changeBox = ChangeAfterFewTicksBox()
        let alreadyContainsSubstringThenChanges: @Sendable () -> String? = {
            defer { changeBox.tick += 1 }
            // First several ticks report the exact same value as the
            // baseline (which already contains "текст"); only later does it
            // change to reflect the new paste actually landing.
            return changeBox.tick < 3 ? "старый текст" : "новый текст"
        }
        let confirmedOnlyAfterValueChangesFromBaseline = PasteConfirmationPoller.waitForPasteConfirmation(
            expectedSubstring: "текст",
            baselineValue: "старый текст",
            pollInterval: 0.001,
            timeout: 1.0,
            valueReader: alreadyContainsSubstringThenChanges
        )
        try expect(confirmedOnlyAfterValueChangesFromBaseline, equals: true,
                   "poller should eventually confirm once the value changes away from the baseline")
        try expect(changeBox.tick > 3, equals: true,
                   "poller must not confirm on tick one just because the pre-existing baseline already contains the expected substring")

        let neverConfirmsIfValueNeverChangesFromBaseline = PasteConfirmationPoller.waitForPasteConfirmation(
            expectedSubstring: "текст",
            baselineValue: "старый текст",
            pollInterval: 0.005,
            timeout: 0.05,
            valueReader: { "старый текст" }
        )
        try expect(neverConfirmsIfValueNeverChangesFromBaseline, equals: false,
                   "poller must not confirm against a value that's identical to the pre-paste baseline, even though it contains the expected substring")

        // Regression test for the early-bailout-on-unreadable-value fix: an
        // app whose AX tree never exposes a readable value at all must not
        // burn the full `timeout` -- it should give up around
        // `unreadableValueBailout` instead.
        let bailoutStart = Date()
        let neverReadable = PasteConfirmationPoller.waitForPasteConfirmation(
            expectedSubstring: "текст",
            baselineValue: nil,
            pollInterval: 0.005,
            timeout: 5.0,
            unreadableValueBailout: 0.05,
            valueReader: { nil }
        )
        let bailoutElapsed = Date().timeIntervalSince(bailoutStart)
        try expect(neverReadable, equals: false,
                   "poller should report false when the value is never readable at all")
        try expect(bailoutElapsed < 1.0, equals: true,
                   "poller should give up around unreadableValueBailout (0.05s) rather than waiting the full 5.0s timeout when the value is never readable")

        // Once at least one readable (even if non-matching) value has been
        // observed, the early unreadable-value bailout must no longer apply
        // -- the target clearly CAN expose a value, so the full timeout
        // should still be honored while waiting for it to change.
        final class ReadableThenNilBox: @unchecked Sendable {
            var tick = 0
        }
        let readableThenNilBox = ReadableThenNilBox()
        let readableOnceThenNil: @Sendable () -> String? = {
            defer { readableThenNilBox.tick += 1 }
            return readableThenNilBox.tick == 0 ? "unrelated value" : nil
        }
        let stillWaitsFullTimeoutAfterOneReadableValue = PasteConfirmationPoller.waitForPasteConfirmation(
            expectedSubstring: "текст",
            baselineValue: nil,
            pollInterval: 0.01,
            timeout: 0.08,
            unreadableValueBailout: 0.02,
            valueReader: readableOnceThenNil
        )
        try expect(stillWaitsFullTimeoutAfterOneReadableValue, equals: false,
                   "poller should still report false (never matched) once its own timeout elapses")
        try expect(readableThenNilBox.tick > 3, equals: true,
                   "once a readable value has been seen even once, the unreadable-value early bailout must not cut the wait short")
    }

    // Covers ClipboardPasteInserter's real (fileprivate, not module-public)
    // `restorePasteboard` directly -- not a hand-duplicated copy of its
    // guard logic -- with an injected `confirm` closure standing in for
    // PasteConfirmationPoller, so this needs neither real Accessibility
    // permission nor a real paste event. Calling the production function
    // itself means a later edit to its guard (e.g. dropping the changeCount
    // check) will actually break this suite, instead of silently keeping a
    // separately-maintained copy green.
    // NOTE: this deliberately does NOT use a blocking DispatchSemaphore.wait()
    // to wait for `completion`, unlike this file's other self-test semaphore
    // bridges (e.g. runParakeetEngineSynchronously above). Those signal from
    // work dispatched off the main thread; restorePasteboard's completion is
    // delivered via DispatchQueue.main.async, which cannot run while the main
    // thread (where this self-test itself executes) is blocked inside a
    // synchronous semaphore.wait() — that would deadlock. Pumping the run
    // loop instead lets the pending main-queue block execute.
    private static func waitUntilMainQueueCallback(timeout: TimeInterval, isDone: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !isDone(), Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private static func testClipboardPasteInserterRestore() throws {
        final class RestoreTestState: @unchecked Sendable {
            var done = false
            var confirmWasCalledWithExpectedText: String?
        }

        // Shared setup mirroring exactly what ClipboardPasteInserter.insert(_:)
        // does before calling restorePasteboard: snapshot the "previous"
        // clipboard contents, then write the dictated text as the transient
        // clipboard payload.
        @MainActor
        func setUpTransientPaste(previousText: String, dictatedText: String, on pasteboard: NSPasteboard) -> (snapshot: PasteboardSnapshot, changeCount: Int) {
            pasteboard.clearContents()
            _ = pasteboard.setString(previousText, forType: .string)
            let snapshot = PasteboardSnapshot.capture(from: pasteboard)
            pasteboard.clearContents()
            _ = pasteboard.setString(dictatedText, forType: .string)
            return (snapshot, pasteboard.changeCount)
        }

        let restoresAfterConfirmSucceeds = MainActor.assumeIsolated { () -> (calledWith: String?, restored: String?) in
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            let (snapshot, changeCount) = setUpTransientPaste(previousText: "previous clipboard content",
                                                              dictatedText: "dictated text",
                                                              on: pasteboard)

            let state = RestoreTestState()

            ClipboardPasteInserter.restorePasteboard(
                snapshot,
                ifStillTemporaryText: "dictated text",
                changeCount: changeCount,
                pasteboard: pasteboard,
                valueReader: { nil },
                confirm: { expectedSubstring, _, _, _, _, _ in
                    state.confirmWasCalledWithExpectedText = expectedSubstring
                    return true
                }
            ) {
                state.done = true
            }

            waitUntilMainQueueCallback(timeout: 1.0) { state.done }
            return (state.confirmWasCalledWithExpectedText, pasteboard.string(forType: .string))
        }
        try expect(restoresAfterConfirmSucceeds.calledWith, equals: "dictated text",
                   "restore should confirm against the dictated text that was actually pasted")
        try expect(restoresAfterConfirmSucceeds.restored, equals: "previous clipboard content",
                   "restore should put the user's previous clipboard content back once confirmed")

        let restoresAfterConfirmTimesOut = MainActor.assumeIsolated { () -> String? in
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            let (snapshot, changeCount) = setUpTransientPaste(previousText: "previous clipboard content",
                                                              dictatedText: "dictated text",
                                                              on: pasteboard)

            let state = RestoreTestState()

            ClipboardPasteInserter.restorePasteboard(
                snapshot,
                ifStillTemporaryText: "dictated text",
                changeCount: changeCount,
                pasteboard: pasteboard,
                valueReader: { nil },
                confirm: { _, _, _, _, _, _ in false }
            ) {
                state.done = true
            }

            waitUntilMainQueueCallback(timeout: 1.0) { state.done }
            return pasteboard.string(forType: .string)
        }
        try expect(restoresAfterConfirmTimesOut, equals: "previous clipboard content",
                   "restore should still happen even when confirmation times out, rather than losing the user's clipboard forever")

        // Safety-critical case: if the pasteboard changes out from under the
        // restore WHILE confirmation is still pending (e.g. the user copied
        // something else in the meantime), the restore must be skipped --
        // not clobber the newer clipboard contents back to the stale
        // pre-paste snapshot. Both prior tests above leave the pasteboard
        // untouched between dispatch and restore, so the
        // `pasteboard.changeCount == changeCount` guard was never actually
        // proven to skip a restore; this test forces that guard to fire for
        // real by mutating the pasteboard from inside `confirm`, before it
        // returns.
        let skipsRestoreIfPasteboardChangedDuringPoll = MainActor.assumeIsolated { () -> String? in
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            let (snapshot, changeCount) = setUpTransientPaste(previousText: "previous clipboard content",
                                                              dictatedText: "dictated text",
                                                              on: pasteboard)

            let state = RestoreTestState()

            ClipboardPasteInserter.restorePasteboard(
                snapshot,
                ifStillTemporaryText: "dictated text",
                changeCount: changeCount,
                pasteboard: pasteboard,
                valueReader: { nil },
                confirm: { _, _, _, _, _, _ in
                    // Simulate the user copying something else while the
                    // poll is still pending. `confirm` runs on the
                    // background queue (see restorePasteboard above), so
                    // this hops to the main queue to perform the mutation
                    // — actual pasteboard touches stay confined to main,
                    // matching this file's NSPasteboard: Sendable
                    // conformance comment — and blocks until it's done, so
                    // the mutation is guaranteed to land before `confirm`
                    // returns and restorePasteboard's own main-queue guard
                    // runs.
                    DispatchQueue.main.sync {
                        pasteboard.clearContents()
                        _ = pasteboard.setString("something else the user copied", forType: .string)
                    }
                    return true
                }
            ) {
                state.done = true
            }

            waitUntilMainQueueCallback(timeout: 1.0) { state.done }
            return pasteboard.string(forType: .string)
        }
        try expect(skipsRestoreIfPasteboardChangedDuringPoll, equals: "something else the user copied",
                   "restore must be skipped (not clobber newer clipboard contents back to the stale snapshot) if the pasteboard changed while confirmation was still pending")
    }

    private static func testRecentTranscriptLimit() throws {
        let transcripts = ["newest", "second", "third", "fourth", "fifth", "sixth"]

        try expect(
            limitedRecentTranscripts(transcripts, limit: .off),
            equals: [],
            "off should keep no recent transcripts"
        )
        try expect(
            limitedRecentTranscripts(transcripts, limit: .last1),
            equals: ["newest"],
            "last-one history should keep only the newest transcript"
        )
        try expect(
            limitedRecentTranscripts(transcripts, limit: .last5),
            equals: ["newest", "second", "third", "fourth", "fifth"],
            "last-five history should preserve the current default cap"
        )
        try expect(
            parseRecentTranscriptLimit(storedValue: NSNumber(value: 1)),
            equals: .last1,
            "numeric defaults writes should be accepted for last-one history"
        )

        let timedEntries = transcripts.enumerated().map { index, text in
            TranscriptHistoryEntry(
                text: text,
                transcriptionDurationSeconds: Double(index + 1) / 10
            )
        }
        try expect(
            limitedRecentTranscriptEntries(timedEntries, limit: .last1),
            equals: [TranscriptHistoryEntry(text: "newest", transcriptionDurationSeconds: 0.1)],
            "history trimming should preserve transcription timing metadata"
        )

        let archivedEntries = limitedTranscriptHistoryArchive(timedEntries, maximumCount: 6)
        try expect(
            archivedEntries.count,
            equals: 6,
            "the archive should retain entries beyond the visible history limit"
        )
        let archiveAfterDeletion = transcriptHistoryArchive(archivedEntries, removing: 2)
        try expect(
            limitedRecentTranscriptEntries(archiveAfterDeletion, limit: .last5).map(\.text),
            equals: ["newest", "second", "fourth", "fifth", "sixth"],
            "deleting a visible history entry should backfill it from the archive"
        )
        try expect(
            transcriptHistoryArchive(archivedEntries, removing: 99),
            equals: archivedEntries,
            "an invalid history deletion index should leave the archive unchanged"
        )

        let historyRowHitTargets = MainActor.assumeIsolated { () -> (delete: Bool, row: Bool, deleteAction: Bool, copyAction: Bool) in
            let row = HistoryTranscriptItemView(
                transcript: "test",
                preview: "test",
                transcriptionDurationSeconds: 0.1,
                asrTiming: nil,
                historyIndex: 0,
                target: nil,
                action: NSSelectorFromString("noop:"),
                onDelete: { _ in }
            )
            row.frame = NSRect(x: 0, y: 0, width: 600, height: 56)
            guard let deleteButton = row.subviews.compactMap({ $0 as? HistoryDeleteButton }).first else {
                return (false, false, false, false)
            }
            deleteButton.frame = NSRect(x: 560, y: 14, width: 28, height: 28)
            let deleteAction: Bool
            if case .delete(0) = row.hitAction(atWindowPoint: NSPoint(x: 574, y: 28)) {
                deleteAction = true
            } else {
                deleteAction = false
            }
            let copyAction: Bool
            if case .copy("test") = row.hitAction(atWindowPoint: NSPoint(x: 200, y: 28)) {
                copyAction = true
            } else {
                copyAction = false
            }
            return (
                row.hitTest(NSPoint(x: 574, y: 28)) === row,
                row.hitTest(NSPoint(x: 200, y: 28)) === row,
                deleteAction,
                copyAction
            )
        }
        try expect(
            historyRowHitTargets.delete,
            equals: true,
            "history rows should own delete-zone clicks"
        )
        try expect(
            historyRowHitTargets.row,
            equals: true,
            "history rows should keep transcript clicks on the copy action"
        )
        try expect(
            historyRowHitTargets.deleteAction,
            equals: true,
            "history delete zones should resolve to deletion"
        )
        try expect(
            historyRowHitTargets.copyAction,
            equals: true,
            "history transcript bodies should resolve to clipboard copy"
        )
        try expect(
            transcriptionDurationLabel(0.1234),
            equals: "0.123 s",
            "history timing should be displayed in seconds with millisecond precision"
        )
        try expect(
            transcriptionDurationLabel(nil),
            equals: "\u{2014}",
            "legacy history entries should not invent transcription timing"
        )

        let timing = ASRTimingBreakdown(
            totalSeconds: 0.295,
            workerQueueSeconds: 0.001,
            decoderPreparationSeconds: 0.002,
            engineCallSeconds: 0.290,
            engineProcessingSeconds: 0.286
        )
        let entriesWithBreakdown = [
            TranscriptHistoryEntry(
                text: "timed",
                transcriptionDurationSeconds: timing.totalSeconds,
                asrTiming: timing
            )
        ]
        let encodedEntries = try JSONEncoder().encode(entriesWithBreakdown)
        try expect(
            try JSONDecoder().decode([TranscriptHistoryEntry].self, from: encodedEntries),
            equals: entriesWithBreakdown,
            "history timing metadata should survive persistence"
        )
        try expect(
            asrTimingTooltip(timing)?.contains("parakeet.cpp  286.0 ms"),
            equals: true,
            "history timing tooltip should expose the parakeet.cpp engine's own processing time"
        )

        let legacyEntryData = Data(
            #"[{"text":"legacy","transcriptionDurationSeconds":0.25}]"#.utf8
        )
        try expect(
            try JSONDecoder().decode([TranscriptHistoryEntry].self, from: legacyEntryData),
            equals: [TranscriptHistoryEntry(text: "legacy", transcriptionDurationSeconds: 0.25)],
            "history entries saved before detailed metrics should remain decodable"
        )

        let metricLine = DictationLatencyMetrics(
            audioSeconds: 2,
            hotkeyDispatchSeconds: 0.0005,
            releasePreparationSeconds: 0.001,
            settingsRefreshSeconds: 0.0002,
            releasePermissionCheckSeconds: 0.0003,
            audioFinalizeSeconds: 0.002,
            audioDetachSeconds: 0.0001,
            journalFlushSeconds: 0.0015,
            audioFlattenSeconds: 0.0004,
            transcribingUISeconds: 0.003,
            taskQueueSeconds: 0.004,
            releaseToASRSeconds: 0.010,
            asrTiming: timing,
            postprocessingSeconds: 0.005,
            historyPersistenceSeconds: 0.006,
            journalCleanupSeconds: 0.007,
            permissionRecheckSeconds: 0.008,
            insertionDispatchSeconds: 0.009,
            releaseToPasteDispatchSeconds: 0.330,
            enterDelaySeconds: nil,
            pasteSucceeded: true
        ).logLine
        try expect(
            metricLine.contains("hotkey_dispatch=0.5 ms")
                && metricLine.contains("journal_flush=1.5 ms")
                && metricLine.contains("engine_processing=286.0 ms")
                && metricLine.contains("release_to_paste=330.0 ms")
                && metricLine.contains("paste=ok"),
            equals: true,
            "latency log should expose model, end-to-end, and insertion outcomes"
        )
    }

    private static func testRecordingHUDDisplayMode() throws {
        let defaults = UserDefaults.standard
        let key = "recording_hud_display_mode"
        let previousRaw = defaults.string(forKey: key)
        defer {
            if let previousRaw {
                defaults.set(previousRaw, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        let settings = Settings.shared
        guard settings.recordingHUDDisplayMode == .levelBars else {
            throw SelfTestFailure.failed("expected default .levelBars, got \(settings.recordingHUDDisplayMode)")
        }

        settings.recordingHUDDisplayMode = .timerOutline
        guard settings.recordingHUDDisplayMode == .timerOutline else {
            throw SelfTestFailure.failed("expected .timerOutline after set, got \(settings.recordingHUDDisplayMode)")
        }

        defaults.set("not-a-real-mode", forKey: key)
        guard settings.recordingHUDDisplayMode == .levelBars else {
            throw SelfTestFailure.failed("expected fallback to .levelBars for garbage stored value")
        }
    }

    private static func testFormatRecordingHUDElapsed() throws {
        let cases: [(TimeInterval, String)] = [
            (0, "00:00"),
            (9, "00:09"),
            (9.9, "00:09"),
            (10, "00:10"),
            (59, "00:59"),
            (60, "01:00"),
            (65, "01:05"),
            (599, "09:59"),
            (600, "10:00"),
            (3661, "61:01"),
        ]
        for (input, expected) in cases {
            let actual = formatRecordingHUDElapsed(input)
            guard actual == expected else {
                throw SelfTestFailure.failed("formatRecordingHUDElapsed(\(input)) = \(actual), expected \(expected)")
            }
        }
    }

    /// `recordingHUDOutlineFillPath` is pure geometry — exercise it directly
    /// without instantiating a window, per the final-review finding that both
    /// Critical geometry bugs (chord across the bubble, missing top edge)
    /// were self-test-catchable this way.
    private static func testRecordingHUDOutlineFillPath() throws {
        let capsuleRect = NSRect(x: 0, y: 0, width: 72, height: 26)
        let bottomCenter = NSPoint(x: capsuleRect.midX, y: capsuleRect.maxY)
        let topCenter = NSPoint(x: capsuleRect.midX, y: capsuleRect.minY)
        let tolerance: CGFloat = 0.5

        func subpaths(_ path: NSBezierPath) -> [[NSPoint]] {
            var result: [[NSPoint]] = []
            var current: [NSPoint] = []
            var associated = [NSPoint](repeating: .zero, count: 3)
            for i in 0..<path.elementCount {
                let type = path.element(at: i, associatedPoints: &associated)
                switch type {
                case .moveTo:
                    if !current.isEmpty { result.append(current) }
                    current = [associated[0]]
                case .lineTo:
                    current.append(associated[0])
                case .curveTo:
                    current.append(contentsOf: associated[0..<3])
                default:
                    break
                }
            }
            if !current.isEmpty { result.append(current) }
            return result
        }

        func allPoints(_ path: NSBezierPath) -> [NSPoint] {
            subpaths(path).flatMap { $0 }
        }

        func approxLength(_ path: NSBezierPath) -> CGFloat {
            let points = allPoints(path)
            guard points.count > 1 else { return 0 }
            var total: CGFloat = 0
            for i in 1..<points.count {
                let dx = points[i].x - points[i - 1].x
                let dy = points[i].y - points[i - 1].y
                total += (dx * dx + dy * dy).squareRoot()
            }
            return total
        }

        func near(_ a: NSPoint, _ b: NSPoint, _ tol: CGFloat = tolerance) -> Bool {
            abs(a.x - b.x) < tol && abs(a.y - b.y) < tol
        }

        // fraction = 0: degenerate (caller already gates on level > 0.001
        // before calling this), but must still produce a valid path that
        // starts at bottom-center.
        let zeroPath = recordingHUDOutlineFillPath(in: capsuleRect, fraction: 0)
        guard let zeroFirst = allPoints(zeroPath).first, near(zeroFirst, bottomCenter) else {
            throw SelfTestFailure.failed("fraction=0 path should start at bottom-center \(bottomCenter)")
        }

        // Every element's associated points stay within the capsule rect
        // (small tolerance for floating point) at a spread of fractions.
        let containment = capsuleRect.insetBy(dx: -tolerance, dy: -tolerance)
        for fraction: CGFloat in [0, 0.25, 0.5, 0.75, 0.999] {
            let path = recordingHUDOutlineFillPath(in: capsuleRect, fraction: fraction)
            for point in allPoints(path) {
                guard containment.contains(point) else {
                    throw SelfTestFailure.failed("fraction=\(fraction) produced point \(point) outside \(capsuleRect)")
                }
                guard point.x.isFinite, point.y.isFinite else {
                    throw SelfTestFailure.failed("fraction=\(fraction) produced a non-finite point")
                }
            }
            // Bottom-center is always the start point of both side subpaths.
            for side in subpaths(path) {
                guard let first = side.first, near(first, bottomCenter) else {
                    throw SelfTestFailure.failed("fraction=\(fraction) subpath should start at bottom-center, got \(side.first.map(String.init(describing:)) ?? "nil")")
                }
            }
        }

        // fraction = 0.5 is analytically exact for this rect (radius 13,
        // straightLength 46): the lit length lands exactly at the arc's
        // horizontal midpoint on each side. This is the one check that pins
        // down the arc's sweep direction -- containment alone would pass
        // even if the arc swept the wrong way, since a <=180 degree arc
        // about the cap center stays inside capsuleRect regardless.
        let halfPath = recordingHUDOutlineFillPath(in: capsuleRect, fraction: 0.5)
        let halfSides = subpaths(halfPath)
        guard halfSides.count == 2 else {
            throw SelfTestFailure.failed("fraction=0.5 path should have two side subpaths, got \(halfSides.count)")
        }
        let leftEnd = halfSides[0].last!
        let rightEnd = halfSides[1].last!
        let expectedLeft = NSPoint(x: capsuleRect.minX, y: capsuleRect.midY)
        let expectedRight = NSPoint(x: capsuleRect.maxX, y: capsuleRect.midY)
        guard near(leftEnd, expectedLeft) else {
            throw SelfTestFailure.failed("fraction=0.5 left side should end at \(expectedLeft), got \(leftEnd)")
        }
        guard near(rightEnd, expectedRight) else {
            throw SelfTestFailure.failed("fraction=0.5 right side should end at \(expectedRight), got \(rightEnd)")
        }

        // fraction = 0.999: both sides should have traversed the bottom
        // straight run, the full arc, and nearly all of the top straight run
        // -- i.e. nearly reached top-center. This is the check that catches
        // a halfPerimeter that omits the top edge (Critical 2): with the bug
        // present, the arc end point (not top-center) would be the ceiling
        // any fraction below 1.0 could reach.
        let almostFullPath = recordingHUDOutlineFillPath(in: capsuleRect, fraction: 0.999)
        let almostFullSides = subpaths(almostFullPath)
        guard almostFullSides.count == 2 else {
            throw SelfTestFailure.failed("fraction=0.999 path should have two side subpaths, got \(almostFullSides.count)")
        }
        for side in almostFullSides {
            guard let end = side.last, near(end, topCenter, 1.0) else {
                throw SelfTestFailure.failed("fraction=0.999 side should nearly reach top-center \(topCenter), got \(side.last.map(String.init(describing:)) ?? "nil")")
            }
        }

        // fraction = 1.0 should equal the full capsule outline (bounds match).
        let fullPath = recordingHUDOutlineFillPath(in: capsuleRect, fraction: 1.0)
        let fullBounds = fullPath.bounds
        guard abs(fullBounds.minX - capsuleRect.minX) < tolerance,
              abs(fullBounds.minY - capsuleRect.minY) < tolerance,
              abs(fullBounds.maxX - capsuleRect.maxX) < tolerance,
              abs(fullBounds.maxY - capsuleRect.maxY) < tolerance else {
            throw SelfTestFailure.failed("fraction=1.0 path bounds \(fullBounds) should match capsuleRect \(capsuleRect)")
        }

        // Traversed length should increase monotonically with fraction.
        let fractions: [CGFloat] = [0, 0.25, 0.5, 0.75, 0.999]
        var previousLength: CGFloat = -1
        for fraction in fractions {
            let length = approxLength(recordingHUDOutlineFillPath(in: capsuleRect, fraction: fraction))
            guard length >= previousLength else {
                throw SelfTestFailure.failed("traversed length should increase monotonically with fraction, regressed at \(fraction)")
            }
            previousLength = length
        }

        // A perfect circle (width == height, straightLength == 0) should not
        // divide by zero or produce NaNs.
        let circleRect = NSRect(x: 0, y: 0, width: 26, height: 26)
        for fraction: CGFloat in [0, 0.5, 0.999, 1.0] {
            let path = recordingHUDOutlineFillPath(in: circleRect, fraction: fraction)
            for point in allPoints(path) {
                guard point.x.isFinite, point.y.isFinite else {
                    throw SelfTestFailure.failed("circle case fraction=\(fraction) produced a non-finite point")
                }
            }
        }
    }

    private static func testDictationUsageStatistics() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = calendar.date(from: DateComponents(year: 2026, month: 7, day: 18, hour: 12))!
        let july10 = calendar.date(from: DateComponents(year: 2026, month: 7, day: 10, hour: 10))!
        let july11 = calendar.date(from: DateComponents(year: 2026, month: 7, day: 11, hour: 10))!
        let july17 = calendar.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 10))!
        let july18 = calendar.date(from: DateComponents(year: 2026, month: 7, day: 18, hour: 10))!

        var stats: [DailyDictationUsage] = []
        stats = addingDictationUsageSample(to: stats,
                                           at: july10,
                                           characterCount: 40,
                                           audioSeconds: 4,
                                           asrSeconds: 0.4,
                                           calendar: calendar)
        stats = addingDictationUsageSample(to: stats,
                                           at: july11,
                                           characterCount: 100,
                                           audioSeconds: 10,
                                           asrSeconds: 0.5,
                                           calendar: calendar)
        stats = addingDictationUsageSample(to: stats,
                                           at: july17,
                                           characterCount: 300,
                                           audioSeconds: 30,
                                           asrSeconds: 0.75,
                                           calendar: calendar)
        stats = addingDictationUsageSample(to: stats,
                                           at: july18,
                                           characterCount: 900,
                                           audioSeconds: 90,
                                           asrSeconds: 1.2,
                                           calendar: calendar)

        let snapshot = lastSevenCompletedDictationUsage(stats,
                                                         referenceDate: reference,
                                                         calendar: calendar)
        try expect(snapshot.days.count, equals: 7,
                   "statistics should always contain seven completed calendar days")
        try expect(snapshot.days.first?.usage.day, equals: "2026-07-11",
                   "statistics should begin seven days before today")
        try expect(snapshot.days.last?.usage.day, equals: "2026-07-17",
                   "statistics should end yesterday")
        try expect(snapshot.totalCharacters, equals: 400,
                   "statistics should exclude both older data and today's dictations")
        try expect(snapshot.totalDictations, equals: 2,
                   "statistics should aggregate completed dictations")
        try expect(snapshot.totalAudioSeconds, equals: 40,
                   "statistics should aggregate recorded audio duration")
        try expect(snapshot.totalASRSeconds, equals: 1.25,
                   "statistics should aggregate ASR duration")

        let log = """
        [23:59:58] 2.00 s audio → 0.20 s → 20 chars
        [00:00:01] HotkeyListener: tap active
        [00:00:02] 3.00 s audio → 0.30 s → 30 chars
        [00:00:03] 1.00 s audio → 0.10 s → 0 chars
        """
        let imported = importedDailyDictationUsage(
            from: log,
            fileCreatedAt: calendar.date(from: DateComponents(year: 2026, month: 7, day: 3))!,
            calendar: calendar
        )
        try expect(imported.count, equals: 2,
                   "log import should infer a new day when timestamps cross midnight")
        try expect(imported.first?.characterCount, equals: 20,
                   "log import should preserve the first day's characters")
        try expect(imported.last?.characterCount, equals: 30,
                   "log import should ignore empty transcripts")
    }

    private static func testAudioLevelMetering() throws {
        var accumulator = AudioSampleAccumulator()
        accumulator.append([])
        accumulator.append([1, 2])
        accumulator.append([3, 4, 5])
        try expect(
            accumulator.sampleCount,
            equals: 5,
            "segmented audio accumulator should track total sample count"
        )
        let captured = accumulator.drain()
        try expect(
            accumulator.sampleCount,
            equals: 0,
            "segmented audio accumulator should reset after drain"
        )
        try expect(
            captured.flattened(),
            equals: [1, 2, 3, 4, 5],
            "segmented audio accumulator should preserve sample order when flattened"
        )

        try expect(
            normalizedAudioLevel(from: Array(repeating: 0, count: 128)),
            equals: 0,
            "silence should map to zero recording level"
        )

        let lowVoice = normalizedAudioLevel(from: Array(repeating: 0.004, count: 128))
        let quiet = normalizedAudioLevel(from: Array(repeating: 0.01, count: 128))
        let normal = normalizedAudioLevel(from: Array(repeating: 0.12, count: 128))
        let loud = normalizedAudioLevel(from: Array(repeating: 4.0, count: 128))

        guard lowVoice > 0 else {
            throw SelfTestFailure.failed("low close-mic voice should rise above the visual gate")
        }
        guard quiet > 0 else {
            throw SelfTestFailure.failed("quiet speech-like input should rise above zero")
        }
        guard normal > quiet else {
            throw SelfTestFailure.failed("higher RMS should produce a higher visual level")
        }
        try expect(
            loud,
            equals: 1,
            "out-of-range samples should clamp to maximum visual level"
        )

        try expect(
            normalizedAudioLevel(from: [.nan, .infinity, -.infinity]),
            equals: 0,
            "non-finite samples should not produce a visible level"
        )
        try expect(
            visibleRecordingLevel(rawLevel: .nan),
            equals: 0,
            "visible recording level should ignore non-finite input"
        )
        try expect(
            visibleRecordingLevel(rawLevel: 0.8),
            equals: 0.8,
            "visible recording level should pass through normal input immediately"
        )
        try expect(
            visibleRecordingLevel(rawLevel: 1.2),
            equals: 1,
            "visible recording level should clamp high input"
        )

        let idlePhaseSpeed = recordingHUDPhaseSpeed(mode: .recording, level: 0)
        let voicePhaseSpeed = recordingHUDPhaseSpeed(mode: .recording, level: 0.8)
        guard voicePhaseSpeed > idlePhaseSpeed else {
            throw SelfTestFailure.failed("voice should visibly accelerate the recording waveform")
        }
        try expect(
            recordingHUDPhaseSpeed(mode: .transcribing, level: 1),
            equals: RECORDING_HUD_TRANSCRIBING_PHASE_SPEED,
            "transcribing animation speed should not depend on stale microphone level"
        )
        try expect(
            recordingHUDPhaseSpeed(mode: .error, level: 0),
            equals: 0,
            "error HUD should be static (zero phase speed)"
        )
    }

    private static func testAudioConversion() throws {
        guard let stereoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: 48_000,
                                               channels: 2,
                                               interleaved: false),
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 48_000,
                                             channels: 1,
                                             interleaved: false),
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: 16_000,
                                               channels: 1,
                                               interleaved: false),
              let stereo = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: 480),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 480),
              let stereoChannels = stereo.floatChannelData,
              let monoChannel = mono.floatChannelData?[0] else {
            throw SelfTestFailure.failed("could not create audio conversion test buffers")
        }
        stereo.frameLength = 480
        for i in 0..<480 {
            stereoChannels[0][i] = 0.5
            stereoChannels[1][i] = 0.02
        }

        let rms = channelRMSValues(channels: stereoChannels, channelCount: 2, frameCount: 480)
        try expect(
            selectedMonoMixChannelIndices(channelRMS: rms),
            equals: [0],
            "manual mono mix should select the active close-mic channel when another channel is near-silent"
        )
        writeMonoMix(channels: stereoChannels,
                     selectedChannels: selectedMonoMixChannelIndices(channelRMS: rms),
                     frameCount: 480,
                     to: monoChannel)
        mono.frameLength = 480
        try expect(
            monoChannel[0],
            equals: 0.5,
            "manual mono mix should preserve the selected active channel"
        )

        for i in 0..<480 {
            stereoChannels[0][i] = 0.5
            stereoChannels[1][i] = -0.5
        }
        let balancedRMS = channelRMSValues(channels: stereoChannels, channelCount: 2, frameCount: 480)
        try expect(
            selectedMonoMixChannelIndices(channelRMS: balancedRMS),
            equals: [0, 1],
            "manual mono mix should average multiple similarly active channels"
        )
        writeMonoMix(channels: stereoChannels,
                     selectedChannels: selectedMonoMixChannelIndices(channelRMS: balancedRMS),
                     frameCount: 480,
                     to: monoChannel)
        try expect(
            monoChannel[0],
            equals: 0,
            "manual mono mix should average selected channels with equal weight"
        )

        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 320),
              let converter = AVAudioConverter(from: monoFormat, to: targetFormat) else {
            throw SelfTestFailure.failed("could not create audio converter")
        }
        var error: NSError?
        let inputProvider = AudioConverterInputProvider(buffer: mono)
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            inputProvider.provide(outStatus: outStatus)
        }
        if status == .error {
            throw SelfTestFailure.failed("audio conversion failed: \(error?.localizedDescription ?? "?")")
        }
        guard converted.format.channelCount == 1,
              Int(converted.format.sampleRate) == 16_000,
              converted.frameLength > 0 else {
            throw SelfTestFailure.failed("audio conversion should produce 16 kHz mono samples")
        }
    }

    private static func testTranscriptCorrections() throws {
        try expect(
            correctionSourcePrefill(from: "  first line\n\nsecond\tline  "),
            equals: "first line second line",
            "correction source prefill should collapse transcript whitespace"
        )
        try expect(
            correctionSourcePrefill(from: String(repeating: "a", count: MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES + 4)).utf8.count,
            equals: MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES,
            "correction source prefill should stay inside correction source byte limits"
        )
        try expect(
            correctionSourcePrefill(from: String(repeating: "é", count: MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES)).utf8.count,
            equals: MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES,
            "correction source prefill should clip at character boundaries"
        )

        let normalized = normalizedTranscriptCorrections([
            TranscriptCorrection(source: "  Yeti   Nano  ", replacement: "  Blue mic  "),
            TranscriptCorrection(source: "yeti nano", replacement: "USB mic"),
            TranscriptCorrection(source: "", replacement: "ignored"),
            TranscriptCorrection(source: "empty replacement", replacement: "   ")
        ])
        try expect(
            normalized,
            equals: [TranscriptCorrection(source: "yeti nano", replacement: "USB mic")],
            "normalization should trim, drop incomplete entries, collapse duplicate sources, and keep the latest replacement"
        )

        let boundedCorrections = normalizedTranscriptCorrections(
            [
                TranscriptCorrection(source: String(repeating: "s", count: MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES + 1),
                                     replacement: "replacement"),
                TranscriptCorrection(source: "source",
                                     replacement: String(repeating: "r", count: MAX_TRANSCRIPT_CORRECTION_REPLACEMENT_BYTES + 1)),
                TranscriptCorrection(source: "nul\u{0}source", replacement: "replacement"),
                TranscriptCorrection(source: "valid", replacement: "replacement")
            ]
            + (0..<(MAX_TRANSCRIPT_CORRECTIONS + 3)).map {
                TranscriptCorrection(source: "source-\($0)", replacement: "replacement-\($0)")
            }
            + [
                TranscriptCorrection(source: "source-0", replacement: "updated")
            ]
        )
        try expect(
            boundedCorrections.count,
            equals: MAX_TRANSCRIPT_CORRECTIONS,
            "normalization should cap stored correction count"
        )
        try expect(
            boundedCorrections.first,
            equals: TranscriptCorrection(source: "valid", replacement: "replacement"),
            "normalization should keep valid corrections while dropping oversized and NUL-containing entries"
        )
        try expect(
            boundedCorrections.dropFirst().first,
            equals: TranscriptCorrection(source: "source-0", replacement: "updated"),
            "normalization should still let later duplicates update retained corrections"
        )
        try expect(
            boundedCorrections.contains(where: { $0.source == "source-\(MAX_TRANSCRIPT_CORRECTIONS)" }),
            equals: false,
            "normalization should drop new unique corrections after the cap"
        )

        let applied = TranscriptCorrector.apply(
            to: "parakeet tdt and parakeetish and PARakeet",
            corrections: [
                TranscriptCorrection(source: "parakeet", replacement: "Parakey"),
                TranscriptCorrection(source: "parakeet tdt", replacement: "Parakeet TDT")
            ]
        )
        try expect(
            applied.text,
            equals: "Parakeet TDT and parakeetish and Parakey",
            "corrections should prefer longer phrases and respect word boundaries"
        )
        try expect(
            applied.appliedCount,
            equals: 2,
            "correction count should track applied non-overlapping replacements"
        )

        let transferred = try TranscriptCorrectionsTransfer.decode(
            TranscriptCorrectionsTransfer.encode([
                TranscriptCorrection(source: "  Right Option  ", replacement: "R-Option")
            ])
        )
        try expect(
            transferred,
            equals: [TranscriptCorrection(source: "Right Option", replacement: "R-Option")],
            "document transfer should round-trip normalized corrections"
        )

        let legacyData = try JSONEncoder().encode([
            TranscriptCorrection(source: "  old phrase  ", replacement: "new phrase")
        ])
        try expect(
            try TranscriptCorrectionsTransfer.decode(legacyData),
            equals: [TranscriptCorrection(source: "old phrase", replacement: "new phrase")],
            "legacy bare-array correction files should remain importable"
        )

        var oversizedDecodeRejected = false
        do {
            _ = try TranscriptCorrectionsTransfer.decode(
                Data(repeating: 0x20, count: TranscriptCorrectionsTransfer.maxFileBytes + 1)
            )
        } catch let error as TranscriptCorrectionsTransferError {
            if case .fileTooLarge = error {
                oversizedDecodeRejected = true
            }
        }
        try expect(oversizedDecodeRejected, equals: true,
                   "correction transfer should reject oversized in-memory data before decoding")

        let transferTmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let transferFileManager = FileManager.default
        let oversized = transferTmpDir
            .appendingPathComponent("parakey-corrections-oversized-\(UUID().uuidString).json")
        try Data(repeating: 0x20, count: TranscriptCorrectionsTransfer.maxFileBytes + 1)
            .write(to: oversized)
        defer { try? transferFileManager.removeItem(at: oversized) }
        var oversizedRejected = false
        do {
            _ = try TranscriptCorrectionsTransfer.read(from: oversized)
        } catch let error as TranscriptCorrectionsTransferError {
            if case .fileTooLarge = error {
                oversizedRejected = true
            }
        }
        try expect(oversizedRejected, equals: true,
                   "correction transfer should reject oversized files before decoding")

        let nonFile = transferTmpDir
            .appendingPathComponent("parakey-corrections-directory-\(UUID().uuidString)")
        try transferFileManager.createDirectory(at: nonFile, withIntermediateDirectories: false)
        defer { try? transferFileManager.removeItem(at: nonFile) }
        var nonFileRejected = false
        do {
            _ = try TranscriptCorrectionsTransfer.read(from: nonFile)
        } catch let error as TranscriptCorrectionsTransferError {
            if case .notRegularFile = error {
                nonFileRejected = true
            }
        }
        try expect(nonFileRejected, equals: true,
                   "correction transfer should reject non-file paths")

        let readTarget = transferTmpDir
            .appendingPathComponent("parakey-corrections-read-target-\(UUID().uuidString).json")
        try TranscriptCorrectionsTransfer.write(
            [TranscriptCorrection(source: "source", replacement: "replacement")],
            to: readTarget
        )
        defer { try? transferFileManager.removeItem(at: readTarget) }
        let readLink = transferTmpDir
            .appendingPathComponent("parakey-corrections-read-link-\(UUID().uuidString).json")
        try transferFileManager.createSymbolicLink(at: readLink, withDestinationURL: readTarget)
        defer { try? transferFileManager.removeItem(at: readLink) }
        var symlinkReadRejected = false
        do {
            _ = try TranscriptCorrectionsTransfer.read(from: readLink)
        } catch let error as TranscriptCorrectionsTransferError {
            if case .notRegularFile = error {
                symlinkReadRejected = true
            }
        }
        try expect(symlinkReadRejected, equals: true,
                   "correction transfer should reject reads through leaf symlinks")

        let writeTarget = transferTmpDir
            .appendingPathComponent("parakey-corrections-write-target-\(UUID().uuidString).json")
        try Data("target\n".utf8).write(to: writeTarget)
        defer { try? transferFileManager.removeItem(at: writeTarget) }
        let writeLink = transferTmpDir
            .appendingPathComponent("parakey-corrections-write-link-\(UUID().uuidString).json")
        try transferFileManager.createSymbolicLink(at: writeLink, withDestinationURL: writeTarget)
        defer { try? transferFileManager.removeItem(at: writeLink) }
        var symlinkWriteRejected = false
        do {
            try TranscriptCorrectionsTransfer.write(
                [TranscriptCorrection(source: "source", replacement: "replacement")],
                to: writeLink
            )
        } catch let error as TranscriptCorrectionsTransferError {
            if case .notRegularFile = error {
                symlinkWriteRejected = true
            }
        }
        try expect(symlinkWriteRejected, equals: true,
                   "correction transfer should reject writes through leaf symlinks")
        try expect(
            String(data: try Data(contentsOf: writeTarget), encoding: .utf8),
            equals: "target\n",
            "correction transfer symlink rejection should leave the target untouched"
        )

        let remoteOnlyChange = mergedTranscriptCorrectionsForSync(
            base: [TranscriptCorrection(source: "old phrase", replacement: "old")],
            local: [TranscriptCorrection(source: "old phrase", replacement: "old")],
            remote: [TranscriptCorrection(source: "old phrase", replacement: "remote")]
        )
        try expect(
            remoteOnlyChange,
            equals: TranscriptCorrectionSyncMergeResult(
                corrections: [TranscriptCorrection(source: "old phrase", replacement: "remote")],
                conflictingSources: []
            ),
            "sync merge should accept remote changes when local has not changed"
        )

        let nonConflictingMerge = mergedTranscriptCorrectionsForSync(
            base: [
                TranscriptCorrection(source: "shared", replacement: "old"),
                TranscriptCorrection(source: "removed locally", replacement: "old")
            ],
            local: [TranscriptCorrection(source: "shared", replacement: "local")],
            remote: [
                TranscriptCorrection(source: "shared", replacement: "old"),
                TranscriptCorrection(source: "removed locally", replacement: "old"),
                TranscriptCorrection(source: "remote only", replacement: "remote")
            ]
        )
        try expect(
            nonConflictingMerge,
            equals: TranscriptCorrectionSyncMergeResult(
                corrections: [
                    TranscriptCorrection(source: "shared", replacement: "local"),
                    TranscriptCorrection(source: "remote only", replacement: "remote")
                ],
                conflictingSources: []
            ),
            "sync merge should combine non-conflicting local edits, local deletes, and remote additions"
        )

        let conflictingMerge = mergedTranscriptCorrectionsForSync(
            base: [TranscriptCorrection(source: "same source", replacement: "old")],
            local: [TranscriptCorrection(source: "same source", replacement: "local")],
            remote: [TranscriptCorrection(source: "same source", replacement: "remote")]
        )
        try expect(
            conflictingMerge,
            equals: TranscriptCorrectionSyncMergeResult(corrections: [],
                                                        conflictingSources: ["same source"]),
            "sync merge should report same-source edits that changed differently on both sides"
        )

        let normalizedSyncPath = normalizedCorrectionSyncFilePath(" /tmp/superdictate/../SuperDictate Corrections.superdictate-corrections\n")
        try expect(
            normalizedSyncPath,
            equals: "/tmp/SuperDictate Corrections.superdictate-corrections",
            "correction sync path normalization should trim and standardize absolute paths"
        )
        try expect(
            normalizedCorrectionSyncFilePath("relative/path.superdictate-corrections"),
            equals: nil,
            "correction sync path normalization should reject relative paths"
        )
        try expect(
            normalizedCorrectionSyncFilePath("/tmp/\u{0}superdictate.superdictate-corrections"),
            equals: nil,
            "correction sync path normalization should reject NUL bytes"
        )
        try expect(
            normalizedCorrectionSyncFilePath("/" + String(repeating: "x", count: MAX_CORRECTION_SYNC_PATH_BYTES)),
            equals: nil,
            "correction sync path normalization should reject oversized paths"
        )

        // Reject leaf-symlinks at the sync path so an attacker who can
        // plant a symlink at the persisted sync-file location cannot use
        // the periodic auto-write to overwrite an unrelated file.
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let fm = FileManager.default
        let nonexistent = tmpDir.appendingPathComponent("parakey-sync-test-missing-\(UUID().uuidString).json")
        try validateCorrectionSyncPath(nonexistent) // missing files are allowed (first-time write)

        let regular = tmpDir.appendingPathComponent("parakey-sync-test-regular-\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: regular)
        defer { try? fm.removeItem(at: regular) }
        try validateCorrectionSyncPath(regular)

        let target = tmpDir.appendingPathComponent("parakey-sync-test-target-\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: target)
        defer { try? fm.removeItem(at: target) }
        let link = tmpDir.appendingPathComponent("parakey-sync-test-link-\(UUID().uuidString).json")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? fm.removeItem(at: link) }
        var rejected = false
        do {
            try validateCorrectionSyncPath(link)
        } catch is TranscriptCorrectionsSyncPathError {
            rejected = true
        }
        try expect(rejected, equals: true,
                   "validateCorrectionSyncPath should reject a leaf symlink")
        try expect(
            shouldStopCorrectionSync(afterPathValidationError: TranscriptCorrectionsSyncPathError.isSymbolicLink),
            equals: true,
            "unsafe sync paths should stop configured correction sync"
        )
        try expect(
            shouldStopCorrectionSync(afterPathValidationError: NSError(domain: "ParakeyTest", code: 1)),
            equals: false,
            "unrelated sync errors should not clear the configured correction sync path"
        )
        try expect(
            correctionSyncFingerprint(for: link),
            equals: nil,
            "correction sync fingerprinting should not follow leaf symlinks"
        )

        let sameSizeA = tmpDir.appendingPathComponent("parakey-sync-fingerprint-a-\(UUID().uuidString).json")
        let sameSizeB = tmpDir.appendingPathComponent("parakey-sync-fingerprint-b-\(UUID().uuidString).json")
        try Data("aaaa".utf8).write(to: sameSizeA)
        try Data("bbbb".utf8).write(to: sameSizeB)
        defer {
            try? fm.removeItem(at: sameSizeA)
            try? fm.removeItem(at: sameSizeB)
        }
        let sharedModifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.setAttributes([.modificationDate: sharedModifiedAt], ofItemAtPath: sameSizeA.path)
        try fm.setAttributes([.modificationDate: sharedModifiedAt], ofItemAtPath: sameSizeB.path)

        guard let fingerprintA = correctionSyncFingerprint(for: sameSizeA),
              let fingerprintB = correctionSyncFingerprint(for: sameSizeB) else {
            throw SelfTestFailure.failed("correction sync fingerprint should read regular files")
        }
        try expect(
            fingerprintA.size,
            equals: fingerprintB.size,
            "same-size sync files should have equal size metadata in the fingerprint"
        )
        try expect(
            fingerprintA == fingerprintB,
            equals: false,
            "correction sync fingerprint should detect content changes even when file size matches"
        )

        // The full legal correction set must encode within the
        // transfer cap: 512 entries at the per-field caps is ~2.4 MB
        // encoded, which silently failed to save under the old 2 MiB
        // cap. Also pin that it really is over 2 MiB, documenting why
        // the cap moved to 4 MiB.
        let worstCaseSet = (0..<MAX_TRANSCRIPT_CORRECTIONS).map { index in
            TranscriptCorrection(
                source: String(format: "%06d-", index)
                    + String(repeating: "s", count: MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES - 7),
                replacement: String(repeating: "r", count: MAX_TRANSCRIPT_CORRECTION_REPLACEMENT_BYTES)
            )
        }
        let worstCaseData = try TranscriptCorrectionsTransfer.encode(worstCaseSet)
        try expect(
            worstCaseData.count > 2 * 1024 * 1024,
            equals: true,
            "worst-case legal correction set should exceed the old 2 MiB cap (why the cap is now larger)"
        )
        try expect(
            worstCaseData.count <= TranscriptCorrectionsTransfer.maxFileBytes,
            equals: true,
            "worst-case legal correction set must fit the transfer cap with JSON-overhead headroom"
        )
        try expect(
            try TranscriptCorrectionsTransfer.decode(worstCaseData).count,
            equals: MAX_TRANSCRIPT_CORRECTIONS,
            "worst-case legal correction set should round-trip through the transfer cap"
        )

        // Near the correction cap a merge can briefly exceed it. The
        // sync baseline must store the same normalized (capped) list
        // that is written to the file — a raw over-cap baseline makes
        // the capped-out entry look like a local deletion later.
        let sharedNearCap = (0..<(MAX_TRANSCRIPT_CORRECTIONS - 1)).map {
            TranscriptCorrection(source: "shared-\($0)", replacement: "same")
        }
        let nearCapMerge = mergedTranscriptCorrectionsForSync(
            base: sharedNearCap,
            local: sharedNearCap + [TranscriptCorrection(source: "local-extra", replacement: "local")],
            remote: sharedNearCap + [TranscriptCorrection(source: "remote-extra", replacement: "remote")]
        )
        try expect(
            nearCapMerge.conflictingSources,
            equals: [],
            "near-cap merge with disjoint additions should not conflict"
        )
        try expect(
            nearCapMerge.corrections.count,
            equals: MAX_TRANSCRIPT_CORRECTIONS + 1,
            "near-cap merge result can exceed the cap before normalization"
        )
        let nearCapNormalized = normalizedTranscriptCorrections(nearCapMerge.corrections)
        try expect(
            nearCapNormalized.count,
            equals: MAX_TRANSCRIPT_CORRECTIONS,
            "normalizing the near-cap merge result should drop the over-cap entry"
        )
        try expect(
            nearCapNormalized.contains(TranscriptCorrection(source: "local-extra", replacement: "local")),
            equals: true,
            "normalization keeps the earlier (local) addition at the cap"
        )
        try expect(
            nearCapNormalized.contains(TranscriptCorrection(source: "remote-extra", replacement: "remote")),
            equals: false,
            "the capped-out remote addition is exactly what the baseline must also drop"
        )

        // Fingerprinting the bytes we wrote must agree with a fresh
        // disk fingerprint when nobody touched the file in between —
        // the sync path uses the in-memory form so a provider replacing
        // the file in the write-to-fingerprint window is still detected
        // by the next scan.
        let fingerprintWriteTarget = tmpDir
            .appendingPathComponent("parakey-sync-written-fingerprint-\(UUID().uuidString).json")
        let fingerprintWrittenData = try TranscriptCorrectionsTransfer.write(
            [TranscriptCorrection(source: "fingerprint", replacement: "match")],
            to: fingerprintWriteTarget
        )
        defer { try? fm.removeItem(at: fingerprintWriteTarget) }
        guard let fingerprintFromDisk = correctionSyncFingerprint(for: fingerprintWriteTarget) else {
            throw SelfTestFailure.failed("disk fingerprint should be readable right after a write")
        }
        try expect(
            correctionSyncFingerprint(forWrittenData: fingerprintWrittenData, at: fingerprintWriteTarget),
            equals: fingerprintFromDisk,
            "fingerprint of written bytes should match the disk fingerprint of an untouched file"
        )

        // Counted decode keeps the file's pre-normalization entry count
        // so the import dialog can disclose truncation.
        let countedOriginal = (0..<(MAX_TRANSCRIPT_CORRECTIONS + 5)).map {
            TranscriptCorrection(source: "counted-\($0)", replacement: "kept")
        }
        let countedEncoder = JSONEncoder()
        countedEncoder.dateEncodingStrategy = .iso8601
        let countedDocument = TranscriptCorrectionsDocument(
            schemaVersion: TranscriptCorrectionsTransfer.schemaVersion,
            exportedAt: Date(),
            appVersion: currentBundleVersion(),
            corrections: countedOriginal
        )
        let counted = try TranscriptCorrectionsTransfer.decodeCounted(countedEncoder.encode(countedDocument))
        try expect(
            counted.originalCount,
            equals: MAX_TRANSCRIPT_CORRECTIONS + 5,
            "counted decode should report the file's pre-normalization entry count"
        )
        try expect(
            counted.corrections.count,
            equals: MAX_TRANSCRIPT_CORRECTIONS,
            "counted decode should still normalize down to the correction cap"
        )
        let countedLegacy = try TranscriptCorrectionsTransfer.decodeCounted(
            try JSONEncoder().encode([TranscriptCorrection(source: "  legacy  ", replacement: "entry")])
        )
        try expect(
            countedLegacy,
            equals: TranscriptCorrectionsTransfer.CountedDecodeResult(
                corrections: [TranscriptCorrection(source: "legacy", replacement: "entry")],
                originalCount: 1
            ),
            "counted decode should support legacy bare-array files"
        )

        // Import dialog copy: state the original count when entries
        // will be dropped, and warn before a cap-overflowing merge.
        try expect(
            correctionImportCountText(sourceName: "file.superdictate-corrections",
                                      originalCount: 3,
                                      keptCount: 3),
            equals: "file.superdictate-corrections contains 3 corrections.",
            "import count text should stay simple when nothing is dropped"
        )
        let truncatedImportText = correctionImportCountText(
            sourceName: "big.superdictate-corrections",
            originalCount: MAX_TRANSCRIPT_CORRECTIONS + 88,
            keptCount: MAX_TRANSCRIPT_CORRECTIONS
        )
        try expect(
            truncatedImportText.contains("contains \(MAX_TRANSCRIPT_CORRECTIONS + 88) entries"),
            equals: true,
            "import count text should state the file's original entry count when entries are dropped"
        )
        try expect(
            truncatedImportText.contains("first \(MAX_TRANSCRIPT_CORRECTIONS)"),
            equals: true,
            "import count text should state how many corrections will actually be kept"
        )
        try expect(
            correctionImportMergeCapWarningText(existingCount: 10, newCount: 10),
            equals: nil,
            "merge cap warning should stay silent when the merged set fits"
        )
        try expect(
            correctionImportMergeCapWarningText(existingCount: MAX_TRANSCRIPT_CORRECTIONS,
                                                newCount: 8)?.contains("8 would be dropped"),
            equals: true,
            "merge cap warning should state how many corrections a merge would drop"
        )
    }

    private static func testVocabularyStore() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocabulary-store-selftest-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let store = try VocabularyStore(fileURL: tempURL)

        // Manual upsert + dedup by source (case-insensitive).
        let first = try store.upsert(source: "инглиш", replacement: "English", origin: .manual)
        guard first.origin == .manual else { throw VocabularyLearningTestFailure("expected manual origin") }
        let updated = try store.upsert(source: "Инглиш", replacement: "english", origin: .manual)
        guard store.count() == 1, updated.replacement == "english" else {
            throw VocabularyLearningTestFailure("case-insensitive upsert should update the existing row, not add a second one")
        }

        // recordLearned: no-op when source already known.
        guard store.recordLearned(source: "инглиш", replacement: "English") == nil else {
            throw VocabularyLearningTestFailure("recordLearned should no-op for an already-known source")
        }

        // recordLearned: succeeds for a new source, tagged 'learned'.
        guard let learned = store.recordLearned(source: "кложа", replacement: "closure"), learned.origin == .learned else {
            throw VocabularyLearningTestFailure("recordLearned should insert a new source tagged learned")
        }
        guard store.count() == 2 else { throw VocabularyLearningTestFailure("expected 2 rows after recordLearned") }

        // delete(id:)
        store.delete(id: learned.id)
        guard store.count() == 1 else { throw VocabularyLearningTestFailure("delete(id:) should remove exactly one row") }

        // replaceAllPreservingOrigin: preserves origin/created_at for kept rows, drops missing ones, adds new ones as manual.
        _ = try store.upsert(source: "старое", replacement: "old", origin: .learned)
        store.replaceAllPreservingOrigin([
            TranscriptCorrection(source: "инглиш", replacement: "English (edited)"),
            TranscriptCorrection(source: "новое", replacement: "new"),
        ])
        let all = store.all()
        guard all.count == 2 else { throw VocabularyLearningTestFailure("replaceAllPreservingOrigin should leave exactly the given sources") }
        guard let englishRow = all.first(where: { $0.source.lowercased() == "инглиш" }), englishRow.replacement == "English (edited)" else {
            throw VocabularyLearningTestFailure("replaceAllPreservingOrigin should update the replacement text for a kept source")
        }
        guard let newRow = all.first(where: { $0.source == "новое" }), newRow.origin == .manual else {
            throw VocabularyLearningTestFailure("replaceAllPreservingOrigin should tag brand-new sources as manual")
        }

        // Cap enforcement in recordLearned.
        let capStore = try VocabularyStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("vocabulary-store-cap-\(UUID().uuidString).sqlite"))
        defer { }
        for index in 0..<MAX_TRANSCRIPT_CORRECTIONS {
            _ = try capStore.upsert(source: "src\(index)", replacement: "rep\(index)", origin: .manual)
        }
        guard capStore.recordLearned(source: "one-too-many", replacement: "nope") == nil else {
            throw VocabularyLearningTestFailure("recordLearned must not exceed MAX_TRANSCRIPT_CORRECTIONS")
        }
    }

    private static func testFillerWordRemoval() throws {
        // Mid-sentence filler with surrounding commas → orphan comma
        // gets collapsed.
        let mid = FillerWordRemover.apply(to: "So, um, I was going.")
        try expect(mid.text, equals: "So, I was going.", "mid-sentence filler should leave a single comma")
        try expect(mid.removedCount, equals: 1, "mid-sentence filler removal count")

        // Sentence-initial filler with leading-comma cleanup AND
        // capitalisation restored (the original 'U' was uppercase).
        let initial = FillerWordRemover.apply(to: "Um, hello.")
        try expect(initial.text, equals: "Hello.", "sentence-initial filler should re-capitalise the next word")
        try expect(initial.removedCount, equals: 1, "sentence-initial filler removal count")

        let secondSentence = FillerWordRemover.apply(to: "This is the first sentence. Um this is the second sentence.")
        try expect(
            secondSentence.text,
            equals: "This is the first sentence. This is the second sentence.",
            "sentence-initial filler after a period should re-capitalise the next word"
        )
        try expect(secondSentence.removedCount, equals: 1, "second-sentence filler removal count")

        let secondSentenceWithComma = FillerWordRemover.apply(to: "This is the first sentence. Um, this is the second sentence.")
        try expect(
            secondSentenceWithComma.text,
            equals: "This is the first sentence. This is the second sentence.",
            "sentence-initial filler after a period should not leave an orphan comma"
        )
        try expect(secondSentenceWithComma.removedCount, equals: 1, "second-sentence comma filler removal count")

        let secondSentenceQuestion = FillerWordRemover.apply(to: "This is the first sentence. Um? this is the second sentence.")
        try expect(
            secondSentenceQuestion.text,
            equals: "This is the first sentence. This is the second sentence.",
            "sentence-initial filler with its own punctuation should take that punctuation with it"
        )
        try expect(secondSentenceQuestion.removedCount, equals: 1, "second-sentence question filler removal count")

        let capitalizedMidSentence = FillerWordRemover.apply(to: "This is not a sentence boundary Um this stays lowercase.")
        try expect(
            capitalizedMidSentence.text,
            equals: "This is not a sentence boundary this stays lowercase.",
            "capitalized fillers away from sentence starts should not force capitalization"
        )
        try expect(capitalizedMidSentence.removedCount, equals: 1, "capitalized mid-sentence filler removal count")

        // Bare filler with adjacent punctuation collapses to empty.
        let bare = FillerWordRemover.apply(to: "Um.")
        try expect(bare.text, equals: "", "bare filler with trailing punctuation should leave empty string")
        try expect(bare.removedCount, equals: 1, "bare filler removal count")

        // Filler with no surrounding punctuation just leaves a space
        // that gets collapsed away.
        let inline = FillerWordRemover.apply(to: "I'm uh going to the store.")
        try expect(inline.text, equals: "I'm going to the store.", "inline filler should collapse the leftover whitespace")
        try expect(inline.removedCount, equals: 1, "inline filler removal count")

        // Compound interjection "uh-huh" must NOT match — the hyphen is
        // part of the boundary class.
        let uhHuh = FillerWordRemover.apply(to: "Yeah, uh-huh.")
        try expect(uhHuh.text, equals: "Yeah, uh-huh.", "uh-huh must not be stripped")
        try expect(uhHuh.removedCount, equals: 0, "uh-huh removal count")

        // Words that *contain* a filler substring must not match. "her"
        // contains "er", "sum" contains "um", "exercise" contains "er".
        let contains = FillerWordRemover.apply(to: "Her sum exercise is harder.")
        try expect(contains.text, equals: "Her sum exercise is harder.", "filler substrings inside larger words must be preserved")
        try expect(contains.removedCount, equals: 0, "no removals when fillers are embedded in real words")

        // Multiple fillers in one utterance all get stripped.
        let multi = FillerWordRemover.apply(to: "Um, ah, I uh think so.")
        try expect(multi.text, equals: "I think so.", "multiple fillers should all be removed and artifacts cleaned up")
        try expect(multi.removedCount, equals: 3, "multi-filler removal count")

        // Empty input should be a no-op.
        let empty = FillerWordRemover.apply(to: "")
        try expect(empty.text, equals: "", "empty input passes through unchanged")
        try expect(empty.removedCount, equals: 0, "empty input has zero removals")

        // No fillers present → identical text, zero removals.
        let clean = FillerWordRemover.apply(to: "Hello world.")
        try expect(clean.text, equals: "Hello world.", "filler-free input passes through unchanged")
        try expect(clean.removedCount, equals: 0, "filler-free input has zero removals")

        // Elongated fillers — common in real dictation. The word-
        // boundary lookahead would have rejected these without the
        // per-pattern trailing-repeat allowance.
        let elongatedUm = FillerWordRemover.apply(to: "Ummm, hello.")
        try expect(elongatedUm.text, equals: "Hello.", "ummm should be stripped like um")
        try expect(elongatedUm.removedCount, equals: 1, "elongated um removal count")

        let elongatedUh = FillerWordRemover.apply(to: "Uhhh I think so.")
        try expect(elongatedUh.text, equals: "I think so.", "uhhh should be stripped like uh")
        try expect(elongatedUh.removedCount, equals: 1, "elongated uh removal count")

        let elongatedAh = FillerWordRemover.apply(to: "Ahhh, that makes sense.")
        try expect(elongatedAh.text, equals: "That makes sense.", "ahhh should be stripped like ah")
        try expect(elongatedAh.removedCount, equals: 1, "elongated ah removal count")

        // `hm+` covers both "hm" (single m) and "hmmm" (extended). The
        // earlier fixed-list "hmm" entry rejected the single-m form.
        let shortHm = FillerWordRemover.apply(to: "Hm, interesting.")
        try expect(shortHm.text, equals: "Interesting.", "short hm should be stripped like hmm")
        try expect(shortHm.removedCount, equals: 1, "short hm removal count")

        // Words containing the new repeat-friendly patterns must still
        // pass through. "ohm" embeds "hm" but has a leading letter.
        let embedded = FillerWordRemover.apply(to: "An ohm is a unit.")
        try expect(embedded.text, equals: "An ohm is a unit.", "ohm must not match hm")
        try expect(embedded.removedCount, equals: 0, "ohm should produce zero removals")

        // Two consecutive fillers used to leave ",," because the
        // comma-collapse pass was single-pass/non-overlapping: it
        // consumed one ", ," pair and the whitespace-before-punctuation
        // pass then glued the leftover " ," into ",,".
        let consecutive = FillerWordRemover.apply(to: "So, um, uh, yes.")
        try expect(consecutive.text, equals: "So, yes.", "consecutive fillers should collapse to a single comma")
        try expect(consecutive.removedCount, equals: 2, "consecutive filler removal count")

        // Three consecutive fillers exercise runs longer than one
        // collapse step.
        let tripleRun = FillerWordRemover.apply(to: "He said, um, uh, er, no.")
        try expect(tripleRun.text, equals: "He said, no.", "a run of three fillers should collapse to a single comma")
        try expect(tripleRun.removedCount, equals: 3, "triple filler removal count")

        // Consecutive fillers mid-sentence keep exactly one comma,
        // matching the single-filler behavior above.
        let midRun = FillerWordRemover.apply(to: "I think, um, uh, we should go.")
        try expect(midRun.text, equals: "I think, we should go.", "mid-sentence consecutive fillers should keep one comma")
        try expect(midRun.removedCount, equals: 2, "mid-sentence consecutive filler removal count")

        // Trailing filler before terminal punctuation used to leave
        // ",." because no pass cleaned a comma glued onto a period.
        let trailing = FillerWordRemover.apply(to: "That's all, um.")
        try expect(trailing.text, equals: "That's all.", "trailing filler should not leave a comma before the period")
        try expect(trailing.removedCount, equals: 1, "trailing filler removal count")

        let beforeQuestion = FillerWordRemover.apply(to: "Is that right, um?")
        try expect(beforeQuestion.text, equals: "Is that right?", "filler before a question mark should not leave a comma")
        try expect(beforeQuestion.removedCount, equals: 1, "filler before question mark removal count")

        let beforeBang = FillerWordRemover.apply(to: "Stop, um!")
        try expect(beforeBang.text, equals: "Stop!", "filler before an exclamation mark should not leave a comma")
        try expect(beforeBang.removedCount, equals: 1, "filler before exclamation mark removal count")

        // Sentence-initial filler with its own terminal punctuation:
        // the leading-strip class must include "?" and "!" or the
        // orphaned punctuation survives ("Um? What?" → "? What?").
        let leadingQuestion = FillerWordRemover.apply(to: "Um? What?")
        try expect(leadingQuestion.text, equals: "What?", "leading filler question should take its punctuation with it")
        try expect(leadingQuestion.removedCount, equals: 1, "leading filler question removal count")

        let leadingBang = FillerWordRemover.apply(to: "Ah! Careful.")
        try expect(leadingBang.text, equals: "Careful.", "leading filler exclamation should take its punctuation with it")
        try expect(leadingBang.removedCount, equals: 1, "leading filler exclamation removal count")
    }

    private static func testFillerWordRemoverPresetsAndCustomWords() throws {
        // Only enabled presets are removed.
        // "Um" carries the capital at sentence start, so removal restores
        // capitalization onto the following word ("hello" -> "Hello"),
        // exactly like the pre-existing sentence-initial-filler behavior
        // exercised in testFillerWordRemoval. "ah" is left untouched
        // because only the "en_um" preset is enabled.
        let onlyUm = FillerWordRemover.apply(to: "Um, hello, ah, world.", enabledPresetKeys: ["en_um"], customWords: [])
        try expect(onlyUm.text, equals: "Hello, ah, world.", "only the enabled preset (um) should be removed, ah stays")

        // Phrase preset, default-off key, explicitly enabled.
        let phrase = FillerWordRemover.apply(to: "Это как бы сложно.", enabledPresetKeys: ["ru_kak_by"], customWords: [])
        try expect(phrase.text, equals: "Это сложно.", "multi-word Russian phrase preset should be removed when enabled")

        // Custom word, case-insensitive, word-boundary safe.
        let custom = FillerWordRemover.apply(to: "So anyway I think so.", enabledPresetKeys: [], customWords: ["anyway"])
        try expect(custom.text, equals: "So I think so.", "custom single word should be removed when listed")

        // Custom multi-word phrase, tolerant of ASR spacing via \s+.
        let customPhrase = FillerWordRemover.apply(to: "This is sort  of  fine.", enabledPresetKeys: [], customWords: ["sort of"])
        try expect(customPhrase.text, equals: "This is fine.", "custom multi-word phrase should tolerate extra whitespace")

        // No presets, no custom words -> no-op.
        let noop = FillerWordRemover.apply(to: "Nothing changes here.", enabledPresetKeys: [], customWords: [])
        try expect(noop.text, equals: "Nothing changes here.", "empty preset/custom sets should leave text untouched")

        // Longest-first ordering: a custom word that's a substring of a longer
        // enabled phrase must not corrupt the phrase.
        // As with "onlyUm" above, "Это" carries the sentence-initial capital,
        // so removing the full "это самое" phrase restores capitalization
        // onto "сложно". The key assertion here is that the longer phrase
        // ("это самое") is matched and removed whole -- not the shorter
        // "это" leaving a stray "самое" behind.
        let ordering = FillerWordRemover.apply(to: "Это самое сложно.", enabledPresetKeys: ["ru_eto_samoe"], customWords: ["это"])
        try expect(ordering.text, equals: "Сложно.", "the longer phrase preset must be tried before the shorter custom word it contains")

        // Regression coverage for the exact two presets a user reported as
        // "не фильтруются": the pipeline itself must handle both when they
        // are ticked (the real bug was in the Settings window, which ate
        // the clicks before they could be saved).
        let znaesh = FillerWordRemover.apply(to: "Ну, знаешь, как дела?", enabledPresetKeys: ["ru_znaesh"], customWords: [])
        try expect(znaesh.text, equals: "Ну, как дела?", "ru_znaesh must be removed when ticked")

        let etoSamoe = FillerWordRemover.apply(to: "Я, это самое, не знаю.", enabledPresetKeys: ["ru_eto_samoe"], customWords: [])
        try expect(etoSamoe.text, equals: "Я, не знаю.", "ru_eto_samoe must be removed when ticked")

        // Blank/whitespace-only custom words must be ignored, not turned
        // into a zero-width-match pattern that inflates removedCount and
        // corrupts unrelated text via the punctuation-cleanup pass.
        let blankCustomWords = FillerWordRemover.apply(to: "Hello world.", enabledPresetKeys: [], customWords: ["", "   "])
        try expect(blankCustomWords.text, equals: "Hello world.", "blank/whitespace-only custom words should be a no-op")
        try expect(blankCustomWords.removedCount, equals: 0, "blank/whitespace-only custom words should not count as removals")

        // Russian hesitation-sound presets (ru_e, ru_em, ru_m, ru_am, ru_aa)
        // are intentionally defaultEnabled: true per the design doc's
        // parity intent (docs/superpowers/specs/2026-08-01-windows-port-
        // feature-parity-design.md §1: Russian hesitation sounds are
        // categorized alongside the English ones as "unambiguous
        // hesitation sounds", not as an ambiguous real-word phrase like
        // "как бы"/"типа"). This is a deliberate behavior *addition* for
        // any user who hasn't touched filler settings, not a preserved
        // no-op -- confirmed here through the same production path
        // (processedDictationText with default enabledFillerPresetKeys)
        // that live dictation uses.
        let russianDefaultOn = processedDictationText(
            rawTranscript: "Э, мне нужно подумать.",
            corrections: [],
            removeFillerWords: true
        )
        try expect(russianDefaultOn.text, equals: "Мне нужно подумать.", "Russian hesitation sound (э) should be removed by default, with no explicit preset/custom-word configuration")
    }

    private static func testFillerWordPresetDefaults() throws {
        // Every preset's default-enabled status must match its curated intent:
        // hesitation sounds on, real-word phrases off.
        let alwaysOnKeys: Set<String> = ["en_um", "en_uh", "en_ah", "en_er", "en_erm", "en_hm",
                                          "ru_e", "ru_em", "ru_m", "ru_am", "ru_aa"]
        let alwaysOffKeys: Set<String> = ["ru_kak_by", "ru_tipa", "ru_koroche", "en_like", "en_you_know"]
        for preset in FillerWordRemover.presets where alwaysOnKeys.contains(preset.key) {
            guard preset.defaultEnabled else {
                throw SelfTestFailure.failed("expected \(preset.key) to default on")
            }
        }
        for preset in FillerWordRemover.presets where alwaysOffKeys.contains(preset.key) {
            guard !preset.defaultEnabled else {
                throw SelfTestFailure.failed("expected \(preset.key) to default off")
            }
        }

        // No duplicate keys -- a duplicate would silently shadow one preset's
        // toggle state with another's in the enabled-set.
        let keys = FillerWordRemover.presets.map(\.key)
        guard Set(keys).count == keys.count else {
            throw SelfTestFailure.failed("duplicate FillerWordPreset keys found")
        }
    }

    private static func testEnabledFillerPresetKeysSetting() throws {
        let defaults = UserDefaults.standard
        let key = "enabled_filler_preset_keys"
        let previous = defaults.array(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        defaults.removeObject(forKey: key)
        let settings = Settings.shared
        guard settings.enabledFillerPresetKeys == FillerWordRemover.defaultEnabledPresetKeys else {
            throw SelfTestFailure.failed("expected default enabled set when nothing stored yet")
        }

        settings.enabledFillerPresetKeys = ["en_um"]
        guard settings.enabledFillerPresetKeys == ["en_um"] else {
            throw SelfTestFailure.failed("expected stored set to override the default once written")
        }
    }

    private static func testSilenceAutoStopTracker() throws {
        // Continuous silence past the threshold fires exactly once.
        var tracker = SilenceAutoStopTracker(thresholdSeconds: 5)
        try expect(tracker.update(level: 0.0, now: 0), equals: false, "tick 0: not yet silent long enough")
        try expect(tracker.update(level: 0.0, now: 3), equals: false, "tick 3s: still under threshold")
        try expect(tracker.update(level: 0.0, now: 5), equals: true, "tick 5s: threshold reached, fires once")
        try expect(tracker.update(level: 0.0, now: 6), equals: false, "tick 6s: already fired, must not fire again")

        // A voiced tick resets the clock.
        var resetTracker = SilenceAutoStopTracker(thresholdSeconds: 5)
        _ = resetTracker.update(level: 0.0, now: 0)
        _ = resetTracker.update(level: 0.0, now: 4)
        _ = resetTracker.update(level: 0.5, now: 4.5) // voice interrupts
        try expect(resetTracker.update(level: 0.0, now: 5), equals: false, "silence restarted after voice, 0.5s in is not enough")
        try expect(resetTracker.update(level: 0.0, now: 9.5), equals: true, "5s of continuous silence after the reset point fires")

        // reset() allows firing again for a new recording.
        var reusedTracker = SilenceAutoStopTracker(thresholdSeconds: 1)
        _ = reusedTracker.update(level: 0.0, now: 0)
        try expect(reusedTracker.update(level: 0.0, now: 1), equals: true, "first recording fires at 1s")
        reusedTracker.reset()
        try expect(reusedTracker.update(level: 0.0, now: 1.5), equals: false, "after reset, clock restarts from the next tick")
        try expect(reusedTracker.update(level: 0.0, now: 2.5), equals: true, "second recording fires 1s after its own start")
    }

    private static func testDisabledCustomFillerWords() throws {
        let defaults = UserDefaults.standard
        let wordsKey = "custom_filler_words"
        let disabledKey = "disabled_custom_filler_words"
        let previousWords = defaults.array(forKey: wordsKey)
        let previousDisabled = defaults.array(forKey: disabledKey)
        defer {
            if let previousWords { defaults.set(previousWords, forKey: wordsKey) } else { defaults.removeObject(forKey: wordsKey) }
            if let previousDisabled { defaults.set(previousDisabled, forKey: disabledKey) } else { defaults.removeObject(forKey: disabledKey) }
        }

        defaults.removeObject(forKey: wordsKey)
        defaults.removeObject(forKey: disabledKey)
        let settings = Settings.shared

        settings.customFillerWords = ["вещь", "thing"]
        try expect(settings.enabledCustomFillerWords, equals: ["вещь", "thing"],
                   "custom words are all enabled until explicitly unticked")

        settings.disabledCustomFillerWords = ["thing"]
        try expect(settings.enabledCustomFillerWords, equals: ["вещь"],
                   "unticked custom word must drop out of the pipeline list but stay stored")

        // The pipeline itself must skip the unticked word and keep the rest.
        let stripped = FillerWordRemover.apply(to: "This thing is a thing, honestly.",
                                               enabledPresetKeys: [],
                                               customWords: settings.enabledCustomFillerWords)
        try expect(stripped.text, equals: "This thing is a thing, honestly.",
                   "unticked custom word must not be removed from dictated text")

        let active = FillerWordRemover.apply(to: "This thing is a вещь, honestly.",
                                             enabledPresetKeys: [],
                                             customWords: settings.enabledCustomFillerWords)
        try expect(active.text, equals: "This thing is a, honestly.",
                   "ticked custom word must still be removed")
    }

    private static func testRecordingHUDAccentColorResolvedColor() throws {
        for color in RecordingHUDAccentColor.allCases where color != .contrast {
            try expect(color.resolvedColor(lightBackground: true), equals: color.nsColor,
                       "\(color) must be background-independent on a light background")
            try expect(color.resolvedColor(lightBackground: false), equals: color.nsColor,
                       "\(color) must be background-independent on a dark background")
        }
        try expect(RecordingHUDAccentColor.contrast.resolvedColor(lightBackground: true), equals: .black,
                   "contrast on a light background must resolve to black")
        try expect(RecordingHUDAccentColor.contrast.resolvedColor(lightBackground: false), equals: .white,
                   "contrast on a dark background must resolve to white")
    }

    private static func testAudioInputDeviceFiltering() throws {
        let pseudo = AudioInputDevice(id: 1,
                                      uid: "CADefaultDeviceAggregate-42159-0",
                                      name: "CADefaultDeviceAggregate-42159-0")
        let real = AudioInputDevice(id: 2,
                                    uid: "real-yeti-nano",
                                    name: "Yeti Nano")

        try expect(
            isDefaultAggregateAudioInputDevice(pseudo),
            equals: true,
            "CoreAudio default aggregate devices should be recognized"
        )
        try expect(
            isDefaultAggregateAudioInputDevice(real),
            equals: false,
            "named microphones should remain selectable"
        )
        try expect(
            normalizedInputDevicePreference(" Yeti Nano\n"),
            equals: "Yeti Nano",
            "input device preferences should be trimmed before storing"
        )
        try expect(
            normalizedInputDevicePreference(pseudo.uid),
            equals: nil,
            "input device preferences should reject CoreAudio default aggregates"
        )
        try expect(
            normalizedInputDevicePreference("real\u{0}device"),
            equals: nil,
            "input device preferences should reject NUL bytes"
        )
        try expect(
            normalizedInputDevicePreference(String(repeating: "x", count: MAX_INPUT_DEVICE_PREFERENCE_BYTES + 1)),
            equals: nil,
            "input device preferences should reject oversized values"
        )
        try expect(
            audioInputDevice(matching: pseudo.uid, in: [pseudo, real])?.uid,
            equals: nil,
            "CoreAudio default aggregate preferences should fall back to system default"
        )
        try expect(
            audioInputDevice(matching: " real-yeti-nano\n", in: [real])?.uid,
            equals: "real-yeti-nano",
            "input device preferences should resolve after trimming"
        )
        try expect(
            audioInputDevice(matching: "Yeti Nano", in: [real])?.uid,
            equals: "real-yeti-nano",
            "named microphone preferences should still resolve by display name"
        )

        // reloadAudioInputIfNeeded()'s change-detection must treat any
        // spelling of "system default" (empty string, whitespace-only,
        // or a stale CoreAudio default-aggregate UID) as equivalent, so
        // a settings save doesn't trigger a spurious audio-only restart.
        try expect(
            audioInputPreferenceDidChange(saved: "real-yeti-nano", activeAtLastEngineStart: ""),
            equals: true,
            "switching from system default to a named device should count as a change"
        )
        try expect(
            audioInputPreferenceDidChange(saved: "real-yeti-nano", activeAtLastEngineStart: "real-yeti-nano"),
            equals: false,
            "reselecting the already-active device should not count as a change"
        )
        try expect(
            audioInputPreferenceDidChange(saved: "", activeAtLastEngineStart: "  "),
            equals: false,
            "empty and whitespace-only preferences should both normalize to system default"
        )
        try expect(
            audioInputPreferenceDidChange(saved: "", activeAtLastEngineStart: pseudo.uid),
            equals: false,
            "a stale default-aggregate UID and an empty preference should both mean system default"
        )
        try expect(
            audioInputPreferenceDidChange(saved: " Yeti Nano\n", activeAtLastEngineStart: "Yeti Nano"),
            equals: false,
            "untrimmed and trimmed spellings of the same device should not count as a change"
        )
        try expect(
            audioInputPreferenceDidChange(saved: "real-yeti-nano", activeAtLastEngineStart: "other-device"),
            equals: true,
            "switching between two named devices should count as a change"
        )

        let sameName = AudioInputDevice(id: 3,
                                        uid: "another-yeti-nano",
                                        name: "Yeti Nano")
        try expect(
            audioInputDevice(matching: sameName.uid, in: [real, sameName])?.id,
            equals: sameName.id,
            "stable device UIDs should win even when microphone names are duplicated"
        )
        try expect(
            audioInputDevice(matching: "missing-device", in: [real]),
            equals: nil,
            "a disconnected saved microphone should resolve to system default"
        )
        try expect(
            shouldRestartAudioInputForSettingsChange(previousPreference: "",
                                                     nextPreference: real.uid,
                                                     isCoreRuntimeReady: true),
            equals: true,
            "changing microphones should restart only the audio input when runtime is ready"
        )
        try expect(
            shouldRestartAudioInputForSettingsChange(previousPreference: real.uid,
                                                     nextPreference: real.uid,
                                                     isCoreRuntimeReady: true),
            equals: false,
            "saving the same microphone should not restart audio"
        )
        try expect(
            shouldRestartAudioInputForSettingsChange(previousPreference: "",
                                                     nextPreference: real.uid,
                                                     isCoreRuntimeReady: false),
            equals: false,
            "startup should pick up a microphone change without an extra audio restart"
        )

        let suiteName = "com.local.superdictate.self-test.input.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw SelfTestFailure.failed("could not create isolated input-device defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let isolatedSettings = Settings(defaults: defaults)
        try expect(isolatedSettings.inputDevice, equals: "",
                   "microphone settings should default to the macOS system input")
        isolatedSettings.inputDevice = " \(real.uid)\n"
        try expect(isolatedSettings.inputDevice, equals: real.uid,
                   "microphone settings should persist a normalized stable UID")
        isolatedSettings.inputDevice = pseudo.uid
        try expect(isolatedSettings.inputDevice, equals: "",
                   "pseudo aggregate inputs should reset the preference to system default")
    }

    private static func testLiveAudioInputEnumeration() throws {
        let devices = availableAudioInputDevices()
        guard !devices.isEmpty else {
            throw SelfTestFailure.failed("CoreAudio reported no selectable input devices")
        }
        var seenUIDs = Set<String>()
        for device in devices {
            guard !device.uid.isEmpty, !device.name.isEmpty else {
                throw SelfTestFailure.failed("CoreAudio returned an input with an empty UID or name")
            }
            guard audioDeviceHasInputChannels(device.id) else {
                throw SelfTestFailure.failed("\(device.name) has no input channels")
            }
            guard !isDefaultAggregateAudioInputDevice(device) else {
                throw SelfTestFailure.failed("a temporary CoreAudio aggregate leaked into the picker")
            }
            guard seenUIDs.insert(device.uid).inserted else {
                throw SelfTestFailure.failed("CoreAudio returned duplicate input UID \(device.uid)")
            }
            print("AUDIO INPUT: \(device.name) [\(device.uid)]")
        }

        let engine = AVAudioEngine()
        guard let unit = engine.inputNode.audioUnit else {
            throw SelfTestFailure.failed("AVAudioEngine did not expose an input audio unit")
        }
        for device in devices {
            var deviceID = device.id
            let status = AudioUnitSetProperty(unit,
                                              kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global,
                                              0,
                                              &deviceID,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else {
                throw SelfTestFailure.failed(
                    "CoreAudio rejected \(device.name): \(formattedOSStatus(status))"
                )
            }
            guard currentAudioInputDeviceID(for: unit) == device.id else {
                throw SelfTestFailure.failed(
                    "CoreAudio did not make \(device.name) the current input"
                )
            }
            let captureFormat = engine.inputNode.inputFormat(forBus: 0)
            guard captureFormat.sampleRate > 0, captureFormat.channelCount > 0 else {
                throw SelfTestFailure.failed(
                    "\(device.name) did not expose an active capture format"
                )
            }
            if let expectedRate = audioInputDeviceNominalSampleRate(device.id),
               abs(captureFormat.sampleRate - expectedRate) >= 0.5 {
                throw SelfTestFailure.failed(
                    "\(device.name) capture format \(captureFormat.sampleRate) did not match \(expectedRate)"
                )
            }
            print("AUDIO SELECT: \(device.name) OK")
        }
    }

    private static func testSpeechModelStartupStatus() throws {
        // `.auto` maps to `nil` here — parakeet.cpp's plain PCM transcription
        // entry point (wrapped by `sd_parakeet_transcribe`) does not accept a
        // forced-language parameter at all (unlike whisper.cpp's
        // `params.language`, which this app used to map `nil` to the literal
        // string "auto" for), so `isoLanguageCode` is used only for
        // deterministic post-processing (`ParakeetTranscriptRepair`) — see
        // `DictationLanguage`'s doc comment in this file.
        try expect(
            DictationLanguage.auto.isoLanguageCode,
            equals: nil,
            "auto-detect should resolve to no forced ISO language code"
        )
        try expect(
            DictationLanguage.russian.isoLanguageCode,
            equals: "ru",
            "a specific language selection should pass its ISO-639-1 code through unchanged"
        )
        try expect(
            resolveEffectiveDictationLanguage(setting: .russian),
            equals: "ru",
            "an explicit language selection should bypass keyboard resolution unchanged"
        )
        // resolveEffectiveDictationLanguage(setting: .auto) itself depends on
        // the live Carbon keyboard input source, which is unavailable/unset
        // over SSH with no GUI session — so it can only be asserted here to
        // not crash. The actual tag → language-code mapping it delegates to
        // is a pure function and is fully exercised below.
        _ = resolveEffectiveDictationLanguage(setting: .auto)
        try expect(
            dictationLanguageCode(forKeyboardLanguageTag: "en-US"),
            equals: "en",
            "a region-qualified BCP-47 tag should resolve to its primary subtag's language code"
        )
        try expect(
            dictationLanguageCode(forKeyboardLanguageTag: "RU"),
            equals: "ru",
            "keyboard language tags should be matched case-insensitively"
        )
        try expect(
            dictationLanguageCode(forKeyboardLanguageTag: "zh-Hans"),
            equals: nil,
            "a keyboard language with no matching DictationLanguage should fall through to auto-detect"
        )
        try expect(
            dictationLanguageCode(forKeyboardLanguageTag: ""),
            equals: nil,
            "an empty keyboard language tag should fall through to auto-detect"
        )
        try expect(
            dictationLanguageCode(forKeyboardLanguageTag: "auto"),
            equals: nil,
            "a keyboard tag literally matching DictationLanguage.auto's rawValue must not be treated as a forced language"
        )
        // No Parakeet equivalent of whisper.cpp's `audio_ctx` window-trimming
        // concept exists (parakeet.cpp's encoder is not the same
        // architecture — see docs/parakeet-intel-backend.md's Phase 1
        // integration checklist) — the former
        // `WhisperEngine.audioContextFrames` boundary tests that lived here
        // were removed along with `WhisperEngine.swift` itself, not ported.
        try expect(
            speechModelStartupStatusTitle(0),
            equals: "Checking speech model files…",
            "zero progress should be visible during first-launch model setup"
        )
        try expect(
            speechModelStartupStatusTitle(0.5),
            equals: "Downloading speech model… 50%",
            "in-progress download should show quantized progress"
        )
        try expect(
            speechModelStartupStatusTitle(1),
            equals: "Preparing speech model…",
            "completed download should be visible without exposing model internals"
        )
        try expect(
            speechModelStartupProgressValue(0),
            equals: nil,
            "zero progress should show indeterminate model progress"
        )
        try expect(
            speechModelStartupProgressValue(0.5),
            equals: 0.5,
            "in-progress download should expose normalized model progress"
        )
        try expect(
            speechModelStartupProgressValue(1),
            equals: nil,
            "completed download should show indeterminate model progress"
        )
        let requiredBytes = speechModelDownloadRequiredBytes(for: .parakeetTDTv3,
                                                             headroomBytes: 100)
        try expect(
            requiredBytes,
            equals: PARAKEET_MODEL_SIZE_BYTES + 100,
            "speech model download requirement should include model estimate plus headroom"
        )
        try expect(
            speechModelDiskSpaceFailureDetail(profile: .parakeetTDTv3,
                                              availableBytes: requiredBytes - 1,
                                              requiredBytes: requiredBytes)?.contains("Free some disk space"),
            equals: true,
            "low disk-space failures should explain how to recover"
        )
        try expect(
            speechModelDiskSpaceFailureDetail(profile: .parakeetTDTv3,
                                              availableBytes: requiredBytes,
                                              requiredBytes: requiredBytes),
            equals: nil,
            "disk-space check should pass once required space is available"
        )
        try expect(
            speechModelDiskSpaceFailureDetail(profile: .parakeetTDTv3,
                                              availableBytes: nil,
                                              requiredBytes: requiredBytes),
            equals: nil,
            "unknown disk-space readings should not block model startup"
        )
    }

    private static func testModelIntegrity() throws {
        try testSpeechModelCachePathSafety()

        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parakey-model-integrity-\(UUID().uuidString)",
                                    isDirectory: true)
        let modelDir = root.appendingPathComponent("Toy.mlmodelc", isDirectory: true)
        try fm.createDirectory(at: modelDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let modelFile = modelDir.appendingPathComponent("model.mil")
        try Data("hello".utf8).write(to: modelFile)
        let expected = [
            ModelFileDigest(
                relativePath: "Toy.mlmodelc/model.mil",
                sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
            )
        ]
        try ModelIntegrity.verifyFiles(root: root,
                                       expectedFiles: expected,
                                       strictDirectories: ["Toy.mlmodelc"])

        var rejectedMismatch = false
        do {
            try ModelIntegrity.verifyFiles(
                root: root,
                expectedFiles: [
                    ModelFileDigest(relativePath: "Toy.mlmodelc/model.mil",
                                    sha256: String(repeating: "0", count: 64))
                ],
                strictDirectories: ["Toy.mlmodelc"]
            )
        } catch is ModelIntegrityError {
            rejectedMismatch = true
        }
        try expect(rejectedMismatch, equals: true,
                   "model integrity should reject digest mismatches")

        try Data("extra".utf8).write(to: modelDir.appendingPathComponent("extra.bin"))
        var rejectedUnexpectedFile = false
        do {
            try ModelIntegrity.verifyFiles(root: root,
                                           expectedFiles: expected,
                                           strictDirectories: ["Toy.mlmodelc"])
        } catch is ModelIntegrityError {
            rejectedUnexpectedFile = true
        }
        try expect(rejectedUnexpectedFile, equals: true,
                   "model integrity should reject unpinned files in strict model bundles")

        try fm.removeItem(at: modelDir.appendingPathComponent("extra.bin"))
        try fm.createDirectory(at: modelDir.appendingPathComponent("empty-extra", isDirectory: true),
                               withIntermediateDirectories: true)
        var rejectedUnexpectedDirectory = false
        do {
            try ModelIntegrity.verifyFiles(root: root,
                                           expectedFiles: expected,
                                           strictDirectories: ["Toy.mlmodelc"])
        } catch is ModelIntegrityError {
            rejectedUnexpectedDirectory = true
        }
        try expect(rejectedUnexpectedDirectory, equals: true,
                   "model integrity should reject unpinned directories in strict model bundles")

        var rejectedBadDigest = false
        do {
            try ModelIntegrity.verifyFiles(
                root: root,
                expectedFiles: [
                    ModelFileDigest(relativePath: "Toy.mlmodelc/model.mil",
                                    sha256: "not-a-sha256")
                ],
                strictDirectories: ["Toy.mlmodelc"]
            )
        } catch is ModelIntegrityError {
            rejectedBadDigest = true
        }
        try expect(rejectedBadDigest, equals: true,
                   "model integrity should reject malformed manifest digests")

        var rejectedDotSegment = false
        do {
            try ModelIntegrity.verifyFiles(
                root: root,
                expectedFiles: [
                    ModelFileDigest(
                        relativePath: "Toy.mlmodelc/./model.mil",
                        sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
                    )
                ],
                strictDirectories: ["Toy.mlmodelc"]
            )
        } catch is ModelIntegrityError {
            rejectedDotSegment = true
        }
        try expect(rejectedDotSegment, equals: true,
                   "model integrity should reject dot path segments")

        let symlinkedModelFile = modelDir.appendingPathComponent("model-link.mil")
        try fm.createSymbolicLink(at: symlinkedModelFile, withDestinationURL: modelFile)
        var rejectedSymlinkHashRead = false
        do {
            _ = try ModelIntegrity.sha256Hex(of: symlinkedModelFile,
                                             relativePath: "Toy.mlmodelc/model-link.mil")
        } catch is ModelIntegrityError {
            rejectedSymlinkHashRead = true
        }
        try expect(rejectedSymlinkHashRead, equals: true,
                   "model integrity hashing should not follow leaf symlinks")

        let localParakeetCache = speechModelCacheDirectory(for: .productionDefault)
        if fm.fileExists(atPath: localParakeetCache.path) {
            try expect(
                try sha256Hex(ofFileAt: localParakeetCache) == PARAKEET_MODEL_SHA256,
                equals: true,
                "cached Parakeet model should pass checksum verification"
            )
        }
    }

    private static func testSpeechModelCachePathSafety() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parakey-cache-safety-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("SuperDictate", isDirectory: true)
        let cache = support.appendingPathComponent("Models/parakeet-tdt-0.6b-v3-q8_0.gguf", isDirectory: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try expect(
            isSafeSpeechModelCacheDirectory(
                cache,
                parakeetSupportDirectory: support
            ),
            equals: true,
            "speech model cache reset should allow nested Parakeet cache paths"
        )
        try expect(
            isExistingSpeechModelCacheDirectorySafeForRemoval(cache,
                                                             parakeetSupportDirectory: support),
            equals: true,
            "speech model cache reset should allow existing plain cache directories"
        )
        try expect(
            isSafeSpeechModelCacheDirectory(support, parakeetSupportDirectory: support),
            equals: false,
            "speech model cache reset should not remove the SuperDictate support root"
        )
        try expect(
            isSafeSpeechModelCacheDirectory(
                support.deletingLastPathComponent().appendingPathComponent("SuperDictateBackup/parakeet-tdt-0.6b-v3-q8_0.gguf", isDirectory: true),
                parakeetSupportDirectory: support
            ),
            equals: false,
            "speech model cache reset should reject sibling support directories"
        )
        try expect(
            isSafeSpeechModelCacheDirectory(
                support.appendingPathComponent("../Outside/parakeet-tdt-0.6b-v3-q8_0.gguf", isDirectory: true),
                parakeetSupportDirectory: support
            ),
            equals: false,
            "speech model cache reset should reject paths that normalize outside SuperDictate support"
        )

        let outside = root.appendingPathComponent("Outside", isDirectory: true)
        let outsideCache = outside.appendingPathComponent("parakeet-tdt-0.6b-v3-q8_0.gguf", isDirectory: true)
        try fm.createDirectory(at: outsideCache, withIntermediateDirectories: true)

        let leafLink = support.appendingPathComponent("Models/link-cache", isDirectory: true)
        try fm.createSymbolicLink(at: leafLink, withDestinationURL: outsideCache)
        try expect(
            isSafeSpeechModelCacheDirectory(leafLink, parakeetSupportDirectory: support),
            equals: true,
            "speech model cache reset path check should remain string-only"
        )
        try expect(
            isExistingSpeechModelCacheDirectorySafeForRemoval(leafLink,
                                                             parakeetSupportDirectory: support),
            equals: false,
            "speech model cache reset should reject leaf symlink directories before deletion"
        )

        let linkedParent = support.appendingPathComponent("LinkedModels", isDirectory: true)
        try fm.createSymbolicLink(at: linkedParent, withDestinationURL: outside)
        try expect(
            isExistingSpeechModelCacheDirectorySafeForRemoval(
                linkedParent.appendingPathComponent("parakeet-tdt-0.6b-v3-q8_0.gguf", isDirectory: true),
                parakeetSupportDirectory: support
            ),
            equals: false,
            "speech model cache reset should reject symlinked parent directories before deletion"
        )
        try expect(
            isSafeSpeechModelCacheDirectory(speechModelCacheDirectory(for: .productionDefault)),
            equals: true,
            "Parakeet cache path should remain inside SuperDictate Application Support"
        )
        let defaultCache = speechModelCacheDirectory(for: .productionDefault)
        if fm.fileExists(atPath: defaultCache.path) {
            try expect(
                isExistingSpeechModelCacheDirectorySafeForRemoval(defaultCache),
                equals: true,
                "existing Parakeet cache path should remain removable"
            )
        }

        // Exercise the file-leaf case directly: the real Parakeet cache path
        // is a regular file, not a directory (fixed as part of the original
        // Whisper port this inherited from —
        // isExistingSpeechModelCacheDirectorySafeForRemoval previously walked
        // every path component, including the leaf, through
        // isExistingPlainDirectory, which meant it could never return true
        // for a file-shaped cache target and removeSpeechModelCacheDirectory
        // would permanently refuse to remove the cached model).
        let fileLeafCache = support.appendingPathComponent("Models/parakeet-file-leaf.gguf", isDirectory: false)
        try fm.createDirectory(at: fileLeafCache.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try Data("fake model bytes".utf8).write(to: fileLeafCache)
        try expect(
            isExistingSpeechModelCacheDirectorySafeForRemoval(fileLeafCache,
                                                             parakeetSupportDirectory: support),
            equals: true,
            "speech model cache reset should allow removing a file-shaped cache leaf"
        )
    }

    private static func testUpdate() throws {
        try testUpdateCheckParsing()
        try testUpdateCheckState()
        try testDirectUpdateManifest()
        try testUpdateHelperScript()
        try testDirectUpdateReplacement()
        try testUpdateProgressState()
    }

    private static func testDirectUpdateManifest() throws {
        let checksum = String(repeating: "a", count: 64)
        let validData = Data("{\"version\":\"9.8.7\",\"sha256\":\"\(checksum)\"}".utf8)
        try expect(
            try SuperDictateUpdateInstaller.parseManifest(validData,
                                                           expectedVersion: "9.8.7"),
            equals: SuperDictateUpdateManifest(version: "9.8.7", sha256: checksum),
            "direct update manifest should parse a canonical version and SHA-256"
        )

        do {
            _ = try SuperDictateUpdateInstaller.parseManifest(validData,
                                                               expectedVersion: "9.8.8")
            throw SelfTestFailure.failed("direct update manifest should reject version disagreement")
        } catch let error as SuperDictateUpdateInstallerError {
            try expect(error,
                       equals: .manifestVersionMismatch(expected: "9.8.8", actual: "9.8.7"),
                       "direct update manifest should describe version disagreement")
        }

        let invalidChecksum = Data(#"{"version":"9.8.7","sha256":"not-a-checksum"}"#.utf8)
        do {
            _ = try SuperDictateUpdateInstaller.parseManifest(invalidChecksum,
                                                               expectedVersion: "9.8.7")
            throw SelfTestFailure.failed("direct update manifest should reject malformed checksums")
        } catch let error as SuperDictateUpdateInstallerError {
            try expect(error, equals: .invalidManifest,
                       "direct update manifest should reject malformed checksums")
        }
    }

    private static func testUpdateCheckParsing() throws {
        let ok = HTTPURLResponse(url: GITHUB_LATEST_RELEASE_URL,
                                 statusCode: 200,
                                 httpVersion: nil,
                                 headerFields: nil)!
        let notFound = HTTPURLResponse(url: GITHUB_LATEST_RELEASE_URL,
                                       statusCode: 404,
                                       httpVersion: nil,
                                       headerFields: nil)!
        let releaseData = Data(
            #"{"tag_name":"v9.8.7","body":"Notes","html_url":"https://github.com/shohart/SuperDictate-Next/releases/tag/v9.8.7"}"#.utf8
        )

        try expect(
            UpdateCheck.parseLatest(data: releaseData, response: ok),
            equals: .success(GitHubRelease(tagName: "v9.8.7",
                                           version: "9.8.7",
                                           body: "Notes",
                                           htmlURL: "https://github.com/shohart/SuperDictate-Next/releases/tag/v9.8.7")),
            "update parsing should decode typed GitHub release payloads"
        )
        try expect(
            UpdateCheck.parseLatest(data: releaseData, response: notFound),
            equals: .failure(.httpStatus(404)),
            "update parsing should reject non-2xx HTTP responses with the status code"
        )
        let rateLimited = HTTPURLResponse(url: GITHUB_LATEST_RELEASE_URL,
                                          statusCode: 403,
                                          httpVersion: nil,
                                          headerFields: nil)!
        try expect(
            UpdateCheck.parseLatest(data: releaseData, response: rateLimited),
            equals: .failure(.httpStatus(403)),
            "update parsing should surface HTTP 403 distinctly (GitHub rate limiting)"
        )
        let oversizedReleaseData = Data(
            """
            {"tag_name":"v9.8.7","body":"\(String(repeating: "x", count: UpdateCheck.maxReleaseResponseBytes))","html_url":"https://github.com/shohart/SuperDictate-Next/releases/tag/v9.8.7"}
            """.utf8
        )
        try expect(
            oversizedReleaseData.count > UpdateCheck.maxReleaseResponseBytes,
            equals: true,
            "oversized release response fixture should exceed the parser limit"
        )
        try expect(
            UpdateCheck.parseLatest(data: oversizedReleaseData, response: ok),
            equals: .failure(.unexpectedResponse),
            "update parsing should reject oversized release responses before decoding"
        )
        try expect(
            UpdateCheck.parseLatest(data: Data(#"{"tag_name":""}"#.utf8), response: ok),
            equals: .failure(.unexpectedResponse),
            "update parsing should reject empty release tags"
        )
        try expect(
            UpdateCheck.parseLatest(data: Data(#"{"tag_name":"latest"}"#.utf8), response: ok),
            equals: .failure(.unexpectedResponse),
            "update parsing should reject non-version release tags"
        )
        try expect(
            UpdateCheck.parseLatest(data: Data(#"{"tag_name":"v01.2.3"}"#.utf8), response: ok),
            equals: .failure(.unexpectedResponse),
            "update parsing should reject non-normal semver tags"
        )
        try expect(
            UpdateCheck.parseLatest(
                data: Data(#"{"tag_name":"v999999999999999999999999.2.3"}"#.utf8),
                response: ok
            ),
            equals: .failure(.unexpectedResponse),
            "update parsing should reject oversized numeric version parts"
        )
        try expect(
            parseSemver("999999999999999999999999.2.3"),
            equals: [Int.max, 2, 3],
            "tolerant version parsing should not overflow on oversized components"
        )
        try expect(
            normalizedSkippedUpdateVersions([
                "junk",
                "v1.2.3",
                "1.2.3",
                " V2.0.0\n",
                "01.2.3",
                "3.999999999999999999999999.0"
            ]),
            equals: ["1.2.3", "2.0.0"],
            "skipped update versions should normalize valid versions and discard malformed entries"
        )
        try expect(
            normalizedSkippedUpdateVersions((0..<(MAX_SKIPPED_UPDATE_VERSIONS + 3)).map { "1.0.\($0)" }),
            equals: (3..<(MAX_SKIPPED_UPDATE_VERSIONS + 3)).map { "1.0.\($0)" },
            "skipped update versions should keep only the most recent bounded entries"
        )
        try expect(
            UpdateCheck.parseLatest(
                data: Data(#"{"tag_name":"9.8.7","html_url":"https://example.test/v9.8.7"}"#.utf8),
                response: ok
            ),
            equals: .success(GitHubRelease(tagName: "9.8.7",
                                           version: "9.8.7",
                                           body: "",
                                           htmlURL: GITHUB_RELEASES_PAGE.absoluteString)),
            "update parsing should fall back from non-project release URLs"
        )
        try expect(
            UpdateCheck.parseLatest(
                data: Data(#"{"tag_name":"v9.8.7","html_url":"https://github.com/shohart/SuperDictate-Next/releases/tag/v9.8.8"}"#.utf8),
                response: ok
            ),
            equals: .success(GitHubRelease(tagName: "v9.8.7",
                                           version: "9.8.7",
                                           body: "",
                                           htmlURL: GITHUB_RELEASES_PAGE.absoluteString)),
            "update parsing should fall back when release URL tag does not match the payload tag"
        )
        // Manual-check alert copy: each failure kind gets its own
        // explanation instead of blaming the network for everything.
        try expect(
            manualUpdateCheckFailureText(.network).contains("internet connection"),
            equals: true,
            "network failure text should point at connectivity"
        )
        try expect(
            manualUpdateCheckFailureText(.httpStatus(403)).contains("rate limiting"),
            equals: true,
            "HTTP 403 failure text should mention rate limiting"
        )
        try expect(
            manualUpdateCheckFailureText(.httpStatus(500)).contains("HTTP 500"),
            equals: true,
            "HTTP failure text should include the status code"
        )
        try expect(
            manualUpdateCheckFailureText(.unexpectedResponse).contains("couldn't read"),
            equals: true,
            "unexpected-response failure text should describe an unreadable response"
        )
        try expect(
            UpdateCheck.normalizedReleaseVersion(from: " V1.2.3\n"),
            equals: "1.2.3",
            "release version normalization should allow one leading v"
        )
        try expect(
            normalizedStoredAppVersion(" v2.3.4\n"),
            equals: "2.3.4",
            "stored app version normalization should canonicalize release-style versions"
        )
        try expect(
            normalizedStoredAppVersion("2.3"),
            equals: nil,
            "stored app version normalization should reject incomplete versions"
        )
        try expect(
            normalizedStoredAppVersion("v999999999999999999999999.2.3"),
            equals: nil,
            "stored app version normalization should reject oversized numeric components"
        )
        try expect(
            UpdateCheck.sanitizedReleaseURL("http://github.com/shohart/SuperDictate-Next/releases/tag/v9.8.7",
                                            expectedTag: "v9.8.7"),
            equals: GITHUB_RELEASES_PAGE.absoluteString,
            "release URL sanitizing should require HTTPS"
        )
        try expect(
            UpdateCheck.sanitizedReleaseURL("https://user@github.com/shohart/SuperDictate-Next/releases/tag/v9.8.7",
                                            expectedTag: "v9.8.7"),
            equals: GITHUB_RELEASES_PAGE.absoluteString,
            "release URL sanitizing should reject userinfo"
        )
        try expect(
            UpdateCheck.sanitizedReleaseURL("https://github.com/shohart/SuperDictate-Next/releases/tag/v9.8.7?download=1",
                                            expectedTag: "v9.8.7"),
            equals: GITHUB_RELEASES_PAGE.absoluteString,
            "release URL sanitizing should reject query strings"
        )
    }

    private static func testUpdateCheckState() throws {
        let release = GitHubRelease(tagName: "v1.2.4",
                                    version: "1.2.4",
                                    body: "",
                                    htmlURL: GITHUB_RELEASES_PAGE.absoluteString)
        try expect(
            updateCheckResult(for: nil, currentVersion: "1.2.3", skippedVersions: []),
            equals: .failed,
            "nil update checks should be recorded as failed or unavailable"
        )
        try expect(
            updateCheckResult(for: release, currentVersion: "1.2.4", skippedVersions: []),
            equals: .upToDate,
            "equal release versions should be recorded as up to date"
        )
        try expect(
            updateCheckResult(for: release, currentVersion: "1.2.3", skippedVersions: []),
            equals: .available,
            "newer releases should be recorded as available"
        )
        try expect(
            updateCheckResult(for: release, currentVersion: "1.2.3", skippedVersions: ["1.2.4"]),
            equals: .skipped,
            "skipped newer releases should be recorded distinctly"
        )

        let now = Date(timeIntervalSince1970: 1_000)
        try expect(
            shouldSuppressUpdateForReminder(version: "1.2.4",
                                            reminderVersion: "1.2.4",
                                            reminderUntil: now.addingTimeInterval(60),
                                            now: now),
            equals: true,
            "active reminders should suppress the matching update version"
        )
        try expect(
            shouldSuppressUpdateForReminder(version: "1.2.5",
                                            reminderVersion: "1.2.4",
                                            reminderUntil: now.addingTimeInterval(60),
                                            now: now),
            equals: false,
            "reminders should not suppress newer versions"
        )
        try expect(
            shouldSuppressUpdateForReminder(version: "1.2.4",
                                            reminderVersion: "1.2.4",
                                            reminderUntil: now.addingTimeInterval(-1),
                                            now: now),
            equals: false,
            "expired reminders should not suppress updates"
        )
        try expect(
            updateCheckDiagnosticText(checkedAt: nil,
                                      source: nil,
                                      result: nil,
                                      releaseVersion: ""),
            equals: "never",
            "missing update-check metadata should render as never"
        )

        // Stale-pause clearing: equal version (expired pause about to
        // be re-shown) and a newer superseding release both clear; an
        // older fetched version or no pause leaves things alone.
        try expect(
            shouldClearUpdateReminderPause(fetchedVersion: "1.2.4", pausedVersion: "1.2.4"),
            equals: true,
            "a fetched release matching the paused version should clear the pause"
        )
        try expect(
            shouldClearUpdateReminderPause(fetchedVersion: "1.2.5", pausedVersion: "1.2.4"),
            equals: true,
            "a newer fetched release should clear a stale pause for the superseded version"
        )
        try expect(
            shouldClearUpdateReminderPause(fetchedVersion: "1.2.3", pausedVersion: "1.2.4"),
            equals: false,
            "an older fetched release should keep the existing pause"
        )
        try expect(
            shouldClearUpdateReminderPause(fetchedVersion: "1.2.4", pausedVersion: nil),
            equals: false,
            "no pause means nothing to clear"
        )

        // Persisted pause expiry validation, mirroring the
        // lastUpdateCheck* pattern: corrupt → nil, in-range round-trip,
        // cleared/missing → nil.
        let pauseNow = Date(timeIntervalSince1970: 2_000)
        let validPauseUntil = pauseNow.addingTimeInterval(UPDATE_REMIND_LATER_SECONDS)
        try expect(
            normalizedUpdateReminderPauseExpiry(storedValue: validPauseUntil, now: pauseNow),
            equals: validPauseUntil,
            "a stored pause expiry inside the pause window should round-trip"
        )
        try expect(
            normalizedUpdateReminderPauseExpiry(storedValue: pauseNow.addingTimeInterval(-60), now: pauseNow),
            equals: pauseNow.addingTimeInterval(-60),
            "an already-expired stored pause expiry is legitimate state and should round-trip"
        )
        try expect(
            normalizedUpdateReminderPauseExpiry(storedValue: "not a date", now: pauseNow),
            equals: nil,
            "a corrupt (non-Date) stored pause expiry should degrade to nil"
        )
        try expect(
            normalizedUpdateReminderPauseExpiry(storedValue: nil, now: pauseNow),
            equals: nil,
            "a cleared pause expiry should read back as nil"
        )
        try expect(
            normalizedUpdateReminderPauseExpiry(
                storedValue: pauseNow.addingTimeInterval(UPDATE_REMIND_LATER_SECONDS + 60),
                now: pauseNow
            ),
            equals: nil,
            "an out-of-range future pause expiry should degrade to nil instead of suppressing indefinitely"
        )
        // The paused-version half persists through the same validated
        // app-version normalization tested in testUpdateCheckParsing
        // (normalizedStoredAppVersion: corrupt → nil, round-trip).

        try expect(
            UpdateCheckSource(rawValue: "settings_toggle"),
            equals: .settingsToggle,
            "settings-toggle update checks should round-trip through their persisted raw value"
        )
        try expect(
            UpdateCheckSource.settingsToggle.diagnosticLabel,
            equals: "settings toggle",
            "settings-toggle update checks should label themselves distinctly in diagnostics"
        )
    }

    private static func testUpdateHelperScript() throws {
        try expect(
            shellSingleQuoted("a'b"),
            equals: "'a'\"'\"'b'",
            "shell quoting should preserve embedded single quotes"
        )
        try expect(
            (UPDATE_HELPER_LOG_PATH as NSString).deletingLastPathComponent,
            equals: (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs"),
            "update helper log should live in the user's log directory"
        )
        let updateEnv = updateProcessEnvironment(current: [
            "LANG": "C\nbad",
            "USER": "parakey-user",
            "LOGNAME": "parakey-logname",
            "__CF_USER_TEXT_ENCODING": "0x1F5:0x0:0x0",
            "BASH_ENV": "/tmp/pwn.sh",
            "ENV": "/tmp/pwn.sh",
            "SHELLOPTS": "xtrace",
            "RUBYOPT": "-r/tmp/pwn.rb",
            "HOMEBREW_BOTTLE_DOMAIN": "https://example.test",
        ])
        try expect(updateEnv["HOME"], equals: Optional(NSHomeDirectory()),
                   "update environment should set HOME explicitly")
        try expect(updateEnv["PATH"],
                   equals: Optional("/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"),
                   "update environment should use a deterministic PATH")
        try expect(updateEnv["LANG"], equals: Optional("en_US.UTF-8"),
                   "update environment should reject unsafe locale values")
        try expect(updateEnv["USER"], equals: Optional("parakey-user"),
                   "update environment should preserve a safe USER value")
        try expect(updateEnv["LOGNAME"], equals: Optional("parakey-logname"),
                   "update environment should preserve a safe LOGNAME value")
        for key in ["BASH_ENV", "ENV", "SHELLOPTS", "RUBYOPT", "HOMEBREW_BOTTLE_DOMAIN"] {
            try expect(updateEnv[key], equals: String?.none,
                       "update environment should not inherit \(key)")
        }
        let systemEnv = systemToolProcessEnvironment(current: [
            "LANG": "en_GB.UTF-8",
            "USER": "parakey-user",
            "BASH_ENV": "/tmp/pwn.sh",
            "DYLD_INSERT_LIBRARIES": "/tmp/pwn.dylib",
            "PATH": "/tmp/bin",
        ])
        try expect(systemEnv["PATH"], equals: Optional("/usr/bin:/bin:/usr/sbin:/sbin"),
                   "system tool environment should not include Homebrew or inherited PATH entries")
        try expect(systemEnv["LANG"], equals: Optional("en_GB.UTF-8"),
                   "system tool environment should preserve a safe locale")
        try expect(systemEnv["USER"], equals: Optional("parakey-user"),
                   "system tool environment should preserve a safe USER value")
        for key in ["BASH_ENV", "DYLD_INSERT_LIBRARIES"] {
            try expect(systemEnv[key], equals: String?.none,
                       "system tool environment should not inherit \(key)")
        }

        let script = updateHelperScript(pid: 123,
                                        brewPath: "/opt/homebrew/bin/brew",
                                        targetVersion: "9.8.7",
                                        statePath: "/tmp/parakey-update.state",
                                        appPath: "/Applications/SuperDictate.app",
                                        releasesPageURL: "https://example.test/releases")
        for fragment in [
            "umask 077",
            "TARGET_VERSION='9.8.7'",
            "STATE_PATH='/tmp/parakey-update.state'",
            "PARAKEY_PID=123",
            "SCRIPT_PATH=\"$0\"",
            "trap cleanup EXIT",
            "/bin/rm -f \"$SCRIPT_PATH\"",
            "printf '[%s] %s\\n' \"$(timestamp)\" \"$*\"",
            "printf '%s\\t%s\\n' \"$phase\" \"$message\" >\"$tmp\"",
            "CASK_TAP='shlgd/superdictate'",
            "CASK_TOKEN='shlgd/superdictate/superdictate'",
            "CASK_INSTALLED_TOKEN='parakey'",
            "PlistBuddy -c \"Print :CFBundleShortVersionString\"",
            "version_at_least \"$installed\" \"$TARGET_VERSION\"",
            "state \"preparing\" \"Preparing Homebrew for Parakey v$TARGET_VERSION...\"",
            "state \"downloading\" \"Downloading Parakey v$TARGET_VERSION...\"",
            "state \"installing\" \"Installing Parakey v$TARGET_VERSION...\"",
            "run_brew tap \"$CASK_TAP\"",
            "run_brew update --force",
            "run_brew fetch --cask --force \"$CASK_TOKEN\"",
            "run_brew upgrade --cask --force --appdir=\"$APP_DIR\" \"$CASK_TOKEN\"",
            "run_brew reinstall --cask --force --appdir=\"$APP_DIR\" \"$CASK_TOKEN\"",
            "installed_target_version",
            "sleep 2",
            "state \"complete\" \"Parakey v$TARGET_VERSION is installed.\"",
            "/usr/bin/open \"$APP_PATH\""
        ] {
            guard script.contains(fragment) else {
                throw SelfTestFailure.failed("update helper script missing fragment: \(fragment)")
            }
        }
        for fragment in ["LOG=", ">>\"$LOG\"", ">\"$LOG\"", "prepare_log"] {
            guard !script.contains(fragment) else {
                throw SelfTestFailure.failed("update helper script should not reopen a log path: \(fragment)")
            }
        }

        let directScript = superDictateDirectUpdateHelperScript(
            pid: 123,
            targetVersion: "9.8.7",
            statePath: "/tmp/superdictate-update.state",
            stagedAppPath: "/tmp/work/release/SuperDictate.app",
            workDirectory: "/tmp/work",
            backupAppPath: "/Applications/.SuperDictate-update-backup-test.app",
            appPath: "/Applications/SuperDictate.app",
            language: .english
        )
        for fragment in [
            "PANEL_PID=123",
            "TARGET_VERSION='9.8.7'",
            "STAGED_APP='/tmp/work/release/SuperDictate.app'",
            "BACKUP_APP='/Applications/.SuperDictate-update-backup-test.app'",
            "wait_for_panel_exit || rollback",
            "launchctl bootout \"$SERVICE\"",
            "/bin/mv \"$APP_PATH\" \"$BACKUP_APP\" || rollback",
            "/usr/bin/ditto \"$STAGED_APP\" \"$APP_PATH\" || rollback",
            "/usr/bin/codesign --verify --deep --strict \"$APP_PATH\"",
            "if [ -d \"$BACKUP_APP\" ]; then",
            "state \"complete\" 'SuperDictate Next v9.8.7 is installed.'",
        ] {
            guard directScript.contains(fragment) else {
                throw SelfTestFailure.failed("direct update helper missing fragment: \(fragment)")
            }
        }
        let directTmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("superdictate-direct-update-self-test-\(UUID().uuidString).sh")
        try directScript.write(to: directTmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: directTmp) }
        let directProc = Process()
        directProc.executableURL = URL(fileURLWithPath: "/bin/bash")
        directProc.arguments = ["-n", directTmp.path]
        directProc.standardOutput = Pipe()
        directProc.standardError = Pipe()
        try directProc.run()
        directProc.waitUntilExit()
        guard directProc.terminationStatus == 0 else {
            throw SelfTestFailure.failed("direct update helper script should pass bash -n")
        }

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parakey-update-self-test-\(UUID().uuidString).sh")
        try script.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-n", tmp.path]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw SelfTestFailure.failed("update helper script should pass bash -n")
        }

        let fm = FileManager.default
        let helperRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parakey-update-helper-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: helperRoot, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: helperRoot) }

        let helperPath = try writePrivateUpdateHelperScript(script,
                                                            directory: helperRoot.path,
                                                            fileName: "helper.sh")
        var createdStat = stat()
        guard lstat(helperPath, &createdStat) == 0 else {
            throw SelfTestFailure.failed("update helper script file should exist")
        }
        try expect((createdStat.st_mode & S_IFMT) == S_IFREG,
                   equals: true,
                   "update helper script should be a regular file")
        try expect(Int(createdStat.st_mode & mode_t(0o777)),
                   equals: 0o600,
                   "update helper script should be private to the current user")
        try expect(Int(createdStat.st_nlink),
                   equals: 1,
                   "update helper script should not be hard-linked")
        try expect(
            String(data: try Data(contentsOf: URL(fileURLWithPath: helperPath)), encoding: .utf8),
            equals: script,
            "update helper script file should contain the generated script"
        )

        let existing = helperRoot.appendingPathComponent("existing.sh")
        try Data("existing\n".utf8).write(to: existing)
        var existingRejected = false
        do {
            _ = try writePrivateUpdateHelperScript("bad",
                                                   directory: helperRoot.path,
                                                   fileName: "existing.sh")
        } catch {
            existingRejected = true
        }
        try expect(existingRejected, equals: true,
                   "update helper script writer should reject existing files")
        try expect(
            String(data: try Data(contentsOf: existing), encoding: .utf8),
            equals: "existing\n",
            "update helper script writer should leave existing files untouched"
        )

        let target = helperRoot.appendingPathComponent("target.sh")
        try Data("target\n".utf8).write(to: target)
        let link = helperRoot.appendingPathComponent("linked.sh")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        var symlinkRejected = false
        do {
            _ = try writePrivateUpdateHelperScript("bad",
                                                   directory: helperRoot.path,
                                                   fileName: "linked.sh")
        } catch {
            symlinkRejected = true
        }
        try expect(symlinkRejected, equals: true,
                   "update helper script writer should reject leaf symlinks")
        try expect(
            String(data: try Data(contentsOf: target), encoding: .utf8),
            equals: "target\n",
            "update helper script writer should leave symlink targets untouched"
        )

        let preferredLog = helperRoot.appendingPathComponent("SuperDictate-update.log")
        let helperLog = try openPrivateUpdateHelperLog(preferredPath: preferredLog.path,
                                                       fallbackDirectory: helperRoot.path)
        helperLog.handle.write(Data("log\n".utf8))
        helperLog.handle.closeFile()
        try expect(helperLog.path, equals: preferredLog.path,
                   "update helper log should use the preferred path when safe")
        var logStat = stat()
        guard lstat(preferredLog.path, &logStat) == 0 else {
            throw SelfTestFailure.failed("update helper log file should exist")
        }
        try expect((logStat.st_mode & S_IFMT) == S_IFREG,
                   equals: true,
                   "update helper log should be a regular file")
        try expect(Int(logStat.st_mode & mode_t(0o777)),
                   equals: 0o600,
                   "update helper log should be private to the current user")
        try expect(Int(logStat.st_nlink),
                   equals: 1,
                   "update helper log should not be hard-linked")
        try expect(
            String(data: try Data(contentsOf: preferredLog), encoding: .utf8),
            equals: "log\n",
            "update helper log should receive helper output"
        )

        let linkedLogTarget = helperRoot.appendingPathComponent("linked-log-target.log")
        try Data("target log\n".utf8).write(to: linkedLogTarget)
        let linkedLog = helperRoot.appendingPathComponent("linked-log.log")
        try fm.createSymbolicLink(at: linkedLog, withDestinationURL: linkedLogTarget)
        let fallbackForSymlink = try openPrivateUpdateHelperLog(preferredPath: linkedLog.path,
                                                                fallbackDirectory: helperRoot.path)
        fallbackForSymlink.handle.write(Data("fallback\n".utf8))
        fallbackForSymlink.handle.closeFile()
        try expect(fallbackForSymlink.path == linkedLog.path,
                   equals: false,
                   "update helper log should fall back when preferred path is a symlink")
        try expect(
            String(data: try Data(contentsOf: linkedLogTarget), encoding: .utf8),
            equals: "target log\n",
            "update helper log fallback should leave symlink targets untouched"
        )

        let hardLogTarget = helperRoot.appendingPathComponent("hard-log-target.log")
        try Data("hard target\n".utf8).write(to: hardLogTarget)
        let hardLog = helperRoot.appendingPathComponent("hard-log.log")
        try fm.linkItem(at: hardLogTarget, to: hardLog)
        let fallbackForHardLink = try openPrivateUpdateHelperLog(preferredPath: hardLog.path,
                                                                 fallbackDirectory: helperRoot.path)
        fallbackForHardLink.handle.write(Data("hard fallback\n".utf8))
        fallbackForHardLink.handle.closeFile()
        try expect(fallbackForHardLink.path == hardLog.path,
                   equals: false,
                   "update helper log should fall back when preferred path is hard-linked")
        try expect(
            String(data: try Data(contentsOf: hardLogTarget), encoding: .utf8),
            equals: "hard target\n",
            "update helper log fallback should leave hard-linked targets untouched"
        )
    }

    private static func testDirectUpdateReplacement() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("superdictate-update-replacement-test-\(UUID().uuidString)",
                                    isDirectory: true)
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let currentApp = applications.appendingPathComponent("SuperDictate.app", isDirectory: true)
        let workDirectory = root.appendingPathComponent("work", isDirectory: true)
        let stagedApp = workDirectory
            .appendingPathComponent("release", isDirectory: true)
            .appendingPathComponent("SuperDictate.app", isDirectory: true)
        let backupApp = applications.appendingPathComponent(".SuperDictate-update-backup.app",
                                                             isDirectory: true)
        let statePath = root.appendingPathComponent("state.txt")
        let helperPath = root.appendingPathComponent("helper.sh")
        try fileManager.createDirectory(at: applications, withIntermediateDirectories: true)
        try makeSyntheticSignedUpdateApp(at: currentApp, version: "1.0.0")
        try makeSyntheticSignedUpdateApp(at: stagedApp, version: "9.8.7")
        try Data("starting\tStarting update…\n".utf8).write(to: statePath)
        defer { try? fileManager.removeItem(at: root) }

        let script = superDictateDirectUpdateHelperScript(
            pid: Int32.max,
            targetVersion: "9.8.7",
            statePath: statePath.path,
            stagedAppPath: stagedApp.path,
            workDirectory: workDirectory.path,
            backupAppPath: backupApp.path,
            appPath: currentApp.path,
            language: .english,
            relaunch: false
        )
        try script.write(to: helperPath, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [helperPath.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let processOutput = String(data: output.fileHandleForReading.readDataToEndOfFile(),
                                   encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw SelfTestFailure.failed("direct update replacement failed: \(processOutput)")
        }

        try SuperDictateUpdateInstaller.validateApp(at: currentApp,
                                                     expectedVersion: "9.8.7")
        try expect(fileManager.fileExists(atPath: backupApp.path), equals: false,
                   "successful direct update should remove its backup")
        try expect(fileManager.fileExists(atPath: workDirectory.path), equals: false,
                   "successful direct update should remove staged files")
        try expect(UpdateProgressState.read(from: statePath.path)?.phase,
                   equals: Optional("complete"),
                   "successful direct update should report completion")
    }

    private static func makeSyntheticSignedUpdateApp(at appURL: URL,
                                                     version: String) throws {
        guard let sourceExecutable = Bundle.main.executableURL else {
            throw SelfTestFailure.failed("self-test executable URL is unavailable")
        }
        let fileManager = FileManager.default
        let executableDirectory = appURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try fileManager.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        let executableURL = executableDirectory.appendingPathComponent("SuperDictate")
        try fileManager.copyItem(at: sourceExecutable, to: executableURL)
        try fileManager.setAttributes([.posixPermissions: 0o755],
                                      ofItemAtPath: executableURL.path)
        let info: [String: Any] = [
            "CFBundleExecutable": "SuperDictate",
            "CFBundleIdentifier": "com.local.superdictate",
            "CFBundleName": "SuperDictate",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": "1",
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info,
                                                          format: .xml,
                                                          options: 0)
        try infoData.write(to: appURL.appendingPathComponent("Contents/Info.plist"))
        let signing = SuperDictateAgentService.run("/usr/bin/codesign",
                                                   ["--force", "--deep", "--sign", "-", appURL.path])
        guard signing.status == 0 else {
            throw SelfTestFailure.failed("could not sign synthetic update app: \(signing.output)")
        }
    }

    private static func testUpdateProgressState() throws {
        let launch = UpdateProgressLaunch(arguments: [
            UPDATE_PROGRESS_ARGUMENT,
            "/tmp/parakey.state",
            "/tmp/parakey.log",
            "9.8.7",
            "/tmp/\(UPDATE_PROGRESS_APP_PREFIX)test.app",
        ])
        try expect(launch != nil, equals: true,
                   "update progress launch arguments should parse")
        try expect(launch?.targetVersion, equals: Optional("9.8.7"),
                   "update progress launch should retain target version")
        try expect(
            UpdateProgressLaunch(arguments: [UPDATE_PROGRESS_ARGUMENT, "", "/tmp/parakey.log", "9.8.7", "/tmp/app"]) != nil,
            equals: false,
            "update progress launch should reject empty paths"
        )

        let statePath = try createPrivateUpdateProgressStateFile()
        defer { try? FileManager.default.removeItem(atPath: statePath) }

        var st = stat()
        guard lstat(statePath, &st) == 0 else {
            throw SelfTestFailure.failed("update progress state file should exist")
        }
        try expect((st.st_mode & S_IFMT) == S_IFREG, equals: true,
                   "update progress state file should be regular")
        try expect(Int(st.st_nlink), equals: 1,
                   "update progress state file should not be hard-linked")
        try expect(Int(st.st_mode & mode_t(0o777)), equals: 0o600,
                   "update progress state file should be private to the current user")

        let initial = UpdateProgressState.read(from: statePath)
        try expect(initial?.phase, equals: Optional("starting"),
                   "update progress state should default to starting")
        try expect(initial?.message, equals: Optional("Starting update..."),
                   "update progress state should default to the startup message")

        try writePrivateUpdateProgressState(phase: "failed\tbad",
                                            message: "Line 1\nLine 2",
                                            to: statePath)
        let failed = UpdateProgressState.read(from: statePath)
        try expect(failed?.phase, equals: Optional("failed bad"),
                   "update progress state should sanitize tab characters in phases")
        try expect(failed?.message, equals: Optional("Line 1 Line 2"),
                   "update progress state should sanitize newlines in messages")

        let safeCleanupPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("\(UPDATE_PROGRESS_APP_PREFIX)test.app")
        try expect(isSafeUpdateProgressCleanupPath(safeCleanupPath), equals: true,
                   "update progress cleanup should allow copied temp app bundles")
        try expect(isSafeUpdateProgressCleanupPath("/Applications/SuperDictate.app"), equals: false,
                   "update progress cleanup should reject non-temp app bundles")
        let unsafeTempPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("Parakey.app")
        try expect(isSafeUpdateProgressCleanupPath(unsafeTempPath), equals: false,
                   "update progress cleanup should reject temp app bundles without the copied-helper prefix")
    }

    private static func testHostileRegistryEnvDetection() throws {
        try expect(
            detectedHostileRegistryEnvVars(in: [:]),
            equals: [],
            "empty environment should not flag any registry override"
        )
        try expect(
            detectedHostileRegistryEnvVars(in: ["HF_TOKEN": "redacted",
                                                "PATH": "/usr/bin"]),
            equals: [],
            "unrelated env vars (incl. HF_TOKEN) must not flag as hostile"
        )
        try expect(
            detectedHostileRegistryEnvVars(in: ["REGISTRY_URL": "https://evil.example/"]),
            equals: ["REGISTRY_URL"],
            "REGISTRY_URL must be flagged"
        )
        try expect(
            detectedHostileRegistryEnvVars(in: ["MODEL_REGISTRY_URL": "https://evil.example/"]),
            equals: ["MODEL_REGISTRY_URL"],
            "MODEL_REGISTRY_URL must be flagged"
        )
        try expect(
            detectedHostileRegistryEnvVars(in: ["REGISTRY_URL": "",
                                                "MODEL_REGISTRY_URL": ""]),
            equals: ["MODEL_REGISTRY_URL", "REGISTRY_URL"],
            "an empty-string value still represents a tampered launch env"
        )
    }

    // MARK: - Sync bridge for actor calls from the (synchronous) self-test runner
    //
    // `ParakeetEngine` is an actor; calling any of its methods from outside
    // requires crossing an isolation boundary, which is always `async` at
    // the call site even for a nominally-synchronous-bodied method. The
    // self-test entry point (`ParakeySelfTest.run`, called from top-level
    // code in this file) is plain synchronous code, so a small
    // semaphore-based bridge is needed to call into the actor and get a
    // result back before returning. Write-then-signal / wait-then-read
    // through the semaphore is the standard safe pattern here: the
    // semaphore itself provides the happens-before relationship, so
    // `@unchecked Sendable` on the box is justified by construction (single
    // writer before signal, single reader after wait).
    private final class ParakeetSyncBridgeBox<T>: @unchecked Sendable {
        var result: Result<T, Error>?
    }

    private static func runParakeetEngineSynchronously<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ParakeetSyncBridgeBox<T>()
        Task {
            do {
                box.result = .success(try await operation())
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        switch box.result! {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    // MARK: - Parakeet transcript repair (spec §13's required test coverage:
    // sentence-initial, mid-word/mid-sentence, punctuation-adjacent, repeated
    // tokens, Russian/auto/non-Russian). `testRecordingLifecycle()` already
    // exercises a few of these cases end-to-end through
    // `processedDictationText`; this group calls `ParakeetTranscriptRepair`
    // directly for focused, addressable coverage of the full matrix.

    private static func testParakeetTranscriptRepair() throws {
        try expect(
            ParakeetTranscriptRepair.apply(to: "<unk>лка стоит в углу.", language: .russian),
            equals: "Ёлка стоит в углу.",
            "sentence-initial <unk> should repair to capitalized Ё for Russian"
        )
        try expect(
            ParakeetTranscriptRepair.apply(to: "Моя л<unk>бимая песня.", language: .russian),
            equals: "Моя лёбимая песня.",
            "mid-word <unk> should repair to lowercase ё"
        )
        try expect(
            ParakeetTranscriptRepair.apply(to: "Привет, <unk>! Как дела?", language: .auto),
            equals: "Привет, ё! Как дела?",
            "punctuation-adjacent <unk> should repair correctly under auto-detect"
        )
        try expect(
            ParakeetTranscriptRepair.apply(to: "<unk> и <unk> и <unk>.", language: .russian),
            equals: "Ё и ё и ё.",
            "repeated <unk> tokens should each repair independently"
        )
        try expect(
            ParakeetTranscriptRepair.apply(to: "Hello <unk> world.", language: .english),
            equals: "Hello world.",
            "non-Russian language should remove <unk> rather than substitute Cyrillic ё"
        )
        try expect(
            ParakeetTranscriptRepair.apply(to: "No unknown tokens here.", language: .russian),
            equals: "No unknown tokens here.",
            "text without <unk> should pass through unchanged (the guard makes this a no-op)"
        )
    }

    // MARK: - Russian number ITN (spec 2026-07-29-clipboard-race-and-number-itn):
    // ported from the plan's XCTest cases into this project's `--self-test`
    // harness, since there is no XCTest target / `Tests/` directory in this
    // package (confirmed via `find swift/Tests` and `grep testTarget
    // Package.swift`, both empty). Same assertions, same inputs/outputs.
    private static func testRussianNumberITNCardinal() throws {
        try expect(RussianNumberNormalizer.normalize("двадцать девять"), equals: "29", "simple tens: двадцать девять")
        try expect(RussianNumberNormalizer.normalize("двадцать пять"), equals: "25", "simple tens: двадцать пять")
        try expect(RussianNumberNormalizer.normalize("двадцать шесть"), equals: "26", "simple tens: двадцать шесть")

        try expect(RussianNumberNormalizer.normalize("пять"), equals: "5", "single digit: пять")
        try expect(RussianNumberNormalizer.normalize("ноль"), equals: "0", "single digit: ноль")

        try expect(RussianNumberNormalizer.normalize("пятнадцать"), equals: "15", "teen: пятнадцать")
        try expect(RussianNumberNormalizer.normalize("девятнадцать"), equals: "19", "teen: девятнадцать")

        try expect(RussianNumberNormalizer.normalize("сто пятьдесят три"), equals: "153", "hundreds and compound: сто пятьдесят три")
        try expect(RussianNumberNormalizer.normalize("девятьсот девяносто девять"), equals: "999", "hundreds and compound: девятьсот девяносто девять")

        try expect(RussianNumberNormalizer.normalize("две тысячи двадцать шесть"), equals: "2026", "thousands: две тысячи двадцать шесть")
        try expect(RussianNumberNormalizer.normalize("один миллион"), equals: "1000000", "millions: один миллион")

        try expect(RussianNumberNormalizer.normalize("привет, как дела?"), equals: "привет, как дела?", "non-number text left unchanged")

        try expect(RussianNumberNormalizer.normalize("мне двадцать пять лет"), equals: "мне 25 лет", "number embedded in sentence preserves surrounding text")

        try expect(RussianNumberNormalizer.normalize("один из способов"), equals: "один из способов", "ambiguous standalone 'один' before 'из' is left unchanged")

        // Regression for a group-boundary bug found while reviewing
        // parseCardinalRun: `break` inside the category `switch` only exits
        // the switch (Swift's break targets the nearest enclosing loop OR
        // switch), so a malformed continuation like a second same-category
        // word used to fall through to `consumed += 1` without contributing
        // to the value — silently eating the second word instead of leaving
        // it for the next parse attempt. Fixed by labeling the `for` loop
        // (`wordLoop:`) and using `break wordLoop`/`continue wordLoop`
        // explicitly, so a malformed continuation stops the run without
        // consuming the offending word.
        try expect(RussianNumberNormalizer.normalize("пять шесть"), equals: "5 6", "two standalone single-digit numbers in a row must not merge or drop a word")
    }

    private static func testRussianNumberITNOrdinal() throws {
        try expect(RussianNumberNormalizer.normalize("пятый"), equals: "5-й", "simple ordinal: пятый")
        try expect(RussianNumberNormalizer.normalize("третий"), equals: "3-й", "simple ordinal: третий")

        try expect(RussianNumberNormalizer.normalize("двадцать пятый"), equals: "25-й", "compound ordinal masc nom: двадцать пятый")
        try expect(RussianNumberNormalizer.normalize("двадцать пятого"), equals: "25-го", "compound ordinal gen: двадцать пятого")
        try expect(RussianNumberNormalizer.normalize("двадцать пятое"), equals: "25-е", "compound ordinal neut nom: двадцать пятое")

        try expect(RussianNumberNormalizer.normalize("это был двадцать пятый раз"), equals: "это был 25-й раз", "ordinal embedded in sentence preserves surrounding text")

        // Regression: ordinalWordSuffixes originally only covered 1-10, 20,
        // 30 as given in the plan's literal table, leaving 11-19, 40-90 and
        // 100 unconvertible — a teen-day ordinal ("одиннадцатое") is neither
        // a recognized ordinal wordform nor a cardinal wordform (the
        // cardinal table has "одиннадцать", not "одиннадцатое"), so it fell
        // straight through unchanged. That silently broke roughly a third
        // of calendar days for the plan's own flagship date example. Also
        // covers the one irregular stem in the run: 40 is "сороковой"
        // (-ой), not the regular "-ый" pattern every other decade uses.
        try expect(RussianNumberNormalizer.normalize("одиннадцатое июля две тысячи двадцать шестого года"), equals: "11-е июля 2026-го года", "teen-day ordinal (11-19) in a date")
        try expect(RussianNumberNormalizer.normalize("сороковой день"), equals: "40-й день", "irregular ordinal stem 40: сороковой")
        try expect(RussianNumberNormalizer.normalize("сотый раз"), equals: "100-й раз", "ordinal 100: сотый")

        // Regression (code review finding): parseOrdinalRun used to try
        // every prefix length from the end of the ENTIRE remaining
        // document down to zero, merging the first (longest) cardinal
        // prefix that happened to be followed by any recognized ordinal
        // wordform — with no check that the ordinal actually completes
        // THAT cardinal run rather than starting an unrelated one.
        // "сто двадцать пять" is already a complete number (125; its
        // units slot is filled by "пять"), so a further ordinal
        // "первого" (a unit-level ordinal, "1st") must NOT merge into it
        // — that produced a fabricated "126-го" ("one hundred twenty six,
        // -го") which does not correspond to anything the speaker said.
        // Fixed by requiring the ordinal's category to be a legal
        // continuation of the cardinal run's last category (the same
        // rule that already stops "пять шесть" from merging into one
        // cardinal) rather than accepting any adjacent ordinal wordform.
        try expect(
            RussianNumberNormalizer.normalize("сто двадцать пять первого"),
            equals: "125 1-го",
            "a complete cardinal (125) followed by an unrelated ordinal (1st) must not fuse into a fabricated value"
        )
    }

    private static func testRussianNumberITNContext() throws {
        // Date/money phrases are not special-cased: they fall out of the
        // existing cardinal/ordinal parsing because context words like
        // "года"/"июля"/"рублей" were deliberately never added to
        // numberWordValues or ordinalWordSuffixes, so they pass through
        // normalize(_:) unchanged via the "not a recognized number word"
        // fallback. Diagnosed per the plan's Task B3 Step 3: hand-traced
        // each case against parseCardinalRun/parseOrdinalRun and confirmed
        // no stray context word was added to either table and no
        // group-boundary bug is exercised here beyond the one already
        // fixed in Task B1 (see the "пять шесть" regression test above).
        try expect(
            RussianNumberNormalizer.normalize("двадцать девятое июля две тысячи двадцать шестого года"),
            equals: "29-е июля 2026-го года",
            "date: ordinal day + cardinal year, context words untouched"
        )
        try expect(RussianNumberNormalizer.normalize("пятьсот рублей"), equals: "500 рублей", "money phrase: пятьсот рублей")
        try expect(RussianNumberNormalizer.normalize("сто долларов"), equals: "100 долларов", "money phrase: сто долларов")
        try expect(
            RussianNumberNormalizer.normalize("это стоит две тысячи пятьсот рублей"),
            equals: "это стоит 2500 рублей",
            "money amount with compound cardinal number"
        )
    }

    private static func testRussianNumberITNPunctuation() throws {
        // Spoken "точка"/"двоеточие"/"запятая" convert to symbols only when
        // a number sits on both sides (an IP-style address, a time, a
        // decimal) -- never as an ordinary word. Parakeet also routinely
        // inserts a stray comma at the pause right before the spoken
        // punctuation word ("168, точка, 1"); that artifact comma must be
        // absorbed, not left dangling next to the converted symbol.
        try expect(
            RussianNumberNormalizer.normalize("19 точка 168 точка 1 точка 122"),
            equals: "19.168.1.122",
            "IP-style address, clean dictation with no stray commas"
        )
        try expect(
            RussianNumberNormalizer.normalize("19, точка, 168, точка, 1, точка, 122, двоеточие, 31, 28"),
            equals: "19.168.1.122:31, 28",
            "IP-style address with a trailing port-like pair, reproducing Parakeet's stray pause-commas around each spoken punctuation word"
        )
        try expect(
            RussianNumberNormalizer.normalize("двадцать пять запятая семь"),
            equals: "25,7",
            "decimal number spelled out as words on both sides of запятая"
        )
        try expect(
            RussianNumberNormalizer.normalize("5 запятая 5 килограмма"),
            equals: "5,5 килограмма",
            "decimal number already in digit form on both sides"
        )
        try expect(
            RussianNumberNormalizer.normalize("5 точка первая"),
            equals: "5.1-я",
            "digit before точка, spelled-out ordinal word after -- hands off to the existing ordinal branch instead of double-processing"
        )
        try expect(
            RussianNumberNormalizer.normalize("это моя точка зрения"),
            equals: "это моя точка зрения",
            "точка as an ordinary word (point of view), no number on either side"
        )
        try expect(
            RussianNumberNormalizer.normalize("я закончил и точка"),
            equals: "я закончил и точка",
            "точка as emphasis at the end of a sentence, no number after it"
        )
        try expect(
            RussianNumberNormalizer.normalize("это точка стиля"),
            equals: "это точка стиля",
            "точка as an ordinary word (matter of style), no number on either side"
        )
        try expect(
            RussianNumberNormalizer.normalize("5 точка зрения"),
            equals: "5 точка зрения",
            "digit before точка but no number after it -- must not convert"
        )
        try expect(
            RussianNumberNormalizer.normalize("122 двоеточие. 31"),
            equals: "122:31",
            "Parakeet's stray pause-artifact is a period after the spoken punctuation word, not just a comma -- must still convert"
        )
        try expect(
            RussianNumberNormalizer.normalize("122. двоеточие 31"),
            equals: "122:31",
            "stray pause-artifact period before the spoken punctuation word -- must still convert"
        )
    }

    private static func testProcessedDictationTextITN() throws {
        let enabled = processedDictationText(
            rawTranscript: "мне двадцать пять лет",
            corrections: [],
            removeFillerWords: false,
            normalizeNumbersToDigits: true,
            language: .russian
        )
        try expect(enabled.text, equals: "мне 25 лет", "processedDictationText should normalize numbers when the flag is on")

        let disabled = processedDictationText(
            rawTranscript: "мне двадцать пять лет",
            corrections: [],
            removeFillerWords: false,
            normalizeNumbersToDigits: false,
            language: .russian
        )
        try expect(disabled.text, equals: "мне двадцать пять лет", "processedDictationText should leave numbers as words when the flag is off")

        let correction = TranscriptCorrection(source: "25 лет", replacement: "25 years old")
        let corrected = processedDictationText(
            rawTranscript: "мне двадцать пять лет",
            corrections: [correction],
            removeFillerWords: false,
            normalizeNumbersToDigits: true,
            language: .russian
        )
        try expect(corrected.text, equals: "мне 25 years old", "ITN should run before user corrections so corrections can match on the digit form")
    }

    // MARK: - Parakeet bridge (spec §18.1 — no large model required)

    private static func testParakeetBridge() throws {
        // Null/invalid-path handling: ParakeetEngine.init checks
        // FileManager existence before ever calling into the native bridge,
        // so this also covers "invalid model path" without needing a live
        // parakeet.cpp context or the ~940MB GGUF.
        var threwModelNotFound = false
        do {
            _ = try ParakeetEngine(
                modelPath: "/nonexistent/path/to/model-\(UUID().uuidString).gguf",
                device: .cpu,
                threadCount: 4
            )
        } catch ParakeetEngineError.modelNotFound {
            threwModelNotFound = true
        }
        try expect(threwModelNotFound, equals: true,
                   "ParakeetEngine should reject a nonexistent model path with .modelNotFound")

        // Requesting Vulkan on a nonexistent model path must fail
        // deterministically and honestly: with NO Vulkan device enumerated
        // (CPU-only build, or a Vulkan-capable build on hardware with no
        // usable GPU), ParakeetEngine.init's cheap registry probe rejects
        // it with .vulkanUnavailable BEFORE even checking the model path —
        // never silently falls back to CPU while claiming GPU. On a build
        // where a Vulkan device IS enumerated (e.g. this fork's real Mac
        // build against the RX 6600), the probe passes and the SAME
        // nonexistent-path guard used above applies instead (.modelNotFound)
        // — the point of this assertion either way is "never silently
        // succeeds/claims GPU for a model path that doesn't exist."
        if parakeetVulkanAvailable() {
            var threwModelNotFoundForVulkan = false
            do {
                _ = try ParakeetEngine(
                    modelPath: "/nonexistent/path/to/model-\(UUID().uuidString).gguf",
                    device: .vulkan,
                    threadCount: 4
                )
            } catch ParakeetEngineError.modelNotFound {
                threwModelNotFoundForVulkan = true
            }
            try expect(threwModelNotFoundForVulkan, equals: true,
                       "a Vulkan-capable build should still reject a nonexistent model path deterministically")
        } else {
            var threwVulkanUnavailable = false
            do {
                _ = try ParakeetEngine(
                    modelPath: "/nonexistent/path/to/model-\(UUID().uuidString).gguf",
                    device: .vulkan,
                    threadCount: 4
                )
            } catch ParakeetEngineError.vulkanUnavailable {
                threwVulkanUnavailable = true
            }
            try expect(threwVulkanUnavailable, equals: true,
                       "requesting Vulkan with no device enumerated should fail deterministically, not silently fall back to CPU")
        }

        // parakeet.cpp's own version string is a native call that needs no
        // loaded model — exercises the bridge/native link itself.
        try expect(
            parakeetRuntimeVersion().isEmpty,
            equals: false,
            "parakeet.cpp runtime version string should be non-empty"
        )

        // Thread-count policy (spec §10): max(2, min(8, active/2)), with a
        // validated SUPERDICTATE_ASR_THREADS override (1...32).
        try expect(
            TranscriptionWorker.resolvedParakeetThreadCount(activeProcessorCount: 4, environmentOverride: nil),
            equals: 2,
            "4 active processors should floor to the minimum of 2 threads"
        )
        try expect(
            TranscriptionWorker.resolvedParakeetThreadCount(activeProcessorCount: 32, environmentOverride: nil),
            equals: 8,
            "a high processor count should cap at the maximum of 8 threads"
        )
        try expect(
            TranscriptionWorker.resolvedParakeetThreadCount(activeProcessorCount: 8, environmentOverride: nil),
            equals: 4,
            "8 active processors should use half (4) within the 2...8 band"
        )
        try expect(
            TranscriptionWorker.resolvedParakeetThreadCount(activeProcessorCount: 8, environmentOverride: "6"),
            equals: 6,
            "a valid SUPERDICTATE_ASR_THREADS override should take precedence over the default policy"
        )
        try expect(
            TranscriptionWorker.resolvedParakeetThreadCount(activeProcessorCount: 8, environmentOverride: "0"),
            equals: 4,
            "an out-of-range (below 1) override should be ignored, falling back to the default"
        )
        try expect(
            TranscriptionWorker.resolvedParakeetThreadCount(activeProcessorCount: 8, environmentOverride: "64"),
            equals: 4,
            "an out-of-range (above 32) override should be ignored, falling back to the default"
        )
        try expect(
            TranscriptionWorker.resolvedParakeetThreadCount(activeProcessorCount: 8, environmentOverride: "not-a-number"),
            equals: 4,
            "a non-numeric override should be ignored, falling back to the default"
        )

        // Model metadata pins (spec §3 / §27) — guards against silent drift
        // of the values recorded in the migration plan/report.
        try expect(PARAKEET_MODEL_SIZE_BYTES, equals: 940_663_680,
                   "pinned Parakeet model size must match the value verified in Phase 2")
        try expect(PARAKEET_MODEL_SHA256, equals: "4d69a4a6683f4f2d952bad794c1357ca6eb628027695b4699c5a9ad4cd07d757",
                   "pinned Parakeet model SHA-256 must match the value verified in Phase 2")
        try expect(PARAKEET_MODEL_FILENAME, equals: "tdt-0.6b-v3-q8_0.gguf",
                   "pinned Parakeet model filename must not drift silently")

        // sd_parakeet_transcribe_with_tokens: NULL out_result -> NULL_ARGUMENT.
        // No live context is needed — this check runs before context/samples
        // are ever inspected, mirroring sd_parakeet_transcribe's own
        // out_result-first ordering.
        var dummySample: Float = 0.1
        let statusNullOutResult = withUnsafeMutablePointer(to: &dummySample) { samplePtr in
            sd_parakeet_transcribe_with_tokens(nil, samplePtr, 1, 16000, nil)
        }
        try expect(statusNullOutResult, equals: SD_PARAKEET_ERR_NULL_ARGUMENT,
                   "sd_parakeet_transcribe_with_tokens with a NULL out_result should return NULL_ARGUMENT")

        // sd_parakeet_transcribe_with_tokens: NULL context -> NULL_ARGUMENT,
        // and the output struct's fields are all cleared (never left
        // uninitialized), matching sd_parakeet_transcribe's contract for
        // SDParakeetResult.
        var tokenResult = SDParakeetTokenResult(
            json: UnsafeMutablePointer(bitPattern: 1), // poison
            total_seconds: 42,
            inference_seconds: 42,
            used_gpu: 1
        )
        let statusNullContext = withUnsafeMutablePointer(to: &dummySample) { samplePtr in
            sd_parakeet_transcribe_with_tokens(nil, samplePtr, 1, 16000, &tokenResult)
        }
        try expect(statusNullContext, equals: SD_PARAKEET_ERR_NULL_ARGUMENT,
                   "sd_parakeet_transcribe_with_tokens with a NULL context should return NULL_ARGUMENT")
        try expect(tokenResult.json == nil, equals: true,
                   "a NULL_ARGUMENT failure must set out_result->json to NULL")
        try expect(tokenResult.total_seconds, equals: 0.0,
                   "a NULL_ARGUMENT failure must zero out_result->total_seconds")
        try expect(tokenResult.inference_seconds, equals: 0.0,
                   "a NULL_ARGUMENT failure must zero out_result->inference_seconds")
        try expect(tokenResult.used_gpu, equals: 0,
                   "a NULL_ARGUMENT failure must zero out_result->used_gpu")

        // sd_parakeet_transcribe_with_tokens: NULL samples -> NULL_ARGUMENT
        // (context stays NULL too, for the same reason documented in
        // testSileroVadBridge — the bridge's guard is a single
        // short-circuiting `!context || !context->native || !samples || ...`,
        // so a fabricated non-NULL context handle would be dereferenced
        // rather than isolating the samples check).
        var tokenResult2 = SDParakeetTokenResult(
            json: UnsafeMutablePointer(bitPattern: 1), total_seconds: 42, inference_seconds: 42, used_gpu: 1
        )
        let statusNullSamples = sd_parakeet_transcribe_with_tokens(nil, nil, 1, 16000, &tokenResult2)
        try expect(statusNullSamples, equals: SD_PARAKEET_ERR_NULL_ARGUMENT,
                   "sd_parakeet_transcribe_with_tokens with NULL samples should return NULL_ARGUMENT")
        try expect(tokenResult2.json == nil, equals: true,
                   "a NULL_ARGUMENT failure must set out_result->json to NULL")

        // sd_parakeet_transcribe_with_tokens: sample_rate == 0 -> NULL_ARGUMENT
        // (grouped with the other NULL-ish argument checks in the bridge's
        // guard, same as sd_parakeet_transcribe).
        var tokenResult3 = SDParakeetTokenResult(
            json: UnsafeMutablePointer(bitPattern: 1), total_seconds: 42, inference_seconds: 42, used_gpu: 1
        )
        let statusZeroSampleRate = withUnsafeMutablePointer(to: &dummySample) { samplePtr in
            sd_parakeet_transcribe_with_tokens(nil, samplePtr, 1, 0, &tokenResult3)
        }
        try expect(statusZeroSampleRate, equals: SD_PARAKEET_ERR_NULL_ARGUMENT,
                   "sd_parakeet_transcribe_with_tokens with sample_rate == 0 should return NULL_ARGUMENT")

        // sd_parakeet_token_result_destroy must be safe (no crash) on NULL.
        sd_parakeet_token_result_destroy(nil)
    }

    /// NULL-argument / invalid-path coverage for the `sd_silero_vad_*` C
    /// bridge (Task 2) — mirrors `testParakeetBridge`'s shape but calls the
    /// C API directly (no Swift-side VAD engine wrapper exists yet; wiring
    /// that up is a later task). No real model is needed for any of these
    /// cases — every one is rejected before (or without ever) touching the
    /// vendored whisper_vad_* implementation. `sample_count == 0` ->
    /// EMPTY_AUDIO is NOT covered here: the bridge's NULL checks
    /// (context/context->native/samples) run before the empty-audio check
    /// (same ordering as sd_parakeet_transcribe's NULL-then-EMPTY_AUDIO
    /// checks), so observing EMPTY_AUDIO specifically requires a live,
    /// successfully-created context — that path is covered by the gated
    /// `silero-vad-real` group instead, alongside the real-model inference
    /// assertions.
    private static func testSileroVadBridge() throws {
        // sd_silero_vad_create: NULL model_path -> NULL_ARGUMENT, and
        // *out_context stays NULL.
        var ctx: OpaquePointer? = OpaquePointer(bitPattern: 1) // poison value
        let statusNullPath = sd_silero_vad_create(nil, &ctx)
        try expect(statusNullPath, equals: SD_SILERO_VAD_ERR_NULL_ARGUMENT,
                   "sd_silero_vad_create with a NULL model_path should return NULL_ARGUMENT")
        try expect(ctx == nil, equals: true,
                   "sd_silero_vad_create must set *out_context to NULL even on a NULL_ARGUMENT failure")

        // sd_silero_vad_create: NULL out_context -> NULL_ARGUMENT (checked
        // before model_path is even read, matching sd_parakeet_create's
        // out_context-first ordering).
        let statusNullOutContext = "/nonexistent/path.bin".withCString { path in
            sd_silero_vad_create(path, nil)
        }
        try expect(statusNullOutContext, equals: SD_SILERO_VAD_ERR_NULL_ARGUMENT,
                   "sd_silero_vad_create with a NULL out_context should return NULL_ARGUMENT")

        // sd_silero_vad_create: nonexistent model path -> MODEL_LOAD_FAILED,
        // *out_context left NULL.
        var ctx2: OpaquePointer? = OpaquePointer(bitPattern: 1) // poison value
        let statusBadPath = "/nonexistent/path/to/silero-vad-\(UUID().uuidString).bin".withCString { path in
            sd_silero_vad_create(path, &ctx2)
        }
        try expect(statusBadPath, equals: SD_SILERO_VAD_ERR_MODEL_LOAD_FAILED,
                   "sd_silero_vad_create with a nonexistent model path should return MODEL_LOAD_FAILED")
        try expect(ctx2 == nil, equals: true,
                   "sd_silero_vad_create must leave *out_context NULL on a load failure")

        // sd_silero_vad_speech_probabilities: NULL context -> NULL_ARGUMENT,
        // and the output pointers are left NULL/zero rather than
        // uninitialized.
        var samples: [Float] = [0.1, 0.2, 0.3]
        var outProbs: UnsafeMutablePointer<Float>? = UnsafeMutablePointer(bitPattern: 1) // poison
        var outCount: UInt64 = 42 // poison
        var outWindow: UInt64 = 42 // poison
        let statusNullContext = samples.withUnsafeMutableBufferPointer { buf in
            sd_silero_vad_speech_probabilities(
                nil, buf.baseAddress, UInt64(buf.count), &outProbs, &outCount, &outWindow
            )
        }
        try expect(statusNullContext, equals: SD_SILERO_VAD_ERR_NULL_ARGUMENT,
                   "sd_silero_vad_speech_probabilities with a NULL context should return NULL_ARGUMENT")
        try expect(outProbs == nil, equals: true,
                   "a NULL_ARGUMENT failure must set *out_probabilities to NULL")
        try expect(outCount, equals: 0,
                   "a NULL_ARGUMENT failure must set *out_count to zero")
        try expect(outWindow, equals: 0,
                   "a NULL_ARGUMENT failure must set *out_window_size_samples to zero")

        // sd_silero_vad_speech_probabilities: NULL samples -> NULL_ARGUMENT.
        //
        // The context argument here is NULL too, and deliberately so: the
        // bridge's guard is a single short-circuiting
        // `!context || !context->native || !samples || ...` (mirroring
        // sd_parakeet_transcribe:247), so ANY non-NULL context value is
        // read as a real SDSileroVadContext and `context->native` is
        // dereferenced before `samples` is ever looked at. Fabricating a
        // plausible-looking handle (e.g. OpaquePointer(bitPattern: 0xdeadbeef))
        // to "isolate" the samples check therefore does not isolate anything
        // — it is simply a wild pointer dereference, and it crashed this
        // very self-test with EXC_BAD_ACCESS at 0x00000000deadbeef. There is
        // no valid non-NULL context obtainable without a real model file, so
        // isolating the individual NULL checks is not possible in this
        // model-free group; the contract this group actually owns is the one
        // the task requires — "a NULL context or NULL samples yields
        // NULL_ARGUMENT, and the out-parameters are cleared, never
        // uninitialized."
        var outProbs2: UnsafeMutablePointer<Float>? = UnsafeMutablePointer(bitPattern: 1)
        var outCount2: UInt64 = 42
        let statusNullSamples = sd_silero_vad_speech_probabilities(
            nil, nil, 3, &outProbs2, &outCount2, nil
        )
        try expect(statusNullSamples, equals: SD_SILERO_VAD_ERR_NULL_ARGUMENT,
                   "sd_silero_vad_speech_probabilities with NULL samples should return NULL_ARGUMENT")
        try expect(outProbs2 == nil, equals: true,
                   "a NULL_ARGUMENT failure must set *out_probabilities to NULL")
        try expect(outCount2, equals: 0,
                   "a NULL_ARGUMENT failure must set *out_count to zero")

        // sd_silero_vad_speech_probabilities: NULL out_probabilities/out_count
        // -> NULL_ARGUMENT (both are required together per the header doc).
        // Same reasoning as above: the context stays NULL rather than a
        // fabricated handle, since any non-NULL value would be dereferenced.
        var dummySample: Float = 0.1
        let statusNullOutProbs = withUnsafeMutablePointer(to: &dummySample) { samplePtr in
            sd_silero_vad_speech_probabilities(nil, samplePtr, 1, nil, &outCount2, nil)
        }
        try expect(statusNullOutProbs, equals: SD_SILERO_VAD_ERR_NULL_ARGUMENT,
                   "sd_silero_vad_speech_probabilities with a NULL out_probabilities should return NULL_ARGUMENT")

        // sd_silero_vad_destroy / sd_silero_vad_free_probabilities /
        // sd_silero_vad_last_error_message must all be safe (no crash) on
        // NULL input.
        sd_silero_vad_destroy(nil)
        sd_silero_vad_free_probabilities(nil)
        let emptyErrorMessage = String(cString: sd_silero_vad_last_error_message(nil))
        try expect(emptyErrorMessage, equals: "",
                   "sd_silero_vad_last_error_message(NULL) should return an empty string, never crash")
    }

    /// Skipped (not failed) unless `SUPERDICTATE_SILERO_VAD_MODEL` points at
    /// a real, already-downloaded Silero VAD ggml model file — mirrors
    /// `testParakeetCPUIntegration`'s gating pattern exactly. Task 1
    /// deliberately left the Silero VAD model-download wiring for a later
    /// task (see upstream-vad/PROVENANCE.md's "Model download wiring: OUT
    /// OF SCOPE" note), so no model is staged on this dev machine yet —
    /// this test is expected to SKIP here and only exercise its real-model
    /// assertions on a machine/CI box that has explicitly staged one via
    /// the env var.
    private static func testSileroVadRealModel() throws {
        guard let modelPath = ProcessInfo.processInfo.environment["SUPERDICTATE_SILERO_VAD_MODEL"],
              FileManager.default.fileExists(atPath: modelPath) else {
            print("SKIP silero-vad-real: SUPERDICTATE_SILERO_VAD_MODEL not set to an existing file")
            return
        }

        var context: OpaquePointer?
        let createStatus = modelPath.withCString { path in
            sd_silero_vad_create(path, &context)
        }
        try expect(createStatus, equals: SD_SILERO_VAD_OK,
                   "sd_silero_vad_create should succeed against a real, staged Silero VAD model")
        guard let liveContext = context else {
            throw SelfTestFailure.failed("sd_silero_vad_create reported OK but *out_context is NULL")
        }
        defer { sd_silero_vad_destroy(liveContext) }

        // sample_count == 0 -> EMPTY_AUDIO, now observable with a real
        // live context (unreachable in the non-gated silero-vad-bridge
        // group — see that test's doc comment).
        var dummySample: Float = 0
        var emptyOutProbs: UnsafeMutablePointer<Float>?
        var emptyOutCount: UInt64 = 0
        let emptyStatus = withUnsafeMutablePointer(to: &dummySample) { samplePtr in
            sd_silero_vad_speech_probabilities(liveContext, samplePtr, 0, &emptyOutProbs, &emptyOutCount, nil)
        }
        try expect(emptyStatus, equals: SD_SILERO_VAD_ERR_EMPTY_AUDIO,
                   "sample_count == 0 against a live context should return EMPTY_AUDIO")
        try expect(emptyOutProbs == nil, equals: true,
                   "an EMPTY_AUDIO failure must leave *out_probabilities NULL")

        // 2 seconds of alternating silence/tone at 16kHz — a short
        // synthetic buffer built the same way testParakeetCPUIntegration
        // builds its own (no bundled speech fixture needed): 0.5s silence,
        // 0.5s of a 440Hz tone, repeated once.
        let sampleRate = SAMPLE_RATE
        func toneBlock(seconds: Double, frequency: Double, amplitude: Float) -> [Float] {
            let count = Int(seconds * sampleRate)
            return (0..<count).map { i in
                amplitude * Float(sin(2.0 * Double.pi * frequency * Double(i) / sampleRate))
            }
        }
        var synthetic: [Float] = []
        synthetic.append(contentsOf: [Float](repeating: 0.0, count: Int(0.5 * sampleRate)))
        synthetic.append(contentsOf: toneBlock(seconds: 0.5, frequency: 440.0, amplitude: 0.2))
        synthetic.append(contentsOf: [Float](repeating: 0.0, count: Int(0.5 * sampleRate)))
        synthetic.append(contentsOf: toneBlock(seconds: 0.5, frequency: 440.0, amplitude: 0.2))

        var outProbs: UnsafeMutablePointer<Float>?
        var outCount: UInt64 = 0
        var outWindow: UInt64 = 0
        let status = synthetic.withUnsafeMutableBufferPointer { buf in
            sd_silero_vad_speech_probabilities(
                liveContext, buf.baseAddress, UInt64(buf.count), &outProbs, &outCount, &outWindow
            )
        }
        try expect(status, equals: SD_SILERO_VAD_OK,
                   "sd_silero_vad_speech_probabilities should succeed on a real 2s synthetic buffer")
        guard let probsPtr = outProbs else {
            throw SelfTestFailure.failed("sd_silero_vad_speech_probabilities reported OK but *out_probabilities is NULL")
        }
        defer { sd_silero_vad_free_probabilities(probsPtr) }

        try expect(outCount > 0, equals: true,
                   "a 2s buffer should produce at least one analysis-window probability")
        try expect(outWindow > 0, equals: true,
                   "out_window_size_samples should be a real, nonzero probed window size")

        let probsBuffer = UnsafeBufferPointer(start: probsPtr, count: Int(outCount))
        for (index, p) in probsBuffer.enumerated() {
            try expect(p >= 0.0 && p <= 1.0, equals: true,
                       "probability at window \(index) (\(p)) must lie in [0, 1]")
        }

        print("SILERO VAD: model=\(modelPath), windows=\(outCount), window_size_samples=\(outWindow)")
    }

    /// Skipped (not failed) unless `SUPERDICTATE_SILERO_VAD_MODEL` points at
    /// a real, already-downloaded Silero VAD ggml model file -- same gating
    /// pattern as `testSileroVadRealModel`. Runs the REAL `VadBoundaryOracle`
    /// (backed by a real, load-once `SileroVadEngine`) over a short
    /// synthetic buffer with a genuine pause in the middle, and confirms the
    /// chosen split lands inside that pause.
    private static func testVadBoundaryOracleRealModel() throws {
        guard let modelPath = ProcessInfo.processInfo.environment["SUPERDICTATE_SILERO_VAD_MODEL"],
              FileManager.default.fileExists(atPath: modelPath) else {
            print("SKIP vad-boundary-oracle-real: SUPERDICTATE_SILERO_VAD_MODEL not set to an existing file")
            return
        }

        let engine = try SileroVadEngine(modelPath: modelPath)
        defer { engine.shutdown() }

        // tone - silence - tone: 1s / 1s / 1s at 16kHz. The pause occupies
        // the middle third, [16_000, 32_000) in zone-relative samples.
        let sampleRate = SAMPLE_RATE
        func toneBlock(seconds: Double, frequency: Double, amplitude: Float) -> [Float] {
            let count = Int(seconds * sampleRate)
            return (0..<count).map { i in
                amplitude * Float(sin(2.0 * Double.pi * frequency * Double(i) / sampleRate))
            }
        }
        var zoneSamples: [Float] = []
        zoneSamples.append(contentsOf: toneBlock(seconds: 1.0, frequency: 440.0, amplitude: 0.3))
        let pauseStartOffset = zoneSamples.count
        zoneSamples.append(contentsOf: [Float](repeating: 0.0, count: Int(1.0 * sampleRate)))
        let pauseEndOffset = zoneSamples.count
        zoneSamples.append(contentsOf: toneBlock(seconds: 1.0, frequency: 440.0, amplitude: 0.3))

        let zoneStart = 100_000
        let zoneEnd = zoneStart + zoneSamples.count
        let oracle = VadBoundaryOracle(engine: engine)
        guard let split = oracle.chooseSplit(samples: zoneSamples, zoneStartSample: zoneStart, zoneEndSample: zoneEnd, sampleRate: sampleRate) else {
            throw SelfTestFailure.failed("VadBoundaryOracle declined against a real model on a buffer with an obvious pause")
        }
        let splitOffsetInZone = split - zoneStart
        try expect(splitOffsetInZone >= pauseStartOffset && splitOffsetInZone < pauseEndOffset, equals: true,
                   "VadBoundaryOracle should pick a split inside the actual pause (got offset \(splitOffsetInZone), pause range [\(pauseStartOffset), \(pauseEndOffset)))")

        print("VAD BOUNDARY ORACLE: model=\(modelPath), split_offset_in_zone=\(splitOffsetInZone)")
    }

    /// Pure algorithm coverage for `PauseSegmenter.segment` — no model, no
    /// audio hardware. Every case asserts the coverage invariant (segments
    /// exactly tile the input, no samples dropped or duplicated) plus the
    /// specific behavior under test.
    private static func testPauseSegmentation() throws {
        let sampleRate = 16_000.0

        // Empty input -> no segments.
        try expect(PauseSegmenter.segment(samples: [], sampleRate: sampleRate).count,
                   equals: 0, "empty input produces zero segments")

        // Short, uninterrupted "speech" (no silence anywhere) well under
        // both the min and max thresholds -> exactly one segment, and nothing
        // is dropped.
        let shortSpeech = [Float](repeating: 0.2, count: Int(2.0 * sampleRate))
        let shortSegments = PauseSegmenter.segment(samples: shortSpeech, sampleRate: sampleRate)
        try expect(shortSegments.count, equals: 1, "short uninterrupted speech stays a single segment")
        try expect(shortSegments.reduce(0) { $0 + $1.samples.count }, equals: shortSpeech.count,
                   "single-segment case preserves every sample")
        try expect(shortSegments[0].hasSignal, equals: true, "non-silent audio is flagged as having signal")

        // Continuous non-silent audio longer than the safety cap -> forced
        // cuts, no segment exceeds the cap, and total sample count is
        // preserved exactly (coverage invariant).
        let longSpeech = [Float](repeating: 0.2, count: Int(70.0 * sampleRate))
        let longSegments = PauseSegmenter.segment(samples: longSpeech, sampleRate: sampleRate,
                                                   maxSegmentSeconds: 25.0)
        try expect(longSegments.count >= 3, equals: true,
                   "70s of unbroken speech with a 25s cap forces at least 3 segments")
        let maxAllowedSamples = Int(25.0 * sampleRate)
        for seg in longSegments {
            try expect(seg.samples.count <= maxAllowedSamples, equals: true,
                       "no forced segment exceeds the safety cap")
        }
        try expect(longSegments.reduce(0) { $0 + $1.samples.count }, equals: longSpeech.count,
                   "forced-cut segments cover the whole buffer with no gaps or overlap")

        // An ORDINARY dictation — 5s of speech, a normal 600ms
        // inter-sentence pause, 5 more seconds (10.6s total, under the 15s
        // minimum segment length) -> must stay ONE segment. This is the
        // whole point of the 15s minimum: everyday short dictations go
        // through ASR exactly once, exactly as before this feature existed,
        // so their punctuation/clause structure is never split up.
        var withPause = [Float](repeating: 0.2, count: Int(5.0 * sampleRate))
        withPause.append(contentsOf: [Float](repeating: 0.0, count: Int(0.6 * sampleRate)))
        withPause.append(contentsOf: [Float](repeating: 0.2, count: Int(5.0 * sampleRate)))
        let pausedSegments = PauseSegmenter.segment(samples: withPause, sampleRate: sampleRate)
        try expect(pausedSegments.count, equals: 1,
                   "an ordinary sub-15s dictation with a normal pause is NOT fragmented")
        try expect(pausedSegments.reduce(0) { $0 + $1.samples.count }, equals: withPause.count,
                   "the single-segment case preserves every sample")

        // The same shape, but genuinely LONG: 16s of speech (past the 15s
        // minimum) + a 600ms pause + 5s more -> the pause now qualifies and
        // the buffer splits in two at it. Proves cutting still happens once
        // a recording is actually long, which is the case this feature
        // exists for.
        var longWithPause = [Float](repeating: 0.2, count: Int(16.0 * sampleRate))
        longWithPause.append(contentsOf: [Float](repeating: 0.0, count: Int(0.6 * sampleRate)))
        longWithPause.append(contentsOf: [Float](repeating: 0.2, count: Int(5.0 * sampleRate)))
        let longPausedSegments = PauseSegmenter.segment(samples: longWithPause, sampleRate: sampleRate)
        try expect(longPausedSegments.count, equals: 2,
                   "a qualifying pause past the 15s minimum splits a long dictation into two segments")
        try expect(longPausedSegments[0].samples.count, equals: Int(16.0 * sampleRate),
                   "the cut lands at the start of the silent run, so segment 1 carries no trailing pause")
        try expect(longPausedSegments.reduce(0) { $0 + $1.samples.count }, equals: longWithPause.count,
                   "pause-split segments cover the whole buffer with no gaps or overlap")

        // The same 16s/0.6s/5s shape, but over a realistic low-amplitude
        // noise floor (0.008 RMS — non-zero, yet well under the 0.02 silence
        // threshold) instead of mathematically perfect digital silence, so
        // the cut logic is exercised against something closer to a real
        // microphone than 0.0/0.2 extremes. NOTE: the 0.02 threshold itself
        // is still uncalibrated against real hardware; this test pins the
        // algorithm's SHAPE so a future recalibration only has to move the
        // constant.
        var noisy = [Float](repeating: 0.2, count: Int(16.0 * sampleRate))
        noisy.append(contentsOf: (0..<Int(0.6 * sampleRate)).map { $0 % 2 == 0 ? 0.008 : -0.008 })
        noisy.append(contentsOf: [Float](repeating: 0.2, count: Int(5.0 * sampleRate)))
        let noisySegments = PauseSegmenter.segment(samples: noisy, sampleRate: sampleRate)
        try expect(noisySegments.count, equals: 2,
                   "a pause over a realistic non-zero noise floor is still detected as a pause")
        try expect(noisySegments[0].samples.count, equals: Int(16.0 * sampleRate),
                   "the noise-floor pause cuts at the same place perfect silence would")
        try expect(noisySegments.reduce(0) { $0 + $1.samples.count }, equals: noisy.count,
                   "noise-floor-split segments cover the whole buffer with no gaps or overlap")

        // A pause before the minimum segment length is NOT a
        // qualifying cut point -> stays a single segment.
        var earlyPause = [Float](repeating: 0.2, count: Int(1.0 * sampleRate))
        earlyPause.append(contentsOf: [Float](repeating: 0.0, count: Int(0.6 * sampleRate)))
        earlyPause.append(contentsOf: [Float](repeating: 0.2, count: Int(1.0 * sampleRate)))
        let earlyPauseSegments = PauseSegmenter.segment(samples: earlyPause, sampleRate: sampleRate)
        try expect(earlyPauseSegments.count, equals: 1,
                   "a pause before the minimum segment length is not a qualifying cut point")

        // Long leading silence (60s, well past the 25s max cap) must still be
        // split into segments respecting the max cap, NOT bundled into a
        // single unbounded segment. This is the critical safety invariant
        // that prevents a single ASR call from growing long enough to hit
        // the Parakeet encoder's superlinear-cost regime, even when the
        // recording opens with dead air (background noise, mic left on).
        let longSilence = [Float](repeating: 0.0, count: Int(60.0 * sampleRate))
        let longSilentSegments = PauseSegmenter.segment(samples: longSilence, sampleRate: sampleRate,
                                                        maxSegmentSeconds: 25.0)
        try expect(longSilentSegments.count >= 2, equals: true,
                   "60s of silence with a 25s cap must force-cut into multiple segments (max safety enforced even through silence)")
        let maxAllowedSamplesLong = Int(25.0 * sampleRate)
        for seg in longSilentSegments {
            try expect(seg.samples.count <= maxAllowedSamplesLong, equals: true,
                       "no silence segment exceeds the safety cap, even leading silence")
        }
        try expect(longSilentSegments.reduce(0) { $0 + $1.samples.count }, equals: longSilence.count,
                   "leading-silence segments cover the whole buffer with no gaps or overlap")

        // All-silent buffer -> a single segment flagged as having no signal.
        let silence = [Float](repeating: 0.0, count: Int(4.0 * sampleRate))
        let silentSegments = PauseSegmenter.segment(samples: silence, sampleRate: sampleRate)
        try expect(silentSegments.count, equals: 1, "an all-silent buffer stays a single segment")
        try expect(silentSegments[0].hasSignal, equals: false, "an all-silent segment is flagged as having no signal")

        // hasSignal needs SUSTAINED content, not one stray window: a single
        // ~20ms blip (a mic bump, a keyboard click, a breath) in an
        // otherwise silent buffer must NOT read as speech, or it would
        // trigger a pointless retry and a spurious "dictation lost" signal
        // on a recording that never contained speech at all.
        var blip = [Float](repeating: 0.0, count: Int(4.0 * sampleRate))
        let blipStart = Int(2.0 * sampleRate)
        for i in blipStart..<(blipStart + Int(PauseSegmenter.defaultWindowSeconds * sampleRate)) {
            blip[i] = 0.5
        }
        let blipSegments = PauseSegmenter.segment(samples: blip, sampleRate: sampleRate)
        try expect(blipSegments.count, equals: 1, "a mostly-silent buffer with one blip stays a single segment")
        try expect(blipSegments[0].hasSignal, equals: false,
                   "a single non-silent window is below the minimum-signal threshold")

        // A sustained run at/above the threshold (5 windows = ~100ms) in the
        // same otherwise-silent buffer DOES count as signal.
        var sustained = [Float](repeating: 0.0, count: Int(4.0 * sampleRate))
        let runStart = Int(2.0 * sampleRate)
        let runLength = PauseSegmenter.defaultSignalMinWindows * Int(PauseSegmenter.defaultWindowSeconds * sampleRate)
        for i in runStart..<(runStart + runLength) {
            sustained[i] = 0.5
        }
        let sustainedSegments = PauseSegmenter.segment(samples: sustained, sampleRate: sampleRate)
        try expect(sustainedSegments.count, equals: 1, "the sustained-signal buffer stays a single segment")
        try expect(sustainedSegments[0].hasSignal, equals: true,
                   "a run at the minimum-signal threshold is flagged as having signal")
    }

    /// Direct regression coverage for `OverlapWindower.addOverlap`, and in
    /// particular for the single most safety-critical invariant in the
    /// overlap-segmentation plan: overlap is carved OUT of the existing
    /// max-segment-seconds safety cap, never added on top of it, so a
    /// window can never grow long enough to reintroduce the Parakeet
    /// encoder hang that the original 25s cap exists to prevent.
    private static func testOverlapWindowing() throws {
        let sampleRate = 16_000.0

        // 1) Single segment -> exactly one AudioWindow, samples identical to
        // the input, no overlap added. This is the majority-case invariant:
        // ordinary short dictations that never get split must be completely
        // unaffected by this feature's existence.
        let single = [AudioSegment(samples: [Float](repeating: 0.2, count: Int(2.0 * sampleRate)),
                                    hasSignal: true, startSample: 0)]
        let singleWindows = OverlapWindower.addOverlap(to: single, sampleRate: sampleRate)
        try expect(singleWindows.count, equals: 1, "a single segment produces exactly one window")
        try expect(singleWindows[0].samples, equals: single[0].samples,
                   "a single segment's window samples are byte-identical to the input (no overlap added)")
        try expect(singleWindows[0].startSample, equals: 0, "single-segment window startSample is unshifted")
        try expect(singleWindows[0].ownedStartSample, equals: 0, "single-segment ownedStartSample is unshifted")
        try expect(singleWindows[0].ownedEndSample, equals: single[0].samples.count,
                   "single-segment ownedEndSample covers exactly the input")

        // Also confirm the zero-segment edge case doesn't crash and returns
        // nothing.
        let emptyWindows = OverlapWindower.addOverlap(to: [], sampleRate: sampleRate)
        try expect(emptyWindows.count, equals: 0, "zero segments produces zero windows")

        // 2) BUDGET-SAFETY INVARIANT (the most important assertion in this
        // task): construct three back-to-back segments EACH AT the 25s
        // safety cap (as PauseSegmenter would actually emit for a very long
        // unbroken dictation -- see the "forced cuts" case in
        // testPauseSegmentation), request a real 4s overlap, and verify
        // EVERY resulting window's sample count still respects the cap.
        // Hand-traced arithmetic (sampleRate = 16_000, maxSegmentSeconds =
        // 25.0 -> maxSegmentSamples = 400_000; each segment.samples.count
        // == 400_000 exactly, so budget = max(0, 400_000 - 400_000) = 0,
        // halfBudget = 0, so overlapBefore == overlapAfter == 0 for every
        // segment regardless of the requested 4s -- i.e. the budget clamp
        // must reduce the requested overlap all the way to zero when a
        // segment is already AT the cap, and the resulting window count
        // must equal exactly maxSegmentSamples, never more).
        let maxSegmentSeconds = PauseSegmenter.defaultMaxSegmentSeconds
        let maxSegmentSamples = Int(maxSegmentSeconds * sampleRate)
        let atCapSegments: [AudioSegment] = (0..<3).map { i in
            AudioSegment(samples: [Float](repeating: 0.2, count: maxSegmentSamples),
                         hasSignal: true, startSample: i * maxSegmentSamples)
        }
        let atCapWindows = OverlapWindower.addOverlap(to: atCapSegments, sampleRate: sampleRate,
                                                       overlapSeconds: 4.0,
                                                       maxSegmentSeconds: maxSegmentSeconds)
        try expect(atCapWindows.count, equals: 3, "budget-safety case produces one window per input segment")
        for (i, w) in atCapWindows.enumerated() {
            try expect(w.samples.count <= maxSegmentSamples, equals: true,
                       "window \(i) built from an at-cap segment must not exceed the safety cap even with overlap requested")
            try expect(w.samples.count, equals: maxSegmentSamples,
                       "window \(i) built from an at-cap segment gets zero overlap (budget fully consumed), so it equals the cap exactly")
        }

        // 2b) A near-cap variant where segments are NOT exactly at the cap,
        // so there IS a small budget, and confirm the clamp still respects
        // both the per-side budget AND the 4s request. Each segment is
        // 24.5s (392_000 samples); budget = 400_000 - 392_000 = 8_000;
        // halfBudget = 4_000 samples (0.25s) per side -- far less than the
        // requested 4s (64_000 samples), so overlapBefore/overlapAfter must
        // clamp to 4_000, and total window length must be
        // 392_000 + 4_000 + 4_000 = 400_000 == exactly the cap, for the
        // middle segment (which has neighbors on both sides).
        let nearCapSamples = Int(24.5 * sampleRate)
        let nearCapSegments: [AudioSegment] = (0..<3).map { i in
            AudioSegment(samples: [Float](repeating: 0.2, count: nearCapSamples),
                         hasSignal: true, startSample: i * nearCapSamples)
        }
        let nearCapWindows = OverlapWindower.addOverlap(to: nearCapSegments, sampleRate: sampleRate,
                                                         overlapSeconds: 4.0,
                                                         maxSegmentSeconds: maxSegmentSeconds)
        for (i, w) in nearCapWindows.enumerated() {
            try expect(w.samples.count <= maxSegmentSamples, equals: true,
                       "near-cap window \(i) never exceeds the safety cap")
        }
        let expectedHalfBudget = (maxSegmentSamples - nearCapSamples) / 2
        try expect(expectedHalfBudget, equals: 4_000, "hand-traced half-budget for the near-cap case is 4_000 samples")
        try expect(nearCapWindows[1].samples.count, equals: nearCapSamples + 2 * expectedHalfBudget,
                   "the middle near-cap window borrows exactly the clamped per-side budget on both sides")
        try expect(nearCapWindows[1].samples.count, equals: maxSegmentSamples,
                   "the middle near-cap window lands exactly at the cap, never over it")

        // 3) Normal case: three moderate segments, well under the cap, so
        // overlap is limited only by the requested overlapSeconds (4s) and
        // by neighbor length, never by the budget clamp. Hand-computed
        // expected values below.
        let segLen = Int(10.0 * sampleRate) // 160_000 samples each, 10s
        let seg0 = AudioSegment(samples: [Float](repeating: 0.1, count: segLen), hasSignal: true, startSample: 0)
        let seg1 = AudioSegment(samples: [Float](repeating: 0.2, count: segLen), hasSignal: true, startSample: segLen)
        let seg2 = AudioSegment(samples: [Float](repeating: 0.3, count: segLen), hasSignal: true, startSample: 2 * segLen)
        let normalSegments = [seg0, seg1, seg2]
        let normalWindows = OverlapWindower.addOverlap(to: normalSegments, sampleRate: sampleRate,
                                                        overlapSeconds: 4.0,
                                                        maxSegmentSeconds: maxSegmentSeconds)
        try expect(normalWindows.count, equals: 3, "normal case produces one window per input segment")

        let overlapSamples = Int(4.0 * sampleRate) // 64_000 -- well under segLen and under budget/2
        // Middle window (index 1): borrows the LAST `overlapSamples` of seg0
        // as a leading prefix, then all of seg1, then the FIRST
        // `overlapSamples` of seg2 as a trailing suffix.
        let middle = normalWindows[1]
        let expectedMiddle = Array(seg0.samples.suffix(overlapSamples))
            + seg1.samples
            + Array(seg2.samples.prefix(overlapSamples))
        try expect(middle.samples.count, equals: expectedMiddle.count,
                   "middle window length equals borrowed-prefix + owned + borrowed-suffix")
        try expect(middle.samples, equals: expectedMiddle,
                   "middle window samples exactly match the hand-assembled borrowed-tail + owned + borrowed-head")
        try expect(middle.startSample, equals: seg1.startSample - overlapSamples,
                   "middle window startSample is shifted left by the borrowed leading overlap")
        try expect(middle.ownedStartSample, equals: seg1.startSample,
                   "middle window ownedStartSample is unchanged from the segment's own startSample")
        try expect(middle.ownedEndSample, equals: seg1.startSample + seg1.samples.count,
                   "middle window ownedEndSample is unchanged from the segment's own end")

        // 4) Edge segments get no outward overlap: first window has no
        // leading overlap (startSample == ownedStartSample), and its
        // trailing borrowed audio (if any) never reaches past its own
        // ownedEndSample plus the borrowed suffix -- concretely, the FIRST
        // window's samples must equal seg0 + borrowed head of seg1 (no
        // borrowed tail from a nonexistent segment "before" it), and the
        // LAST window's samples must equal borrowed tail of seg1 + seg2 (no
        // borrowed head from a nonexistent segment "after" it).
        let first = normalWindows[0]
        try expect(first.startSample, equals: first.ownedStartSample,
                   "the first window has no leading overlap: startSample == ownedStartSample")
        let expectedFirst = seg0.samples + Array(seg1.samples.prefix(overlapSamples))
        try expect(first.samples, equals: expectedFirst,
                   "the first window borrows only a trailing head from segment 2, nothing leading")

        let last = normalWindows[2]
        let expectedLast = Array(seg1.samples.suffix(overlapSamples)) + seg2.samples
        try expect(last.samples, equals: expectedLast,
                   "the last window borrows only a leading tail from segment 2, nothing trailing")
        try expect(last.ownedEndSample, equals: seg2.startSample + seg2.samples.count,
                   "the last window's ownedEndSample is its own true end, with nothing borrowed past it")
        try expect(last.startSample + last.samples.count, equals: last.ownedEndSample,
                   "the last window's samples end exactly at its own ownedEndSample -- no trailing overlap exists to overrun it")
    }

    /// Coverage for the `BoundaryOracle` chain (Task 6): `MidpointBoundaryOracle`,
    /// `MelEnergyBoundaryOracle`, and `chainBoundaryOracle`'s fallthrough +
    /// defensive clamping. No VAD oracle exists yet -- that's Task 7.
    private static func testBoundaryOracle() throws {
        let sampleRate = 16_000.0

        // 1) MidpointBoundaryOracle: zone [100, 200) -> 150.
        let midpointOracle = MidpointBoundaryOracle()
        let midpointSplit = midpointOracle.chooseSplit(samples: [], zoneStartSample: 100, zoneEndSample: 200, sampleRate: sampleRate)
        try expect(midpointSplit, equals: 150, "midpoint of [100, 200) is 150")

        // Zero-width zone -> returns the zone start, doesn't crash.
        let zeroWidthSplit = midpointOracle.chooseSplit(samples: [], zoneStartSample: 300, zoneEndSample: 300, sampleRate: sampleRate)
        try expect(zeroWidthSplit, equals: 300, "a zero-width zone's midpoint is its own start")

        // 2) MelEnergyBoundaryOracle: loud-quiet-loud synthetic buffer, same
        // style as PauseSegmenter's own silence tests -- the returned offset
        // must land inside the quiet stretch.
        let loudSeconds = 1.0
        let quietSeconds = 1.0
        var meZone = [Float](repeating: 0.2, count: Int(loudSeconds * sampleRate))
        let quietStartOffset = meZone.count
        meZone.append(contentsOf: [Float](repeating: 0.0, count: Int(quietSeconds * sampleRate)))
        let quietEndOffset = meZone.count
        meZone.append(contentsOf: [Float](repeating: 0.2, count: Int(loudSeconds * sampleRate)))

        let zoneStart = 5_000
        let zoneEnd = zoneStart + meZone.count
        let melOracle = MelEnergyBoundaryOracle()
        guard let melSplit = melOracle.chooseSplit(samples: meZone, zoneStartSample: zoneStart, zoneEndSample: zoneEnd, sampleRate: sampleRate) else {
            throw SelfTestFailure.failed("MelEnergyBoundaryOracle declined on a non-empty zone")
        }
        let melSplitOffsetInZone = melSplit - zoneStart
        try expect(melSplitOffsetInZone >= quietStartOffset && melSplitOffsetInZone < quietEndOffset, equals: true,
                   "MelEnergyBoundaryOracle picks an offset inside the quiet stretch (got offset \(melSplitOffsetInZone), quiet range [\(quietStartOffset), \(quietEndOffset)))")

        // 3) chainBoundaryOracle: a declining (always-nil) oracle is skipped
        // in favor of the next one in the chain.
        struct DecliningOracle: BoundaryOracle {
            func chooseSplit(samples: [Float], zoneStartSample: Int, zoneEndSample: Int, sampleRate: Double) -> Int? { nil }
        }
        struct FixedOracle: BoundaryOracle {
            let answer: Int
            func chooseSplit(samples: [Float], zoneStartSample: Int, zoneEndSample: Int, sampleRate: Double) -> Int? { answer }
        }
        let fallthroughChain = chainBoundaryOracle([DecliningOracle(), FixedOracle(answer: 175)])
        let fallthroughResult = fallthroughChain([], 100, 200, sampleRate)
        try expect(fallthroughResult, equals: 175, "a declining oracle is skipped in favor of the next oracle in the chain")

        // An empty oracle list still produces an answer -- falls through to
        // the always-appended MidpointBoundaryOracle.
        let emptyChain = chainBoundaryOracle([])
        let emptyChainResult = emptyChain([], 100, 200, sampleRate)
        try expect(emptyChainResult, equals: 150, "a chain with zero oracles still falls through to MidpointBoundaryOracle")

        // 4) Clamping: a deliberately-broken oracle that returns an offset
        // OUTSIDE [zoneStartSample, zoneEndSample] gets clamped before being
        // returned, both above the top and below the bottom of the zone.
        let tooHighChain = chainBoundaryOracle([FixedOracle(answer: 9_999)])
        try expect(tooHighChain([], 100, 200, sampleRate), equals: 200,
                   "an out-of-range answer above the zone is clamped to zoneEndSample")

        let tooLowChain = chainBoundaryOracle([FixedOracle(answer: -5)])
        try expect(tooLowChain([], 100, 200, sampleRate), equals: 100,
                   "an out-of-range answer below the zone is clamped to zoneStartSample")
    }

    /// Pure decision-logic coverage for `VadBoundaryOracle.chooseSplit` --
    /// no real model, no native context. Injects a mock
    /// `SpeechProbabilitySource` (mirroring how `testSegmentedTranscription`
    /// injects a mock `transcribeOne` closure instead of a real
    /// `ParakeetEngine`) so the longest-quiet-run selection, center
    /// computation, and decline paths can all be exercised deterministically.
    private static func testVadBoundaryOracle() throws {
        let sampleRate = 16_000.0
        let zoneStart = 10_000
        let zoneEnd = 20_000

        struct MockSource: SpeechProbabilitySource {
            let result: Result<SpeechProbabilities, Error>
            func speechProbabilities(samples: [Float]) throws -> SpeechProbabilities {
                switch result {
                case .success(let value): return value
                case .failure(let error): throw error
                }
            }
        }
        struct MockError: Error {}

        // 1) One clear low-probability run in the middle -> its center.
        // Windows: [high, high, low, low, low, high, high] with windowSize 100.
        // Run is indices [2, 3, 4] (length 3), center index = 2 + 3/2 = 3.
        let singleRunProbs = SpeechProbabilities(
            values: [0.9, 0.8, 0.1, 0.2, 0.1, 0.85, 0.95],
            windowSizeSamples: 100
        )
        let singleRunOracle = VadBoundaryOracle(engine: MockSource(result: .success(singleRunProbs)))
        let singleRunSplit = singleRunOracle.chooseSplit(samples: [Float](repeating: 0, count: 10_000), zoneStartSample: zoneStart, zoneEndSample: zoneEnd, sampleRate: sampleRate)
        try expect(singleRunSplit, equals: zoneStart + 3 * 100,
                   "a single clear low-probability run picks its own center window")

        // 2) Multiple runs of different lengths -> the LONGEST one's center,
        // not the first one encountered. First run: indices [1] (length 1).
        // Second (longest) run: indices [4, 5, 6, 7] (length 4), center
        // index = 4 + 4/2 = 6.
        let multiRunProbs = SpeechProbabilities(
            values: [0.9, 0.1, 0.9, 0.9, 0.2, 0.1, 0.3, 0.15, 0.9],
            windowSizeSamples: 50
        )
        let multiRunOracle = VadBoundaryOracle(engine: MockSource(result: .success(multiRunProbs)))
        let multiRunSplit = multiRunOracle.chooseSplit(samples: [Float](repeating: 0, count: 10_000), zoneStartSample: zoneStart, zoneEndSample: zoneEnd, sampleRate: sampleRate)
        try expect(multiRunSplit, equals: zoneStart + 6 * 50,
                   "the LONGEST run's center is picked over an earlier, shorter run")

        // 3) Nothing below the threshold -> declines (nil).
        let allLoudProbs = SpeechProbabilities(values: [0.9, 0.8, 0.95, 0.7], windowSizeSamples: 100)
        let allLoudOracle = VadBoundaryOracle(engine: MockSource(result: .success(allLoudProbs)))
        let allLoudSplit = allLoudOracle.chooseSplit(samples: [Float](repeating: 0, count: 10_000), zoneStartSample: zoneStart, zoneEndSample: zoneEnd, sampleRate: sampleRate)
        try expect(allLoudSplit == nil, equals: true,
                   "an array with nothing below the silence threshold declines (returns nil)")

        // 4) VAD-fetch failure -> declines (nil), doesn't crash/throw out.
        let failingOracle = VadBoundaryOracle(engine: MockSource(result: .failure(MockError())))
        let failingSplit = failingOracle.chooseSplit(samples: [Float](repeating: 0, count: 10_000), zoneStartSample: zoneStart, zoneEndSample: zoneEnd, sampleRate: sampleRate)
        try expect(failingSplit == nil, equals: true,
                   "a VAD-fetch failure declines (returns nil) rather than throwing/crashing")

        // 5) Empty zone -> declines without even consulting the source.
        let emptyZoneOracle = VadBoundaryOracle(engine: MockSource(result: .success(singleRunProbs)))
        let emptyZoneSplit = emptyZoneOracle.chooseSplit(samples: [], zoneStartSample: 500, zoneEndSample: 500, sampleRate: sampleRate)
        try expect(emptyZoneSplit == nil, equals: true,
                   "a zero-width zone declines immediately")

        // 6) windowSizeSamples == 0 -> declines (can't convert window index
        // to a sample offset).
        let zeroWindowProbs = SpeechProbabilities(values: [0.1, 0.1], windowSizeSamples: 0)
        let zeroWindowOracle = VadBoundaryOracle(engine: MockSource(result: .success(zeroWindowProbs)))
        let zeroWindowSplit = zeroWindowOracle.chooseSplit(samples: [Float](repeating: 0, count: 10_000), zoneStartSample: zoneStart, zoneEndSample: zoneEnd, sampleRate: sampleRate)
        try expect(zeroWindowSplit == nil, equals: true,
                   "a zero window size declines rather than dividing/producing a bogus offset")

        // 7) Custom silenceProbabilityThreshold is honored: a value that
        // would qualify under the default 0.4 threshold no longer qualifies
        // under a stricter 0.05 threshold -> declines.
        var strictOracle = VadBoundaryOracle(engine: MockSource(result: .success(singleRunProbs)))
        strictOracle.silenceProbabilityThreshold = 0.05
        let strictSplit = strictOracle.chooseSplit(samples: [Float](repeating: 0, count: 10_000), zoneStartSample: zoneStart, zoneEndSample: zoneEnd, sampleRate: sampleRate)
        try expect(strictSplit == nil, equals: true,
                   "a stricter silenceProbabilityThreshold can turn a would-be run into nothing qualifying")
    }

    /// Pure orchestration coverage for `transcribeSegments` using a mock
    /// `transcribeOne` closure — no model, no engine, no audio hardware.
    /// Bridged through `runParakeetEngineSynchronously` since this test
    /// suite's entry point is synchronous (see that helper's doc comment).
    private static func testSegmentedTranscription() throws {
        // All segments succeed on the first try -> concatenated with a
        // single space, no failure flagged.
        let allOk: [AudioSegment] = [
            AudioSegment(samples: [0.1], hasSignal: true),
            AudioSegment(samples: [0.1], hasSignal: true),
        ]
        nonisolated(unsafe) var callIndex = 0
        let okTexts = ["hello", "world"]
        let okOutcome = try runParakeetEngineSynchronously {
            await transcribeSegments(allOk) { _ in
                defer { callIndex += 1 }
                return okTexts[callIndex]
            }
        }
        try expect(okOutcome.text, equals: "hello world", "successful segments are joined with a space")
        try expect(okOutcome.hadSegmentFailure, equals: false, "no failure flagged when every segment succeeds")

        // A signal-bearing segment that returns empty on the first call but
        // real text on the retry -> succeeds, no failure flagged, and the
        // closure was actually called twice for that segment.
        let retrySucceeds: [AudioSegment] = [AudioSegment(samples: [0.1], hasSignal: true)]
        nonisolated(unsafe) var retryCallCount = 0
        let retryOutcome = try runParakeetEngineSynchronously {
            await transcribeSegments(retrySucceeds) { _ in
                retryCallCount += 1
                return retryCallCount == 1 ? "" : "recovered"
            }
        }
        try expect(retryCallCount, equals: 2, "an empty signal-bearing segment is retried exactly once")
        try expect(retryOutcome.text, equals: "recovered", "a successful retry contributes its text")
        try expect(retryOutcome.hadSegmentFailure, equals: false, "a retry that succeeds is not a failure")

        // A signal-bearing segment that stays empty after the retry ->
        // flagged as a failure, contributes nothing to the joined text, but
        // does not discard an earlier segment's text.
        let stillFails: [AudioSegment] = [
            AudioSegment(samples: [0.1], hasSignal: true),
            AudioSegment(samples: [0.1], hasSignal: true),
        ]
        nonisolated(unsafe) var stillFailsCallIndex = 0
        let failOutcome = try runParakeetEngineSynchronously {
            await transcribeSegments(stillFails) { _ in
                defer { stillFailsCallIndex += 1 }
                // Segment 0 always succeeds; segment 1 (calls 2 and 3, since
                // segment 0 only ever calls once) always returns empty.
                return stillFailsCallIndex == 0 ? "kept" : ""
            }
        }
        try expect(failOutcome.text, equals: "kept",
                   "a persistently-empty segment doesn't discard an earlier segment's text")
        try expect(failOutcome.hadSegmentFailure, equals: true,
                   "a signal-bearing segment still empty after retry is flagged as a failure")

        // A segment with no signal (silence) that returns empty is NOT
        // retried and is NOT flagged as a failure.
        let silentSegment: [AudioSegment] = [AudioSegment(samples: [0.0], hasSignal: false)]
        nonisolated(unsafe) var silentCallCount = 0
        let silentOutcome = try runParakeetEngineSynchronously {
            await transcribeSegments(silentSegment) { _ in
                silentCallCount += 1
                return ""
            }
        }
        try expect(silentCallCount, equals: 1, "a silent segment is not retried")
        try expect(silentOutcome.text, equals: "", "a silent segment contributes no text")
        try expect(silentOutcome.hadSegmentFailure, equals: false, "a silent segment is never a failure")

        // A segment whose transcribeOne throws is treated like an empty
        // result: retried once (since it has signal), and doesn't crash the
        // whole run.
        let throwing: [AudioSegment] = [AudioSegment(samples: [0.1], hasSignal: true)]
        nonisolated(unsafe) var throwCallCount = 0
        struct DummyError: Error {}
        let throwOutcome = try runParakeetEngineSynchronously {
            await transcribeSegments(throwing) { _ in
                throwCallCount += 1
                throw DummyError()
            }
        }
        try expect(throwCallCount, equals: 2, "a throwing segment is retried exactly once, same as empty text")
        try expect(throwOutcome.hadSegmentFailure, equals: true, "a segment that keeps throwing is flagged as a failure")
        try expect(throwOutcome.lastErrorDescription != nil, equals: true,
                   "a thrown error's description is surfaced for logging")

        // REGRESSION GUARD: a segment with NO detected signal whose closure
        // THROWS is a broken engine, not legitimate silence. It must still be
        // retried and must still be flagged as a failure — otherwise a
        // recording where every segment fell under the RMS threshold (or a
        // nil engine) silently deletes the user's recovery audio with no
        // failure signal at all, which is the exact bug this feature exists
        // to prevent.
        let silentThrowing: [AudioSegment] = [AudioSegment(samples: [0.0], hasSignal: false)]
        nonisolated(unsafe) var silentThrowCallCount = 0
        struct EngineUnavailable: LocalizedError {
            var errorDescription: String? { "engine unavailable" }
        }
        let silentThrowOutcome = try runParakeetEngineSynchronously {
            await transcribeSegments(silentThrowing) { _ in
                silentThrowCallCount += 1
                throw EngineUnavailable()
            }
        }
        try expect(silentThrowCallCount, equals: 2,
                   "a THROWING segment is retried even when it carries no detected signal")
        try expect(silentThrowOutcome.hadSegmentFailure, equals: true,
                   "a throw is never treated as legitimate silence, even with hasSignal == false")
        try expect(silentThrowOutcome.lastErrorDescription ?? "", equals: "engine unavailable",
                   "the most recent thrown error's description is captured verbatim")

        // A throw whose retry SUCCEEDS is not a failure — but the error is
        // still reported so it can be logged. Non-nil error != failure.
        let throwThenSucceed: [AudioSegment] = [AudioSegment(samples: [0.1], hasSignal: true)]
        nonisolated(unsafe) var mixedCallCount = 0
        let mixedOutcome = try runParakeetEngineSynchronously {
            await transcribeSegments(throwThenSucceed) { _ in
                mixedCallCount += 1
                if mixedCallCount == 1 { throw EngineUnavailable() }
                return "second try"
            }
        }
        try expect(mixedOutcome.text, equals: "second try", "a throw whose retry succeeds keeps its text")
        try expect(mixedOutcome.hadSegmentFailure, equals: false,
                   "a throw whose retry succeeds is not a failure")
        try expect(mixedOutcome.lastErrorDescription ?? "", equals: "engine unavailable",
                   "a recovered throw still reports its error for logging")

        // Nothing ever threw -> no error description at all.
        try expect(okOutcome.lastErrorDescription == nil, equals: true,
                   "lastErrorDescription is nil when no call ever threw")
    }

    // MARK: - Seam token dedup (achetronic/parakeet DD-014 port)

    /// Tests timestamp-based deduplication of tokens at overlap boundaries.
    /// Pure and deterministic — no model, no I/O.
    private static func testSeamDedup() throws {
        let tolerance = 0.24
        let lookbackCount = 3

        // 1. Exact duplicate: two tokens with identical text and timestamps
        // within tolerance -> only the first is kept
        let exactDupInput = [
            AbsoluteToken(text: "hello", absoluteSeconds: 1.0),
            AbsoluteToken(text: "hello", absoluteSeconds: 1.0),
        ]
        let exactDupOutput = dedupSeam(exactDupInput, toleranceSeconds: tolerance, lookbackCount: lookbackCount)
        try expect(exactDupOutput.count, equals: 1, "exact duplicate should keep only the first token")
        try expect(exactDupOutput[0].text, equals: "hello", "exact duplicate should keep the first token's text")
        try expect(exactDupOutput[0].absoluteSeconds, equals: 1.0, "exact duplicate should keep the first token's timestamp")

        // 2. Collision: two tokens with DIFFERENT text but timestamps within
        // tolerance -> only the first (earlier) is kept, regardless of text
        let collisionInput = [
            AbsoluteToken(text: "hello", absoluteSeconds: 1.0),
            AbsoluteToken(text: "helo", absoluteSeconds: 1.15),  // within tolerance, different text
        ]
        let collisionOutput = dedupSeam(collisionInput, toleranceSeconds: tolerance, lookbackCount: lookbackCount)
        try expect(collisionOutput.count, equals: 1, "collision should keep only the earlier token")
        try expect(collisionOutput[0].text, equals: "hello", "collision should keep the earlier token's text")

        // 3. Correctly-kept-far-token: two tokens whose timestamps differ by
        // MORE than toleranceSeconds -> both kept
        let farTokenInput = [
            AbsoluteToken(text: "hello", absoluteSeconds: 1.0),
            AbsoluteToken(text: "world", absoluteSeconds: 1.5),  // more than tolerance apart
        ]
        let farTokenOutput = dedupSeam(farTokenInput, toleranceSeconds: tolerance, lookbackCount: lookbackCount)
        try expect(farTokenOutput.count, equals: 2, "tokens further apart than tolerance should both be kept")
        try expect(farTokenOutput[0].text, equals: "hello", "first token should be preserved")
        try expect(farTokenOutput[1].text, equals: "world", "second token should be preserved")

        // 4. Empty input: dedupSeam([]) returns []
        let emptyInput: [AbsoluteToken] = []
        let emptyOutput = dedupSeam(emptyInput, toleranceSeconds: tolerance, lookbackCount: lookbackCount)
        try expect(emptyOutput.count, equals: 0, "empty input should produce empty output")

        // 5. Lookback window respected: a token that collides in TIME with
        // something more than lookbackCount POSITIONS back should NOT be
        // deduped against it (positional lookback, not time window).
        // Construct: 5 tokens where token[0] and token[4] collide in time
        // (both at 1.0s) but token[4] is more than lookbackCount=3 positions
        // away. Tokens 1-3 have distinct timestamps to fill the gap.
        let lookbackInput = [
            AbsoluteToken(text: "token0", absoluteSeconds: 1.0),
            AbsoluteToken(text: "token1", absoluteSeconds: 2.0),  // distinct, will be kept
            AbsoluteToken(text: "token2", absoluteSeconds: 3.0),  // distinct, will be kept
            AbsoluteToken(text: "token3", absoluteSeconds: 4.0),  // distinct, will be kept
            AbsoluteToken(text: "token4", absoluteSeconds: 1.0),  // collides in TIME with token0 (at 1.0s)
            // but token0 is 4 positions back, outside lookbackCount=3 window
        ]
        let lookbackOutput = dedupSeam(lookbackInput, toleranceSeconds: tolerance, lookbackCount: lookbackCount)
        // Expected: token0, token1, token2, token3, token4 ALL kept
        // because token4's collision is with token0 which is outside the
        // lookback window of 3 preceding tokens (only token1, token2, token3 are checked)
        try expect(lookbackOutput.count, equals: 5,
                   "token colliding with something beyond lookbackCount positions back should not be deduped")
        try expect(lookbackOutput[0].text, equals: "token0", "token0 kept")
        try expect(lookbackOutput[1].text, equals: "token1", "token1 kept")
        try expect(lookbackOutput[2].text, equals: "token2", "token2 kept")
        try expect(lookbackOutput[3].text, equals: "token3", "token3 kept")
        try expect(lookbackOutput[4].text, equals: "token4", "token4 kept (collision outside lookback window)")
    }

    // MARK: - Parakeet CPU integration (spec §18.2 — real model, opt-in via env var)

    /// Skipped (not failed) unless `SUPERDICTATE_PARAKEET_MODEL` points at a
    /// real, already-downloaded GGUF — mirrors spec §18.2's "if the
    /// environment variable or device is absent, mark the integration test
    /// skipped, not passed" requirement (written for the Vulkan case there,
    /// applied here to the CPU case too since CI/most dev machines won't
    /// have the ~940MB model pre-staged).
    private static func testParakeetCPUIntegration() throws {
        guard let modelPath = ProcessInfo.processInfo.environment["SUPERDICTATE_PARAKEET_MODEL"],
              FileManager.default.fileExists(atPath: modelPath) else {
            print("SKIP parakeet-cpu: SUPERDICTATE_PARAKEET_MODEL not set to an existing file")
            return
        }

        let threadCount = TranscriptionWorker.resolvedParakeetThreadCount()
        let loadStarted = ProcessInfo.processInfo.systemUptime
        // ParakeetEngine.init is synchronous (an actor's init runs before
        // the instance's isolation is established, so no `await` is needed
        // to call it) — only its instance methods need the sync bridge
        // below. `engine` itself is Sendable (actors are Sendable by
        // construction), so it can be captured directly in the bridge's
        // `Task { }` closures with no extra wrapper.
        let engine = try ParakeetEngine(modelPath: modelPath, device: .cpu, threadCount: threadCount)
        let loadSeconds = ProcessInfo.processInfo.systemUptime - loadStarted

        try runParakeetEngineSynchronously { try await engine.warmUp() }

        // 0.5s of near-silence (a tiny DC offset, not exact zero, so this
        // isn't indistinguishable from a truly empty buffer) — enough to
        // exercise a real forward pass without needing a real speech
        // fixture file bundled into the repo.
        let sampleCount = Int(SAMPLE_RATE * 0.5)
        let samples = [Float](repeating: 0.0001, count: sampleCount)
        let inferStarted = ProcessInfo.processInfo.systemUptime
        let result = try runParakeetEngineSynchronously { try await engine.transcribe(samples: samples) }
        let inferSeconds = ProcessInfo.processInfo.systemUptime - inferStarted
        let rtf = inferSeconds / max(0.001, Double(sampleCount) / SAMPLE_RATE)

        print("PARAKEET CPU: load \(String(format: "%.2f", loadSeconds))s, threads \(threadCount), infer \(String(format: "%.3f", inferSeconds))s, RTF \(String(format: "%.3f", rtf)), text=\"\(result.text)\"")

        // Repeat inference on the SAME loaded context (load-once contract).
        let secondResult = try runParakeetEngineSynchronously { try await engine.transcribe(samples: samples) }
        print("PARAKEET CPU (2nd call, same context): text=\"\(secondResult.text)\"")

        // Destroy and recreate the context safely (spec §18.2 item 7).
        try runParakeetEngineSynchronously { await engine.shutdown() }
        let recreated = try ParakeetEngine(modelPath: modelPath, device: .cpu, threadCount: threadCount)
        try runParakeetEngineSynchronously { try await recreated.warmUp() }
        try runParakeetEngineSynchronously { await recreated.shutdown() }
    }

    // MARK: - Parakeet Vulkan integration (spec §18.3 — real GPU, opt-in via
    // env vars; skipped, not failed, when the hardware/model isn't present)

    /// Skipped (not failed) unless BOTH `SUPERDICTATE_TEST_VULKAN=1` and
    /// `SUPERDICTATE_PARAKEET_MODEL` (an existing GGUF path) are set — spec
    /// §18.3's "if the environment variable or device is absent, mark the
    /// integration test skipped, not passed." Real hardware verification
    /// (device selection, forced-failure fallback, VRAM use) is covered by
    /// the Phase 5 integration report's manual runs on the actual RX 6600;
    /// this self-test is the re-runnable regression check for CI/dev boxes
    /// that DO have Vulkan + the model staged.
    // MARK: - Minimal WAV reader (Phase 5 benchmark harness only)

    /// Parses a canonical 16-bit PCM WAV file into mono Float32 samples in
    /// [-1, 1] at its native sample rate. Deliberately minimal (no
    /// float/24-bit/extensible fmt chunk support) — this exists ONLY to
    /// drive `benchmarkParakeetCPUvsVulkan()` against the Phase 1 corpus
    /// fixtures (16-bit PCM mono/stereo WAV), not as production audio I/O
    /// (the app's real capture path uses AVFoundation, never a file).
    private static func loadWavMonoFloat32(path: String) throws -> (samples: [Float], sampleRate: UInt32) {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        func u32(_ offset: Int) -> UInt32 {
            UInt32(data[offset]) | (UInt32(data[offset+1]) << 8) | (UInt32(data[offset+2]) << 16) | (UInt32(data[offset+3]) << 24)
        }
        func u16(_ offset: Int) -> UInt16 {
            UInt16(data[offset]) | (UInt16(data[offset+1]) << 8)
        }
        guard data.count > 44, data[0...3].elementsEqual("RIFF".utf8), data[8...11].elementsEqual("WAVE".utf8) else {
            throw NSError(domain: "Parakey", code: -10, userInfo: [NSLocalizedDescriptionKey: "not a RIFF/WAVE file: \(path)"])
        }
        var offset = 12
        var channels: UInt16 = 1
        var sampleRate: UInt32 = 16000
        var bitsPerSample: UInt16 = 16
        var dataRange: Range<Int>?
        while offset + 8 <= data.count {
            let chunkID = data[offset...offset+3]
            let chunkSize = Int(u32(offset + 4))
            let bodyStart = offset + 8
            if chunkID.elementsEqual("fmt ".utf8) {
                channels = u16(bodyStart + 2)
                sampleRate = u32(bodyStart + 4)
                bitsPerSample = u16(bodyStart + 14)
            } else if chunkID.elementsEqual("data".utf8) {
                dataRange = bodyStart..<min(bodyStart + chunkSize, data.count)
            }
            offset = bodyStart + chunkSize + (chunkSize % 2)
        }
        guard let dataRange, bitsPerSample == 16 else {
            throw NSError(domain: "Parakey", code: -11, userInfo: [NSLocalizedDescriptionKey: "unsupported/missing WAV data chunk (need 16-bit PCM): \(path)"])
        }
        let bytes = [UInt8](data[dataRange])
        let frameCount = bytes.count / (2 * Int(channels))
        var samples = [Float](repeating: 0, count: frameCount)
        bytes.withUnsafeBytes { raw in
            let i16 = raw.bindMemory(to: Int16.self)
            for frame in 0..<frameCount {
                var sum: Int32 = 0
                for ch in 0..<Int(channels) {
                    sum += Int32(i16[frame * Int(channels) + ch])
                }
                samples[frame] = Float(sum) / Float(Int(channels)) / 32768.0
            }
        }
        return (samples, sampleRate)
    }

    /// Phase 5 benchmark harness: Parakeet CPU vs Vulkan, wired through the
    /// EXACT same ParakeetEngine/bridge path the app itself uses (not the
    /// standalone parakeet-cli used by the Phase 5 pre-spike) — the point
    /// is to measure whatever overhead Swift/actor/bridge marshalling adds
    /// on top of the pre-spike's raw ~30-63% latency reduction. Opt-in via
    /// SUPERDICTATE_TEST_VULKAN=1 + SUPERDICTATE_PARAKEET_MODEL (same gates
    /// as testParakeetVulkanIntegration) plus SUPERDICTATE_BENCH_CORPUS_DIR
    /// pointing at a directory of 16-bit PCM WAV files (the Phase 1 corpus
    /// fixture set) and SUPERDICTATE_BENCH_DEVICE ("cpu" or "vulkan"). Runs
    /// ONE device per process invocation deliberately — parakeet.cpp's
    /// compute backend (pk::global_backend()) is a process-global
    /// singleton that commits to one device for the process's lifetime
    /// (confirmed by this same bridge's own post-init safety check, which
    /// correctly refused a same-process CPU-then-Vulkan sequence here
    /// during development), matching how TranscriptionWorker itself never
    /// holds a CPU and a Vulkan engine alive at the same time either. Run
    /// this once per device and compare the two logs' `cpu_ms`/timing
    /// columns externally. Not part of testAll — this is a manual
    /// measurement tool, not a pass/fail regression test (timings are
    /// inherently machine/load-dependent; only the log output matters).
    private static func benchmarkParakeetCPUvsVulkan() throws {
        guard ProcessInfo.processInfo.environment["SUPERDICTATE_TEST_VULKAN"] == "1",
              let modelPath = ProcessInfo.processInfo.environment["SUPERDICTATE_PARAKEET_MODEL"],
              FileManager.default.fileExists(atPath: modelPath),
              let corpusDir = ProcessInfo.processInfo.environment["SUPERDICTATE_BENCH_CORPUS_DIR"],
              let deviceRaw = ProcessInfo.processInfo.environment["SUPERDICTATE_BENCH_DEVICE"],
              let device = deviceRaw == "cpu" ? ParakeetDevice.cpu : (deviceRaw == "vulkan" ? ParakeetDevice.vulkan : nil)
        else {
            print("SKIP parakeet-vulkan-bench: requires SUPERDICTATE_TEST_VULKAN=1, SUPERDICTATE_PARAKEET_MODEL, SUPERDICTATE_BENCH_CORPUS_DIR, SUPERDICTATE_BENCH_DEVICE=cpu|vulkan")
            return
        }
        if device == .vulkan {
            guard parakeetVulkanAvailable() else {
                print("SKIP parakeet-vulkan-bench: no Vulkan device enumerated")
                return
            }
        }
        let clipNames = ["01_ru_short_command.wav", "02_en_short_command.wav", "03_ru_numbers.wav", "11_ru_paragraph_30s.wav"]
        let threadCount = TranscriptionWorker.resolvedParakeetThreadCount()

        let engine = try ParakeetEngine(modelPath: modelPath, device: device, threadCount: threadCount)
        try runParakeetEngineSynchronously { try await engine.warmUp() }
        let actualDevice = try runParakeetEngineSynchronously { await engine.backendDescription() }

        print("PARAKEET BENCH [\(deviceRaw), actual=\(actualDevice)]: clip,audio_s,wall_ms,text")
        for name in clipNames {
            let path = (corpusDir as NSString).appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: path) else {
                print("PARAKEET BENCH: SKIP \(name) (not found under \(corpusDir))")
                continue
            }
            let (samples, sampleRate) = try loadWavMonoFloat32(path: path)
            let audioSeconds = Double(samples.count) / Double(sampleRate)

            let started = ProcessInfo.processInfo.systemUptime
            let result = try runParakeetEngineSynchronously { try await engine.transcribe(samples: samples, sampleRate: sampleRate) }
            let wallMs = (ProcessInfo.processInfo.systemUptime - started) * 1000

            print("PARAKEET BENCH: \(name),\(String(format: "%.2f", audioSeconds)),\(String(format: "%.1f", wallMs)),\"\(result.text)\"")
        }

        try runParakeetEngineSynchronously { await engine.shutdown() }
    }

    private static func testParakeetVulkanIntegration() throws {
        guard ProcessInfo.processInfo.environment["SUPERDICTATE_TEST_VULKAN"] == "1" else {
            print("SKIP parakeet-vulkan: SUPERDICTATE_TEST_VULKAN=1 not set")
            return
        }
        guard let modelPath = ProcessInfo.processInfo.environment["SUPERDICTATE_PARAKEET_MODEL"],
              FileManager.default.fileExists(atPath: modelPath) else {
            print("SKIP parakeet-vulkan: SUPERDICTATE_PARAKEET_MODEL not set to an existing file")
            return
        }
        guard parakeetVulkanAvailable() else {
            print("SKIP parakeet-vulkan: no Vulkan device enumerated by ggml's backend registry on this machine")
            return
        }

        let threadCount = TranscriptionWorker.resolvedParakeetThreadCount()

        // Forced-failure fallback check FIRST, before any real Vulkan
        // backend has been constructed in this process: parakeet.cpp's
        // compute backend (pk::global_backend()) is a process-global
        // singleton, created lazily on first use and NOT reconstructed on
        // a later request unless explicitly reset — so this ordering
        // matters. Running the forced-failure attempt first guarantees the
        // bogus device name is actually consulted when the singleton is
        // first constructed, rather than a real backend from an earlier
        // sub-test being silently reused (which would make this assertion
        // pass for the wrong reason — the check never even running, not
        // "ran and correctly detected no fallback").
        // SD_PARAKEET_TEST_FORCE_DEVICE_NAME is a test-only bridge hook
        // (see sd_parakeet_create) that requests a device name guaranteed
        // not to exist, reproducing exactly the upstream silent-CPU-fallback
        // behavior the Phase 5 pre-spike found (backend.cpp logs "not
        // found; falling back to CPU" and continues successfully) —
        // confirms the bridge's post-init check catches it rather than
        // reporting Vulkan success. Restores the environment afterward so
        // it doesn't leak into the real-device sub-test below.
        setenv("SD_PARAKEET_TEST_FORCE_DEVICE_NAME", "Vulkan9-does-not-exist", 1)
        var threwFellBackToCPU = false
        do {
            let bogus = try ParakeetEngine(modelPath: modelPath, device: .vulkan, threadCount: threadCount)
            try runParakeetEngineSynchronously { try await bogus.warmUp() }
        } catch ParakeetEngineError.vulkanFellBackToCPU {
            threwFellBackToCPU = true
        }
        unsetenv("SD_PARAKEET_TEST_FORCE_DEVICE_NAME")
        try expect(
            threwFellBackToCPU, equals: true,
            "a bogus forced device name (upstream falls back to CPU silently) must surface as .vulkanFellBackToCPU, never a silent success"
        )

        // Real-device verification second: the forced-failure attempt above
        // left parakeet.cpp's process-global backend torn down (the bridge's
        // post-init check calls pk::shutdown_backend() on this exact
        // failure path — see sd_parakeet_warm_up), so this constructs a
        // genuinely fresh backend against the real device name.
        let loadStarted = ProcessInfo.processInfo.systemUptime
        let engine = try ParakeetEngine(modelPath: modelPath, device: .vulkan, threadCount: threadCount)
        let loadSeconds = ProcessInfo.processInfo.systemUptime - loadStarted

        // warmUp() is what forces parakeet.cpp's process-global backend
        // construction and performs the mandatory post-init device check
        // (see ParakeetEngine.warmUp's doc comment) — a build/environment
        // where Vulkan silently fell back to CPU must surface here as
        // .vulkanFellBackToCPU, not a quiet pass.
        try runParakeetEngineSynchronously { try await engine.warmUp() }
        let actualDevice = try runParakeetEngineSynchronously { await engine.backendDescription() }
        try expect(
            actualDevice.lowercased().hasPrefix("vulkan"),
            equals: true,
            "a Vulkan-requested engine must report an actual selected device name starting with \"Vulkan\" after warm-up, got \"\(actualDevice)\""
        )

        let sampleCount = Int(SAMPLE_RATE * 0.5)
        let samples = [Float](repeating: 0.0001, count: sampleCount)
        let inferStarted = ProcessInfo.processInfo.systemUptime
        let result = try runParakeetEngineSynchronously { try await engine.transcribe(samples: samples) }
        let inferSeconds = ProcessInfo.processInfo.systemUptime - inferStarted
        let rtf = inferSeconds / max(0.001, Double(sampleCount) / SAMPLE_RATE)
        print("PARAKEET VULKAN: load \(String(format: "%.2f", loadSeconds))s, device \(actualDevice), threads \(threadCount), infer \(String(format: "%.3f", inferSeconds))s, RTF \(String(format: "%.3f", rtf)), text=\"\(result.text)\"")

        try runParakeetEngineSynchronously { await engine.shutdown() }

        // Stale-singleton regression (production signature: "Vulkan was
        // requested but the actual selected backend is 'cpu'" right after
        // re-enabling GPU in settings). The process-global pk::Backend
        // singleton outlives context destruction and reads PARAKEET_DEVICE
        // only at construction, so a CPU context created after a Vulkan one
        // (exactly what the mid-session Vulkan-error fallback does) leaves a
        // CPU singleton behind. A subsequent Vulkan context — with the fix,
        // the bridge resets the stale singleton when the device request
        // changes and no contexts are alive — must come up on a real
        // "Vulkan…" device, not throw .vulkanFellBackToCPU.
        let cpuEngine = try ParakeetEngine(modelPath: modelPath, device: .cpu, threadCount: threadCount)
        try runParakeetEngineSynchronously { try await cpuEngine.warmUp() }
        let cpuDevice = try runParakeetEngineSynchronously { await cpuEngine.backendDescription() }
        try expect(
            cpuDevice.lowercased().hasPrefix("cpu") || cpuDevice.lowercased().hasPrefix("vulkan"),
            equals: true,
            "CPU-requested engine should report a sane backend (got \"\(cpuDevice)\")"
        )
        try runParakeetEngineSynchronously { await cpuEngine.shutdown() }

        let vulkanReload = try ParakeetEngine(modelPath: modelPath, device: .vulkan, threadCount: threadCount)
        try runParakeetEngineSynchronously { try await vulkanReload.warmUp() }
        let reloadedDevice = try runParakeetEngineSynchronously { await vulkanReload.backendDescription() }
        try expect(
            reloadedDevice.lowercased().hasPrefix("vulkan"),
            equals: true,
            "re-enabling Vulkan after a CPU context in the same process must select a Vulkan device, not reuse the stale CPU singleton (got \"\(reloadedDevice)\")"
        )
        try runParakeetEngineSynchronously { await vulkanReload.shutdown() }
    }

    private static func testAudioRouteChangeDecision() throws {
        try expect(
            audioStartupRetryDelaySeconds(afterFailedAttempt: 1),
            equals: Optional(1 as UInt64),
            "first audio startup failure should retry after one second"
        )
        try expect(
            audioStartupRetryDelaySeconds(afterFailedAttempt: 2),
            equals: Optional(3 as UInt64),
            "second audio startup failure should retry after three seconds"
        )
        try expect(
            audioStartupRetryDelaySeconds(afterFailedAttempt: 3),
            equals: Optional(8 as UInt64),
            "third audio startup failure should retry after eight seconds"
        )
        try expect(
            audioStartupRetryDelaySeconds(afterFailedAttempt: 4),
            equals: UInt64?.none,
            "audio startup should stop retrying after the configured backoff schedule"
        )
        try expect(
            audioRouteChangeAction(isTerminating: true,
                                   isRestartingAudioInput: false,
                                   isCoreRuntimeReady: true,
                                   isRecording: false,
                                   isBusy: false,
                                   hasStartupTask: false),
            equals: .ignore,
            "route changes during termination should be ignored"
        )
        try expect(
            audioRouteChangeAction(isTerminating: false,
                                   isRestartingAudioInput: false,
                                   isCoreRuntimeReady: false,
                                   isRecording: false,
                                   isBusy: false,
                                   hasStartupTask: false),
            equals: .rebuildMenuOnly,
            "route changes before runtime readiness should only refresh the menu"
        )
        try expect(
            audioRouteChangeAction(isTerminating: false,
                                   isRestartingAudioInput: false,
                                   isCoreRuntimeReady: true,
                                   isRecording: true,
                                   isBusy: false,
                                   hasStartupTask: false),
            equals: .deferRefresh,
            "route changes during recording should defer the restart"
        )
        try expect(
            audioRouteChangeAction(isTerminating: false,
                                   isRestartingAudioInput: false,
                                   isCoreRuntimeReady: true,
                                   isRecording: false,
                                   isBusy: false,
                                   hasStartupTask: false),
            equals: .restartNow,
            "idle ready route changes should restart audio immediately"
        )
        try expect(
            audioConfigurationChangeIsSuppressed(now: 10, suppressedUntil: nil),
            equals: false,
            "configuration changes should not be suppressed without a suppression deadline"
        )
        try expect(
            audioConfigurationChangeIsSuppressed(now: 10, suppressedUntil: 11),
            equals: true,
            "configuration changes before the app-owned deadline should be ignored"
        )
        try expect(
            audioConfigurationChangeIsSuppressed(now: 11, suppressedUntil: 11),
            equals: false,
            "configuration changes at the suppression deadline should be handled normally"
        )
    }

    private static func testRecordingLifecycle() throws {
        try expect(
            recordingReleaseAction(capturedSampleCount: 3_999,
                                   sampleRate: 16_000,
                                   minimumClipSeconds: 0.25),
            equals: .discardTooShort(duration: 0.2499375),
            "release decision should discard clips under the minimum duration"
        )
        try expect(
            recordingReleaseAction(capturedSampleCount: 4_000,
                                   sampleRate: 16_000,
                                   minimumClipSeconds: 0.25),
            equals: .transcribe(duration: 0.25),
            "release decision should transcribe clips at the minimum duration"
        )
        try expect(
            recordingReleaseAction(capturedSampleCount: 4_000,
                                   sampleRate: 0,
                                   minimumClipSeconds: 0.25),
            equals: .discardTooShort(duration: 0),
            "release decision should handle invalid sample rates defensively"
        )

        let recoveryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("superdictate-recovery-test-\(UUID().uuidString)")
            .appendingPathExtension("sdaudio")
        defer { try? FileManager.default.removeItem(at: recoveryURL) }
        let expectedSamples: [Float] = [-0.75, -0.125, 0, 0.25, 0.875]
        let journal = try PendingDictationJournal(url: recoveryURL)
        journal.append(Array(expectedSamples.prefix(2)))
        journal.append(Array(expectedSamples.dropFirst(2)))
        journal.finish()
        try expect(
            try PendingDictationRecovery.loadSamples(from: recoveryURL),
            equals: expectedSamples,
            "pending dictation journal should round-trip captured samples"
        )
        let recoveryHandle = try FileHandle(forWritingTo: recoveryURL)
        try recoveryHandle.seekToEnd()
        try recoveryHandle.write(contentsOf: Data([0x7f]))
        try recoveryHandle.close()
        try expect(
            try PendingDictationRecovery.loadSamples(from: recoveryURL),
            equals: expectedSamples,
            "pending dictation recovery should ignore a partial trailing sample after a crash"
        )
        let recoveryAttributes = try FileManager.default.attributesOfItem(atPath: recoveryURL.path)
        guard let recoveryMode = recoveryAttributes[.posixPermissions] as? NSNumber else {
            throw SelfTestFailure.failed("pending dictation journal should expose POSIX permissions")
        }
        try expect(
            recoveryMode.intValue,
            equals: 0o600,
            "pending dictation journal should be private"
        )

        let processed = processedDictationText(
            rawTranscript: "  Um, parakeet is fast.  ",
            corrections: [TranscriptCorrection(source: "parakeet", replacement: "Parakey")],
            removeFillerWords: true
        )
        try expect(
            processed,
            equals: DictationTextProcessingResult(text: "Parakey is fast.",
                                                  appliedCorrectionCount: 1,
                                                  removedFillerWordCount: 1),
            "dictation text processing should trim, apply corrections, then remove fillers"
        )

        let preservedFillers = processedDictationText(
            rawTranscript: "  Um, parakeet is fast.  ",
            corrections: [TranscriptCorrection(source: "parakeet", replacement: "Parakey")],
            removeFillerWords: false
        )
        try expect(
            preservedFillers,
            equals: DictationTextProcessingResult(text: "Um, Parakey is fast.",
                                                  appliedCorrectionCount: 1,
                                                  removedFillerWordCount: 0),
            "dictation text processing should preserve fillers when the setting is off"
        )

        let repairedYo = processedDictationText(
            rawTranscript: "  <unk>лка, мо<UNK> и е<unk>. Потом <unk>жик.  ",
            corrections: [],
            removeFillerWords: false
        )
        try expect(
            repairedYo.text,
            equals: "Ёлка, моё и её. Потом ёжик.",
            "dictation text processing should repair Parakeet unknown tokens used for Cyrillic yo"
        )

        let repairedYoRussian = processedDictationText(
            rawTranscript: "  <unk>лка.  ",
            corrections: [],
            removeFillerWords: false,
            language: .russian
        )
        try expect(
            repairedYoRussian.text,
            equals: "Ёлка.",
            "explicit Russian language should repair <unk> to ё"
        )

        let removedUnkEnglish = processedDictationText(
            rawTranscript: "  Hello <unk> world.  ",
            corrections: [],
            removeFillerWords: false,
            language: .english
        )
        try expect(
            removedUnkEnglish.text,
            equals: "Hello world.",
            "non-Russian language should remove <unk> tokens, not replace with Cyrillic ё"
        )

        let removedUnkPunctuation = ParakeetTranscriptRepair.apply(
            to: "Hello <unk>, world.",
            language: .english
        )
        try expect(
            removedUnkPunctuation,
            equals: "Hello, world.",
            "removing <unk> should not leave a space before punctuation"
        )

        let removedUnkMultiSpace = ParakeetTranscriptRepair.apply(
            to: "Hello <unk>   world",
            language: .english
        )
        try expect(
            removedUnkMultiSpace,
            equals: "Hello world",
            "removing <unk> should collapse multi-space runs left behind"
        )

        let removedUnkFrench = ParakeetTranscriptRepair.apply(
            to: "Bonjour <unk> le monde.",
            language: .french
        )
        try expect(
            removedUnkFrench,
            equals: "Bonjour le monde.",
            "ParakeetTranscriptRepair should strip <unk> for French"
        )

        let autoYo = ParakeetTranscriptRepair.apply(
            to: "<unk>лка",
            language: .auto
        )
        try expect(
            autoYo,
            equals: "Ёлка",
            "auto-detect language should preserve the ё repair for the default audience"
        )

        let markerText = systemAudioMuteMarkerText(pid: 12345,
                                                   date: Date(timeIntervalSince1970: 0))
        try expect(
            systemAudioMuteMarkerProcessID(from: markerText),
            equals: Optional(pid_t(12345)),
            "system audio mute marker should preserve the owning pid"
        )
        try expect(
            systemAudioMuteMarkerProcessID(from: "created=bad\n"),
            equals: pid_t?.none,
            "system audio mute marker parsing should ignore missing pids"
        )

        let script = systemAudioMuteWatchdogScript()
        for fragment in [
            #"PID="$1""#,
            #"MARKER="$2""#,
            #"/bin/kill -0 "$PID""#,
            "/usr/bin/osascript -e 'set volume without output muted'",
            #"/bin/rm -f "$MARKER""#,
        ] {
            guard script.contains(fragment) else {
                throw SelfTestFailure.failed("system audio mute watchdog script missing fragment: \(fragment)")
            }
        }

        // Mute command outcome: command failure and verified-unmuted
        // are definitive "not muted"; an ambiguous verification after
        // a successful command must be assumed muted so the recovery
        // marker + watchdog stay armed.
        try expect(
            systemAudioMuteCommandOutcome(commandSucceeded: true, verifiedMuted: true),
            equals: .muted,
            "verified mute should report muted"
        )
        try expect(
            systemAudioMuteCommandOutcome(commandSucceeded: true, verifiedMuted: nil),
            equals: .assumedMuted,
            "successful command with failed verification must assume muted"
        )
        try expect(
            systemAudioMuteCommandOutcome(commandSucceeded: true, verifiedMuted: false),
            equals: .failed,
            "verified-unmuted after the command is a definitive failure"
        )
        try expect(
            systemAudioMuteCommandOutcome(commandSucceeded: false, verifiedMuted: true),
            equals: .failed,
            "a failed command is not muted regardless of verification"
        )

        // Probe decision: only a definitive "output is live" while the
        // recording still wants the mute arms recovery and mutes.
        try expect(
            systemAudioMuteProbeDecision(mutedState: false, unmuteAlreadyRequested: false),
            equals: .armRecoveryAndMute,
            "live output during an active recording should mute"
        )
        try expect(
            systemAudioMuteProbeDecision(mutedState: true, unmuteAlreadyRequested: false),
            equals: .standDown,
            "a user-set mute must not be stomped"
        )
        try expect(
            systemAudioMuteProbeDecision(mutedState: nil, unmuteAlreadyRequested: false),
            equals: .standDown,
            "a failed probe must not risk stomping an unseen user mute"
        )
        try expect(
            systemAudioMuteProbeDecision(mutedState: false, unmuteAlreadyRequested: true),
            equals: .standDown,
            "a recording that already ended should not mute"
        )

        // Mute completion decision: assumed mutes behave exactly like
        // verified mutes (recovery stays armed); a definitive failure
        // disarms; a release that raced the command unmutes at once.
        try expect(
            systemAudioMuteCommandDecision(outcome: .muted, unmuteAlreadyRequested: false),
            equals: .stayMuted,
            "verified mute during recording should hold"
        )
        try expect(
            systemAudioMuteCommandDecision(outcome: .assumedMuted, unmuteAlreadyRequested: false),
            equals: .stayMuted,
            "assumed mute must keep recovery armed, not disarm it"
        )
        try expect(
            systemAudioMuteCommandDecision(outcome: .failed, unmuteAlreadyRequested: false),
            equals: .disarmRecovery,
            "definitive mute failure should disarm marker and watchdog"
        )
        try expect(
            systemAudioMuteCommandDecision(outcome: .muted, unmuteAlreadyRequested: true),
            equals: .beginUnmute,
            "release during the mute command should unmute immediately"
        )
        try expect(
            systemAudioMuteCommandDecision(outcome: .assumedMuted, unmuteAlreadyRequested: true),
            equals: .beginUnmute,
            "release during an assumed mute should also unmute immediately"
        )

        // Unmute request routing per lifecycle phase.
        try expect(
            systemAudioUnmuteRequestDecision(phase: .idle),
            equals: .nothingToDo,
            "no lifecycle → nothing to unmute"
        )
        try expect(
            systemAudioUnmuteRequestDecision(phase: .probing),
            equals: .deferUntilCommandSettles,
            "release during the probe defers to the probe completion"
        )
        try expect(
            systemAudioUnmuteRequestDecision(phase: .muting),
            equals: .deferUntilCommandSettles,
            "release during the mute command defers to its completion"
        )
        try expect(
            systemAudioUnmuteRequestDecision(phase: .muted),
            equals: .beginUnmute,
            "release while muted unmutes immediately"
        )
        try expect(
            systemAudioUnmuteRequestDecision(phase: .unmuting),
            equals: .nothingToDo,
            "release while an unmute is in flight should not double-issue"
        )

        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parakey-mute-marker-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }

        let marker = root.appendingPathComponent("system-audio-muted")
        try writeSystemAudioMuteMarker(to: marker, text: markerText)
        var markerStat = stat()
        guard lstat(marker.path, &markerStat) == 0 else {
            throw SelfTestFailure.failed("system audio mute marker should exist")
        }
        try expect((markerStat.st_mode & S_IFMT) == S_IFREG,
                   equals: true,
                   "system audio mute marker should be a regular file")
        try expect(Int(markerStat.st_mode & mode_t(0o777)),
                   equals: 0o600,
                   "system audio mute marker should be private")
        try expect(
            String(data: try Data(contentsOf: marker), encoding: .utf8),
            equals: markerText,
            "system audio mute marker should contain the expected pid"
        )

        let target = root.appendingPathComponent("target-marker")
        try Data("target\n".utf8).write(to: target)
        let symlink = root.appendingPathComponent("linked-marker")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: target)
        var symlinkRejected = false
        do {
            try writeSystemAudioMuteMarker(to: symlink, text: "bad\n")
        } catch {
            symlinkRejected = true
        }
        try expect(symlinkRejected,
                   equals: true,
                   "system audio mute marker should reject leaf symlinks")
        try expect(
            String(data: try Data(contentsOf: target), encoding: .utf8),
            equals: "target\n",
            "system audio mute marker should leave symlink targets untouched"
        )
    }

    private static func testPowerStateRecoveryDecision() throws {
        try expect(
            shouldResumeRuntimeAfterSystemSleep(isTerminating: true,
                                                isCoreRuntimeReady: true,
                                                isReady: true,
                                                isRecording: true,
                                                audioIsRunning: true),
            equals: false,
            "sleep during termination should not schedule wake recovery"
        )
        try expect(
            shouldResumeRuntimeAfterSystemSleep(isTerminating: false,
                                                isCoreRuntimeReady: false,
                                                isReady: false,
                                                isRecording: false,
                                                audioIsRunning: false),
            equals: false,
            "sleep before runtime startup should not schedule wake recovery"
        )
        try expect(
            shouldResumeRuntimeAfterSystemSleep(isTerminating: false,
                                                isCoreRuntimeReady: false,
                                                isReady: false,
                                                isRecording: true,
                                                audioIsRunning: true),
            equals: true,
            "active recording should schedule wake recovery even if readiness is already down"
        )
        try expect(
            wakeRuntimeRecoveryAction(shouldResumeAfterWake: false,
                                      isTerminating: false,
                                      hasStartupTask: false,
                                      isBusy: false,
                                      isSpeechModelReady: true),
            equals: .ignore,
            "wake without a sleep-paused runtime should do nothing"
        )
        try expect(
            wakeRuntimeRecoveryAction(shouldResumeAfterWake: true,
                                      isTerminating: false,
                                      hasStartupTask: false,
                                      isBusy: true,
                                      isSpeechModelReady: true),
            equals: .deferUntilIdle,
            "wake during transcription should defer runtime recovery"
        )
        try expect(
            wakeRuntimeRecoveryAction(shouldResumeAfterWake: true,
                                      isTerminating: false,
                                      hasStartupTask: true,
                                      isBusy: false,
                                      isSpeechModelReady: true),
            equals: .deferUntilIdle,
            "wake during startup should defer runtime recovery"
        )
        try expect(
            wakeRuntimeRecoveryAction(shouldResumeAfterWake: true,
                                      isTerminating: false,
                                      hasStartupTask: false,
                                      isBusy: false,
                                      isSpeechModelReady: true),
            equals: .startAudioRuntime,
            "wake after a loaded model should restart audio without reloading the model"
        )
        try expect(
            wakeRuntimeRecoveryAction(shouldResumeAfterWake: true,
                                      isTerminating: false,
                                      hasStartupTask: false,
                                      isBusy: false,
                                      isSpeechModelReady: false),
            equals: .startFullStartup,
            "wake without a loaded model should fall back to full startup"
        )
    }

    private static func testHandledHotkeySuppression() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)
        let f7 = hotkeyChoice(forKeycode: 98)

        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "F-key keyDown should suppress and press"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: 97), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .pass,
            "non-hotkey keyDown should pass through"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: f5.keycode), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "F-key keyUp should suppress and release"
        )

        try expect(
            state.transition(for: event(.keyDown, keycode: f7.keycode), hotkey: f7, triggerMode: .hold, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "recorded F-key keyDown should suppress and press"
        )
    }

    private static func testCustomShortcutMatching() throws {
        var state = HotkeyTransitionState()
        let shortcut = hotkeyChoice(forKeycode: 40,
                                    modifiers: [.maskCommand, .maskShift])
        let commandShift = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue

        try expect(
            state.transition(for: event(.keyDown, keycode: 40, flags: commandShift),
                             hotkey: shortcut,
                             triggerMode: .hold,
                             isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "custom shortcut should trigger when its exact modifiers are held"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: 40),
                             hotkey: shortcut,
                             triggerMode: .hold,
                             isRecording: true),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "custom shortcut release should not depend on modifier release order"
        )
        try expect(
            state.transition(for: event(.keyDown,
                                        keycode: 40,
                                        flags: CGEventFlags.maskCommand.rawValue),
                             hotkey: shortcut,
                             triggerMode: .hold,
                             isRecording: false),
            equals: .pass,
            "custom shortcut should ignore incomplete modifier combinations"
        )
    }

    private static func testModifierOnlyChordMatching() throws {
        var state = HotkeyTransitionState()
        let shortcut = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE,
                                    modifiers: [.maskAlternate, .maskCommand])
        let unrelatedEnterShortcut = hotkeyChoice(forKeycode: 80)
        let alternate = CGEventFlags.maskAlternate.rawValue
        let commandAlternate = alternate | CGEventFlags.maskCommand.rawValue

        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_OPTION_KEYCODE,
                                        flags: alternate),
                             hotkey: shortcut,
                             enterHotkey: unrelatedEnterShortcut,
                             triggerMode: .toggle,
                             isRecording: false),
            equals: .pass,
            "an incomplete modifier chord must not reserve Option globally"
        )
        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_OPTION_KEYCODE),
                             hotkey: shortcut,
                             enterHotkey: unrelatedEnterShortcut,
                             triggerMode: .toggle,
                             isRecording: false),
            equals: .pass,
            "releasing an incomplete modifier chord must reach the frontmost app"
        )
        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_OPTION_KEYCODE,
                                        flags: alternate),
                             hotkey: shortcut,
                             enterHotkey: unrelatedEnterShortcut,
                             triggerMode: .toggle,
                             isRecording: false),
            equals: .pass,
            "Option should still pass through before the full shortcut activates"
        )
        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_COMMAND_KEYCODE,
                                        flags: commandAlternate),
                             hotkey: shortcut,
                             enterHotkey: unrelatedEnterShortcut,
                             triggerMode: .toggle,
                             isRecording: false),
            equals: HotkeyTransitionResult(suppress: false, actions: [.press]),
            "Option+Command should start dictation without stealing modifier events"
        )
        _ = state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_COMMAND_KEYCODE,
                                        flags: alternate),
                             hotkey: shortcut,
                             enterHotkey: unrelatedEnterShortcut,
                             triggerMode: .toggle,
                             isRecording: true)
        _ = state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_OPTION_KEYCODE),
                             hotkey: shortcut,
                             enterHotkey: unrelatedEnterShortcut,
                             triggerMode: .toggle,
                             isRecording: true)
        _ = state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_COMMAND_KEYCODE,
                                        flags: CGEventFlags.maskCommand.rawValue),
                             hotkey: shortcut,
                             enterHotkey: unrelatedEnterShortcut,
                             triggerMode: .toggle,
                             isRecording: true)
        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_OPTION_KEYCODE,
                                        flags: commandAlternate),
                             hotkey: shortcut,
                             enterHotkey: unrelatedEnterShortcut,
                             triggerMode: .toggle,
                             isRecording: true),
            equals: HotkeyTransitionResult(suppress: false, actions: [.release]),
            "the same modifier chord should stop dictation without stealing modifiers"
        )

        var holdState = HotkeyTransitionState()
        try expect(
            holdState.transition(for: event(.flagsChanged,
                                           keycode: RIGHT_OPTION_KEYCODE,
                                           flags: alternate),
                                 hotkey: shortcut,
                                 enterHotkey: unrelatedEnterShortcut,
                                 triggerMode: .hold,
                                 isRecording: false),
            equals: .pass,
            "hold-mode chord prefixes must pass through"
        )
        try expect(
            holdState.transition(for: event(.flagsChanged,
                                           keycode: RIGHT_COMMAND_KEYCODE,
                                           flags: commandAlternate),
                                 hotkey: shortcut,
                                 enterHotkey: unrelatedEnterShortcut,
                                 triggerMode: .hold,
                                 isRecording: false),
            equals: HotkeyTransitionResult(suppress: false, actions: [.press]),
            "hold-mode modifier chords should press without stealing modifiers"
        )
        try expect(
            holdState.transition(for: event(.flagsChanged,
                                           keycode: RIGHT_OPTION_KEYCODE,
                                           flags: CGEventFlags.maskCommand.rawValue),
                                 hotkey: shortcut,
                                 enterHotkey: unrelatedEnterShortcut,
                                 triggerMode: .hold,
                                 isRecording: true),
            equals: HotkeyTransitionResult(suppress: false, actions: [.release]),
            "hold-mode modifier chords should release without stealing modifiers"
        )
        try expect(
            holdState.transition(for: event(.flagsChanged,
                                           keycode: RIGHT_COMMAND_KEYCODE),
                                 hotkey: shortcut,
                                 enterHotkey: unrelatedEnterShortcut,
                                 triggerMode: .hold,
                                 isRecording: false),
            equals: .pass,
            "the final modifier release must pass through"
        )
    }

    private static func testConfigurableEnterShortcut() throws {
        var state = HotkeyTransitionState()
        let standard = hotkeyChoice(forKeycode: 96)
        let enterShortcut = hotkeyChoice(forKeycode: 40,
                                         modifiers: [.maskCommand, .maskShift])
        let commandShift = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue

        try expect(
            state.transition(for: event(.keyDown,
                                        keycode: 40,
                                        flags: commandShift),
                             hotkey: standard,
                             enterHotkey: enterShortcut,
                             triggerMode: .toggle,
                             isRecording: true),
            equals: HotkeyTransitionResult(suppress: true, actions: [.releaseAlternate]),
            "a user-configured Enter shortcut should use the Enter completion path"
        )
    }

    /// A release-first recorder capture of Ctrl+Command is represented as
    /// "Command + Left Control": Command is the required modifier and
    /// Control is the primary key. With bare Right Command as the primary
    /// dictation shortcut, this must still finish the active recording —
    /// the shared Command is intentional, not an ambiguous prefix.
    private static func testCommandModifierEnterShortcutWithPrimaryCommand() throws {
        var state = HotkeyTransitionState()
        let primary = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE)
        let commandControl = hotkeyChoice(forKeycode: LEFT_CONTROL_KEYCODE,
                                          modifiers: .maskCommand)
        let commandControlFlags = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue

        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_COMMAND_KEYCODE,
                                        flags: CGEventFlags.maskCommand.rawValue),
                             hotkey: primary,
                             enterHotkey: commandControl,
                             triggerMode: .hold,
                             isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "Right Command should start the primary dictation shortcut"
        )
        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: LEFT_CONTROL_KEYCODE,
                                        flags: commandControlFlags),
                             hotkey: primary,
                             enterHotkey: commandControl,
                             triggerMode: .hold,
                             isRecording: true),
            equals: HotkeyTransitionResult(suppress: false, actions: [.releaseAlternate]),
            "Command + Control should finish an active Right Command recording"
        )
    }

    /// Hold-mode fix: when the alternate-completion chord is built on the
    /// same modifier keycode as the primary dictation hotkey (e.g.
    /// primary "Right Command", chord "Control + Right Command"), the
    /// shared modifier is necessarily pressed BEFORE the recording
    /// starts — pressing it is what starts the recording — so the enter
    /// state machine never sees its flagsChanged. The recording edge
    /// must adopt the held modifier, or the chord could never fire.
    private static func testEnterChordBuiltOnHeldPrimaryModifier() throws {
        let rightCommand = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE)
        let enterChord = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE,
                                      modifiers: [.maskControl])
        let controlCommand = CGEventFlags.maskControl.rawValue | CGEventFlags.maskCommand.rawValue

        var state = HotkeyTransitionState()
        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_COMMAND_KEYCODE,
                                        flags: CGEventFlags.maskCommand.rawValue),
                             hotkey: rightCommand,
                             enterHotkey: enterChord,
                             triggerMode: .hold,
                             isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "Right Command press should start dictation"
        )
        // The app flips isRecording=true only after .press above, so the
        // enter state machine missed the Right Command flagsChanged —
        // exactly the real-world hold-mode sequence.
        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: LEFT_CONTROL_KEYCODE,
                                        flags: controlCommand),
                             hotkey: rightCommand,
                             enterHotkey: enterChord,
                             triggerMode: .hold,
                             isRecording: true),
            equals: HotkeyTransitionResult(suppress: false, actions: [.releaseAlternate]),
            "pressing the extra chord modifier mid-recording should fire alternate completion (held primary adopted)"
        )

        // The default ⌥⌘ chord must behave the same way.
        var defaultChordState = HotkeyTransitionState()
        let defaultEnterChord = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE,
                                             modifiers: [.maskAlternate])
        _ = defaultChordState.transition(for: event(.flagsChanged,
                                                     keycode: RIGHT_COMMAND_KEYCODE,
                                                     flags: CGEventFlags.maskCommand.rawValue),
                                         hotkey: rightCommand,
                                         enterHotkey: defaultEnterChord,
                                         triggerMode: .hold,
                                         isRecording: false)
        try expect(
            defaultChordState.transition(for: event(.flagsChanged,
                                                     keycode: RIGHT_OPTION_KEYCODE,
                                                     flags: CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue),
                                         hotkey: rightCommand,
                                         enterHotkey: defaultEnterChord,
                                         triggerMode: .hold,
                                         isRecording: true),
            equals: HotkeyTransitionResult(suppress: false, actions: [.releaseAlternate]),
            "the default Option+Right Command chord should fire alternate completion mid-recording"
        )

        // Negative: a primary hotkey that is NOT the chord's base key
        // must not adopt anything — the chord still requires its own
        // modifier press to be seen.
        var unrelatedState = HotkeyTransitionState()
        let f5Primary = hotkeyChoice(forKeycode: 96)
        try expect(
            unrelatedState.transition(for: event(.flagsChanged,
                                                  keycode: LEFT_CONTROL_KEYCODE,
                                                  flags: CGEventFlags.maskControl.rawValue),
                                       hotkey: f5Primary,
                                       enterHotkey: enterChord,
                                       triggerMode: .hold,
                                       isRecording: true),
            equals: .pass,
            "without the chord's base modifier held, the extra modifier alone must not fire alternate completion"
        )
    }

    private static func testFKeyAutoRepeatSuppressesWithoutAction() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)

        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "initial F-key keyDown should press"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode, isAutoRepeat: true), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .suppressOnly,
            "F-key autorepeat keyDown should suppress without action"
        )
    }

    private static func testRightModifierReleaseWithLeftFlagStillSet() throws {
        var state = HotkeyTransitionState()
        let rightOption = hotkeyChoice(forKeycode: 61)
        let alternate = CGEventFlags.maskAlternate.rawValue

        try expect(
            state.transition(for: event(.flagsChanged, keycode: rightOption.keycode, flags: alternate), hotkey: rightOption, triggerMode: .hold, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "right modifier flagsChanged should press"
        )
        try expect(
            state.transition(for: event(.flagsChanged, keycode: rightOption.keycode, flags: alternate), hotkey: rightOption, triggerMode: .hold, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "right modifier release should be recognized while left-side flag remains set"
        )

        var toggleState = HotkeyTransitionState()
        try expect(
            toggleState.transition(for: event(.flagsChanged,
                                              keycode: rightOption.keycode,
                                              flags: alternate),
                                   hotkey: rightOption,
                                   triggerMode: .toggle,
                                   isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "right Option should start when it is the configured toggle hotkey"
        )
        _ = toggleState.transition(for: event(.flagsChanged,
                                              keycode: rightOption.keycode),
                                   hotkey: rightOption,
                                   triggerMode: .toggle,
                                   isRecording: true)
        try expect(
            toggleState.transition(for: event(.flagsChanged,
                                              keycode: rightOption.keycode,
                                              flags: alternate),
                                   hotkey: rightOption,
                                   triggerMode: .toggle,
                                   isRecording: true),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "right Option should stop instead of being swallowed by the Enter chord"
        )
    }

    private static func testHistoryChordShowsOverlay() throws {
        let rightCommand = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE)
        let commandShift = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue

        var shiftAlone = HotkeyTransitionState()
        try expect(
            shiftAlone.transition(for: event(.flagsChanged,
                                            keycode: RIGHT_SHIFT_KEYCODE,
                                            flags: CGEventFlags.maskShift.rawValue),
                                  hotkey: rightCommand,
                                  triggerMode: .toggle,
                                  isRecording: false),
            equals: .pass,
            "Shift alone must pass through for app gestures such as Blender navigation"
        )
        try expect(
            shiftAlone.transition(for: event(.flagsChanged,
                                            keycode: RIGHT_SHIFT_KEYCODE,
                                            flags: 0),
                                  hotkey: rightCommand,
                                  triggerMode: .toggle,
                                  isRecording: false),
            equals: .pass,
            "Shift release must pass through when the history chord never completed"
        )

        var shiftFirst = HotkeyTransitionState()
        try expect(
            shiftFirst.transition(for: event(.flagsChanged,
                                             keycode: RIGHT_SHIFT_KEYCODE,
                                             flags: CGEventFlags.maskShift.rawValue),
                                  hotkey: rightCommand,
                                  triggerMode: .toggle,
                                  isRecording: false),
            equals: .pass,
            "the first key of the history chord must remain available to other apps"
        )
        try expect(
            shiftFirst.transition(for: event(.flagsChanged,
                                             keycode: RIGHT_COMMAND_KEYCODE,
                                             flags: commandShift),
                                  hotkey: rightCommand,
                                  triggerMode: .toggle,
                                  isRecording: false),
            equals: HotkeyTransitionResult(suppress: false, actions: [.showHistory]),
            "right shift then right command should show history without stealing modifiers"
        )
        try expect(
            shiftFirst.transition(for: event(.flagsChanged,
                                             keycode: RIGHT_COMMAND_KEYCODE,
                                             flags: CGEventFlags.maskShift.rawValue),
                                  hotkey: rightCommand,
                                  triggerMode: .toggle,
                                  isRecording: false),
            equals: .pass,
            "history chord should pass the paired right command release"
        )
        try expect(
            shiftFirst.transition(for: event(.flagsChanged,
                                             keycode: RIGHT_SHIFT_KEYCODE,
                                             flags: 0),
                                  hotkey: rightCommand,
                                  triggerMode: .toggle,
                                  isRecording: false),
            equals: .pass,
            "history chord should pass the paired right shift release"
        )

        var requiredModifierReleasedFirst = HotkeyTransitionState()
        _ = requiredModifierReleasedFirst.transition(
            for: event(.flagsChanged,
                       keycode: RIGHT_SHIFT_KEYCODE,
                       flags: CGEventFlags.maskShift.rawValue),
            hotkey: rightCommand,
            triggerMode: .toggle,
            isRecording: false
        )
        _ = requiredModifierReleasedFirst.transition(
            for: event(.flagsChanged,
                       keycode: RIGHT_COMMAND_KEYCODE,
                       flags: commandShift),
            hotkey: rightCommand,
            triggerMode: .toggle,
            isRecording: false
        )
        try expect(
            requiredModifierReleasedFirst.transition(
                for: event(.flagsChanged,
                           keycode: RIGHT_SHIFT_KEYCODE,
                           flags: CGEventFlags.maskCommand.rawValue),
                hotkey: rightCommand,
                triggerMode: .toggle,
                isRecording: false
            ),
            equals: .pass,
            "releasing Shift first should remain visible to the frontmost app"
        )
        try expect(
            requiredModifierReleasedFirst.transition(
                for: event(.flagsChanged,
                           keycode: RIGHT_COMMAND_KEYCODE,
                           flags: 0),
                hotkey: rightCommand,
                triggerMode: .toggle,
                isRecording: false
            ),
            equals: .pass,
            "releasing right Command last should clear the history chord without interception"
        )
        try expect(
            requiredModifierReleasedFirst.transition(
                for: event(.flagsChanged,
                           keycode: LEFT_COMMAND_KEYCODE,
                           flags: CGEventFlags.maskCommand.rawValue),
                hotkey: rightCommand,
                triggerMode: .toggle,
                isRecording: false
            ),
            equals: .pass,
            "left Command must not reuse stale right Command state"
        )
        try expect(
            requiredModifierReleasedFirst.transition(
                for: event(.flagsChanged,
                           keycode: RIGHT_SHIFT_KEYCODE,
                           flags: commandShift),
                hotkey: rightCommand,
                triggerMode: .toggle,
                isRecording: false
            ),
            equals: .pass,
            "left Command plus Shift must pass through and not trigger right Command history"
        )

        var commandFirst = HotkeyTransitionState()
        try expect(
            commandFirst.transition(for: event(.flagsChanged,
                                               keycode: RIGHT_COMMAND_KEYCODE,
                                               flags: CGEventFlags.maskCommand.rawValue),
                                    hotkey: rightCommand,
                                    triggerMode: .toggle,
                                    isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "right command alone should still start toggle dictation"
        )
        try expect(
            commandFirst.transition(for: event(.flagsChanged,
                                               keycode: RIGHT_SHIFT_KEYCODE,
                                               flags: commandShift),
                                    hotkey: rightCommand,
                                    triggerMode: .toggle,
                                    isRecording: true),
            equals: HotkeyTransitionResult(suppress: false, actions: [.showHistory]),
            "history chord should show history without canceling dictation or stealing Shift"
        )
        try expect(
            commandFirst.transition(for: event(.flagsChanged,
                                               keycode: RIGHT_COMMAND_KEYCODE,
                                               flags: CGEventFlags.maskShift.rawValue),
                                    hotkey: rightCommand,
                                    triggerMode: .toggle,
                                    isRecording: true),
            equals: .pass,
            "history chord should pass the paired right command release while recording"
        )
        try expect(
            commandFirst.transition(for: event(.flagsChanged,
                                               keycode: RIGHT_SHIFT_KEYCODE,
                                               flags: 0),
                                    hotkey: rightCommand,
                                    triggerMode: .toggle,
                                    isRecording: true),
            equals: .pass,
            "history chord should pass the paired right shift release"
        )
        try expect(
            commandFirst.transition(for: event(.flagsChanged,
                                               keycode: RIGHT_COMMAND_KEYCODE,
                                               flags: CGEventFlags.maskCommand.rawValue),
                                    hotkey: rightCommand,
                                    triggerMode: .toggle,
                                    isRecording: true),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "right command after the history chord should still stop active dictation"
        )
    }

    private static func testConfigurableHistoryShortcut() throws {
        var state = HotkeyTransitionState()
        let standard = hotkeyChoice(forKeycode: 96)
        let history = hotkeyChoice(forKeycode: 40,
                                   modifiers: [.maskCommand, .maskShift])
        let commandShift = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue

        try expect(
            state.transition(for: event(.keyDown,
                                        keycode: 40,
                                        flags: commandShift),
                             hotkey: standard,
                             historyHotkey: history,
                             triggerMode: .toggle,
                             isRecording: true),
            equals: HotkeyTransitionResult(suppress: true, actions: [.showHistory]),
            "a user-configured history shortcut should open history without stopping recording"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: 40),
                             hotkey: standard,
                             historyHotkey: history,
                             triggerMode: .toggle,
                             isRecording: true),
            equals: .suppressOnly,
            "a configurable history shortcut should suppress its paired release"
        )
    }

    private static func testOptionCommandEnterChordStopsWithEnter() throws {
        let rightCommand = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE)
        let alternate = CGEventFlags.maskAlternate.rawValue
        let commandAlternate = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue

        var state = HotkeyTransitionState()
        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_OPTION_KEYCODE,
                                        flags: alternate),
                             hotkey: rightCommand,
                             triggerMode: .toggle,
                             isRecording: true),
            equals: .pass,
            "right Option alone must remain available while recording"
        )
        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_COMMAND_KEYCODE,
                                        flags: commandAlternate),
                             hotkey: rightCommand,
                             triggerMode: .toggle,
                             isRecording: true),
            equals: HotkeyTransitionResult(suppress: false, actions: [.releaseAlternate]),
            "right Option + right Command should stop dictation without stealing modifiers"
        )
        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_COMMAND_KEYCODE,
                                        flags: alternate),
                             hotkey: rightCommand,
                             triggerMode: .toggle,
                             isRecording: false),
            equals: .pass,
            "enter chord should pass the paired right command release"
        )
        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_OPTION_KEYCODE,
                                        flags: 0),
                             hotkey: rightCommand,
                             triggerMode: .toggle,
                             isRecording: false),
            equals: .pass,
            "enter chord should pass the paired right Option release"
        )

    }

    private static func testEnterShortcutModeSelection() throws {
        try expect(
            shouldPressEnterAfterDictation(shortcut: .standard,
                                           primaryBehavior: .insert),
            equals: false,
            "insert mode should make the primary shortcut finish without Enter"
        )
        try expect(
            shouldPressEnterAfterDictation(shortcut: .alternate,
                                           primaryBehavior: .insert),
            equals: true,
            "the alternate shortcut should invert insert mode"
        )
        try expect(
            shouldPressEnterAfterDictation(shortcut: .standard,
                                           primaryBehavior: .insertAndEnter),
            equals: true,
            "insert-and-Enter mode should make the primary shortcut press Enter"
        )
        try expect(
            shouldPressEnterAfterDictation(shortcut: .alternate,
                                           primaryBehavior: .insertAndEnter),
            equals: false,
            "the alternate shortcut should invert insert-and-Enter mode"
        )

        var state = HotkeyTransitionState()
        let primary = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE)
        let alternate = hotkeyChoice(forKeycode: 96)
        try expect(
            state.transition(for: event(.keyDown, keycode: alternate.keycode),
                             hotkey: primary,
                             enterHotkey: alternate,
                             alternateCompletionEnabled: false,
                             triggerMode: .toggle,
                             isRecording: true),
            equals: .pass,
            "a disabled alternate shortcut should not be intercepted"
        )
    }

    private static func testTogglePressFlipsOnceAndReleaseIsNoOp() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)

        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .toggle, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "first toggle press should start"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: f5.keycode), hotkey: f5, triggerMode: .toggle, isRecording: false),
            equals: .suppressOnly,
            "toggle release should be a no-op"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .toggle, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "second toggle press should stop"
        )
    }

    private static func testToggleGatedPressDoesNotFlipToggleState() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)

        // A press the app would reject (e.g. a transcription in
        // flight) must suppress the key but not flip the toggle —
        // otherwise the next press emits a swallowed .release and
        // only the third press records.
        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .toggle, isRecording: false, canStartRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.rejectedBusyPress]),
            "gated toggle press should suppress without flipping state but emit rejectedBusyPress for feedback"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .toggle, isRecording: false, canStartRecording: true),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "press after a gated press should start immediately"
        )
        // The stop-side press must NOT be gated: once a recording is
        // active (canStartRecording is false by definition), the
        // press still has to stop it.
        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .toggle, isRecording: true, canStartRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "gate must not block the toggle press that stops a recording"
        )
        // Hold mode ignores the gate entirely — handlePress discarding
        // the press leaves no state behind in hold mode.
        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .hold, isRecording: false, canStartRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "hold-mode press should be unaffected by the gate"
        )
    }

    private static func testEscapePassesThroughWhenNotRecording() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)

        try expect(
            state.transition(for: event(.keyDown, keycode: ESCAPE_KEYCODE), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .pass,
            "Escape keyDown should pass through when not recording"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: ESCAPE_KEYCODE, isAutoRepeat: true), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .pass,
            "Escape autorepeat should pass through when not recording"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: ESCAPE_KEYCODE), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .pass,
            "Escape keyUp should pass through when not recording"
        )
    }

    private static func testEscapeSuppressesCancelRepeatAndKeyUpWhileRecording() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)

        try expect(
            state.transition(for: event(.keyDown, keycode: ESCAPE_KEYCODE), hotkey: f5, triggerMode: .hold, isRecording: true),
            equals: HotkeyTransitionResult(suppress: true, actions: [.cancel]),
            "Escape keyDown should suppress and cancel while recording"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: ESCAPE_KEYCODE, isAutoRepeat: true), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .suppressOnly,
            "Escape autorepeat from a canceled press should stay suppressed"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: ESCAPE_KEYCODE), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .suppressOnly,
            "paired Escape keyUp should stay suppressed after cancel"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: ESCAPE_KEYCODE), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .pass,
            "later Escape keyUp should pass through once the canceled press is complete"
        )
    }

    // MARK: - Overlap assembly (Task 9)
    //
    // `assembleOverlapTranscript` is the whole genuinely-new integration
    // step, and it is a pure synchronous function over synthetic data —
    // no `TranscriptionWorker`, no models, no protocol seam needed on the
    // concrete actor. Everything below runs with zero model files staged.

    /// Builds a window whose owned span is [ownedStart, ownedEnd) with
    /// `overlapBefore`/`overlapAfter` samples borrowed from its neighbors.
    /// `samples` content is irrelevant to assembly (only the oracle reads
    /// audio, and these tests pin the oracle), so it's zero-filled.
    private static func assemblyWindow(ownedStart: Int, ownedEnd: Int,
                                       overlapBefore: Int = 0, overlapAfter: Int = 0,
                                       hasSignal: Bool = true) -> AudioWindow {
        AudioWindow(samples: [Float](repeating: 0, count: (ownedEnd - ownedStart) + overlapBefore + overlapAfter),
                    startSample: ownedStart - overlapBefore,
                    ownedStartSample: ownedStart,
                    ownedEndSample: ownedEnd,
                    hasSignal: hasSignal)
    }

    private static func word(_ text: String, _ start: Double) -> TranscribedWord {
        TranscribedWord(w: text, start: start, end: start + 0.1, conf: 0.9)
    }

    /// A `BoundaryOracle` that always answers a fixed absolute offset —
    /// lets these tests pin seam placement deterministically instead of
    /// depending on synthetic-audio energy.
    private struct FixedBoundaryOracle: BoundaryOracle {
        let split: Int
        func chooseSplit(samples: [Float], zoneStartSample: Int, zoneEndSample: Int, sampleRate: Double) -> Int? {
            split
        }
    }

    private static func testOverlapAssembly() throws {
        let rate = SAMPLE_RATE  // 16000

        // --- 1) THE ANTI-CATASTROPHE REGRESSION -----------------------
        // A single window of fast, evenly-spaced speech (150ms between word
        // starts — well inside `dedupSeam`'s 240ms tolerance) must come
        // back with EVERY word intact. Running Task 8's whole-list
        // `dedupSeam` over an assembled transcript would delete most of
        // these; the seam-scoped `dedupAcrossSeam` the assembly actually
        // uses must not touch them at all.
        let fastWords = (0..<40).map { word("w\($0)", Double($0) * 0.15) }
        let singleWindow = assemblyWindow(ownedStart: 0, ownedEnd: Int(6.0 * rate))
        let fastResult = try assembleOverlapTranscript(
            windows: [singleWindow], perWindowWords: [fastWords],
            fullSamples: [Float](repeating: 0, count: Int(6.0 * rate)),
            sampleRate: rate, boundaryOracles: [])
        try expect(fastResult.text.split(separator: " ").count, equals: 40,
                   "every word of a 150ms-spaced stream must survive assembly (whole-list dedup would delete most of them)")
        try expect(fastResult.droppedAtSeams, equals: 0, "a single-window dictation has no seams to dedup at")
        // Sanity: this fixture really would be destroyed by the whole-list form.
        let wholeListSurvivors = dedupSeam(fastWords.map { AbsoluteToken(text: $0.w, absoluteSeconds: $0.start) }).count
        try expect(wholeListSurvivors < 40, equals: true,
                   "fixture check: whole-list dedupSeam really does drop words from a 150ms-spaced stream (got \(wholeListSurvivors)/40)")

        // --- 2) A duplicated word at a seam is deduped exactly once ----
        // Two windows meeting at sample 32000 (2.0s), each with 0.5s of
        // overlap. "beta" is emitted by BOTH decoders around the seam.
        let seamSample = Int(2.0 * rate)
        let overlap = Int(0.5 * rate)
        let leftWindow = assemblyWindow(ownedStart: 0, ownedEnd: seamSample, overlapAfter: overlap)
        let rightWindow = assemblyWindow(ownedStart: seamSample, ownedEnd: Int(4.0 * rate), overlapBefore: overlap)
        let full = [Float](repeating: 0, count: Int(4.0 * rate))
        // Left window's words are relative to its own start (sample 0).
        let leftWords = [word("alpha", 1.50), word("beta", 1.95)]
        // Right window starts at 2.0s - 0.5s = 1.5s absolute, so its
        // relative 0.55 is absolute 2.05 — the same "beta", 100ms later.
        let rightWords = [word("beta", 0.55), word("gamma", 1.00)]
        let dedupResult = try assembleOverlapTranscript(
            windows: [leftWindow, rightWindow], perWindowWords: [leftWords, rightWords],
            fullSamples: full, sampleRate: rate,
            boundaryOracles: [FixedBoundaryOracle(split: seamSample)])
        try expect(dedupResult.text, equals: "alpha beta gamma",
                   "the duplicated seam word must appear exactly once, from the EARLIER window")
        try expect(dedupResult.droppedAtSeams, equals: 1, "exactly one word should have been deduped")

        // --- 3) A word past the tolerance band is never dropped -------
        // Same geometry, but the right window's first word lands 0.5s after
        // the split — outside the 240ms band, so it can't be a duplicate.
        let farResult = try assembleOverlapTranscript(
            windows: [leftWindow, rightWindow],
            perWindowWords: [leftWords, [word("delta", 1.00), word("gamma", 1.50)]],
            fullSamples: full, sampleRate: rate,
            boundaryOracles: [FixedBoundaryOracle(split: seamSample)])
        try expect(farResult.text, equals: "alpha beta delta gamma",
                   "a word comfortably past the seam tolerance band must always be kept")
        try expect(farResult.droppedAtSeams, equals: 0, "nothing should be deduped when nothing is inside the band")

        // --- 4) An oracle-refined split really moves ownership --------
        // Push the split 0.4s EARLIER (to 1.6s). "beta" (absolute 1.95, in
        // the left window) now belongs to the right window, so the left
        // window's copy is discarded by the ownership filter and the right
        // window's copy is what survives.
        let movedResult = try assembleOverlapTranscript(
            windows: [leftWindow, rightWindow], perWindowWords: [leftWords, rightWords],
            fullSamples: full, sampleRate: rate,
            boundaryOracles: [FixedBoundaryOracle(split: Int(1.6 * rate))])
        try expect(movedResult.text, equals: "alpha beta gamma",
                   "moving the split earlier reassigns the seam word to the later window without duplicating or losing it")
        try expect(movedResult.seamSplitSamples, equals: [Int(1.6 * rate)],
                   "the oracle's refined split should be the one actually used")

        // --- 5) Zero-width overlap zone must not crash ----------------
        // Two back-to-back windows with no overlap budget at all.
        let tightLeft = assemblyWindow(ownedStart: 0, ownedEnd: seamSample)
        let tightRight = assemblyWindow(ownedStart: seamSample, ownedEnd: Int(4.0 * rate))
        let tightResult = try assembleOverlapTranscript(
            windows: [tightLeft, tightRight],
            perWindowWords: [[word("alpha", 1.0)], [word("gamma", 1.0)]],
            fullSamples: full, sampleRate: rate,
            boundaryOracles: [MelEnergyBoundaryOracle()])
        try expect(tightResult.text, equals: "alpha gamma", "a zero-width overlap zone falls back to the nominal seam")
        try expect(tightResult.seamSplitSamples, equals: [seamSample], "zero-width zone keeps the nominal seam")

        // --- 6) A signal-bearing window with no words aborts the path -
        // This is the guarantee that the overlap path can never lose audio
        // more quietly than v0.4.6 does: it refuses to return at all, so
        // `transcribeSegmented` re-runs the dictation on the plain path
        // (which retries per segment and sets `hadSegmentFailure`).
        var threwOnLoss = false
        do {
            _ = try assembleOverlapTranscript(
                windows: [leftWindow, rightWindow], perWindowWords: [leftWords, []],
                fullSamples: full, sampleRate: rate,
                boundaryOracles: [FixedBoundaryOracle(split: seamSample)])
        } catch OverlapAssemblyError.signalBearingWindowProducedNoWords {
            threwOnLoss = true
        }
        try expect(threwOnLoss, equals: true,
                   "a signal-bearing window that produced nothing must abort the overlap path, not silently drop audio")

        // A window with NO signal producing nothing is legitimate silence.
        let silentRight = assemblyWindow(ownedStart: seamSample, ownedEnd: Int(4.0 * rate),
                                         overlapBefore: overlap, hasSignal: false)
        let silentResult = try assembleOverlapTranscript(
            windows: [leftWindow, silentRight], perWindowWords: [leftWords, []],
            fullSamples: full, sampleRate: rate,
            boundaryOracles: [FixedBoundaryOracle(split: seamSample)])
        try expect(silentResult.text, equals: "alpha beta", "a genuinely silent window contributing nothing is not a failure")

        // --- 7) Shape/emptiness guards --------------------------------
        var threwShape = false
        do {
            _ = try assembleOverlapTranscript(windows: [leftWindow, rightWindow], perWindowWords: [leftWords],
                                              fullSamples: full, sampleRate: rate, boundaryOracles: [])
        } catch OverlapAssemblyError.shapeMismatch { threwShape = true }
        try expect(threwShape, equals: true, "mismatched window/word-list counts must throw, not index out of range")

        var threwEmpty = false
        do {
            _ = try assembleOverlapTranscript(windows: [assemblyWindow(ownedStart: 0, ownedEnd: 100, hasSignal: false)],
                                              perWindowWords: [[]], fullSamples: full, sampleRate: rate,
                                              boundaryOracles: [])
        } catch OverlapAssemblyError.emptyTranscript { threwEmpty = true }
        try expect(threwEmpty, equals: true, "an entirely empty transcript must throw so the plain path takes over")

        // --- 8) `words` decodes from the REAL bridge JSON shape --------
        // The exact document `parakeet_capi_transcribe_pcm_batch_json`
        // documents (a one-element ARRAY carrying both "words" and
        // "tokens"), so the words-over-tokens decision stays verified.
        let realShapeJSON = """
        [{"text":"hello world","frame_sec":0.080000,\
        "words":[{"w":"hello","start":0.480,"end":0.640,"conf":0.9100},{"w":"world","start":0.720,"end":0.960,"conf":0.8800}],\
        "tokens":[{"id":123,"t":0.480,"conf":0.9100}]}]
        """
        let realDecoded = try decodeTokenTranscription(json: realShapeJSON)
        try expect(realDecoded.words.count, equals: 2, "the real bridge JSON shape's words array should decode")
        try expect(realDecoded.words[0].w, equals: "hello", "first decoded word text")
        try expect(realDecoded.words[1].start, equals: 0.720, "second decoded word start time")
        try expect(realDecoded.tokens.count, equals: 1, "tokens must still decode alongside words")

        // --- 9) A malformed word timestamp must never crash the process -
        // A corrupted/malformed bridge response could in principle hand us
        // a non-finite or absurdly large `word.start` that survived JSON
        // decoding (e.g. via a future bridge change). The `Int(...)`
        // sample-offset conversion traps on overflow/NaN, so this word
        // must be skipped BEFORE that conversion rather than reaching it —
        // and every other, well-formed word in the same window must still
        // come through untouched.
        let malformedWords = [
            word("alpha", 1.0),
            word("nan", .nan),
            word("inf", .infinity),
            word("neginf", -.infinity),
            word("huge", 1e12),
            word("beta", 1.4),
        ]
        let malformedResult = try assembleOverlapTranscript(
            windows: [singleWindow], perWindowWords: [malformedWords],
            fullSamples: [Float](repeating: 0, count: Int(6.0 * rate)),
            sampleRate: rate, boundaryOracles: [])
        try expect(malformedResult.text, equals: "alpha beta",
                   "non-finite and absurdly large word timestamps must be skipped, not crash assembly, while sane words survive")
    }

    /// Gated real-hardware end-to-end check for the overlap path. Skipped
    /// (not failed) unless `SUPERDICTATE_PARAKEET_MODEL` points at a real
    /// GGUF and `SUPERDICTATE_OVERLAP_TEST_WAV` at a genuinely long
    /// (multi-segment) 16-bit PCM WAV. `SUPERDICTATE_SILERO_VAD_MODEL` is
    /// optional — without it the chain runs mel-energy/midpoint, which is
    /// itself a supported production configuration.
    ///
    /// Never touches `TranscriptionWorker` or any app state: it drives
    /// `ParakeetEngine` directly and calls the SAME pure
    /// `assembleOverlapTranscript` production uses.
    private static func testOverlapTranscriptionRealModel() throws {
        guard let modelPath = ProcessInfo.processInfo.environment["SUPERDICTATE_PARAKEET_MODEL"],
              FileManager.default.fileExists(atPath: modelPath),
              let wavPath = ProcessInfo.processInfo.environment["SUPERDICTATE_OVERLAP_TEST_WAV"],
              FileManager.default.fileExists(atPath: wavPath) else {
            print("SKIP overlap-transcription-real: needs SUPERDICTATE_PARAKEET_MODEL + SUPERDICTATE_OVERLAP_TEST_WAV")
            return
        }

        let (wavSamples, wavRate) = try loadWavMonoFloat32(path: wavPath)
        guard wavRate == UInt32(SAMPLE_RATE) else {
            throw SelfTestFailure.failed("overlap-transcription-real needs a 16 kHz WAV, got \(wavRate) Hz")
        }
        let audioSeconds = Double(wavSamples.count) / SAMPLE_RATE
        let segments = PauseSegmenter.segment(samples: wavSamples, sampleRate: SAMPLE_RATE)
        print("OVERLAP REAL: \(String(format: "%.1f", audioSeconds))s audio -> \(segments.count) segment(s)")
        guard segments.count > 1 else {
            throw SelfTestFailure.failed("overlap-transcription-real needs a multi-segment fixture; \(wavPath) produced \(segments.count)")
        }

        let engine = try ParakeetEngine(modelPath: modelPath, device: .cpu,
                                        threadCount: TranscriptionWorker.resolvedParakeetThreadCount())
        defer { _ = try? runParakeetEngineSynchronously { await engine.shutdown() } }
        try runParakeetEngineSynchronously { try await engine.warmUp() }

        // --- The overlap path ---
        let windows = OverlapWindower.addOverlap(to: segments, sampleRate: SAMPLE_RATE)
        var perWindowWords: [[TranscribedWord]] = []
        let overlapStarted = ProcessInfo.processInfo.systemUptime
        for window in windows {
            let transcription = try runParakeetEngineSynchronously {
                try await engine.transcribeWithTokens(samples: window.samples)
            }
            perWindowWords.append(transcription.words)
        }
        let overlapSeconds = ProcessInfo.processInfo.systemUptime - overlapStarted

        // Measure how tightly real words are actually spaced — this is the
        // evidence behind `dedupAcrossSeam`'s doc comment (i.e. why Task
        // 8's whole-list `dedupSeam` is NOT applied to the whole stream).
        var gapsWithinTolerance = 0
        var totalGaps = 0
        for words in perWindowWords where words.count > 1 {
            for i in 1..<words.count {
                totalGaps += 1
                if words[i].start - words[i - 1].start <= 0.24 { gapsWithinTolerance += 1 }
            }
        }
        print("OVERLAP REAL: inter-word start gaps <= 0.24s: \(gapsWithinTolerance)/\(totalGaps)")

        var oracles: [BoundaryOracle] = []
        var vad: SileroVadEngine?
        defer { vad?.shutdown() }
        if let vadPath = ProcessInfo.processInfo.environment["SUPERDICTATE_SILERO_VAD_MODEL"],
           FileManager.default.fileExists(atPath: vadPath),
           let loaded = try? SileroVadEngine(modelPath: vadPath) {
            vad = loaded
            oracles.append(VadBoundaryOracle(engine: loaded))
            print("OVERLAP REAL: Silero VAD loaded — VAD seam placement active")
        } else {
            print("OVERLAP REAL: no Silero VAD model — mel-energy/midpoint seam placement (a supported production config)")
        }
        oracles.append(MelEnergyBoundaryOracle())

        let assembled = try assembleOverlapTranscript(windows: windows, perWindowWords: perWindowWords,
                                                      fullSamples: wavSamples, sampleRate: SAMPLE_RATE,
                                                      boundaryOracles: oracles)
        print("OVERLAP REAL: \(windows.count) windows, splits \(assembled.seamSplitSamples), \(assembled.droppedAtSeams) deduped, \(String(format: "%.1f", overlapSeconds))s wall clock")
        print("OVERLAP REAL text: \(assembled.text)")

        guard !assembled.text.isEmpty else {
            throw SelfTestFailure.failed("overlap path produced an empty transcript on a real multi-segment recording")
        }
        // No runaway blowup: this whole feature exists to keep long
        // dictations off the encoder's superlinear cost curve, so the
        // overlap path must stay comfortably real-time-ish on CPU.
        guard overlapSeconds < audioSeconds * 4 else {
            throw SelfTestFailure.failed("overlap path took \(overlapSeconds)s for \(audioSeconds)s of audio — runaway cost")
        }
        // No obviously duplicated word run anywhere (the failure mode
        // overlap+dedup exists to prevent): no 3-word sequence repeated
        // back-to-back.
        let allWords = assembled.text.split(separator: " ").map(String.init)
        if allWords.count >= 6 {
            for i in 0...(allWords.count - 6) {
                let a = allWords[i..<(i + 3)]
                let b = allWords[(i + 3)..<(i + 6)]
                if a.elementsEqual(b) {
                    throw SelfTestFailure.failed("duplicated 3-word run at index \(i): \(Array(a))")
                }
            }
        }

        // --- Side-by-side against the plain (v0.4.6) path -------------
        let plainStarted = ProcessInfo.processInfo.systemUptime
        var plainPieces: [String] = []
        for segment in segments {
            let result = try runParakeetEngineSynchronously { try await engine.transcribe(samples: segment.samples) }
            if !result.text.isEmpty { plainPieces.append(result.text) }
        }
        let plainSeconds = ProcessInfo.processInfo.systemUptime - plainStarted
        print("PLAIN  REAL: \(String(format: "%.1f", plainSeconds))s wall clock")
        print("PLAIN  REAL text: \(plainPieces.joined(separator: " "))")
    }

    private static func testTokenTranscriptionDecode() throws {
        // Test: well-formed single-clip array JSON decodes correctly
        let wellFormedJSON = """
        [{"text":"hello world","frame_sec":0.080000,"tokens":[{"id":123,"t":0.480,"conf":0.9100},{"id":456,"t":0.640,"conf":0.8900}]}]
        """
        let decoded = try decodeTokenTranscription(json: wellFormedJSON)
        try expect(decoded.text, equals: "hello world", "decoded text should match input")
        try expect(decoded.frameSec, equals: 0.080000, "decoded frameSec should match input")
        try expect(decoded.tokens.count, equals: 2, "decoded tokens array should have 2 elements")
        try expect(decoded.tokens[0].id, equals: 123, "first token id should be 123")
        try expect(decoded.tokens[0].t, equals: 0.480, "first token timestamp should be 0.480")
        try expect(decoded.tokens[0].conf, equals: 0.9100, "first token confidence should be 0.9100")
        try expect(decoded.tokens[1].id, equals: 456, "second token id should be 456")
        try expect(decoded.tokens[1].t, equals: 0.640, "second token timestamp should be 0.640")
        try expect(decoded.tokens[1].conf, equals: 0.8900, "second token confidence should be 0.8900")

        // Test: empty array throws .emptyArray
        let emptyJSON = "[]"
        var threwEmptyArray = false
        do {
            _ = try decodeTokenTranscription(json: emptyJSON)
        } catch TokenTranscriptionDecodeError.emptyArray {
            threwEmptyArray = true
        }
        try expect(threwEmptyArray, equals: true, "empty JSON array should throw .emptyArray")

        // Test: malformed JSON throws .malformedJSON
        let malformedJSON = "\"not json\""
        var threwMalformedJSON = false
        do {
            _ = try decodeTokenTranscription(json: malformedJSON)
        } catch TokenTranscriptionDecodeError.malformedJSON {
            threwMalformedJSON = true
        }
        try expect(threwMalformedJSON, equals: true, "malformed JSON should throw .malformedJSON")

        // Test: array with multiple elements takes the first
        let multiElementJSON = """
        [{"text":"first","frame_sec":0.080000,"tokens":[]},{"text":"second","frame_sec":0.080000,"tokens":[]}]
        """
        let decodedMulti = try decodeTokenTranscription(json: multiElementJSON)
        try expect(decodedMulti.text, equals: "first", "when given multiple array elements, should take the first")
    }

    private static func event(
        _ type: CGEventType,
        keycode: CGKeyCode,
        flags: UInt64 = 0,
        isAutoRepeat: Bool = false
    ) -> HotkeyEventSnapshot {
        HotkeyEventSnapshot(
            typeRawValue: type.rawValue,
            keycode: keycode,
            flagsRawValue: flags,
            isAutoRepeat: isAutoRepeat
        )
    }

    private static func expect<T: Equatable>(
        _ actual: T,
        equals expected: T,
        _ message: String
    ) throws {
        guard actual == expected else {
            throw SelfTestFailure.failed("\(message): got \(actual), expected \(expected)")
        }
    }
}

#endif
