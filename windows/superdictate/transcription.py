"""Long dictation: pause segmentation, overlap windows, seam dedup.

Port of ``transcribeSegmented`` (``swift/Sources/Parakey/TranscriptionWorker.swift``).
The pieces — :mod:`segmentation`, :mod:`overlap`, :mod:`boundary` — were
already here; this is the driver that puts them on the dictation path.

* One segment (any dictation under ~15 s, i.e. nearly all of them): one
  plain pass, exactly as if none of this existed.
* Several segments: every overlap window is transcribed with word
  timestamps, the seams are split in silence (VAD → mel energy → midpoint)
  and a word heard twice at a seam is kept once.
* Anything at all going wrong on the overlap path falls back to the plain
  path: each pause-bounded segment transcribed on its own and the texts
  joined. A failed segment loses only itself, never the dictation.

Windows already transcribed during the recording (:mod:`incremental`) are
taken from its exact-match cache instead of being transcribed again.

A model with a fixed input length (the NPU builds: Parakeet takes 15 s at a
time) caps the segments at that length (:func:`segment_limits`), so every
cut still lands on a pause and every seam is still placed by the VAD, and
no window ever has to be cut again by the clock inside the model host.
"""

from __future__ import annotations

import os
import threading
import time
from dataclasses import dataclass
from typing import Optional

import numpy as np

from .asr import SpeechModel, TranscriptionResult
from .audio import SAMPLE_RATE
from .boundary import MelEnergyBoundaryOracle, MidpointBoundaryOracle, VadBoundaryOracle
from .logging_setup import get as get_logger
from .overlap import OverlapAssemblyError, Word, add_overlap, assemble
from .segmentation import DEFAULT_MAX_SEGMENT_SECONDS, DEFAULT_MIN_SEGMENT_SECONDS, segment

log = get_logger("transcription")

_vad_lock = threading.Lock()
_vad = None
_vad_tried = False
#: True when the last attempt failed only for want of the model file, which
#: downloads in the background at startup (vad.ensure_model): worth another
#: try once it is there. Any other failure (no DLL) is final.
_vad_waiting_for_model = False


def _shared_vad():
    """Silero VAD, loaded once on first use; ``None`` when unavailable."""
    global _vad, _vad_tried, _vad_waiting_for_model
    with _vad_lock:
        if _vad_tried and _vad is None and _vad_waiting_for_model:
            from .vad import VAD_MODEL_SIZE, model_path

            try:
                _vad_tried = os.path.getsize(model_path()) != VAD_MODEL_SIZE
            except OSError:
                pass
        if not _vad_tried:
            _vad_tried = True
            _vad_waiting_for_model = False
            try:
                from .vad import SileroVad

                candidate = SileroVad()
                _vad = candidate if candidate.is_available else None
                if _vad is None:
                    _vad_waiting_for_model = "not downloaded" in (candidate.error or "")
                    log.info("Silero VAD unavailable (%s); seams use mel energy",
                             candidate.error)
            except Exception as exc:
                log.info("Silero VAD unavailable (%s); seams use mel energy", exc)
                _vad = None
        return _vad


@dataclass
class SegmentedResult(TranscriptionResult):
    segments: int = 1
    overlap_path: bool = False
    had_segment_failure: bool = False
    #: Windows whose words came from recording-time transcription.
    windows_reused: int = 0


def segment_limits(model) -> tuple[float, float]:
    """``(max, min)`` segment seconds for this model.

    The defaults (25 s / 15 s) unless the model takes a fixed window shorter
    than 25 s; then the cap is that window, since an overlap window is never
    longer than the cap (:func:`overlap.add_overlap`), and the minimum keeps
    the defaults' proportion.
    """
    window = float(getattr(model, "max_window_seconds", 0.0) or 0.0)
    if window <= 0 or window >= DEFAULT_MAX_SEGMENT_SECONDS:
        return DEFAULT_MAX_SEGMENT_SECONDS, DEFAULT_MIN_SEGMENT_SECONDS
    ratio = DEFAULT_MIN_SEGMENT_SECONDS / DEFAULT_MAX_SEGMENT_SECONDS
    return window, window * ratio


def transcribe(model: SpeechModel, samples: np.ndarray, enqueued_at: float,
               cache=None) -> SegmentedResult:
    """``cache``: an :class:`incremental.WindowCache` from this recording, or None."""
    audio_seconds = len(samples) / SAMPLE_RATE
    max_segment, min_segment = segment_limits(model)
    segments = segment(samples, SAMPLE_RATE, max_segment_seconds=max_segment,
                       min_segment_seconds=min_segment)
    if len(segments) <= 1:
        plain = model.transcribe(samples, enqueued_at)
        return SegmentedResult(text=plain.text, audio_seconds=plain.audio_seconds,
                               queue_seconds=plain.queue_seconds,
                               inference_seconds=plain.inference_seconds)

    queue_seconds = time.monotonic() - enqueued_at
    started = time.monotonic()
    try:
        text, reused = _overlap_path(model, samples, segments, max_segment, cache)
        log.info("overlap transcription path: succeeded (%d segments, %d from the "
                 "recording-time cache)", len(segments), reused)
        return SegmentedResult(text=text, audio_seconds=audio_seconds,
                               queue_seconds=queue_seconds,
                               inference_seconds=time.monotonic() - started,
                               segments=len(segments), overlap_path=True,
                               windows_reused=reused)
    except Exception as exc:
        log.warning("overlap transcription path failed (%s), falling back to plain segmentation",
                    exc)

    texts: list[str] = []
    failed = False
    last_error: Optional[BaseException] = None
    for piece in segments:
        if not piece.has_signal:
            continue
        try:
            text = model.transcribe(piece.samples, time.monotonic()).text
        except Exception as exc:
            failed = True
            last_error = exc
            continue
        if text:
            texts.append(text)
    if last_error is not None:
        log.warning("segmented transcription ASR error: %s", last_error)
        if not texts:
            raise last_error
    return SegmentedResult(text=" ".join(texts), audio_seconds=audio_seconds,
                           queue_seconds=queue_seconds,
                           inference_seconds=time.monotonic() - started,
                           segments=len(segments), had_segment_failure=failed)


def _overlap_path(model: SpeechModel, samples: np.ndarray, segments, max_segment: float,
                  cache=None) -> tuple[str, int]:
    # ``segments`` must be segment()'s direct output, never filtered or
    # reordered: every start_sample, and so every seam time, depends on it.
    windows = add_overlap(segments, SAMPLE_RATE, max_segment_seconds=max_segment)
    per_window: list[list[Word]] = []
    reused = 0
    for window in windows:
        if not window.has_signal:
            per_window.append([])
            continue
        cached = cache.lookup(window, model.generation) if cache is not None else None
        if cached is not None:
            reused += 1
            words = cached.words
        else:
            words = model.transcribe_words(window.samples).words
        per_window.append([Word(text=word.text, start=word.start) for word in words])

    oracles = []
    vad = _shared_vad()
    if vad is not None:
        oracles.append(VadBoundaryOracle(vad))
    oracles += [MelEnergyBoundaryOracle(), MidpointBoundaryOracle()]
    assembled = assemble(windows, per_window, samples, SAMPLE_RATE, oracles=oracles)
    log.info("overlap: %d windows, %d seam words dropped",
             len(windows), assembled.dropped_at_seams)
    if not assembled.text.strip():
        raise OverlapAssemblyError("empty transcript")
    return assembled.text, reused
