"""Silero VAD, for finding where speech actually stops.

Port of the macOS build's ``superdictate_silero_vad`` bridge
(``swift/Sources/parakeet_cpp/bridge/superdictate_silero_vad.cpp``) and the
``SileroVadEngine`` above it — with one simplification the platform allows.

The macOS build vendors whisper.cpp's Silero implementation into its own
target and wraps it in a hand-written C bridge, because two copies of ggml
cannot be linked into one binary there. Windows has no such problem: the
same functions are already exported from ``whisper.dll``, so this binds them
directly with ``ctypes``. Same upstream code, same model file, one layer
fewer.

Everything here degrades rather than fails. A missing DLL, a missing model,
an inference that throws — each leaves :attr:`SileroVad.is_available` false
and the callers fall back to their own heuristics. A dictation must never
be blocked by a component whose entire job is to make a cut point slightly
better.
"""

from __future__ import annotations

import ctypes
import os
import threading
from typing import Optional

import numpy as np

from . import paths
from .logging_setup import get as get_logger

log = get_logger("vad")

#: The pinned model, same file and digest as the macOS build
#: (swift/Sources/parakeet_cpp/upstream-vad/PROVENANCE.md). Converted from
#: Silero VAD v6.2.0 with whisper.cpp's own convert-silero-vad-to-ggml.py.
VAD_MODEL_REPOSITORY = "ggml-org/whisper-vad"
VAD_MODEL_REVISION = "9ffd54a1e1ee413ddf265af9913beaf518d1639b"
VAD_MODEL_FILENAME = "ggml-silero-v6.2.0.bin"
VAD_MODEL_SHA256 = "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"
VAD_MODEL_URL = (f"https://huggingface.co/{VAD_MODEL_REPOSITORY}/resolve/"
                 f"{VAD_MODEL_REVISION}/{VAD_MODEL_FILENAME}")

#: Silero's own analysis window at 16 kHz. Upstream does not expose the
#: value it read from the model, and the macOS bridge derives it by probing;
#: here it is asserted instead — the probability count and the sample count
#: are both known after a run, so a mismatch is caught rather than assumed.
WINDOW_SIZE_SAMPLES = 512

SAMPLE_RATE = 16000


class _VadContextParams(ctypes.Structure):
    _fields_ = [
        ("n_threads", ctypes.c_int),
        ("use_gpu", ctypes.c_bool),
        ("gpu_device", ctypes.c_int),
    ]


def model_path() -> str:
    return str(paths.MODELS_DIR / "vad" / VAD_MODEL_FILENAME)


def _engine_directory() -> str:
    return str(paths.resource_path("engines"))


class SileroVad:
    """One loaded VAD model, guarded by a lock.

    The underlying context carries LSTM state across calls, so two threads
    running inference on it concurrently would interleave that state and
    produce nonsense. Every call is serialised; the model is small and the
    app only ever has one dictation in flight.
    """

    def __init__(self, path: Optional[str] = None) -> None:
        self._lock = threading.RLock()
        self._lib = None
        self._ctx = None
        self._error = ""
        self._load(path or model_path())

    # -- lifecycle ---------------------------------------------------

    def _load(self, path: str) -> None:
        if not os.path.exists(path):
            self._error = f"VAD model not downloaded: {path}"
            log.info("%s", self._error)
            return
        try:
            self._lib = _load_library()
        except OSError as exc:
            self._error = f"whisper.dll not loadable: {exc}"
            log.info("%s", self._error)
            return

        try:
            params = self._lib.whisper_vad_default_context_params()
            # CPU on purpose. The model is roughly a megabyte and one pass
            # over a long dictation costs milliseconds; putting it on the
            # GPU would contend for the device the ASR model is using for
            # work that is not the bottleneck.
            params.use_gpu = False
            self._ctx = self._lib.whisper_vad_init_from_file_with_params(
                path.encode("utf-8"), params)
        except Exception as exc:  # a broken DLL must not take the app down
            self._error = f"VAD init raised: {exc}"
            log.warning("%s", self._error)
            self._ctx = None
            return

        if not self._ctx:
            self._error = f"VAD model failed to load: {path}"
            log.warning("%s", self._error)
            return
        log.info("Silero VAD loaded from %s", path)

    @property
    def is_available(self) -> bool:
        return self._ctx is not None

    @property
    def error(self) -> str:
        return self._error

    def close(self) -> None:
        with self._lock:
            if self._ctx is not None and self._lib is not None:
                self._lib.whisper_vad_free(self._ctx)
            self._ctx = None

    # -- inference ---------------------------------------------------

    def speech_probabilities(self, samples: np.ndarray) -> Optional[np.ndarray]:
        """One speech probability per analysis window, or None on any failure.

        ``samples`` must already be mono float32 at 16 kHz — the app's fixed
        rate everywhere, so nothing resamples here.
        """
        if not self.is_available or samples is None or len(samples) == 0:
            return None
        buffer = np.ascontiguousarray(samples, dtype=np.float32)
        with self._lock:
            try:
                ok = self._lib.whisper_vad_detect_speech(
                    self._ctx,
                    buffer.ctypes.data_as(ctypes.POINTER(ctypes.c_float)),
                    ctypes.c_int(len(buffer)))
                if not ok:
                    log.debug("VAD inference returned false")
                    return None
                count = int(self._lib.whisper_vad_n_probs(self._ctx))
                if count <= 0:
                    return None
                pointer = self._lib.whisper_vad_probs(self._ctx)
                if not pointer:
                    return None
                # Copied, not wrapped: the buffer belongs to the context and
                # the next call overwrites it.
                return np.ctypeslib.as_array(pointer, shape=(count,)).copy()
            except Exception as exc:
                log.warning("VAD inference raised: %s", exc)
                return None


def _dll_directories(engine_directory: str) -> list[str]:
    """Directories to make loadable, most specific first.

    Both CUDA layouts are listed because they differ by version and getting
    it wrong is invisible until load time: CUDA 12 put the runtime DLLs in
    ``bin``, CUDA 13 moved them to ``bin\\x64``. Listing both costs nothing
    and spares the next person this exact hour.
    """
    directories = [engine_directory]
    cuda = os.environ.get("CUDA_PATH")
    if cuda:
        directories.append(os.path.join(cuda, "bin", "x64"))
        directories.append(os.path.join(cuda, "bin"))
    return [d for d in directories if os.path.isdir(d)]


def _load_library():
    """Open whisper.dll from the engines directory, with its dependencies.

    ``ggml.dll`` and friends sit beside it and are not on any search path,
    so the directory is added explicitly rather than relying on the process
    working directory happening to be right.
    """
    directory = _engine_directory()
    dll = os.path.join(directory, "whisper.dll")
    if not os.path.exists(dll):
        raise OSError(f"not found: {dll}")

    # whisper.dll pulls in the ggml family beside it, and the CUDA backend
    # pulls in the CUDA runtime, which lives in the toolkit rather than
    # next to us. Both directories are registered explicitly: relying on
    # the process working directory or a user PATH is how this fails on
    # somebody else's machine.
    if hasattr(os, "add_dll_directory"):
        for candidate in _dll_directories(directory):
            try:
                os.add_dll_directory(candidate)
            except OSError:
                continue
    library = ctypes.CDLL(dll)

    library.whisper_vad_default_context_params.restype = _VadContextParams
    library.whisper_vad_default_context_params.argtypes = []

    library.whisper_vad_init_from_file_with_params.restype = ctypes.c_void_p
    library.whisper_vad_init_from_file_with_params.argtypes = [
        ctypes.c_char_p, _VadContextParams]

    library.whisper_vad_detect_speech.restype = ctypes.c_bool
    library.whisper_vad_detect_speech.argtypes = [
        ctypes.c_void_p, ctypes.POINTER(ctypes.c_float), ctypes.c_int]

    library.whisper_vad_n_probs.restype = ctypes.c_int
    library.whisper_vad_n_probs.argtypes = [ctypes.c_void_p]

    library.whisper_vad_probs.restype = ctypes.POINTER(ctypes.c_float)
    library.whisper_vad_probs.argtypes = [ctypes.c_void_p]

    library.whisper_vad_free.restype = None
    library.whisper_vad_free.argtypes = [ctypes.c_void_p]

    _silence_upstream_logging(library)
    return library


#: Kept alive at module scope on purpose: ctypes callbacks are collected as
#: soon as the last Python reference goes, and whisper.dll would then call
#: into freed memory on its next log line.
_LOG_CALLBACK = None


def _silence_upstream_logging(library) -> None:
    """Route whisper.cpp's own chatter into our log, not into stderr.

    Upstream prints device banners, buffer sizes and per-call timings to
    stderr. A windowed build has no stderr at all — this fork has already
    been bitten by that once, where the model download died on the first
    write to a missing stream — and even with a console it is noise the
    user did not ask for. Nothing here is fatal if the symbol is absent:
    an older DLL just keeps printing.
    """
    global _LOG_CALLBACK
    try:
        prototype = ctypes.CFUNCTYPE(None, ctypes.c_int, ctypes.c_char_p,
                                     ctypes.c_void_p)

        def sink(level: int, text: bytes, _user) -> None:
            try:
                message = (text or b"").decode("utf-8", "replace").rstrip()
                if message:
                    log.debug("whisper: %s", message)
            except Exception:
                pass

        _LOG_CALLBACK = prototype(sink)
        library.whisper_log_set.restype = None
        library.whisper_log_set.argtypes = [prototype, ctypes.c_void_p]
        library.whisper_log_set(_LOG_CALLBACK, None)
    except Exception as exc:
        log.debug("Could not install the whisper log sink: %s", exc)
