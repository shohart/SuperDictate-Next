"""Learning corrections from edits made right after a dictation is pasted.

Port of ``PostInsertionEditWatcher`` (``swift/Sources/Parakey/
VocabularyLearning.swift``). After a paste, the field the text went into is
watched for :data:`WATCH_SECONDS`. If the user hand-corrects a short span of
what was just inserted («инглиш» → «English»), the edit is learned as a
replacement rule by the same rules as on macOS
(:func:`vocabulary.learn_candidate`): one contiguous swap of up to three
words, never a pure deletion, never a casing-only touch-up.

macOS gets value-change notifications from Accessibility; here the field
is read through UI Automation (:meth:`focus_target.FocusProbe.read_field`)
every :data:`POLL_SECONDS`, which gives the same sequence of states. The
timing is the macOS one:

* an edit is evaluated once the field has been still for
  :data:`DEBOUNCE_SECONDS`;
* a candidate is saved only after another :data:`CONFIRM_SECONDS` without
  further edits, so a correction still being typed is never learned half
  done. Meanwhile the UI shows it as pending (``on_pending``): Enter saves
  it at once (:meth:`EditWatcher.confirm_now`), Escape drops it
  (:meth:`EditWatcher.cancel_pending`) and the watch goes on;
* after a save the watch rebases on the corrected text and keeps going, so
  a second word fixed in the same dictation is learned on its own;
* focus moving to another field, an edit outside the inserted region, a
  password field, or a field that cannot be read ends the watch. Nothing is
  ever guessed;
* a candidate goes through the vocabulary hygiene first (``review``,
  docs/specs/vocabulary-hygiene-and-sync-spec.md §2): a punctuation-only
  edit, a grammar fix of an ordinary word or a sentence rewrite gets no
  pill and no write, and a candidate may be shown rewritten (edge
  punctuation trimmed, a chain followed to its end).
"""

from __future__ import annotations

import threading
import time
from dataclasses import dataclass
from typing import Callable, Optional

from .logging_setup import get as get_logger
from .vocabulary import LearnCandidate, learn_candidate

log = get_logger("edit_watch")

WATCH_SECONDS = 45.0
DEBOUNCE_SECONDS = 0.35
CONFIRM_SECONDS = 4.0
POLL_SECONDS = 0.15
#: The target app updates its text a moment after the paste.
ANCHOR_ATTEMPTS = 6
ANCHOR_RETRY_SECONDS = 0.25


def inserted_range(inserted: str, field: str, caret: Optional[int]) -> Optional[tuple[int, int]]:
    """Where the just-inserted text sits in the field, as ``(start, end)``.

    Port of ``PostInsertionEditWatcher.insertedRange``: first the exact span
    ending at the caret; otherwise the text with its outer whitespace
    trimmed and no-break spaces read as spaces (rich editors store a
    trailing space as U+00A0 or drop it), taking the occurrence nearest the
    caret, or the last one when there is no caret. ``None`` when the text is
    not in the field at all.
    """
    if caret is not None:
        start = caret - len(inserted)
        if start >= 0 and caret <= len(field) and field[start:caret] == inserted:
            return start, caret
    needle = inserted.replace(" ", " ").strip()
    if not needle:
        return None
    haystack = field.replace(" ", " ")
    best: Optional[tuple[int, int]] = None
    search = 0
    while True:
        found = haystack.find(needle, search)
        if found < 0:
            break
        span = (found, found + len(needle))
        if best is None or caret is None or abs(span[1] - caret) < abs(best[1] - caret):
            best = span
        search = found + 1
    return best


@dataclass
class _Watch:
    element: tuple
    pid: int
    inserted: str           # the baseline region; rebased after each save
    prefix: str
    suffix: str
    deadline: float
    last_text: str
    changed_at: Optional[float] = None
    pending: Optional[LearnCandidate] = None
    confirm_at: float = 0.0
    #: The UI is showing a pending candidate (``pending`` may already be
    #: gone while the next one is being typed).
    shown: bool = False


class EditWatcher:
    """One watch at a time, on its own thread.

    ``read_field`` returns a :class:`focus_target.FieldSnapshot` (or None);
    ``learn(candidate)`` saves a rule and returns what was saved (falsy when
    the store declined: already known, or a cap). ``review(candidate)``
    returns the candidate to offer (possibly rewritten) or None to drop it
    silently. ``on_pending(candidate,
    bounds)`` reports a candidate waiting out its confirm window, with the
    field's screen rectangle; ``on_pending_cleared()`` says it went away
    without being saved (it was edited into nothing learnable, or the watch
    ended). All of them are called from the watcher thread.
    """

    def __init__(self, read_field: Callable[[], object],
                 learn: Callable[[LearnCandidate], object], *,
                 review: Callable[[LearnCandidate], Optional[LearnCandidate]] = lambda c: c,
                 on_pending: Callable[[LearnCandidate, object], None] = lambda c, b: None,
                 on_pending_cleared: Callable[[], None] = lambda: None,
                 own_pids: frozenset[int] = frozenset(),
                 clock: Callable[[], float] = time.monotonic,
                 sleep: Optional[Callable[[float], object]] = None) -> None:
        self._read = read_field
        self._learn = learn
        self._review = review
        self._on_pending = on_pending
        self._on_pending_cleared = on_pending_cleared
        #: "save" or "cancel" from the UI, taken up by the next poll.
        self._request: Optional[str] = None
        self._own = own_pids
        self._clock = clock
        #: Tests pass a fake; otherwise each watch sleeps on its own stop event.
        self._custom_sleep = sleep
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._lock = threading.Lock()

    def begin(self, inserted_text: str) -> None:
        """Watch the field that has just received ``inserted_text``."""
        self.stop()
        if not inserted_text.strip():
            return
        stop = threading.Event()
        self._stop = stop
        thread = threading.Thread(target=self._run, args=(inserted_text, stop),
                                  name="edit-watch", daemon=True)
        with self._lock:
            self._thread = thread
        thread.start()

    def stop(self) -> None:
        with self._lock:
            thread, self._thread = self._thread, None
        self._stop.set()
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout=2.0)

    def confirm_now(self) -> None:
        """Enter on the pending pill: save without waiting the window out."""
        with self._lock:
            self._request = "save"

    def cancel_pending(self) -> None:
        """Escape on the pending pill: drop the candidate, keep watching."""
        with self._lock:
            self._request = "cancel"

    def _take_request(self) -> Optional[str]:
        with self._lock:
            request, self._request = self._request, None
        return request

    # -- thread ----------------------------------------------------------

    def _snapshot(self):
        try:
            return self._read()
        except Exception as exc:
            log.debug("Reading the field failed: %s", exc)
            return None

    def _run(self, inserted: str, stop: threading.Event) -> None:
        sleep = self._custom_sleep or stop.wait
        watch = self._arm(inserted, stop, sleep)
        if watch is None:
            return
        log.info("Watching the field for corrections (%d characters inserted)", len(inserted))
        self._take_request()  # a key meant for an earlier watch's pill
        try:
            while not stop.is_set():
                sleep(POLL_SECONDS)
                if stop.is_set():
                    return
                now = self._clock()
                if now >= watch.deadline and watch.pending is None:
                    log.debug("Edit watch window over")
                    return
                if not self._step(watch, now):
                    return
        finally:
            if watch.shown:
                self._clear(watch)

    def _arm(self, inserted: str, stop: threading.Event,
             sleep: Callable[[float], object]) -> Optional[_Watch]:
        for attempt in range(1, ANCHOR_ATTEMPTS + 1):
            snapshot = self._snapshot()
            if snapshot is not None:
                if snapshot.secure:
                    log.info("Edit watch skipped: password field")
                    return None
                if snapshot.pid not in self._own:
                    span = inserted_range(inserted, snapshot.text, snapshot.caret)
                    if span is not None:
                        start, end = span
                        return _Watch(element=snapshot.element, pid=snapshot.pid,
                                      inserted=snapshot.text[start:end],
                                      prefix=snapshot.text[:start],
                                      suffix=snapshot.text[end:],
                                      deadline=self._clock() + WATCH_SECONDS,
                                      last_text=snapshot.text)
            if attempt < ANCHOR_ATTEMPTS:
                sleep(ANCHOR_RETRY_SECONDS)
                if stop.is_set():
                    return None
        log.info("Edit watch not armed: the inserted text was not found in the focused field")
        return None

    def _region(self, watch: _Watch, text: str) -> Optional[str]:
        if not (text.startswith(watch.prefix) and text.endswith(watch.suffix)):
            return None
        if len(text) < len(watch.prefix) + len(watch.suffix):
            return None
        return text[len(watch.prefix):len(text) - len(watch.suffix)]

    def _clear(self, watch: _Watch) -> None:
        watch.pending, watch.shown = None, False
        self._on_pending_cleared()

    def _step(self, watch: _Watch, now: float) -> bool:
        """One poll. False ends the watch."""
        request = self._take_request()
        if request == "cancel" and watch.pending is not None:
            log.info("Edit watch: %r cancelled by the user; still watching",
                     watch.pending.source)
            self._clear(watch)
            # Rebase on the edit the user kept but did not want learned, or
            # it would come back folded into the next correction's diff.
            region = self._region(watch, watch.last_text)
            if region:
                watch.inserted = region
            return True
        if request == "save" and watch.pending is not None:
            watch.confirm_at = now  # saved below, on this very poll
        snapshot = self._snapshot()
        if snapshot is None:
            log.info("Edit watch ended: the field can no longer be read")
            return False
        if snapshot.element != watch.element or snapshot.pid != watch.pid:
            log.debug("Edit watch ended: focus moved")
            return False

        if snapshot.text != watch.last_text:
            # A new edit: whatever was waiting to be saved is stale, and
            # the debounce starts again.
            watch.last_text = snapshot.text
            watch.changed_at = now
            if watch.pending is not None:
                # The pill stays up while the user types on: the next
                # candidate replaces it, or it goes once there is none.
                log.debug("Edit watch: further edit, pending candidate dropped")
                watch.pending = None
            return True

        if watch.changed_at is not None and now - watch.changed_at >= DEBOUNCE_SECONDS:
            watch.changed_at = None
            region = self._region(watch, snapshot.text)
            if region is None:
                log.info("Edit watch ended: the text around the dictation changed")
                return False
            candidate = learn_candidate(watch.inserted, region)
            if candidate is not None:
                try:
                    candidate = self._review(candidate)
                except Exception as exc:
                    log.warning("Reviewing a learn candidate failed: %s", exc)
                    candidate = None
            if candidate is None:
                if watch.shown:
                    self._clear(watch)
                return True
            log.info("Edit watch: candidate %r -> %r, saving in %.0fs (Enter = now, Esc = cancel)",
                     candidate.source, candidate.replacement, CONFIRM_SECONDS)
            watch.pending = candidate
            watch.confirm_at = now + CONFIRM_SECONDS
            watch.shown = True
            self._on_pending(candidate, getattr(snapshot, "bounds", None))
            return True

        if watch.pending is not None and now >= watch.confirm_at:
            candidate, watch.pending = watch.pending, None
            watch.shown = False
            try:
                saved = self._learn(candidate)
            except Exception as exc:
                log.warning("Saving a learned correction failed: %s", exc)
                saved = None
            if not saved:
                log.info("Edit watch: %r was not saved (already known or declined)",
                         candidate.source)
                self._on_pending_cleared()
            region = self._region(watch, snapshot.text)
            if not region:
                return False
            # Rebase: a later fix to another word is a fresh correction,
            # not one oversized diff against the original dictation.
            watch.inserted = region
        return True
