"""Persistent settings.

macOS leans on ``NSUserDefaults``; the Windows port writes one JSON file
with the same key set, atomically (temp file + ``os.replace``) so a crash
mid-write can never truncate the user's configuration. Every getter has an
inline default, matching the macOS ``Settings`` class where a missing key
returns the default rather than being pre-registered.
"""

from __future__ import annotations

import json
import os
import threading
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Optional

from . import paths
from .hotkeys import (
    DEFAULT_CORRECTION_HOTKEY,
    DEFAULT_EDIT_HOTKEY,
    DEFAULT_HISTORY_HOTKEY,
    DEFAULT_HOTKEY,
    DEFAULT_REWRITE_HOTKEY,
    DEFAULT_REWRITE_STYLE_HOTKEY,
    DEFAULT_ENTER_HOTKEY,
    HotkeyChoice,
    TriggerMode,
)


class CompletionBehavior(str, Enum):
    INSERT = "insert"
    INSERT_AND_ENTER = "insert_and_enter"

    @property
    def presses_enter(self) -> bool:
        return self is CompletionBehavior.INSERT_AND_ENTER

    @property
    def opposite(self) -> "CompletionBehavior":
        """What the alternate finish does (macOS DictationCompletionBehavior.opposite)."""
        return (CompletionBehavior.INSERT_AND_ENTER if self is CompletionBehavior.INSERT
                else CompletionBehavior.INSERT)


class TextStyle(str, Enum):
    """How much punctuation the inserted text keeps.

    The model always returns a fully punctuated sentence. Chat and code
    comments rarely want that, so the looser styles trim it back.
    """

    FORMAL = "formal"          # exactly what the model produced
    STANDARD = "standard"      # no full stop at the end
    INFORMAL = "informal"      # no full stop, and no leading capital
    CASUAL = "casual"          # the above, plus no full stops inside either


class PasteSuffix(str, Enum):
    SPACE = "space"
    NONE = "none"
    NEWLINE = "newline"

    @property
    def text(self) -> str:
        return {"space": " ", "none": "", "newline": "\n"}[self.value]


class HUDDisplayMode(str, Enum):
    """What the capsule shows while a dictation is running.

    ``TIMER_OUTLINE`` does not replace the bars outright: the capsule opens
    as bars either way and crosses over to the timer once the dictation has
    lasted long enough to be worth timing. Values match the macOS setting.
    """

    LEVEL_BARS = "levelBars"
    TIMER_OUTLINE = "timerOutline"


class HUDBackgroundStyle(str, Enum):
    """The capsule's own fill. ``SYSTEM`` follows the Windows app theme.

    Values match the macOS ``RecordingHUDBackgroundStyle``.
    """

    SYSTEM = "system"
    DARK = "dark"
    LIGHT = "light"


class HUDSize(str, Enum):
    COMPACT = "compact"
    STANDARD = "standard"
    LARGE = "large"

    @property
    def scale(self) -> float:
        return {"compact": 1.15, "standard": 1.5, "large": 1.85}[self.value]


class AccentColor(str, Enum):
    RED = "red"
    ORANGE = "orange"
    PINK = "pink"
    PURPLE = "purple"
    BLUE = "blue"
    CYAN = "cyan"
    GREEN = "green"
    WHITE = "white"
    # Black on a light capsule, white on a dark one: the only preset that
    # depends on the background, exactly as on macOS.
    CONTRAST = "contrast"

    @property
    def rgb(self) -> tuple[int, int, int]:
        return {
            "red": (255, 69, 58),
            "orange": (255, 159, 10),
            "pink": (255, 55, 95),
            "purple": (191, 90, 242),
            "blue": (0, 112, 255),
            "cyan": (100, 210, 255),
            "green": (48, 209, 88),
            "white": (255, 255, 255),
            "contrast": (255, 255, 255),
        }[self.value]

    @property
    def hex(self) -> str:
        return "#%02x%02x%02x" % self.rgb


@dataclass(frozen=True)
class ColorSpec:
    """A capsule colour: one colour, or two for a gradient.

    Stored as a string so the settings file stays readable and older
    files keep working: a preset is its own name (``"red"``), a picked
    colour is ``"#ff4536"``, and a gradient is the two joined by a pipe.
    """

    start: str
    end: Optional[str] = None

    @property
    def is_gradient(self) -> bool:
        return bool(self.end)

    @property
    def is_contrast(self) -> bool:
        return self.start == CONTRAST_COLOR

    def resolved(self, light_background: bool) -> "ColorSpec":
        """Literal colours only: ``contrast`` becomes black or white."""
        ink = "#000000" if light_background else "#ffffff"
        return ColorSpec(ink if self.start == CONTRAST_COLOR else self.start,
                         ink if self.end == CONTRAST_COLOR else self.end)

    @property
    def rgb(self) -> tuple[int, int, int]:
        raw = self.start.lstrip("#")
        return tuple(int(raw[i:i + 2], 16) for i in (0, 2, 4))  # type: ignore[return-value]

    def to_json(self) -> str:
        return f"{self.start}|{self.end}" if self.end else self.start

    @classmethod
    def parse(cls, raw: Any, fallback: "ColorSpec") -> "ColorSpec":
        if not isinstance(raw, str) or not raw.strip():
            return fallback
        parts = [cls._resolve(part) for part in raw.split("|", 1)]
        if parts[0] is None:
            return fallback
        end = parts[1] if len(parts) > 1 else None
        return cls(parts[0], end)

    @staticmethod
    def _resolve(raw: str) -> Optional[str]:
        """A preset name or a #rrggbb literal, normalised to a literal."""
        value = raw.strip().lower()
        if value == CONTRAST_COLOR:
            # Kept symbolic: what it resolves to depends on the capsule.
            return CONTRAST_COLOR
        try:
            return AccentColor(value).hex
        except ValueError:
            pass
        if len(value) == 7 and value.startswith("#"):
            try:
                int(value[1:], 16)
            except ValueError:
                return None
            return value
        return None

    @classmethod
    def of(cls, color: AccentColor) -> "ColorSpec":
        if color is AccentColor.CONTRAST:
            return cls(CONTRAST_COLOR)
        return cls(color.hex)


CONTRAST_COLOR = AccentColor.CONTRAST.value


# Matches the macOS DictationLanguage enum: the 25-language Parakeet TDT v3
# decoder, narrowed to the languages the macOS UI exposes.
DICTATION_LANGUAGES: list[tuple[str, str]] = [
    ("auto", "Автоопределение / Auto-detect"),
    ("en", "English"),
    ("es", "Español"),
    ("fr", "Français"),
    ("de", "Deutsch"),
    ("it", "Italiano"),
    ("pt", "Português"),
    ("ro", "Română"),
    ("pl", "Polski"),
    ("cs", "Čeština"),
    ("sk", "Slovenčina"),
    ("sl", "Slovenščina"),
    ("hr", "Hrvatski"),
    ("bs", "Bosanski"),
    ("ru", "Русский"),
    ("uk", "Українська"),
    ("be", "Беларуская"),
    ("bg", "Български"),
    ("sr", "Српски"),
]

RECENT_LIMITS = ["off", "1", "5", "10"]
DEFAULT_RECENT_LIMIT = "10"
HISTORY_ARCHIVE_MAX_ENTRIES = 200


@dataclass
class Correction:
    source: str
    replacement: str

    def to_json(self) -> dict:
        return {"source": self.source, "replacement": self.replacement}


# Which of the offered filler words are removed until the user says
# otherwise. Hesitation sounds only: they cannot be anything but
# hesitation. Everything else on the list — "это", "вот", "короче", "like"
# — is an ordinary word doing filler duty, and deleting those uninvited
# would quietly change what somebody said.
DEFAULT_FILLER_WORDS: tuple[str, ...] = (
    "э", "эм", "ээ", "м", "мм", "ам", "аа",
    "um", "uh", "ah", "er", "erm", "hm",
)


_DEFAULTS: dict[str, Any] = {
    "hotkey": DEFAULT_HOTKEY.to_json(),
    "history_hotkey": DEFAULT_HISTORY_HOTKEY.to_json(),
    "edit_hotkey": DEFAULT_EDIT_HOTKEY.to_json(),
    "correction_hotkey": DEFAULT_CORRECTION_HOTKEY.to_json(),
    "rewrite_hotkey": DEFAULT_REWRITE_HOTKEY.to_json(),
    "rewrite_style_hotkey": DEFAULT_REWRITE_STYLE_HOTKEY.to_json(),
    # The alternate finish: pressed mid-recording, it ends the recording
    # the other way (paste + Enter when the primary shortcut only pastes).
    # Same idea and defaults as macOS enterHotkey / alternate_completion_enabled_v1.
    "enter_hotkey": DEFAULT_ENTER_HOTKEY.to_json(),
    "alternate_completion_enabled": True,
    "primary_completion_behavior": CompletionBehavior.INSERT.value,
    "text_style": TextStyle.FORMAL.value,
    "interface_language": "ru",
    "trigger_mode": TriggerMode.TOGGLE.value,
    "paste_suffix": PasteSuffix.SPACE.value,
    "enter_delay_milliseconds": 120,
    "recent_transcript_limit": DEFAULT_RECENT_LIMIT,
    "show_recording_waveform": True,
    "live_preview": True,
    "hud_recording_color": AccentColor.RED.value,
    "hud_transcribing_color": AccentColor.BLUE.value,
    # The second accent of the AI-improvement animation: the bars run from
    # the transcribing colour to this one. macOS defaults to purple too.
    "hud_correcting_color": AccentColor.PURPLE.value,
    "hud_background_style": HUDBackgroundStyle.SYSTEM.value,
    "hud_size": HUDSize.STANDARD.value,
    # The timer, unlike macOS: this is how the port is meant to be used,
    # and the setting does not travel from the Mac. Installs from before
    # this default are moved over once, in load().
    "hud_display_mode": HUDDisplayMode.TIMER_OUTLINE.value,
    "hud_timer_default_v1": True,
    "mute_while_recording": False,
    "pause_media_while_recording": False,
    "play_feedback_sounds": True,
    "input_device": "",  # empty = system default
    "check_for_updates": True,
    "dictation_language": "auto",
    "remove_filler_words": False,
    "filler_words": list(DEFAULT_FILLER_WORDS),
    "numbers_as_digits": True,
    "stop_on_silence": False,
    "silence_stop_seconds": 2.5,
    "start_at_login": False,
    # Which speech model runs. Same key and values as the macOS build.
    # The GPU belongs to the LLM stages, which is why the LLM device below
    # is its own setting.
    "speech_model_profile": "parakeet_ultra_onnx",  # parakeet_ultra_onnx | gigaam_v3_onnx
    # Where recognition runs, Windows only: cpu (ONNX Runtime in
    # SuperDictateOnnxHost) | npu (OpenVINO in SuperDictateOvHost, offered
    # only on machines with an Intel NPU). Same profile either way; the NPU
    # runs its own OpenVINO build of that model.
    "speech_compute_backend": "cpu",
    # LLM only: gpu | cpu. CPU until the user opts in, as on macOS
    # (llmUseGPU): a GPU that computes wrong gives fluent-looking garbage,
    # and the CPU path is the one that is right everywhere.
    "llm_compute_backend": "cpu",

    # -- LLM post-processing ------------------------------------------
    # Key names match the macOS build's UserDefaults keys exactly, so the
    # two platforms stay comparable and a support answer transfers. Every
    # *_system_prompt_* value is empty until the user actually edits it;
    # empty means "use the built-in prompt", never "no prompt".
    "text_postprocessing_mode_v1": "off",       # off | correction
    "llm_engine_backend_v1": "bundledLocal",    # bundledLocal | customEndpoint
    "correction_bundled_model_v2": "voicescribe",
    "correction_system_prompt_v1": "",
    "llm_custom_base_url_v1": "",
    "llm_custom_api_key_v1": "",
    "llm_custom_model_name_v1": "",
    # Internet endpoints go through the system proxy when this is on; LAN
    # addresses (127.0.0.1, 192.168.x.x, 10.x.x.x, *.local) never do.
    "llm_use_system_proxy_v1": True,

    "rewrite_enabled_v1": False,
    # Punctuation restoration, the last text stage (punctuation.py).
    "punctuation_restoration_enabled_v1": False,
    "punctuation_model_v1": "base",
    "rewrite_engine_backend_v1": "bundledLocal",
    "local_rewrite_v1": False,                  # migration marker, see load()
    "rewrite_bundled_model_v2": "yandexgpt",
    "rewrite_style_v1": "official",             # polish | structured_task | official
    "rewrite_custom_styles_v1": [],
    "rewrite_custom_style_id_v1": "",
    "rewrite_system_prompt_polish_v1": "",
    "rewrite_system_prompt_structured_task_v1": "",
    "rewrite_system_prompt_official_v1": "",
    "rewrite_custom_base_url_v1": "",
    "rewrite_custom_api_key_v1": "",
    "rewrite_custom_model_name_v1": "",
    # ASR hotwords (docs/specs/asr-hotwords-spec.md §8): the vocabulary's
    # terms are handed to the speech model itself. normal = 2.0, strong = 3.0.
    "asr_hotwords_enabled": True,
    "asr_hotwords_strength": "normal",
    # Account sync of the vocabulary (vocabulary-hygiene-and-sync spec §4).
    # Everything but the server URL is written by the sync itself, never
    # by the settings window's draft (see _RUNTIME_KEYS). The token is not
    # here: it lives DPAPI-protected next to this file (vocabulary_sync).
    "vocabulary_sync_enabled": False,
    "vocabulary_sync_server_url": "https://superdictate.bykovlegal.ru",
    "vocabulary_sync_email": "",
    "vocabulary_sync_last_server_revision": 0,
    "vocabulary_sync_last_pushed_local_stamp": "",
    "vocabulary_sync_last_synced_at": 0.0,
    "last_seen_version": "",
    "skipped_versions": [],
    "update_reminder_paused_version": "",
    "update_reminder_paused_until": 0.0,
}


#: Written by the app while it runs, never by the settings window: its
#: draft is a snapshot taken when it opened, and saving that would roll
#: back a sign-in or the sync cursors that happened meanwhile.
_RUNTIME_KEYS = frozenset({
    "vocabulary_sync_enabled",
    "vocabulary_sync_email",
    "vocabulary_sync_last_server_revision",
    "vocabulary_sync_last_pushed_local_stamp",
    "vocabulary_sync_last_synced_at",
})


class Settings:
    def __init__(self, path: Optional[os.PathLike] = None) -> None:
        self._path = paths.SETTINGS_FILE if path is None else path
        self._lock = threading.RLock()
        self._data: dict[str, Any] = dict(_DEFAULTS)
        self.load()

    # -- persistence -------------------------------------------------

    def load(self) -> None:
        try:
            with open(self._path, "r", encoding="utf-8") as handle:
                stored = json.load(handle)
        except (OSError, ValueError):
            return
        if not isinstance(stored, dict):
            return
        with self._lock:
            for key, value in stored.items():
                if key in _DEFAULTS:
                    self._data[key] = value
            # Every key is written on save, so a stored "levelBars" from
            # before the timer became the default is the old default, not
            # a choice. Moved once; picking the bars afterwards sticks.
            if "hud_timer_default_v1" not in stored:
                self._data["hud_display_mode"] = HUDDisplayMode.TIMER_OUTLINE.value
                self._data["hud_timer_default_v1"] = True
            # Until 0.9.1 the rewrite always went to the endpoint, so the
            # stored "bundledLocal" was never anyone's choice. Someone who
            # set an endpoint up keeps it rather than being moved to a local
            # model they have not downloaded.
            if "local_rewrite_v1" not in stored:
                if str(self._data.get("rewrite_custom_base_url_v1") or "").strip():
                    self._data["rewrite_engine_backend_v1"] = "customEndpoint"
                self._data["local_rewrite_v1"] = True

    def save(self) -> None:
        paths.ensure_directories()
        with self._lock:
            snapshot = dict(self._data)
        temp = f"{self._path}.tmp"
        try:
            with open(temp, "w", encoding="utf-8") as handle:
                json.dump(snapshot, handle, ensure_ascii=False, indent=2)
            os.replace(temp, self._path)
        except OSError:
            try:
                os.unlink(temp)
            except OSError:
                pass

    def _get(self, key: str) -> Any:
        with self._lock:
            return self._data.get(key, _DEFAULTS[key])

    def _set(self, key: str, value: Any) -> None:
        with self._lock:
            self._data[key] = value

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            return dict(self._data)

    def apply(self, changes: dict[str, Any]) -> None:
        """Apply a whole draft at once, the macOS `Save and restart` flow."""
        with self._lock:
            for key, value in changes.items():
                if key in _DEFAULTS and key not in _RUNTIME_KEYS:
                    self._data[key] = value
        self.save()

    def update_runtime(self, changes: dict[str, Any]) -> None:
        """Write keys the app itself owns (the sync state) and save."""
        with self._lock:
            for key, value in changes.items():
                if key in _DEFAULTS:
                    self._data[key] = value
        self.save()

    # -- typed accessors ---------------------------------------------

    @property
    def hotkey(self) -> HotkeyChoice:
        return HotkeyChoice.from_json(self._get("hotkey"), DEFAULT_HOTKEY)

    @property
    def history_hotkey(self) -> HotkeyChoice:
        return HotkeyChoice.from_json(self._get("history_hotkey"),
                                      DEFAULT_HISTORY_HOTKEY)

    @property
    def edit_hotkey(self) -> HotkeyChoice:
        return HotkeyChoice.from_json(self._get("edit_hotkey"), DEFAULT_EDIT_HOTKEY)

    @property
    def correction_hotkey(self) -> HotkeyChoice:
        return HotkeyChoice.from_json(self._get("correction_hotkey"),
                                      DEFAULT_CORRECTION_HOTKEY)

    @property
    def rewrite_hotkey(self) -> HotkeyChoice:
        return HotkeyChoice.from_json(self._get("rewrite_hotkey"),
                                      DEFAULT_REWRITE_HOTKEY)

    @property
    def rewrite_style_hotkey(self) -> HotkeyChoice:
        return HotkeyChoice.from_json(self._get("rewrite_style_hotkey"),
                                      DEFAULT_REWRITE_STYLE_HOTKEY)

    @property
    def enter_hotkey(self) -> HotkeyChoice:
        return HotkeyChoice.from_json(self._get("enter_hotkey"), DEFAULT_ENTER_HOTKEY)

    @property
    def alternate_completion_enabled(self) -> bool:
        return bool(self._get("alternate_completion_enabled"))

    @property
    def primary_completion_behavior(self) -> CompletionBehavior:
        return _enum_or(CompletionBehavior, self._get("primary_completion_behavior"),
                        CompletionBehavior.INSERT)

    @property
    def text_style(self) -> TextStyle:
        return _enum_or(TextStyle, self._get("text_style"), TextStyle.FORMAL)

    @property
    def interface_language(self) -> str:
        value = self._get("interface_language")
        return value if value in ("ru", "en") else "ru"

    @property
    def trigger_mode(self) -> TriggerMode:
        return _enum_or(TriggerMode, self._get("trigger_mode"), TriggerMode.TOGGLE)

    @property
    def paste_suffix(self) -> PasteSuffix:
        return _enum_or(PasteSuffix, self._get("paste_suffix"), PasteSuffix.SPACE)

    @property
    def enter_delay_milliseconds(self) -> int:
        try:
            return max(0, min(500, int(self._get("enter_delay_milliseconds"))))
        except (TypeError, ValueError):
            return 120

    @property
    def recent_transcript_limit(self) -> int:
        raw = str(self._get("recent_transcript_limit"))
        return {"off": 0, "1": 1, "5": 5, "10": 10}.get(raw, 10)

    @property
    def show_recording_waveform(self) -> bool:
        return bool(self._get("show_recording_waveform"))

    @property
    def live_preview(self) -> bool:
        return bool(self._get("live_preview"))

    @property
    def hud_recording_color(self) -> ColorSpec:
        return ColorSpec.parse(self._get("hud_recording_color"),
                               ColorSpec.of(AccentColor.RED))

    @property
    def hud_transcribing_color(self) -> ColorSpec:
        return ColorSpec.parse(self._get("hud_transcribing_color"),
                               ColorSpec.of(AccentColor.BLUE))

    @property
    def hud_correcting_color(self) -> ColorSpec:
        return ColorSpec.parse(self._get("hud_correcting_color"),
                               ColorSpec.of(AccentColor.PURPLE))

    @property
    def hud_background_style(self) -> HUDBackgroundStyle:
        return _enum_or(HUDBackgroundStyle, self._get("hud_background_style"),
                        HUDBackgroundStyle.SYSTEM)

    @property
    def hud_size(self) -> HUDSize:
        return _enum_or(HUDSize, self._get("hud_size"), HUDSize.STANDARD)

    @property
    def mute_while_recording(self) -> bool:
        return bool(self._get("mute_while_recording"))

    @property
    def pause_media_while_recording(self) -> bool:
        return bool(self._get("pause_media_while_recording"))

    @property
    def play_feedback_sounds(self) -> bool:
        return bool(self._get("play_feedback_sounds"))

    @property
    def input_device(self) -> str:
        return str(self._get("input_device") or "")

    @property
    def check_for_updates(self) -> bool:
        return bool(self._get("check_for_updates"))

    @property
    def dictation_language(self) -> str:
        value = str(self._get("dictation_language"))
        return value if value in {code for code, _ in DICTATION_LANGUAGES} else "auto"

    @property
    def remove_filler_words(self) -> bool:
        return bool(self._get("remove_filler_words"))

    @property
    def filler_words(self) -> tuple[str, ...]:
        """The words the removal pass acts on, in the order they were stored.

        An empty list is a legitimate answer — somebody who unticks every
        word gets nothing removed — so it is not replaced by the defaults;
        only a value of the wrong shape is.
        """
        raw = self._get("filler_words")
        if not isinstance(raw, list):
            return DEFAULT_FILLER_WORDS
        seen: list[str] = []
        for entry in raw:
            word = str(entry).strip()
            if word and word.lower() not in {w.lower() for w in seen}:
                seen.append(word)
        return tuple(seen)

    @property
    def numbers_as_digits(self) -> bool:
        return bool(self._get("numbers_as_digits"))

    @property
    def stop_on_silence(self) -> bool:
        return bool(self._get("stop_on_silence"))

    @property
    def silence_stop_seconds(self) -> float:
        try:
            return max(1.0, min(10.0, float(self._get("silence_stop_seconds"))))
        except (TypeError, ValueError):
            return 2.5

    @property
    def hud_display_mode(self) -> HUDDisplayMode:
        return _enum_or(HUDDisplayMode, self._get("hud_display_mode"),
                        HUDDisplayMode.TIMER_OUTLINE)

    @property
    def start_at_login(self) -> bool:
        return bool(self._get("start_at_login"))

    @property
    def speech_model_profile(self) -> str:
        value = str(self._get("speech_model_profile"))
        return value if value in ("parakeet_ultra_onnx", "gigaam_v3_onnx") else "parakeet_ultra_onnx"

    @property
    def speech_compute_backend(self) -> str:
        value = str(self._get("speech_compute_backend"))
        return value if value in ("cpu", "npu") else "cpu"

    # -- LLM post-processing ------------------------------------------

    @property
    def llm_compute_backend(self) -> str:
        """Where the post-processing models run. Independent of the ASR one."""
        value = str(self._get("llm_compute_backend"))
        return value if value in ("gpu", "cpu") else "cpu"

    @property
    def llm_gpu_layers(self) -> int:
        """Layers to offload, as llama.cpp counts them.

        99 means "all of them" — the model is a few gigabytes and the card
        it is aimed at has enough room. 0 keeps everything on the CPU.
        There is no partial-offload setting on purpose: it is a tuning knob
        that needs a benchmark to set well, and getting it wrong is slower
        than either end.
        """
        return 99 if self.llm_compute_backend == "gpu" else 0

    @property
    def llm_use_system_proxy(self) -> bool:
        """Whether internet endpoints use the system proxy.

        Local-network endpoints bypass it unconditionally; see
        :mod:`superdictate.llm.host`. Defaults to on, matching the macOS
        build, because a remote provider is commonly only reachable
        through the proxy.
        """
        return bool(self._get("llm_use_system_proxy_v1"))

    @property
    def correction_enabled(self) -> bool:
        return str(self._get("text_postprocessing_mode_v1")) == "correction"

    def _llm_backend(self, key: str):
        """The stored stage backend, or the endpoint when no host ships.

        A build without the local LLM host (``build.ps1 -SkipEngines``)
        cannot run ``bundledLocal`` (the macOS default, kept for key
        compatibility), so there it reads as the custom endpoint.
        """
        from .llm import LLMBackend
        from .llm.host import bundled_host_available

        backend = _enum_or(LLMBackend, self._get(key), LLMBackend.BUNDLED_LOCAL)
        if backend is LLMBackend.BUNDLED_LOCAL and not bundled_host_available():
            return LLMBackend.CUSTOM_ENDPOINT
        return backend

    def correction_config(self):
        """Build the correction stage's config from stored settings."""
        from .llm import BundledLLMModel, CorrectionConfig, CustomEndpoint, LLMBackend
        from .llm.models import CORRECTION_MODELS

        model = _enum_or(BundledLLMModel, self._get("correction_bundled_model_v2"),
                         BundledLLMModel.VOICESCRIBE)
        if model not in CORRECTION_MODELS:
            model = BundledLLMModel.VOICESCRIBE
        return CorrectionConfig(
            enabled=self.correction_enabled,
            backend=self._llm_backend("llm_engine_backend_v1"),
            model=model,
            endpoint=CustomEndpoint(
                base_url=str(self._get("llm_custom_base_url_v1") or ""),
                api_key=str(self._get("llm_custom_api_key_v1") or ""),
                model_name=str(self._get("llm_custom_model_name_v1") or ""),
                use_system_proxy=self.llm_use_system_proxy,
            ),
            system_prompt_override=str(self._get("correction_system_prompt_v1") or ""),
        )

    def set_correction_enabled(self, enabled: bool) -> None:
        """Flip the correction stage from the keyboard, and persist it.

        Writes through immediately rather than waiting for a settings-window
        save: the hotkey IS the commit, and a toggle lost to a crash would
        have the app quietly disagreeing with the toast it just showed.
        """
        self._set("text_postprocessing_mode_v1",
                  "correction" if enabled else "off")
        self.save()

    def set_rewrite_enabled(self, enabled: bool) -> None:
        self._set("rewrite_enabled_v1", bool(enabled))
        self.save()

    def set_rewrite_style(self, style) -> None:
        self._set("rewrite_style_v1", getattr(style, "value", str(style)))
        self.save()

    @property
    def rewrite_enabled(self) -> bool:
        return bool(self._get("rewrite_enabled_v1"))

    @property
    def punctuation_enabled(self) -> bool:
        return bool(self._get("punctuation_restoration_enabled_v1"))

    @property
    def punctuation_model(self) -> str:
        """``"small"`` or ``"base"`` (the default)."""
        value = str(self._get("punctuation_model_v1"))
        return value if value in ("small", "base") else "base"

    def rewrite_config(self):
        """Build the rewrite stage's config from stored settings."""
        from .llm import (BundledLLMModel, CustomEndpoint, LLMBackend,
                          RewriteConfig, RewriteStyle)

        styles = self._get("rewrite_custom_styles_v1")
        custom = {}
        if isinstance(styles, list):
            for entry in styles:
                if isinstance(entry, dict) and entry.get("id"):
                    custom[str(entry["id"])] = {
                        "name": str(entry.get("name", "")),
                        "instruction": str(entry.get("instruction", "")),
                    }
        from .llm.models import REWRITE_MODELS

        model = _enum_or(BundledLLMModel, self._get("rewrite_bundled_model_v2"),
                         BundledLLMModel.YANDEXGPT)
        if model not in REWRITE_MODELS:
            model = BundledLLMModel.YANDEXGPT
        return RewriteConfig(
            enabled=self.rewrite_enabled,
            backend=self._llm_backend("rewrite_engine_backend_v1"),
            model=model,
            style=_enum_or(RewriteStyle, self._get("rewrite_style_v1"),
                           RewriteStyle.OFFICIAL),
            endpoint=CustomEndpoint(
                base_url=str(self._get("rewrite_custom_base_url_v1") or ""),
                api_key=str(self._get("rewrite_custom_api_key_v1") or ""),
                model_name=str(self._get("rewrite_custom_model_name_v1") or ""),
                use_system_proxy=self.llm_use_system_proxy,
            ),
            system_prompt_overrides={
                style: str(self._get(f"rewrite_system_prompt_{style}_v1") or "")
                for style in ("polish", "structured_task", "official")
            },
            custom_styles=custom,
            custom_style_id=str(self._get("rewrite_custom_style_id_v1") or ""),
        )

    # -- ASR hotwords ---------------------------------------------------

    @property
    def asr_hotwords_enabled(self) -> bool:
        return bool(self._get("asr_hotwords_enabled"))

    @property
    def asr_hotwords_strength(self) -> str:
        from .asr_hotwords import DEFAULT_STRENGTH, STRENGTH_SCORES

        value = str(self._get("asr_hotwords_strength") or "")
        return value if value in STRENGTH_SCORES else DEFAULT_STRENGTH

    def asr_hotwords_configuration(self, phrases):
        """What the next dictation sends: ``phrases`` (the store's
        selection) with the chosen weight, or nothing when switched off."""
        from .asr_hotwords import DISABLED, HotwordsConfiguration, strength_score

        if not self.asr_hotwords_enabled:
            return DISABLED
        return HotwordsConfiguration(phrases=tuple(phrases),
                                     score=strength_score(self.asr_hotwords_strength))

    # -- vocabulary sync -------------------------------------------------

    @property
    def vocabulary_sync_enabled(self) -> bool:
        return bool(self._get("vocabulary_sync_enabled"))

    @property
    def vocabulary_sync_server_url(self) -> str:
        url = str(self._get("vocabulary_sync_server_url") or "").strip()
        return url or str(_DEFAULTS["vocabulary_sync_server_url"])

    @property
    def vocabulary_sync_email(self) -> str:
        return str(self._get("vocabulary_sync_email") or "")

    @property
    def vocabulary_sync_last_server_revision(self) -> int:
        try:
            return max(0, int(self._get("vocabulary_sync_last_server_revision") or 0))
        except (TypeError, ValueError):
            return 0

    @property
    def vocabulary_sync_last_pushed_local_stamp(self) -> str:
        return str(self._get("vocabulary_sync_last_pushed_local_stamp") or "")

    @property
    def vocabulary_sync_last_synced_at(self) -> float:
        try:
            return float(self._get("vocabulary_sync_last_synced_at") or 0.0)
        except (TypeError, ValueError):
            return 0.0

    @property
    def last_seen_version(self) -> str:
        return str(self._get("last_seen_version") or "")

    @last_seen_version.setter
    def last_seen_version(self, value: str) -> None:
        self._set("last_seen_version", value)
        self.save()

    @property
    def skipped_versions(self) -> list[str]:
        value = self._get("skipped_versions")
        return [str(v) for v in value] if isinstance(value, list) else []

    def skip_version(self, version: str) -> None:
        versions = self.skipped_versions
        if version not in versions:
            versions.append(version)
        self._set("skipped_versions", versions[-20:])
        self.save()


def _enum_or(enum_cls, raw: Any, fallback):
    try:
        return enum_cls(raw)
    except (ValueError, TypeError):
        return fallback
