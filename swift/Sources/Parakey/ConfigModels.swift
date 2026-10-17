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
    /// "transmutation" animation (the transcription wave re-formed by a
    /// sweeping luminous front into a left->right gradient, see
    /// RecordingHUDView.drawCorrectingWave) so it reads as the text being
    /// improved, not as a continuation of transcription. Only entered when
    /// correction or rewrite is actually enabled (ParakeyApp.
    /// showCorrectingHUD gates the call), so nothing changes for users
    /// who never turned either feature on.
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

// ASR engine/model selection. Whisper profiles run whisper.cpp (GGUF) in
// the SuperDictateWhisperHost helper process — Vulkan on the RX 6600 with
// CPU fallback; Parakeet remains its own native Vulkan path.
enum SpeechModelProfile: String, CaseIterable {
    case parakeetTDTv3 = "parakeet_tdt_v3"
    case whisperRussian = "whisper_large_v3_turbo_russian"
    case whisperRussianCodeSwitch = "whisper_large_v3_turbo_russian_codeswitch"
    /// Experimental ONNX backend (docs/specs/cross-platform-onnx-asr-spec.md):
    /// Parakeet Ultra int8 in the SuperDictateOnnxHost helper, CPU only.
    /// Explicit user choice; never selected or migrated to automatically.
    case parakeetUltraOnnx = "parakeet_ultra_onnx"

    static let productionDefault: SpeechModelProfile = .parakeetTDTv3

    var isProductionSupported: Bool {
        true
    }

    /// Whisper runs only on a discrete GPU with "Use GPU" on; otherwise the
    /// session falls back to `productionDefault` (TranscriptionWorker.load).
    var requiresDiscreteGPU: Bool {
        self == .whisperRussian || self == .whisperRussianCodeSwitch
    }

    var productionProfile: SpeechModelProfile {
        isProductionSupported ? self : Self.productionDefault
    }

    var displayName: String {
        switch self {
        case .parakeetTDTv3: return "Parakeet TDT 0.6B v3"
        case .whisperRussian: return "Whisper Large v3 Turbo Russian"
        case .whisperRussianCodeSwitch: return "Whisper Large v3 Turbo Russian Code-Switch"
        case .parakeetUltraOnnx: return "Parakeet Ultra 0.6B ONNX (experimental)"
        }
    }

    var shortName: String {
        displayName
    }

    var aboutModelText: String {
        switch self {
        case .parakeetTDTv3: return "parakeet.cpp · NVIDIA Parakeet TDT 0.6B v3 multilingual · GGUF q8_0"
        case .whisperRussian: return "whisper.cpp · OpenAI Whisper Large v3 Turbo · GGUF Q8_0 · только дискретная GPU (Vulkan) · язык: русский"
        case .whisperRussianCodeSwitch: return "whisper.cpp · OpenAI Whisper Large v3 Turbo · GGUF Q8_0 · только дискретная GPU (Vulkan) · язык: авто (RU/EN)"
        case .parakeetUltraOnnx: return "ONNX Runtime · Parakeet Ultra 0.6B (TDT) · ONNX int8 · CPU · CC-BY-4.0: NVIDIA (parakeet-tdt-0.6b-v3), Moondream (parakeet-ultra), mldecode (ONNX int8)"
        }
    }

    var setupReadyDetail: String {
        "\(shortName) is loaded locally."
    }

    var cacheResetDetail: String {
        "Parakey will delete the local \(shortName) model cache, unload the current speech model, and download a fresh verified copy before dictation is available again."
    }

    var estimatedDownloadBytes: Int64 {
        switch self {
        case .parakeetTDTv3: return PARAKEET_MODEL_SIZE_BYTES
        case .whisperRussian, .whisperRussianCodeSwitch: return WHISPER_GGUF_SIZE_BYTES
        case .parakeetUltraOnnx: return PARAKEET_ULTRA_ONNX_SIZE_BYTES
        }
    }

    var downloadSizeText: String {
        switch self {
        case .parakeetTDTv3: return "about 940 MB"
        case .whisperRussian, .whisperRussianCodeSwitch: return "about 874 MB"
        case .parakeetUltraOnnx: return "about 630 MB"
        }
    }

    /// True for the experimental ONNX Runtime backend (CPU only; the
    /// "Use GPU" preference does not apply to it).
    var usesOnnxRuntime: Bool {
        self == .parakeetUltraOnnx
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

/// A bundled LLM model the user can pick for the correction or rewrite
/// pass. Every entry ran in the 2026-08-21 benchmark
/// (benchmark/REPORT.md, this machine: AMD RX 6600, llama.cpp/Vulkan,
/// temperature 0); the download pins live next to the file-resolution
/// helpers in ModelDownload.swift and were verified against the exact
/// bytes that benchmark ran on.
///
/// The pickers mirror the benchmark's test roles: CORRECTION offers every
/// small model the benchmark tested for correction plus YandexGPT (the
/// correction winner); REWRITE offers the models the benchmark tested for
/// rewrite (curated per the product decision — no Qwen3-8B, no T-Lite).
enum BundledLLMModel: String, CaseIterable, Codable {
    // MARK: Correction pass models (small class + the quality 8B option)
    /// VoiceScribe V15 R-3: Qwen3.5-0.8B Q6_K + dictation-corrector LoRA.
    /// Benchmark: EM 0.600, Identity 1.000, p50 189 ms, 0.7 GB.
    case voiceScribe = "voicescribe"
    /// Benchmark correction: EM 0.723 (best of the small models), p50 549 ms.
    case qwen35_4b = "qwen35_4b"
    /// Benchmark correction: EM 0.677, p50 375 ms.
    case ruAdapt4b = "ruadapt4b"
    /// Benchmark correction: EM 0.600, p50 484 ms.
    case qvikhr4b = "qvikhr4b"
    /// Benchmark correction: EM 0.585, p50 375 ms.
    case ministral3b = "ministral3b"
    /// Benchmark correction: EM 0.538, p50 343 ms.
    case phi4mini = "phi4mini"
    /// Benchmark correction: EM 0.462, p50 179 ms. Pure GEC fine-tune:
    /// perfect identity but ZERO script normalization (ScriptF1 0.000),
    /// and its system prompt is mandatory (see allowsCustomSystemPrompt).
    case loqira = "loqira"
    /// Vanilla Qwen3.5-0.8B Q6_K — the VoiceScribe base WITHOUT the LoRA.
    /// Benchmark correction: EM 0.369, p50 209 ms. Same file as the
    /// VoiceScribe base pin.
    case vanilla08b = "vanilla08b"
    /// Benchmark correction: EM 0.246, p50 10.8 s — the report calls it
    /// unfit for correction; kept because the correction picker offers
    /// EVERY small model the benchmark tested.
    case lfm25 = "lfm25"
    /// Benchmark correction winner: EM 0.892, Levenshtein 0.985, p50 433 ms.
    /// Also the rewrite winner — offered in BOTH passes.
    case yandexGPT = "yandexgpt"

    // MARK: Big models — rewrite pass
    /// Benchmark rewrite: FactRec 0.489, LenRatio 1.185, p50 3232 ms.
    case qwen35_9b = "qwen35_9b"
    /// Benchmark rewrite: FactRec 0.483, LenRatio 1.444, p50 2252 ms.
    case gemma4e4b = "gemma4e4b"

    /// Models offered by the correction-pass picker: every small model the
    /// benchmark tested for correction, plus YandexGPT (the correction
    /// winner, also in the rewrite list). LFM2.5 is deliberately ABSENT:
    /// it is a "pure reasoning model" whose template hard-codes `<think>`
    /// and which emits `<think>` even when the template omits it (verified
    /// in a live harness) — correction requests burn the entire token
    /// budget on inline reasoning (17 s+, truncated, guardrail-rejected).
    /// Its benchmark EM 0.246 was measured WITH that thinking.
    static let correctionModels: [BundledLLMModel] = [
        .voiceScribe, .qwen35_4b, .ruAdapt4b, .qvikhr4b, .ministral3b,
        .phi4mini, .loqira, .vanilla08b, .yandexGPT,
    ]
    /// Models offered by the rewrite-pass picker (the benchmark's rewrite
    /// table, curated: YandexGPT is the measured winner; Qwen3-8B and
    /// T-Lite are deliberately absent per the product decision). LFM2.5 is
    /// an EXPERIMENTAL addition — the benchmark never tested it for
    /// rewrite; it is offered to try now that its thinking mode is forced
    /// off server-side.
    static let rewriteModels: [BundledLLMModel] = [
        .yandexGPT, .qwen35_9b, .gemma4e4b, .phi4mini, .ministral3b, .ruAdapt4b,
        .lfm25,
    ]

    var displayName: String {
        switch self {
        case .voiceScribe: return "VoiceScribe V15 R-3"
        case .qwen35_4b: return "Qwen3.5-4B Q6_K"
        case .ruAdapt4b: return "RuAdapt Qwen3-4B Q6_K"
        case .qvikhr4b: return "QVikhr-3-4B Q6_K"
        case .ministral3b: return "Ministral-3-3B Q6_K"
        case .phi4mini: return "Phi-4-mini Q6_K"
        case .loqira: return "Loqira Q4_0"
        case .vanilla08b: return "Qwen3.5-0.8B Q6_K (vanilla)"
        case .lfm25: return "LFM2.5-2.6B Q6_K"
        case .yandexGPT: return "YandexGPT 5 Lite 8B Q4_K_M"
        case .qwen35_9b: return "Qwen3.5-9B Q4_K_M"
        case .gemma4e4b: return "Gemma 4 E4B Q4_0"
        }
    }

    /// One-line benchmark digest for the settings UI (locale-neutral
    /// numbers; the surrounding text is localized in ControlPanel).
    var benchmarkSummary: String {
        switch self {
        case .voiceScribe: return "EM 0.600 · ~0,2 s · 0.7 GB"
        case .qwen35_4b: return "EM 0.723 · ~0,55 s · 3.8 GB"
        case .ruAdapt4b: return "EM 0.677 · ~0,38 s · 3.3 GB"
        case .qvikhr4b: return "EM 0.600 · ~0,48 s · 3.3 GB"
        case .ministral3b: return "EM 0.585 · ~0,38 s · 2.8 GB"
        case .phi4mini: return "EM 0.538 · ~0,34 s · 3.2 GB"
        case .loqira: return "EM 0.462 · ~0,18 s · 0.6 GB"
        case .vanilla08b: return "EM 0.369 · ~0,21 s · 0.7 GB"
        case .lfm25: return "EM 0.246 · ~10,8 s · 2.2 GB"
        case .yandexGPT: return "EM 0.892 · FactRec 0.527 · 4.9 GB"
        case .qwen35_9b: return "FactRec 0.489 · ~3,2 s · 5.7 GB"
        case .gemma4e4b: return "FactRec 0.483 · ~2,3 s · 5.2 GB"
        }
    }

    /// Only VoiceScribe is the base-weights + LoRA pair (see ModelDownload's
    /// GEC_LORA_* pins); every other model is a single standalone GGUF.
    var usesLoRAAdapter: Bool { self == .voiceScribe }

    /// Only VoiceScribe was benchmark-validated with the few-shot
    /// VoiceScribe-tuned prompt; every other (instruct) model gets the
    /// benchmark's zero-shot correction prompt.
    var usesFewShotCorrectionPrompt: Bool { self == .voiceScribe }

    /// Loqira is a GEC fine-tune with a MANDATORY system prompt — its
    /// training format must not be overridden by the user (the settings UI
    /// shows the prompt read-only for this model).
    var allowsCustomSystemPrompt: Bool { self != .loqira }

    // NB on thinking mode: NO model needs launch flags to suppress it.
    // The bundled SuperDictateLLMHost helper hardcodes
    // COMMON_REASONING_FORMAT_NONE and reads enable_thinking from the
    // request's chat_template_kwargs — which our client always sends as
    // false (see llama_cpp_host/bridge/superdictate_llm_host_main.cpp).
    // The benchmark's `--reasoning-format none` was a llama-SERVER flag;
    // passing it to the helper makes the host exit at startup ("unknown
    // argument") and every dictation passes through uncorrected.

    /// llama.cpp context window for this model's host. Models that serve
    /// the rewrite pass: 8192 — rewrite-style outputs on long dictations
    /// need prompt + up to ~3072 completion tokens inside one window.
    /// Correction-only small models: 4096 (as benchmarked).
    var hostContextSize: Int32 {
        BundledLLMModel.rewriteModels.contains(self) ? 8192 : 4096
    }

    /// Chat-template override passed to the host (--chat-template-file).
    /// LFM2.5-2.6B is a "pure reasoning model" whose template hard-codes a
    /// `<think>` tag into every generation prompt (its own model card:
    /// "always thinks before it answers") — the benchmark's 10.8 s p50 was
    /// exactly that thinking, and `enable_thinking: false` is ignored by
    /// this template. The override is the SAME template with `<think>`
    /// removed from the generation prompt, so the model answers directly.
    /// nil = use the model's built-in template.
    var chatTemplateOverride: String? {
        switch self {
        case .lfm25:
            return LFM25NoThinkChatTemplate.template
        default:
            return nil
        }
    }
}

/// The LFM2.5-2.6B chat template with the forced `<think>` tag removed
/// from the generation prompt (see BundledLLMModel.chatTemplateOverride).
private enum LFM25NoThinkChatTemplate {
    /// The LFM2.5-2.6B chat template with the forced `<think>` tag
    /// removed from the generation prompt (see chatTemplateOverride).
    static let template: String = #"""
{{- bos_token -}}
{%- set preserve_thinking = preserve_thinking | default(false) -%}

{%- macro format_arg_value(arg_value) -%}
    {%- if arg_value is string -%}
        {{- "'" + (arg_value | replace("\\", "\\\\") | replace("'", "\\'") | replace("\n", "\\n") | replace("\r", "\\r")) + "'" -}}
    {%- elif arg_value is mapping or arg_value is iterable -%}
        {{- arg_value | tojson -}}
    {%- else -%}
        {{- arg_value | string -}}
    {%- endif -%}
{%- endmacro -%}

{%- macro parse_content(content) -%}
    {%- if content is string -%}
        {{- content -}}
    {%- elif content is mapping -%}
        {{- content | tojson -}}
    {%- elif content is iterable -%}
        {%- set _ns = namespace(result="") -%}
        {%- for item in content -%}
            {%- if item is string -%}
                {%- set _ns.result = _ns.result + item -%}
            {%- elif item is mapping and item.get("type") == "image" -%}
                {%- set _ns.result = _ns.result + "<image>" -%}
            {%- elif item is mapping and item.get("type") == "text" -%}
                {%- set _ns.result = _ns.result + ((item.get("text") or "") | string) -%}
            {%- else -%}
                {%- set _ns.result = _ns.result + (item | tojson) -%}
            {%- endif -%}
        {%- endfor -%}
        {{- _ns.result -}}
    {%- endif -%}
{%- endmacro -%}

{%- macro render_tool_calls(tool_calls) -%}
    {%- set tool_calls_ns = namespace(tool_calls=[]) -%}
    {%- for tool_call in tool_calls -%}
        {%- set func = tool_call["function"] if "function" in tool_call else tool_call -%}
        {%- set func_name = func["name"] -%}
        {%- set func_args = func.get("arguments") -%}
        {%- set args_ns = namespace(arg_strings=[]) -%}
        {%- if func_args is mapping -%}
            {%- for arg_name, arg_value in func_args.items() -%}
                {%- set args_ns.arg_strings = args_ns.arg_strings + [arg_name + "=" + format_arg_value(arg_value)] -%}
            {%- endfor -%}
        {%- elif func_args is string and (func_args | trim) not in ["", "{}", "null"] -%}
            {{- raise_exception("Tool call arguments must be a mapping, got a JSON-encoded string: parse arguments with json.loads() before applying the chat template") -}}
        {%- endif -%}
        {%- set tool_calls_ns.tool_calls = tool_calls_ns.tool_calls + [func_name + "(" + (args_ns.arg_strings | join(", ")) + ")"] -%}
    {%- endfor -%}
    {{- "<|tool_call_start|>[" + (tool_calls_ns.tool_calls | join(", ")) + "]<|tool_call_end|>" -}}
{%- endmacro -%}

{%- set ns = namespace(system_prompt="", last_user_index=-1) -%}
{%- if messages and messages[0]["role"] == "system" -%}
    {%- if messages[0].get("content") -%}
        {%- set ns.system_prompt = parse_content(messages[0]["content"]) -%}
    {%- endif -%}
    {%- set messages = messages[1:] -%}
{%- endif -%}
{%- if tools -%}
    {%- set ns.system_prompt = ns.system_prompt + ("\n" if ns.system_prompt else "") + "List of tools: [" -%}
    {%- for tool in tools -%}
        {%- if tool is not string -%}
            {%- set tool = tool | tojson -%}
        {%- endif -%}
        {%- set ns.system_prompt = ns.system_prompt + tool -%}
        {%- if not loop.last -%}
            {%- set ns.system_prompt = ns.system_prompt + ", " -%}
        {%- endif -%}
    {%- endfor -%}
    {%- set ns.system_prompt = ns.system_prompt + "]" -%}
{%- endif -%}
{%- if ns.system_prompt -%}
    {{- "<|im_start|>system\n" + ns.system_prompt + "<|im_end|>\n" -}}
{%- endif -%}
{%- for message in messages -%}
    {%- if message["role"] == "user" -%}
        {%- set ns.last_user_index = loop.index0 -%}
    {%- endif -%}
{%- endfor -%}
{%- for message in messages -%}
    {{- "<|im_start|>" + message.role + "\n" -}}
    {%- if message.role == "assistant" -%}
        {%- generation -%}
        {%- set keep_thinking = preserve_thinking or loop.index0 > ns.last_user_index -%}
        {%- set thinking = message.thinking or message.reasoning or message.reasoning_content -%}
        {%- set thinking = thinking if thinking is string else "" -%}
        {%- if thinking and keep_thinking -%}
            {{- "<think>" + thinking + "</think>" -}}
        {%- endif -%}
        {%- set _cfm_tag = "CONTINUE_FINAL_MESSAGE_TAG " -%}
        {%- set _has_cfm = false -%}
        {%- set content = "" -%}
        {%- if message.get("content") -%}
            {%- set content = parse_content(message.content) -%}
        {%- endif -%}
        {%- if not keep_thinking and "</think>" in content -%}
            {%- set content = content.split("</think>")[-1] | trim -%}
        {%- endif -%}
        {%- if content.endswith(_cfm_tag) -%}
            {%- set _has_cfm = true -%}
            {%- set _trunc_len = (content | length) - (_cfm_tag | length) -%}
            {%- set content = content[:_trunc_len] -%}
        {%- endif -%}
        {{- content -}}
        {%- if message.tool_calls -%}
            {{- render_tool_calls(message.tool_calls) -}}
        {%- endif -%}
        {%- if _has_cfm -%}
            {{- _cfm_tag -}}
        {%- endif -%}
        {{- "<|im_end|>\n" -}}
        {%- endgeneration -%}
    {%- else %}
        {%- if message.get("content") -%}
            {{- parse_content(message["content"]) -}}
        {%- endif -%}
        {{- "<|im_end|>\n" -}}
    {%- endif %}
{%- endfor -%}
{%- if add_generation_prompt -%}
    {{- "<|im_start|>assistant\n" -}}
{%- endif -%}
"""#
}


/// Correction pass model setting. Defaults to `.voiceScribe` (the
/// benchmark's best fast correction model). Migration from the retired
/// tier setting (`correction_model_tier_v1`): "fast" → .voiceScribe,
/// "quality" → .yandexGPT (the benchmark correction winner, offered in
/// the correction picker).
func normalizedCorrectionBundledModel(rawValue: String?, legacyTier: String?) -> BundledLLMModel {
    if let rawValue, let model = BundledLLMModel(rawValue: rawValue),
       BundledLLMModel.correctionModels.contains(model) {
        return model
    }
    switch legacyTier {
    case "quality": return .yandexGPT
    default: return .voiceScribe
    }
}

/// Rewrite pass model setting. Defaults to `.yandexGPT` (benchmark
/// winner). Migration from the retired picker (`rewrite_bundled_model_v1`):
/// "voicescribe" is no longer offered for rewrite (small class; the report
/// shows it compresses output to 0.6×) → the recommended .yandexGPT.
func normalizedRewriteBundledModel(rawValue: String?, legacyModel: String?) -> BundledLLMModel {
    if let rawValue, let model = BundledLLMModel(rawValue: rawValue),
       BundledLLMModel.rewriteModels.contains(model) {
        return model
    }
    if legacyModel == BundledLLMModel.yandexGPT.rawValue {
        return .yandexGPT
    }
    return .yandexGPT
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

/// A user-created rewrite mode: name, identity color, LLM instruction and
/// an optional activation hotkey (docs/specs/custom-rewrite-styles-spec.md).
/// Stored as a JSON array in `rewrite_custom_styles_v1`.
struct CustomRewriteStyle: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    /// Identity color for the state toast, "#RRGGBB".
    var colorHex: String
    /// Mode-specific instruction appended after the shared
    /// fact-preservation base in the system prompt.
    var instruction: String
    /// Activation hotkey; keycode 0 = not assigned.
    var hotkeyKeycode: Int
    var hotkeyModifiers: UInt64
}

/// The active rewrite style: either a built-in or a user-created one.
/// Both share the `rewrite_style_v1` key's value space (built-in raw
/// values + `c-<uuid>` for customs), so no migration is needed.
enum RewriteStyleSelection: Equatable {
    case builtin(RewriteStyle)
    case custom(CustomRewriteStyle)

    var id: String {
        switch self {
        case .builtin(let style): return style.rawValue
        case .custom(let custom): return custom.id
        }
    }

    var displayName: String {
        switch self {
        case .builtin(let style): return style.displayName
        case .custom(let custom): return custom.name
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

func normalizedRewriteStyle(rawValue: String?) -> RewriteStyle {
    guard let rawValue, let style = RewriteStyle(rawValue: rawValue) else {
        return .polish
    }
    return style
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
