"""Choosing where one segment's transcript stops owning the audio.

Port of ``swift/Sources/Parakey/BoundaryOracle.swift`` and
``VadBoundaryOracle.swift``.

When a long dictation is cut into overlapping windows, the overlap belongs
to both transcripts and must be given to exactly one of them, at one sample
offset. Picking that offset badly duplicates a word or loses one. Picking it
in silence costs nothing, which is the whole idea.

Three oracles, tried in order, each free to decline:

1. **VAD** — the centre of the longest genuinely-silent run, as Silero
   judges it. The best answer when it is available.
2. **Mel energy** — the quietest short window, by the same RMS measure
   :mod:`superdictate.segmentation` already uses for pause detection.
   Reused rather than reimplemented, so the two "what counts as quiet"
   definitions in this codebase cannot drift apart.
3. **Midpoint** — always answers, so the chain cannot fail.

Declining is normal, not an error: a missing VAD model, a failed inference,
or an overlap with no quiet moment in it all simply fall through to the next
link. Nothing here may ever block a dictation — its whole job is to make a
cut point slightly better than the middle.
"""

from __future__ import annotations

import math
from typing import Callable, Optional, Protocol, Sequence

import numpy as np

from .segmentation import DEFAULT_WINDOW_SECONDS

#: Below this speech probability a window counts as silent when looking for
#: the longest quiet run. The macOS build's tuned value, inside the
#: documented 0.35–0.5 band.
DEFAULT_SILENCE_PROBABILITY = 0.4


class BoundaryOracle(Protocol):
    """Returns an absolute sample offset, or None to defer to the next link."""

    def choose_split(self, samples: np.ndarray, zone_start: int,
                     zone_end: int, sample_rate: float) -> Optional[int]:
        ...


class VadBoundaryOracle:
    """The centre of the longest silent run, as Silero hears it."""

    def __init__(self, vad, silence_probability: float = DEFAULT_SILENCE_PROBABILITY,
                 window_size_samples: int = 512) -> None:
        #: Anything with ``speech_probabilities(samples)``. Not the concrete
        #: :class:`~superdictate.vad.SileroVad`, so the self-tests can drive
        #: the run-finding logic with a synthetic source and no model.
        self._vad = vad
        self._threshold = silence_probability
        self._window = window_size_samples

    def choose_split(self, samples: np.ndarray, zone_start: int,
                     zone_end: int, sample_rate: float) -> Optional[int]:
        if zone_end <= zone_start or samples is None or len(samples) == 0:
            return None
        probabilities = self._vad.speech_probabilities(samples)
        if probabilities is None or len(probabilities) == 0:
            return None  # VAD unavailable or failed — decline, chain continues
        if self._window <= 0:
            return None

        quiet = np.asarray(probabilities) < self._threshold
        run_start, run_length = _longest_run(quiet)
        if run_start < 0:
            return None  # nothing quiet enough in this zone — decline

        centre = run_start + run_length // 2
        return zone_start + centre * self._window


class MelEnergyBoundaryOracle:
    """The quietest short window in the zone, by RMS."""

    def __init__(self, window_seconds: float = DEFAULT_WINDOW_SECONDS) -> None:
        self._window_seconds = window_seconds

    def choose_split(self, samples: np.ndarray, zone_start: int,
                     zone_end: int, sample_rate: float) -> Optional[int]:
        if zone_end <= zone_start or samples is None or len(samples) == 0:
            return None
        window_size = max(1, int(self._window_seconds * sample_rate))
        buffer = np.asarray(samples, dtype=np.float64)

        full = len(buffer) // window_size
        best_offset = 0
        best_rms = math.inf
        if full:
            block = buffer[:full * window_size].reshape(full, window_size)
            rms = np.sqrt((block * block).mean(axis=1))
            index = int(np.argmin(rms))
            best_rms = float(rms[index])
            best_offset = index * window_size
        tail = buffer[full * window_size:]
        if len(tail):
            tail_rms = math.sqrt(float((tail * tail).mean()))
            if tail_rms < best_rms:
                best_offset = full * window_size
        return zone_start + best_offset


class MidpointBoundaryOracle:
    """Always answers. The guaranteed last link."""

    def choose_split(self, samples: np.ndarray, zone_start: int,
                     zone_end: int, sample_rate: float) -> Optional[int]:
        if zone_end < zone_start:
            return None
        return zone_start + (zone_end - zone_start) // 2


def chain(oracles: Sequence[BoundaryOracle]) -> Callable[..., int]:
    """Build a chain that always produces an answer.

    A midpoint oracle is appended whatever the caller passed, so the chain
    cannot fail, and every answer is clamped back into the zone regardless
    of which link produced it — a buggy oracle must never be able to move
    ownership outside the overlap it was asked about.
    """
    links = list(oracles) + [MidpointBoundaryOracle()]

    def choose(samples: np.ndarray, zone_start: int, zone_end: int,
               sample_rate: float) -> int:
        for oracle in links:
            try:
                split = oracle.choose_split(samples, zone_start, zone_end,
                                            sample_rate)
            except Exception:
                # An oracle that raises has declined, loudly. The chain must
                # survive it; a seam is not worth an exception reaching the
                # dictation.
                continue
            if split is not None:
                return min(max(split, zone_start), zone_end)
        # Only reachable for an inverted zone, which still needs an answer.
        return zone_start

    return choose


def _longest_run(flags: np.ndarray) -> tuple[int, int]:
    """Start index and length of the longest run of True, or (-1, 0)."""
    best_start, best_length = -1, 0
    current_start, current_length = -1, 0
    for index, flag in enumerate(flags):
        if flag:
            if current_start < 0:
                current_start = index
            current_length += 1
            if current_length > best_length:
                best_start, best_length = current_start, current_length
        else:
            current_start, current_length = -1, 0
    return best_start, best_length
