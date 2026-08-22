// SuperDictate — extracted from the monolithic main.swift
// during the refactor/split-main refactor.
//

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

// MARK: - Settings
//
// Thin wrapper around the app's standard NSUserDefaults domain, so
// settings persist at `~/Library/Preferences/com.local.superdictate.plist`.
// One property per user-visible setting; defaults are returned inline
// by each getter when the key is missing, rather than via a central
// `register()` call.

final class Settings: @unchecked Sendable {
    private static let keyHotkeyKeycode = "hotkey_keycode"
    private static let keyHotkeyModifiers = "hotkey_modifiers"
    private static let keyEnterHotkeyKeycode = "enter_hotkey_keycode"
    private static let keyEnterHotkeyModifiers = "enter_hotkey_modifiers"
    private static let keyHistoryHotkeyKeycode = "history_hotkey_keycode"
    private static let keyHistoryHotkeyModifiers = "history_hotkey_modifiers"
    private static let keyCorrectionHotkeyKeycode = "correction_hotkey_keycode"
    private static let keyCorrectionHotkeyModifiers = "correction_hotkey_modifiers"
    private static let keyPrimaryCompletionBehavior = "primary_completion_behavior_v1"
    private static let keyAlternateCompletionEnabled = "alternate_completion_enabled_v1"
    private static let keyInterfaceLanguage = "interface_language"
    private static let keyTriggerMode = "trigger_mode"
    private static let keyPasteSuffix = "paste_suffix"
    private static let keyRecentTranscripts = "recent_transcripts"
    private static let keyRecentTranscriptHistory = "recent_transcript_history"
    private static let keyRecentTranscriptEntries = "recent_transcript_entries_v1"
    private static let keyDailyDictationUsage = "daily_dictation_usage_v1"
    private static let keyDidImportDictationUsageLog = "did_import_dictation_usage_log_v1"
    private static let keyShowRecordingWaveform = "show_recording_waveform"
    private static let keyRecordingHUDRecordingColor = "recording_hud_recording_color"
    private static let keyRecordingHUDTranscribingColor = "recording_hud_transcribing_color"
    private static let keyRecordingHUDBackgroundStyle = "recording_hud_background_style"
    private static let keyRecordingHUDSize = "recording_hud_size"
    private static let keyRecordingHUDDisplayMode = "recording_hud_display_mode"
    private static let legacyKeyShowRecordingIndicator = "show_recording_indicator"
    private static let keyMuteWhileRecording = "mute_while_recording"
    private static let keyAutoStopOnSilenceEnabled = "auto_stop_on_silence_enabled"
    private static let keyAutoStopSilenceSeconds = "auto_stop_silence_seconds"
    private static let keyPlayFeedbackSounds = "play_feedback_sounds"
    private static let keyShowInDock = "show_in_dock"
    private static let keyInputDevice = "input_device"
    private static let keyCheckForUpdates = "check_for_updates"
    private static let keyLastUpdateCheckAt = "last_update_check_at"
    private static let keyLastUpdateCheckSource = "last_update_check_source"
    private static let keyLastUpdateCheckResult = "last_update_check_result"
    private static let keyLastUpdateCheckVersion = "last_update_check_version"
    private static let keyUpdateReminderPausedVersion = "update_reminder_paused_version"
    private static let keyUpdateReminderPausedUntil = "update_reminder_paused_until"
    private static let keyLastSeenVersion = "last_seen_version"
    private static let keySkippedVersions = "skipped_versions"
    private static let keyTranscriptCorrections = "transcript_corrections"
    private static let keyTranscriptCorrectionsSyncFile = "transcript_corrections_sync_file"
    private static let keyDidMigrateTranscriptCorrectionsToSQLite = "did_migrate_transcript_corrections_to_sqlite_v1"
    private static let keyAutoLearnVocabularyEnabled = "auto_learn_vocabulary_enabled_v1"
    private static let keyDictationLanguage = "dictation_language"
    private static let keySpeechModelProfile = "speech_model_profile"
    private static let keyInitialSpeechModelChoiceRequired = "initial_speech_model_choice_required"
    private static let keyRemoveFinalPeriod = "remove_final_period_v1"
    private static let keyRemoveFillerWords = "remove_filler_words"
    private static let keyEnabledFillerPresetKeys = "enabled_filler_preset_keys"
    private static let keyCustomFillerWords = "custom_filler_words"
    private static let keyDisabledCustomFillerWords = "disabled_custom_filler_words"
    private static let keyNormalizeNumbersToDigits = "normalize_numbers_to_digits"
    // New key, deliberately NOT the old "use_gpu" (spec §10: "Do not
    // inherit the old Whisper `useGPU` storage value... the persisted key
    // must be new so an old installation with Whisper Vulkan enabled starts
    // Parakeet on CPU after upgrading"). The Swift property below stays
    // named `useGPU` for minimal call-site churn; only the UserDefaults key
    // changed. `use_gpu` itself is intentionally left unused/unread from
    // here on — it is simply abandoned old state, never migrated.
    private static let keyUseGPU = "parakeet_use_gpu"
    private static let keyEnterDelayMilliseconds = "enter_delay_milliseconds_v1"
    private static let keyActiveRunMarker = "active_run_marker"
    private static let keyAgentEnabled = "agent_enabled"
    private static let keyTextPostprocessingMode = "text_postprocessing_mode_v1"
    private static let keyLLMEngineBackend = "llm_engine_backend_v1"
    private static let keyLLMCustomBaseURL = "llm_custom_base_url_v1"
    private static let keyLLMCustomAPIKey = "llm_custom_api_key_v1"
    private static let keyLLMCustomModelName = "llm_custom_model_name_v1"
    // Tiered correction + rewrite (docs/specs/rewrite-tiered-correction-
    // spec.md §4). Rewrite keys are fully independent from the
    // llm_* correction keys above on purpose: correction and rewrite are
    // two separately-toggleable functions, each able to point at its own
    // OpenAI-compatible endpoint.
    private static let keyCorrectionModelTier = "correction_model_tier_v1"
    private static let keyRewriteEnabled = "rewrite_enabled_v1"
    private static let keyRewriteStyle = "rewrite_style_v1"
    private static let keyRewriteBundledModel = "rewrite_bundled_model_v1"
    private static let keyRewriteEngineBackend = "rewrite_engine_backend_v1"
    private static let keyRewriteCustomBaseURL = "rewrite_custom_base_url_v1"
    private static let keyRewriteCustomAPIKey = "rewrite_custom_api_key_v1"
    private static let keyRewriteCustomModelName = "rewrite_custom_model_name_v1"

    private let defaults: UserDefaults
    let vocabularyStore: VocabularyStore

    static let shared = Settings()

    init(defaults: UserDefaults = .standard, vocabularyStore: VocabularyStore? = nil) {
        self.defaults = defaults
        self.vocabularyStore = vocabularyStore ?? Self.openDefaultVocabularyStore()
        migrateLegacyTranscriptCorrectionsIfNeeded()
    }

    /// A writable Application Support directory is a basic launch
    /// precondition this app already relies on elsewhere (model files,
    /// logs) — not a scenario worth chained fallbacks for. The one
    /// fallback kept here is an in-memory store so a single bad launch
    /// degrades to "corrections don't persist this run" instead of a
    /// crash, since corrections are a convenience feature, not core
    /// dictation functionality.
    private static func openDefaultVocabularyStore() -> VocabularyStore {
        do {
            let dbURL = try superDictateApplicationSupportDirectory()
                .appendingPathComponent("corrections.sqlite", isDirectory: false)
            return try VocabularyStore(fileURL: dbURL)
        } catch {
            log("settings: failed to open vocabulary store at the app support path, falling back to an in-memory store for this run: \(error)")
            return VocabularyStore.inMemoryFallback()
        }
    }

    private func migrateLegacyTranscriptCorrectionsIfNeeded() {
        // If openDefaultVocabularyStore() had to fall back to an
        // in-memory store (e.g. the on-disk DB is corrupted or locked),
        // never let migration "complete" against it: upserts would only
        // ever live in memory, and marking migration done + deleting the
        // UserDefaults copy here would destroy the user's entire
        // correction history the moment the process exits, with no
        // retry. Skip so a future launch where the real store opens can
        // retry migration correctly. See C2 in the final-review fix report.
        guard !vocabularyStore.isEphemeral else {
            log("settings: vocabulary store is ephemeral (in-memory fallback); skipping legacy migration so the UserDefaults copy survives for a future real attempt")
            return
        }
        guard !defaults.bool(forKey: Self.keyDidMigrateTranscriptCorrectionsToSQLite) else { return }

        guard let data = defaults.data(forKey: Self.keyTranscriptCorrections) else {
            defaults.set(true, forKey: Self.keyDidMigrateTranscriptCorrectionsToSQLite)
            return
        }
        do {
            let legacy = try TranscriptCorrectionsTransfer.decode(data)
            var migratedCount = 0
            for correction in normalizedTranscriptCorrections(legacy) {
                do {
                    _ = try vocabularyStore.upsert(source: correction.source, replacement: correction.replacement, origin: .manual)
                    migratedCount += 1
                } catch {
                    log("settings: failed to migrate one legacy correction (source: \(correction.source)): \(error)")
                }
            }
            defaults.removeObject(forKey: Self.keyTranscriptCorrections)
            defaults.set(true, forKey: Self.keyDidMigrateTranscriptCorrectionsToSQLite)
            log("settings: migrated \(migratedCount) of \(legacy.count) legacy transcript corrections into SQLite")
        } catch {
            log("settings: legacy transcript correction migration failed, leaving UserDefaults copy in place: \(error)")
        }
    }

    @discardableResult
    func refreshFromDisk() -> Bool {
        defaults.synchronize()
    }

    var hotkeyKeycode: CGKeyCode {
        get {
            normalizedHotkeyKeycode(storedValue: defaults.object(forKey: Self.keyHotkeyKeycode))
                ?? DEFAULT_HOTKEY_KEYCODE
        }
        set {
            let normalized = normalizedHotkeyKeycode(storedValue: NSNumber(value: Int(newValue)))
                ?? DEFAULT_HOTKEY_KEYCODE
            defaults.set(Int(normalized), forKey: Self.keyHotkeyKeycode)
        }
    }

    var hotkeyModifiers: CGEventFlags {
        get {
            let raw = defaults.object(forKey: Self.keyHotkeyModifiers) as? NSNumber
            return CGEventFlags(rawValue: raw?.uint64Value ?? 0)
                .intersection(HOTKEY_SHORTCUT_MODIFIER_MASK)
        }
        set {
            defaults.set(NSNumber(value: newValue.intersection(HOTKEY_SHORTCUT_MODIFIER_MASK).rawValue),
                         forKey: Self.keyHotkeyModifiers)
        }
    }

    var configuredHotkey: HotkeyChoice {
        hotkeyChoice(forKeycode: hotkeyKeycode, modifiers: hotkeyModifiers)
    }

    func setConfiguredHotkey(_ choice: HotkeyChoice) {
        hotkeyKeycode = choice.keycode
        hotkeyModifiers = choice.requiredModifiers
    }

    var enterHotkeyKeycode: CGKeyCode {
        get {
            normalizedHotkeyKeycode(storedValue: defaults.object(forKey: Self.keyEnterHotkeyKeycode))
                ?? RIGHT_COMMAND_KEYCODE
        }
        set {
            let normalized = normalizedHotkeyKeycode(storedValue: NSNumber(value: Int(newValue)))
                ?? RIGHT_COMMAND_KEYCODE
            defaults.set(Int(normalized), forKey: Self.keyEnterHotkeyKeycode)
        }
    }

    var enterHotkeyModifiers: CGEventFlags {
        get {
            let raw = defaults.object(forKey: Self.keyEnterHotkeyModifiers) as? NSNumber
            if raw == nil { return .maskAlternate }
            return CGEventFlags(rawValue: raw?.uint64Value ?? 0)
                .intersection(HOTKEY_SHORTCUT_MODIFIER_MASK)
        }
        set {
            defaults.set(NSNumber(value: newValue.intersection(HOTKEY_SHORTCUT_MODIFIER_MASK).rawValue),
                         forKey: Self.keyEnterHotkeyModifiers)
        }
    }

    var configuredEnterHotkey: HotkeyChoice {
        hotkeyChoice(forKeycode: enterHotkeyKeycode, modifiers: enterHotkeyModifiers)
    }

    func setConfiguredEnterHotkey(_ choice: HotkeyChoice) {
        enterHotkeyKeycode = choice.keycode
        enterHotkeyModifiers = choice.requiredModifiers
    }

    var primaryCompletionBehavior: DictationCompletionBehavior {
        get {
            guard let raw = defaults.string(forKey: Self.keyPrimaryCompletionBehavior),
                  let behavior = DictationCompletionBehavior(rawValue: raw) else {
                // Preserve the behavior of releases before v0.2.35.
                return .insert
            }
            return behavior
        }
        set { defaults.set(newValue.rawValue, forKey: Self.keyPrimaryCompletionBehavior) }
    }

    var alternateCompletionEnabled: Bool {
        get {
            guard defaults.object(forKey: Self.keyAlternateCompletionEnabled) != nil else {
                // The alternate finish shortcut was always enabled before v0.2.35.
                return true
            }
            return defaults.bool(forKey: Self.keyAlternateCompletionEnabled)
        }
        set { defaults.set(newValue, forKey: Self.keyAlternateCompletionEnabled) }
    }

    /// Delay between pasting the transcribed text and posting the
    /// Return key when the completion behavior includes "+ Enter".
    /// Some apps (Electron, VMs) need a beat to process the paste
    /// before they can handle a keystroke. Stored in milliseconds;
    /// the default (120) matches the original hardcoded constant.
    var enterDelayMilliseconds: Int {
        get {
            guard defaults.object(forKey: Self.keyEnterDelayMilliseconds) != nil else {
                return 120
            }
            return max(0, min(500, defaults.integer(forKey: Self.keyEnterDelayMilliseconds)))
        }
        set { defaults.set(max(0, min(500, newValue)), forKey: Self.keyEnterDelayMilliseconds) }
    }

    var historyHotkeyKeycode: CGKeyCode {
        get {
            normalizedHotkeyKeycode(storedValue: defaults.object(forKey: Self.keyHistoryHotkeyKeycode))
                ?? RIGHT_COMMAND_KEYCODE
        }
        set {
            let normalized = normalizedHotkeyKeycode(storedValue: NSNumber(value: Int(newValue)))
                ?? RIGHT_COMMAND_KEYCODE
            defaults.set(Int(normalized), forKey: Self.keyHistoryHotkeyKeycode)
        }
    }

    var historyHotkeyModifiers: CGEventFlags {
        get {
            let raw = defaults.object(forKey: Self.keyHistoryHotkeyModifiers) as? NSNumber
            if raw == nil { return .maskShift }
            return CGEventFlags(rawValue: raw?.uint64Value ?? 0)
                .intersection(HOTKEY_SHORTCUT_MODIFIER_MASK)
        }
        set {
            defaults.set(NSNumber(value: newValue.intersection(HOTKEY_SHORTCUT_MODIFIER_MASK).rawValue),
                         forKey: Self.keyHistoryHotkeyModifiers)
        }
    }

    var configuredHistoryHotkey: HotkeyChoice {
        hotkeyChoice(forKeycode: historyHotkeyKeycode, modifiers: historyHotkeyModifiers)
    }

    func setConfiguredHistoryHotkey(_ choice: HotkeyChoice) {
        historyHotkeyKeycode = choice.keycode
        historyHotkeyModifiers = choice.requiredModifiers
    }

    var correctionHotkeyKeycode: CGKeyCode {
        get {
            normalizedHotkeyKeycode(storedValue: defaults.object(forKey: Self.keyCorrectionHotkeyKeycode))
                ?? LEFT_COMMAND_KEYCODE
        }
        set {
            let normalized = normalizedHotkeyKeycode(storedValue: NSNumber(value: Int(newValue)))
                ?? LEFT_COMMAND_KEYCODE
            defaults.set(Int(normalized), forKey: Self.keyCorrectionHotkeyKeycode)
        }
    }

    var correctionHotkeyModifiers: CGEventFlags {
        get {
            let raw = defaults.object(forKey: Self.keyCorrectionHotkeyModifiers) as? NSNumber
            if raw == nil { return [] }
            return CGEventFlags(rawValue: raw?.uint64Value ?? 0)
                .intersection(HOTKEY_SHORTCUT_MODIFIER_MASK)
        }
        set {
            defaults.set(NSNumber(value: newValue.intersection(HOTKEY_SHORTCUT_MODIFIER_MASK).rawValue),
                         forKey: Self.keyCorrectionHotkeyModifiers)
        }
    }

    var configuredCorrectionHotkey: HotkeyChoice {
        hotkeyChoice(forKeycode: correctionHotkeyKeycode, modifiers: correctionHotkeyModifiers)
    }

    func setConfiguredCorrectionHotkey(_ choice: HotkeyChoice) {
        correctionHotkeyKeycode = choice.keycode
        correctionHotkeyModifiers = choice.requiredModifiers
    }

    var interfaceLanguage: InterfaceLanguage {
        get {
            guard let raw = defaults.string(forKey: Self.keyInterfaceLanguage),
                  let language = InterfaceLanguage(rawValue: raw) else {
                return .russian
            }
            return language
        }
        set { defaults.set(newValue.rawValue, forKey: Self.keyInterfaceLanguage) }
    }

    var triggerMode: TriggerMode {
        get {
            if let v = defaults.string(forKey: Self.keyTriggerMode), let m = TriggerMode(rawValue: v) {
                return m
            }
            return .toggle
        }
        set { defaults.set(newValue.rawValue, forKey: Self.keyTriggerMode) }
    }

    var agentEnabled: Bool {
        get {
            if defaults.object(forKey: Self.keyAgentEnabled) == nil { return true }
            return defaults.bool(forKey: Self.keyAgentEnabled)
        }
        set { defaults.set(newValue, forKey: Self.keyAgentEnabled) }
    }

    var pasteSuffix: PasteSuffix {
        get {
            if let v = defaults.string(forKey: Self.keyPasteSuffix), let s = PasteSuffix(rawValue: v) {
                return s
            }
            return .appendSpace
        }
        set { defaults.set(newValue.rawValue, forKey: Self.keyPasteSuffix) }
    }

    var recentTranscriptLimit: RecentTranscriptLimit {
        get {
            parseRecentTranscriptLimit(storedValue: defaults.object(forKey: Self.keyRecentTranscripts))
                ?? DEFAULT_RECENT_TRANSCRIPT_LIMIT
        }
        set { defaults.set(newValue.rawValue, forKey: Self.keyRecentTranscripts) }
    }

    var recentTranscriptHistory: [String] {
        get {
            let stored = defaults.stringArray(forKey: Self.keyRecentTranscriptHistory) ?? []
            return Array(
                stored.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .prefix(TRANSCRIPT_HISTORY_ARCHIVE_MAX_ENTRIES)
            )
        }
        set {
            let cleaned = Array(
                newValue.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .prefix(TRANSCRIPT_HISTORY_ARCHIVE_MAX_ENTRIES)
            )
            if cleaned.isEmpty {
                defaults.removeObject(forKey: Self.keyRecentTranscriptHistory)
            } else {
                defaults.set(cleaned, forKey: Self.keyRecentTranscriptHistory)
            }
            defaults.removeObject(forKey: Self.keyRecentTranscriptEntries)
        }
    }

    var recentTranscriptEntries: [TranscriptHistoryEntry] {
        get {
            if let data = defaults.data(forKey: Self.keyRecentTranscriptEntries),
               let decoded = try? JSONDecoder().decode([TranscriptHistoryEntry].self, from: data) {
                let cleaned = decoded.compactMap { entry -> TranscriptHistoryEntry? in
                    let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    return TranscriptHistoryEntry(
                        text: text,
                        transcriptionDurationSeconds: entry.transcriptionDurationSeconds,
                        asrTiming: entry.asrTiming
                    )
                }
                return limitedTranscriptHistoryArchive(cleaned)
            }

            return recentTranscriptHistory.map { TranscriptHistoryEntry(text: $0) }
        }
        set {
            let cleaned = limitedTranscriptHistoryArchive(
                newValue.compactMap { entry -> TranscriptHistoryEntry? in
                    let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    return TranscriptHistoryEntry(
                        text: text,
                        transcriptionDurationSeconds: entry.transcriptionDurationSeconds,
                        asrTiming: entry.asrTiming
                    )
                }
            )

            guard !cleaned.isEmpty else {
                defaults.removeObject(forKey: Self.keyRecentTranscriptEntries)
                defaults.removeObject(forKey: Self.keyRecentTranscriptHistory)
                return
            }

            if let data = try? JSONEncoder().encode(cleaned) {
                defaults.set(data, forKey: Self.keyRecentTranscriptEntries)
            }
            defaults.set(cleaned.map(\.text), forKey: Self.keyRecentTranscriptHistory)
        }
    }

    var dailyDictationUsage: [DailyDictationUsage] {
        get {
            guard let data = defaults.data(forKey: Self.keyDailyDictationUsage),
                  let decoded = try? JSONDecoder().decode([DailyDictationUsage].self, from: data) else {
                return []
            }
            return mergedDailyDictationUsage(decoded)
        }
        set {
            let cleaned = mergedDailyDictationUsage(newValue)
            guard !cleaned.isEmpty else {
                defaults.removeObject(forKey: Self.keyDailyDictationUsage)
                return
            }
            if let data = try? JSONEncoder().encode(cleaned) {
                defaults.set(data, forKey: Self.keyDailyDictationUsage)
            }
        }
    }

    var didImportDictationUsageLog: Bool {
        get { defaults.bool(forKey: Self.keyDidImportDictationUsageLog) }
        set { defaults.set(newValue, forKey: Self.keyDidImportDictationUsageLog) }
    }

    var showRecordingWaveform: Bool {
        get {
            if defaults.object(forKey: Self.keyShowRecordingWaveform) != nil {
                return defaults.bool(forKey: Self.keyShowRecordingWaveform)
            }
            if defaults.object(forKey: Self.legacyKeyShowRecordingIndicator) != nil {
                return defaults.bool(forKey: Self.legacyKeyShowRecordingIndicator)
            }
            return true
        }
        set { defaults.set(newValue, forKey: Self.keyShowRecordingWaveform) }
    }

    var recordingHUDRecordingColor: RecordingHUDAccentColor {
        get {
            guard let raw = defaults.string(forKey: Self.keyRecordingHUDRecordingColor),
                  let color = RecordingHUDAccentColor(rawValue: raw) else {
                return .red
            }
            return color
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.keyRecordingHUDRecordingColor)
            defaults.synchronize()
        }
    }

    var recordingHUDTranscribingColor: RecordingHUDAccentColor {
        get {
            guard let raw = defaults.string(forKey: Self.keyRecordingHUDTranscribingColor),
                  let color = RecordingHUDAccentColor(rawValue: raw) else {
                return .blue
            }
            return color
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.keyRecordingHUDTranscribingColor)
            defaults.synchronize()
        }
    }

    var recordingHUDBackgroundStyle: RecordingHUDBackgroundStyle {
        get {
            guard let raw = defaults.string(forKey: Self.keyRecordingHUDBackgroundStyle),
                  let style = RecordingHUDBackgroundStyle(rawValue: raw) else {
                return .system
            }
            return style
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.keyRecordingHUDBackgroundStyle)
            defaults.synchronize()
        }
    }

    var recordingHUDSize: RecordingHUDSize {
        get {
            guard let raw = defaults.string(forKey: Self.keyRecordingHUDSize),
                  let size = RecordingHUDSize(rawValue: raw) else {
                return .standard
            }
            return size
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.keyRecordingHUDSize)
            defaults.synchronize()
        }
    }

    var recordingHUDDisplayMode: RecordingHUDDisplayMode {
        get {
            guard let raw = defaults.string(forKey: Self.keyRecordingHUDDisplayMode),
                  let mode = RecordingHUDDisplayMode(rawValue: raw) else {
                return .levelBars
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.keyRecordingHUDDisplayMode)
            defaults.synchronize()
        }
    }

    var muteWhileRecording: Bool {
        get {
            if defaults.object(forKey: Self.keyMuteWhileRecording) == nil { return true }
            return defaults.bool(forKey: Self.keyMuteWhileRecording)
        }
        set { defaults.set(newValue, forKey: Self.keyMuteWhileRecording) }
    }

    var autoStopOnSilenceEnabled: Bool {
        get { defaults.bool(forKey: Self.keyAutoStopOnSilenceEnabled) }
        set { defaults.set(newValue, forKey: Self.keyAutoStopOnSilenceEnabled) }
    }

    var autoStopSilenceSeconds: Int {
        get {
            guard defaults.object(forKey: Self.keyAutoStopSilenceSeconds) != nil else { return 5 }
            return max(1, min(10, defaults.integer(forKey: Self.keyAutoStopSilenceSeconds)))
        }
        set { defaults.set(max(1, min(10, newValue)), forKey: Self.keyAutoStopSilenceSeconds) }
    }

    var playFeedbackSounds: Bool {
        get {
            if defaults.object(forKey: Self.keyPlayFeedbackSounds) == nil { return true }
            return defaults.bool(forKey: Self.keyPlayFeedbackSounds)
        }
        set { defaults.set(newValue, forKey: Self.keyPlayFeedbackSounds) }
    }

    var showInDock: Bool {
        get {
            if defaults.object(forKey: Self.keyShowInDock) == nil { return false }
            return defaults.bool(forKey: Self.keyShowInDock)
        }
        set { defaults.set(newValue, forKey: Self.keyShowInDock) }
    }

    var inputDevice: String {
        get {
            guard let raw = defaults.string(forKey: Self.keyInputDevice),
                  let normalized = normalizedInputDevicePreference(raw) else {
                return ""
            }
            return normalized
        }
        set {
            if let normalized = normalizedInputDevicePreference(newValue) {
                defaults.set(normalized, forKey: Self.keyInputDevice)
            } else {
                defaults.removeObject(forKey: Self.keyInputDevice)
            }
        }
    }

    var checkForUpdates: Bool {
        get {
            if defaults.object(forKey: Self.keyCheckForUpdates) == nil { return false }
            return defaults.bool(forKey: Self.keyCheckForUpdates)
        }
        set { defaults.set(newValue, forKey: Self.keyCheckForUpdates) }
    }

    var lastUpdateCheckAt: Date? {
        get { defaults.object(forKey: Self.keyLastUpdateCheckAt) as? Date }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Self.keyLastUpdateCheckAt)
            } else {
                defaults.removeObject(forKey: Self.keyLastUpdateCheckAt)
            }
        }
    }

    var lastUpdateCheckSource: UpdateCheckSource? {
        get {
            guard let raw = defaults.string(forKey: Self.keyLastUpdateCheckSource) else {
                return nil
            }
            return UpdateCheckSource(rawValue: raw)
        }
        set {
            if let newValue {
                defaults.set(newValue.rawValue, forKey: Self.keyLastUpdateCheckSource)
            } else {
                defaults.removeObject(forKey: Self.keyLastUpdateCheckSource)
            }
        }
    }

    var lastUpdateCheckResult: UpdateCheckResult? {
        get {
            guard let raw = defaults.string(forKey: Self.keyLastUpdateCheckResult) else {
                return nil
            }
            return UpdateCheckResult(rawValue: raw)
        }
        set {
            if let newValue {
                defaults.set(newValue.rawValue, forKey: Self.keyLastUpdateCheckResult)
            } else {
                defaults.removeObject(forKey: Self.keyLastUpdateCheckResult)
            }
        }
    }

    var lastUpdateCheckVersion: String {
        get {
            guard let raw = defaults.string(forKey: Self.keyLastUpdateCheckVersion),
                  let normalized = normalizedStoredAppVersion(raw) else {
                return ""
            }
            return normalized
        }
        set {
            if let normalized = normalizedStoredAppVersion(newValue) {
                defaults.set(normalized, forKey: Self.keyLastUpdateCheckVersion)
            } else {
                defaults.removeObject(forKey: Self.keyLastUpdateCheckVersion)
            }
        }
    }

    /// "Remind me later" pause state, persisted so a relaunch inside
    /// the 24 h window does not re-prompt ~30 s after launch. Both
    /// halves are validated independently and corrupt stored values
    /// degrade to nil; ParakeyApp treats a missing half as "no pause"
    /// and clears the leftover at startup.
    var updateReminderPausedVersion: String? {
        get {
            guard let raw = defaults.string(forKey: Self.keyUpdateReminderPausedVersion),
                  let normalized = normalizedStoredAppVersion(raw) else {
                return nil
            }
            return normalized
        }
        set {
            if let newValue, let normalized = normalizedStoredAppVersion(newValue) {
                defaults.set(normalized, forKey: Self.keyUpdateReminderPausedVersion)
            } else {
                defaults.removeObject(forKey: Self.keyUpdateReminderPausedVersion)
            }
        }
    }

    var updateReminderPausedUntil: Date? {
        get {
            normalizedUpdateReminderPauseExpiry(
                storedValue: defaults.object(forKey: Self.keyUpdateReminderPausedUntil)
            )
        }
        set {
            if let newValue,
               normalizedUpdateReminderPauseExpiry(storedValue: newValue) != nil {
                defaults.set(newValue, forKey: Self.keyUpdateReminderPausedUntil)
            } else {
                defaults.removeObject(forKey: Self.keyUpdateReminderPausedUntil)
            }
        }
    }

    var lastSeenVersion: String {
        get {
            guard let raw = defaults.string(forKey: Self.keyLastSeenVersion),
                  let normalized = normalizedStoredAppVersion(raw) else {
                return ""
            }
            return normalized
        }
        set {
            if let normalized = normalizedStoredAppVersion(newValue) {
                defaults.set(normalized, forKey: Self.keyLastSeenVersion)
            } else {
                defaults.removeObject(forKey: Self.keyLastSeenVersion)
            }
        }
    }

    var skippedVersions: [String] {
        get {
            normalizedSkippedUpdateVersions(
                (defaults.array(forKey: Self.keySkippedVersions) as? [String]) ?? []
            )
        }
        set {
            let versions = normalizedSkippedUpdateVersions(newValue)
            if versions.isEmpty {
                defaults.removeObject(forKey: Self.keySkippedVersions)
            } else {
                defaults.set(versions, forKey: Self.keySkippedVersions)
            }
        }
    }

    var autoLearnVocabularyEnabled: Bool {
        get {
            defaults.object(forKey: Self.keyAutoLearnVocabularyEnabled) as? Bool ?? true
        }
        set { defaults.set(newValue, forKey: Self.keyAutoLearnVocabularyEnabled) }
    }

    var transcriptCorrections: [TranscriptCorrection] {
        get {
            vocabularyStore.all().map { TranscriptCorrection(source: $0.source, replacement: $0.replacement) }
        }
        set { storeTranscriptCorrections(newValue) }
    }

    /// Persists corrections and reports failure to the caller instead
    /// of swallowing it, matching the pre-SQLite contract this replaces.
    /// With SQLite there is no encode/size-limit failure mode left (each
    /// row is capped and validated by `normalizedTranscriptCorrections`
    /// before it reaches here), so this always returns nil today; the
    /// `Error?` return type is kept because call sites throughout
    /// ParakeyApp.swift already branch on it.
    @discardableResult
    func storeTranscriptCorrections(_ newValue: [TranscriptCorrection]) -> Error? {
        let corrections = normalizedTranscriptCorrections(newValue)
        vocabularyStore.replaceAllPreservingOrigin(corrections)
        return nil
    }

    var transcriptCorrectionsSyncFile: String {
        get {
            guard let raw = defaults.string(forKey: Self.keyTranscriptCorrectionsSyncFile),
                  let normalized = normalizedCorrectionSyncFilePath(raw) else {
                return ""
            }
            return normalized
        }
        set {
            if let normalized = normalizedCorrectionSyncFilePath(newValue) {
                defaults.set(normalized, forKey: Self.keyTranscriptCorrectionsSyncFile)
            } else {
                defaults.removeObject(forKey: Self.keyTranscriptCorrectionsSyncFile)
            }
        }
    }

    var dictationLanguage: DictationLanguage {
        get {
            if let v = defaults.string(forKey: Self.keyDictationLanguage),
               let lang = DictationLanguage(rawValue: v) {
                return lang
            }
            return .auto
        }
        set { defaults.set(newValue.rawValue, forKey: Self.keyDictationLanguage) }
    }

    var speechModelProfile: SpeechModelProfile {
        get {
            productionSpeechModelProfile(rawValue: defaults.string(forKey: Self.keySpeechModelProfile))
        }
        set { defaults.set(newValue.productionProfile.rawValue, forKey: Self.keySpeechModelProfile) }
    }

    @discardableResult
    func normalizeSpeechModelProfileForCurrentBuild() -> Bool {
        var changed = false
        if let raw = defaults.string(forKey: Self.keySpeechModelProfile) {
            let normalized = productionSpeechModelProfile(rawValue: raw)
            if normalized.rawValue != raw {
                defaults.set(SpeechModelProfile.productionDefault.rawValue,
                             forKey: Self.keySpeechModelProfile)
                changed = true
            }
        }
        if defaults.object(forKey: Self.keyInitialSpeechModelChoiceRequired) != nil {
            defaults.removeObject(forKey: Self.keyInitialSpeechModelChoiceRequired)
            changed = true
        }
        return changed
    }

    var removeFinalPeriod: Bool {
        get { defaults.bool(forKey: Self.keyRemoveFinalPeriod) }
        set { defaults.set(newValue, forKey: Self.keyRemoveFinalPeriod) }
    }

    var removeFillerWords: Bool {
        get { defaults.bool(forKey: Self.keyRemoveFillerWords) }
        set { defaults.set(newValue, forKey: Self.keyRemoveFillerWords) }
    }

    var enabledFillerPresetKeys: Set<String> {
        get {
            guard let stored = defaults.array(forKey: Self.keyEnabledFillerPresetKeys) as? [String] else {
                return FillerWordRemover.defaultEnabledPresetKeys
            }
            return Set(stored)
        }
        set { defaults.set(Array(newValue), forKey: Self.keyEnabledFillerPresetKeys) }
    }

    var customFillerWords: [String] {
        get { (defaults.array(forKey: Self.keyCustomFillerWords) as? [String]) ?? [] }
        set { defaults.set(newValue, forKey: Self.keyCustomFillerWords) }
    }

    /// Custom words the user switched off in the checklist but kept on the
    /// list (mirrors the Windows port: a custom word can stay visible but
    /// unticked, instead of forcing delete-or-always-on).
    var disabledCustomFillerWords: Set<String> {
        get { Set((defaults.array(forKey: Self.keyDisabledCustomFillerWords) as? [String]) ?? []) }
        set { defaults.set(Array(newValue), forKey: Self.keyDisabledCustomFillerWords) }
    }

    /// The custom-word list the transcription pipeline should actually
    /// apply: every custom word except the ones unticked in Settings.
    var enabledCustomFillerWords: [String] {
        let disabled = disabledCustomFillerWords
        return customFillerWords.filter { !disabled.contains($0) }
    }

    var normalizeNumbersToDigits: Bool {
        get { defaults.bool(forKey: Self.keyNormalizeNumbersToDigits) }
        set { defaults.set(newValue, forKey: Self.keyNormalizeNumbersToDigits) }
    }

    // Opt-in Vulkan GPU backend for Parakeet (parakeet.cpp). Not implemented
    // yet — Vulkan support is Phase 5 of the parakeet.cpp migration plan;
    // this phase only adds the storage key + default so clean installs and
    // upgrades both start on CPU (spec §10). Defaults to `false` (CPU) via
    // `defaults.bool(forKey:)`'s standard "unset key reads as false"
    // behavior — never force this on by default. Persisted under a NEW key
    // (`parakeet_use_gpu`, see `keyUseGPU`'s comment), never inherited from
    // the old Whisper `use_gpu` value.
    var useGPU: Bool {
        get { defaults.bool(forKey: Self.keyUseGPU) }
        set { defaults.set(newValue, forKey: Self.keyUseGPU) }
    }

    /// Off / correction (see TextPostprocessingMode's own doc comment for
    /// why there is no rewrite case yet).
    var textPostprocessingMode: TextPostprocessingMode {
        get { normalizedTextPostprocessingMode(rawValue: defaults.string(forKey: Self.keyTextPostprocessingMode)) }
        set { defaults.set(newValue.rawValue, forKey: Self.keyTextPostprocessingMode) }
    }

    var llmEngineBackend: LLMEngineBackend {
        get { normalizedLLMEngineBackend(rawValue: defaults.string(forKey: Self.keyLLMEngineBackend)) }
        set { defaults.set(newValue.rawValue, forKey: Self.keyLLMEngineBackend) }
    }

    /// Base URL for `.customEndpoint`. Stored verbatim (trimmed); validity
    /// is checked at the point of use (OpenAICompatibleClient rejects a
    /// malformed URL per-request) rather than here, so a user can save a
    /// draft value before finishing it.
    var llmCustomBaseURL: String {
        get { defaults.string(forKey: Self.keyLLMCustomBaseURL)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.keyLLMCustomBaseURL) }
    }

    /// API key for `.customEndpoint`. NOT stored in the Keychain — this
    /// mirrors how this app already stores no other secret today (there is
    /// no existing Keychain integration to extend), and the key only ever
    /// leaves this Mac in an Authorization header the user's own configured
    /// endpoint receives. Revisit if a future custom-endpoint feature needs
    /// stronger at-rest protection than the standard `~/Library/Preferences`
    /// plist already gets from full-disk encryption.
    var llmCustomAPIKey: String {
        get { defaults.string(forKey: Self.keyLLMCustomAPIKey) ?? "" }
        set { defaults.set(newValue, forKey: Self.keyLLMCustomAPIKey) }
    }

    var llmCustomModelName: String {
        get { defaults.string(forKey: Self.keyLLMCustomModelName)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.keyLLMCustomModelName) }
    }

    /// Which bundled correction model the correction pass uses when its
    /// backend is `.bundledLocal` — `.fast` (VoiceScribe, default; this
    /// branch's fixed choice for fast correction) or `.quality`
    /// (YandexGPT-5-Lite-8B, on-demand ~4.9 GB download). Stored
    /// independently of the rewrite keys below.
    var correctionModelTier: CorrectionModelTier {
        get { normalizedCorrectionModelTier(rawValue: defaults.string(forKey: Self.keyCorrectionModelTier)) }
        set { defaults.set(newValue.rawValue, forKey: Self.keyCorrectionModelTier) }
    }

    /// Rewrite on/off — deliberately a SEPARATE toggle from
    /// textPostprocessingMode (correction): the user may enable both at
    /// once (docs/specs/rewrite-tiered-correction-spec.md §1.4), in which
    /// case the pipeline runs correction first, then rewrite.
    var rewriteEnabled: Bool {
        get { defaults.bool(forKey: Self.keyRewriteEnabled) }
        set { defaults.set(newValue, forKey: Self.keyRewriteEnabled) }
    }

    var rewriteStyle: RewriteStyle {
        get { normalizedRewriteStyle(rawValue: defaults.string(forKey: Self.keyRewriteStyle)) }
        set { defaults.set(newValue.rawValue, forKey: Self.keyRewriteStyle) }
    }

    /// Which bundled model the rewrite pass loads when
    /// rewriteEngineBackend is `.bundledLocal` — the Settings dropdown
    /// next to the style picker. `.yandexGPT` (default, benchmark winner)
    /// or `.voiceScribe` (reuses the fast correction pair — faster but
    /// compresses text, experimental).
    var rewriteBundledModel: RewriteBundledModel {
        get { normalizedRewriteBundledModel(rawValue: defaults.string(forKey: Self.keyRewriteBundledModel)) }
        set { defaults.set(newValue.rawValue, forKey: Self.keyRewriteBundledModel) }
    }

    /// Backend for the rewrite pass — its own selector, independent from
    /// the correction pass's llmEngineBackend, so correction and rewrite
    /// can each point at a different OpenAI-compatible endpoint.
    var rewriteEngineBackend: LLMEngineBackend {
        get { normalizedLLMEngineBackend(rawValue: defaults.string(forKey: Self.keyRewriteEngineBackend)) }
        set { defaults.set(newValue.rawValue, forKey: Self.keyRewriteEngineBackend) }
    }

    /// Base URL for the rewrite `.customEndpoint` — independent from the
    /// correction llmCustomBaseURL. Same verbatim-store, validate-at-use
    /// policy as that key.
    var rewriteCustomBaseURL: String {
        get { defaults.string(forKey: Self.keyRewriteCustomBaseURL)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.keyRewriteCustomBaseURL) }
    }

    var rewriteCustomAPIKey: String {
        get { defaults.string(forKey: Self.keyRewriteCustomAPIKey) ?? "" }
        set { defaults.set(newValue, forKey: Self.keyRewriteCustomAPIKey) }
    }

    var rewriteCustomModelName: String {
        get { defaults.string(forKey: Self.keyRewriteCustomModelName)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.keyRewriteCustomModelName) }
    }

    var hasActiveRunMarker: Bool {
        get { defaults.bool(forKey: Self.keyActiveRunMarker) }
        set {
            if newValue {
                defaults.set(true, forKey: Self.keyActiveRunMarker)
            } else {
                defaults.removeObject(forKey: Self.keyActiveRunMarker)
            }
        }
    }
}

