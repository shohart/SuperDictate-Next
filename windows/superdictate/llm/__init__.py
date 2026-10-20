"""Local LLM post-processing for dictated text.

Correction and rewrite, both served by the same ``superdictate-llm-host.exe``
subprocess over loopback HTTP — the identical arrangement the macOS build
uses, down to the prompts and the model weights.

The entry point is :class:`~superdictate.llm.pipeline.LLMPostprocessor`.
"""

from .models import BundledLLMModel, LLMBackend
from .pipeline import (
    CorrectionConfig,
    CustomEndpoint,
    LLMPostprocessor,
    PostprocessingMode,
    RewriteConfig,
)
from .prompts import RewriteStyle

__all__ = [
    "BundledLLMModel",
    "CorrectionConfig",
    "CustomEndpoint",
    "LLMBackend",
    "LLMPostprocessor",
    "PostprocessingMode",
    "RewriteConfig",
    "RewriteStyle",
]
