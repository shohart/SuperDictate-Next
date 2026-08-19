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
}

struct ControlPanelSettingsDraft: Equatable {
    var dictationHotkey: HotkeyChoice
    var alternateCompletionHotkey: HotkeyChoice
    var historyHotkey: HotkeyChoice
    var primaryCompletionBehavior: DictationCompletionBehavior
    var alternateCompletionEnabled: Bool
    var enterDelayMilliseconds: Int
    var inputDevicePreference: String
    var recordingColor: RecordingHUDAccentColor
    var transcribingColor: RecordingHUDAccentColor
    var backgroundStyle: RecordingHUDBackgroundStyle
    var hudSize: RecordingHUDSize
    var hudDisplayMode: RecordingHUDDisplayMode
    var normalizeNumbersToDigits: Bool
    var removeFillerWords: Bool
    var enabledFillerPresetKeys: Set<String>
    var customFillerWords: [String]
    var disabledCustomFillerWords: Set<String>
    var autoStopOnSilenceEnabled: Bool
    var autoStopSilenceSeconds: Int
    var muteWhileRecording: Bool
    var autoLearnVocabularyEnabled: Bool

    init(settings: Settings) {
        dictationHotkey = settings.configuredHotkey
        alternateCompletionHotkey = settings.configuredEnterHotkey
        historyHotkey = settings.configuredHistoryHotkey
        primaryCompletionBehavior = settings.primaryCompletionBehavior
        alternateCompletionEnabled = settings.alternateCompletionEnabled
        enterDelayMilliseconds = settings.enterDelayMilliseconds
        let savedInput = settings.inputDevice
        inputDevicePreference = audioInputDevice(matching: savedInput)?.uid ?? savedInput
        recordingColor = settings.recordingHUDRecordingColor
        transcribingColor = settings.recordingHUDTranscribingColor
        backgroundStyle = settings.recordingHUDBackgroundStyle
        hudSize = settings.recordingHUDSize
        hudDisplayMode = settings.recordingHUDDisplayMode
        normalizeNumbersToDigits = settings.normalizeNumbersToDigits
        removeFillerWords = settings.removeFillerWords
        enabledFillerPresetKeys = settings.enabledFillerPresetKeys
        customFillerWords = settings.customFillerWords
        disabledCustomFillerWords = settings.disabledCustomFillerWords
        autoStopOnSilenceEnabled = settings.autoStopOnSilenceEnabled
        autoStopSilenceSeconds = settings.autoStopSilenceSeconds
        muteWhileRecording = settings.muteWhileRecording
        autoLearnVocabularyEnabled = settings.autoLearnVocabularyEnabled
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

private enum SettingsTab: Int, CaseIterable {
    case dictation
    case text
    case audio
    case appearance
    case system
}

@MainActor
final class SuperDictateControlPanelApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
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
                settingsWindow.title = t("Настройки SuperDictate Next", "SuperDictate Next Settings")
                settingsWindow.contentView = makeTabbedSettingsContentView()
            }
        }
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
            content.addArrangedSubview(correctionsInfoRow())
            content.addArrangedSubview(autoLearnVocabularyRow(draft))

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
                let prepared = try await SuperDictateUpdateInstaller.prepare(manifest: manifest)
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
        text.addArrangedSubview(panelLabel(detail, size: 12, color: .secondaryLabelColor))

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
        return row
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
        let save = panelButton(
            t("Сохранить и перезапустить", "Save & Restart"),
            action: #selector(saveSettingsClicked(_:)),
            enabled: hasChanges && validation == nil && serviceOperation == nil,
            toolTip: t("Сохранить настройки и перезапустить фоновую службу.",
                       "Save settings and restart the background service.")
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
            ]
            if draft.alternateCompletionEnabled {
                pairs.append((draft.dictationHotkey, draft.alternateCompletionHotkey, false))
                pairs.append((draft.alternateCompletionHotkey, draft.historyHotkey, true))
            }
            return pairs
        }()

        for (first, second, allowModifierPrefix) in shortcutPairs {
                if hotkeysConflict(first, second) {
                    return t("Сочетания для диктовки, завершения и истории должны отличаться.",
                             "Dictation, finish, and history shortcuts must be different.")
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
        settingsWindow.title = t("Настройки SuperDictate Next", "SuperDictate Next Settings")
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

    @objc private func saveSettingsClicked(_ sender: NSButton) {
        guard let draft = settingsDraft,
              settingsValidationMessage(draft) == nil else { return }
        settings.setConfiguredHotkey(draft.dictationHotkey)
        settings.setConfiguredEnterHotkey(draft.alternateCompletionHotkey)
        settings.setConfiguredHistoryHotkey(draft.historyHotkey)
        settings.primaryCompletionBehavior = draft.primaryCompletionBehavior
        settings.alternateCompletionEnabled = draft.alternateCompletionEnabled
        settings.enterDelayMilliseconds = draft.enterDelayMilliseconds
        settings.inputDevice = draft.inputDevicePreference
        settings.recordingHUDRecordingColor = draft.recordingColor
        settings.recordingHUDTranscribingColor = draft.transcribingColor
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
        settings.agentEnabled = true
        _ = settings.refreshFromDisk()
        settingsDraft = ControlPanelSettingsDraft(settings: settings)
        beginServiceOperation(.applyingSettings)
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

    private func showError(title: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: t("ОК", "OK"))
        alert.runModal()
    }
}
