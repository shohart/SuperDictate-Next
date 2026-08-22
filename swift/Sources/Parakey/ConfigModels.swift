// SuperDictate — extracted from the monolithic main.swift
// during the refactor/split-main refactor (settings/hotkey enums).
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

enum MenuBarState {
    case loading
    case idle
    case recording
    case busy
    case error
}

enum RecordingHUDMode {
    case recording
    case transcribing
    /// Shown while the LLM correction pass (LLMPostprocessingCoordinator)
    /// is running on already-transcribed text -- a visually distinct
    /// "improving" animation (orbiting sparkles, see
    /// RecordingHUDView.drawCorrectingStars) so it doesn't read as a
    /// continuation of transcription. Only entered when correction mode is
    /// actually enabled (ParakeyApp.showCorrectingHUD gates the call), so
    /// nothing changes for users who never turned this feature on.
    case correcting
    /// Brief flash shown when a dictation fails (transcription error,
    /// paste failure). Renders a static yellow capsule so the user
    /// gets visual feedback even when the menu-bar icon is hidden.
    case error
}

/// A global dictation shortcut: either one modifier key or a regular
/// keyboard key with an optional Control/Option/Shift/Command chord.
struct HotkeyChoice: Equatable {
    let name: String
    let keycode: CGKeyCode
    let isModifier: Bool
    /// Which CGEventFlags mask bit fires for this modifier (nil for non-modifiers).
    let modifierFlag: CGEventFlags?
    /// Modifier keys required alongside a non-modifier key.
    let requiredModifiers: CGEventFlags

    init(name: String,
         keycode: CGKeyCode,
         isModifier: Bool,
         modifierFlag: CGEventFlags?,
         requiredModifiers: CGEventFlags = []) {
        self.name = name
        self.keycode = keycode
        self.isModifier = isModifier
        self.modifierFlag = modifierFlag
        self.requiredModifiers = requiredModifiers.intersection(HOTKEY_SHORTCUT_MODIFIER_MASK)
    }
}

let HOTKEY_SHORTCUT_MODIFIER_MASK: CGEventFlags = [
    .maskControl,
    .maskAlternate,
    .maskShift,
    .maskCommand,
    .maskSecondaryFn,
]

let MODIFIER_HOTKEY_CHOICES: [HotkeyChoice] = [
    HotkeyChoice(name: "Left Control", keycode: 59, isModifier: true, modifierFlag: .maskControl),
    HotkeyChoice(name: "Right Control", keycode: 62, isModifier: true, modifierFlag: .maskControl),
    HotkeyChoice(name: "Left Option", keycode: 58, isModifier: true, modifierFlag: .maskAlternate),
    HotkeyChoice(name: "Right Option", keycode: 61, isModifier: true, modifierFlag: .maskAlternate),
    HotkeyChoice(name: "Left Shift", keycode: 56, isModifier: true, modifierFlag: .maskShift),
    HotkeyChoice(name: "Right Shift", keycode: 60, isModifier: true, modifierFlag: .maskShift),
    HotkeyChoice(name: "Left Command", keycode: 55, isModifier: true, modifierFlag: .maskCommand),
    HotkeyChoice(name: "Right Command", keycode: 54, isModifier: true, modifierFlag: .maskCommand),
    HotkeyChoice(name: "Fn", keycode: FN_KEYCODE, isModifier: true, modifierFlag: .maskSecondaryFn),
]

let FUNCTION_KEY_NAMES_BY_KEYCODE: [CGKeyCode: String] = [
    122: "F1",
    120: "F2",
    99: "F3",
    118: "F4",
    96: "F5",
    97: "F6",
    98: "F7",
    100: "F8",
    101: "F9",
    109: "F10",
    103: "F11",
    111: "F12",
    105: "F13",
    107: "F14",
    113: "F15",
    106: "F16",
    64: "F17",
    79: "F18",
    80: "F19",
    90: "F20",
]

let HOTKEY_CHOICES: [HotkeyChoice] = [
    MODIFIER_HOTKEY_CHOICES.first(where: { $0.keycode == 62 })!,
    MODIFIER_HOTKEY_CHOICES.first(where: { $0.keycode == 61 })!,
    MODIFIER_HOTKEY_CHOICES.first(where: { $0.keycode == 54 })!,
    HotkeyChoice(name: "F5",            keycode: 96,  isModifier: false, modifierFlag: nil),
    HotkeyChoice(name: "F6",            keycode: 97,  isModifier: false, modifierFlag: nil),
    HotkeyChoice(name: "F13",           keycode: 105, isModifier: false, modifierFlag: nil),
    HotkeyChoice(name: "F18",           keycode: 79,  isModifier: false, modifierFlag: nil),
    HotkeyChoice(name: "F19",           keycode: 80,  isModifier: false, modifierFlag: nil),
]

private let HOTKEY_KEY_NAMES_BY_KEYCODE: [CGKeyCode: String] = [
    0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
    11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
    20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
    29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
    37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
    46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Escape",
    65: "Keypad .", 67: "Keypad *", 69: "Keypad +", 71: "Clear", 75: "Keypad /",
    76: "Enter", 78: "Keypad -", 81: "Keypad =", 82: "Keypad 0", 83: "Keypad 1",
    84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6",
    89: "Keypad 7", 91: "Keypad 8", 92: "Keypad 9", 114: "Help", 115: "Home",
    116: "Page Up", 117: "Forward Delete", 119: "End", 121: "Page Down", 123: "Left Arrow",
    124: "Right Arrow", 125: "Down Arrow", 126: "Up Arrow",
]

private func hotkeyKeyName(for keycode: CGKeyCode) -> String {
    FUNCTION_KEY_NAMES_BY_KEYCODE[keycode]
        ?? HOTKEY_KEY_NAMES_BY_KEYCODE[keycode]
        ?? "Key \(keycode)"
}

private func hotkeyModifierSymbols(_ flags: CGEventFlags) -> String {
    var result = ""
    if flags.contains(.maskControl) { result += "⌃" }
    if flags.contains(.maskAlternate) { result += "⌥" }
    if flags.contains(.maskShift) { result += "⇧" }
    if flags.contains(.maskCommand) { result += "⌘" }
    if flags.contains(.maskSecondaryFn) { result += "fn" }
    return result
}

private func modifierHotkeyName(primary: HotkeyChoice,
                                requiredModifiers: CGEventFlags) -> String {
    var parts: [String] = []
    if requiredModifiers.contains(.maskControl) { parts.append("Control") }
    if requiredModifiers.contains(.maskAlternate) { parts.append("Option") }
    if requiredModifiers.contains(.maskShift) { parts.append("Shift") }
    if requiredModifiers.contains(.maskCommand) { parts.append("Command") }
    if requiredModifiers.contains(.maskSecondaryFn) { parts.append("Fn") }
    parts.append(primary.name)
    return parts.joined(separator: " + ")
}

func recordableHotkeyChoice(forKeycode keycode: CGKeyCode,
                            modifiers: CGEventFlags = []) -> HotkeyChoice? {
    let normalizedModifiers = modifiers.intersection(HOTKEY_SHORTCUT_MODIFIER_MASK)
    if let choice = MODIFIER_HOTKEY_CHOICES.first(where: { $0.keycode == keycode }) {
        let requiredModifiers = choice.modifierFlag.map {
            normalizedModifiers.subtracting($0)
        } ?? normalizedModifiers
        return HotkeyChoice(name: modifierHotkeyName(primary: choice,
                                                     requiredModifiers: requiredModifiers),
                            keycode: choice.keycode,
                            isModifier: true,
                            modifierFlag: choice.modifierFlag,
                            requiredModifiers: requiredModifiers)
    }
    guard keycode <= 255, keycode != ESCAPE_KEYCODE else { return nil }
    let name = hotkeyModifierSymbols(normalizedModifiers) + hotkeyKeyName(for: keycode)
    return HotkeyChoice(name: name,
                        keycode: keycode,
                        isModifier: false,
                        modifierFlag: nil,
                        requiredModifiers: normalizedModifiers)
}

func hotkeyChoice(forKeycode keycode: CGKeyCode,
                  modifiers: CGEventFlags = []) -> HotkeyChoice {
    recordableHotkeyChoice(forKeycode: keycode, modifiers: modifiers)
        ?? HOTKEY_CHOICES.first(where: { $0.keycode == DEFAULT_HOTKEY_KEYCODE })!
}

func normalizedHotkeyKeycode(storedValue value: Any?) -> CGKeyCode? {
    let raw: Int?
    if let number = value as? NSNumber {
        raw = number.intValue
    } else if let string = value as? String {
        raw = Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
    } else {
        raw = nil
    }

    guard let raw,
          raw >= 0,
          raw <= Int(CGKeyCode.max),
          recordableHotkeyChoice(forKeycode: CGKeyCode(raw)) != nil else {
        return nil
    }
    return CGKeyCode(raw)
}

enum TriggerMode: String { case hold, toggle }
let TRIGGER_DISPLAY: [TriggerMode: String] = [
    .hold: "Press and hold",
    .toggle: "Press to toggle",
]

enum DictationCompletionBehavior: String, CaseIterable {
    case insert
    case insertAndEnter

    var opposite: DictationCompletionBehavior {
        self == .insert ? .insertAndEnter : .insert
    }

    var pressesEnter: Bool { self == .insertAndEnter }
}

func localizedHotkeyName(_ choice: HotkeyChoice,
                         language: InterfaceLanguage) -> String {
    guard language == .russian else { return choice.name }
    if choice.isModifier {
        let primary: String
        switch choice.keycode {
        case 59: primary = "Левый Control"
        case 62: primary = "Правый Control"
        case 58: primary = "Левый Option"
        case 61: primary = "Правый Option"
        case 56: primary = "Левый Shift"
        case 60: primary = "Правый Shift"
        case 55: primary = "Левый Command"
        case 54: primary = "Правый Command"
        case FN_KEYCODE: primary = "Fn"
        default: primary = choice.name
        }
        var parts: [String] = []
        if choice.requiredModifiers.contains(.maskControl) { parts.append("Control") }
        if choice.requiredModifiers.contains(.maskAlternate) { parts.append("Option") }
        if choice.requiredModifiers.contains(.maskShift) { parts.append("Shift") }
        if choice.requiredModifiers.contains(.maskCommand) { parts.append("Command") }
        if choice.requiredModifiers.contains(.maskSecondaryFn) { parts.append("Fn") }
        parts.append(primary)
        return parts.joined(separator: " + ")
    }

    let keyName: String
    switch choice.keycode {
    case 36: keyName = "Return"
    case 48: keyName = "Tab"
    case 49: keyName = "Пробел"
    case 51: keyName = "Delete"
    case 76: keyName = "Enter"
    case 115: keyName = "Home"
    case 116: keyName = "Page Up"
    case 117: keyName = "Forward Delete"
    case 119: keyName = "End"
    case 121: keyName = "Page Down"
    case 123: keyName = "Стрелка влево"
    case 124: keyName = "Стрелка вправо"
    case 125: keyName = "Стрелка вниз"
    case 126: keyName = "Стрелка вверх"
    default: keyName = hotkeyKeyName(for: choice.keycode)
    }
    return hotkeyModifierSymbols(choice.requiredModifiers) + keyName
}

enum PasteSuffix: String { case appendSpace = "space", none, appendNewline = "newline" }
let PASTE_SUFFIX_DISPLAY: [PasteSuffix: String] = [
    .appendSpace: "Append space",
    .none: "No suffix",
    .appendNewline: "Append newline",
]

/// User-visible language choice. `.auto` is the default and lets Parakeet's
/// own multilingual decoder detect the language freely — parakeet.cpp's
/// plain PCM transcription entry point (`parakeet_capi_transcribe_pcm`,
/// wrapped by `sd_parakeet_transcribe`) does not accept a forced-language
/// parameter, so this app does not force a decoder language onto native
/// code (see docs/parakeet-intel-backend.md §12: "do not pretend to force a
/// decoder language unless the pinned model/runtime truly supports it" —
/// documented as a known limitation in the Phase 3 report). Raw values are
/// ISO-639-1 codes (`isoLanguageCode` below); the effective language is
/// still resolved (from the setting or the active keyboard layout, see
/// KeyboardLanguage.swift) and used for deterministic post-processing —
/// specifically `ParakeetTranscriptRepair`'s Russian/`ё` handling.
enum DictationLanguage: String, CaseIterable {
    case auto
    case english = "en"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case portuguese = "pt"
    case romanian = "ro"
    case polish = "pl"
    case czech = "cs"
    case slovak = "sk"
    case slovenian = "sl"
    case croatian = "hr"
    case bosnian = "bs"
    case russian = "ru"
    case ukrainian = "uk"
    case belarusian = "be"
    case bulgarian = "bg"
    case serbian = "sr"

    /// ISO-639-1 string, exactly this enum's raw value; `.auto` returns nil.
    /// Not passed to native code today (see the enum's doc comment) — used
    /// for deterministic post-processing (`ParakeetTranscriptRepair`).
    var isoLanguageCode: String? {
        self == .auto ? nil : rawValue
    }
}

let DICTATION_LANGUAGE_DISPLAY: [DictationLanguage: String] = [
    .auto: "Auto-detect",
    .english: "English",
    .spanish: "Spanish",
    .french: "French",
    .german: "German",
    .italian: "Italian",
    .portuguese: "Portuguese",
    .romanian: "Romanian",
    .polish: "Polish",
    .czech: "Czech",
    .slovak: "Slovak",
    .slovenian: "Slovenian",
    .croatian: "Croatian",
    .bosnian: "Bosnian",
    .russian: "Russian",
    .ukrainian: "Ukrainian",
    .belarusian: "Belarusian",
    .bulgarian: "Bulgarian",
    .serbian: "Serbian",
]

// There is exactly one production speech model (spec §14: "There is one
// speech model, so do not show a model picker"). This is still a
// `CaseIterable` enum with a single real case — rather than deleting the
// type outright — because `productionSpeechModelProfile(rawValue:)` below
// doubles as the upgrade-migration path: any old persisted raw value
// (`"multilingual_v3"`, `"english_unified"`, or anything else left over from
// a pre-Parakeet install) normalizes to `.parakeetTDTv3` the same way it
// always normalized deprecated/unknown values to the production default
// before this migration.
enum SpeechModelProfile: String, CaseIterable {
    case parakeetTDTv3 = "parakeet_tdt_v3"

    static let productionDefault: SpeechModelProfile = .parakeetTDTv3

    var isProductionSupported: Bool {
        self == .parakeetTDTv3
    }

    var productionProfile: SpeechModelProfile {
        isProductionSupported ? self : Self.productionDefault
    }

    var displayName: String {
        "Parakeet TDT 0.6B v3"
    }

    var shortName: String {
        "Parakeet TDT 0.6B v3"
    }

    var aboutModelText: String {
        "parakeet.cpp · NVIDIA Parakeet TDT 0.6B v3 multilingual · GGUF q8_0"
    }

    var setupReadyDetail: String {
        "\(shortName) is loaded locally."
    }

    var cacheResetDetail: String {
        "Parakey will delete the local Parakeet TDT 0.6B v3 model cache, unload the current speech model, and download a fresh verified copy before dictation is available again."
    }

    var estimatedDownloadBytes: Int64 {
        PARAKEET_MODEL_SIZE_BYTES
    }

    var downloadSizeText: String {
        "about 940 MB"
    }
}

func productionSpeechModelProfile(rawValue: String?) -> SpeechModelProfile {
    guard let rawValue,
          let profile = SpeechModelProfile(rawValue: rawValue),
          profile.isProductionSupported else {
        return .productionDefault
    }
    return profile
}

/// Text postprocessing after ASR + the deterministic corrections/filler/
/// number passes in RecordingLifecycle.swift's `processedDictationText`.
/// Per the architecture note this implements (local memory atom
/// a81da166-460a-467e-ae78-f53667069cb0 §2-4): correction and rewrite are
/// two DIFFERENT user-facing functions, never chained (`GEC → REWRITE` is
/// explicitly disallowed) — only `.correction` exists today. `.off` and
/// `.correction` are the only real states; a future rewrite mode adds its
/// own case here rather than reusing this one, matching the atom's staged
/// rollout (correction must fully ship and stabilize first).
enum TextPostprocessingMode: String, CaseIterable, Codable {
    case off
    case correction
}

/// Where the correction model actually runs. `.bundledLocal` spawns
/// SuperDictateLLMHost (swift/Sources/llama_cpp_host/) as a subprocess and
/// talks to it over loopback HTTP; `.customEndpoint` points the exact same
/// OpenAI-compatible client (OpenAICompatibleClient.swift) at a
/// user-supplied server instead. See LLMHostProcess.swift's own doc
/// comment for why this is a subprocess, not a linked library.
enum LLMEngineBackend: String, CaseIterable, Codable {
    case bundledLocal
    case customEndpoint
}

/// Which bundled correction model tier the correction pass uses
/// (docs/specs/rewrite-tiered-correction-spec.md §2). `.fast` is the
/// already-shipped VoiceScribe V15 R-3 pair (Qwen3.5-0.8B Q6_K + the
/// dictation-corrector LoRA, benchmark/REPORT.md: p50 189 ms, Identity
/// 1.000, 0.7 GB) and is deliberately the default — this branch fixes it
/// as THE fast correction model. `.quality` is YandexGPT-5-Lite-8B
/// Q4_K_M (same report: EM 0.892, Levenshtein 0.985, ~4.9 GB, on-demand
/// download), which also doubles as the bundled rewrite model — see
/// LLMPostprocessingPrompts/ModelDownload for the shared file pin.
enum CorrectionModelTier: String, CaseIterable, Codable {
    case fast
    case quality

    var displayName: String {
        switch self {
        case .fast: return "Fast"
        case .quality: return "Quality"
        }
    }
}

/// Rewrite style — the second, independent post-processing function
/// (docs/specs/rewrite-tiered-correction-spec.md §3). Runs AFTER the
/// correction pass when both are enabled; unlike correction it is allowed
/// to restructure text (repeats, filler segments, task structure, register).
enum RewriteStyle: String, CaseIterable, Codable {
    /// Убрать повторы, несогласование падежей и бессмысленные отрезки;
    /// стиль и порядок мыслей близки к оригиналу.
    case polish
    /// Вольный текст → максимально структурированная задача: суть,
    /// главное, второстепенное, шаги; повторы и логические ошибки отсечь.
    case structuredTask = "structured_task"
    /// Casual-речь → сухой официальный стиль; факты/числа/даты/отрицания
    /// сохранены дословно.
    case official

    var displayName: String {
        switch self {
        case .polish: return "Polish"
        case .structuredTask: return "Structured task"
        case .official: return "Official"
        }
    }
}

func normalizedTextPostprocessingMode(rawValue: String?) -> TextPostprocessingMode {
    guard let rawValue, let mode = TextPostprocessingMode(rawValue: rawValue) else {
        return .off
    }
    return mode
}

func normalizedLLMEngineBackend(rawValue: String?) -> LLMEngineBackend {
    guard let rawValue, let backend = LLMEngineBackend(rawValue: rawValue) else {
        return .bundledLocal
    }
    return backend
}

func normalizedCorrectionModelTier(rawValue: String?) -> CorrectionModelTier {
    guard let rawValue, let tier = CorrectionModelTier(rawValue: rawValue) else {
        return .fast
    }
    return tier
}

func normalizedRewriteStyle(rawValue: String?) -> RewriteStyle {
    guard let rawValue, let style = RewriteStyle(rawValue: rawValue) else {
        return .polish
    }
    return style
}

/// Which bundled model file the rewrite pass loads when its backend is
/// `.bundledLocal` — the Settings dropdown next to the style picker
/// (docs/specs/rewrite-tiered-correction-spec.md §9). `.yandexGPT` is
/// the benchmark winner and the default (FactRec 0.527, LenRatio 0.966 —
/// benchmark/REPORT.md); `.voiceScribe` reuses the fast correction pair
/// (rewrite LenRatio 0.599: much faster but compresses text — kept as an
/// experimental choice because it is the only other bundled file and
/// needs no extra download for fast-tier correction users).
enum RewriteBundledModel: String, CaseIterable, Codable {
    case yandexGPT = "yandexgpt"
    case voiceScribe = "voicescribe"

    /// The correction tier whose bundled files this choice maps to — used
    /// to resolve model/LoRA paths and to SHARE a host process with that
    /// tier: one 0.8B host serves fast correction AND voiceScribe rewrite;
    /// one YandexGPT host serves quality correction AND yandexGPT rewrite.
    var correctionTierEquivalent: CorrectionModelTier {
        self == .yandexGPT ? .quality : .fast
    }
}

func normalizedRewriteBundledModel(rawValue: String?) -> RewriteBundledModel {
    guard let rawValue, let model = RewriteBundledModel(rawValue: rawValue) else {
        return .yandexGPT
    }
    return model
}

enum RecentTranscriptLimit: String, CaseIterable {
    case off
    case last1 = "1"
    case last5 = "5"
    case last10 = "10"

    var count: Int {
        switch self {
        case .off: return 0
        case .last1: return 1
        case .last5: return 5
        case .last10: return 10
        }
    }
}

let DEFAULT_RECENT_TRANSCRIPT_LIMIT = RecentTranscriptLimit.last10
let RECENT_TRANSCRIPT_LIMIT_DISPLAY: [RecentTranscriptLimit: String] = [
    .off: "Off",
    .last1: "Last 1",
    .last5: "Last 5",
    .last10: "Last 10",
]

enum RecordingHUDAccentColor: String, CaseIterable {
    case red
    case orange
    case pink
    case purple
    case blue
    case cyan
    case green
    case white
    case contrast

    var displayName: String {
        switch self {
        case .red: return "Red"
        case .orange: return "Orange"
        case .pink: return "Pink"
        case .purple: return "Purple"
        case .blue: return "Blue"
        case .cyan: return "Cyan"
        case .green: return "Green"
        case .white: return "White"
        case .contrast: return "Contrast"
        }
    }

    var nsColor: NSColor {
        switch self {
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .pink: return .systemPink
        case .purple: return .systemPurple
        case .blue: return NSColor(calibratedRed: 0.0, green: 0.44, blue: 1.0, alpha: 1)
        case .cyan: return .systemCyan
        case .green: return .systemGreen
        case .white: return .white
        case .contrast: return .white
        }
    }
}

extension RecordingHUDAccentColor {
    /// `contrast` adapts to the HUD background (dark on light, white on
    /// dark); every other color is background-independent. `.contrast.nsColor`
    /// stays a plain literal for callers that must resolve without a
    /// background context.
    func resolvedColor(lightBackground: Bool) -> NSColor {
        switch self {
        case .contrast: return lightBackground ? .black : .white
        default: return nsColor
        }
    }
}

enum RecordingHUDSize: String, CaseIterable {
    case compact
    case standard
    case large

    var displayName: String {
        switch self {
        case .compact: return "Compact"
        case .standard: return "Standard"
        case .large: return "Large"
        }
    }

    var visualScale: CGFloat {
        switch self {
        case .compact: return 1.15
        case .standard: return 1.5
        case .large: return 1.85
        }
    }

    var expandedSize: NSSize {
        NSSize(width: RECORDING_HUD_BASE_SIZE.width * visualScale,
               height: RECORDING_HUD_BASE_SIZE.height * visualScale)
    }
}

enum RecordingHUDBackgroundStyle: String, CaseIterable {
    case system
    case dark
    case light

    var displayName: String {
        switch self {
        case .system: return "System"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }
}

enum RecordingHUDDisplayMode: String, CaseIterable {
    case levelBars
    case timerOutline

    var displayName: String {
        switch self {
        case .levelBars: return "Level bars"
        case .timerOutline: return "Timer"
        }
    }
}

func parseRecentTranscriptLimit(storedValue value: Any?) -> RecentTranscriptLimit? {
    if let raw = value as? String {
        return RecentTranscriptLimit(rawValue: raw)
    }
    if let number = value as? NSNumber {
        return RecentTranscriptLimit(rawValue: number.stringValue)
    }
    return nil
}

func limitedRecentTranscripts(_ transcripts: [String], limit: RecentTranscriptLimit) -> [String] {
    let count = limit.count
    guard count > 0 else { return [] }
    guard transcripts.count > count else { return transcripts }
    return Array(transcripts.prefix(count))
}

