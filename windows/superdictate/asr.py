"""Speech recognition.

Same engine as the macOS build since 0.7.0: ``SuperDictateOnnxHost``, the
native C++ core in ``native/asr-runtime``, running ONNX Runtime 1.23.2 on
the CPU in a helper process (:mod:`superdictate.onnx_host`). Same models
from the same pinned catalog (:mod:`superdictate.onnx_models`):

* **Parakeet Ultra 0.6B** (``parakeet_ultra_onnx``), int8, 25 languages
  including Russian. Default.
* **GigaAM v3** (``gigaam_v3_onnx``), int8, Russian only — punctuation,
  capitalisation, ё and digits come from the model itself, with far fewer
  word-form errors on Russian than Parakeet.

On the CPU, the GPU stays out of it: it belongs to the LLM stages, which
gain several times from it; Parakeet does not, and one device switch for
both was always wrong for one of them.

**Intel NPU** (Windows only, ``speech_compute_backend = "npu"``): the same
two profiles run as OpenVINO builds — Parakeet TDT 0.6B v3 and the
NPU-calibrated GigaAM v3 — in ``SuperDictateOvHost``
(:mod:`superdictate.openvino_host`), which speaks the same IPC as the ONNX
host. The choice is offered only where OpenVINO sees an NPU (:func:`npu_info`).
If the NPU host cannot be brought up at all, the model loads on the CPU
path instead, so a driver problem costs speed, never dictation.
"""

from __future__ import annotations

import json
import subprocess
import threading
import time
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Callable, Optional

import numpy as np

from . import onnx_models, paths
from .audio import SAMPLE_RATE
from .logging_setup import get as get_logger
from .onnx_host import HostTranscription, OnnxHost, OnnxHostError, resolved_thread_count

log = get_logger("asr")

PROFILE_PARAKEET_ULTRA = "parakeet_ultra_onnx"
PROFILE_GIGAAM_V3 = "gigaam_v3_onnx"
DEFAULT_PROFILE = PROFILE_PARAKEET_ULTRA
PROFILES = (PROFILE_PARAKEET_ULTRA, PROFILE_GIGAAM_V3)

BACKEND_CPU = "cpu"
BACKEND_NPU = "npu"
BACKENDS = (BACKEND_CPU, BACKEND_NPU)

_PROFILE_MODEL_IDS = {
    PROFILE_PARAKEET_ULTRA: onnx_models.PARAKEET_ULTRA_MODEL_ID,
    PROFILE_GIGAAM_V3: onnx_models.GIGAAM_V3_MODEL_ID,
}
_NPU_MODEL_IDS = {
    PROFILE_PARAKEET_ULTRA: onnx_models.PARAKEET_OV_MODEL_ID,
    PROFILE_GIGAAM_V3: onnx_models.GIGAAM_OV_MODEL_ID,
}

#: The first NPU compile of a model takes minutes (GigaAM's model card: 3.5
#: minutes with the fast compiler options, far longer without); the blob is
#: cached, so later loads take seconds. The CREATE deadline has to cover the
#: first one.
NPU_CREATE_TIMEOUT_SECONDS = 45 * 60.0


def model_id_for(profile: str, backend: str = BACKEND_CPU) -> str:
    table = _NPU_MODEL_IDS if backend == BACKEND_NPU else _PROFILE_MODEL_IDS
    return table.get(profile, table[DEFAULT_PROFILE])


# -- NPU detection ------------------------------------------------------

_npu_lock = threading.Lock()
_npu_probe: Optional[dict] = None


def npu_info(timeout: float = 60.0) -> Optional[dict]:
    """``{"name", "driver_build"}`` of the Intel NPU, or ``None``.

    Asked of the host (``--probe``), not of OpenVINO in this process: loading
    the runtime here would cost the app ~100 MB for one question. The answer
    is kept for the session; the first call blocks, so the app asks once in
    the background at startup (:func:`probe_npu_async`).
    """
    global _npu_probe
    with _npu_lock:
        if _npu_probe is None:
            _npu_probe = _run_probe(timeout)
        return _npu_probe.get("npu") or None


def probe_npu_async() -> None:
    threading.Thread(target=npu_info, name="npu-probe", daemon=True).start()


def _run_probe(timeout: float) -> dict:
    command = onnx_models.openvino_host_command()
    if command is None:
        return {"npu": None}
    try:
        completed = subprocess.run(
            command + ["--probe"], capture_output=True, timeout=timeout,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        lines = completed.stdout.decode("utf-8", "replace").strip().splitlines()
        result = json.loads(lines[-1]) if lines else {}
    except (OSError, subprocess.SubprocessError, ValueError) as exc:
        log.info("NPU probe failed: %s", exc)
        return {"npu": None}
    if not isinstance(result, dict):
        return {"npu": None}
    log.info("NPU probe: OpenVINO %s, devices %s, NPU %s", result.get("openvino"),
             result.get("devices"), result.get("npu"))
    return result


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


def model_is_present(profile: str, backend: str = BACKEND_CPU) -> bool:
    return onnx_models.is_installed(model_id_for(profile, backend))


def local_model_bytes(profile: str, backend: str = BACKEND_CPU) -> int:
    return onnx_models.installed_bytes(model_id_for(profile, backend))


def model_total_bytes(profile: str, backend: str = BACKEND_CPU) -> int:
    try:
        return onnx_models.model(model_id_for(profile, backend)).total_bytes
    except (onnx_models.ModelInstallError, OSError, ValueError):
        return 0


def delete_model_cache(profile: Optional[str] = None, backend: str = BACKEND_CPU) -> None:
    onnx_models.delete(model_id_for(profile, backend) if profile else None)


class SpeechModel:
    """Owns one host process and serialises requests to it.

    The host answers one TRANSCRIBE at a time (a second one gets BUSY), so a
    lock keeps a fast second dictation from racing the first. A host that
    died — a crash, a timeout kill — is started again on the next request,
    once; if that fails too the error surfaces to the dictation.
    """

    def __init__(self, profile: str = DEFAULT_PROFILE, threads: Optional[int] = None,
                 backend: str = BACKEND_CPU) -> None:
        self.profile = profile if profile in PROFILES else DEFAULT_PROFILE
        self.requested_backend = backend if backend in BACKENDS else BACKEND_CPU
        #: What actually runs; becomes "cpu" if the NPU host cannot start.
        self.backend = self.requested_backend
        self.model_id = model_id_for(self.profile, self.backend)
        self.threads = threads or resolved_thread_count()
        self._host: Optional[OnnxHost] = None
        self._lock = threading.Lock()
        self._state = State.IDLE
        self._error: Optional[str] = None
        self._fallback_reason = ""
        #: Bumped on every load and unload, like the macOS
        #: ``TranscriptionWorker.engineGeneration``.
        self.generation = 0

    @property
    def state(self) -> State:
        return self._state

    @property
    def error(self) -> Optional[str]:
        return self._error

    @property
    def is_ready(self) -> bool:
        return self._state is State.READY and self._host is not None

    @property
    def active_providers(self) -> list[str]:
        host = self._host
        return [host.provider_actual] if host is not None else []

    @property
    def uses_gpu(self) -> bool:
        return False

    @property
    def max_window_seconds(self) -> float:
        """Longest audio one pass takes (the NPU models' static input); 0 = any."""
        host = self._host
        return host.window_seconds if host is not None else 0.0

    @property
    def npu_compiling(self) -> bool:
        """The NPU was asked for and is still being compiled in the host."""
        return self.backend == BACKEND_NPU and "compiling" in self.fallback_reason

    def refresh_device(self) -> bool:
        """Re-read the host's device. Skipped (False) while a request runs,
        so it never delays a dictation. True when it was read."""
        if self._host is None or not self._lock.acquire(blocking=False):
            return False
        try:
            self._host.refresh_status()
            return True
        except Exception as exc:
            log.debug("Status poll failed: %s", exc)
            return False
        finally:
            self._lock.release()

    @property
    def fallback_reason(self) -> str:
        """Why the requested device is not the one running, or ``""``."""
        host = self._host
        if host is not None and host.provider_fallback_reason:
            return host.provider_fallback_reason
        return self._fallback_reason

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
            if self.backend == BACKEND_NPU:
                try:
                    self._install(report)
                    report(Progress(State.LOADING, message="compiling"))
                    with self._lock:
                        self._start_host()
                    report(Progress(State.READY, message="ready"))
                    return True
                except Exception as exc:
                    log.exception("NPU speech model failed; falling back to the CPU")
                    self._fallback_reason = f"npu: {exc}"
                    self.backend = BACKEND_CPU
                    self.model_id = model_id_for(self.profile, BACKEND_CPU)

            self._install(report)
            report(Progress(State.LOADING, message="loading"))
            with self._lock:
                self._start_host()
            report(Progress(State.READY, message="ready"))
            return True
        except Exception as exc:
            self._error = str(exc)
            log.exception("Model preparation failed")
            report(Progress(State.FAILED, message=str(exc)))
            return False

    def _install(self, report: Callable[[Progress], None]) -> None:
        if onnx_models.is_installed(self.model_id):
            return
        total = model_total_bytes(self.profile, self.backend)
        report(Progress(State.DOWNLOADING, 0, total))
        onnx_models.install(
            self.model_id,
            lambda done, all_bytes: report(Progress(State.DOWNLOADING, done, all_bytes)))

    def _start_host(self) -> None:
        if self.backend == BACKEND_NPU:
            self._start_openvino_host()
            return
        executable = onnx_models.host_executable()
        if executable is None:
            raise RuntimeError("SuperDictateOnnxHost.exe is missing from the installation")
        if self._host is not None:
            self._host.shutdown()
            self._host = None
        host = OnnxHost([str(executable)], cwd=executable.parent,
                        stderr_path=paths.LOG_DIR / "OnnxHost.log")
        try:
            host.create(model_directory=onnx_models.model_directory(self.model_id),
                        assets_directory=onnx_models.assets_directory(),
                        threads=self.threads,
                        expected_model_id=self.model_id)
        except Exception:
            host.shutdown()
            raise
        self._host = host
        self.generation += 1
        log.info("ONNX model %s loaded in %.1fs (provider=%s, threads=%d)",
                 host.model_id or self.model_id, host.load_seconds,
                 host.provider_actual, self.threads)
        self._warm_up(host)

    def _start_openvino_host(self) -> None:
        command = onnx_models.openvino_host_command()
        if command is None:
            raise RuntimeError("SuperDictateOvHost is missing from the installation")
        if self._host is not None:
            self._host.shutdown()
            self._host = None
        host = OnnxHost(command, cwd=Path(command[-1]).parent,
                        stderr_path=paths.LOG_DIR / "OvHost.log")
        entry = onnx_models.model(self.model_id).entry
        try:
            host.create_with({
                "engine": "openvino",
                "family": entry["family"],
                "model_id": self.model_id,
                "model_directory": str(onnx_models.model_directory(self.model_id)),
                "cache_directory": str(onnx_models.openvino_cache_directory()),
                "device": "NPU",
            }, timeout=NPU_CREATE_TIMEOUT_SECONDS)
        except Exception:
            host.shutdown()
            raise
        self._host = host
        self.generation += 1
        log.info("OpenVINO model %s loaded in %.1fs (device=%s%s)", self.model_id,
                 host.load_seconds, host.provider_actual,
                 f", fallback: {host.provider_fallback_reason}"
                 if host.provider_fallback_reason else "")
        self._warm_up(host)

    @staticmethod
    def _warm_up(host: OnnxHost) -> None:
        """First inference allocates kernels; pay it at load, not at the first dictation."""
        try:
            started = time.monotonic()
            host.transcribe(np.zeros(SAMPLE_RATE // 2, dtype=np.float32))
            log.info("Warm-up inference took %.2fs", time.monotonic() - started)
        except OnnxHostError as exc:
            log.warning("Warm-up failed (continuing anyway): %s", exc)

    def unload(self) -> None:
        with self._lock:
            if self._host is not None:
                self._host.shutdown()
            self._host = None
            self._state = State.IDLE
            self.generation += 1

    # -- inference ---------------------------------------------------

    def _call(self, samples: np.ndarray, timestamps: bool) -> HostTranscription:
        """One request, with one restart if the host turned out to be dead."""
        if self._host is None:
            raise RuntimeError("Speech model is not loaded")
        if not self._host.is_alive:
            log.warning("ONNX host is gone; starting it again")
            self._start_host()
        try:
            return self._host.transcribe(samples, timestamps=timestamps)
        except OnnxHostError as exc:
            if not exc.kills_host:
                raise
            log.warning("ONNX host failed (%s); restarting it for the next request", exc)
            self._start_host()
            raise

    def transcribe(self, samples: np.ndarray, enqueued_at: float) -> TranscriptionResult:
        audio_seconds = len(samples) / SAMPLE_RATE
        with self._lock:
            queue_seconds = time.monotonic() - enqueued_at
            started = time.monotonic()
            result = self._call(samples, timestamps=False)
            inference_seconds = time.monotonic() - started
        return TranscriptionResult(
            text=result.text.strip(),
            audio_seconds=audio_seconds,
            queue_seconds=queue_seconds,
            inference_seconds=inference_seconds,
        )

    def transcribe_words(self, samples: np.ndarray) -> HostTranscription:
        """Text plus per-word start/end times, for the overlap-window path."""
        with self._lock:
            return self._call(samples, timestamps=True)

    def transcribe_preview(self, samples: np.ndarray) -> Optional[tuple[str, float]]:
        """A throwaway pass over a recording still in progress.

        Returns the text and how long inference took, or ``None`` if the
        model is busy with a real dictation. The lock is taken without
        blocking on purpose: a preview that has to wait its turn is stale
        by the time it runs, and holding up the transcription the user is
        actually waiting for to produce one would be backwards.
        """
        if self._host is None or samples.size == 0:
            return None
        if not self._lock.acquire(blocking=False):
            return None
        try:
            started = time.monotonic()
            result = self._call(samples, timestamps=False)
            elapsed = time.monotonic() - started
        except Exception as exc:
            log.debug("Preview pass failed: %s", exc)
            return None
        finally:
            self._lock.release()
        return result.text.strip(), elapsed
