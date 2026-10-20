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
"""

from __future__ import annotations

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
from .segmentation import segment

log = get_logger("transcription")

_vad_lock = threading.Lock()
_vad = None
_vad_tried = False


def _shared_vad():
    """Silero VAD, loaded once on first use; ``None`` when unavailable."""
    global _vad, _vad_tried
    with _vad_lock:
        if not _vad_tried:
            _vad_tried = True
            try:
                from .vad import SileroVad

                candidate = SileroVad()
                _vad = candidate if candidate.is_available else None
                if _vad is None:
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


def transcribe(model: SpeechModel, samples: np.ndarray, enqueued_at: float) -> SegmentedResult:
    audio_seconds = len(samples) / SAMPLE_RATE
    segments = segment(samples, SAMPLE_RATE)
    if len(segments) <= 1:
        plain = model.transcribe(samples, enqueued_at)
        return SegmentedResult(text=plain.text, audio_seconds=plain.audio_seconds,
                               queue_seconds=plain.queue_seconds,
                               inference_seconds=plain.inference_seconds)

    queue_seconds = time.monotonic() - enqueued_at
    started = time.monotonic()
    try:
        text = _overlap_path(model, samples, segments)
        log.info("overlap transcription path: succeeded (%d segments)", len(segments))
        return SegmentedResult(text=text, audio_seconds=audio_seconds,
                               queue_seconds=queue_seconds,
                               inference_seconds=time.monotonic() - started,
                               segments=len(segments), overlap_path=True)
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


def _overlap_path(model: SpeechModel, samples: np.ndarray, segments) -> str:
    windows = add_overlap(segments, SAMPLE_RATE)
    per_window: list[list[Word]] = []
    for window in windows:
        if not window.has_signal:
            per_window.append([])
            continue
        result = model.transcribe_words(window.samples)
        per_window.append([Word(text=word.text, start=word.start) for word in result.words])

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
    return assembled.text
