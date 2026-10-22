"""Bundled LLM weights, pinned to the same files the macOS build uses.

Every repository, revision, filename, byte size and SHA-256 here is copied
from ``swift/Sources/Parakey/ModelDownload.swift``. The digests were
computed there from the actual downloaded bytes, never from Hugging Face
API metadata, and the same policy applies to anything added here: a pin
that was not verified against real bytes is not a pin.

Keeping the two platforms on identical weights is what makes the tuned
prompts in :mod:`superdictate.llm.prompts` mean the same thing on both.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum

from .. import paths


class LLMBackend(str, Enum):
    """Where a post-processing stage sends its requests."""

    BUNDLED_LOCAL = "bundledLocal"
    CUSTOM_ENDPOINT = "customEndpoint"


class BundledLLMModel(str, Enum):
    """The bundled models this port ships.

    The macOS correction picker offers every small model its benchmark
    tested; this port starts with the two that are actually reachable from
    the shipped defaults and grows by adding table entries below — nothing
    else in the pipeline is model-specific.
    """

    #: Qwen3.5-0.8B Q6_K + the dictation-corrector LoRA. The default
    #: correction model. Benchmark: EM 0.600, identity 1.000, p50 189 ms.
    VOICESCRIBE = "voicescribe"
    #: YandexGPT-5-Lite-8B-instruct Q4_K_M. The quality correction tier and
    #: the bundled rewrite model — one host serves both.
    YANDEXGPT = "yandexgpt"


@dataclass(frozen=True)
class ModelPin:
    repository: str
    revision: str
    filename: str
    sha256: str
    size_bytes: int

    @property
    def url(self) -> str:
        return (f"https://huggingface.co/{self.repository}/resolve/"
                f"{self.revision}/{self.filename}")

    @property
    def local_path(self) -> str:
        return str(paths.MODELS_DIR / "llm" / self.filename)


#: Base weights: Qwen3.5-0.8B vanilla (NOT Instruct, NOT -Base) Q6_K.
GEC_MODEL = ModelPin(
    repository="bartowski/Qwen_Qwen3.5-0.8B-GGUF",
    revision="f36b1ea49a332ede8fe5f389bbf5b3575ef71f48",
    filename="Qwen_Qwen3.5-0.8B-Q6_K.gguf",
    sha256="976220309a81b4eb26462657a77570bc6e7d936e8425161c54d6d85488567f95",
    size_bytes=691_461_216,
)

YANDEXGPT_MODEL = ModelPin(
    repository="yandex/YandexGPT-5-Lite-8B-instruct-GGUF",
    revision="9fe287d2f512503046bb008aed350f2b4bbb903d",
    filename="YandexGPT-5-Lite-8B-instruct-Q4_K_M.gguf",
    sha256="d9ff5b826f20fbcc2f898f9f2349ac21241579f8fbb79cd32148a333623ba228",
    size_bytes=4_920_741_184,
)


def lora_adapter_path() -> str:
    """The dictation-corrector LoRA, shipped with the app.

    2.75 MB — small enough to bundle rather than download, which also
    removes a network dependency from the default correction path. Converted
    from the upstream safetensors adapter with llama.cpp's
    ``convert_lora_to_gguf.py --outtype f32``; the conversion output is what
    the macOS build checksum-pins.
    """
    return str(paths.resource_path("assets", "models", "gec-lora-adapter.gguf"))


@dataclass(frozen=True)
class ModelProfile:
    """Everything the pipeline needs to know about one bundled model."""

    pin: ModelPin
    #: Whether the correction pass sends this model few-shot example turns.
    #: True only for the LoRA adapter it was tuned against; every instruct
    #: model was benchmarked zero-shot.
    uses_few_shot_correction: bool
    #: Whether the user may replace this model's system prompt. False for
    #: models whose prompt is mandatory.
    allows_custom_system_prompt: bool = True
    #: Whether a LoRA adapter is applied on top of the base weights.
    uses_lora: bool = False
    #: llama.cpp's ``--lora-scale``. The VoiceScribe adapter is rsLoRA
    #: (alpha 80, rank 16, effective scale alpha/sqrt(rank) = 20) while
    #: llama.cpp applies scale * alpha/rank, so it needs 4.0 — macOS
    #: GEC_LORA_SCALE. At 1.0 the adapter runs at a quarter strength.
    lora_scale: float = 1.0
    #: Rough working-set size, for the "not enough VRAM" warning.
    context_size: int = 4096

    @property
    def model_path(self) -> str:
        return self.pin.local_path

    @property
    def lora_path(self) -> str:
        return lora_adapter_path() if self.uses_lora else ""


PROFILES: dict[BundledLLMModel, ModelProfile] = {
    BundledLLMModel.VOICESCRIBE: ModelProfile(
        pin=GEC_MODEL,
        uses_few_shot_correction=True,
        uses_lora=True,
        lora_scale=4.0,
    ),
    BundledLLMModel.YANDEXGPT: ModelProfile(
        pin=YANDEXGPT_MODEL,
        uses_few_shot_correction=False,
    ),
}


#: What the local host is offered for. Correction only, with the small
#: models (VoiceScribe first); YandexGPT stays in the table for settings
#: carried over from macOS, but is not offered: an 8B model is a rewrite
#: model, and local rewrite is not part of this port yet.
LOCAL_CORRECTION_MODELS: tuple[BundledLLMModel, ...] = (BundledLLMModel.VOICESCRIBE,)
LOCAL_REWRITE_ENABLED = False


def profile(model: BundledLLMModel) -> ModelProfile:
    return PROFILES[model]
