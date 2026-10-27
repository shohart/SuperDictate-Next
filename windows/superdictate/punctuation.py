"""Punctuation restoration: the last text stage, after correction and rewrite.

A ModernBERT token classifier (Horizon-Labs/punctuation-restoration Small or
Base, Apache-2.0) predicts a mark after every word. It runs on the CPU in its
own ``SuperDictateOnnxHost`` process, the same native runtime as on macOS
(native/asr-runtime/src/families/modernbert_punct.cpp; the merge with the
marks earlier stages set is in punct_text.cpp). Spec:
docs/specs/punctuation-restoration-spec.md.

Like the LLM stages it never costs the text: a model that is not downloaded,
a host that will not start or a failed request all return the input
unchanged.
"""

from __future__ import annotations

import logging
import threading
import time
from typing import Optional

from . import onnx_models, paths
from .onnx_host import OnnxHost

log = logging.getLogger(__name__)

MODELS = ("small", "base")
DEFAULT_MODEL = "base"
#: About 60 ms a sentence for Base on four threads; more barely helps a
#: model this size and would compete with the speech model.
THREADS = 4


def model_id(model: str) -> str:
    """Catalog id (native/asr-runtime/catalog/onnx-models.json)."""
    return f"punct-{model if model in MODELS else DEFAULT_MODEL}-int8"


def is_installed(model: str) -> bool:
    return onnx_models.is_installed(model_id(model))


def download_bytes(model: str) -> int:
    try:
        return onnx_models.model(model_id(model)).total_bytes
    except Exception:
        return 0


class PunctuationRestorer:
    """Owns at most one loaded punctuation model. Thread-safe."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._host: Optional[OnnxHost] = None
        self._model: Optional[str] = None
        self._reported_missing: set[str] = set()

    def restore(self, text: str, model: str) -> str:
        if not text.strip():
            return text
        with self._lock:
            host = self._host_for(model)
            if host is None:
                return text
            try:
                result = host.punctuate(text)
            except Exception as exc:
                log.warning("Punctuation: request failed (%s); keeping the text as it was", exc)
                if not host.is_alive:
                    self._unload_locked()
                return text
        log.info("Punctuation: %s in %.0f ms", model, result.processing_seconds * 1000)
        return result.text or text

    def warm_up(self, model: str) -> None:
        with self._lock:
            self._host_for(model)

    @property
    def loaded_model(self) -> Optional[str]:
        return self._model if self._host is not None else None

    def shutdown(self) -> None:
        with self._lock:
            self._unload_locked()

    # -- internals ------------------------------------------------------

    def _host_for(self, model: str) -> Optional[OnnxHost]:
        if self._host is not None and self._model == model and self._host.is_alive:
            return self._host
        self._unload_locked()
        if not is_installed(model):
            if model not in self._reported_missing:
                self._reported_missing.add(model)
                log.info("Punctuation: %s is not downloaded; skipping (download it in Settings)",
                         model_id(model))
            return None
        executable = onnx_models.host_executable()
        if executable is None:
            log.warning("Punctuation: SuperDictateOnnxHost.exe is missing")
            return None
        started = time.monotonic()
        host = OnnxHost([str(executable)], cwd=executable.parent,
                        stderr_path=paths.LOG_DIR / "PunctuationHost.log")
        try:
            host.create(model_directory=onnx_models.model_directory(model_id(model)),
                        assets_directory=onnx_models.assets_directory(),
                        threads=THREADS, expected_model_id=model_id(model))
        except Exception as exc:
            host.shutdown()
            log.warning("Punctuation: could not load %s (%s)", model_id(model), exc)
            return None
        log.info("Punctuation: loaded %s in %.1fs", model_id(model), time.monotonic() - started)
        self._host, self._model = host, model
        return host

    def _unload_locked(self) -> None:
        if self._host is not None:
            self._host.shutdown()
            log.info("Punctuation: unloaded %s", self._model)
        self._host, self._model = None, None
