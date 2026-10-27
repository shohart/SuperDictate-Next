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
    """The bundled models: the macOS table (ConfigModels.swift), value for value.

    Which of them each stage offers is :data:`CORRECTION_MODELS` and
    :data:`REWRITE_MODELS`, the macOS pickers' own lists.
    """

    #: Qwen3.5-0.8B Q6_K + the dictation-corrector LoRA. The default
    #: correction model. Benchmark: EM 0.600, identity 1.000, p50 189 ms.
    VOICESCRIBE = "voicescribe"
    #: Correction EM 0.723 (best of the small models), p50 549 ms.
    QWEN35_4B = "qwen35_4b"
    #: Correction EM 0.677, p50 375 ms.
    RUADAPT_4B = "ruadapt4b"
    #: Correction EM 0.600, p50 484 ms.
    QVIKHR_4B = "qvikhr4b"
    #: Correction EM 0.585, p50 375 ms.
    MINISTRAL_3B = "ministral3b"
    #: Correction EM 0.538, p50 343 ms.
    PHI4_MINI = "phi4mini"
    #: Correction EM 0.462, p50 179 ms. A GEC fine-tune with a mandatory
    #: system prompt.
    LOQIRA = "loqira"
    #: The VoiceScribe base without the LoRA. Correction EM 0.369.
    VANILLA_08B = "vanilla08b"
    #: A reasoning model; rewrite only, with its forced <think> removed from
    #: the template (assets/models/chat-template-lfm25.jinja).
    LFM25 = "lfm25"
    #: YandexGPT-5-Lite-8B-instruct Q4_K_M. Correction winner (EM 0.892) and
    #: rewrite winner — offered in both stages; one host serves both.
    YANDEXGPT = "yandexgpt"
    #: Rewrite: FactRec 0.489, p50 3.2 s.
    QWEN35_9B = "qwen35_9b"
    #: Rewrite: FactRec 0.483, p50 2.3 s.
    GEMMA4_E4B = "gemma4e4b"


@dataclass(frozen=True)
class ModelPin:
    repository: str
    revision: str
    filename: str
    sha256: str
    size_bytes: int
    #: The name in the model folder, when it differs from the remote one
    #: (RuAdapt's repo names its files bare, "Q6_K.gguf").
    local_name: str = ""

    @property
    def url(self) -> str:
        return (f"https://huggingface.co/{self.repository}/resolve/"
                f"{self.revision}/{self.filename}")

    @property
    def local_path(self) -> str:
        return str(paths.MODELS_DIR / "llm" / (self.local_name or self.filename))


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

#: bundledLLMModelPin (ModelDownload.swift): the digests are of the bytes the
#: macOS benchmark ran on.
_PINS: dict[str, ModelPin] = {
    "qwen35_4b": ModelPin(
        "bartowski/Qwen_Qwen3.5-4B-GGUF", "4168f45a16a1290d65a4ec0fa312ae917a4c15d6",
        "Qwen_Qwen3.5-4B-Q6_K.gguf",
        "5a5bc7a3f9375b395e9f81fb69109038cf160c84606b8192f13cbb8355ca59f2", 3_805_358_048),
    "ruadapt4b": ModelPin(
        "RefalMachine/RuadaptQwen3-4B-Instruct-GGUF", "0cf4a934b379b3d070116164aaa6e5db1c7d4198",
        "Q6_K.gguf",
        "a206b1994822653e1da29ce76e96dc57f0f2a899f09a44466b94d3c043b82d29", 3_295_488_128,
        local_name="RuadaptQwen3-4B-Instruct-Q6_K.gguf"),
    "qvikhr4b": ModelPin(
        "Vikhrmodels/QVikhr-3-4B-Instruction-GGUF", "ab5a2e9090cd1643ea48f3eb86d7b8fde8df8db6",
        "QVikhr-3-4B-Instruction-Q6_K.gguf",
        "4b75f6682b1d84c9048f54ffe5ddb54c7c5202afccb4121d027b59c227c31076", 3_306_261_568),
    "ministral3b": ModelPin(
        "unsloth/Ministral-3-3B-Instruct-2512-GGUF", "7564922f37fa5bbb62b87f09a55c12f1f91d7a6a",
        "Ministral-3-3B-Instruct-2512-Q6_K.gguf",
        "ca22c676b97aad1d50952416f44ddd6d8130e24c11c474aed5e8865dd7e35297", 2_821_256_480),
    "phi4mini": ModelPin(
        "unsloth/Phi-4-mini-instruct-GGUF", "78eb92a46fc37e6b524df991ed9aca9bc6aa7b80",
        "Phi-4-mini-instruct-Q6_K.gguf",
        "72b8446a3db55617950bef48d296659050867cca41bd7a7be4622010c9589400", 3_155_622_880),
    "loqira": ModelPin(
        "loqira/Qwen3.5-0.8B-GEC-KAZ-RUS-ENG", "ced469768d40dffc899fe459efb66a4a07aeabee",
        "Qwen3.5-0.8B-GEC-KAZ-RUS-ENG.Q4_0.gguf",
        "893f573db88f587e823b66847e06049cdb3029eff6177d92f6577179f7178871", 563_035_616),
    "lfm25": ModelPin(
        "LiquidAI/LFM2.5-2.6B-GGUF", "f4a289c8a200a5ca71005ba7abc2dad33058a450",
        "LFM2.5-2.6B-Q6_K.gguf",
        "2e74b1a0979a4a1936a408445147d103b8f15b2e2ec31c65fa0166f9069c250d", 2_221_615_104),
    "gemma4e4b": ModelPin(
        "google/gemma-4-E4B-it-qat-q4_0-gguf", "4b4a2c1d584be7264f87aac328a1bc739ce81b6c",
        "gemma-4-E4B_q4_0-it.gguf",
        "676c35070db6dbe52f93e9c864ee0fba4eddea94b9c875d9cb10daff453fbaee", 5_154_941_280),
    "qwen35_9b": ModelPin(
        "unsloth/Qwen3.5-9B-GGUF", "3885219b6810b007914f3a7950a8d1b469d598a5",
        "Qwen3.5-9B-Q4_K_M.gguf",
        "03b74727a860a56338e042c4420bb3f04b2fec5734175f4cb9fa853daf52b7e8", 5_680_522_464),
}


def chat_template_path(name: str) -> str:
    """A chat-template override shipped with the app (``--chat-template-file``)."""
    return str(paths.resource_path("assets", "models", name))


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
    #: llama.cpp context window: 8192 for the models that serve the
    #: rewrite (a long dictation's rewrite needs up to ~3072 completion
    #: tokens on top of the prompt), 4096 for correction-only ones
    #: (hostContextSize).
    context_size: int = 4096
    #: Chat-template override file, or "" for the model's own template.
    chat_template: str = ""

    @property
    def model_path(self) -> str:
        return self.pin.local_path

    @property
    def lora_path(self) -> str:
        return lora_adapter_path() if self.uses_lora else ""

    @property
    def chat_template_path(self) -> str:
        return chat_template_path(self.chat_template) if self.chat_template else ""


#: The macOS pickers (BundledLLMModel.correctionModels / .rewriteModels).
#: LFM2.5 is not a correction model: it reasons even with the template fixed.
CORRECTION_MODELS: tuple[BundledLLMModel, ...] = (
    BundledLLMModel.VOICESCRIBE, BundledLLMModel.QWEN35_4B, BundledLLMModel.RUADAPT_4B,
    BundledLLMModel.QVIKHR_4B, BundledLLMModel.MINISTRAL_3B, BundledLLMModel.PHI4_MINI,
    BundledLLMModel.LOQIRA, BundledLLMModel.VANILLA_08B, BundledLLMModel.YANDEXGPT,
)
REWRITE_MODELS: tuple[BundledLLMModel, ...] = (
    BundledLLMModel.YANDEXGPT, BundledLLMModel.QWEN35_9B, BundledLLMModel.GEMMA4_E4B,
    BundledLLMModel.PHI4_MINI, BundledLLMModel.MINISTRAL_3B, BundledLLMModel.RUADAPT_4B,
    BundledLLMModel.LFM25,
)


def _profile(model: BundledLLMModel) -> ModelProfile:
    rewrite_window = 8192 if model in REWRITE_MODELS else 4096
    if model is BundledLLMModel.VOICESCRIBE:
        return ModelProfile(pin=GEC_MODEL, uses_few_shot_correction=True,
                            uses_lora=True, lora_scale=4.0)
    if model is BundledLLMModel.VANILLA_08B:
        return ModelProfile(pin=GEC_MODEL, uses_few_shot_correction=False)
    if model is BundledLLMModel.YANDEXGPT:
        return ModelProfile(pin=YANDEXGPT_MODEL, uses_few_shot_correction=False,
                            context_size=rewrite_window)
    return ModelProfile(
        pin=_PINS[model.value],
        uses_few_shot_correction=False,
        allows_custom_system_prompt=model is not BundledLLMModel.LOQIRA,
        context_size=rewrite_window,
        chat_template="chat-template-lfm25.jinja" if model is BundledLLMModel.LFM25 else "",
    )


PROFILES: dict[BundledLLMModel, ModelProfile] = {model: _profile(model) for model in BundledLLMModel}


def profile(model: BundledLLMModel) -> ModelProfile:
    return PROFILES[model]
