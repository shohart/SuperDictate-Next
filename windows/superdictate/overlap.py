"""Overlapping windows, and stitching their transcripts back together.

Port of ``OverlapWindower.swift``, ``SeamDedup.swift`` and
``OverlapAssembly.swift``.

Cutting a dictation at a pause is not enough on its own. The decoder needs
context: a segment that begins exactly where the previous one ended starts
cold, and its first word or two come out worse than the rest. So each
segment borrows a few seconds of its neighbours' audio, every seam is then
transcribed twice, and this module decides which copy to keep.

Three things have to be right:

* **Overlap is carved out of the segment cap, never added on top.** A window
  that borrows four seconds must give up four seconds of its own length, or
  the safety cap that keeps the encoder out of its expensive regime is
  quietly defeated.
* **Ownership splits in silence.** The boundary oracle picks the quietest
  point inside the shared zone, so the handover happens between words.
* **The earlier copy wins.** Where both windows emitted a word at the same
  moment, the earlier window's decoder had more context leading up to it;
  the later window's was still warming up at the very start of its span.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional, Sequence

import numpy as np

from .boundary import BoundaryOracle, chain
from .segmentation import DEFAULT_MAX_SEGMENT_SECONDS, AudioSegment

DEFAULT_OVERLAP_SECONDS = 4.0
#: Two words this close together at a seam are the same word heard twice.
DEFAULT_TOLERANCE_SECONDS = 0.24
#: How many of the previous window's trailing words a candidate is compared
#: against. Not merely a cost bound: timestamps are ordered and every
#: candidate sits at or after the split, so a candidate within tolerance of
#: an earlier reference is necessarily within tolerance of a later one too.
DEFAULT_LOOKBACK = 3


class OverlapAssemblyError(Exception):
    """Assembly could not produce a trustworthy transcript.

    Always recoverable by the caller: the dictation is re-run on the plain
    single-pass path, which is slower but has no seams to get wrong.
    """


@dataclass
class AudioWindow:
    """One window of audio to transcribe, with its ownership span."""

    samples: np.ndarray
    #: Absolute offset of ``samples[0]`` in the original recording.
    start_sample: int
    #: The window's nominal span, before the oracle refines the seam.
    owned_start: int
    owned_end: int
    has_signal: bool


@dataclass(frozen=True)
class Word:
    """One transcribed word with a window-relative start time, in seconds."""

    text: str
    start: float


@dataclass(frozen=True)
class AbsoluteWord:
    """One word with a dictation-relative timestamp."""

    text: str
    seconds: float


@dataclass
class AssemblyResult:
    text: str
    seam_splits: list[int]
    dropped_at_seams: int


def words_from_tokens(tokens: Sequence[str],
                      timestamps: Sequence[float]) -> list[Word]:
    """Group the model's sub-word tokens into words with start times.

    Parakeet emits sentencepiece pieces, not words: "fellow" arrives as
    ``' f'``, ``'ell'``, ``'ow'``. A leading space marks the start of a new
    word, so pieces are joined until the next one carries that mark, and the
    word inherits the timestamp of its FIRST piece — which is the moment the
    word was actually spoken, and the only timestamp a seam can be reasoned
    about with.

    Punctuation arrives as its own space-less piece and therefore attaches
    to the word it follows, which is what we want: dropping " ask" at a seam
    must take its comma with it.
    """
    words: list[Word] = []
    current = ""
    current_start = 0.0
    for token, start in zip(tokens, timestamps):
        if not token:
            continue
        starts_word = token[0] in " \u2581"  # space or sentencepiece ▁
        piece = token.lstrip(" \u2581")
        if starts_word and current:
            words.append(Word(text=current, start=current_start))
            current = ""
        if not current:
            current_start = float(start)
        current += piece
    if current:
        words.append(Word(text=current, start=current_start))
    return words


def add_overlap(segments: Sequence[AudioSegment], sample_rate: float, *,
                overlap_seconds: float = DEFAULT_OVERLAP_SECONDS,
                max_segment_seconds: float = DEFAULT_MAX_SEGMENT_SECONDS
                ) -> list[AudioWindow]:
    """Extend each interior segment into its neighbours.

    A single segment is returned untouched with zero overlap, so an ordinary
    short dictation goes through exactly as it would if this module did not
    exist. The first window gets no leading overlap and the last gets no
    trailing one — there is nothing there to borrow.
    """
    if not segments:
        return []
    if len(segments) == 1:
        only = segments[0]
        return [AudioWindow(samples=only.samples,
                            start_sample=only.start_sample,
                            owned_start=only.start_sample,
                            owned_end=only.start_sample + len(only.samples),
                            has_signal=only.has_signal)]

    max_samples = int(max_segment_seconds * sample_rate)
    requested = int(overlap_seconds * sample_rate)
    windows: list[AudioWindow] = []

    for index, current in enumerate(segments):
        owned_start = current.start_sample
        owned_end = owned_start + len(current.samples)
        # The borrowed audio comes OUT of the cap, split between the two
        # sides. A segment already at the cap borrows nothing.
        budget = max(0, max_samples - len(current.samples))
        half = budget // 2

        before = 0
        if index > 0:
            before = min(requested, half, len(segments[index - 1].samples))
        after = 0
        if index < len(segments) - 1:
            after = min(requested, half, len(segments[index + 1].samples))

        pieces = []
        if before:
            pieces.append(segments[index - 1].samples[-before:])
        pieces.append(current.samples)
        if after:
            pieces.append(segments[index + 1].samples[:after])

        windows.append(AudioWindow(
            samples=np.concatenate(pieces) if len(pieces) > 1 else current.samples,
            start_sample=owned_start - before,
            owned_start=owned_start,
            owned_end=owned_end,
            has_signal=current.has_signal,
        ))
    return windows


def dedup_across_seam(previously_kept: Sequence[AbsoluteWord],
                      candidates: Sequence[AbsoluteWord], *,
                      tolerance_seconds: float = DEFAULT_TOLERANCE_SECONDS,
                      lookback: int = DEFAULT_LOOKBACK) -> list[AbsoluteWord]:
    """Drop the later copy of anything the earlier window already said.

    Scoped strictly to one seam, and this scoping is the whole point. The
    macOS build documents why at length, and it is worth repeating: the same
    rule applied to a whole transcript would drop *any* word starting within
    240 ms of one of the last few kept words — and at real speech rates a
    large share of consecutive words are that close. Run over the full
    stream it silently deletes much of every long dictation. Only the head
    of window *i+1* is ever compared against the tail of window *i*.

    Candidates are never compared against each other: two genuinely distinct
    words on the later side of a seam are not evidence of a duplicate.
    """
    references = list(previously_kept)[-lookback:]
    if not references:
        return list(candidates)
    return [candidate for candidate in candidates
            if not any(abs(reference.seconds - candidate.seconds) <= tolerance_seconds
                       for reference in references)]


def assemble(windows: Sequence[AudioWindow],
             per_window_words: Sequence[Sequence[Word]],
             full_samples: np.ndarray,
             sample_rate: float, *,
             oracles: Sequence[BoundaryOracle] = (),
             tolerance_seconds: float = DEFAULT_TOLERANCE_SECONDS,
             lookback: int = DEFAULT_LOOKBACK) -> AssemblyResult:
    """Stitch per-window words into one transcript.

    Pure and synchronous: everything that needed a model has already
    happened, and the oracles are all allowed to decline. That makes this
    testable with synthetic data and no models at all.
    """
    if not windows:
        raise OverlapAssemblyError("no windows")
    if len(windows) != len(per_window_words):
        raise OverlapAssemblyError(
            f"shape mismatch: {len(windows)} windows, "
            f"{len(per_window_words)} word lists")

    choose_split = chain(oracles)
    total = len(full_samples)

    # -- one ownership split per interior seam ------------------------
    splits: list[int] = []
    for index in range(1, len(windows)):
        previous, current = windows[index - 1], windows[index]
        nominal = previous.owned_end
        raw_start = min(current.start_sample, nominal)
        raw_end = max(previous.start_sample + len(previous.samples), nominal)
        zone_start = max(0, min(raw_start, total))
        zone_end = max(zone_start, min(raw_end, total))

        if zone_end <= zone_start:
            # No overlap budget was available at all — two back-to-back
            # segments already at the cap. Nothing to refine.
            splits.append(max(0, min(nominal, total)))
            continue
        zone = full_samples[zone_start:zone_end]
        splits.append(choose_split(zone, zone_start, zone_end, sample_rate))

    # -- keep each window's words inside its owned span ---------------
    per_window_kept: list[list[AbsoluteWord]] = []
    for index, window in enumerate(windows):
        left = None if index == 0 else splits[index - 1]
        right = None if index == len(windows) - 1 else splits[index]

        kept: list[AbsoluteWord] = []
        for word in per_window_words[index]:
            text = word.text.strip()
            if not text:
                continue
            # A non-finite or absurd timestamp is a corrupt result, not a
            # word: skipping it keeps the rest of the window intact, where
            # letting it through would place it anywhere at all.
            if not np.isfinite(word.start) or abs(word.start) > 1e6:
                continue
            absolute_seconds = window.start_sample / sample_rate + word.start
            absolute_sample = window.start_sample + int(round(word.start * sample_rate))
            if left is not None and absolute_sample < left:
                continue
            if right is not None and absolute_sample >= right:
                continue
            kept.append(AbsoluteWord(text=text, seconds=absolute_seconds))

        # A window built from audio that carried real signal must produce
        # something. If it did not, this path is not to be trusted for this
        # dictation — the caller falls back to the plain single-pass one,
        # which has no seams to get wrong.
        if not kept and window.has_signal:
            raise OverlapAssemblyError(
                f"window {index} carried signal but produced no words")
        per_window_kept.append(kept)

    # -- dedup across each seam ---------------------------------------
    assembled: list[AbsoluteWord] = list(per_window_kept[0])
    dropped = 0
    for index in range(1, len(per_window_kept)):
        split_seconds = splits[index - 1] / sample_rate
        following = per_window_kept[index]
        # Only words inside the tolerance band can collide; everything past
        # it is appended untouched and can never be dropped.
        band_end = split_seconds + tolerance_seconds
        band_count = 0
        for word in following:
            if word.seconds <= band_end:
                band_count += 1
            else:
                break
        band, rest = following[:band_count], following[band_count:]

        survivors = dedup_across_seam(assembled, band,
                                      tolerance_seconds=tolerance_seconds,
                                      lookback=lookback)
        dropped += len(band) - len(survivors)
        assembled.extend(survivors)
        assembled.extend(rest)

    text = " ".join(word.text for word in assembled)
    if not text:
        raise OverlapAssemblyError("assembly produced an empty transcript")
    return AssemblyResult(text=text, seam_splits=splits, dropped_at_seams=dropped)
