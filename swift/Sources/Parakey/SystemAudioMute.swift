// SuperDictate — extracted from the monolithic main.swift
// during the refactor/split-main refactor.
//

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

// MARK: - System audio mute
//
// Mute the system output volume during recording so an open Zoom /
// Music / browser tab doesn't get captured back into the mic and
// transcribed alongside the user's voice. Done via NSAppleScript
// since there's no public AVFoundation knob for it. On release we
// only unmute if WE were the ones who muted — leave alone if the
// user had already muted manually.
//
// Threading: every AppleScript round-trip takes milliseconds at best
// and can stall for much longer under load. The hotkey path runs
// behind a session-wide CGEvent tap on the main run loop, where ANY
// main-thread stall delays every keystroke system-wide and a >1 s
// stall makes macOS disable the tap. So the recording-time mute /
// unmute scripts execute on a dedicated serial queue (the *Async
// wrappers below) and report back to the main actor. The serial
// queue is also the ordering guarantee: a mute enqueued before an
// unmute always executes before it. The synchronous isMuted() /
// unmute() remain for launch-time stale-mute recovery, which runs
// before the event tap exists.

/// Outcome of the "set volume with output muted" command plus its
/// follow-up verification read. The distinction matters for crash
/// recovery: a command that succeeded but could not be VERIFIED must
/// be assumed muted, so the recovery marker and watchdog stay armed.
/// Treating it as a failure would dismantle every recovery mechanism
/// for a mute that may well have happened, leaving the system muted
/// with no way back.
enum SystemAudioMuteCommandOutcome: Equatable, Sendable {
    /// Command ran without error and verification confirmed the
    /// output is muted.
    case muted
    /// Command ran without error but the verification read itself
    /// failed. Assume we muted: keeping recovery armed for a mute
    /// that didn't happen is harmless; the reverse is not.
    case assumedMuted
    /// The command itself failed, or verification definitively
    /// reported the output unmuted. Nothing happened to recover from.
    case failed
}

func systemAudioMuteCommandOutcome(commandSucceeded: Bool,
                                   verifiedMuted: Bool?) -> SystemAudioMuteCommandOutcome {
    guard commandSucceeded else { return .failed }
    switch verifiedMuted {
    case .some(true): return .muted
    case .none: return .assumedMuted
    case .some(false): return .failed
    }
}

enum SystemAudio {
    // NSAppleScript isn't Sendable so we can't memoise it across
    // threads under Swift 6 strict concurrency. AppleScript compile
    // is microseconds — happy to take the per-call cost. Each script
    // instance is created, executed, and discarded entirely on one
    // thread (this serial queue or, for the launch-time sync calls,
    // the main thread), which satisfies NSAppleScript's
    // not-thread-safe contract.
    private static let queue = DispatchQueue(label: "ParakeySystemAudio", qos: .userInitiated)

    /// nil = the query itself failed, as opposed to a definitive
    /// muted/unmuted answer.
    static func mutedState() -> Bool? {
        var err: NSDictionary?
        guard let script = NSAppleScript(source: "output muted of (get volume settings)") else {
            return nil
        }
        let result = script.executeAndReturnError(&err)
        guard err == nil else { return nil }
        return result.booleanValue
    }

    static func isMuted() -> Bool { mutedState() == true }

    static func mute() -> SystemAudioMuteCommandOutcome {
        guard let script = NSAppleScript(source: "set volume with output muted") else {
            return systemAudioMuteCommandOutcome(commandSucceeded: false, verifiedMuted: nil)
        }
        var err: NSDictionary?
        script.executeAndReturnError(&err)
        return systemAudioMuteCommandOutcome(commandSucceeded: err == nil,
                                             verifiedMuted: mutedState())
    }

    @discardableResult
    static func unmute() -> Bool {
        var err: NSDictionary?
        _ = NSAppleScript(source: "set volume without output muted")?.executeAndReturnError(&err)
        // A failed verification counts as "not unmuted": the caller
        // keeps the recovery marker + watchdog armed and retries
        // later, which is the safe direction.
        return err == nil && mutedState() == false
    }

    // Async wrappers — see the threading note above. Completions hop
    // back to the main actor, where all mute-lifecycle state lives.
    static func mutedStateAsync(_ completion: @escaping @MainActor @Sendable (Bool?) -> Void) {
        queue.async {
            let state = mutedState()
            Task { @MainActor in completion(state) }
        }
    }

    static func muteAsync(_ completion: @escaping @MainActor @Sendable (SystemAudioMuteCommandOutcome) -> Void) {
        queue.async {
            let outcome = mute()
            Task { @MainActor in completion(outcome) }
        }
    }

    static func unmuteAsync(_ completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        queue.async {
            let unmuted = unmute()
            Task { @MainActor in completion(unmuted) }
        }
    }
}

// MARK: - System audio mute lifecycle
//
// Pure decision functions for the recording-time mute state machine.
// All phase transitions happen on the main actor; only the
// AppleScript execution itself runs on SystemAudio's serial queue.
// At most one command is in flight at a time — each phase has exactly
// one outstanding completion, which performs the next transition.

enum SystemAudioMutePhase: Equatable, Sendable {
    /// No mute lifecycle active; marker + watchdog disarmed.
    case idle
    /// "is the output already muted?" probe in flight. No marker or
    /// watchdog yet, and nothing has been muted.
    case probing
    /// Marker + watchdog armed; the mute command is in flight.
    case muting
    /// We muted the output; marker + watchdog stay armed until an
    /// unmute succeeds (or the watchdog recovers after a crash).
    case muted
    /// Unmute command in flight; marker + watchdog stay armed until
    /// it succeeds.
    case unmuting
}

enum SystemAudioMuteProbeDecision: Equatable, Sendable {
    /// Do not mute: the output is already muted by the user, the
    /// probe failed (we can't risk stomping a user-set mute we can't
    /// see), or the recording already ended. Nothing to arm or undo.
    case standDown
    /// The output is live and the recording still wants it muted —
    /// arm the recovery marker + watchdog, then issue the mute.
    case armRecoveryAndMute
}

func systemAudioMuteProbeDecision(mutedState: Bool?,
                                  unmuteAlreadyRequested: Bool) -> SystemAudioMuteProbeDecision {
    guard mutedState == false, !unmuteAlreadyRequested else { return .standDown }
    return .armRecoveryAndMute
}

enum SystemAudioMuteCommandDecision: Equatable, Sendable {
    /// The mute definitively failed — disarm the marker + watchdog.
    case disarmRecovery
    /// We are (or must assume we are) muted and the recording is
    /// still running — hold the muted state.
    case stayMuted
    /// We muted, but the recording ended while the command ran —
    /// unmute immediately.
    case beginUnmute
}

func systemAudioMuteCommandDecision(outcome: SystemAudioMuteCommandOutcome,
                                    unmuteAlreadyRequested: Bool) -> SystemAudioMuteCommandDecision {
    switch outcome {
    case .failed:
        return .disarmRecovery
    case .muted, .assumedMuted:
        return unmuteAlreadyRequested ? .beginUnmute : .stayMuted
    }
}

enum SystemAudioUnmuteRequestDecision: Equatable, Sendable {
    /// We never muted (or an unmute is already in flight).
    case nothingToDo
    /// A probe or the mute command is still in flight — record the
    /// request; that command's completion honours it.
    case deferUntilCommandSettles
    /// We hold the mute — issue the unmute now.
    case beginUnmute
}

func systemAudioUnmuteRequestDecision(phase: SystemAudioMutePhase) -> SystemAudioUnmuteRequestDecision {
    switch phase {
    case .idle, .unmuting: return .nothingToDo
    case .probing, .muting: return .deferUntilCommandSettles
    case .muted: return .beginUnmute
    }
}

func systemAudioMuteMarkerURL() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(APP_SUPPORT_DIR_NAME, isDirectory: true)
        .appendingPathComponent("system-audio-muted", isDirectory: false)
}

func systemAudioMuteMarkerText(pid: pid_t = getpid(), date: Date = Date()) -> String {
    """
    pid=\(pid)
    created=\(ISO8601DateFormatter().string(from: date))
    """
}

func systemAudioMuteMarkerProcessID(from text: String) -> pid_t? {
    for line in text.split(separator: "\n") {
        guard line.hasPrefix("pid="),
              let raw = Int32(line.dropFirst(4)),
              raw > 0 else { continue }
        return raw
    }
    return nil
}

func writeSystemAudioMuteMarker(to url: URL = systemAudioMuteMarkerURL(),
                                        text: String = systemAudioMuteMarkerText()) throws {
    let fm = FileManager.default
    let directory = url.deletingLastPathComponent()
    try fm.createDirectory(at: directory,
                           withIntermediateDirectories: true,
                           attributes: [.posixPermissions: 0o700])

    let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw currentPOSIXError() }
    defer { Darwin.close(fd) }
    try text.withCString { raw in
        let data = UnsafeRawPointer(raw)
        let count = strlen(raw)
        var written = 0
        while written < count {
            let n = Darwin.write(fd, data.advanced(by: written), count - written)
            guard n >= 0 else { throw currentPOSIXError() }
            written += n
        }
    }
    _ = Darwin.fchmod(fd, 0o600)
}

func removeSystemAudioMuteMarker(at url: URL = systemAudioMuteMarkerURL()) {
    try? FileManager.default.removeItem(at: url)
}

func systemAudioMuteWatchdogScript() -> String {
    #"""
    PID="$1"
    MARKER="$2"

    while /bin/kill -0 "$PID" 2>/dev/null; do
        /bin/sleep 0.5
    done

    if [ -e "$MARKER" ]; then
        /usr/bin/osascript -e 'set volume without output muted' >/dev/null 2>&1 || true
        /bin/rm -f "$MARKER"
    fi
    """#
}

// MARK: - Sounds
//
// Short system sounds: Tink on recording start, Pop after a
// successful paste, Basso when a dictation is dropped. Loaded from
// /System/Library/Sounds so we don't have to bundle audio resources.
