"""Speech recognition.

The macOS build runs Parakeet TDT v3 through FluidAudio on the Apple
Neural Engine. Windows has no ANE, so the same model runs through ONNX
Runtime via ``onnx-asr``, which resolves the weights from
``istupakov/parakeet-tdt-0.6b-v3-onnx``, the same NVIDIA checkpoint,
same 25 languages, same vocabulary.

Two weight sets exist upstream and both are offered:

* ``int8``, 640 MB, matching the macOS on-disk footprint. Default.
* ``fp32``, 2.4 GB, meaningfully better on a CUDA GPU, where int8
  kernels are not the fast path.

One caveat versus macOS: FluidAudio exposes a per-language decoder script
filter, which ``onnx-asr`` does not. The dictation-language setting still
drives the ``<unk>`` → "ё" repair in :mod:`superdictate.textproc`, but it
cannot bias the joint head. Auto-detect behaves identically on both
platforms.
"""

from __future__ import annotations

import os
import threading
import time
from dataclasses import dataclass
from enum import Enum
from typing import Callable, Optional

import numpy as np

from . import paths
from .audio import SAMPLE_RATE
from .logging_setup import get as get_logger

log = get_logger("asr")

MODEL_NAME = "nemo-parakeet-tdt-0.6b-v3"
MODEL_REPO = "istupakov/parakeet-tdt-0.6b-v3-onnx"

QUANTIZATION_INT8 = "int8"
QUANTIZATION_FULL = "full"

MODEL_FILES: dict[str, list[str]] = {
    QUANTIZATION_INT8: [
        "config.json",
        "vocab.txt",
        "nemo128.onnx",
        "encoder-model.int8.onnx",
        "decoder_joint-model.int8.onnx",
    ],
    QUANTIZATION_FULL: [
        "config.json",
        "vocab.txt",
        "nemo128.onnx",
        "encoder-model.onnx",
        "encoder-model.onnx.data",
        "decoder_joint-model.onnx",
    ],
}

MODEL_TOTAL_BYTES: dict[str, int] = {
    QUANTIZATION_INT8: 671 * 1024 * 1024,
    QUANTIZATION_FULL: 2551 * 1024 * 1024,
}


class State(str, Enum):
    IDLE = "idle"
    DOWNLOADING = "downloading"
    LOADING = "loading"
    READY = "ready"
    FAILED = "failed"


@dataclass
class Progress:
    state: State
    downloaded_bytes: int = 0
    total_bytes: int = 0
    message: str = ""

    @property
    def fraction(self) -> float:
        if self.total_bytes <= 0:
            return 0.0
        return min(1.0, self.downloaded_bytes / self.total_bytes)


@dataclass
class TranscriptionResult:
    text: str
    audio_seconds: float
    queue_seconds: float
    inference_seconds: float

    @property
    def total_seconds(self) -> float:
        return self.queue_seconds + self.inference_seconds

    @property
    def realtime_factor(self) -> float:
        if self.audio_seconds <= 0:
            return 0.0
        return self.inference_seconds / self.audio_seconds


def _model_dir(quantization: str) -> "os.PathLike[str]":
    return paths.MODELS_DIR / f"parakeet-tdt-0.6b-v3-{quantization}"


def model_is_present(quantization: str) -> bool:
    directory = paths.MODELS_DIR / f"parakeet-tdt-0.6b-v3-{quantization}"
    return all((directory / name).exists() for name in MODEL_FILES[quantization])


def local_model_bytes(quantization: str) -> int:
    directory = paths.MODELS_DIR / f"parakeet-tdt-0.6b-v3-{quantization}"
    total = 0
    if not directory.exists():
        return 0
    for item in directory.rglob("*"):
        try:
            if item.is_file():
                total += item.stat().st_size
        except OSError:
            continue
    return total


def available_providers() -> list[str]:
    try:
        import onnxruntime as rt

        return list(rt.get_available_providers())
    except Exception:
        return []


def resolve_providers(preference: str) -> list[str]:
    """Turn the user's compute choice into an ONNX Runtime provider list.

    CUDA is only offered when the runtime actually reports it; a wheel
    built without it, a missing driver, or an absent cuDNN all surface the
    same way, and silently falling back to CPU beats failing to start.
    """
    available = available_providers()
    cuda = "CUDAExecutionProvider"
    if preference == "cpu":
        return ["CPUExecutionProvider"]
    if cuda in available and preference in ("auto", "cuda"):
        return [cuda, "CPUExecutionProvider"]
    if preference == "cuda":
        log.warning("CUDA requested but unavailable (providers: %s); using CPU", available)
    return ["CPUExecutionProvider"]


class SpeechModel:
    """Owns the ONNX session and serialises transcription requests.

    ONNX Runtime sessions are thread-safe for ``Run``, but the transducer
    decoding in onnx-asr keeps per-call state, so a lock keeps concurrent
    dictations (a fast second hotkey press) from interleaving.
    """

    def __init__(self, quantization: str = QUANTIZATION_INT8,
                 compute_provider: str = "auto") -> None:
        self.quantization = quantization
        self.compute_provider = compute_provider
        self._model = None
        self._lock = threading.Lock()
        self._state = State.IDLE
        self._error: Optional[str] = None
        self._active_providers: list[str] = []

    @property
    def state(self) -> State:
        return self._state

    @property
    def error(self) -> Optional[str]:
        return self._error

    @property
    def is_ready(self) -> bool:
        return self._state is State.READY and self._model is not None

    @property
    def active_providers(self) -> list[str]:
        return list(self._active_providers)

    @property
    def uses_gpu(self) -> bool:
        return any("CUDA" in provider or "Dml" in provider
                   for provider in self._active_providers)

    # -- loading -----------------------------------------------------

    def prepare(self, on_progress: Optional[Callable[[Progress], None]] = None) -> bool:
        """Download (if needed) and load the model. Blocking; call off the UI thread."""

        def report(progress: Progress) -> None:
            self._state = progress.state
            if on_progress is not None:
                try:
                    on_progress(progress)
                except Exception:
                    pass

        try:
            if not model_is_present(self.quantization):
                report(Progress(State.DOWNLOADING, local_model_bytes(self.quantization),
                                MODEL_TOTAL_BYTES[self.quantization]))
                self._download(report)

            report(Progress(State.LOADING, message="loading"))
            self._load()
            report(Progress(State.READY, message="ready"))
            return True
        except Exception as exc:
            self._error = str(exc)
            log.exception("Model preparation failed")
            report(Progress(State.FAILED, message=str(exc)))
            return False

    def _download(self, report: Callable[[Progress], None]) -> None:
        from huggingface_hub import snapshot_download
        from huggingface_hub.utils import disable_progress_bars

        # The hub draws its own tqdm bar on stderr. A windowed build has no
        # stderr at all, so the bar's first write ended the download with
        # "'NoneType' object has no attribute 'write'" before a single byte
        # had been fetched. The progress the user sees comes from the
        # watcher below, so the bar is not wanted here in any case.
        disable_progress_bars()

        target = _model_dir(self.quantization)
        total = MODEL_TOTAL_BYTES[self.quantization]
        stop = threading.Event()

        def watch() -> None:
            # snapshot_download has no aggregate callback, so progress is
            # measured from what has landed on disk. Good enough for a
            # progress bar and immune to upstream API churn.
            while not stop.wait(0.5):
                report(Progress(State.DOWNLOADING,
                                local_model_bytes(self.quantization), total))

        watcher = threading.Thread(target=watch, name="model-download-progress", daemon=True)
        watcher.start()
        try:
            snapshot_download(
                MODEL_REPO,
                local_dir=str(target),
                allow_patterns=MODEL_FILES[self.quantization],
                max_workers=4,
            )
        finally:
            stop.set()
            watcher.join(timeout=1.0)

        missing = [name for name in MODEL_FILES[self.quantization]
                   if not (paths.MODELS_DIR / f"parakeet-tdt-0.6b-v3-{self.quantization}"
                           / name).exists()]
        if missing:
            raise RuntimeError(f"Model download incomplete, missing: {', '.join(missing)}")
        report(Progress(State.DOWNLOADING, local_model_bytes(self.quantization), total))

    def _load(self) -> None:
        import onnx_asr

        providers = resolve_providers(self.compute_provider)
        quantization = None if self.quantization == QUANTIZATION_FULL else "int8"
        started = time.monotonic()
        model = onnx_asr.load_model(
            MODEL_NAME,
            str(_model_dir(self.quantization)),
            quantization=quantization,
            providers=providers,
        )
        self._model = model
        self._active_providers = providers
        log.info(
            "Model loaded in %.1fs (quantization=%s, providers=%s)",
            time.monotonic() - started, self.quantization, providers,
        )
        self._warm_up()

    def _warm_up(self) -> None:
        """First inference allocates kernels and, on CUDA, compiles them.

        Doing it at load time keeps the first real dictation from paying a
        multi-second penalty, the same reason the macOS build primes
        FluidAudio right after the model finishes loading.
        """
        try:
            silence = np.zeros(int(SAMPLE_RATE * 0.5), dtype=np.float32)
            started = time.monotonic()
            self._model.recognize(silence, sample_rate=SAMPLE_RATE)
            log.info("Warm-up inference took %.2fs", time.monotonic() - started)
        except Exception as exc:
            log.warning("Warm-up failed (continuing anyway): %s", exc)

    def unload(self) -> None:
        with self._lock:
            self._model = None
            self._state = State.IDLE
            self._active_providers = []

    # -- inference ---------------------------------------------------

    def transcribe(self, samples: np.ndarray, enqueued_at: float) -> TranscriptionResult:
        if self._model is None:
            raise RuntimeError("Speech model is not loaded")
        audio_seconds = len(samples) / SAMPLE_RATE
        with self._lock:
            queue_seconds = time.monotonic() - enqueued_at
            started = time.monotonic()
            raw = self._model.recognize(samples, sample_rate=SAMPLE_RATE)
            inference_seconds = time.monotonic() - started
        text = raw if isinstance(raw, str) else str(raw)
        return TranscriptionResult(
            text=text.strip(),
            audio_seconds=audio_seconds,
            queue_seconds=queue_seconds,
            inference_seconds=inference_seconds,
        )

    def transcribe_preview(self, samples: np.ndarray) -> Optional[tuple[str, float]]:
        """A throwaway pass over a recording still in progress.

        Returns the text and how long inference took, or ``None`` if the
        model is busy with a real dictation. The lock is taken without
        blocking on purpose: a preview that has to wait its turn is stale
        by the time it runs, and holding up the transcription the user is
        actually waiting for to produce one would be backwards.
        """
        if self._model is None or samples.size == 0:
            return None
        if not self._lock.acquire(blocking=False):
            return None
        try:
            started = time.monotonic()
            raw = self._model.recognize(samples, sample_rate=SAMPLE_RATE)
            elapsed = time.monotonic() - started
        except Exception as exc:
            log.debug("Preview pass failed: %s", exc)
            return None
        finally:
            self._lock.release()
        text = raw if isinstance(raw, str) else str(raw)
        return text.strip(), elapsed


def delete_model_cache(quantization: Optional[str] = None) -> None:
    import shutil

    targets = [quantization] if quantization else list(MODEL_FILES)
    for name in targets:
        directory = paths.MODELS_DIR / f"parakeet-tdt-0.6b-v3-{name}"
        if directory.exists():
            shutil.rmtree(directory, ignore_errors=True)
