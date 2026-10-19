// Parakey — push-to-talk dictation for macOS.
//
// Swift menu-bar app. The runtime covers hotkey capture (`CGEventTap`), audio capture
// (`AVAudioEngine`), transcription (Parakeet via ONNX Runtime in the
// SuperDictateOnnxHost helper, CPU only — the GPU is for the LLM host),
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
import CryptoKit
import Darwin
import ApplicationServices
import IOKit
import QuartzCore
import ServiceManagement
import UniformTypeIdentifiers

#if DEBUG
if let status = ParakeySelfTest.run(arguments: Array(CommandLine.arguments.dropFirst())) {
    exit(status)
}
#endif

let app = NSApplication.shared
let launchArguments = Array(CommandLine.arguments.dropFirst())
if let benchmarkResult = runASRBenchmarkDiagnostic(arguments: launchArguments) {
    exit(benchmarkResult)
} else if let streamingResult = runStreamingASRBenchmarkDiagnostic(arguments: launchArguments) {
    exit(streamingResult)
} else if let diagnosticResult = runAudioCaptureDiagnostic(arguments: launchArguments) {
    exit(diagnosticResult)
} else if launchArguments.first == RECORDING_HUD_EXPORT_ARGUMENT {
    guard launchArguments.count == 2 else {
        fputs("usage: SuperDictate --export-hud-animation <frames-directory>\n", stderr)
        exit(EXIT_FAILURE)
    }
    do {
        try exportRecordingHUDAnimationFrames(to: URL(fileURLWithPath: launchArguments[1],
                                                       isDirectory: true))
        exit(EXIT_SUCCESS)
    } catch {
        fputs("HUD export failed: \(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }
} else if let launch = UpdateProgressLaunch(arguments: launchArguments) {
    let delegate = UpdateProgressAppDelegate(launch: launch)
    app.delegate = delegate
    app.run()
} else if launchArguments.contains(AGENT_ARGUMENT) {
    app.setActivationPolicy(.accessory)
    let delegate = ParakeyApp()
    app.delegate = delegate
    // Refuse to start under a tampered launch environment that would
    // redirect the speech model download to an attacker-controlled host.
    // Runs after NSApplication.shared is initialised so NSAlert.runModal
    // has its event loop.
    refuseHostileRegistryEnvironmentAndExit()
    app.run()
} else {
    let delegate = SuperDictateControlPanelApp()
    app.delegate = delegate
    app.run()
}
