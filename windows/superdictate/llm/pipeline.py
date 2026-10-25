"""LLM post-processing: correction, then rewrite.

Port of ``swift/Sources/Parakey/LLMPostprocessingPipeline.swift``.

Two independent stages, either or both of which may be on:

1. **Correction** — fixes ASR slips, casing, punctuation and, above all,
   restores canonical Latin spelling for foreign terms the model heard in
   Cyrillic. Tiered: a fast 0.8B+LoRA host, or the 8B quality tier.
2. **Rewrite** — allowed to restructure: drop repeats, regroup thoughts,
   change register. Runs second, on the corrected text.

**Failure policy, every branch: post-processing must never lose or block
the user's dictated text.** Model not downloaded, host would not start,
request timed out, custom endpoint misconfigured — each falls back to
returning that stage's input unchanged, logged and never surfaced as a
blocking error. A dictation that arrives uncorrected is a worse dictation;
a dictation that does not arrive is a bug.

What this module deliberately does NOT do is foreign-term normalization
from a hardcoded dictionary. That already happened, before anything here
runs, through the user's own learned vocabulary
(:mod:`superdictate.textproc`). The macOS build tried a second parallel
term list here and rejected it; see its prompts file for why.
"""

from __future__ import annotations

import threading
import time
from dataclasses import dataclass
from enum import Enum
from typing import Callable, Optional

from ..logging_setup import get as get_logger
from . import guardrail, prompts
from .download import is_present
from .host import LLMHostError, LLMHostPool, HostSpec, chat_completion
from .models import BundledLLMModel, LLMBackend, profile
from .prompts import Message, RewriteStyle, Role

log = get_logger("llm.pipeline")

#: How long a host with nothing left to do is kept warm. Quick hotkey
#: on/off toggles then reuse an already-loaded model instead of paying its
#: multi-second reload every time, while sustained disuse still frees the
#: VRAM.
UNLOAD_DELAY_SECONDS = 10 * 60


class PostprocessingMode(str, Enum):
    """What the correction stage does. Values match the macOS setting.

    The macOS build keeps this as a mode rather than a boolean because the
    stage historically also had a rewrite setting folded into it; the two
    are independent now, but the stored value stays compatible.
    """

    OFF = "off"
    CORRECTION = "correction"


@dataclass
class CustomEndpoint:
    """A user-supplied OpenAI-compatible endpoint."""

    base_url: str = ""
    api_key: str = ""
    model_name: str = ""
    #: Internet endpoints honour the system proxy unless this is off.
    #: Local-network endpoints (loopback, private LAN addresses) always go
    #: direct, whatever this says.
    use_system_proxy: bool = True

    #: What the request names when the user left the model empty — the
    #: macOS default, which most OpenAI-compatible local servers ignore.
    DEFAULT_MODEL_NAME = "gpt-4o-mini"

    @property
    def is_configured(self) -> bool:
        return bool(self.base_url.strip())

    @property
    def effective_model_name(self) -> str:
        return self.model_name.strip() or self.DEFAULT_MODEL_NAME


@dataclass
class CorrectionConfig:
    enabled: bool = False
    backend: LLMBackend = LLMBackend.BUNDLED_LOCAL
    model: BundledLLMModel = BundledLLMModel.VOICESCRIBE
    endpoint: CustomEndpoint = None  # type: ignore[assignment]
    #: Empty means "use the built-in prompt", exactly as on macOS, where a
    #: value is stored only after the user actually edits it.
    system_prompt_override: str = ""

    def __post_init__(self) -> None:
        if self.endpoint is None:
            self.endpoint = CustomEndpoint()


@dataclass
class RewriteConfig:
    enabled: bool = False
    backend: LLMBackend = LLMBackend.BUNDLED_LOCAL
    model: BundledLLMModel = BundledLLMModel.YANDEXGPT
    style: RewriteStyle = RewriteStyle.OFFICIAL
    endpoint: CustomEndpoint = None  # type: ignore[assignment]
    #: Per-style overrides, keyed by style value. Empty string = built-in.
    system_prompt_overrides: dict = None  # type: ignore[assignment]
    #: User-created modes: ``{"id": {"name": ..., "instruction": ...}}``.
    custom_styles: dict = None  # type: ignore[assignment]
    #: Which custom mode is selected, if any. Empty = a built-in style.
    custom_style_id: str = ""

    def __post_init__(self) -> None:
        if self.endpoint is None:
            self.endpoint = CustomEndpoint()
        if self.system_prompt_overrides is None:
            self.system_prompt_overrides = {}
        if self.custom_styles is None:
            self.custom_styles = {}


class LLMPostprocessor:
    """Owns the host pool and applies the enabled stages to one transcript.

    Thread-affine only in the sense that the host pool serializes starts;
    ``finalize`` itself is safe to call from the transcription worker
    thread, which is where the app calls it from — never from the UI thread,
    since a cold 8B load blocks for tens of seconds.
    """

    def __init__(self) -> None:
        self._pool = LLMHostPool()
        self._lock = threading.RLock()
        self._unload_timer: Optional[threading.Timer] = None
        #: Called with a short stage description when a COLD host start
        #: begins, and with no arguments when it finishes. Loading a
        #: multi-GB model takes tens of seconds on first use, and without
        #: this the user watches the correcting HUD with no idea anything is
        #: happening.
        self.on_load_stage: Optional[Callable[[str], None]] = None
        self.on_load_finished: Optional[Callable[[], None]] = None
        #: Called with the model whose weights are missing, once per model
        #: per session. The UI turns this into an offer to download; saying
        #: it on every dictation would be nagging, not helping.
        self.on_model_missing: Optional[Callable[[BundledLLMModel], None]] = None
        self._reported_missing: set = set()
        #: How many layers the host offloads. Set from settings, and kept
        #: separate from the ASR engine's device: the two are independent
        #: choices, and on real hardware the right answer differs — Parakeet
        #: has come out fastest on the CPU while this is several times
        #: faster on the GPU.
        self.gpu_layers = 99

    # -- public API --------------------------------------------------

    def finalize(self, text: str, *,
                 correction: CorrectionConfig,
                 rewrite: RewriteConfig) -> str:
        """Apply the enabled stages. Returns ``text`` unchanged if none are."""
        if not text.strip():
            return text
        result = text
        if correction.enabled:
            result = self._corrected(result, correction)
        if rewrite.enabled:
            result = self._rewritten(result, rewrite)
        return result

    def shutdown(self) -> None:
        with self._lock:
            if self._unload_timer is not None:
                self._unload_timer.cancel()
                self._unload_timer = None
        self._pool.shutdown()

    def schedule_unload(self, delay: float = UNLOAD_DELAY_SECONDS) -> None:
        """Free every host after ``delay`` of disuse.

        Called when the user turns post-processing off by hotkey — not on a
        settings save, which restarts the whole service and takes the hosts
        with it. Re-scheduling restarts the clock, matching "ten minutes
        after the most recent disable".
        """
        with self._lock:
            if self._unload_timer is not None:
                self._unload_timer.cancel()
            timer = threading.Timer(delay, self._pool.shutdown)
            timer.daemon = True
            self._unload_timer = timer
            timer.start()

    def cancel_scheduled_unload(self) -> None:
        """Keep every host alive — the user turned post-processing back on."""
        with self._lock:
            if self._unload_timer is not None:
                self._unload_timer.cancel()
                self._unload_timer = None

    # -- stages ------------------------------------------------------

    def warm_up(self, config: CorrectionConfig) -> None:
        """Load the local correction host and prime its prompt cache, off the
        dictation path. Blocking; call from a background thread.

        The host keeps a snapshot of the prompt prefix every correction
        request shares (system prompt and example turns, ~276 of ~295
        tokens), learned from two consecutive requests. Without this the
        first dictation after a start pays the model load and the full
        prompt (~3 s) and the second the snapshot (~1.2 s); with it, both
        take the usual 0.2-0.4 s. Nothing happens unless the bundled model
        is the correction backend and its weights are on disk.
        """
        if not config.enabled or config.backend is not LLMBackend.BUNDLED_LOCAL:
            return
        if not is_present(profile(config.model).pin):
            return
        system, examples = self._correction_prompt(config)
        try:
            # Two different one-letter sentences: what they share is exactly
            # the prefix every real request shares.
            for text in ("а", "б"):
                self._bundled_completion(
                    config.model, [Message(Role.SYSTEM, system), *examples, Message(Role.USER, text)],
                    max_tokens=8)
            log.info("Local correction host warmed up")
        except Exception as exc:
            log.info("Local correction warm-up failed (the first dictation will load it): %s", exc)

    def _correction_prompt(self, config: CorrectionConfig) -> tuple[str, list[Message]]:
        # A custom endpoint serves whichever model the user named there, so
        # it gets the zero-shot instruct prompt, as on macOS: the few-shot
        # turns were tuned against the bundled adapter only.
        few_shot = (config.backend is LLMBackend.BUNDLED_LOCAL
                    and profile(config.model).uses_few_shot_correction)
        system = (config.system_prompt_override.strip()
                  or prompts.correction_system_prompt(few_shot=few_shot))
        return system, list(prompts.correction_example_turns(few_shot=few_shot))

    def _corrected(self, text: str, config: CorrectionConfig) -> str:
        system, examples = self._correction_prompt(config)

        # One request per sentence-bounded chunk, as on macOS: a long
        # dictation in one request is where the model loses or replaces
        # text, and the guardrail then reverts each chunk on its own.
        chunks = guardrail.correction_chunks(text)
        corrected: list[str] = []
        for index, chunk in enumerate(chunks):
            messages = [Message(Role.SYSTEM, system), *examples, Message(Role.USER, chunk)]
            raw = self._complete(messages, backend=config.backend,
                                 model=config.model, endpoint=config.endpoint,
                                 stage="correction",
                                 max_tokens=min(2048, max(64, len(chunk.encode("utf-8")))))
            if raw is None:
                # A failed request would fail the same way for every
                # remaining chunk; don't wait it out N times.
                corrected += chunks[index:]
                break
            # The guardrail is the whole reason the correction stage is safe
            # to run by default: it reverts to the input whenever the
            # model's known failure modes show up.
            corrected.append(guardrail.sanitized_correction(chunk, raw))
        return " ".join(corrected) if corrected else text

    def _rewritten(self, text: str, config: RewriteConfig) -> str:
        custom = config.custom_styles.get(config.custom_style_id) \
            if config.custom_style_id else None
        if custom:
            system = prompts.rewrite_system_prompt_custom(
                str(custom.get("name", "")), str(custom.get("instruction", "")))
            token = str(custom.get("name", "")).upper()
        else:
            override = str(config.system_prompt_overrides.get(
                config.style.value, "")).strip()
            system = override or prompts.rewrite_system_prompt(config.style)
            token = config.style.token

        messages = [
            Message(Role.SYSTEM, system),
            Message(Role.USER, prompts.rewrite_user_text(text, token)),
        ]
        raw = self._complete(messages, backend=config.backend,
                             model=config.model, endpoint=config.endpoint,
                             stage="rewrite", max_tokens=2048)
        if raw is None:
            return text
        # No leading-word guardrail here: rewrite IS allowed to restructure,
        # so that check would reject its whole purpose. The prompt's own
        # fact-preservation constraints are the safety mechanism, plus this
        # empty-output fallback.
        trimmed = raw.strip()
        return trimmed or text

    # -- transport ---------------------------------------------------

    def _complete(self, messages: list[Message], *,
                  backend: LLMBackend,
                  model: BundledLLMModel,
                  endpoint: CustomEndpoint,
                  stage: str,
                  max_tokens: int) -> Optional[str]:
        """One request. Returns None on any failure — the caller keeps its input."""
        started = time.monotonic()
        try:
            if backend is LLMBackend.CUSTOM_ENDPOINT:
                if not endpoint.is_configured:
                    log.warning("%s: custom endpoint not configured; skipping", stage)
                    return None
                content = chat_completion(
                    endpoint.base_url, messages,
                    max_tokens=max_tokens,
                    api_key=endpoint.api_key,
                    model=endpoint.effective_model_name,
                    use_system_proxy=endpoint.use_system_proxy,
                )
            else:
                content = self._bundled_completion(model, messages, max_tokens)
        except LLMHostError as exc:
            log.warning("%s failed (%s); keeping text unchanged", stage, exc)
            return None
        except Exception as exc:  # never let post-processing break dictation
            log.exception("%s raised (%s); keeping text unchanged", stage, exc)
            return None

        log.info("%s took %.2fs", stage, time.monotonic() - started)
        return content

    def _bundled_completion(self, model: BundledLLMModel,
                            messages: list[Message], max_tokens: int) -> str:
        model_profile = profile(model)
        # Checked before the host is spawned, so a missing model reads as
        # "the weights are not here" rather than as a host that would not
        # start. Downloading is never done from here: a dictation must not
        # block on five gigabytes, so the UI offers the download and this
        # path just declines until the file exists.
        if not is_present(model_profile.pin):
            self._report_missing(model)
            raise LLMHostError(
                f"model not downloaded: {model_profile.pin.filename}")
        spec = HostSpec(
            model_path=model_profile.model_path,
            lora_path=model_profile.lora_path,
            lora_scale=model_profile.lora_scale,
            context_size=model_profile.context_size,
            gpu_layers=self.gpu_layers,
        )
        cold = not self._pool_has(spec)
        if cold and self.on_load_stage is not None:
            self._notify(self.on_load_stage, "Загружается модель…")
        try:
            host = self._pool.get(spec)
        finally:
            if cold and self.on_load_finished is not None:
                self._notify(self.on_load_finished)
        return host.complete(messages, max_tokens=max_tokens)

    def _pool_has(self, spec: HostSpec) -> bool:
        existing = self._pool._hosts.get(spec.identity)  # noqa: SLF001
        return existing is not None and existing.is_running

    def _report_missing(self, model: BundledLLMModel) -> None:
        if model in self._reported_missing:
            return
        self._reported_missing.add(model)
        log.warning("Bundled model %s is not downloaded; skipping the stage",
                    model.value)
        if self.on_model_missing is not None:
            self._notify(self.on_model_missing, model)

    def forget_missing(self, model: BundledLLMModel) -> None:
        """Allow the missing-model notice again — the weights just arrived."""
        self._reported_missing.discard(model)

    @staticmethod
    def _notify(callback, *args) -> None:
        """UI callbacks must never break the pipeline."""
        try:
            callback(*args)
        except Exception:
            log.debug("LLM load-progress callback raised", exc_info=True)
