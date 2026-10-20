"""Splitting a long recording at natural pauses.

Port of ``swift/Sources/Parakey/PauseSegmenter.swift``.

The problem this solves: the Parakeet encoder's cost grows superlinearly
with audio length, so a five-minute dictation does not take five times as
long as a one-minute one — it takes much worse than that. Cutting the audio
up fixes the cost, but cutting it in the wrong place is far more damaging
than the delay it saves: a cut mid-phrase produces two half-sentences, each
punctuated as if it were complete, and the seam is visible in the output
forever.

So the cut points are pauses, never a clock. Three rules do the work:

* A pause has to be long enough (0.4 s by default) to be a pause rather
  than the gap between two words.
* The segment so far has to already be **substantial** — 15 seconds — before
  a pause is even considered. This is the rule that keeps ordinary
  dictations intact: two sentences with a normal breath between them go
  through as one segment, exactly as if this module did not exist. Only a
  genuinely long dictation ever reaches the threshold and starts cutting.
* A hard cap (25 s) forces a cut when somebody talks without pausing, so
  one unbroken run cannot reach the expensive regime anyway.

Pure and synchronous: no audio hardware, no model, no I/O. The self-tests
drive it directly.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Sequence

import numpy as np

DEFAULT_MAX_SEGMENT_SECONDS = 25.0
DEFAULT_MIN_SEGMENT_SECONDS = 15.0
DEFAULT_PAUSE_THRESHOLD_SECONDS = 0.4
DEFAULT_WINDOW_SECONDS = 0.02
DEFAULT_SILENCE_RMS_THRESHOLD = 0.02
#: How many non-silent analysis windows (~100 ms at a 20 ms window) a
#: segment needs before it counts as carrying real signal. One stray window
#: is a click or a breath, not speech.
DEFAULT_SIGNAL_MIN_WINDOWS = 5


@dataclass
class AudioSegment:
    """One contiguous slice of a recording.

    ``has_signal`` is true only when at least ``signal_min_windows`` windows
    inside the slice were judged non-silent. A single non-silent window is
    deliberately not enough: it would flag a spurious failure on a dictation
    that actually worked. Downstream this distinguishes "the model returned
    nothing because this really was silence" from "the model returned
    nothing despite real speech" — the failure this whole feature exists to
    catch.
    """

    samples: np.ndarray
    has_signal: bool
    #: Absolute offset, in samples, within the buffer that was segmented.
    start_sample: int = 0

    @property
    def end_sample(self) -> int:
        return self.start_sample + len(self.samples)


def segment(samples: np.ndarray, sample_rate: float, *,
            max_segment_seconds: float = DEFAULT_MAX_SEGMENT_SECONDS,
            min_segment_seconds: float = DEFAULT_MIN_SEGMENT_SECONDS,
            pause_threshold_seconds: float = DEFAULT_PAUSE_THRESHOLD_SECONDS,
            window_seconds: float = DEFAULT_WINDOW_SECONDS,
            silence_rms_threshold: float = DEFAULT_SILENCE_RMS_THRESHOLD,
            signal_min_windows: int = DEFAULT_SIGNAL_MIN_WINDOWS
            ) -> list[AudioSegment]:
    """Split ``samples`` into segments cut only at pauses."""
    if samples is None or len(samples) == 0:
        return []

    total = len(samples)
    window_size = max(1, int(window_seconds * sample_rate))
    max_segment_samples = max(window_size, int(max_segment_seconds * sample_rate))
    min_segment_samples = max(0, int(min_segment_seconds * sample_rate))
    pause_window_count = max(1, int(round(pause_threshold_seconds / window_seconds)))

    window_is_silent = _silence_flags(samples, window_size, silence_rms_threshold)

    def has_signal(start: int, end: int) -> bool:
        if start >= end:
            return False
        first = start // window_size
        last = min(len(window_is_silent), (end + window_size - 1) // window_size)
        if first >= last:
            return False
        non_silent = int(np.count_nonzero(~window_is_silent[first:last]))
        return non_silent >= max(1, signal_min_windows)

    segments: list[AudioSegment] = []
    segment_start = 0

    def cut_at(end_sample: int) -> bool:
        nonlocal segment_start
        end = min(end_sample, total)
        if end <= segment_start:
            return False
        segments.append(AudioSegment(
            samples=np.array(samples[segment_start:end], dtype=np.float32),
            has_signal=has_signal(segment_start, end),
            start_sample=segment_start,
        ))
        segment_start = end
        return True

    silent_run_start = None
    for index in range(len(window_is_silent)):
        if window_is_silent[index]:
            if silent_run_start is None:
                silent_run_start = index
        else:
            silent_run_start = None

        current_length = (index + 1) * window_size - segment_start
        made_cut = False

        if (silent_run_start is not None
                and (index - silent_run_start + 1) >= pause_window_count
                and current_length >= min_segment_samples):
            # Cut at the START of the silent run, so the segment that just
            # ended carries no trailing silence and the pause becomes the
            # next segment's leading quiet — harmless there, since ASR
            # ignores it.
            if cut_at(silent_run_start * window_size):
                silent_run_start = None
                made_cut = True

        if not made_cut and current_length >= max_segment_samples:
            # No qualifying pause arrived before the safety cap.
            if cut_at((index + 1) * window_size):
                silent_run_start = None

    cut_at(total)
    return segments


def _silence_flags(samples: np.ndarray, window_size: int,
                   threshold: float) -> np.ndarray:
    """Per-window "is this silence" flags, computed once for the buffer.

    Vectorised rather than looped: at a 20 ms window a five-minute dictation
    is 15 000 windows, and this runs on the transcription worker while the
    user waits.
    """
    total = len(samples)
    full = total // window_size
    flags = np.empty(int(math.ceil(total / window_size)), dtype=bool)

    if full:
        block = np.asarray(samples[:full * window_size],
                           dtype=np.float64).reshape(full, window_size)
        flags[:full] = np.sqrt((block * block).mean(axis=1)) < threshold
    if full * window_size < total:
        tail = np.asarray(samples[full * window_size:], dtype=np.float64)
        flags[full] = math.sqrt(float((tail * tail).mean())) < threshold
    return flags
