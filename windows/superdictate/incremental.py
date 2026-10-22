"""Transcribe while recording.

Port of ``swift/Sources/Parakey/IncrementalTranscription.swift``.

A long dictation is cut into segments at pauses (:mod:`segmentation`) and
transcribed as overlapping windows (:mod:`transcription`). Most of those
windows are fixed long before the hotkey is released, so
:class:`IncrementalTranscriber` transcribes them DURING the recording and
the release path only has the last one or two left to do.

The recording-time results are an exact-match CACHE, never a second
algorithm. At release the segments and windows are computed from the FULL
buffer exactly as before; a window's words are taken from the cache only
when its start sample, sample count and audio checksum all match (and the
model was not reloaded in between); every other window is transcribed
again. Assembly then runs unchanged. So the final text is identical to the
batch path for the same buffer, and the stability rule below only decides
how much recording-time work is wasted, never what the text says.

The cache holds words only. Nothing here produces text, and nothing here
reaches the LLM: correction and rewrite still run once per dictation, on
the fully assembled text, after release.
"""

from __future__ import annotations

import hashlib
import threading
import time
from dataclasses import dataclass, field
from typing import Callable, Optional

import numpy as np

from .logging_setup import get as get_logger
from .overlap import DEFAULT_OVERLAP_SECONDS, AudioWindow, add_overlap
from .segmentation import (DEFAULT_MAX_SEGMENT_SECONDS, DEFAULT_MIN_SEGMENT_SECONDS,
                           DEFAULT_WINDOW_SECONDS, segment_with_pending_pause)

log = get_logger("incremental")

#: How often the recording is looked at, as on macOS.
POLL_SECONDS = 1.5


def window_checksum(samples: np.ndarray) -> bytes:
    """Tells "this window is the same audio" apart, alongside start and count.

    Not FNV-1a as on macOS: the cache never leaves the process, so any
    digest of the exact float bytes does, and this one runs in C.
    """
    data = np.ascontiguousarray(samples, dtype=np.float32).tobytes()
    return hashlib.blake2b(data, digest_size=8).digest()


@dataclass(frozen=True)
class CachedWindow:
    start_sample: int
    sample_count: int
    checksum: bytes
    words: tuple                    # onnx_host.HostWord
    seconds: float                  # ASR time spent on it during the recording


@dataclass
class WindowCache:
    """Recording-time window results for ONE recording.

    ``generation`` is the :attr:`asr.SpeechModel.generation` they were
    transcribed with; a reload since then (model switch, restart, a host
    that had to be started again) invalidates the whole cache.
    """

    generation: int
    entries: dict = field(default_factory=dict)

    def __len__(self) -> int:
        return len(self.entries)

    @property
    def total_seconds(self) -> float:
        return sum(entry.seconds for entry in self.entries.values())

    def contains(self, window: AudioWindow) -> bool:
        return (window.start_sample, len(window.samples)) in self.entries

    def insert(self, entry: CachedWindow) -> None:
        self.entries[(entry.start_sample, entry.sample_count)] = entry

    def lookup(self, window: AudioWindow, generation: int) -> Optional[CachedWindow]:
        """The cached words for ``window`` ONLY if it is the very same audio
        transcribed by the very same loaded model; ``None`` means
        "transcribe it again"."""
        if generation != self.generation:
            return None
        entry = self.entries.get((window.start_sample, len(window.samples)))
        if entry is None or entry.checksum != window_checksum(window.samples):
            return None
        return entry


def stable_windows(prefix: np.ndarray, sample_rate: float, *,
                   max_segment_seconds: float = DEFAULT_MAX_SEGMENT_SECONDS,
                   min_segment_seconds: float = DEFAULT_MIN_SEGMENT_SECONDS,
                   overlap_seconds: float = DEFAULT_OVERLAP_SECONDS) -> list[AudioWindow]:
    """Overlap windows of the growing recording that are guaranteed to come
    out identical (same start, same samples) when the FULL buffer is
    windowed at release.

    Why a window is stable:

    * The segmenter is one greedy left-to-right pass over fixed 20 ms
      analysis windows aligned at sample 0. Its decision at window w depends
      only on windows <= w, and every cut lands on a window boundary. Run on
      the prefix trimmed to whole analysis windows (the trailing partial
      window's RMS could still change), it makes exactly the full buffer's
      cuts up to that point. So every segment but the last (still open) one
      is final.
    * :func:`overlap.add_overlap` gives window i ``before = min(overlap,
      half_budget(i), len(i-1))`` and ``after = min(overlap, half_budget(i),
      len(i+1))``, where half_budget depends only on segment i's own length.
      Window i is therefore fixed once segments i-1 and i are final and
      segment i+1 is either final too or can no longer end up shorter than
      ``min(overlap, half_budget(i))``.
    * The open segment can still be cut at a later pause, but never before
      the silent run that is open at the end of the prefix (if any), and
      never before the end of the trimmed prefix otherwise.

    A window that is final has a segment after it, so the full buffer always
    has >= 2 segments and really takes the overlap path.
    """
    analysis = max(1, int(DEFAULT_WINDOW_SECONDS * sample_rate))
    usable = (len(prefix) // analysis) * analysis
    if usable <= 0:
        return []
    trimmed = prefix[:usable]
    segments, pending = segment_with_pending_pause(
        trimmed, sample_rate,
        max_segment_seconds=max_segment_seconds,
        min_segment_seconds=min_segment_seconds)
    if len(segments) < 2:
        return []

    windows = add_overlap(segments, sample_rate, overlap_seconds=overlap_seconds,
                          max_segment_seconds=max_segment_seconds)
    open_segment = segments[-1]
    earliest_open_end = min(pending if pending is not None else usable, usable)
    open_minimum = max(0, earliest_open_end - open_segment.start_sample)
    max_samples = int(max_segment_seconds * sample_rate)
    requested = int(overlap_seconds * sample_rate)

    stable: list[AudioWindow] = []
    for index in range(len(segments) - 1):
        if index + 1 < len(segments) - 1:
            stable.append(windows[index])
            continue
        half_budget = max(0, max_samples - len(segments[index].samples)) // 2
        if open_minimum >= min(requested, half_budget):
            stable.append(windows[index])
    return stable


class IncrementalTranscriber:
    """Recording-time transcription for ONE recording.

    Every :data:`POLL_SECONDS` it snapshots the audio captured so far, finds
    the stable windows and transcribes the next one not yet cached, one ASR
    call at a time. Nothing happens below the minimum segment length: a
    short dictation is never segmented, so it never gets recording-time work.

    :meth:`finish` (release) and :meth:`cancel` stop the loop and wait for
    the window in flight before returning: it is never interrupted, and its
    result is a stable window the release path will reuse. Any failure ends
    recording-time work and drops the cache; the release path still has the
    full buffer and every existing fallback.
    """

    def __init__(self, model, snapshot: Callable[[], Optional[np.ndarray]], *,
                 sample_rate: float,
                 max_segment_seconds: float = DEFAULT_MAX_SEGMENT_SECONDS,
                 min_segment_seconds: float = DEFAULT_MIN_SEGMENT_SECONDS,
                 poll_seconds: float = POLL_SECONDS) -> None:
        self._model = model
        self._snapshot = snapshot
        self._sample_rate = sample_rate
        self._max_segment = max_segment_seconds
        self._min_segment = min_segment_seconds
        self._poll = poll_seconds
        self._cache = WindowCache(generation=model.generation)
        self._stop = threading.Event()
        self._failed = False
        self._thread: Optional[threading.Thread] = None

    def start(self) -> "IncrementalTranscriber":
        if self._thread is None:
            self._thread = threading.Thread(target=self._run, name="recording-time-asr",
                                            daemon=True)
            self._thread.start()
        return self

    def finish(self) -> Optional[WindowCache]:
        """Release: stop, wait for the window in flight, hand over the cache
        (``None`` when recording-time work failed or produced nothing)."""
        self._stop_and_wait()
        if self._failed or not len(self._cache):
            return None
        return self._cache

    def cancel(self) -> None:
        """Cancelled or abandoned recording: stop and drop everything."""
        self._stop_and_wait()
        self._cache = WindowCache(generation=self._cache.generation)

    def _stop_and_wait(self) -> None:
        self._stop.set()
        thread, self._thread = self._thread, None
        if thread is not None:
            thread.join()

    def _run(self) -> None:
        minimum = int(self._min_segment * self._sample_rate)
        more_ready = False
        while not self._stop.is_set():
            if not more_ready and self._stop.wait(self._poll):
                return
            more_ready = False

            prefix = self._snapshot()
            if prefix is None:
                return
            if len(prefix) < minimum:
                continue
            stable = stable_windows(prefix, self._sample_rate,
                                    max_segment_seconds=self._max_segment,
                                    min_segment_seconds=self._min_segment)
            pending = [window for window in stable if not self._cache.contains(window)]
            if not pending or self._stop.is_set():
                continue
            window = pending[0]
            try:
                started = time.monotonic()
                result = self._model.transcribe_words(window.samples)
                seconds = time.monotonic() - started
            except Exception as exc:
                log.info("recording-time transcription stopped (%s); release "
                         "transcribes the whole buffer", exc)
                self._failed = True
                return
            self._cache.insert(CachedWindow(
                start_sample=window.start_sample, sample_count=len(window.samples),
                checksum=window_checksum(window.samples), words=tuple(result.words),
                seconds=seconds))
            log.debug("recording-time window %.1f-%.1fs done in %.2fs",
                      window.start_sample / self._sample_rate,
                      (window.start_sample + len(window.samples)) / self._sample_rate, seconds)
            more_ready = len(pending) > 1
