"""Command-line diagnostics that exercise the real speech host.

Counterpart of the macOS ``--benchmark-transcribe``: no window, no tray,
no microphone, no keyboard hook — load the model through the same
:class:`~superdictate.asr.SpeechModel` the app uses, transcribe WAV files
on the plain and the segmented path, print text and timings.

    python main.py --benchmark-transcribe parakeet_ultra_onnx a.wav [b.wav ...]
    python main.py --benchmark-transcribe gigaam_v3_onnx a.wav

WAV files must be 16 kHz mono 16-bit PCM (what the recorder captures).
``SUPERDICTATE_ASR_THREADS`` overrides the thread count, as on macOS.
"""

from __future__ import annotations

import threading
import time
import wave

import numpy as np

from . import asr, transcription
from .audio import SAMPLE_RATE


def _read_wav(path: str) -> np.ndarray:
    with wave.open(path, "rb") as handle:
        if (handle.getframerate(), handle.getnchannels(), handle.getsampwidth()) != (SAMPLE_RATE, 1, 2):
            raise SystemExit(f"{path}: need 16 kHz mono 16-bit PCM, got "
                             f"{handle.getframerate()} Hz, {handle.getnchannels()} ch, "
                             f"{8 * handle.getsampwidth()}-bit")
        frames = handle.readframes(handle.getnframes())
    return np.frombuffer(frames, dtype="<i2").astype(np.float32) / 32768.0


#: How much faster than real time ``_stream`` plays the "recording".
STREAM_SPEED = 4.0


def _stream(model, samples: np.ndarray):
    """The recording as the app sees it: the buffer grows at STREAM_SPEED x
    real time while recording-time transcription works on it, then the
    release path runs on the full buffer with what it cached."""
    from .incremental import IncrementalTranscriber

    started = time.monotonic()
    finished = threading.Event()

    def snapshot():
        if finished.is_set():
            return None
        elapsed = (time.monotonic() - started) * STREAM_SPEED
        return samples[:min(len(samples), int(elapsed * SAMPLE_RATE))]

    max_segment, min_segment = transcription.segment_limits(model)
    driver = IncrementalTranscriber(model, snapshot, sample_rate=SAMPLE_RATE,
                                    max_segment_seconds=max_segment,
                                    min_segment_seconds=min_segment,
                                    poll_seconds=1.5 / STREAM_SPEED).start()
    time.sleep(len(samples) / SAMPLE_RATE / STREAM_SPEED)
    finished.set()
    released = time.monotonic()
    cache = driver.finish()
    result = transcription.transcribe(model, samples, time.monotonic(), cache=cache)
    return result, time.monotonic() - released, cache.total_seconds if cache else 0.0


def benchmark_transcribe(args: list[str]) -> int:
    backend = asr.BACKEND_NPU if "--npu" in args else asr.BACKEND_CPU
    args = [a for a in args if a != "--npu"]
    if len(args) < 2 or args[0] not in asr.PROFILES:
        print("usage: --benchmark-transcribe {" + "|".join(asr.PROFILES) + "} [--npu] <wav...>")
        return 2
    profile, files = args[0], args[1:]

    def on_progress(progress: asr.Progress) -> None:
        if progress.state is asr.State.DOWNLOADING and progress.total_bytes:
            print(f"\rdownloading {progress.fraction:6.1%}", end="", flush=True)

    model = asr.SpeechModel(profile=profile, backend=backend)
    started = time.monotonic()
    if not model.prepare(on_progress):
        print(f"\nmodel failed: {model.error}")
        return 1
    print(f"\nmodel={model.model_id} provider={','.join(model.active_providers)} "
          f"threads={model.threads} ready_in={time.monotonic() - started:.2f}s"
          + (f" fallback={model.fallback_reason}" if model.fallback_reason else ""))
    try:
        for path in files:
            samples = _read_wav(path)
            seconds = len(samples) / SAMPLE_RATE
            plain = model.transcribe(samples, time.monotonic())
            print(f"{path}: {seconds:.1f}s audio")
            print(f"  plain      {plain.inference_seconds:6.2f}s RTF {plain.realtime_factor:.3f}: {plain.text}")
            segmented = transcription.transcribe(model, samples, time.monotonic())
            path_name = "overlap" if segmented.overlap_path else "plain"
            print(f"  segmented  {segmented.inference_seconds:6.2f}s RTF {segmented.realtime_factor:.3f} "
                  f"({segmented.segments} segment(s), {path_name}): {segmented.text}")
            streamed, release_seconds, cached = _stream(model, samples)
            print(f"  streamed   {release_seconds:6.2f}s after release "
                  f"({streamed.windows_reused}/{streamed.segments} window(s) done while "
                  f"recording, {cached:.2f}s ASR then) identical={streamed.text == segmented.text}")
    finally:
        model.unload()
    return 0
