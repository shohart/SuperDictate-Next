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


enum ControlPanelServiceOperation: String, Sendable {
    case starting
    case restarting
    case stopping
    case applyingSettings
}

enum ControlPanelShortcutKind: Int {
    case dictation = 0
    case alternateCompletion = 1
    case history = 2
    case correction = 3
    case rewriteToggle = 4
    case rewriteStyle = 5
}

struct ControlPanelSettingsDraft: Equatable {
    var speechModelProfile: SpeechModelProfile
    var dictationHotkey: HotkeyChoice
    var alternateCompletionHotkey: HotkeyChoice
    var historyHotkey: HotkeyChoice
    var correctionHotkey: HotkeyChoice
    var rewriteToggleHotkey: HotkeyChoice
    var rewriteStyleHotkey: HotkeyChoice
    var primaryCompletionBehavior: DictationCompletionBehavior
    var alternateCompletionEnabled: Bool
    var enterDelayMilliseconds: Int
    var inputDevicePreference: String
    var recordingColor: RecordingHUDAccentColor
    var transcribingColor: RecordingHUDAccentColor
    var correctingColor: RecordingHUDAccentColor
    var backgroundStyle: RecordingHUDBackgroundStyle
    var hudSize: RecordingHUDSize
    var hudDisplayMode: RecordingHUDDisplayMode
    var normalizeNumbersToDigits: Bool
    var removeFillerWords: Bool
    var removeFinalPeriod: Bool
    var enabledFillerPresetKeys: Set<String>
    var customFillerWords: [String]
    var disabledCustomFillerWords: Set<String>
    var autoStopOnSilenceEnabled: Bool
    var autoStopSilenceSeconds: Int
    var muteWhileRecording: Bool
    var autoLearnVocabularyEnabled: Bool
    var textPostprocessingMode: TextPostprocessingMode
    var llmEngineBackend: LLMEngineBackend
    var llmCustomBaseURL: String
    var llmCustomAPIKey: String
    var llmCustomModelName: String
    /// Shared by both custom endpoints: internet addresses go through the
    /// system proxy, LAN addresses always connect directly.
    var llmUseSystemProxy: Bool
    var correctionModel: BundledLLMModel
    /// The correction system prompt AS SHOWN IN THE EDITOR: either the
    /// stored override or (when none) the selected model's built-in
    /// default, pre-filled so the user edits the standard text in place
    /// instead of writing a replacement from scratch.
    var correctionSystemPrompt: String
    var rewriteEnabled: Bool
    var punctuationRestorationEnabled: Bool
    var punctuationModel: PunctuationModel
    var rewriteStyleID: String
    var customRewriteStyles: [CustomRewriteStyle]
    var rewriteBundledModel: BundledLLMModel
    /// Per-style rewrite system prompts AS SHOWN IN THE EDITOR — one
    /// independent editable prompt per rewrite mode (built-ins by raw
    /// value, customs by `c-<uuid>` id), each pre-filled with its
    /// built-in default when no override is stored.
    var rewriteSystemPrompts: [String: String]
    var rewriteEngineBackend: LLMEngineBackend
    var rewriteCustomBaseURL: String
    var rewriteCustomAPIKey: String
    var rewriteCustomModelName: String

    init(settings: Settings) {
        speechModelProfile = settings.speechModelProfile
        dictationHotkey = settings.configuredHotkey
        alternateCompletionHotkey = settings.configuredEnterHotkey
        historyHotkey = settings.configuredHistoryHotkey
        correctionHotkey = settings.configuredCorrectionHotkey
        rewriteToggleHotkey = settings.configuredRewriteToggleHotkey
        rewriteStyleHotkey = settings.configuredRewriteStyleHotkey
        primaryCompletionBehavior = settings.primaryCompletionBehavior
        alternateCompletionEnabled = settings.alternateCompletionEnabled
        enterDelayMilliseconds = settings.enterDelayMilliseconds
        let savedInput = settings.inputDevice
        inputDevicePreference = audioInputDevice(matching: savedInput)?.uid ?? savedInput
        recordingColor = settings.recordingHUDRecordingColor
        transcribingColor = settings.recordingHUDTranscribingColor
        correctingColor = settings.recordingHUDCorrectingColor
        backgroundStyle = settings.recordingHUDBackgroundStyle
        hudSize = settings.recordingHUDSize
        hudDisplayMode = settings.recordingHUDDisplayMode
        normalizeNumbersToDigits = settings.normalizeNumbersToDigits
        removeFillerWords = settings.removeFillerWords
        removeFinalPeriod = settings.removeFinalPeriod
        enabledFillerPresetKeys = settings.enabledFillerPresetKeys
        customFillerWords = settings.customFillerWords
        disabledCustomFillerWords = settings.disabledCustomFillerWords
        autoStopOnSilenceEnabled = settings.autoStopOnSilenceEnabled
        autoStopSilenceSeconds = settings.autoStopSilenceSeconds
        muteWhileRecording = settings.muteWhileRecording
        autoLearnVocabularyEnabled = settings.autoLearnVocabularyEnabled
        textPostprocessingMode = settings.textPostprocessingMode
        llmEngineBackend = settings.llmEngineBackend
        llmCustomBaseURL = settings.llmCustomBaseURL
        llmCustomAPIKey = settings.llmCustomAPIKey
        llmCustomModelName = settings.llmCustomModelName
        llmUseSystemProxy = settings.llmUseSystemProxy
        correctionModel = settings.correctionBundledModel
        correctionSystemPrompt = {
            let override = settings.correctionSystemPromptOverride
            return override.isEmpty
                ? LLMCorrectionPrompt.systemPrompt(vocabulary: [], model: settings.correctionBundledModel)
                : override
        }()
        rewriteEnabled = settings.rewriteEnabled
        punctuationRestorationEnabled = settings.punctuationRestorationEnabled
        punctuationModel = settings.punctuationModel
        rewriteStyleID = settings.rewriteStyleID
        customRewriteStyles = settings.customRewriteStyles
        rewriteBundledModel = settings.rewriteBundledModel
        rewriteSystemPrompts = {
            var map: [String: String] = [:]
            for style in RewriteStyle.allCases {
                let override = settings.rewriteSystemPromptOverride(for: style)
                map[style.rawValue] = override.isEmpty
                    ? LLMRewritePrompt.systemPrompt(style: style)
                    : override
            }
            for custom in settings.customRewriteStyles {
                let override = settings.rewriteSystemPromptOverride(forStyleID: custom.id)
                map[custom.id] = override.isEmpty
                    ? LLMRewritePrompt.systemPrompt(custom: custom)
                    : override
            }
            return map
        }()
        rewriteEngineBackend = settings.rewriteEngineBackend
        rewriteCustomBaseURL = settings.rewriteCustomBaseURL
        rewriteCustomAPIKey = settings.rewriteCustomAPIKey
        rewriteCustomModelName = settings.rewriteCustomModelName
    }
}

func hotkeysConflict(_ lhs: HotkeyChoice, _ rhs: HotkeyChoice) -> Bool {
    lhs.keycode == rhs.keycode && lhs.requiredModifiers == rhs.requiredModifiers
}

func hotkeyIsModifierPrefix(_ prefix: HotkeyChoice,
                                    of shortcut: HotkeyChoice) -> Bool {
    guard prefix.isModifier,
          prefix.requiredModifiers.isEmpty,
          let prefixMask = prefix.modifierFlag else { return false }
    if shortcut.isModifier {
        return shortcut.requiredModifiers.contains(prefixMask)
    }
    return shortcut.requiredModifiers.contains(prefixMask)
}

enum ControlPanelUpdateState: Equatable, Sendable {
    case checking
    case upToDate(String)
    case available(GitHubRelease)
    case preparing(version: String, phase: String)
    case failed(String)
}

/// Transient, window-local download progress for the bundled GEC model —
/// deliberately not part of `ControlPanelSettingsDraft` (not a setting,
/// never persisted, never compared for unsaved-changes).
enum LLMModelDownloadState: Equatable {
    case idle
    case downloading
    case failed(String)
}

private enum SettingsTab: Int, CaseIterable {
    case dictation
    case text
    case correction
    case audio
    case appearance
    case system
}

@MainActor
final class SuperDictateControlPanelApp: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate, NSTextViewDelegate {
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private lazy var vocabularyManagerWindowController = VocabularyManagerWindowController(store: Settings.shared.vocabularyStore)
    private var refreshTimer: Timer?
    private var serviceOperation: ControlPanelServiceOperation?
    private var updateTask: Task<Void, Never>?
    private var updateState: ControlPanelUpdateState = .checking
    private var lastRenderFingerprint = ""
    private let settings = Settings.shared
    private var permissionClickCount: [Permission: Int] = [:]
    private var settingsDraft: ControlPanelSettingsDraft?
    private var selectedSettingsTab: SettingsTab = .dictation
    private var hotkeyRecorder: HotkeyRecorderController?
    private weak var settingsSaveButton: NSButton?
    private weak var settingsDiscardButton: NSButton?
    private weak var settingsStatusLabel: NSTextField?
    private var llmModelDownloadState: LLMModelDownloadState = .idle
    private var llmModelDownloadTask: Task<Void, Never>?
    /// Live byte progress of the in-flight model download, relayed from
    /// the URLSession delegate straight into the status row's views (no
    /// window rebuild — rebuilding at progress frequency would reset the
    /// settings window's scroll state).
    private var llmModelDownloadProgress: (received: Int64, total: Int64)?
    private weak var llmDownloadStatusLabel: NSTextField?
    private weak var llmDownloadProgressBar: NSProgressIndicator?
    private var punctuationDownloadTask: Task<Void, Never>?
    private var punctuationDownloadModel: PunctuationModel?
    private var punctuationDownloadFraction: Double?
    private var punctuationDownloadError: String?
    private weak var punctuationDownloadStatusLabel: NSTextField?
    private weak var punctuationDownloadProgressBar: NSProgressIndicator?
    /// Which bundled LLM model an in-flight download is for (the Settings
    /// UI offers every benchmark-listed model as an independent download).
    private var llmModelDownloadModel: BundledLLMModel = .voiceScribe
    /// Which rewrite style's system prompt the editor is currently showing
    /// (UI state only — never persisted; the persisted setting is the
    /// ACTIVE rewrite style).
    /// Which style's prompt the rewrite prompt editor is showing — by
    /// unified style id (built-in raw value or custom `c-<uuid>`).
    private var rewritePromptEditorStyleID: String = RewriteStyle.polish.rawValue
    static let llmCustomBaseURLFieldTag = 9001
    static let llmCustomAPIKeyFieldTag = 9002
    static let llmCustomModelNameFieldTag = 9003
    static let rewriteCustomBaseURLFieldTag = 9004
    // Prompt editors are NSTextViews; NSView.tag is get-only in Swift, so
    // they are identified through NSUserInterfaceItemIdentifier instead.
    static let correctionSystemPromptEditorID = NSUserInterfaceItemIdentifier("correction-system-prompt-editor")
    static let rewriteSystemPromptEditorID = NSUserInterfaceItemIdentifier("rewrite-system-prompt-editor")

    /// The built-in benchmark system prompt for a correction model — the
    /// text the prompt editor pre-fills and resets to.
    private func defaultCorrectionSystemPrompt(for model: BundledLLMModel) -> String {
        LLMCorrectionPrompt.systemPrompt(vocabulary: [], model: model)
    }

    private func defaultRewriteSystemPrompt(for style: RewriteStyle) -> String {
        LLMRewritePrompt.systemPrompt(style: style)
    }

    /// Resolves the built-in default system prompt by unified style id:
    /// built-in raw values map to their benchmark prompts, custom ids to
    /// base + the mode's own instruction block.
    private func defaultRewriteSystemPrompt(forStyleID id: String, draft: ControlPanelSettingsDraft) -> String {
        if let builtin = RewriteStyle(rawValue: id) {
            return LLMRewritePrompt.systemPrompt(style: builtin)
        }
        if let custom = draft.customRewriteStyles.first(where: { $0.id == id }) {
            return LLMRewritePrompt.systemPrompt(custom: custom)
        }
        return LLMRewritePrompt.systemPrompt(style: .polish)
    }
    static let rewriteCustomAPIKeyFieldTag = 9005
    static let rewriteCustomModelNameFieldTag = 9006

    private var language: InterfaceLanguage { settings.interfaceLanguage }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !SuperDictateControlPanelRegistry.claimCurrentPanel() {
            if SuperDictateControlPanelRegistry.activateExistingPanelIfPresent() {
                NSApp.terminate(nil)
                return
            }
            // No live panel to hand off to (stale pid file, permission error,
            // recycled PID) -- opening normally is safer than terminating
            // silently and leaving the control panel unreachable.
            log("controlPanel: claimCurrentPanel failed and no existing panel could be activated; opening anyway")
        }
        NSApp.setActivationPolicy(.regular)
        showWindow()
        startRefreshTimer()
        checkForUpdates()
        if settings.agentEnabled && !SuperDictateAgentService.isAgentLoadedOrRunning() {
            beginServiceOperation(.starting)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyRecorder?.cancel()
        hotkeyRecorder = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        updateTask?.cancel()
        updateTask = nil
        SuperDictateControlPanelRegistry.clearCurrentPanel()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else { return }
        if closingWindow === settingsWindow {
            hotkeyRecorder?.cancel()
            hotkeyRecorder = nil
            settingsWindow = nil
            settingsDraft = nil
            return
        }
        if closingWindow === window {
            settingsWindow?.orderOut(nil)
            settingsWindow = nil
            NSApp.terminate(nil)
        }
    }

    private func t(_ russian: String, _ english: String) -> String {
        localizedText(russian, english, language: language)
    }

    private func showWindow() {
        if let window {
            refresh(force: true)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 310),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered,
                              defer: false)
        window.title = "SuperDictate Next"
        window.contentMinSize = NSSize(width: 520, height: 310)
        window.contentMaxSize = NSSize(width: 520, height: 310)
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        refresh(force: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(timeInterval: 0.75,
                                            target: self,
                                            selector: #selector(refreshTimerFired(_:)),
                                            userInfo: nil,
                                            repeats: true)
        refreshTimer?.tolerance = 0.15
    }

    @objc private func refreshTimerFired(_ timer: Timer) {
        refresh()
    }

    private func refresh(force: Bool = false) {
        guard let window else { return }
        let fingerprint = renderFingerprint()
        guard force || fingerprint != lastRenderFingerprint else { return }
        lastRenderFingerprint = fingerprint
        resizeCompactPanel(window)
        window.title = t("SuperDictate Next — панель управления", "SuperDictate Next — Control Panel")
        window.contentView = makeContentView()
        if let settingsWindow, settingsWindow.isVisible {
            // Rebuilding the content view mid-edit destroys the very
            // NSButton the user is clicking: the 0.75s refresh timer fires
            // on any fingerprint change (update checks, agent state
            // transitions after a save), and if it lands between
            // mouse-down and mouse-up, the toggle is silently eaten -- the
            // rebuilt checkbox just shows the old draft state again. Real
            // report: two preset ticks never reached the draft and were
            // lost on save. Freeze the settings window while there are
            // unsaved draft changes; save/discard rebuild explicitly.
            let hasUnsavedChanges = settingsDraft
                .map { $0 != ControlPanelSettingsDraft(settings: settings) } ?? false
            if force || !hasUnsavedChanges {
                settingsWindow.title = settingsWindowTitle()
                settingsWindow.contentView = makeTabbedSettingsContentView()
            }
        }
    }

    /// Settings window title carries the running version, so a test/dev
    /// build (CFBundleShortVersionString suffixed "-dev" by
    /// scripts/build-test-app.sh) is unmistakable at a glance.
    private func settingsWindowTitle() -> String {
        t("Настройки SuperDictate Next", "SuperDictate Next Settings") + " · v" + currentBundleVersion()
    }

    private func resizeCompactPanel(_ window: NSWindow) {
        let missingCount = Permission.allCases.filter { !Permissions.isGranted($0) }.count
        let height = CGFloat(310 + max(0, missingCount - 1) * 28)
        let oldTop = window.frame.maxY
        let size = NSSize(width: 520, height: height)
        window.contentMinSize = size
        window.contentMaxSize = size
        window.setContentSize(size)
        var frame = window.frame
        frame.origin.y = oldTop - frame.height
        window.setFrame(frame, display: false)
    }

    private func renderFingerprint() -> String {
        let state = AgentRuntimeStateStore.read()
        let permissions = Permission.allCases.map { Permissions.isGranted($0) ? "1" : "0" }.joined()
        let inputDevices = settingsWindow?.isVisible == true
            ? availableAudioInputDevices()
                .map { "\($0.uid)=\($0.name)" }
                .joined(separator: "|")
            : ""
        let stateToken: String
        if serviceOperation != nil {
            stateToken = "operation"
        } else {
            let rawStatus = state?.status ?? "none"
            let isHealthyRuntimeState = ["ready", "recording", "transcribing"].contains(rawStatus)
            stateToken = [isHealthyRuntimeState ? "ready" : rawStatus,
                          isHealthyRuntimeState ? "" : state?.detail ?? "",
                          state?.downloadProgressFraction.map { String(format: "%.2f", $0) } ?? "",
                          String(state?.pid ?? 0),
                          state?.speechModelReady == true ? "1" : "0"].joined(separator: "|")
        }
        return [language.rawValue,
                serviceOperation?.rawValue ?? "idle",
                updateStateFingerprint(),
                SuperDictateAgentService.isAgentRunning() ? "running" : "stopped",
                stateToken,
                permissions,
                settings.configuredHotkey.name,
                settings.configuredEnterHotkey.name,
                settings.configuredHistoryHotkey.name,
                settings.inputDevice,
                inputDevices,
                settings.primaryCompletionBehavior.rawValue,
                settings.alternateCompletionEnabled ? "alternate-on" : "alternate-off",
                settings.triggerMode.rawValue,
                settings.recordingHUDRecordingColor.rawValue,
                settings.recordingHUDTranscribingColor.rawValue,
                settings.recordingHUDBackgroundStyle.rawValue,
                settings.recordingHUDSize.rawValue,
                permissionClickCount.description].joined(separator: "::")
    }

    private func updateStateFingerprint() -> String {
        switch updateState {
        case .checking:
            return "checking"
        case .upToDate(let version):
            return "current:\(version)"
        case .available(let release):
            return "available:\(release.version)"
        case .preparing(let version, let phase):
            return "preparing:\(version):\(phase)"
        case .failed(let message):
            return "failed:\(message)"
        }
    }

    private func makeContentView() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false

        root.addArrangedSubview(compactHeaderView())
        root.addArrangedSubview(compactServiceCard())
        root.addArrangedSubview(compactPermissionsCard())
        root.addArrangedSubview(compactUpdateCard())
        root.addArrangedSubview(compactPrivacyFooter())

        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .active
        background.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            root.topAnchor.constraint(equalTo: background.topAnchor),
            root.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        let innerWidthInset = -(root.edgeInsets.left + root.edgeInsets.right)
        for view in root.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: root.widthAnchor,
                                        constant: innerWidthInset).isActive = true
        }
        return background
    }

    private func makeSettingsContentView() -> NSView {
        let draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 11
        root.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false

        root.addArrangedSubview(settingsHeaderView())
        root.addArrangedSubview(separator())
        root.addArrangedSubview(hotkeyRow(
            title: t("Диктовка", "Dictation"),
            shortcut: draft.dictationHotkey,
            kind: .dictation,
            toolTip: t("Начать запись. Повторное нажатие завершает её выбранным способом.",
                       "Start recording. Press again to finish using the selected action.")
        ))
        root.addArrangedSubview(primaryCompletionBehaviorRow(draft))
        root.addArrangedSubview(alternateCompletionRow(draft))
        root.addArrangedSubview(normalizeNumbersRow(draft))
        root.addArrangedSubview(fillerWordsRow(draft))
        root.addArrangedSubview(autoStopOnSilenceRow(draft))
        root.addArrangedSubview(autoStopSilenceDurationRow(draft))
        root.addArrangedSubview(enterDelayRow(draft))
        root.addArrangedSubview(hotkeyRow(
            title: t("История", "History"),
            shortcut: draft.historyHotkey,
            kind: .history,
            toolTip: t("Открыть или закрыть последние транскрипции.",
                       "Open or close recent transcriptions.")
        ))
        root.addArrangedSubview(separator())
        root.addArrangedSubview(microphoneSettingsRow(draft))
        root.addArrangedSubview(muteWhileRecordingRow(draft))
        root.addArrangedSubview(launchAtLoginRow())
        root.addArrangedSubview(correctionsInfoRow())
        root.addArrangedSubview(autoLearnVocabularyRow(draft))
        root.addArrangedSubview(separator())
        root.addArrangedSubview(popupRow(
            title: t("Размер капсулы", "Capsule size"),
            detail: t("Размер плавающего индикатора записи.",
                      "Size of the floating recording indicator."),
            selectedValue: draft.hudSize.rawValue,
            options: RecordingHUDSize.allCases.map { (localizedHUDSizeName($0), $0.rawValue) },
            action: #selector(selectRecordingHUDSize(_:)),
            toolTip: t("Выбрать компактную, обычную или крупную капсулу.",
                       "Choose a compact, standard, or large capsule.")
        ))
        root.addArrangedSubview(popupRow(
            title: t("Цвет записи", "Recording color"),
            detail: t("Цвет аудиоволн, пока микрофон слушает.",
                      "Color used while the microphone is listening."),
            selectedValue: draft.recordingColor.rawValue,
            options: RecordingHUDAccentColor.allCases.map { (localizedColorName($0), $0.rawValue) },
            action: #selector(selectRecordingHUDRecordingColor(_:)),
            toolTip: t("Цвет индикатора во время записи.", "Indicator color while recording.")
        ))
        root.addArrangedSubview(popupRow(
            title: t("Индикатор записи", "Recording indicator"),
            detail: t("Полоски уровня громкости или таймер длительности после 10 секунд записи.",
                      "Volume level bars, or an elapsed-time timer after 10 seconds of recording."),
            selectedValue: draft.hudDisplayMode.rawValue,
            options: RecordingHUDDisplayMode.allCases.map { (localizedDisplayModeName($0), $0.rawValue) },
            action: #selector(selectRecordingHUDDisplayMode(_:)),
            toolTip: t("Переключить вид плавающего индикатора во время записи.",
                       "Switch how the floating recording indicator looks while recording.")
        ))
        root.addArrangedSubview(popupRow(
            title: t("Цвет транскрибации", "Transcribing color"),
            detail: t("Цвет анимации во время распознавания речи.",
                      "Color used while speech is being converted to text."),
            selectedValue: draft.transcribingColor.rawValue,
            options: RecordingHUDAccentColor.allCases.map { (localizedColorName($0), $0.rawValue) },
            action: #selector(selectRecordingHUDTranscribingColor(_:)),
            toolTip: t("Цвет индикатора во время распознавания речи.",
                       "Indicator color while speech is being transcribed.")
        ))
        root.addArrangedSubview(popupRow(
            title: t("Цвет AI-улучшения", "AI polish color"),
            detail: t("Второй цвет градиента анимации улучшения текста: волна перетекает слева направо от цвета транскрибации к этому цвету.",
                      "Second color of the AI-improvement wave gradient: bars fade left-to-right from the transcribing color to this one."),
            selectedValue: draft.correctingColor.rawValue,
            options: RecordingHUDAccentColor.allCases.map { (localizedColorName($0), $0.rawValue) },
            action: #selector(selectRecordingHUDCorrectingColor(_:)),
            toolTip: t("Конечный цвет градиента анимации AI-улучшения.",
                       "Gradient end color of the AI-improvement animation.")
        ))
        root.addArrangedSubview(popupRow(
            title: t("Фон капсулы", "HUD background"),
            detail: t("Системная тема или постоянный светлый/тёмный фон.",
                      "Follow the system appearance or use a fixed background."),
            selectedValue: draft.backgroundStyle.rawValue,
            options: RecordingHUDBackgroundStyle.allCases.map { (localizedBackgroundName($0), $0.rawValue) },
            action: #selector(selectRecordingHUDBackgroundStyle(_:)),
            toolTip: t("Выбрать фон плавающего индикатора диктовки.",
                       "Choose the floating dictation indicator background.")
        ))
        root.addArrangedSubview(settingsActionsRow(draft: draft))
        root.addArrangedSubview(privacyInfoView())

        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .active
        background.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            root.topAnchor.constraint(equalTo: background.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: background.bottomAnchor),
        ])

        let innerWidthInset = -(root.edgeInsets.left + root.edgeInsets.right)
        for view in root.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: root.widthAnchor,
                                        constant: innerWidthInset).isActive = true
        }
        return background
    }

    private func makeTabbedSettingsContentView() -> NSView {
        let draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 18, left: 24, bottom: 18, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false

        root.addArrangedSubview(settingsHeaderView())
        root.addArrangedSubview(separator())
        root.addArrangedSubview(settingsTabSelector())
        root.addArrangedSubview(settingsTabScrollView(draft: draft))
        root.addArrangedSubview(settingsActionsRow(draft: draft))

        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .active
        background.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            root.topAnchor.constraint(equalTo: background.topAnchor),
            root.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        let innerWidthInset = -(root.edgeInsets.left + root.edgeInsets.right)
        for view in root.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: root.widthAnchor,
                                        constant: innerWidthInset).isActive = true
        }
        return background
    }

    private func settingsTabSelector() -> NSView {
        let selector = NSSegmentedControl(
            labels: SettingsTab.allCases.map { localizedSettingsTabTitle($0) },
            trackingMode: .selectOne,
            target: self,
            action: #selector(selectSettingsTab(_:))
        )
        selector.selectedSegment = selectedSettingsTab.rawValue
        selector.segmentStyle = .texturedRounded
        selector.controlSize = .small
        selector.setAccessibilityLabel(t("Раздел настроек", "Settings section"))
        return selector
    }

    private func settingsTabScrollView(draft: ControlPanelSettingsDraft) -> NSView {
        let document = settingsTabContent(draft: draft)
        document.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = document
        scrollView.heightAnchor.constraint(equalToConstant: 342).isActive = true
        document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor).isActive = true
        // Keep short tab contents pinned to the top of the viewport. Without
        // a minimum document height, AppKit centers a document that is
        // shorter than the clip view, leaving a large blank gap above the
        // first setting on Dictation/Audio/Appearance/System tabs.
        document.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor).isActive = true
        return scrollView
    }

    private func settingsTabContent(draft: ControlPanelSettingsDraft) -> NSView {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 9
        content.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 8, right: 12)

        switch selectedSettingsTab {
        case .dictation:
            content.addArrangedSubview(speechModelRow(draft))
            content.addArrangedSubview(hotkeyRow(
                title: t("Диктовка", "Dictation"),
                shortcut: draft.dictationHotkey,
                kind: .dictation,
                toolTip: t("Начать запись. Повторное нажатие завершает её выбранным способом.",
                           "Start recording. Press again to finish using the selected action.")
            ))
            content.addArrangedSubview(primaryCompletionBehaviorRow(draft))
            content.addArrangedSubview(alternateCompletionRow(draft))
            content.addArrangedSubview(enterDelayRow(draft))
            content.addArrangedSubview(hotkeyRow(
                title: t("История", "History"),
                shortcut: draft.historyHotkey,
                kind: .history,
                toolTip: t("Открыть или закрыть последние транскрипции.",
                           "Open or close recent transcriptions.")
            ))

case .text:
            content.addArrangedSubview(normalizeNumbersRow(draft))
            content.addArrangedSubview(fillerWordsRow(draft))
            content.addArrangedSubview(removeFinalPeriodRow(draft))
            content.addArrangedSubview(correctionsInfoRow())
            content.addArrangedSubview(autoLearnVocabularyRow(draft))

        case .correction:
            // Correction section (tier, engine, endpoint/model) — gated on
            // its own toggle, independent of the rewrite section below.
            content.addArrangedSubview(llmCorrectionModeRow(draft))
            content.addArrangedSubview(hotkeyRow(
                title: t("Переключить коррекцию", "Toggle correction"),
                shortcut: draft.correctionHotkey,
                kind: .correction,
                toolTip: t("Включить или выключить коррекцию без открытия настроек.",
                           "Turn correction on or off without opening Settings.")
            ))
            content.addArrangedSubview(hotkeyRow(
                title: t("Переключить рерайт", "Toggle rewrite"),
                shortcut: draft.rewriteToggleHotkey,
                kind: .rewriteToggle,
                toolTip: t("Включить или выключить рерайт без открытия настроек.",
                           "Turn rewrite on or off without opening Settings.")
            ))
            content.addArrangedSubview(hotkeyRow(
                title: t("Режим рерайта", "Rewrite style"),
                shortcut: draft.rewriteStyleHotkey,
                kind: .rewriteStyle,
                toolTip: t("Переключить режим рерайта по кругу; выключенный рерайт включается.",
                           "Cycle the rewrite style; disabled rewrite is turned on first.")
            ))
            if draft.textPostprocessingMode == .correction {
                content.addArrangedSubview(correctionModelRow(draft))
                content.addArrangedSubview(llmEngineBackendRow(draft))
                switch draft.llmEngineBackend {
                case .bundledLocal:
                    content.addArrangedSubview(llmBundledModelStatusRow(model: draft.correctionModel))
                case .customEndpoint:
                    content.addArrangedSubview(llmCustomEndpointRows(draft))
                }
                content.addArrangedSubview(correctionPromptRow(draft))
            }
            // Rewrite section — fully independent toggles/endpoint from
            // correction (docs/specs/rewrite-tiered-correction-spec.md §1).
            content.addArrangedSubview(rewriteModeRow(draft))
            if draft.rewriteEnabled {
                content.addArrangedSubview(rewriteStyleRow(draft))
            content.addArrangedSubview(customRewriteStylesBlock(draft))
                content.addArrangedSubview(rewriteModelRow(draft))
                content.addArrangedSubview(rewriteEngineBackendRow(draft))
                switch draft.rewriteEngineBackend {
                case .bundledLocal:
                    content.addArrangedSubview(llmBundledModelStatusRow(model: draft.rewriteBundledModel))
                case .customEndpoint:
                    content.addArrangedSubview(rewriteCustomEndpointRows(draft))
                }
                content.addArrangedSubview(rewritePromptRow(draft))
            }
            let usesCustomEndpoint =
                (draft.textPostprocessingMode == .correction && draft.llmEngineBackend == .customEndpoint)
                || (draft.rewriteEnabled && draft.rewriteEngineBackend == .customEndpoint)
            if usesCustomEndpoint {
                content.addArrangedSubview(llmProxyRow(draft))
            }
            // Punctuation restoration — the last stage, after correction and
            // rewrite (PunctuationRestoration.swift).
            content.addArrangedSubview(punctuationModeRow(draft))
            if draft.punctuationRestorationEnabled {
                content.addArrangedSubview(punctuationModelRow(draft))
                content.addArrangedSubview(punctuationModelStatusRow(model: draft.punctuationModel))
            }

        case .audio:
            content.addArrangedSubview(microphoneSettingsRow(draft))
            content.addArrangedSubview(muteWhileRecordingRow(draft))
            content.addArrangedSubview(autoStopOnSilenceRow(draft))
            content.addArrangedSubview(autoStopSilenceDurationRow(draft))

        case .appearance:
            content.addArrangedSubview(popupRow(
                title: t("Размер капсулы", "Capsule size"),
                detail: t("Размер плавающего индикатора записи.",
                          "Size of the floating recording indicator."),
                selectedValue: draft.hudSize.rawValue,
                options: RecordingHUDSize.allCases.map { (localizedHUDSizeName($0), $0.rawValue) },
                action: #selector(selectRecordingHUDSize(_:)),
                toolTip: t("Выбрать компактную, обычную или крупную капсулу.",
                           "Choose a compact, standard, or large capsule.")
            ))
            content.addArrangedSubview(popupRow(
                title: t("Цвет записи", "Recording color"),
                detail: t("Цвет аудиоволн, пока микрофон слушает.",
                          "Color used while the microphone is listening."),
                selectedValue: draft.recordingColor.rawValue,
                options: RecordingHUDAccentColor.allCases.map { (localizedColorName($0), $0.rawValue) },
                action: #selector(selectRecordingHUDRecordingColor(_:)),
                toolTip: t("Цвет индикатора во время записи.", "Indicator color while recording.")
            ))
            content.addArrangedSubview(popupRow(
                title: t("Индикатор записи", "Recording indicator"),
                detail: t("Полоски уровня громкости или таймер длительности после 10 секунд записи.",
                          "Volume level bars, or an elapsed-time timer after 10 seconds of recording."),
                selectedValue: draft.hudDisplayMode.rawValue,
                options: RecordingHUDDisplayMode.allCases.map { (localizedDisplayModeName($0), $0.rawValue) },
                action: #selector(selectRecordingHUDDisplayMode(_:)),
                toolTip: t("Переключить вид плавающего индикатора во время записи.",
                           "Switch how the floating recording indicator looks while recording.")
            ))
            content.addArrangedSubview(popupRow(
                title: t("Цвет транскрибации", "Transcribing color"),
                detail: t("Цвет анимации во время распознавания речи.",
                          "Color used while speech is being converted to text."),
                selectedValue: draft.transcribingColor.rawValue,
                options: RecordingHUDAccentColor.allCases.map { (localizedColorName($0), $0.rawValue) },
                action: #selector(selectRecordingHUDTranscribingColor(_:)),
                toolTip: t("Цвет индикатора во время распознавания речи.",
                           "Color used while speech is being transcribed.")
            ))
            content.addArrangedSubview(popupRow(
                title: t("Цвет AI-улучшения", "AI polish color"),
                detail: t("Второй цвет градиента анимации улучшения текста: волна перетекает слева направо от цвета транскрибации к этому цвету.",
                          "Second color of the AI-improvement wave gradient: bars fade left-to-right from the transcribing color to this one."),
                selectedValue: draft.correctingColor.rawValue,
                options: RecordingHUDAccentColor.allCases.map { (localizedColorName($0), $0.rawValue) },
                action: #selector(selectRecordingHUDCorrectingColor(_:)),
                toolTip: t("Конечный цвет градиента анимации AI-улучшения.",
                           "Gradient end color of the AI-improvement animation.")
            ))
            content.addArrangedSubview(popupRow(
                title: t("Фон капсулы", "HUD background"),
                detail: t("Системная тема или постоянный светлый/тёмный фон.",
                          "Follow the system appearance or use a fixed background."),
                selectedValue: draft.backgroundStyle.rawValue,
                options: RecordingHUDBackgroundStyle.allCases.map { (localizedBackgroundName($0), $0.rawValue) },
                action: #selector(selectRecordingHUDBackgroundStyle(_:)),
                toolTip: t("Выбрать фон плавающего индикатора диктовки.",
                           "Choose the floating dictation indicator background.")
            ))

        case .system:
            content.addArrangedSubview(launchAtLoginRow())
            content.addArrangedSubview(privacyInfoView())
        }

        for view in content.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: content.widthAnchor,
                                        constant: -(content.edgeInsets.left + content.edgeInsets.right)).isActive = true
        }
        return content
    }

    private func localizedSettingsTabTitle(_ tab: SettingsTab) -> String {
        switch tab {
        case .dictation: return t("Диктовка", "Dictation")
        case .text: return t("Текст", "Text")
        case .correction: return t("Коррекция", "Correction")
        case .audio: return t("Аудио", "Audio")
        case .appearance: return t("Внешний вид", "Appearance")
        case .system: return t("Система", "System")
        }
    }

    @objc private func selectSettingsTab(_ sender: NSSegmentedControl) {
        guard let tab = SettingsTab(rawValue: sender.selectedSegment) else { return }
        selectedSettingsTab = tab
        settingsWindow?.contentView = makeTabbedSettingsContentView()
    }

    private func compactHeaderView() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.addArrangedSubview(panelLabel("SuperDictate Next", size: 20, weight: .semibold))
        text.addArrangedSubview(panelLabel(
            t("Локальная диктовка · работает в фоне", "Local dictation · runs in the background"),
            size: 11.5,
            color: .secondaryLabelColor
        ))

        let version = panelLabel("v\(currentBundleVersion())", size: 11, color: .tertiaryLabelColor)
        version.setContentHuggingPriority(.required, for: .horizontal)
        version.toolTip = t("Установленная версия SuperDictate Next", "Installed SuperDictate Next version")

        let languageControl = NSSegmentedControl(labels: ["RU", "EN"],
                                                 trackingMode: .selectOne,
                                                 target: self,
                                                 action: #selector(selectInterfaceLanguage(_:)))
        languageControl.selectedSegment = language == .russian ? 0 : 1
        languageControl.controlSize = .small
        languageControl.toolTip = t("Язык панели и настроек", "Panel and settings language")
        languageControl.setContentHuggingPriority(.required, for: .horizontal)

        let settingsButton = compactIconButton(
            symbol: "gearshape.fill",
            accessibilityTitle: t("Открыть настройки", "Open Settings"),
            toolTip: t("Открыть настройки диктовки и внешний вид индикатора",
                       "Open dictation and indicator appearance settings"),
            action: #selector(openSettingsClicked(_:))
        )

        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(version)
        row.addArrangedSubview(languageControl)
        row.addArrangedSubview(settingsButton)
        return row
    }

    private func settingsHeaderView() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.addArrangedSubview(panelLabel(t("Настройки", "Settings"), size: 20, weight: .semibold))
        text.addArrangedSubview(panelLabel(
            t("Изменения применятся вместе после сохранения и перезапуска службы.",
              "Changes are applied together after saving and restarting the service."),
            size: 11.5,
            color: .secondaryLabelColor
        ))
        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(panelLabel("v\(currentBundleVersion())", size: 11, color: .tertiaryLabelColor))
        return row
    }

    private func compactServiceCard() -> NSView {
        let running = SuperDictateAgentService.isAgentRunning()
        let state = AgentRuntimeStateStore.read()
        let presentation = servicePresentation(running: running, state: state)
        let card = compactCard()
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false

        let icon = panelSymbol(running ? "waveform.circle.fill" : "waveform.circle",
                               color: presentation.color,
                               description: t("Состояние службы", "Service status"),
                               pointSize: 25)
        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.addArrangedSubview(panelLabel(presentation.status, size: 14, weight: .semibold))
        let primaryShortcut = "\(t("Диктовка", "Dictation")): \(localizedHotkeyName(settings.configuredHotkey, language: language))"
        let historyShortcut = "\(t("История", "History")): \(localizedHotkeyName(settings.configuredHistoryHotkey, language: language))"
        let primaryBehavior = localizedCompletionBehavior(settings.primaryCompletionBehavior)
        let primaryAction = "\(t("Повторное нажатие", "Press again")): \(primaryBehavior)"
        let alternateAction = localizedCompletionBehavior(settings.primaryCompletionBehavior.opposite)
        let alternateShortcut = settings.alternateCompletionEnabled
            ? "\(t("Альтернативно", "Alternative")): \(localizedHotkeyName(settings.configuredEnterHotkey, language: language)) — \(alternateAction)"
            : t("Альтернативное завершение выключено", "Alternative finish is disabled")
        let detail = panelLabel(
            "\(presentation.detail)\n\(primaryShortcut) · \(historyShortcut)",
            size: 11.5,
            color: .secondaryLabelColor
        )
        detail.maximumNumberOfLines = 2
        detail.lineBreakMode = .byTruncatingTail
        detail.toolTip = "\(presentation.detail)\n\(primaryShortcut)\n\(primaryAction)\n\(alternateShortcut)\n\(historyShortcut)"
        text.addArrangedSubview(detail)

        // Progress bar for download
        if running, state?.status == "starting", let fraction = state?.downloadProgressFraction {
            let progressBar = NSProgressIndicator()
            progressBar.style = .bar
            progressBar.controlSize = .small
            progressBar.isIndeterminate = false
            progressBar.minValue = 0
            progressBar.maxValue = 1
            progressBar.doubleValue = fraction
            progressBar.translatesAutoresizingMaskIntoConstraints = false
            progressBar.heightAnchor.constraint(equalToConstant: 6).isActive = true
            text.addArrangedSubview(progressBar)
            progressBar.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        } else if running, state?.status == "starting" {
            let progressBar = NSProgressIndicator()
            progressBar.style = .bar
            progressBar.controlSize = .small
            progressBar.isIndeterminate = true
            progressBar.startAnimation(nil)
            progressBar.translatesAutoresizingMaskIntoConstraints = false
            progressBar.heightAnchor.constraint(equalToConstant: 6).isActive = true
            text.addArrangedSubview(progressBar)
            progressBar.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        }

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 5
        let enabled = serviceOperation == nil
        if running {
            actions.addArrangedSubview(compactIconButton(
                symbol: "arrow.clockwise",
                accessibilityTitle: t("Перезапустить службу", "Restart Service"),
                toolTip: t("Перезапустить фоновую службу, не закрывая панель",
                           "Restart the background service without closing the panel"),
                action: #selector(restartAgentClicked(_:)),
                enabled: enabled
            ))
            actions.addArrangedSubview(compactIconButton(
                symbol: "stop.fill",
                accessibilityTitle: t("Остановить службу", "Stop Service"),
                toolTip: t("Остановить диктовку до следующего ручного запуска",
                           "Stop dictation until it is started manually"),
                action: #selector(stopAgentClicked(_:)),
                enabled: enabled
            ))
        } else {
            actions.addArrangedSubview(compactIconButton(
                symbol: "play.fill",
                accessibilityTitle: t("Запустить службу", "Start Service"),
                toolTip: t("Запустить фоновую службу диктовки",
                           "Start the background dictation service"),
                action: #selector(startAgentClicked(_:)),
                enabled: enabled
            ))
        }

        row.addArrangedSubview(icon)
        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(actions)
        pin(row, inside: card, horizontal: 14, vertical: 11)
        card.toolTip = presentation.detail
        return card
    }

    private func compactPermissionsCard() -> NSView {
        let missing = Permission.allCases.filter { !Permissions.isGranted($0) }
        let card = compactCard()
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 7
        content.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        let color: NSColor = missing.isEmpty ? .systemGreen : .systemOrange
        header.addArrangedSubview(panelSymbol(missing.isEmpty ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
                                              color: color,
                                              description: t("Разрешения macOS", "macOS permissions"),
                                              pointSize: 15))
        header.addArrangedSubview(panelLabel(t("Разрешения macOS", "macOS permissions"),
                                             size: 12.5,
                                             weight: .semibold))
        header.addArrangedSubview(NSView())
header.addArrangedSubview(panelLabel(
            missing.isEmpty ? t("Все выданы", "All granted")
                            : t("Нужно: \(missing.count)", "Missing: \(missing.count)"),
                        size: 11.5,
                        weight: .medium,
                        color: color
                    ))
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(panelButton(
            t("Сбросить", "Reset"),
            action: #selector(resetPermissionsClicked(_:)),
            enabled: serviceOperation == nil,
            toolTip: t("Отозвать все разрешения macOS у SuperDictate (микрофон, вставка текста, хоткей). После сброса их нужно выдать заново.",
                       "Revoke all macOS permissions from SuperDictate (microphone, text insertion, hotkey). You'll need to grant them again.")
        ))
        content.addArrangedSubview(header)

        if missing.isEmpty {
            let ready = panelLabel(
                t("Микрофон, вставка текста и глобальный хоткей доступны.",
                  "Microphone, text insertion, and the global shortcut are available."),
                size: 11,
                color: .secondaryLabelColor
            )
            ready.toolTip = t("SuperDictate Next получил все три необходимых разрешения macOS.",
                              "SuperDictate Next has all three required macOS permissions.")
            content.addArrangedSubview(ready)
        } else {
            for permission in missing {
                content.addArrangedSubview(compactPermissionRow(permission))
            }
        }
        pin(content, inside: card, horizontal: 13, vertical: 10)
        return card
    }

    private func compactPermissionRow(_ permission: Permission) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        let title = panelLabel(permissionTitle(permission), size: 11.5, weight: .medium)
        title.toolTip = permissionDetail(permission)
        let buttonTitle = (permissionClickCount[permission] ?? 0) >= 1
            ? t("Открыть настройки", "Open Settings") : t("Разрешить", "Grant")
        let button = panelButton(buttonTitle,
                                 action: #selector(grantPermissionClicked(_:)),
                                 enabled: serviceOperation == nil,
                                 toolTip: t("Открыть системное разрешение: \(permissionTitle(permission))",
                                            "Open the system permission: \(permissionTitle(permission))"))
        button.controlSize = .small
        button.tag = Permission.allCases.firstIndex(of: permission) ?? -1
        row.addArrangedSubview(title)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(button)
        return row
    }

    private func compactUpdateCard() -> NSView {
        let card = compactCard()
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 11
        row.translatesAutoresizingMaskIntoConstraints = false

        let presentation = compactUpdatePresentation()
        row.addArrangedSubview(panelSymbol(presentation.symbol,
                                           color: presentation.color,
                                           description: t("Обновления", "Updates"),
                                           pointSize: 17))
        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.addArrangedSubview(panelLabel(presentation.title, size: 12.5, weight: .semibold))
        let detail = panelLabel(presentation.detail, size: 11, color: .secondaryLabelColor)
        detail.maximumNumberOfLines = 1
        detail.lineBreakMode = .byTruncatingTail
        detail.toolTip = presentation.detail
        text.addArrangedSubview(detail)
        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        if let buttonTitle = presentation.buttonTitle,
           let action = presentation.action {
            let button = panelButton(buttonTitle,
                                     action: action,
                                     enabled: presentation.buttonEnabled,
                                     toolTip: presentation.buttonToolTip)
            button.controlSize = .small
            row.addArrangedSubview(button)
        }
        pin(row, inside: card, horizontal: 13, vertical: 9)
        return card
    }

    private func compactUpdatePresentation() -> (symbol: String,
                                                   color: NSColor,
                                                   title: String,
                                                   detail: String,
                                                   buttonTitle: String?,
                                                   action: Selector?,
                                                   buttonEnabled: Bool,
                                                   buttonToolTip: String?) {
        switch updateState {
        case .checking:
            return ("arrow.triangle.2.circlepath", .systemBlue,
                    t("Проверяю обновления", "Checking for updates"),
                    t("Установлена v\(currentBundleVersion())", "Installed v\(currentBundleVersion())"),
                    nil, nil, false, nil)
        case .upToDate:
            return ("checkmark.circle.fill", .systemGreen,
                    t("SuperDictate Next актуален", "SuperDictate Next is up to date"),
                    t("Установлена последняя версия v\(currentBundleVersion())",
                      "Latest version v\(currentBundleVersion()) is installed"),
                    t("Проверить", "Check"), #selector(updateButtonClicked(_:)), true,
                    t("Проверить GitHub Releases ещё раз", "Check GitHub Releases again"))
        case .available(let release):
            return ("arrow.down.circle.fill", .systemBlue,
                    t("Доступна версия v\(release.version)", "Version v\(release.version) is available"),
                    t("Скачается, проверится и установится автоматически",
                      "Downloads, verifies, and installs automatically"),
                    t("Обновить", "Update"), #selector(updateButtonClicked(_:)), serviceOperation == nil,
                    t("Обновить SuperDictate Next до v\(release.version) одной кнопкой",
                      "Update SuperDictate Next to v\(release.version) with one click"))
        case .preparing(let version, let phase):
            return ("arrow.down.circle", .systemBlue,
                    t("Обновляю до v\(version)", "Updating to v\(version)"),
                    phase, nil, nil, false, nil)
        case .failed(let message):
            return ("exclamationmark.triangle.fill", .systemRed,
                    t("Обновление не проверено", "Update check failed"),
                    message,
                    t("Повторить", "Retry"), #selector(updateButtonClicked(_:)), true,
                    t("Повторить проверку обновлений", "Retry the update check"))
        }
    }

    private func compactPrivacyFooter() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        row.addArrangedSubview(panelSymbol("xmark.circle",
                                           color: .tertiaryLabelColor,
                                           description: nil,
                                           pointSize: 10))
        let label = panelLabel(
            t("Панель можно закрыть — диктовка продолжит работать в фоне.",
              "You can close this panel — dictation keeps running in the background."),
            size: 10.5,
            color: .tertiaryLabelColor
        )
        label.toolTip = t("Это только панель управления. Аудио и распознавание остаются на Mac.",
                          "This is only the control panel. Audio and transcription stay on this Mac.")
        row.addArrangedSubview(label)
        row.addArrangedSubview(NSView())
        return row
    }

    private func operationTitle(_ operation: ControlPanelServiceOperation) -> String {
        switch operation {
        case .starting: return t("Запускаю службу диктовки", "Starting dictation service")
        case .restarting: return t("Перезапускаю фоновую службу", "Restarting background service")
        case .stopping: return t("Останавливаю фоновую службу", "Stopping background service")
        case .applyingSettings: return t("Применяю настройки и перезапускаю службу",
                                         "Applying settings and restarting service")
        }
    }

    private func operationDetail(_ operation: ControlPanelServiceOperation) -> String {
        switch operation {
        case .starting:
            return t("Подключаю глобальный хоткей и локальную модель.\nОбычно 1–3 секунды; при первой загрузке дольше.",
                     "Enabling the global shortcut and local model.\nUsually 1–3 seconds; the first download takes longer.")
        case .restarting, .applyingSettings:
            return t("Диктовка временно недоступна. Панель не зависла — новый воркер уже запускается.",
                     "Dictation is temporarily unavailable. The panel is responsive while the new worker starts.")
        case .stopping:
            return t("Хоткей перестанет работать, но настройки и история сохранятся.",
                     "The shortcut will stop; settings and history remain saved.")
        }
    }

    private func servicePresentation(running: Bool,
                                     state: AgentRuntimeState?) -> (status: String, detail: String, color: NSColor) {
        if let operation = serviceOperation {
            return (operationTitle(operation), operationDetail(operation), .systemBlue)
        }
        if running, let state {
            if ["ready", "recording", "transcribing"].contains(state.status) {
                return (t("Работает", "Running"),
                        t("Фоновая служба включена.", "The background service is running."),
                        .systemGreen)
            }
            return (displayStatus(state.status), localizedServiceDetail(state), colorForStatus(state.status))
        }
        if running {
            return (t("Запускается", "Starting"),
                    t("Фоновый процесс запущен и готовит модель.", "The background process is preparing the model."),
                    .systemOrange)
        }
        return (settings.agentEnabled ? t("Остановлена", "Stopped") : t("Выключена", "Off"),
                t("Хоткей не работает, пока служба не запущена.",
                  "The shortcut is unavailable until the service starts."),
                settings.agentEnabled ? .systemRed : .secondaryLabelColor)
    }

    private func checkForUpdates() {
        updateTask?.cancel()
        updateState = .checking
        refresh(force: true)
        updateTask = Task { [weak self] in
            let outcome = await UpdateCheck.fetchLatest()
            guard !Task.isCancelled, let self else { return }
            self.updateTask = nil
            switch outcome {
            case .success(let release):
                self.settings.lastUpdateCheckAt = Date()
                self.settings.lastUpdateCheckSource = .manual
                self.settings.lastUpdateCheckVersion = release.version
                if isNewer(release.version, than: currentBundleVersion()) {
                    self.settings.lastUpdateCheckResult = .available
                    self.updateState = .available(release)
                } else {
                    self.settings.lastUpdateCheckResult = .upToDate
                    self.updateState = .upToDate(currentBundleVersion())
                }
            case .failure(let failure):
                self.settings.lastUpdateCheckAt = Date()
                self.settings.lastUpdateCheckSource = .manual
                self.settings.lastUpdateCheckResult = .failed
                self.updateState = .failed(self.localizedUpdateFailure(failure))
            }
            self.lastRenderFingerprint = ""
            self.refresh(force: true)
        }
    }

    private func localizedUpdateFailure(_ failure: UpdateCheckFailure) -> String {
        guard language == .russian else { return manualUpdateCheckFailureText(failure) }
        switch failure {
        case .network:
            return "Не удалось связаться с GitHub. Проверьте интернет и повторите попытку."
        case .httpStatus(403):
            return "GitHub временно ограничил проверку обновлений. Повторите через несколько минут."
        case .httpStatus(let code):
            return "GitHub вернул ошибку HTTP \(code). Повторите попытку позже."
        case .unexpectedResponse:
            return "GitHub вернул ответ, который SuperDictate не смог проверить."
        }
    }

    private func beginInAppUpdate(for release: GitHubRelease) {
        guard updateTask == nil else { return }
        let version = release.version
        updateState = .preparing(
            version: version,
            phase: t("Получаю защищённый манифест обновления…",
                     "Fetching the verified update manifest…")
        )
        refresh(force: true)
        updateTask = Task { [weak self] in
            guard let self else { return }
            do {
                let manifest = try await SuperDictateUpdateInstaller.fetchManifest(
                    expectedVersion: version
                )
                guard !Task.isCancelled else { return }
                self.updateState = .preparing(
                    version: version,
                    phase: self.t("Скачиваю архив и проверяю SHA-256…",
                                  "Downloading the archive and verifying SHA-256…")
                )
                self.refresh(force: true)
                let prepared = try await SuperDictateUpdateInstaller.prepare(manifest: manifest,
                                                                             tagName: release.tagName)
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: prepared.workDirectory)
                    return
                }
                self.updateState = .preparing(
                    version: version,
                    phase: self.t("Архив проверен. Запускаю установку…",
                                  "The archive is verified. Starting installation…")
                )
                self.refresh(force: true)
                try self.launchPreparedUpdate(prepared)
            } catch {
                self.updateTask = nil
                let message = (error as? SuperDictateUpdateInstallerError)?
                    .message(language: self.language) ?? error.localizedDescription
                self.updateState = .failed(message)
                self.lastRenderFingerprint = ""
                self.refresh(force: true)
            }
        }
    }

    private func launchPreparedUpdate(_ prepared: PreparedSuperDictateUpdate) throws {
        let statePath = try createPrivateUpdateProgressStateFile()
        let helperLog = try openPrivateUpdateHelperLog()
        let appURL = Bundle.main.bundleURL
        let backupURL = appURL.deletingLastPathComponent()
            .appendingPathComponent(".SuperDictate-update-backup-\(UUID().uuidString).app",
                                    isDirectory: true)
        let script = superDictateDirectUpdateHelperScript(
            pid: getpid(),
            targetVersion: prepared.version,
            statePath: statePath,
            stagedAppPath: prepared.stagedAppURL.path,
            workDirectory: prepared.workDirectory.path,
            backupAppPath: backupURL.path,
            appPath: appURL.path,
            language: language
        )
        let helperPath = try writePrivateUpdateHelperScript(script)

        let progressAppPath: String
        do {
            progressAppPath = try launchUpdateProgressApp(
                statePath: statePath,
                logPath: helperLog.path,
                targetVersion: prepared.version
            )
        } catch {
            try? FileManager.default.removeItem(atPath: helperPath)
            try? FileManager.default.removeItem(atPath: statePath)
            try? FileManager.default.removeItem(at: prepared.workDirectory)
            helperLog.handle.closeFile()
            throw error
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [helperPath]
        process.environment = systemToolProcessEnvironment()
        process.standardOutput = helperLog.handle
        process.standardError = helperLog.handle
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(atPath: helperPath)
            try? FileManager.default.removeItem(atPath: statePath)
            try? FileManager.default.removeItem(at: prepared.workDirectory)
            try? FileManager.default.removeItem(atPath: progressAppPath)
            helperLog.handle.closeFile()
            throw error
        }

        updateTask = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            NSApp.terminate(nil)
        }
    }

    private func launchUpdateProgressApp(statePath: String,
                                         logPath: String,
                                         targetVersion: String) throws -> String {
        let sourceAppURL = Bundle.main.bundleURL
        guard sourceAppURL.pathExtension == "app",
              let executableName = Bundle.main.executableURL?.lastPathComponent else {
            throw posixError(EINVAL)
        }
        let progressAppURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(UPDATE_PROGRESS_APP_PREFIX)\(UUID().uuidString).app",
                                    isDirectory: true)
        try FileManager.default.copyItem(at: sourceAppURL, to: progressAppURL)
        let executableURL = progressAppURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(executableName)
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            UPDATE_PROGRESS_ARGUMENT,
            statePath,
            logPath,
            targetVersion,
            progressAppURL.path,
        ]
        process.environment = systemToolProcessEnvironment()
        do {
            try process.run()
            return progressAppURL.path
        } catch {
            try? FileManager.default.removeItem(at: progressAppURL)
            throw error
        }
    }

    private func statusRow(title: String,
                           detail: String,
                           status: String,
                           statusColor: NSColor,
                           buttonTitle: String? = nil,
                           action: Selector? = nil,
                           tag: Int = 0,
                           buttonEnabled: Bool = true,
                           toolTip: String? = nil) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.addArrangedSubview(panelLabel(title, size: 13, weight: .semibold))
        let detailLabel = panelLabel(detail, size: 12, color: .secondaryLabelColor)
        detailLabel.preferredMaxLayoutWidth = 440
        text.addArrangedSubview(detailLabel)

        let statusLabel = panelLabel(status, size: 12, weight: .medium, color: statusColor)
        statusLabel.alignment = .right
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(statusLabel)
        if let buttonTitle, let action {
            let button = panelButton(buttonTitle,
                                     action: action,
                                     enabled: buttonEnabled,
                                     toolTip: toolTip)
            button.tag = tag
            row.addArrangedSubview(button)
        }
        return row
    }

    private func hotkeyRow(title: String,
                           shortcut: HotkeyChoice,
                           kind: ControlPanelShortcutKind,
                           toolTip: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14

        row.addArrangedSubview(panelLabel(title, size: 13, weight: .semibold))
        row.addArrangedSubview(NSView())
        let button = panelButton(localizedHotkeyName(shortcut, language: language),
                                 action: #selector(recordDictationShortcutClicked(_:)),
                                 enabled: serviceOperation == nil,
                                 toolTip: toolTip)
        button.tag = kind.rawValue
        button.controlSize = .regular
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.widthAnchor.constraint(equalToConstant: 200).isActive = true
        row.addArrangedSubview(button)
        return row
    }

    private func primaryCompletionBehaviorRow(_ draft: ControlPanelSettingsDraft) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.addArrangedSubview(panelLabel(t("Повторное нажатие", "Press again"),
                                           size: 13,
                                           weight: .semibold))
        text.addArrangedSubview(panelLabel(
            t("Что сделать после вставки распознанного текста.",
              "What to do after inserting the transcribed text."),
            size: 12,
            color: .secondaryLabelColor
        ))

        let control = NSSegmentedControl(
            labels: [t("Вставить", "Insert"), t("Вставить + Enter", "Insert + Enter")],
            trackingMode: .selectOne,
            target: self,
            action: #selector(selectPrimaryCompletionBehavior(_:))
        )
        control.selectedSegment = draft.primaryCompletionBehavior == .insert ? 0 : 1
        control.isEnabled = serviceOperation == nil
        control.toolTip = t("Выберите действие при повторном нажатии основного хоткея.",
                            "Choose what the main shortcut does when pressed again.")
        control.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(control)
        return row
    }

    private func alternateCompletionRow(_ draft: ControlPanelSettingsDraft) -> NSView {
        let behavior = draft.primaryCompletionBehavior.opposite
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.addArrangedSubview(panelLabel(
            behavior == .insert
                ? t("Завершить без Enter", "Finish without Enter")
                : t("Завершить + Enter", "Finish + Enter"),
            size: 13,
            weight: .semibold
        ))
        text.addArrangedSubview(panelLabel(
            t("Дополнительный хоткей работает только во время записи.",
              "The alternative shortcut only works while recording."),
            size: 12,
            color: .secondaryLabelColor
        ))

        let toggle = NSSwitch()
        toggle.target = self
        toggle.action = #selector(toggleAlternateCompletion(_:))
        toggle.state = draft.alternateCompletionEnabled ? .on : .off
        toggle.isEnabled = serviceOperation == nil
        toggle.toolTip = t("Включить дополнительный способ завершения записи.",
                           "Enable the alternative way to finish recording.")
        toggle.setContentHuggingPriority(.required, for: .horizontal)

        let button = panelButton(
            localizedHotkeyName(draft.alternateCompletionHotkey, language: language),
            action: #selector(recordDictationShortcutClicked(_:)),
            enabled: draft.alternateCompletionEnabled && serviceOperation == nil,
            toolTip: t("Изменить дополнительный хоткей завершения.",
                       "Change the alternative finish shortcut.")
        )
        button.tag = ControlPanelShortcutKind.alternateCompletion.rawValue
        button.controlSize = .regular
        button.widthAnchor.constraint(equalToConstant: 200).isActive = true

        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(toggle)
        row.addArrangedSubview(button)
        return row
    }

    private func normalizeNumbersRow(_ draft: ControlPanelSettingsDraft) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.addArrangedSubview(panelLabel(
            t("Числа цифрами", "Numbers as digits"),
            size: 13,
            weight: .semibold
        ))
        text.addArrangedSubview(panelLabel(
            t("Записывать продиктованные числа цифрами (25) вместо слов (двадцать пять). Только для русского языка.",
              "Write dictated numbers as digits (25) instead of words (twenty five). Russian only."),
            size: 12,
            color: .secondaryLabelColor
        ))

        let toggle = NSSwitch()
        toggle.target = self
        toggle.action = #selector(toggleNormalizeNumbers(_:))
        toggle.state = draft.normalizeNumbersToDigits ? .on : .off
        toggle.toolTip = t("Включить преобразование чисел в цифры.",
                           "Enable converting numbers to digits.")
        toggle.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(toggle)
        return row
    }

    private func fillerWordsRow(_ draft: ControlPanelSettingsDraft) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 8

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.addArrangedSubview(panelLabel(
            t("Удалять слова-паразиты", "Remove filler words"),
            size: 13,
            weight: .semibold
        ))
        text.addArrangedSubview(panelLabel(
            t("Удаляет слова-хезитации и разговорные паразиты из текста диктовки.",
              "Removes hesitation sounds and verbal tics from dictated text."),
            size: 12,
            color: .secondaryLabelColor
        ))

        let toggle = NSSwitch()
        toggle.target = self
        toggle.action = #selector(toggleRemoveFillerWordsSetting(_:))
        toggle.state = draft.removeFillerWords ? .on : .off
        toggle.toolTip = t("Включить удаление слов-паразитов.",
                           "Enable removing filler words.")
        toggle.setContentHuggingPriority(.required, for: .horizontal)

        header.addArrangedSubview(text)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(toggle)
        container.addArrangedSubview(header)

        if draft.removeFillerWords {
            // Four columns across, like the Windows port's QGridLayout:
            // the words are short, so a single column left most of the
            // window width empty and made the list look unfinished.
            // Row-major order (left to right, then down), presets first,
            // then the user's own words -- the same ordering the Windows
            // port uses. Four vertical stacks inside a .fillEqually
            // horizontal stack guarantee equal column widths structurally,
            // which is what the Windows port needed setColumnStretch for:
            // one long word must not drag the whole grid sideways.
            let fillerColumnCount = 4
            var columnStacks: [NSStackView] = []
            for _ in 0..<fillerColumnCount {
                let column = NSStackView()
                column.orientation = .vertical
                column.alignment = .leading
                column.spacing = 4
                columnStacks.append(column)
            }

            func addCell(_ cell: NSView, at index: Int) {
                let column = columnStacks[index % fillerColumnCount]
                column.addArrangedSubview(cell)
                cell.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            }

            var cellIndex = 0
            for preset in FillerWordRemover.presets {
                let box = NSButton(checkboxWithTitle: preset.displayText, target: self, action: #selector(toggleFillerPreset(_:)))
                box.state = draft.enabledFillerPresetKeys.contains(preset.key) ? .on : .off
                box.identifier = NSUserInterfaceItemIdentifier(preset.key)
                box.lineBreakMode = .byTruncatingTail
                box.toolTip = preset.displayText
                addCell(box, at: cellIndex)
                cellIndex += 1
            }
            for word in draft.customFillerWords {
                let cell = NSStackView()
                cell.orientation = .horizontal
                cell.alignment = .centerY
                cell.spacing = 4
                let box = NSButton(checkboxWithTitle: word, target: self, action: #selector(toggleCustomFillerWord(_:)))
                box.state = draft.disabledCustomFillerWords.contains(word) ? .off : .on
                box.identifier = NSUserInterfaceItemIdentifier(word)
                box.lineBreakMode = .byTruncatingTail
                box.toolTip = word
                box.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                cell.addArrangedSubview(box)
                cell.addArrangedSubview(NSView())
                let remove = NSButton(title: "×", target: self, action: #selector(removeCustomFillerWord(_:)))
                remove.identifier = NSUserInterfaceItemIdentifier(word)
                remove.bezelStyle = .inline
                remove.toolTip = t("Убрать слово из списка", "Remove this word from the list")
                remove.setContentHuggingPriority(.required, for: .horizontal)
                cell.addArrangedSubview(remove)
                addCell(cell, at: cellIndex)
                cellIndex += 1
            }

            let columnsRow = NSStackView(views: columnStacks)
            columnsRow.orientation = .horizontal
            columnsRow.alignment = .top
            columnsRow.spacing = 12
            columnsRow.distribution = .fillEqually
            columnsRow.translatesAutoresizingMaskIntoConstraints = false

            let scroll = NSScrollView()
            scroll.documentView = columnsRow
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            scroll.translatesAutoresizingMaskIntoConstraints = false
            // Without explicit constraints a view used as a scroll document
            // stays (0,0,0,0) and the whole checklist renders empty -- pin
            // its width to the clip view and give the scroll view itself a
            // real height.
            NSLayoutConstraint.activate([
                columnsRow.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
                columnsRow.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
                columnsRow.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
                scroll.heightAnchor.constraint(equalToConstant: 180),
            ])
            container.addArrangedSubview(scroll)

            let customField = NSTextField()
            customField.placeholderString = t("Добавить своё слово или фразу и нажать Enter",
                                              "Add a custom word or phrase and press Enter")
            customField.target = self
            customField.action = #selector(addCustomFillerWord(_:))
            container.addArrangedSubview(customField)

            // The container is a vertical stack with .leading alignment, so
            // its arranged subviews keep their intrinsic (near-zero) width
            // unless pinned -- the outer makeSettingsContentView only pins
            // the container itself to the window width.
            NSLayoutConstraint.activate([
                header.widthAnchor.constraint(equalTo: container.widthAnchor),
                scroll.widthAnchor.constraint(equalTo: container.widthAnchor),
                customField.widthAnchor.constraint(equalTo: container.widthAnchor),
            ])
        }

        return container
    }

    private var silenceDurationOptions: [(title: String, value: String)] {
        (1...10).map { ("\($0) \(t("сек", "sec"))", String($0)) }
    }

    private func autoStopOnSilenceRow(_ draft: ControlPanelSettingsDraft) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.addArrangedSubview(panelLabel(
            t("Останавливать запись при тишине", "Stop automatically after silence"),
            size: 13,
            weight: .semibold
        ))
        text.addArrangedSubview(panelLabel(
            t("Диктовка завершится сама после указанного времени тишины.",
              "Dictation ends on its own after the configured amount of silence."),
            size: 12,
            color: .secondaryLabelColor
        ))

        let toggle = NSSwitch()
        toggle.target = self
        toggle.action = #selector(toggleAutoStopOnSilence(_:))
        toggle.state = draft.autoStopOnSilenceEnabled ? .on : .off
        toggle.toolTip = t("Автоматически завершать запись после длительной тишины.",
                           "Automatically end recording after a long silence.")
        toggle.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(toggle)
        return row
    }

    private func autoStopSilenceDurationRow(_ draft: ControlPanelSettingsDraft) -> NSView {
        popupRow(
            title: t("Длительность тишины", "Silence duration"),
            detail: t("Сколько секунд тишины ждать перед остановкой.",
                      "How many seconds of silence to wait before stopping."),
            selectedValue: String(draft.autoStopSilenceSeconds),
            options: silenceDurationOptions,
            action: #selector(selectAutoStopSilenceSeconds(_:)),
            toolTip: t("Настроить порог тишины для автоостановки.",
                       "Configure the silence threshold for auto-stop.")
        )
    }

    private func launchAtLoginRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.addArrangedSubview(panelLabel(
            t("Запускать при входе в систему", "Launch at Login"),
            size: 13,
            weight: .semibold
        ))
        text.addArrangedSubview(panelLabel(
            t("Открывать SuperDictate Next автоматически при входе в macOS.",
              "Open SuperDictate Next automatically when you log in to macOS."),
            size: 12,
            color: .secondaryLabelColor
        ))

        let toggle = NSSwitch()
        toggle.target = self
        toggle.action = #selector(toggleLaunchAtLoginSetting(_:))
        switch SMAppService.mainApp.status {
        case .enabled:
            toggle.state = .on
        case .requiresApproval:
            toggle.state = .mixed
            toggle.toolTip = t("Подтвердите в Системных настройках → Основные → Элементы входа.",
                               "Approve in System Settings → General → Login Items.")
        default:
            toggle.state = .off
        }
        toggle.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(toggle)
        return row
    }

    private func muteWhileRecordingRow(_ draft: ControlPanelSettingsDraft) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.addArrangedSubview(panelLabel(
            t("Заглушать системный звук во время записи", "Mute system audio while recording"),
            size: 13,
            weight: .semibold
        ))
        text.addArrangedSubview(panelLabel(
            t("Временно приглушает воспроизведение, пока микрофон слушает.",
              "Temporarily mutes playback while the microphone is listening."),
            size: 12,
            color: .secondaryLabelColor
        ))

        let toggle = NSSwitch()
        toggle.target = self
        toggle.action = #selector(toggleMuteWhileRecordingSetting(_:))
        toggle.state = draft.muteWhileRecording ? .on : .off
        toggle.toolTip = t("Заглушать системный звук во время записи.",
                           "Mute system audio while recording.")
        toggle.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(toggle)
        return row
    }

    private func removeFinalPeriodRow(_ draft: ControlPanelSettingsDraft) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.addArrangedSubview(panelLabel(
            t("Убирать финальную точку", "Remove final period"),
            size: 13,
            weight: .semibold
        ))
        text.addArrangedSubview(panelLabel(
            t("Удалять точку в конце продиктованного текста (кроме многоточий).",
              "Drop the trailing period from dictated text (ellipses are kept)."),
            size: 12,
            color: .secondaryLabelColor
        ))

        let toggle = NSSwitch()
        toggle.target = self
        toggle.action = #selector(toggleRemoveFinalPeriodSetting(_:))
        toggle.state = draft.removeFinalPeriod ? .on : .off
        toggle.toolTip = t("Удалять точку в конце продиктованного текста (кроме многоточий).",
                           "Drop the trailing period from dictated text (ellipses are kept).")
        toggle.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(toggle)
        return row
    }

    private func autoLearnVocabularyRow(_ draft: ControlPanelSettingsDraft) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.addArrangedSubview(panelLabel(
            t("Автоматически учить словарь по вашим правкам", "Automatically learn vocabulary from your edits"),
            size: 13,
            weight: .semibold
        ))

        let toggle = NSSwitch()
        toggle.target = self
        toggle.action = #selector(toggleAutoLearnVocabularySetting(_:))
        toggle.state = draft.autoLearnVocabularyEnabled ? .on : .off
        toggle.toolTip = t("Автоматически учить словарь по вашим правкам.",
                           "Automatically learn vocabulary from your edits.")
        toggle.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(toggle)
        return row
    }

    private func correctionsInfoRow() -> NSView {
        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.addArrangedSubview(panelLabel(
            t("Исправления транскрипции", "Text corrections"),
            size: 13,
            weight: .semibold
        ))
        text.addArrangedSubview(panelLabel(
            t("Управляются из меню значка в строке меню → «Исправления текста».",
              "Managed from the menu bar icon → “Text Corrections”."),
            size: 12,
            color: .secondaryLabelColor
        ))

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(panelButton(
            t("Открыть словарь…", "Open Vocabulary…"),
            action: #selector(openVocabularyManager),
            toolTip: t("Открыть окно управления словарём исправлений (добавить, изменить, удалить, импорт/экспорт).",
                       "Open the vocabulary manager window (add, edit, delete, import/export).")
        ))
        return row
    }

    @objc private func openVocabularyManager() {
        vocabularyManagerWindowController.show()
    }

    // MARK: - LLM correction (Correction tab)
    //
    // Local memory atom a81da166-460a-467e-ae78-f53667069cb0: a small
    // local (or user-supplied OpenAI-compatible) model corrects
    // spelling/punctuation/casing/foreign-term script after ASR, without
    // rewriting style. This UI only edits settings (persisted on Save &
    // Restart, like every other tab) plus drives the model download
    // directly in THIS process — downloading a file needs no background
    // dictation service. `llmModelDownloadState` is separate from
    // `settingsDraft` on purpose: it's this window's own transient
    // progress, never persisted, never part of the has-unsaved-changes
    // comparison.

    private func llmCorrectionModeRow(_ draft: ControlPanelSettingsDraft) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.addArrangedSubview(panelLabel(
            t("Исправлять ошибки распознавания", "Correct recognition errors"),
            size: 13,
            weight: .semibold
        ))
        let modeDescription = panelLabel(
            t("Локальная модель поверх обычных исправлений: орфография, пунктуация, регистр и написание иностранных терминов. Стиль и смысл текста не меняются.",
              "A local model layered on top of the regular corrections: spelling, punctuation, casing, and foreign-term spelling. Style and meaning are never changed."),
            size: 12,
            color: .secondaryLabelColor
        )
        modeDescription.preferredMaxLayoutWidth = 440
        text.addArrangedSubview(modeDescription)

        let toggle = NSSwitch()
        toggle.target = self
        toggle.action = #selector(toggleLLMCorrectionMode(_:))
        toggle.state = draft.textPostprocessingMode == .correction ? .on : .off
        toggle.toolTip = t("Включить коррекцию текста локальной моделью.",
                           "Enable text correction by a local model.")
        toggle.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(toggle)
        return row
    }

    private func llmEngineBackendRow(_ draft: ControlPanelSettingsDraft) -> NSView {
        popupRow(
            title: t("Движок", "Engine"),
            detail: t("Встроенная модель работает полностью локально. Свой сервер — любой OpenAI-совместимый эндпоинт (например llama-server).",
                      "The built-in model runs fully locally. A custom server is any OpenAI-compatible endpoint (e.g. llama-server)."),
            selectedValue: draft.llmEngineBackend.rawValue,
            options: [
                (t("Встроенная (локально)", "Built-in (local)"), LLMEngineBackend.bundledLocal.rawValue),
                (t("Свой сервер", "Custom server"), LLMEngineBackend.customEndpoint.rawValue),
            ],
            action: #selector(selectLLMEngineBackend(_:)),
            toolTip: t("Выбрать, где выполняется коррекция текста.", "Choose where text correction runs.")
        )
    }

    /// Status + download row for a bundled LLM model file: shows the
    /// model's benchmark digest and its on-disk size, ready/missing state,
    /// and a Download/Re-download/Cancel button (tag carries the model).
    private func llmBundledModelStatusRow(model: BundledLLMModel) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 8

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.addArrangedSubview(panelLabel(model.displayName, size: 13, weight: .semibold))

        let sizeLabel = formattedByteCount(UInt64(bundledLLMModelDownloadSize(model)))
        let modelReady = bundledLLMModelExists(model)
        let readyText = t("Готова (\(model.benchmarkSummary))",
                          "Ready (\(model.benchmarkSummary))")
        let missingText = t("Не скачана (\(sizeLabel)) · \(model.benchmarkSummary)",
                            "Not downloaded (\(sizeLabel)) · \(model.benchmarkSummary)")

        let statusText: String
        let statusColor: NSColor
        // A download in flight is only shown by the row for THAT model;
        // other models' rows keep their plain ready/missing status.
        let downloadInFlight = llmModelDownloadTask != nil && llmModelDownloadModel == model
        let liveProgress = downloadInFlight ? llmModelDownloadProgress : nil
        if downloadInFlight, case .downloading = llmModelDownloadState {
            if let liveProgress, liveProgress.total > 0 {
                let fraction = Double(liveProgress.received) / Double(liveProgress.total)
                statusText = t("Скачивание… " + String(Int(fraction * 100)) + "% (" + formattedByteCount(UInt64(liveProgress.received)) + " из " + formattedByteCount(UInt64(liveProgress.total)) + ")",
                               "Downloading… " + String(Int(fraction * 100)) + "% (" + formattedByteCount(UInt64(liveProgress.received)) + " of " + formattedByteCount(UInt64(liveProgress.total)) + ")")
            } else {
                statusText = t("Скачивание…", "Downloading…")
            }
            statusColor = .systemBlue
        } else if downloadInFlight, case .failed(let message) = llmModelDownloadState {
            statusText = message
            statusColor = .systemRed
        } else {
            statusText = modelReady ? readyText : missingText
            statusColor = modelReady ? .systemGreen : .secondaryLabelColor
        }
        let statusLabel = panelLabel(statusText, size: 12, color: statusColor)
        text.addArrangedSubview(statusLabel)
        if downloadInFlight {
            llmDownloadStatusLabel = statusLabel
        }

        let button: NSButton
        if downloadInFlight, case .downloading = llmModelDownloadState {
            button = panelButton(t("Отменить", "Cancel"), action: #selector(cancelLLMModelDownload(_:)))
        } else {
            button = panelButton(
                modelReady ? t("Скачать заново", "Re-download") : t("Скачать", "Download"),
                action: #selector(startBundledModelDownloadClicked(_:))
            )
            // The tag carries the model through the @objc selector
            // (BundledLLMModel.allCases index — stable within a run).
            button.tag = BundledLLMModel.allCases.firstIndex(of: model) ?? 0
        }

        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(button)
        container.addArrangedSubview(row)

        if downloadInFlight, case .downloading = llmModelDownloadState {
            let progressBar = NSProgressIndicator()
            progressBar.style = .bar
            progressBar.controlSize = .small
            if let liveProgress, liveProgress.total > 0 {
                progressBar.isIndeterminate = false
                progressBar.minValue = 0
                progressBar.maxValue = 1
                progressBar.doubleValue = Double(liveProgress.received) / Double(liveProgress.total)
            } else {
                progressBar.isIndeterminate = true
                progressBar.startAnimation(nil)
            }
            progressBar.translatesAutoresizingMaskIntoConstraints = false
            progressBar.heightAnchor.constraint(equalToConstant: 6).isActive = true
            container.addArrangedSubview(progressBar)
            progressBar.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
            llmDownloadProgressBar = progressBar
        }

        return container
    }

    private func llmCustomEndpointRows(_ draft: ControlPanelSettingsDraft) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 8

        func fieldRow(title: String, placeholder: String, value: String, tag: Int, secure: Bool) -> NSView {
            let row = NSStackView()
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 3
            row.addArrangedSubview(panelLabel(title, size: 12, weight: .medium, color: .secondaryLabelColor))

            let field: NSTextField = secure ? NSSecureTextField() : NSTextField()
            field.placeholderString = placeholder
            field.stringValue = value
            field.tag = tag
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
            row.addArrangedSubview(field)
            field.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            return row
        }

        container.addArrangedSubview(fieldRow(
            title: t("Базовый URL (OpenAI-совместимый)", "Base URL (OpenAI-compatible)"),
            placeholder: "http://127.0.0.1:8080",
            value: draft.llmCustomBaseURL,
            tag: Self.llmCustomBaseURLFieldTag,
            secure: false
        ))
        container.addArrangedSubview(fieldRow(
            title: t("API-ключ (необязательно)", "API key (optional)"),
            placeholder: "",
            value: draft.llmCustomAPIKey,
            tag: Self.llmCustomAPIKeyFieldTag,
            secure: true
        ))
        container.addArrangedSubview(fieldRow(
            title: t("Имя модели", "Model name"),
            placeholder: "gpt-4o-mini",
            value: draft.llmCustomModelName,
            tag: Self.llmCustomModelNameFieldTag,
            secure: false
        ))

        NSLayoutConstraint.activate(container.arrangedSubviews.map {
            $0.widthAnchor.constraint(equalTo: container.widthAnchor)
        })
        return container
    }

    /// Same three-field block as llmCustomEndpointRows, but for the
    /// rewrite pass's OWN endpoint (tags 9004-9006) — correction and
    /// rewrite custom endpoints are fully independent
    /// (docs/specs/rewrite-tiered-correction-spec.md §1.5).
    private func rewriteCustomEndpointRows(_ draft: ControlPanelSettingsDraft) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 8

        func fieldRow(title: String, placeholder: String, value: String, tag: Int, secure: Bool) -> NSView {
            let row = NSStackView()
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 3
            row.addArrangedSubview(panelLabel(title, size: 12, weight: .medium, color: .secondaryLabelColor))

            let field: NSTextField = secure ? NSSecureTextField() : NSTextField()
            field.placeholderString = placeholder
            field.stringValue = value
            field.tag = tag
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
            row.addArrangedSubview(field)
            field.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            return row
        }

        container.addArrangedSubview(fieldRow(
            title: t("Базовый URL реврайта (OpenAI-совместимый)", "Rewrite base URL (OpenAI-compatible)"),
            placeholder: "http://127.0.0.1:8080",
            value: draft.rewriteCustomBaseURL,
            tag: Self.rewriteCustomBaseURLFieldTag,
            secure: false
        ))
        container.addArrangedSubview(fieldRow(
            title: t("API-ключ (необязательно)", "API key (optional)"),
            placeholder: "",
            value: draft.rewriteCustomAPIKey,
            tag: Self.rewriteCustomAPIKeyFieldTag,
            secure: true
        ))
        container.addArrangedSubview(fieldRow(
            title: t("Имя модели реврайта", "Rewrite model name"),
            placeholder: "gpt-4o-mini",
            value: draft.rewriteCustomModelName,
            tag: Self.rewriteCustomModelNameFieldTag,
            secure: false
        ))

        NSLayoutConstraint.activate(container.arrangedSubviews.map {
            $0.widthAnchor.constraint(equalTo: container.widthAnchor)
        })
        return container
    }

    /// One switch for both custom endpoints: whether internet addresses go
    /// through the system proxy. LAN addresses (loopback, 10/8, 172.16/12,
    /// 192.168/16, *.local) always bypass it — a proxy has no route into
    /// the user's own machine or LAN.
    private func llmProxyRow(_ draft: ControlPanelSettingsDraft) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.addArrangedSubview(panelLabel(
            t("Использовать системный прокси", "Use the system proxy"),
            size: 13,
            weight: .semibold
        ))
        let detail = panelLabel(
            t("Для интернет-адресов моделей коррекции и рерайта. Локальные адреса (127.0.0.1, 192.168.x.x, 10.x.x.x, *.local) всегда открываются напрямую, без прокси.",
              "For internet addresses of the correction and rewrite models. Local addresses (127.0.0.1, 192.168.x.x, 10.x.x.x, *.local) always connect directly, without the proxy."),
            size: 12,
            color: .secondaryLabelColor
        )
        detail.preferredMaxLayoutWidth = 440
        text.addArrangedSubview(detail)

        let toggle = NSSwitch()
        toggle.target = self
        toggle.action = #selector(toggleLLMUseSystemProxy(_:))
        toggle.state = draft.llmUseSystemProxy ? .on : .off
        toggle.toolTip = t("Использовать системный прокси для интернет-адресов моделей коррекции и рерайта.",
                           "Use the system proxy for internet addresses of the correction and rewrite models.")
        toggle.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(toggle)
        return row
    }

    /// Bundled correction model picker — the benchmark's small-model class
    /// (benchmark/REPORT.md correction table). Numbers in the detail line
    /// come from the same report; the "?" button opens the benchmark
    /// summary.
    private func correctionModelRow(_ draft: ControlPanelSettingsDraft) -> NSView {
        popupRow(
            title: t("Модель коррекции", "Correction model"),
            detail: t("Маленькие модели из замеров: VoiceScribe — мгновенная (0,19 с), Qwen3.5-4B — точнейшая из малых (EM 0,72). Подробности — кнопка «?».",
                      "Small models from the benchmark: VoiceScribe — instant (0.19 s), Qwen3.5-4B — most accurate of the small ones (EM 0.72). Details — the \"?\" button."),
            selectedValue: draft.correctionModel.rawValue,
            options: BundledLLMModel.correctionModels.map { model in
                (model == .voiceScribe
                    ? t("\(model.displayName) — рекомендуется", "\(model.displayName) — recommended")
                    : model.displayName,
                 model.rawValue)
            },
            action: #selector(selectCorrectionBundledModel(_:)),
            toolTip: t("Выбрать встроенную модель коррекции (замеры — кнопка «?»).",
                       "Choose the bundled correction model (benchmark — the \"?\" button)."),
            showsHelp: true
        )
    }

    /// The rewrite master toggle — deliberately NOT coupled to the
    /// correction toggle above it: both may be on at once, in which case
    /// correction runs first and rewrite second.
    private func rewriteModeRow(_ draft: ControlPanelSettingsDraft) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.addArrangedSubview(panelLabel(
            t("Реврайтинг текста", "Text rewriting"),
            size: 13,
            weight: .semibold
        ))
        let modeDescription = panelLabel(
            t("Переписывает продиктованный текст выбранным способом: причесать, структурировать в задачу или официальный стиль. Работает независимо от коррекции и может включаться вместе с ней.",
              "Rewrites dictated text the selected way: polish, structure into a task, or official style. Independent from correction and can be enabled together with it."),
            size: 12,
            color: .secondaryLabelColor
        )
        modeDescription.preferredMaxLayoutWidth = 440
        text.addArrangedSubview(modeDescription)

        let toggle = NSSwitch()
        toggle.target = self
        toggle.action = #selector(toggleRewriteMode(_:))
        toggle.state = draft.rewriteEnabled ? .on : .off
        toggle.toolTip = t("Включить реврайтинг текста.", "Enable text rewriting.")
        toggle.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(toggle)
        return row
    }

    private func punctuationModeRow(_ draft: ControlPanelSettingsDraft) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.addArrangedSubview(panelLabel(
            t("Восстановление пунктуации", "Punctuation restoration"),
            size: 13,
            weight: .semibold
        ))
        let detail = panelLabel(
            t("Последний этап после коррекции и рерайта: отдельная модель расставляет запятые, точки, вопросительные знаки, двоеточия и тире. Уже стоящие точки, «!» и «?» не убирает. Работает локально на процессоре.",
              "The last stage, after correction and rewrite: a separate model places commas, periods, question marks, colons and dashes. It never removes periods, \"!\" or \"?\" that are already there. Runs locally on the CPU."),
            size: 12,
            color: .secondaryLabelColor
        )
        detail.preferredMaxLayoutWidth = 440
        text.addArrangedSubview(detail)

        let toggle = NSSwitch()
        toggle.target = self
        toggle.action = #selector(togglePunctuationRestoration(_:))
        toggle.state = draft.punctuationRestorationEnabled ? .on : .off
        toggle.toolTip = t("Восстанавливать пунктуацию моделью.", "Restore punctuation with a model.")
        toggle.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(toggle)
        return row
    }

    private func punctuationModelRow(_ draft: ControlPanelSettingsDraft) -> NSView {
        popupRow(
            title: t("Модель пунктуации", "Punctuation model"),
            detail: t("Base точнее, Small быстрее и легче: ~60 и ~25 мс на фразу, ~1,5 и ~0,7 ГБ памяти.",
                      "Base is more accurate, Small is faster and lighter: ~60 and ~25 ms per sentence, ~1.5 and ~0.7 GB of memory."),
            selectedValue: draft.punctuationModel.rawValue,
            options: PunctuationModel.allCases.map { model in
                (model.displayName + (model == .base ? t(" — рекомендуется", " — recommended") : ""), model.rawValue)
            },
            action: #selector(selectPunctuationModel(_:)),
            toolTip: t("Выбрать модель восстановления пунктуации.", "Choose the punctuation restoration model.")
        )
    }

    private func punctuationModelStatusRow(model: PunctuationModel) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 8

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.addArrangedSubview(panelLabel("Horizon Labs punctuation-restoration \(model.displayName)",
                                           size: 13, weight: .semibold))
        let inFlight = punctuationDownloadTask != nil && punctuationDownloadModel == model
        let ready = punctuationModelInstalled(model)
        let statusText: String
        let statusColor: NSColor
        if inFlight {
            statusText = t("Скачивание… \(Int((punctuationDownloadFraction ?? 0) * 100))%",
                           "Downloading… \(Int((punctuationDownloadFraction ?? 0) * 100))%")
            statusColor = .systemBlue
        } else if let error = punctuationDownloadError, punctuationDownloadModel == model {
            statusText = error
            statusColor = .systemRed
        } else if ready {
            statusText = t("Готова · Apache-2.0", "Ready · Apache-2.0")
            statusColor = .systemGreen
        } else {
            statusText = t("Не скачана (\(formattedByteCount(UInt64(model.downloadBytes)))). Пока модели нет, текст вставляется без этого этапа.",
                           "Not downloaded (\(formattedByteCount(UInt64(model.downloadBytes)))). Until it is, text is inserted without this stage.")
            statusColor = .secondaryLabelColor
        }
        let statusLabel = panelLabel(statusText, size: 12, color: statusColor)
        statusLabel.preferredMaxLayoutWidth = 440
        text.addArrangedSubview(statusLabel)
        if inFlight { punctuationDownloadStatusLabel = statusLabel }

        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        if inFlight {
            row.addArrangedSubview(panelButton(t("Отменить", "Cancel"), action: #selector(cancelPunctuationModelDownload(_:))))
        } else if !ready {
            row.addArrangedSubview(panelButton(t("Скачать", "Download"), action: #selector(startPunctuationModelDownload(_:))))
        }
        container.addArrangedSubview(row)

        if inFlight {
            let bar = NSProgressIndicator()
            bar.style = .bar
            bar.controlSize = .small
            bar.isIndeterminate = false
            bar.minValue = 0
            bar.maxValue = 1
            bar.doubleValue = punctuationDownloadFraction ?? 0
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.heightAnchor.constraint(equalToConstant: 6).isActive = true
            container.addArrangedSubview(bar)
            bar.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
            punctuationDownloadProgressBar = bar
        }
        return container
    }

    private func rewriteStyleRow(_ draft: ControlPanelSettingsDraft) -> NSView {
        popupRow(
            title: t("Режим реврайта", "Rewrite style"),
            detail: t("Причесать — убрать повторы и несогласования. Задача — структурировать вольный текст в чёткую задачу. Официальный — сухой формальный стиль.",
                      "Polish — remove repeats and mismatches. Task — structure free-form text into a clear task. Official — dry formal style."),
            selectedValue: draft.rewriteStyleID,
            options: [
                (t("Причесать текст", "Polish text"), RewriteStyle.polish.rawValue),
                (t("Структурировать в задачу", "Structure into a task"), RewriteStyle.structuredTask.rawValue),
                (t("Официальный стиль", "Official style"), RewriteStyle.official.rawValue),
            ] + draft.customRewriteStyles.map { ($0.name, $0.id) },
            action: #selector(selectRewriteStyle(_:)),
            toolTip: t("Выбрать способ переработки текста.", "Choose how the text is rewritten.")
        )
    }

    /// User-created rewrite modes: one row per mode (color swatch, name,
    /// activation hotkey, edit/delete) plus the «Новый режим» button.
    /// Creation/editing opens a modal sheet (name, color, instruction,
    /// hotkey); persistence happens on Save like every other setting.
    private func customRewriteStylesBlock(_ draft: ControlPanelSettingsDraft) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 6

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.addArrangedSubview(panelLabel(
            t("Свои режимы реврайта", "Custom rewrite modes"),
            size: 13,
            weight: .semibold
        ))
        header.addArrangedSubview(NSView())
        let addButton = panelButton(
            t("＋ Новый режим", "＋ New mode"),
            action: #selector(addCustomRewriteStyleClicked(_:))
        )
        addButton.toolTip = t("Создать свой режим реврайта: имя, цвет, инструкция, хоткей.",
                              "Create a custom rewrite mode: name, color, instruction, hotkey.")
        header.addArrangedSubview(addButton)
        container.addArrangedSubview(header)

        if draft.customRewriteStyles.isEmpty {
            let empty = panelLabel(
                t("Своих режимов пока нет — создай режим со своей инструкцией для модели, цветом и хоткеем.",
                  "No custom modes yet — create one with its own model instruction, color and hotkey."),
                size: 11,
                color: .secondaryLabelColor
            )
            empty.preferredMaxLayoutWidth = 440
            container.addArrangedSubview(empty)
        }

        for (index, custom) in draft.customRewriteStyles.enumerated() {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8

            let swatch = NSView(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
            swatch.wantsLayer = true
            swatch.layer?.cornerRadius = 6
            swatch.layer?.backgroundColor = StateToastController.color(forColorHex: custom.colorHex).cgColor
            swatch.translatesAutoresizingMaskIntoConstraints = false
            swatch.widthAnchor.constraint(equalToConstant: 12).isActive = true
            swatch.heightAnchor.constraint(equalToConstant: 12).isActive = true
            row.addArrangedSubview(swatch)

            row.addArrangedSubview(panelLabel(custom.name, size: 12, weight: .medium))

            let hotkeyButton = panelButton(
                localizedHotkeyName(hotkeyChoice(forKeycode: CGKeyCode(custom.hotkeyKeycode),
                                                    modifiers: CGEventFlags(rawValue: custom.hotkeyModifiers)),
                                    language: language),
                action: #selector(customStyleHotkeyClicked(_:)),
                enabled: serviceOperation == nil
            )
            hotkeyButton.tag = index
            hotkeyButton.toolTip = t("Хоткей активации этого режима (0 = не назначен).",
                                     "This mode's activation hotkey (0 = none).")
            row.addArrangedSubview(hotkeyButton)

            row.addArrangedSubview(NSView())

            let editButton = panelButton(t("Изменить", "Edit"),
                                         action: #selector(editCustomRewriteStyleClicked(_:)))
            editButton.tag = index
            row.addArrangedSubview(editButton)

            let deleteButton = panelButton(t("Удалить", "Delete"),
                                           action: #selector(deleteCustomRewriteStyleClicked(_:)))
            deleteButton.tag = index
            row.addArrangedSubview(deleteButton)

            container.addArrangedSubview(row)
        }

        NSLayoutConstraint.activate(container.arrangedSubviews.map {
            $0.widthAnchor.constraint(equalTo: container.widthAnchor)
        })
        return container
    }

    /// Preset identity colors for custom rewrite modes (hex). A clickable
    /// swatch row instead of NSColorWell: the system color panel needs the
    /// app active and is unreliable in this menu-bar app's auxiliary
    /// windows.
    private static let customStylePalette: [String] = [
        "#0A84FF", // blue
        "#34C759", // green
        "#FF9F0A", // orange
        "#FF375F", // pink
        "#BF5AF2", // purple
        "#00C7BE", // teal
        "#FFD60A", // yellow
        "#FF453A", // red
        "#5E5CE6", // indigo
        "#98989D", // gray
    ]

    /// Hotkey being assigned in the custom-mode editor (nil = none).
    private var customStyleEditorHotkey: HotkeyChoice?
    /// The swatch-selected identity color of the editor (hex).
    private var customStyleEditorColor: String = "#0A84FF"
    private var customStyleSwatchButtons: [NSButton] = []
    /// The create/edit window. A STANDALONE key window presented exactly
    /// like the settings window itself (makeKeyAndOrderFront + activate) —
    /// NSAlert/beginSheetModal variants were unusable in this menu-bar
    /// app: without a real activated window the accessory fields received
    /// no keyboard or mouse input at all.
    private var customStyleEditorWindow: NSWindow?
    private var customStyleEditorExisting: CustomRewriteStyle?
    private var customStyleEditorNameField: NSTextField?
    private var customStyleEditorInstructionView: NSTextView?
    private weak var customStyleEditorHotkeyButton: NSButton?

    /// Opens the create/edit window for a custom rewrite mode: name,
    /// identity color (swatch palette), LLM instruction and activation
    /// hotkey. Save applies to the draft; persistence happens on
    /// «Сохранить и перезапустить» like every other setting.
    private func presentCustomStyleEditor(_ draft: ControlPanelSettingsDraft, existing: CustomRewriteStyle?) {
        NSApp.activate(ignoringOtherApps: true)
        customStyleEditorWindow?.orderOut(nil)
        customStyleEditorWindow = nil

        customStyleEditorExisting = existing
        customStyleEditorColor = existing?.colorHex ?? Self.customStylePalette[0]
        customStyleEditorHotkey = existing.map { custom in
            hotkeyChoice(forKeycode: CGKeyCode(custom.hotkeyKeycode),
                         modifiers: CGEventFlags(rawValue: custom.hotkeyModifiers))
        }

        let nameField = NSTextField(string: existing?.name ?? "")
        nameField.placeholderString = t("Например: Задача для ассистента", "e.g. Task for my assistant")
        nameField.translatesAutoresizingMaskIntoConstraints = false

        let instruction = NSTextView()
        instruction.isRichText = false
        instruction.font = NSFont.systemFont(ofSize: 12)
        instruction.string = existing?.instruction ?? ""
        instruction.isEditable = true
        instruction.isVerticallyResizable = true
        instruction.textContainer?.widthTracksTextView = true
        instruction.autoresizingMask = [.width]
        let instructionScroll = NSScrollView()
        instructionScroll.hasVerticalScroller = true
        instructionScroll.borderType = .bezelBorder
        instructionScroll.documentView = instruction
        instructionScroll.translatesAutoresizingMaskIntoConstraints = false

        let swatchRow = NSStackView()
        swatchRow.orientation = .horizontal
        swatchRow.spacing = 6
        var swatchButtons: [NSButton] = []
        for (index, hex) in Self.customStylePalette.enumerated() {
            let swatch = NSButton(title: "", target: nil, action: nil)
            swatch.wantsLayer = true
            swatch.layer?.backgroundColor = NSColor(hexString: hex).cgColor
            swatch.layer?.cornerRadius = 6
            swatch.isBordered = false
            swatch.title = ""
            swatch.tag = index
            swatch.translatesAutoresizingMaskIntoConstraints = false
            swatch.widthAnchor.constraint(equalToConstant: 26).isActive = true
            swatch.heightAnchor.constraint(equalToConstant: 26).isActive = true
            swatchRow.addArrangedSubview(swatch)
            swatchButtons.append(swatch)
        }
        customStyleSwatchButtons = swatchButtons
        refreshCustomStyleSwatchSelection()

        let swatchAction = SwatchAction(handler: { [weak self] index in
            guard let self, Self.customStylePalette.indices.contains(index) else { return }
            self.customStyleEditorColor = Self.customStylePalette[index]
            self.refreshCustomStyleSwatchSelection()
        })
        for swatch in swatchButtons {
            swatch.target = swatchAction
            swatch.action = #selector(SwatchAction.swatchClicked(_:))
            objc_setAssociatedObject(swatch, &SwatchAction.associationKey, swatchAction, .OBJC_ASSOCIATION_RETAIN)
        }

        let hotkeyButton = panelButton(
            localizedHotkeyName(customStyleEditorHotkey ?? hotkeyChoice(forKeycode: 0), language: language),
            action: #selector(customStyleEditorHotkeyClicked(_:))
        )
        customStyleEditorHotkeyButton = hotkeyButton

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        content.addArrangedSubview(panelLabel(t("Имя режима", "Mode name"), size: 12, weight: .medium, color: .secondaryLabelColor))
        content.addArrangedSubview(nameField)
        content.addArrangedSubview(panelLabel(t("Инструкция для модели (что делать с текстом)", "Model instruction (what to do with the text)"), size: 12, weight: .medium, color: .secondaryLabelColor))
        content.addArrangedSubview(instructionScroll)
        content.addArrangedSubview(panelLabel(t("Цвет уведомления", "Notification color"), size: 12, weight: .medium, color: .secondaryLabelColor))
        content.addArrangedSubview(swatchRow)
        content.addArrangedSubview(panelLabel(t("Хоткей активации режима", "Mode activation hotkey"), size: 12, weight: .medium, color: .secondaryLabelColor))
        content.addArrangedSubview(hotkeyButton)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        let cancelButton = panelButton(t("Отмена", "Cancel"),
                                       action: #selector(customStyleEditorCancelClicked(_:)))
        let saveButton = panelButton(t("Сохранить режим", "Save mode"),
                                     action: #selector(customStyleEditorSaveClicked(_:)))
        buttonRow.addArrangedSubview(NSView())
        buttonRow.addArrangedSubview(cancelButton)
        buttonRow.addArrangedSubview(saveButton)
        content.addArrangedSubview(buttonRow)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = existing == nil
            ? t("Новый режим реврайта", "New rewrite mode")
            : t("Изменить режим реврайта", "Edit rewrite mode")
        window.isReleasedWhenClosed = false
        window.contentView = content

        NSLayoutConstraint.activate([
            nameField.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32),
            instructionScroll.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32),
            instructionScroll.heightAnchor.constraint(equalToConstant: 88),
            swatchRow.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32),
        ])

        customStyleEditorNameField = nameField
        customStyleEditorInstructionView = instruction
        customStyleEditorWindow = window

        // Position centered over the settings window.
        if let settingsFrame = settingsWindow?.frame {
            let x = settingsFrame.midX - window.frame.width / 2
            let y = settingsFrame.midY - window.frame.height / 2
            window.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(nameField)
    }

    /// Re-renders the selection ring on the editor's color swatches.
    private func refreshCustomStyleSwatchSelection() {
        for (index, button) in customStyleSwatchButtons.enumerated() {
            let selected = Self.customStylePalette.indices.contains(index)
                && Self.customStylePalette[index] == customStyleEditorColor
            button.layer?.borderWidth = selected ? 2.5 : 0
            button.layer?.borderColor = NSColor.white.cgColor
        }
    }

    @objc private func swatchClicked(_ sender: NSButton) {
        guard Self.customStylePalette.indices.contains(sender.tag) else { return }
        customStyleEditorColor = Self.customStylePalette[sender.tag]
        refreshCustomStyleSwatchSelection()
    }

    private func closeCustomStyleEditor() {
        customStyleEditorWindow?.orderOut(nil)
        customStyleEditorWindow = nil
        customStyleEditorNameField = nil
        customStyleEditorInstructionView = nil
        customStyleEditorHotkeyButton = nil
        customStyleEditorHotkey = nil
        customStyleSwatchButtons = []
    }

    @objc private func customStyleEditorCancelClicked(_ sender: NSButton) {
        closeCustomStyleEditor()
    }

    @objc private func customStyleEditorSaveClicked(_ sender: NSButton) {
        guard let nameField = customStyleEditorNameField else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            nameField.placeholderString = t("Введите имя режима", "Enter a mode name")
            return
        }
        let instructionText = customStyleEditorInstructionView?.string ?? ""
        let colorHex = customStyleEditorColor
        let hotkey = customStyleEditorHotkey ?? hotkeyChoice(forKeycode: 0)

        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        var styles = draft.customRewriteStyles
        if let existing = customStyleEditorExisting {
            guard let index = styles.firstIndex(where: { $0.id == existing.id }) else { return }
            styles[index].name = name
            styles[index].colorHex = colorHex
            styles[index].instruction = instructionText
            styles[index].hotkeyKeycode = Int(hotkey.keycode)
            styles[index].hotkeyModifiers = hotkey.requiredModifiers.rawValue
        } else {
            styles.append(CustomRewriteStyle(
                id: "c-\(UUID().uuidString)",
                name: name,
                colorHex: colorHex,
                instruction: instructionText,
                hotkeyKeycode: Int(hotkey.keycode),
                hotkeyModifiers: hotkey.requiredModifiers.rawValue
            ))
        }
        draft.customRewriteStyles = styles
        settingsDraft = draft
        closeCustomStyleEditor()
        refreshSettingsWindow()
    }

    @objc private func addCustomRewriteStyleClicked(_ sender: NSButton) {
        let draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        presentCustomStyleEditor(draft, existing: nil)
    }

    @objc private func editCustomRewriteStyleClicked(_ sender: NSButton) {
        let draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        guard draft.customRewriteStyles.indices.contains(sender.tag) else { return }
        presentCustomStyleEditor(draft, existing: draft.customRewriteStyles[sender.tag])
    }

    @objc private func deleteCustomRewriteStyleClicked(_ sender: NSButton) {
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        guard draft.customRewriteStyles.indices.contains(sender.tag) else { return }
        let removed = draft.customRewriteStyles.remove(at: sender.tag)
        // Deleting the ACTIVE style must not strand the setting on a
        // dangling id — the resolver would silently fall back to polish.
        if draft.rewriteStyleID == removed.id {
            draft.rewriteStyleID = RewriteStyle.polish.rawValue
        }
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func customStyleHotkeyClicked(_ sender: NSButton) {
        // Per-row hotkey recording for EXISTING modes (the sheet uses
        // customStyleEditorHotkeyClicked instead).
        let draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        guard draft.customRewriteStyles.indices.contains(sender.tag) else { return }
        let index = sender.tag
        startCustomStyleHotkeyRecording(index: index) { [weak self] selected in
            guard let self, self.settingsDraft?.customRewriteStyles.indices.contains(index) == true else { return }
            self.settingsDraft?.customRewriteStyles[index].hotkeyKeycode = Int(selected.keycode)
            self.settingsDraft?.customRewriteStyles[index].hotkeyModifiers = selected.requiredModifiers.rawValue
            self.refreshSettingsWindow()
        }
    }

    @objc private func customStyleEditorHotkeyClicked(_ sender: NSButton) {
        startCustomStyleHotkeyRecording(index: -1) { [weak self] selected in
            self?.customStyleEditorHotkey = selected
            if let button = sender as? NSButton {
                button.title = localizedHotkeyName(selected, language: self?.language ?? .russian)
            }
        }
    }

    /// Starts a global hotkey recording session for a custom mode's
    /// activation key (index -1 = the editor sheet's button).
    private func startCustomStyleHotkeyRecording(index: Int,
                                                 completion: @escaping (HotkeyChoice) -> Void) {
        DistributedNotificationCenter.default().postNotificationName(
            HOTKEY_CAPTURE_BEGIN_NOTIFICATION,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        let recorder = HotkeyRecorderController(language: language,
                                                titleOverride: t("Нажмите сочетание для режима", "Press the shortcut for this mode")) { [weak self] selected in
            DistributedNotificationCenter.default().postNotificationName(
                HOTKEY_CAPTURE_END_NOTIFICATION,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            guard let self else { return }
            self.hotkeyRecorder = nil
            guard let selected else { return }
            completion(selected)
            self.refreshSettingsWindow()
        }
        hotkeyRecorder = recorder
        recorder.present(relativeTo: settingsWindow)
    }

    private static func hexString(from color: NSColor) -> String {
        let converted = color.usingColorSpace(.sRGB) ?? color
        return String(format: "#%02X%02X%02X",
                      Int(round(converted.redComponent * 255)),
                      Int(round(converted.greenComponent * 255)),
                      Int(round(converted.blueComponent * 255)))
    }

    /// Bundled rewrite model picker — the benchmark's big-model class
    /// (benchmark/REPORT.md rewrite table): YandexGPT 5 Lite is the
    /// measured winner (facts preserved, output length closest to input).
    private func rewriteModelRow(_ draft: ControlPanelSettingsDraft) -> NSView {
        popupRow(
            title: t("Модель реврайта", "Rewrite model"),
            detail: t("Большие модели из замеров: YandexGPT 5 Lite — лучший (факты 0,53, длина 0,97×). Подробности — кнопка «?».",
                      "Big models from the benchmark: YandexGPT 5 Lite — the winner (fact recall 0.53, length 0.97×). Details — the \"?\" button."),
            selectedValue: draft.rewriteBundledModel.rawValue,
            options: BundledLLMModel.rewriteModels.map { model in
                let suffix: String
                if model == .yandexGPT {
                    suffix = t(" — рекомендуется", " — recommended")
                } else if model == .lfm25 {
                    // Not benchmark-tested for rewrite — offered experimentally.
                    suffix = t(" — экспериментальная", " — experimental")
                } else {
                    suffix = ""
                }
                return ("\(model.displayName)\(suffix)", model.rawValue)
            },
            action: #selector(selectRewriteBundledModel(_:)),
            toolTip: t("Выбрать встроенную модель реврайта (замеры — кнопка «?»).",
                       "Choose the bundled rewrite model (benchmark — the \"?\" button)."),
            showsHelp: true
        )
    }

    /// Editable SYSTEM prompt for the correction pass. Pre-filled with the
    /// built-in benchmark default (or the stored override), so the user
    /// edits the standard text in place. Read-only for models with a
    /// mandatory prompt (Loqira).
    private func correctionPromptRow(_ draft: ControlPanelSettingsDraft) -> NSView {
        let model = draft.correctionModel
        let locked = !model.allowsCustomSystemPrompt
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 6

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.addArrangedSubview(panelLabel(
            t("Системный промпт коррекции", "Correction system prompt"),
            size: 13,
            weight: .semibold
        ))
        header.addArrangedSubview(NSView())
        if !locked {
            let isDefault = draft.correctionSystemPrompt == defaultCorrectionSystemPrompt(for: model)
            let reset = panelButton(
                t("Вернуть стандартный", "Reset to default"),
                action: #selector(resetCorrectionPromptClicked(_:)),
                enabled: !isDefault
            )
            reset.toolTip = t("Вернуть стандартный промпт бенчмарка для выбранной модели.",
                              "Restore the benchmark default prompt for the selected model.")
            header.addArrangedSubview(reset)
        }
        container.addArrangedSubview(header)

        let field = promptEditorField(
            text: draft.correctionSystemPrompt,
            identifier: Self.correctionSystemPromptEditorID,
            editable: !locked
        )
        container.addArrangedSubview(field)

        let note: String
        if locked {
            note = t("У этой модели обязательный системный промпт — редактирование недоступно.",
                     "This model has a mandatory system prompt — editing is disabled.")
        } else {
            note = t("Пустое поле нельзя сохранить: текст заменяет стандартный промпт бенчмарка для выбранной модели. Кнопка выше возвращает стандартный.",
                     "This text replaces the benchmark default prompt for the selected model. The button above restores the standard.")
        }
        let noteLabel = panelLabel(note, size: 11, color: .secondaryLabelColor)
        noteLabel.preferredMaxLayoutWidth = 440
        container.addArrangedSubview(noteLabel)

        NSLayoutConstraint.activate(container.arrangedSubviews.map {
            $0.widthAnchor.constraint(equalTo: container.widthAnchor)
        })
        return container
    }

    /// Editable SYSTEM prompts for the rewrite pass — one INDEPENDENT
    /// prompt per style (polish / structured task / official), each
    /// pre-filled with its built-in default. The mini style switcher picks
    /// which style's prompt is being edited; it is separate from the
    /// active-style picker above.
    private func rewritePromptRow(_ draft: ControlPanelSettingsDraft) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 6

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.addArrangedSubview(panelLabel(
            t("Системные промпты реврайта", "Rewrite system prompts"),
            size: 13,
            weight: .semibold
        ))
        header.addArrangedSubview(NSView())

        let styleSwitcher = NSPopUpButton()
        styleSwitcher.toolTip = t("Какой режим реврайта редактировать.",
                                  "Which rewrite style's prompt to edit.")
        for style in RewriteStyle.allCases {
            styleSwitcher.addItem(withTitle: localizedRewriteStyleShortName(style))
        }
        let allEditorStyles: [(id: String, name: String)] =
            RewriteStyle.allCases.map { ($0.rawValue, localizedRewriteStyleShortName($0)) }
            + draft.customRewriteStyles.map { ($0.id, $0.name) }
        for styleEntry in allEditorStyles {
            styleSwitcher.addItem(withTitle: styleEntry.name)
        }
        let editorIndex = allEditorStyles.firstIndex(where: { $0.id == rewritePromptEditorStyleID }) ?? 0
        styleSwitcher.selectItem(at: editorIndex)
        styleSwitcher.target = self
        styleSwitcher.action = #selector(selectRewritePromptStyle(_:))
        styleSwitcher.setContentHuggingPriority(.required, for: .horizontal)
        header.addArrangedSubview(styleSwitcher)

        let editingStyleID = rewritePromptEditorStyleID
        let currentText = draft.rewriteSystemPrompts[editingStyleID]
            ?? defaultRewriteSystemPrompt(forStyleID: editingStyleID, draft: draft)
        let isDefault = currentText == defaultRewriteSystemPrompt(forStyleID: editingStyleID, draft: draft)
        let reset = panelButton(
            t("Вернуть стандартный", "Reset to default"),
            action: #selector(resetRewritePromptClicked(_:)),
            enabled: !isDefault
        )
        reset.toolTip = t("Вернуть стандартный промпт бенчмарка для этого режима.",
                          "Restore the benchmark default prompt for this style.")
        header.addArrangedSubview(reset)
        container.addArrangedSubview(header)

        let field = promptEditorField(
            text: currentText,
            identifier: Self.rewriteSystemPromptEditorID,
            editable: true
        )
        container.addArrangedSubview(field)

        let noteLabel = panelLabel(
            t("У каждого режима свой промпт: переключай режимы списком выше. Суффикс «Режим: …» в сообщении пользователя не редактируется.",
              "Each style has its own prompt: switch styles with the list above. The «Режим: …» user-turn suffix is not editable."),
            size: 11,
            color: .secondaryLabelColor
        )
        noteLabel.preferredMaxLayoutWidth = 440
        container.addArrangedSubview(noteLabel)

        NSLayoutConstraint.activate(container.arrangedSubviews.map {
            $0.widthAnchor.constraint(equalTo: container.widthAnchor)
        })
        return container
    }

    /// Multi-line, word-wrapping prompt editor: NSTextView in a scroll
    /// view. (NSTextField's wrapping cell proved unreliable — the prompt
    /// rendered as one long line.) Change tracking goes through
    /// NSTextViewDelegate.textDidChange; the view's tag carries which
    /// editor fired.
    private func promptEditorField(text: String, identifier: NSUserInterfaceItemIdentifier, editable: Bool) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        let textView = NSTextView()
        textView.isRichText = false
        textView.font = NSFont.systemFont(ofSize: 12)
        textView.textColor = .labelColor
        textView.isEditable = editable
        textView.isSelectable = true
        textView.delegate = editable ? self : nil
        textView.identifier = identifier
        textView.string = text
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.heightAnchor.constraint(equalToConstant: 96).isActive = true
        return scrollView
    }

    private func localizedRewriteStyleShortName(_ style: RewriteStyle) -> String {
        switch style {
        case .polish: return t("Причесать", "Polish")
        case .structuredTask: return t("Задача", "Task")
        case .official: return t("Официальный", "Official")
        }
    }

    @objc private func selectRewritePromptStyle(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        let allIDs = RewriteStyle.allCases.map(\.rawValue)
            + (settingsDraft?.customRewriteStyles ?? []).map(\.id)
        guard allIDs.indices.contains(index) else { return }
        rewritePromptEditorStyleID = allIDs[index]
        refreshSettingsWindow()
    }

    @objc private func resetCorrectionPromptClicked(_ sender: NSButton) {
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.correctionSystemPrompt = defaultCorrectionSystemPrompt(for: draft.correctionModel)
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func resetRewritePromptClicked(_ sender: NSButton) {
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.rewriteSystemPrompts[rewritePromptEditorStyleID] = defaultRewriteSystemPrompt(forStyleID: rewritePromptEditorStyleID, draft: draft)
        settingsDraft = draft
        refreshSettingsWindow()
    }

    private func rewriteEngineBackendRow(_ draft: ControlPanelSettingsDraft) -> NSView {
        popupRow(
            title: t("Движок реврайта", "Rewrite engine"),
            detail: t("Выбранная модель реврайта работает локально. Свой сервер — любой OpenAI-совместимый эндпоинт, отдельный от коррекции.",
                      "The selected rewrite model runs locally. A custom server is any OpenAI-compatible endpoint, separate from correction."),
            selectedValue: draft.rewriteEngineBackend.rawValue,
            options: [
                (t("Встроенная (локально)", "Built-in (local)"), LLMEngineBackend.bundledLocal.rawValue),
                (t("Свой сервер", "Custom server"), LLMEngineBackend.customEndpoint.rawValue),
            ],
            action: #selector(selectRewriteEngineBackend(_:)),
            toolTip: t("Выбрать, где выполняется реврайтинг текста.", "Choose where text rewriting runs.")
        )
    }

    @objc private func toggleLLMCorrectionMode(_ sender: NSSwitch) {
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.textPostprocessingMode = sender.state == .on ? .correction : .off
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func toggleLLMUseSystemProxy(_ sender: NSSwitch) {
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.llmUseSystemProxy = sender.state == .on
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func selectLLMEngineBackend(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let backend = LLMEngineBackend(rawValue: raw) else { return }
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.llmEngineBackend = backend
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func selectCorrectionBundledModel(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let model = BundledLLMModel(rawValue: raw),
              BundledLLMModel.correctionModels.contains(model) else { return }
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.correctionModel = model
        // The prompt editor shows the EFFECTIVE prompt: with no stored
        // override, switching models re-fills the editor with the new
        // model's built-in default (a stored override keeps showing).
        if settings.correctionSystemPromptOverride.isEmpty {
            draft.correctionSystemPrompt = defaultCorrectionSystemPrompt(for: model)
        }
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func togglePunctuationRestoration(_ sender: NSSwitch) {
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.punctuationRestorationEnabled = sender.state == .on
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func selectPunctuationModel(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let model = PunctuationModel(rawValue: raw) else { return }
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.punctuationModel = model
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func startPunctuationModelDownload(_ sender: NSButton) {
        guard punctuationDownloadTask == nil else { return }
        let model = (settingsDraft ?? ControlPanelSettingsDraft(settings: settings)).punctuationModel
        punctuationDownloadModel = model
        punctuationDownloadFraction = 0
        punctuationDownloadError = nil
        refreshSettingsWindow()
        punctuationDownloadTask = Task { [weak self, model] in
            do {
                try await downloadPunctuationModelIfNeeded(model, progressHandler: { [weak self] fraction in
                    Task { @MainActor in
                        guard let self else { return }
                        self.punctuationDownloadFraction = fraction
                        // Direct view updates, as for the LLM download.
                        self.punctuationDownloadStatusLabel?.stringValue = self.t(
                            "Скачивание… \(Int(fraction * 100))%", "Downloading… \(Int(fraction * 100))%")
                        self.punctuationDownloadProgressBar?.doubleValue = fraction
                    }
                })
            } catch is CancellationError {
            } catch {
                guard let self else { return }
                self.punctuationDownloadError = self.t("Не удалось скачать модель: \(error.localizedDescription)",
                                                       "Couldn't download the model: \(error.localizedDescription)")
            }
            guard let self else { return }
            self.punctuationDownloadTask = nil
            self.punctuationDownloadFraction = nil
            self.refreshSettingsWindow()
        }
    }

    @objc private func cancelPunctuationModelDownload(_ sender: NSButton) {
        punctuationDownloadTask?.cancel()
        punctuationDownloadTask = nil
        punctuationDownloadFraction = nil
        refreshSettingsWindow()
    }

    @objc private func toggleRewriteMode(_ sender: NSSwitch) {
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.rewriteEnabled = sender.state == .on
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func selectRewriteStyle(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.rewriteStyleID = id
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func selectRewriteBundledModel(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let model = BundledLLMModel(rawValue: raw),
              BundledLLMModel.rewriteModels.contains(model) else { return }
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.rewriteBundledModel = model
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func startBundledModelDownloadClicked(_ sender: NSButton) {
        let index = sender.tag
        guard BundledLLMModel.allCases.indices.contains(index) else { return }
        startBundledModelDownload(model: BundledLLMModel.allCases[index])
    }

    private func startBundledModelDownload(model: BundledLLMModel) {
        guard llmModelDownloadTask == nil else { return }
        llmModelDownloadModel = model
        llmModelDownloadState = .downloading
        refreshSettingsWindow()
        llmModelDownloadTask = Task { [weak self, model] in
            do {
                _ = try await downloadBundledLLMModelIfNeeded(model, progress: { [weak self] received, total in
                    Task { @MainActor in
                        guard let self = self else { return }
                        self.llmModelDownloadProgress = (received, total)
                        // Direct view updates — a full window rebuild at
                        // progress frequency would reset the settings
                        // window's scroll state.
                        let fraction = total > 0 ? Double(received) / Double(total) : 0
                        self.llmDownloadStatusLabel?.stringValue = self.t(
                            "Скачивание… " + String(Int(fraction * 100)) + "% (" + formattedByteCount(UInt64(received)) + " из " + formattedByteCount(UInt64(total)) + ")",
                            "Downloading… " + String(Int(fraction * 100)) + "% (" + formattedByteCount(UInt64(received)) + " of " + formattedByteCount(UInt64(total)) + ")")
                        if let bar = self.llmDownloadProgressBar, !bar.isIndeterminate {
                            bar.doubleValue = fraction
                        }
                    }
                })
                guard let self, !Task.isCancelled else { return }
                self.llmModelDownloadState = .idle
                self.llmModelDownloadProgress = nil
            } catch is CancellationError {
            } catch {
                guard let self else { return }
                self.llmModelDownloadState = .failed(
                    self.t("Не удалось скачать модель: \(error.localizedDescription)",
                          "Couldn't download the model: \(error.localizedDescription)")
                )
            }
            guard let self else { return }
            self.llmModelDownloadTask = nil
            self.refreshSettingsWindow()
        }
    }

    @objc private func selectRewriteEngineBackend(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let backend = LLMEngineBackend(rawValue: raw) else { return }
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.rewriteEngineBackend = backend
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func cancelLLMModelDownload(_ sender: NSButton) {
        llmModelDownloadTask?.cancel()
        llmModelDownloadTask = nil
        llmModelDownloadState = .idle
        refreshSettingsWindow()
    }

    private static let enterDelayOptions: [(title: String, value: String)] = [
        ("0 ms", "0"),
        ("50 ms", "50"),
        ("80 ms", "80"),
        ("120 ms", "120"),
        ("200 ms", "200"),
        ("300 ms", "300"),
    ]

    private func enterDelayRow(_ draft: ControlPanelSettingsDraft) -> NSView {
        popupRow(
            title: t("Задержка Enter", "Enter delay"),
            detail: t("Пауза между вставкой текста и нажатием Enter.",
                      "Pause between inserting text and pressing Enter."),
            selectedValue: String(draft.enterDelayMilliseconds),
            options: Self.enterDelayOptions,
            action: #selector(selectEnterDelay(_:)),
            toolTip: t("Некоторым приложениям (Electron, VM) нужна пауза после вставки. Уменьшите для быстрых приложений.",
                       "Some apps (Electron, VMs) need a pause after paste. Lower for fast native apps.")
        )
    }

    private func microphoneSettingsRow(_ draft: ControlPanelSettingsDraft) -> NSView {
        let devices = availableAudioInputDevices()
        let preference = draft.inputDevicePreference
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedDevice = audioInputDevice(matching: preference, in: devices)
        let unavailable = !preference.isEmpty && selectedDevice == nil

        let detailText: String
        if unavailable {
            detailText = t(
                "Устройство сейчас недоступно — временно используется системный микрофон.",
                "The device is unavailable; the system microphone is used temporarily."
            )
        } else if let selectedDevice {
            detailText = t(
                "Выбран: \(selectedDevice.name). Применится после перезапуска сервиса.",
                "Selected: \(selectedDevice.name). Applies after the service restarts."
            )
        } else {
            detailText = t(
                "Следовать выбору входа в настройках macOS.",
                "Follow the input selected in macOS settings."
            )
        }

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.addArrangedSubview(panelLabel(t("Микрофон", "Microphone"),
                                           size: 13,
                                           weight: .semibold))
        let detail = panelLabel(detailText, size: 12, color: .secondaryLabelColor)
        detail.maximumNumberOfLines = 2
        detail.lineBreakMode = .byWordWrapping
        text.addArrangedSubview(detail)

        let popup = NSPopUpButton()
        popup.target = self
        popup.action = #selector(selectInputDeviceDraft(_:))
        popup.toolTip = t(
            "Выберите микрофон для диктовки. Отключённое устройство автоматически заменяется системным до его возвращения.",
            "Choose the dictation microphone. A disconnected device falls back to the system input until it returns."
        )
        popup.addItem(withTitle: t("Системный по умолчанию", "System default"))
        popup.lastItem?.representedObject = ""

        if unavailable {
            popup.addItem(withTitle: t("Недоступен: \(preference)", "Unavailable: \(preference)"))
            popup.lastItem?.representedObject = preference
            popup.lastItem?.isEnabled = false
        }
        if !devices.isEmpty {
            popup.menu?.addItem(.separator())
        }
        for device in devices {
            popup.addItem(withTitle: device.name)
            popup.lastItem?.representedObject = device.uid
            popup.lastItem?.toolTip = device.uid
        }

        let selectedValue = selectedDevice?.uid ?? (unavailable ? preference : "")
        if let item = popup.itemArray.first(where: {
            ($0.representedObject as? String) == selectedValue
        }) {
            popup.select(item)
        }
        popup.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(popup)
        return row
    }

    private func popupRow(title: String,
                          detail: String,
                          selectedValue: String,
                          options: [(title: String, value: String)],
                          action: Selector,
                          toolTip: String? = nil,
                          showsHelp: Bool = false) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.addArrangedSubview(panelLabel(title, size: 13, weight: .semibold))
        let detailLabel = panelLabel(detail, size: 12, color: .secondaryLabelColor)
        detailLabel.preferredMaxLayoutWidth = 440
        text.addArrangedSubview(detailLabel)

        let popup = NSPopUpButton()
        popup.target = self
        popup.action = action
        popup.toolTip = toolTip
        for option in options {
            popup.addItem(withTitle: option.title)
            popup.lastItem?.representedObject = option.value
        }
        if let item = popup.itemArray.first(where: { $0.representedObject as? String == selectedValue }) {
            popup.select(item)
        }
        popup.setContentHuggingPriority(.required, for: .horizontal)
        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(popup)
        if showsHelp {
            row.addArrangedSubview(benchmarkHelpButton())
        }
        return row
    }

    /// Small round "?" button appended to model-picker rows; opens the
    /// benchmark summary (benchmarkHelpSummaryText) so the user can see
    /// what the measured differences between the bundled models actually
    /// are without opening the repository.
    private func benchmarkHelpButton() -> NSButton {
        let button = NSButton(title: "?", target: self, action: #selector(showBenchmarkHelp(_:)))
        button.bezelStyle = .circular
        button.controlSize = .small
        button.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        button.toolTip = t("Результаты замеров моделей (бенчмарк).",
                           "Model benchmark results.")
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    @objc private func showBenchmarkHelp(_ sender: NSButton) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = t("Замеры моделей (бенчмарк, 21.08.2026)",
                              "Model benchmark (Aug 21, 2026)")
        alert.informativeText = benchmarkHelpSummaryText()
        alert.addButton(withTitle: t("Понятно", "Got it"))
        _ = alert.runModal()
    }

    /// Brief benchmark digest shown by the "?" help buttons next to the
    /// model pickers — numbers from benchmark/REPORT.md (this machine,
    /// AMD Radeon RX 6600, llama.cpp/Vulkan, temperature 0).
    private func benchmarkHelpSummaryText() -> String {
        t("""
        Замеры на этом Mac (AMD Radeon RX 6600, llama.cpp/Vulkan, 21 августа 2026 г.). Полный отчёт с методикой — benchmark/REPORT.md в репозитории.

        КОРРЕКЦИЯ (маленькие модели; EM — доля идеально исправленных фраз)
        • VoiceScribe V15 R-3 — EM 0,60, 0,19 с на фразу, 0,7 ГБ. Рекомендуется: мгновенная реакция для повседневной диктовки.
        • Qwen3.5-4B Q6_K — EM 0,72 (лучшая из малых), 0,55 с, 3,8 ГБ.
        • RuAdapt Qwen3-4B Q6_K — EM 0,68, 0,38 с, 3,3 ГБ.
        • QVikhr-3-4B Q6_K — EM 0,60, 0,48 с, 3,3 ГБ.
        • Ministral-3-3B Q6_K — EM 0,59, 0,38 с, 2,8 ГБ.
        • Phi-4-mini Q6_K — EM 0,54, 0,34 с, 3,2 ГБ.

        РЕВРАЙТ (большие модели; FactRec — сохранение фактов, длина — отношение к исходнику)
        • YandexGPT 5 Lite 8B Q4_K_M — FactRec 0,53, длина 0,97×, ~2,7 с, 4,9 ГБ. Рекомендуется.
        • Qwen3-8B Q4_K_M — FactRec 0,49, длина 1,26×, ~3,3 с, 5,0 ГБ.
        • Qwen3.5-9B Q4_K_M — FactRec 0,49, длина 1,19×, ~3,2 с, 5,7 ГБ.
        • Gemma 4 E4B Q4_0 — FactRec 0,48, длина 1,44×, ~2,3 с, 5,2 ГБ.
        • LFM2.5-2.6B Q6_K — экспериментальная: на рерайт не замерялась; в замере коррекции думание было включено (10,8 с), в приложении оно принудительно выключено. 2,2 ГБ.

        СОВМЕСТНАЯ РАБОТА
        Коррекция и реврайт независимы: при включении обеих текст сначала исправляется, затем переписывается. Каждая выбранная модель скачивается и хранится отдельно.
        """,
        """
        Measured on this Mac (AMD Radeon RX 6600, llama.cpp/Vulkan, Aug 21, 2026). Full report with methodology — benchmark/REPORT.md in the repository.

        CORRECTION (small models; EM — share of perfectly corrected phrases)
        • VoiceScribe V15 R-3 — EM 0.60, 0.19 s per phrase, 0.7 GB. Recommended: instant response for everyday dictation.
        • Qwen3.5-4B Q6_K — EM 0.72 (best of the small ones), 0.55 s, 3.8 GB.
        • RuAdapt Qwen3-4B Q6_K — EM 0.68, 0.38 s, 3.3 GB.
        • QVikhr-3-4B Q6_K — EM 0.60, 0.48 s, 3.3 GB.
        • Ministral-3-3B Q6_K — EM 0.59, 0.38 s, 2.8 GB.
        • Phi-4-mini Q6_K — EM 0.54, 0.34 s, 3.2 GB.

        REWRITE (big models; FactRec — fact preservation, length — output vs input ratio)
        • YandexGPT 5 Lite 8B Q4_K_M — FactRec 0.53, length 0.97×, ~2.7 s, 4.9 GB. Recommended.
        • Qwen3-8B Q4_K_M — FactRec 0.49, length 1.26×, ~3.3 s, 5.0 GB.
        • Qwen3.5-9B Q4_K_M — FactRec 0.49, length 1.19×, ~3.2 s, 5.7 GB.
        • Gemma 4 E4B Q4_0 — FactRec 0.48, length 1.44×, ~2.3 s, 5.2 GB.
        • LFM2.5-2.6B Q6_K — experimental: never benchmarked for rewrite; its correction benchmark ran with thinking ON (10.8 s), which the app forces off. 2.2 GB.

        WORKING TOGETHER
        Correction and rewrite are independent: with both enabled, text is corrected first, then rewritten. Each selected model downloads and stores separately.
        """)
    }

    /// Whether saving `draft` requires the background-service restart.
    /// Most settings are read LIVE by the agent on every dictation
    /// (models, prompts, styles, custom modes, endpoints, text
    /// post-processing) — restarting for those would just interrupt the
    /// user for nothing. Restart is needed only for what the agent reads
    /// ONCE at launch (hotkeys, HUD appearance) or configures at audio
    /// capture time (device, auto-stop, mute).
    private func settingsRestartRequired(_ draft: ControlPanelSettingsDraft) -> Bool {
        let persisted = ControlPanelSettingsDraft(settings: settings)
        return draft.speechModelProfile != persisted.speechModelProfile
            || draft.dictationHotkey != persisted.dictationHotkey
            || draft.alternateCompletionHotkey != persisted.alternateCompletionHotkey
            || draft.historyHotkey != persisted.historyHotkey
            || draft.correctionHotkey != persisted.correctionHotkey
            || draft.rewriteToggleHotkey != persisted.rewriteToggleHotkey
            || draft.rewriteStyleHotkey != persisted.rewriteStyleHotkey
            || draft.customRewriteStyles != persisted.customRewriteStyles
            || draft.inputDevicePreference != persisted.inputDevicePreference
            || draft.muteWhileRecording != persisted.muteWhileRecording
            || draft.autoStopOnSilenceEnabled != persisted.autoStopOnSilenceEnabled
            || draft.autoStopSilenceSeconds != persisted.autoStopSilenceSeconds
            || draft.recordingColor != persisted.recordingColor
            || draft.transcribingColor != persisted.transcribingColor
            || draft.correctingColor != persisted.correctingColor
            || draft.backgroundStyle != persisted.backgroundStyle
            || draft.hudSize != persisted.hudSize
            || draft.hudDisplayMode != persisted.hudDisplayMode
    }

    private func speechModelRow(_ draft: ControlPanelSettingsDraft) -> NSView {
        popupRow(
            title: t("Движок распознавания", "Speech engine"),
            detail: t("ONNX Runtime, только CPU. Parakeet Ultra — многоязычная; GigaAM v3 — только русский, точнее на русском. Видеокарта используется лишь для LLM-коррекции и рерайта.",
                       "ONNX Runtime, CPU only. Parakeet Ultra is multilingual; GigaAM v3 is Russian-only and more accurate in Russian. The GPU is used only for LLM correction and rewrite."),
            selectedValue: draft.speechModelProfile.rawValue,
            options: SpeechModelProfile.allCases.map { ($0.displayName, $0.rawValue) },
            action: #selector(selectSpeechModelProfile(_:)),
            toolTip: t("Выбор модели для следующей загрузки службы.",
                       "Select the model used at the next service startup.")
        )
    }

    private func settingsActionsRow(draft: ControlPanelSettingsDraft) -> NSView {
        let persisted = ControlPanelSettingsDraft(settings: settings)
        let hasChanges = draft != persisted
        let validation = settingsValidationMessage(draft)
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let message = panelLabel(
            validation ?? (hasChanges
                ? t("Есть несохранённые изменения", "You have unsaved changes")
                : t("Все изменения сохранены", "All changes are saved")),
            size: 11.5,
            weight: .medium,
            color: validation == nil ? .secondaryLabelColor : .systemRed
        )
        message.toolTip = validation
        row.addArrangedSubview(message)
        row.addArrangedSubview(NSView())

        let discard = panelButton(
            t("Отменить", "Discard"),
            action: #selector(discardSettingsClicked(_:)),
            enabled: hasChanges && serviceOperation == nil,
            toolTip: t("Отменить несохранённые изменения.", "Discard unsaved changes.")
        )
        row.addArrangedSubview(discard)
        let restartRequired = settingsRestartRequired(draft)
        let save = panelButton(
            restartRequired
                ? t("Сохранить и перезапустить", "Save & Restart")
                : t("Сохранить", "Save"),
            action: #selector(saveSettingsClicked(_:)),
            enabled: hasChanges && validation == nil && serviceOperation == nil,
            toolTip: restartRequired
                ? t("Сохранить настройки и перезапустить фоновую службу.",
                    "Save settings and restart the background service.")
                : t("Сохранить настройки — перезапуск не требуется.",
                    "Save settings — no restart needed.")
        )
        save.keyEquivalent = "\r"
        row.addArrangedSubview(save)
        settingsStatusLabel = message
        settingsDiscardButton = discard
        settingsSaveButton = save
        return row
    }

    /// Updates just the Save/Discard buttons and the status label after an
    /// in-place draft change (checkbox toggles), without rebuilding the
    /// whole content view -- a rebuild mid-edit is what used to eat
    /// checklist clicks and go stale the other way.
    private func updateSettingsSaveState() {
        guard let save = settingsSaveButton,
              let discard = settingsDiscardButton,
              let message = settingsStatusLabel else { return }
        let draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        let hasChanges = draft != ControlPanelSettingsDraft(settings: settings)
        let validation = settingsValidationMessage(draft)
        save.isEnabled = hasChanges && validation == nil && serviceOperation == nil
        discard.isEnabled = hasChanges && serviceOperation == nil
        message.stringValue = validation ?? (hasChanges
            ? t("Есть несохранённые изменения", "You have unsaved changes")
            : t("Все изменения сохранены", "All changes are saved"))
        message.textColor = validation == nil ? .secondaryLabelColor : .systemRed
        message.toolTip = validation
    }

    private func settingsValidationMessage(_ draft: ControlPanelSettingsDraft) -> String? {
        // The dictation/finish pair is intentionally allowed to share a
        // modifier prefix. For example, the primary shortcut can be bare
        // Right Command while the finish shortcut is Command + Control,
        // Option, or Fn: the extra modifier is pressed while recording is
        // already active, so this is not an ambiguous prefix in the
        // transition state machine. History still keeps the stricter
        // prefix-conflict rule.
        let shortcutPairs: [(HotkeyChoice, HotkeyChoice, Bool)] = {
            var pairs: [(HotkeyChoice, HotkeyChoice, Bool)] = [
                (draft.dictationHotkey, draft.historyHotkey, true),
                (draft.dictationHotkey, draft.correctionHotkey, true),
                (draft.correctionHotkey, draft.historyHotkey, true),
            ]
            if draft.alternateCompletionEnabled {
                pairs.append((draft.dictationHotkey, draft.alternateCompletionHotkey, false))
                pairs.append((draft.alternateCompletionHotkey, draft.historyHotkey, true))
                pairs.append((draft.correctionHotkey, draft.alternateCompletionHotkey, true))
            }
            return pairs
        }()

        for (first, second, allowModifierPrefix) in shortcutPairs {
                if hotkeysConflict(first, second) {
                    return t("Сочетания для диктовки, завершения, истории и коррекции должны отличаться.",
                             "Dictation, finish, history, and correction shortcuts must be different.")
                }
                if allowModifierPrefix == false,
                   (hotkeyIsModifierPrefix(first, of: second)
                    || hotkeyIsModifierPrefix(second, of: first)) {
                    return t("Одна активная комбинация не должна быть частью другой.",
                             "One active shortcut cannot be a prefix of another.")
                }
        }
        return nil
    }

    private func privacyInfoView() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        let icon = NSImageView(image: NSImage(systemSymbolName: "lock.shield.fill",
                                              accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        row.addArrangedSubview(icon)
        let label = panelLabel(
            t("Аудио и распознавание остаются на Mac. Интернет нужен только для первой загрузки модели и обновлений.",
              "Audio and transcription stay on this Mac. Internet is only used for the first model download and updates."),
            size: 11.5,
            color: .secondaryLabelColor
        )
        label.preferredMaxLayoutWidth = 600
        row.addArrangedSubview(label)
        return row
    }

    private func panelLabel(_ text: String,
                            size: CGFloat,
                            weight: NSFont.Weight = .regular,
                            color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }

    private func panelButton(_ title: String,
                             action: Selector,
                             enabled: Bool = true,
                             toolTip: String? = nil) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.isEnabled = enabled
        button.toolTip = toolTip
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private func compactIconButton(symbol: String,
                                   accessibilityTitle: String,
                                   toolTip: String,
                                   action: Selector,
                                   enabled: Bool = true) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol,
                                             accessibilityDescription: accessibilityTitle) ?? NSImage(),
                              target: self,
                              action: action)
        button.bezelStyle = .texturedRounded
        button.controlSize = .small
        button.isEnabled = enabled
        button.toolTip = toolTip
        button.setAccessibilityLabel(accessibilityTitle)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 30),
            button.heightAnchor.constraint(equalToConstant: 26),
        ])
        return button
    }

    private func compactCard() -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.70).cgColor
        card.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.42).cgColor
        card.layer?.borderWidth = 1
        card.setContentHuggingPriority(.required, for: .vertical)
        card.setContentCompressionResistancePriority(.required, for: .vertical)
        return card
    }

    private func panelSymbol(_ name: String,
                             color: NSColor,
                             description: String?,
                             pointSize: CGFloat) -> NSImageView {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description) ?? NSImage()
        let view = NSImageView(image: image)
        view.contentTintColor = color
        view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }

    private func pin(_ view: NSView,
                     inside container: NSView,
                     horizontal: CGFloat,
                     vertical: CGFloat) {
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: horizontal),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -horizontal),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: vertical),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -vertical),
        ])
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func triggerModeText() -> String {
        switch settings.triggerMode {
        case .hold: return t("Удерживать", "Press and hold")
        case .toggle: return t("Нажать для старта и ещё раз для остановки", "Press to start, press again to stop")
        }
    }

    private func localizedCompletionBehavior(_ behavior: DictationCompletionBehavior) -> String {
        switch behavior {
        case .insert:
            return t("Вставить", "Insert")
        case .insertAndEnter:
            return t("Вставить + Enter", "Insert + Enter")
        }
    }

    private func displayStatus(_ raw: String) -> String {
        switch raw {
        case "ready": return t("Работает", "Running")
        case "recording", "transcribing": return t("Работает", "Running")
        case "starting": return t("Запускается", "Starting")
        case "needs_permissions": return t("Нужен доступ", "Needs Access")
        case "error": return t("Ошибка", "Error")
        case "stopping": return t("Останавливается", "Stopping")
        case "stopped": return t("Остановлена", "Stopped")
        default: return raw.capitalized
        }
    }

    private func localizedServiceDetail(_ state: AgentRuntimeState) -> String {
        switch state.status {
        case "ready", "recording", "transcribing":
            return t("Фоновая служба готова к диктовке.",
                     "The background service is ready for dictation.")
        case "starting":
            if state.detail.hasPrefix("Downloading speech model") {
                if let percentRange = state.detail.range(of: "\\d+%", options: .regularExpression) {
                    let percent = state.detail[percentRange]
                    return t("Скачиваю языковую модель… \(percent)", "Downloading speech model… \(percent)")
                }
                return t("Скачиваю языковую модель…", "Downloading speech model…")
            } else if state.detail.hasPrefix("Checking speech model") {
                return t("Проверяю список файлов модели…", "Checking speech model files…")
            } else if state.detail.hasPrefix("Preparing speech model") {
                return t("Подготавливаю модель…", "Preparing speech model…")
            } else if state.detail.hasPrefix("Loading cached speech model") {
                return t("Загружаю модель из кэша…", "Loading cached speech model…")
            } else if state.detail.hasPrefix("Loading speech model") {
                return t("Загружаю языковую модель…", "Loading speech model…")
            }
            return t("Запускаю службу диктовки…", "Starting dictation service…")
        case "needs_permissions": return t("Выдайте недостающие разрешения ниже.", "Grant the missing permissions below.")
        case "stopped": return t("Фоновая служба остановлена.", "The background service is stopped.")
        case "error": return t("Служба сообщила об ошибке: \(state.detail)", "Service error: \(state.detail)")
        default: return state.detail
        }
    }

    private func colorForStatus(_ raw: String) -> NSColor {
        switch raw {
        case "ready", "recording", "transcribing": return .systemGreen
        case "starting", "needs_permissions", "stopping": return .systemOrange
        case "error", "stopped": return .systemRed
        default: return .secondaryLabelColor
        }
    }

    private func permissionTitle(_ permission: Permission) -> String {
        switch permission {
        case .microphone: return t("Микрофон", "Microphone")
        case .accessibility: return t("Универсальный доступ", "Accessibility")
        case .inputMonitoring: return t("Мониторинг ввода", "Input Monitoring")
        }
    }

    private func permissionDetail(_ permission: Permission) -> String {
        switch permission {
        case .microphone:
            return t("Запись голоса только во время активной диктовки.",
                     "Lets the service hear your voice while dictation is active.")
        case .accessibility:
            return t("Поиск активного поля и вставка готового текста.",
                     "Lets the service find the active field and insert text.")
        case .inputMonitoring:
            return t("Глобальное распознавание выбранного сочетания клавиш.",
                     "Lets the service detect your shortcut globally.")
        }
    }

    private func localizedColorName(_ color: RecordingHUDAccentColor) -> String {
        guard language == .russian else { return color.displayName }
        switch color {
        case .red: return "Красный"
        case .orange: return "Оранжевый"
        case .pink: return "Розовый"
        case .purple: return "Фиолетовый"
        case .blue: return "Синий"
        case .cyan: return "Голубой"
        case .green: return "Зелёный"
        case .white: return "Белый"
        case .contrast: return "Контрастный"
        }
    }

    private func localizedBackgroundName(_ style: RecordingHUDBackgroundStyle) -> String {
        guard language == .russian else { return style.displayName }
        switch style {
        case .system: return "Как в системе"
        case .dark: return "Тёмный"
        case .light: return "Светлый"
        }
    }

    private func localizedHUDSizeName(_ size: RecordingHUDSize) -> String {
        guard language == .russian else { return size.displayName }
        switch size {
        case .compact: return "Компактная"
        case .standard: return "Обычная"
        case .large: return "Крупная"
        }
    }

    private func localizedDisplayModeName(_ mode: RecordingHUDDisplayMode) -> String {
        guard language == .russian else { return mode.displayName }
        switch mode {
        case .levelBars: return "Полоски уровня"
        case .timerOutline: return "Таймер"
        }
    }

    private func beginServiceOperation(_ operation: ControlPanelServiceOperation) {
        guard serviceOperation == nil else { return }
        serviceOperation = operation
        lastRenderFingerprint = ""
        refresh(force: true)
        let operationStartedAt = Date().timeIntervalSince1970

        Task { [weak self] in
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    switch operation {
                    case .starting:
                        try SuperDictateAgentService.installAndStart()
                    case .restarting, .applyingSettings:
                        try SuperDictateAgentService.restart()
                    case .stopping:
                        SuperDictateAgentService.stop()
                    }
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value

            guard let self else { return }
            if failure == nil {
                await self.waitForServiceResult(operation: operation, startedAt: operationStartedAt)
            }
            self.serviceOperation = nil
            self.lastRenderFingerprint = ""
            self.refresh(force: true)
            if let failure {
                self.showError(
                    title: self.t("Не удалось изменить состояние службы", "Service operation failed"),
                    detail: failure
                )
            }
        }
    }

    private func waitForServiceResult(operation: ControlPanelServiceOperation,
                                      startedAt: TimeInterval) async {
        for _ in 0..<80 {
            let state = AgentRuntimeStateStore.read()
            if operation == .stopping {
                if state?.status == "stopped" { return }
            } else if let state,
                      state.updatedAt >= startedAt,
                      ["ready", "error", "needs_permissions"].contains(state.status) {
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    @objc private func updateButtonClicked(_ sender: NSButton) {
        switch updateState {
        case .available(let release):
            beginInAppUpdate(for: release)
        case .checking, .preparing:
            return
        case .upToDate, .failed:
            checkForUpdates()
        }
    }

    @objc private func startAgentClicked(_ sender: NSButton) {
        settings.agentEnabled = true
        _ = settings.refreshFromDisk()
        beginServiceOperation(.starting)
    }

    @objc private func restartAgentClicked(_ sender: NSButton) {
        settings.agentEnabled = true
        _ = settings.refreshFromDisk()
        beginServiceOperation(.restarting)
    }

    @objc private func stopAgentClicked(_ sender: NSButton) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = t("Остановить службу диктовки?", "Stop Dictation Service?")
        alert.informativeText = t("Хоткей перестанет работать, но история, модель и настройки сохранятся.",
                                  "The shortcut will stop, but history, model, and settings remain saved.")
        alert.addButton(withTitle: t("Оставить включённой", "Keep Running"))
        alert.addButton(withTitle: t("Остановить", "Stop Service"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        settings.agentEnabled = false
        _ = settings.refreshFromDisk()
        beginServiceOperation(.stopping)
    }

    @objc private func openSettingsClicked(_ sender: NSButton) {
        if let settingsWindow {
            settingsWindow.contentView = makeTabbedSettingsContentView()
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        settingsDraft = ControlPanelSettingsDraft(settings: settings)

        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = settingsWindowTitle()
        settingsWindow.contentMinSize = NSSize(width: 680, height: 560)
        settingsWindow.contentMaxSize = NSSize(width: 680, height: 560)
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.delegate = self
        settingsWindow.contentView = makeTabbedSettingsContentView()
        if let mainWindow = window, let visibleFrame = mainWindow.screen?.visibleFrame {
            let mainFrame = mainWindow.frame
            let preferredRight = mainFrame.maxX + 14
            let preferredLeft = mainFrame.minX - settingsWindow.frame.width - 14
            let x = preferredRight + settingsWindow.frame.width <= visibleFrame.maxX
                ? preferredRight
                : max(visibleFrame.minX, preferredLeft)
            let y = min(max(visibleFrame.minY,
                            mainFrame.maxY - settingsWindow.frame.height),
                        visibleFrame.maxY - settingsWindow.frame.height)
            settingsWindow.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            settingsWindow.center()
        }
        self.settingsWindow = settingsWindow
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func recordDictationShortcutClicked(_ sender: NSButton) {
        guard serviceOperation == nil,
              let kind = ControlPanelShortcutKind(rawValue: sender.tag) else { return }
        if let hotkeyRecorder {
            hotkeyRecorder.present(relativeTo: settingsWindow)
            return
        }
        let state = AgentRuntimeStateStore.read()
        if state?.isRecording == true || state?.isTranscribing == true {
            showError(
                title: t("Сначала завершите диктовку", "Finish Dictation First"),
                detail: t("Сочетание нельзя менять во время записи или распознавания.",
                          "Shortcuts cannot be changed while recording or transcribing.")
            )
            return
        }
        if SuperDictateAgentService.isAgentRunning(), state?.isReady != true {
            showError(
                title: t("Служба ещё запускается", "Service Is Still Starting"),
                detail: t("Дождитесь статуса «Работает» и попробуйте изменить сочетание ещё раз.",
                          "Wait for the Running status, then try changing the shortcut again.")
            )
            return
        }

        DistributedNotificationCenter.default().postNotificationName(
            HOTKEY_CAPTURE_BEGIN_NOTIFICATION,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        let recorderTitle: String
        switch kind {
        case .dictation:
            recorderTitle = t("Новое сочетание для диктовки", "New Dictation Shortcut")
        case .alternateCompletion:
            recorderTitle = t("Дополнительное сочетание завершения", "Alternative Finish Shortcut")
        case .history:
            recorderTitle = t("Новое сочетание для истории", "New History Shortcut")
        case .correction:
            recorderTitle = t("Новое сочетание для коррекции", "New Correction Shortcut")
        case .rewriteToggle:
            recorderTitle = t("Новое сочетание для рерайта", "New Rewrite Shortcut")
        case .rewriteStyle:
            recorderTitle = t("Новое сочетание режима рерайта", "New Rewrite Style Shortcut")
        }
        let recorder = HotkeyRecorderController(language: language,
                                                titleOverride: recorderTitle) { [weak self] selected in
            DistributedNotificationCenter.default().postNotificationName(
                HOTKEY_CAPTURE_END_NOTIFICATION,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            guard let self else { return }
            self.hotkeyRecorder = nil
            guard let selected else { return }
            var draft = self.settingsDraft ?? ControlPanelSettingsDraft(settings: self.settings)
            switch kind {
            case .dictation: draft.dictationHotkey = selected
            case .alternateCompletion: draft.alternateCompletionHotkey = selected
            case .history: draft.historyHotkey = selected
            case .correction: draft.correctionHotkey = selected
            case .rewriteToggle: draft.rewriteToggleHotkey = selected
            case .rewriteStyle: draft.rewriteStyleHotkey = selected
            }
            self.settingsDraft = draft
            self.refreshSettingsWindow()
        }
        hotkeyRecorder = recorder
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self, weak recorder] in
            guard self?.hotkeyRecorder === recorder else { return }
            recorder?.present(relativeTo: self?.settingsWindow)
        }
    }

    @objc private func selectInterfaceLanguage(_ sender: NSSegmentedControl) {
        settings.interfaceLanguage = sender.selectedSegment == 1 ? .english : .russian
        _ = settings.refreshFromDisk()
        lastRenderFingerprint = ""
        refresh(force: true)
    }

    @objc private func selectPrimaryCompletionBehavior(_ sender: NSSegmentedControl) {
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.primaryCompletionBehavior = sender.selectedSegment == 1 ? .insertAndEnter : .insert
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func toggleAlternateCompletion(_ sender: NSSwitch) {
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.alternateCompletionEnabled = sender.state == .on
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func toggleNormalizeNumbers(_ sender: NSSwitch) {
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.normalizeNumbersToDigits = sender.state == .on
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func toggleRemoveFillerWordsSetting(_ sender: NSSwitch) {
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.removeFillerWords = sender.state == .on
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func toggleRemoveFinalPeriodSetting(_ sender: NSSwitch) {
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.removeFinalPeriod = sender.state == .on
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func toggleFillerPreset(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        if sender.state == .on {
            draft.enabledFillerPresetKeys.insert(key)
        } else {
            draft.enabledFillerPresetKeys.remove(key)
        }
        settingsDraft = draft
        // No refreshSettingsWindow() here: the checkbox the user just
        // clicked already shows the right state, and rebuilding the whole
        // content view would bounce the scroll position back to the top
        // of the checklist on every tick. But the Save button must still
        // learn about the change -- update it in place.
        updateSettingsSaveState()
    }

    @objc private func toggleCustomFillerWord(_ sender: NSButton) {
        guard let word = sender.identifier?.rawValue else { return }
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        if sender.state == .on {
            draft.disabledCustomFillerWords.remove(word)
        } else {
            draft.disabledCustomFillerWords.insert(word)
        }
        settingsDraft = draft
        // See toggleFillerPreset for why this skips a full rebuild.
        updateSettingsSaveState()
    }

    @objc private func addCustomFillerWord(_ sender: NSTextField) {
        // Normalize the same way the Windows port does: collapse internal
        // whitespace and lowercase (matching is case-insensitive anyway).
        let word = sender.stringValue
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
        guard !word.isEmpty else { return }
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        // A word typed in is a word wanted: if it already names a preset,
        // tick that preset; if it is already a custom word, re-tick it;
        // only genuinely new words extend the list.
        if let preset = FillerWordRemover.presets.first(where: { $0.displayText.lowercased() == word }) {
            draft.enabledFillerPresetKeys.insert(preset.key)
        } else if let existing = draft.customFillerWords.first(where: { $0.lowercased() == word }) {
            draft.disabledCustomFillerWords.remove(existing)
        } else {
            draft.customFillerWords.append(word)
        }
        settingsDraft = draft
        sender.stringValue = ""
        refreshSettingsWindow()
    }

    @objc private func removeCustomFillerWord(_ sender: NSButton) {
        guard let word = sender.identifier?.rawValue else { return }
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.customFillerWords.removeAll { $0 == word }
        draft.disabledCustomFillerWords.remove(word)
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func toggleAutoStopOnSilence(_ sender: NSSwitch) {
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.autoStopOnSilenceEnabled = sender.state == .on
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func selectAutoStopSilenceSeconds(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let seconds = Int(raw) else { return }
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.autoStopSilenceSeconds = seconds
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func toggleMuteWhileRecordingSetting(_ sender: NSSwitch) {
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.muteWhileRecording = sender.state == .on
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func toggleAutoLearnVocabularySetting(_ sender: NSSwitch) {
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.autoLearnVocabularyEnabled = sender.state == .on
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func toggleLaunchAtLoginSetting(_ sender: NSSwitch) {
        do {
            switch SMAppService.mainApp.status {
            case .enabled, .requiresApproval:
                try SMAppService.mainApp.unregister()
                log("launch at login disabled (settings window)")
            default:
                try SMAppService.mainApp.register()
                log("launch at login enabled (settings window)")
            }
        } catch {
            showError(title: t("Не удалось изменить запуск при входе", "Couldn't change Launch at Login"),
                      detail: "\(error)")
        }
        refreshSettingsWindow()
    }

    @objc private func selectRecordingHUDRecordingColor(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let color = RecordingHUDAccentColor(rawValue: raw) else { return }
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.recordingColor = color
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func selectRecordingHUDTranscribingColor(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let color = RecordingHUDAccentColor(rawValue: raw) else { return }
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.transcribingColor = color
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func selectRecordingHUDCorrectingColor(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let color = RecordingHUDAccentColor(rawValue: raw) else { return }
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.correctingColor = color
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func selectRecordingHUDBackgroundStyle(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let style = RecordingHUDBackgroundStyle(rawValue: raw) else { return }
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.backgroundStyle = style
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func selectEnterDelay(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let ms = Int(raw) else { return }
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.enterDelayMilliseconds = ms
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func selectInputDeviceDraft(_ sender: NSPopUpButton) {
        guard let preference = sender.selectedItem?.representedObject as? String else { return }
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.inputDevicePreference = preference
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func selectSpeechModelProfile(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let profile = SpeechModelProfile(rawValue: raw) else { return }
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.speechModelProfile = profile
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func selectRecordingHUDSize(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let size = RecordingHUDSize(rawValue: raw) else { return }
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.hudSize = size
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func selectRecordingHUDDisplayMode(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let mode = RecordingHUDDisplayMode(rawValue: raw) else { return }
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.hudDisplayMode = mode
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func discardSettingsClicked(_ sender: NSButton) {
        settingsDraft = ControlPanelSettingsDraft(settings: settings)
        refreshSettingsWindow()
    }

    /// Live-updates the draft as the user types in the custom-endpoint
    /// fields (llmCustomEndpointRows). Deliberately does NOT call
    /// `refreshSettingsWindow()` -- that rebuilds the whole tab content
    /// view and would drop keyboard focus on every keystroke. Only the
    /// Save/Discard button state needs to react live, and
    /// `updateSettingsSaveState()` already does that without a rebuild.
    /// Prompt editors are NSTextViews (see promptEditorField) — their
    /// edits arrive here, NOT through controlTextDidChange. Updates the
    /// draft WITHOUT rebuilding the window (a rebuild would reset the
    /// caret mid-typing).
    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        switch textView.identifier {
        case Self.correctionSystemPromptEditorID:
            draft.correctionSystemPrompt = textView.string
        case Self.rewriteSystemPromptEditorID:
            draft.rewriteSystemPrompts[rewritePromptEditorStyleID] = textView.string
        default:
            return
        }
        settingsDraft = draft
        updateSettingsSaveState()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        switch field.tag {
        case Self.llmCustomBaseURLFieldTag:
            draft.llmCustomBaseURL = field.stringValue
        case Self.llmCustomAPIKeyFieldTag:
            draft.llmCustomAPIKey = field.stringValue
        case Self.llmCustomModelNameFieldTag:
            draft.llmCustomModelName = field.stringValue
        case Self.rewriteCustomBaseURLFieldTag:
            draft.rewriteCustomBaseURL = field.stringValue
        case Self.rewriteCustomAPIKeyFieldTag:
            draft.rewriteCustomAPIKey = field.stringValue
        case Self.rewriteCustomModelNameFieldTag:
            draft.rewriteCustomModelName = field.stringValue
        default:
            return
        }
        settingsDraft = draft
        updateSettingsSaveState()
    }

    @objc private func saveSettingsClicked(_ sender: NSButton) {
        guard let draft = settingsDraft,
              settingsValidationMessage(draft) == nil else { return }
        // Decided against the PERSISTED values, so before anything is
        // written: afterwards the draft always equals the settings.
        let restartRequired = settingsRestartRequired(draft)
        settings.setConfiguredHotkey(draft.dictationHotkey)
        settings.setConfiguredEnterHotkey(draft.alternateCompletionHotkey)
        settings.setConfiguredHistoryHotkey(draft.historyHotkey)
        settings.setConfiguredCorrectionHotkey(draft.correctionHotkey)
        settings.setConfiguredRewriteToggleHotkey(draft.rewriteToggleHotkey)
        settings.setConfiguredRewriteStyleHotkey(draft.rewriteStyleHotkey)
        settings.primaryCompletionBehavior = draft.primaryCompletionBehavior
        settings.alternateCompletionEnabled = draft.alternateCompletionEnabled
        settings.enterDelayMilliseconds = draft.enterDelayMilliseconds
        settings.speechModelProfile = draft.speechModelProfile
        settings.inputDevice = draft.inputDevicePreference
        settings.recordingHUDRecordingColor = draft.recordingColor
        settings.recordingHUDTranscribingColor = draft.transcribingColor
        settings.recordingHUDCorrectingColor = draft.correctingColor
        settings.recordingHUDBackgroundStyle = draft.backgroundStyle
        settings.recordingHUDSize = draft.hudSize
        settings.recordingHUDDisplayMode = draft.hudDisplayMode
        settings.normalizeNumbersToDigits = draft.normalizeNumbersToDigits
        settings.removeFillerWords = draft.removeFillerWords
        settings.enabledFillerPresetKeys = draft.enabledFillerPresetKeys
        settings.customFillerWords = draft.customFillerWords
        settings.disabledCustomFillerWords = draft.disabledCustomFillerWords
        settings.autoStopOnSilenceEnabled = draft.autoStopOnSilenceEnabled
        settings.autoStopSilenceSeconds = draft.autoStopSilenceSeconds
        settings.muteWhileRecording = draft.muteWhileRecording
        settings.autoLearnVocabularyEnabled = draft.autoLearnVocabularyEnabled
        settings.textPostprocessingMode = draft.textPostprocessingMode
        settings.llmEngineBackend = draft.llmEngineBackend
        settings.llmCustomBaseURL = draft.llmCustomBaseURL
        settings.llmCustomAPIKey = draft.llmCustomAPIKey
        settings.llmCustomModelName = draft.llmCustomModelName
        settings.llmUseSystemProxy = draft.llmUseSystemProxy
        settings.correctionBundledModel = draft.correctionModel
        // Prompt editors: text identical to the built-in default is stored
        // as EMPTY (no override), so "reset to default" and "typed the
        // default back in" converge on the same state.
        let correctionPromptDefault = defaultCorrectionSystemPrompt(for: draft.correctionModel)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let correctionPromptText = draft.correctionSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.correctionSystemPromptOverride = correctionPromptText == correctionPromptDefault ? "" : draft.correctionSystemPrompt
        var allStyles: [(id: String, defaultPrompt: String)] =
            RewriteStyle.allCases.map { ($0.rawValue, defaultRewriteSystemPrompt(for: $0)) }
            + draft.customRewriteStyles.map { ($0.id, LLMRewritePrompt.systemPrompt(custom: $0)) }
        for styleEntry in allStyles {
            let styleDefault = styleEntry.defaultPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let styleText = (draft.rewriteSystemPrompts[styleEntry.id] ?? styleEntry.defaultPrompt)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            settings.setRewriteSystemPromptOverride(
                styleText == styleDefault ? "" : (draft.rewriteSystemPrompts[styleEntry.id] ?? styleDefault),
                forStyleID: styleEntry.id)
        }
        settings.rewriteEnabled = draft.rewriteEnabled
        settings.punctuationRestorationEnabled = draft.punctuationRestorationEnabled
        settings.punctuationModel = draft.punctuationModel
        settings.rewriteStyleID = draft.rewriteStyleID
        settings.customRewriteStyles = draft.customRewriteStyles
        settings.rewriteBundledModel = draft.rewriteBundledModel
        settings.rewriteEngineBackend = draft.rewriteEngineBackend
        settings.rewriteCustomBaseURL = draft.rewriteCustomBaseURL
        settings.rewriteCustomAPIKey = draft.rewriteCustomAPIKey
        settings.rewriteCustomModelName = draft.rewriteCustomModelName
        settings.agentEnabled = true
        _ = settings.refreshFromDisk()
        settingsDraft = ControlPanelSettingsDraft(settings: settings)
        if restartRequired {
            beginServiceOperation(.applyingSettings)
        } else {
            // Nothing the agent reads at launch changed — persisting is
            // enough; the agent picks the values up live on the next
            // dictation. No service restart, no HUD interruption.
            DistributedNotificationCenter.default().postNotificationName(
                SETTINGS_LIVE_CHANGED_NOTIFICATION,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            refreshSettingsWindow()
        }
    }

    private func refreshSettingsWindow() {
        guard let settingsWindow else { return }
        settingsWindow.contentView = makeTabbedSettingsContentView()
    }

    @objc private func grantPermissionClicked(_ sender: NSButton) {
        guard Permission.allCases.indices.contains(sender.tag) else { return }
        let permission = Permission.allCases[sender.tag]
        if Permissions.isGranted(permission) {
            permissionClickCount[permission] = nil
            refresh(force: true)
            return
        }

        let clicks = (permissionClickCount[permission] ?? 0) + 1
        permissionClickCount[permission] = clicks
        if clicks >= 2 {
            Permissions.openSettings(for: permission)
        } else {
            Permissions.request(permission)
        }
        refresh(force: true)
    }

    @objc private func resetPermissionsClicked(_ sender: NSButton) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = t("Сбросить разрешения?", "Reset Permissions?")
        alert.informativeText = t("macOS отзовёт у SuperDictate Next микрофон, вставку текста и мониторинг ввода. Приложение перезапустится и снова попросит доступ.",
                                  "macOS will revoke SuperDictate Next's microphone, text insertion, and input monitoring. The app will relaunch and ask again.")
        alert.addButton(withTitle: t("Отмена", "Cancel"))
        alert.addButton(withTitle: t("Сбросить", "Reset"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        Permissions.resetAll()
        permissionClickCount = [:]
        refresh(force: true)
    }

    @MainActor private func showError(title: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: t("ОК", "OK"))
        alert.runModal()
    }
}

/// NSButton's target must be an NSObject; this wraps a Swift closure that
/// receives the clicked button's tag (the palette index).
@MainActor
private final class SwatchAction: NSObject {
    nonisolated(unsafe) static var associationKey: UInt8 = 0
    let handler: (Int) -> Void
    init(handler: @escaping (Int) -> Void) { self.handler = handler }
    @objc func swatchClicked(_ sender: NSButton) { handler(sender.tag) }
}

extension NSColor {
    /// "#RRGGBB" → NSColor (sRGB); falls back to gray on malformed input.
    convenience init(hexString: String) {
        var value: UInt64 = 0
        let cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        if Scanner(string: cleaned).scanHexInt64(&value), cleaned.count == 6 {
            self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255.0,
                      green: CGFloat((value >> 8) & 0xFF) / 255.0,
                      blue: CGFloat(value & 0xFF) / 255.0,
                      alpha: 1)
        } else {
            self.init(srgbRed: 0.6, green: 0.6, blue: 0.6, alpha: 1)
        }
    }
}
