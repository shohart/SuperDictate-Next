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


def benchmark_transcribe(args: list[str]) -> int:
    if len(args) < 2 or args[0] not in asr.PROFILES:
        print("usage: --benchmark-transcribe {" + "|".join(asr.PROFILES) + "} <wav...>")
        return 2
    profile, files = args[0], args[1:]

    def on_progress(progress: asr.Progress) -> None:
        if progress.state is asr.State.DOWNLOADING and progress.total_bytes:
            print(f"\rdownloading {progress.fraction:6.1%}", end="", flush=True)

    model = asr.SpeechModel(profile=profile)
    started = time.monotonic()
    if not model.prepare(on_progress):
        print(f"\nmodel failed: {model.error}")
        return 1
    print(f"\nmodel={model.model_id} provider={','.join(model.active_providers)} "
          f"threads={model.threads} ready_in={time.monotonic() - started:.2f}s")
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
    finally:
        model.unload()
    return 0
