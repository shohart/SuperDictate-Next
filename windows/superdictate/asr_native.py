"""Parakeet through the native ggml engine, as an alternative to ONNX.

The port started on ONNX Runtime, which is a sound choice and stays the
fallback. This module adds the engine the macOS build actually uses — the
same ggml Parakeet, through a thin C bridge (``native/``) compiled to
``sd_parakeet.dll`` — for two reasons:

* **The device is a real choice.** ONNX Runtime's CUDA provider is all or
  nothing and drags cuDNN along; ggml runs the same model on the CPU or the
  GPU from one build, and on real hardware the right answer is not always
  the GPU. Parakeet has repeatedly come out fastest *and* most accurate on
  the CPU, which is why the engine and the device are separate settings.
* **The transcript matches the Mac's.** Same weights, same decoder, same
  quirks — so a bug reproduced on one platform is a bug on the other, and a
  prompt tuned against one model's output is tuned against both.

The container differs from the Mac's, and this is the one place the two
platforms genuinely diverge: whisper.cpp's in-tree Parakeet rejects
``mudler/parakeet-cpp-gguf``'s file with "bad magic". Same NVIDIA TDT
0.6b v3 checkpoint, different wrapper — see ``PROVENANCE.md``.
"""

from __future__ import annotations

import ctypes
import os
import threading
import time
from dataclasses import dataclass
from typing import Optional

import numpy as np

from . import paths
from .logging_setup import get as get_logger
from .vad import _dll_directories  # same search-path rules, one definition

log = get_logger("asr.native")

#: Pinned to the same checkpoint the macOS build uses, in whisper.cpp's own
#: container. f16 rather than q8_0 because that is what upstream publishes
#: for this engine.
MODEL_REPOSITORY = "ggml-org/parakeet-GGUF"
MODEL_REVISION = "main"
MODEL_FILENAME = "ggml-parakeet-tdt-0.6b-v3-f16.bin"
MODEL_URL = (f"https://huggingface.co/{MODEL_REPOSITORY}/resolve/"
             f"{MODEL_REVISION}/{MODEL_FILENAME}")

SAMPLE_RATE = 16000

SD_PARAKEET_OK = 0
_STATUS_NAMES = {
    0: "ok",
    1: "null argument",
    2: "model failed to load",
    3: "no audio",
    4: "inference failed",
    5: "native exception",
}


class _Result(ctypes.Structure):
    _fields_ = [
        ("text", ctypes.c_char_p),
        ("token_blob", ctypes.POINTER(ctypes.c_char)),
        ("token_blob_bytes", ctypes.c_int64),
        ("token_times", ctypes.POINTER(ctypes.c_float)),
        ("token_word_start", ctypes.POINTER(ctypes.c_uint8)),
        ("token_count", ctypes.c_int32),
    ]


@dataclass
class NativeTranscription:
    text: str
    tokens: list[str]
    #: One start time per token, in seconds from the beginning of the audio.
    timestamps: list[float]
    #: True where the model says a new word begins. Authoritative, unlike
    #: inferring it from a leading space on the token text.
    word_starts: list[bool]
    inference_seconds: float


def model_path() -> str:
    return str(paths.MODELS_DIR / "parakeet-native" / MODEL_FILENAME)


def is_available() -> bool:
    """Whether the engine could run at all: bridge present and model on disk."""
    bridge = os.path.join(str(paths.resource_path("engines")), "sd_parakeet.dll")
    return os.path.exists(bridge) and os.path.exists(model_path())


class NativeParakeet:
    """One loaded model. Calls are serialised; the context is not reentrant."""

    def __init__(self, path: Optional[str] = None, *, use_gpu: bool = False,
                 gpu_device: int = 0, n_threads: int = 0,
                 allow_gpu: bool = False) -> None:
        # CPU unless somebody explicitly overrides it, and the reason is not
        # performance. whisper.cpp's Parakeet CUDA path is broken as of the
        # pinned commit: it returns a runaway decode — "tamb tamb tamb…" —
        # or an empty transcript, non-deterministically, and it does so
        # through upstream's own parakeet-cli with no bridge of ours
        # involved, so this is not a binding bug. CPU is correct every time.
        #
        # This is the worst failure shape there is: not a crash, not an
        # error, just confidently wrong text pasted into whatever the user
        # was typing into. Offering the switch would be offering that.
        # `allow_gpu` exists so the day upstream fixes it can be checked
        # without editing this file.
        if use_gpu and not allow_gpu:
            log.info("Native Parakeet: ignoring the GPU request — upstream's "
                     "CUDA path returns corrupt transcripts (see this "
                     "constructor's comment)")
            use_gpu = False
        self._lock = threading.RLock()
        self._lib = None
        self._ctx = None
        self._error = ""
        self._n_threads = n_threads
        self._load(path or model_path(), use_gpu, gpu_device)

    def _load(self, path: str, use_gpu: bool, gpu_device: int) -> None:
        if not os.path.exists(path):
            self._error = f"model not downloaded: {path}"
            log.info("%s", self._error)
            return
        try:
            self._lib = _load_library()
        except OSError as exc:
            self._error = f"sd_parakeet.dll not loadable: {exc}"
            log.info("%s", self._error)
            return

        context = ctypes.c_void_p()
        try:
            status = self._lib.sd_parakeet_create(
                path.encode("utf-8"), ctypes.c_bool(use_gpu),
                ctypes.c_int(gpu_device), ctypes.byref(context))
        except Exception as exc:
            self._error = f"engine init raised: {exc}"
            log.warning("%s", self._error)
            return
        if status != SD_PARAKEET_OK or not context.value:
            self._error = f"engine init failed: {_STATUS_NAMES.get(status, status)}"
            log.warning("%s", self._error)
            return
        self._ctx = context
        log.info("Native Parakeet loaded from %s (gpu=%s)", path, use_gpu)

    @property
    def is_ready(self) -> bool:
        return self._ctx is not None

    @property
    def error(self) -> str:
        return self._error

    def close(self) -> None:
        with self._lock:
            if self._ctx is not None and self._lib is not None:
                self._lib.sd_parakeet_destroy(self._ctx)
            self._ctx = None

    def transcribe(self, samples: np.ndarray) -> Optional[NativeTranscription]:
        """Transcribe mono float32 at 16 kHz. None on any failure."""
        if not self.is_ready or samples is None or len(samples) == 0:
            return None
        buffer = np.ascontiguousarray(samples, dtype=np.float32)
        result = _Result()
        with self._lock:
            started = time.monotonic()
            try:
                status = self._lib.sd_parakeet_transcribe(
                    self._ctx,
                    buffer.ctypes.data_as(ctypes.POINTER(ctypes.c_float)),
                    ctypes.c_int64(len(buffer)),
                    ctypes.c_int32(self._n_threads),
                    ctypes.byref(result))
            except Exception as exc:
                log.warning("Native transcription raised: %s", exc)
                return None
            elapsed = time.monotonic() - started

            if status != SD_PARAKEET_OK:
                log.warning("Native transcription failed: %s",
                            _STATUS_NAMES.get(status, status))
                return None
            try:
                return self._copy_out(result, elapsed)
            finally:
                # Always, on every path: the bridge malloc'd three buffers
                # and nothing else will free them.
                self._lib.sd_parakeet_free_result(ctypes.byref(result))

    @staticmethod
    def _copy_out(result: _Result, elapsed: float) -> NativeTranscription:
        text = (result.text or b"").decode("utf-8", "replace")
        count = int(result.token_count)

        tokens: list[str] = []
        if count and result.token_blob:
            blob = ctypes.string_at(result.token_blob, int(result.token_blob_bytes))
            # The blob holds `count` NUL-terminated strings back to back, so
            # the split leaves one trailing empty piece to discard.
            pieces = blob.split(b"\0")
            tokens = [piece.decode("utf-8", "replace") for piece in pieces[:count]]

        timestamps = ([float(result.token_times[i]) for i in range(count)]
                      if result.token_times else [])
        word_starts = ([bool(result.token_word_start[i]) for i in range(count)]
                       if result.token_word_start else [])
        return NativeTranscription(text=text.strip(), tokens=tokens,
                                   timestamps=timestamps, word_starts=word_starts,
                                   inference_seconds=elapsed)


def words(transcription: NativeTranscription):
    """Group tokens into :class:`~superdictate.overlap.Word` values.

    Uses the model's own ``is_word_start`` flags rather than the leading-space
    convention, and falls back to that convention only when the flags are
    absent — an older bridge, or a model that does not report them.
    """
    from .overlap import Word, words_from_tokens

    if not transcription.word_starts:
        return words_from_tokens(transcription.tokens, transcription.timestamps)

    result: list[Word] = []
    current = ""
    start = 0.0
    for token, stamp, is_start in zip(transcription.tokens,
                                      transcription.timestamps,
                                      transcription.word_starts):
        piece = token.lstrip(" ▁")
        if is_start and current:
            result.append(Word(text=current, start=start))
            current = ""
        if not current:
            start = float(stamp)
        current += piece
    if current:
        result.append(Word(text=current, start=start))
    return result


def _load_library():
    directory = str(paths.resource_path("engines"))
    dll = os.path.join(directory, "sd_parakeet.dll")
    if not os.path.exists(dll):
        raise OSError(f"not found: {dll}")
    if hasattr(os, "add_dll_directory"):
        for candidate in _dll_directories(directory):
            try:
                os.add_dll_directory(candidate)
            except OSError:
                continue
    library = ctypes.CDLL(dll)

    library.sd_parakeet_create.restype = ctypes.c_int
    library.sd_parakeet_create.argtypes = [
        ctypes.c_char_p, ctypes.c_bool, ctypes.c_int,
        ctypes.POINTER(ctypes.c_void_p)]

    library.sd_parakeet_transcribe.restype = ctypes.c_int
    library.sd_parakeet_transcribe.argtypes = [
        ctypes.c_void_p, ctypes.POINTER(ctypes.c_float), ctypes.c_int64,
        ctypes.c_int32, ctypes.POINTER(_Result)]

    library.sd_parakeet_free_result.restype = None
    library.sd_parakeet_free_result.argtypes = [ctypes.POINTER(_Result)]

    library.sd_parakeet_destroy.restype = None
    library.sd_parakeet_destroy.argtypes = [ctypes.c_void_p]
    return library


class NativeSpeechModel:
    """The native engine behind :class:`superdictate.asr.SpeechModel`'s API.

    Same surface as the ONNX model — ``prepare``/``transcribe``/``unload``
    plus the state and progress reporting — so the controller does not know
    or care which engine it is driving.
    """

    def __init__(self, compute_provider: str = "cpu", **_ignored) -> None:
        # The device argument is accepted and ignored: this engine is CPU
        # only until upstream's CUDA path stops corrupting transcripts. It
        # is accepted rather than rejected so the two engines stay
        # interchangeable at the call site.
        self._engine: Optional[NativeParakeet] = None
        self._state = "idle"
        self._error: Optional[str] = None

    @property
    def state(self) -> str:
        return self._state

    @property
    def error(self) -> Optional[str]:
        return self._error

    @property
    def is_ready(self) -> bool:
        return self._engine is not None and self._engine.is_ready

    @property
    def active_providers(self) -> list:
        return ["ggml-cpu"] if self.is_ready else []

    @property
    def uses_gpu(self) -> bool:
        return False

    def prepare(self, on_progress=None) -> bool:
        from .asr import Progress, State

        def report(state, message=""):
            self._state = state
            if on_progress is not None:
                try:
                    on_progress(Progress(state, message=message))
                except Exception:
                    pass

        if not os.path.exists(model_path()):
            self._error = f"model not downloaded: {model_path()}"
            report(State.FAILED, self._error)
            return False

        report(State.LOADING, "loading")
        engine = NativeParakeet()
        if not engine.is_ready:
            self._error = engine.error
            report(State.FAILED, engine.error)
            return False
        self._engine = engine
        # A first pass over half a second of silence, for the same reason
        # the ONNX model does one: the first real dictation should not pay
        # for whatever the engine allocates on its first call.
        try:
            engine.transcribe(np.zeros(SAMPLE_RATE // 2, dtype=np.float32))
        except Exception:
            pass
        report(State.READY, "ready")
        return True

    def unload(self) -> None:
        if self._engine is not None:
            self._engine.close()
        self._engine = None
        self._state = "idle"

    def transcribe(self, samples: np.ndarray, enqueued_at: float):
        from .asr import TranscriptionResult

        if self._engine is None:
            raise RuntimeError("Speech model is not loaded")
        queue_seconds = time.monotonic() - enqueued_at
        result = self._engine.transcribe(samples)
        if result is None:
            raise RuntimeError(self._engine.error or "native transcription failed")
        return TranscriptionResult(
            text=result.text,
            audio_seconds=len(samples) / SAMPLE_RATE,
            queue_seconds=queue_seconds,
            inference_seconds=result.inference_seconds,
        )

    def transcribe_preview(self, samples: np.ndarray):
        """No live preview on this engine.

        The preview re-transcribes the whole recording every second or so,
        and this engine is slower per pass than the one the preview was
        tuned against; running it would spend more time on previews than on
        the dictation. Returning None simply leaves the preview blank.
        """
        return None
