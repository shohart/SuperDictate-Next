// SuperDictate — extracted from the monolithic main.swift
// during the refactor/split-main refactor (update+correction models).
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

enum UpdateCheckSource: String, Equatable {
    case automatic
    case manual
    /// Check fired because the user re-enabled automatic update checks
    /// in the settings menu — user-initiated like .manual but silent like
    /// .automatic, so diagnostics record it as its own source.
    case settingsToggle = "settings_toggle"

    var diagnosticLabel: String {
        switch self {
        case .automatic: return "automatic"
        case .manual: return "manual"
        case .settingsToggle: return "settings toggle"
        }
    }
}

enum UpdateCheckResult: String, Equatable {
    case failed = "failed"
    case upToDate = "up_to_date"
    case available = "available"
    case skipped = "skipped"

    var diagnosticLabel: String {
        switch self {
        case .failed: return "failed or unavailable"
        case .upToDate: return "up to date"
        case .available: return "update available"
        case .skipped: return "skipped version available"
        }
    }
}

func updateCheckResult(for release: GitHubRelease?,
                       currentVersion: String,
                       skippedVersions: [String]) -> UpdateCheckResult {
    guard let release else { return .failed }
    guard isNewer(release.version, than: currentVersion) else { return .upToDate }
    return skippedVersions.contains(release.version) ? .skipped : .available
}

func shouldSuppressUpdateForReminder(version: String,
                                     reminderVersion: String?,
                                     reminderUntil: Date?,
                                     now: Date) -> Bool {
    guard let reminderVersion,
          let reminderUntil,
          reminderVersion == version else {
        return false
    }
    return now < reminderUntil
}

/// True when a fetched release makes a stored "Remind me later" pause
/// stale: either the pause expired for the same version (it is about
/// to be re-shown), or a NEWER release superseded the paused one.
/// Without the newer-version case, pausing v0.3.0 and seeing v0.3.1
/// ship within 24 h left diagnostics showing both "Pending update:
/// v0.3.1" and "Reminder paused: v0.3.0 until …". An OLDER fetched
/// version (e.g. a retracted release) keeps the pause.
func shouldClearUpdateReminderPause(fetchedVersion: String, pausedVersion: String?) -> Bool {
    guard let pausedVersion else { return false }
    return fetchedVersion == pausedVersion || isNewer(fetchedVersion, than: pausedVersion)
}

/// Validates a persisted "Remind me later" expiry read back from
/// UserDefaults. Non-Date values and dates further in the future than
/// one full pause window are treated as corrupt and degrade to nil,
/// so a tampered or clock-skewed value re-arms the reminder instead
/// of suppressing updates indefinitely. Past dates pass through —
/// an expired pause is legitimate state that the suppress logic and
/// `shouldClearUpdateReminderPause` handle.
func normalizedUpdateReminderPauseExpiry(storedValue value: Any?,
                                         now: Date = Date(),
                                         maxPauseSeconds: TimeInterval = UPDATE_REMIND_LATER_SECONDS) -> Date? {
    guard let date = value as? Date else { return nil }
    guard date.timeIntervalSince(now) <= maxPauseSeconds else { return nil }
    return date
}

func updateCheckDiagnosticText(checkedAt: Date?,
                               source: UpdateCheckSource?,
                               result: UpdateCheckResult?,
                               releaseVersion: String) -> String {
    guard let checkedAt else { return "never" }
    let timestamp = ISO8601DateFormatter().string(from: checkedAt)
    let sourceText = source?.diagnosticLabel ?? "unknown source"
    let resultText = result?.diagnosticLabel ?? "unknown result"
    let versionText = releaseVersion.isEmpty ? "" : " (latest v\(releaseVersion))"
    return "\(timestamp), \(sourceText), \(resultText)\(versionText)"
}

struct AudioInputDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

let CORE_AUDIO_DEFAULT_AGGREGATE_PREFIX = "CADefaultDeviceAggregate-"

struct TranscriptCorrection: Codable, Equatable, Sendable {
    let source: String
    let replacement: String
}

