"""The user's replacement dictionary, on SQLite.

Port of ``swift/Sources/Parakey/VocabularyStore.swift`` and the candidate
detector from ``VocabularyLearning.swift``.

The Windows fork kept this list in ``Corrections.json``, rewritten whole on
every change. That is fine for a handful of rules and wrong for a list that
grows on its own: the macOS build learns a rule every time somebody
hand-corrects a dictated word, and a JSON file rewritten from a background
thread on every learn is both a lost-write risk and a re-parse of the whole
list on every dictation. Same schema as macOS, so an exported dictionary
moves between the platforms unchanged.

Existing ``Corrections.json`` files are migrated on first open and left on
disk — see :func:`migrate_json_if_needed`.

Two additions shared with macOS: the ``asr_hint`` column (which entries
become ASR hotwords, docs/specs/asr-hotwords-spec.md §6) and the
``deleted_corrections`` tombstones the account sync needs to carry a
deletion to the other machines (docs/specs/vocabulary-hygiene-and-sync-spec.md
§4.1). Every delete writes one; adding the key again removes it.
"""

from __future__ import annotations

import calendar
import json
import sqlite3
import threading
import time
import unicodedata
from contextlib import contextmanager
from dataclasses import dataclass, field
from enum import Enum
from typing import Callable, Iterable, Iterator, Optional, Sequence

from . import asr_hotwords, paths, vocabulary_hygiene as hygiene
from .logging_setup import get as get_logger

log = get_logger("vocabulary")

DB_FILE = paths.BASE_DIR / "corrections.sqlite"

#: The longest word span either side of a learned correction. A longer edit
#: is prose editing, not a vocabulary fix.
MAX_SPAN_WORDS = 3

#: Change notifications: a write made here, or one applied from the sync
#: server (which must not schedule another sync of its own).
CHANGE_LOCAL = "local"
CHANGE_SYNC = "sync"


class Origin(str, Enum):
    MANUAL = "manual"
    LEARNED = "learned"


@dataclass(frozen=True)
class Record:
    id: int
    source: str
    replacement: str
    origin: Origin
    created_at: str
    updated_at: str
    #: ASR hotword hint (docs/specs/asr-hotwords-spec.md §6): None =
    #: automatic, True = always, False = never.
    asr_hint: Optional[bool] = None

    @property
    def key(self) -> str:
        return _normalized(self.source)


@dataclass(frozen=True)
class DraftEntry:
    """One row of the vocabulary list while it is being edited."""

    source: str
    replacement: str
    asr_hint: Optional[bool] = None
    origin: Origin = Origin.MANUAL

    def to_json(self) -> dict:
        return {"source": self.source, "replacement": self.replacement}


@dataclass(frozen=True)
class Tombstone:
    key: str
    source: str
    deleted_at: str


@dataclass
class LearnOutcome:
    """What :meth:`VocabularyStore.learn_reviewed` did."""

    written: list[Record] = field(default_factory=list)
    rejected: str = ""
    undone_id: Optional[int] = None


# `source` declares COLLATE NOCASE and there is a unique index to match, but
# that index only catches ASCII-case duplicates — SQLite's built-in NOCASE
# collation does not fold non-ASCII scripts, Cyrillic included. It is kept
# as defence in depth against exact and ASCII-case dupes; the real
# Unicode-aware dedup is `_normalized` below, which every write goes
# through. Identical reasoning, and identical schema, to the macOS build.
_SCHEMA = """
CREATE TABLE IF NOT EXISTS corrections (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source TEXT NOT NULL COLLATE NOCASE,
    replacement TEXT NOT NULL,
    origin TEXT NOT NULL DEFAULT 'manual',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_corrections_source_nocase
    ON corrections (source);
CREATE TABLE IF NOT EXISTS deleted_corrections (
    key TEXT PRIMARY KEY,
    source TEXT NOT NULL,
    deleted_at TEXT NOT NULL
);
"""

_COLUMNS = "id, source, replacement, origin, created_at, updated_at, asr_hint"


def _normalized(text: str) -> str:
    """Canonical comparison form: NFC, casefolded, whitespace collapsed.

    ``casefold`` rather than ``lower`` because this list is mostly Russian
    and has to fold «Ё»/«ё» and the German ß-class edge cases the same way
    everywhere. The same key the sync server uses for an entry.
    """
    return " ".join(unicodedata.normalize("NFC", text).casefold().split())


def _timestamp() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _after(previous: str, now: Optional[str] = None) -> str:
    """A stamp for a change to a row last stamped ``previous``: now, or one
    second past ``previous`` when the clock has not moved past it.

    Stamps have one-second resolution and the sync's last-writer-wins
    keeps the server copy on a tie, so an add and a delete within the same
    second would otherwise lose the delete.
    """
    now = now or _timestamp()
    if not previous or now > previous:
        return now
    try:
        parsed = time.strptime(previous, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return now
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(calendar.timegm(parsed) + 1))


def _hint_value(hint: Optional[bool]) -> Optional[int]:
    return None if hint is None else int(bool(hint))


_KEEP = object()


class VocabularyStore:
    """Thread-safe access to the dictionary.

    Reached from the Qt thread (the manager window), the transcription
    worker (applying corrections, learning new ones) and the sync thread,
    so every statement runs under one lock on one connection. The list is
    small and the writes are rare; a connection pool would be complexity
    for nothing.
    """

    def __init__(self, path: Optional[str] = None) -> None:
        self._lock = threading.RLock()
        self._path = str(path or DB_FILE)
        self._db = sqlite3.connect(self._path, check_same_thread=False)
        self._db.row_factory = sqlite3.Row
        self._listeners: list[Callable[[str], None]] = []
        with self._lock:
            # WAL so a read from the UI thread never blocks behind a learn
            # on the worker thread. Best-effort: a database on a network
            # share can refuse it, and rollback journalling still works.
            try:
                self._db.execute("PRAGMA journal_mode=WAL;")
            except sqlite3.Error as exc:
                log.debug("Could not enable WAL: %s", exc)
            self._db.execute("PRAGMA busy_timeout=3000;")
            self._db.executescript(_SCHEMA)
            self._migrate_asr_hint()
            self._db.commit()

    def _migrate_asr_hint(self) -> None:
        """Idempotent: adds ``asr_hint INTEGER`` (NULL auto / 1 on / 0 off),
        the macOS migration. A second process may race us to it."""
        columns = {row[1] for row in self._db.execute("PRAGMA table_info(corrections);")}
        if "asr_hint" in columns:
            return
        try:
            self._db.execute("ALTER TABLE corrections ADD COLUMN asr_hint INTEGER;")
        except sqlite3.OperationalError as exc:
            columns = {row[1] for row in self._db.execute("PRAGMA table_info(corrections);")}
            if "asr_hint" not in columns:
                raise
            log.debug("asr_hint added concurrently: %s", exc)

    def close(self) -> None:
        with self._lock:
            self._db.close()

    # -- notifications -------------------------------------------------

    def add_listener(self, callback: Callable[[str], None]) -> None:
        """``callback(kind)`` after every committed change, on the writing
        thread; ``kind`` is :data:`CHANGE_LOCAL` or :data:`CHANGE_SYNC`."""
        self._listeners.append(callback)

    def _notify(self, kind: str = CHANGE_LOCAL) -> None:
        for callback in list(self._listeners):
            try:
                callback(kind)
            except Exception as exc:
                log.debug("Vocabulary listener failed: %s", exc)

    @contextmanager
    def _transaction(self) -> Iterator[sqlite3.Connection]:
        with self._lock:
            try:
                yield self._db
                self._db.commit()
            except BaseException:
                self._db.rollback()
                raise

    # -- reads -------------------------------------------------------

    def all(self) -> list[Record]:
        with self._lock:
            rows = self._db.execute(
                f"SELECT {_COLUMNS} FROM corrections ORDER BY source COLLATE NOCASE ASC;"
            ).fetchall()
        return [_record(row) for row in rows]

    def count(self) -> int:
        with self._lock:
            row = self._db.execute("SELECT COUNT(*) FROM corrections;").fetchone()
        return int(row[0]) if row else 0

    def find(self, source: str) -> Optional[Record]:
        """Case-insensitive lookup, Unicode-aware."""
        target = _normalized(source)
        for record in self.all():
            if _normalized(record.source) == target:
                return record
        return None

    def get(self, record_id: int) -> Optional[Record]:
        with self._lock:
            row = self._db.execute(f"SELECT {_COLUMNS} FROM corrections WHERE id = ?;",
                                   (record_id,)).fetchone()
        return _record(row) if row else None

    def tombstones(self) -> list[Tombstone]:
        with self._lock:
            rows = self._db.execute(
                "SELECT key, source, deleted_at FROM deleted_corrections ORDER BY deleted_at;"
            ).fetchall()
        return [Tombstone(str(r["key"]), str(r["source"]), str(r["deleted_at"])) for r in rows]

    def asr_hotword_phrases(self) -> list[str]:
        """The hotword list for the speech model (spec §6)."""
        return asr_hotwords.phrases(self.all())

    # -- low-level writes (caller holds the lock and commits) ----------

    def _tombstone(self, record: Record, when: str) -> None:
        self._db.execute(
            "INSERT INTO deleted_corrections (key, source, deleted_at) VALUES (?, ?, ?) "
            "ON CONFLICT(key) DO UPDATE SET source = excluded.source, "
            "deleted_at = excluded.deleted_at;",
            (record.key, record.source, when))

    def _clear_tombstone(self, source: str) -> None:
        self._db.execute("DELETE FROM deleted_corrections WHERE key = ?;",
                         (_normalized(source),))

    def _tombstone_stamp(self, source: str) -> str:
        row = self._db.execute("SELECT deleted_at FROM deleted_corrections WHERE key = ?;",
                               (_normalized(source),)).fetchone()
        return str(row[0]) if row else ""

    def _delete_row(self, record: Record, when: str) -> None:
        self._db.execute("DELETE FROM corrections WHERE id = ?;", (record.id,))
        self._tombstone(record, _after(record.updated_at, when))

    def _update_row(self, record: Record, source: str, replacement: str, origin: Origin,
                    hint: Optional[bool], when: str) -> Record:
        when = _after(record.updated_at, when)
        if _normalized(source) != record.key:
            # A new key on the server: the old one goes as a tombstone, and
            # the new key must be newer than any tombstone it had.
            self._tombstone(record, when)
            when = _after(self._tombstone_stamp(source), when)
        self._db.execute(
            "UPDATE corrections SET source = ?, replacement = ?, origin = ?, "
            "asr_hint = ?, updated_at = ? WHERE id = ?;",
            (source, replacement, origin.value, _hint_value(hint), when, record.id))
        self._clear_tombstone(source)
        return Record(record.id, source, replacement, origin, record.created_at, when, hint)

    def _insert_row(self, source: str, replacement: str, origin: Origin,
                    hint: Optional[bool], created: str, updated: str,
                    *, local: bool = True) -> Record:
        if local:
            updated = _after(self._tombstone_stamp(source), updated)
        cursor = self._db.execute(
            "INSERT INTO corrections (source, replacement, origin, created_at, "
            "updated_at, asr_hint) VALUES (?, ?, ?, ?, ?, ?);",
            (source, replacement, origin.value, created, updated, _hint_value(hint)))
        self._clear_tombstone(source)
        return Record(int(cursor.lastrowid), source, replacement, origin, created, updated, hint)

    def _find_locked(self, source: str) -> Optional[Record]:
        target = _normalized(source)
        for row in self._db.execute(f"SELECT {_COLUMNS} FROM corrections;"):
            if _normalized(str(row["source"])) == target:
                return _record(row)
        return None

    # -- writes ------------------------------------------------------

    def upsert(self, source: str, replacement: str,
               origin: Origin = Origin.MANUAL, *, asr_hint=_KEEP) -> Optional[Record]:
        """Add a rule, or rewrite the existing one for the same source.

        A second correction of the same word is the user changing their
        mind, not a second rule: the dictionary must never hold two answers
        for one input. The ASR hint of an existing rule is kept unless one
        is given.
        """
        source = " ".join(source.split())
        replacement = " ".join(replacement.split())
        if not source or not replacement:
            return None

        now = _timestamp()
        with self._transaction():
            existing = self._find_locked(source)
            if existing is not None:
                hint = existing.asr_hint if asr_hint is _KEEP else asr_hint
                record = self._update_row(existing, source, replacement, origin, hint, now)
            else:
                hint = None if asr_hint is _KEEP else asr_hint
                record = self._insert_row(source, replacement, origin, hint, now, now)
        self._notify()
        return record

    def learn(self, pairs: Iterable[tuple[str, str]]) -> list[Record]:
        """Record ``(heard, meant)`` pairs, one rule per source word.

        Returns the records written, so the caller can offer an undo for
        exactly what it just learned. Marked :attr:`Origin.LEARNED` so the
        manager window can tell the user's own entries from the ones the
        app worked out on its own — unless the rule being rewritten was the
        user's own, which stays theirs.
        """
        written: list[Record] = []
        for source, replacement in pairs:
            existing = self.find(source)
            origin = (Origin.MANUAL if existing is not None and existing.origin is Origin.MANUAL
                      else Origin.LEARNED)
            record = self.upsert(source, replacement, origin)
            if record is not None:
                written.append(record)
        return written

    def review(self, source: str, replacement: str) -> hygiene.Verdict:
        """The learn-time hygiene verdict (spec §2) against this dictionary."""
        return hygiene.review(source, replacement, self.all())

    def learn_reviewed(self, source: str, replacement: str) -> LearnOutcome:
        """Learn one edit through the hygiene rules (spec §2).

        A rejected candidate writes nothing. An undo deletes the entry the
        user just reverted. An accepted one is stored as rewritten, and the
        chains that ended at its source are moved onto its target.
        """
        outcome = LearnOutcome()
        with self._lock:
            verdict = self.review(source, replacement)
            if isinstance(verdict, hygiene.Reject):
                log.info("Learning skipped (%s): %r -> %r", verdict.reason, source, replacement)
                outcome.rejected = verdict.reason
                return outcome
            if isinstance(verdict, hygiene.Undo):
                record = self.get(verdict.existing_id)
                if record is not None:
                    with self._transaction():
                        self._delete_row(record, _timestamp())
                    log.info("Learning: %r -> %r reverts rule %d (%r -> %r); removed",
                             source, replacement, record.id, record.source, record.replacement)
                    outcome.undone_id = record.id
                    self._notify()
                return outcome
            written = self.learn([(verdict.source, verdict.replacement)])
            outcome.written = written
            if verdict.chain_rewrites:
                now = _timestamp()
                with self._transaction():
                    for record_id, target in verdict.chain_rewrites:
                        record = self.get(record_id)
                        if record is not None:
                            self._update_row(record, record.source, target, record.origin,
                                             record.asr_hint, now)
                            log.info("Learning: chain %r -> %r now ends at %r",
                                     record.source, record.replacement, target)
                self._notify()
        return outcome

    def delete(self, record_id: int) -> bool:
        with self._transaction():
            record = self.get(record_id)
            if record is not None:
                self._delete_row(record, _timestamp())
        if record is not None:
            self._notify()
        return record is not None

    def delete_source(self, source: str) -> bool:
        """Delete by source word — what the learned-toast's undo calls."""
        existing = self.find(source)
        return self.delete(existing.id) if existing else False

    def set_asr_hint(self, record_id: int, hint: Optional[bool]) -> bool:
        """``None`` automatic, ``True`` always, ``False`` never.

        Bumps ``updated_at``: the hint travels with the entry through the
        sync, and the sync only sends entries changed since its last push.
        """
        with self._transaction():
            record = self.get(record_id)
            if record is not None:
                self._db.execute(
                    "UPDATE corrections SET asr_hint = ?, updated_at = ? WHERE id = ?;",
                    (_hint_value(hint), _after(record.updated_at), record_id))
        if record is not None:
            self._notify()
        return record is not None

    def replace_all(self, records: Iterable) -> None:
        """Make the dictionary exactly ``records``, for an import that
        replaces rather than merges.

        Accepts ``(source, replacement)`` tuples or anything with those two
        attributes. Rules that did not change keep their origin, hint and
        timestamps (so the sync does not see them as edited); removed ones
        leave tombstones.
        """
        current = self.all()
        self.apply_edits(current, [DraftEntry(s, r) for s, r in _pairs(records)],
                         keep_hints=True)

    def apply_edits(self, baseline: Sequence[Record], edited: Sequence,
                    *, keep_hints: bool = False) -> None:
        """Save the vocabulary list as the user left it.

        ``baseline`` is what the list was loaded from, ``edited`` what it
        holds now (:class:`DraftEntry` or anything with ``source`` and
        ``replacement``). Only the difference is written, so a rule the
        sync changed while the window was open is not reverted, and an
        unchanged rule keeps its timestamps.
        """
        base = {record.key: record for record in baseline}
        wanted: dict[str, DraftEntry] = {}
        for item in edited:
            source = " ".join(str(getattr(item, "source", "")).split())
            replacement = " ".join(str(getattr(item, "replacement", "")).split())
            if not source or not replacement:
                continue
            hint = getattr(item, "asr_hint", None)
            wanted[_normalized(source)] = DraftEntry(source, replacement, hint)

        now = _timestamp()
        changed = False
        with self._transaction():
            current = {record.key: record for record in (
                _record(row) for row in self._db.execute(f"SELECT {_COLUMNS} FROM corrections;"))}
            for key, record in base.items():
                if key not in wanted and key in current:
                    self._delete_row(current[key], now)
                    changed = True
            for key, draft in wanted.items():
                before = base.get(key)
                existing = current.get(key)
                hint = draft.asr_hint
                if keep_hints and existing is not None:
                    hint = existing.asr_hint
                if (before is not None and before.source == draft.source
                        and before.replacement == draft.replacement and before.asr_hint == hint):
                    continue
                if existing is None:
                    self._insert_row(draft.source, draft.replacement, Origin.MANUAL, hint, now, now)
                elif (existing.source, existing.replacement, existing.asr_hint) != (
                        draft.source, draft.replacement, hint):
                    origin = existing.origin if before is not None else Origin.MANUAL
                    self._update_row(existing, draft.source, draft.replacement, origin, hint, now)
                else:
                    continue
                changed = True
        if changed:
            self._notify()

    # -- cleanup (hygiene spec §3) -------------------------------------

    def cleanup_plan(self) -> hygiene.CleanupPlan:
        return hygiene.cleanup_plan(self.all())

    def apply_cleanup(self, plan: hygiene.CleanupPlan) -> int:
        """Apply a confirmed plan in one transaction; returns rows touched."""
        now = _timestamp()
        touched = 0
        with self._transaction():
            for deletion in plan.deletions:
                record = self.get(deletion.record.id)
                if record is not None:
                    self._delete_row(record, now)
                    touched += 1
            for rewrite in plan.rewrites:
                record = self.get(rewrite.record.id)
                if record is not None:
                    self._update_row(record, rewrite.source, rewrite.replacement,
                                     record.origin, record.asr_hint, now)
                    touched += 1
        if touched:
            log.info("Vocabulary cleanup: %d deleted, %d rewritten",
                     len(plan.deletions), len(plan.rewrites))
            self._notify()
        return touched

    # -- sync support (hygiene spec §4.2) ------------------------------

    def local_changes_since(self, stamp: str) -> tuple[list[Record], list[Tombstone]]:
        """Entries and tombstones stamped at or after ``stamp``.

        "At or after", not "after": stamps have one-second resolution, and
        re-sending a change the server already has is harmless (a tie keeps
        the server copy), while missing one is not.
        """
        with self._lock:
            rows = self._db.execute(
                f"SELECT {_COLUMNS} FROM corrections WHERE updated_at >= ? ORDER BY updated_at;",
                (stamp,)).fetchall()
            dead = self._db.execute(
                "SELECT key, source, deleted_at FROM deleted_corrections WHERE deleted_at >= ? "
                "ORDER BY deleted_at;", (stamp,)).fetchall()
        return ([_record(row) for row in rows],
                [Tombstone(str(r["key"]), str(r["source"]), str(r["deleted_at"])) for r in dead])

    def apply_remote(self, entries: Iterable[dict]) -> int:
        """Merge entries from the sync server; returns how many changed.

        Last writer wins on ``updated_at`` (a tie keeps the local copy). A
        remote entry keeps its own ``updated_at``, origin and hint, so it
        does not look like a local edit.
        """
        changed = 0
        with self._transaction():
            current = {record.key: record for record in (
                _record(row) for row in self._db.execute(f"SELECT {_COLUMNS} FROM corrections;"))}
            tombs = {str(r["key"]): str(r["deleted_at"]) for r in self._db.execute(
                "SELECT key, deleted_at FROM deleted_corrections;")}
            for entry in entries:
                if not isinstance(entry, dict):
                    continue
                source = " ".join(str(entry.get("source") or "").split())
                stamp = str(entry.get("updated_at") or "")
                if not source or not stamp:
                    continue
                key = _normalized(source)
                local = current.get(key)
                local_stamp = max(local.updated_at if local else "", tombs.get(key, ""))
                if stamp <= local_stamp:
                    continue
                if entry.get("deleted"):
                    if local is not None:
                        self._db.execute("DELETE FROM corrections WHERE id = ?;", (local.id,))
                        current.pop(key, None)
                    self._db.execute(
                        "INSERT INTO deleted_corrections (key, source, deleted_at) VALUES (?, ?, ?) "
                        "ON CONFLICT(key) DO UPDATE SET source = excluded.source, "
                        "deleted_at = excluded.deleted_at;", (key, source, stamp))
                    tombs[key] = stamp
                    changed += 1
                    continue
                replacement = " ".join(str(entry.get("replacement") or "").split())
                if not replacement:
                    continue
                try:
                    origin = Origin(str(entry.get("origin") or "manual"))
                except ValueError:
                    origin = Origin.MANUAL
                raw_hint = entry.get("asr_hint")
                hint = None if raw_hint is None else bool(raw_hint)
                if local is not None:
                    self._db.execute(
                        "UPDATE corrections SET source = ?, replacement = ?, origin = ?, "
                        "asr_hint = ?, updated_at = ? WHERE id = ?;",
                        (source, replacement, origin.value, _hint_value(hint), stamp, local.id))
                    current[key] = Record(local.id, source, replacement, origin,
                                          local.created_at, stamp, hint)
                else:
                    record = self._insert_row(source, replacement, origin, hint, stamp, stamp,
                                              local=False)
                    current[key] = record
                self._db.execute("DELETE FROM deleted_corrections WHERE key = ?;", (key,))
                tombs.pop(key, None)
                changed += 1
        if changed:
            self._notify(CHANGE_SYNC)
        return changed

    # -- import / export ---------------------------------------------

    def export_json(self) -> list[dict[str, str]]:
        """The same shape the macOS sync file uses."""
        return [{"source": r.source, "replacement": r.replacement}
                for r in self.all()]

    def import_json(self, payload: Sequence[dict], *, merge: bool = True) -> int:
        """Load a sync file. Returns how many rules were applied."""
        pairs = [(str(item.get("source", "")), str(item.get("replacement", "")))
                 for item in payload if isinstance(item, dict)]
        pairs = [(s, r) for s, r in pairs if s.strip() and r.strip()]
        if not merge:
            self.replace_all(pairs)
            return len(pairs)
        applied = 0
        for source, replacement in pairs:
            if self.upsert(source, replacement, Origin.MANUAL) is not None:
                applied += 1
        return applied


def _pairs(records: Iterable) -> list[tuple[str, str]]:
    pairs: list[tuple[str, str]] = []
    for item in records:
        if isinstance(item, (tuple, list)) and len(item) == 2:
            pairs.append((str(item[0]), str(item[1])))
        else:
            source = getattr(item, "source", None)
            replacement = getattr(item, "replacement", None)
            if source is not None and replacement is not None:
                pairs.append((str(source), str(replacement)))
    return pairs


def _record(row: sqlite3.Row) -> Record:
    try:
        origin = Origin(row["origin"])
    except ValueError:
        origin = Origin.MANUAL
    raw_hint = row["asr_hint"]
    return Record(int(row["id"]), str(row["source"]), str(row["replacement"]),
                  origin, str(row["created_at"]), str(row["updated_at"]),
                  None if raw_hint is None else bool(raw_hint))


def migrate_json_if_needed(store: VocabularyStore) -> int:
    """Fold a pre-SQLite ``Corrections.json`` into the database.

    Runs once: the JSON file is renamed rather than deleted, so a user who
    downgrades still has their list, and a half-finished migration cannot
    lose it. Returns how many rules moved.
    """
    source_file = paths.CORRECTIONS_FILE
    if not source_file.exists():
        return 0
    try:
        payload = json.loads(source_file.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        log.warning("Could not read %s for migration: %s", source_file, exc)
        return 0
    if not isinstance(payload, list) or not payload:
        return 0

    moved = store.import_json(payload, merge=True)
    try:
        source_file.replace(source_file.with_suffix(".json.migrated"))
    except OSError as exc:
        log.warning("Migrated %d rules but could not rename %s: %s",
                    moved, source_file, exc)
    log.info("Migrated %d correction(s) from Corrections.json to SQLite", moved)
    return moved


# -- learning --------------------------------------------------------

@dataclass(frozen=True)
class LearnCandidate:
    source: str
    replacement: str


def learn_candidate(inserted_text: str, edited_text: str) -> Optional[LearnCandidate]:
    """Whether a hand-edit looks like a vocabulary correction.

    Pure word-level diff between the text the app inserted and what sits in
    that region now. A short, contiguous word or phrase swap is a
    correction worth remembering; anything larger is ordinary prose editing
    and is ignored.
    """
    inserted = inserted_text.split()
    edited = edited_text.split()
    if not inserted or not edited:
        return None

    prefix = 0
    while (prefix < len(inserted) and prefix < len(edited)
           and inserted[prefix] == edited[prefix]):
        prefix += 1

    suffix = 0
    while (suffix < len(inserted) - prefix and suffix < len(edited) - prefix
           and inserted[len(inserted) - 1 - suffix] == edited[len(edited) - 1 - suffix]):
        suffix += 1

    old_span = inserted[prefix:len(inserted) - suffix]
    new_span = edited[prefix:len(edited) - suffix]
    if not old_span or not new_span:
        return None
    if len(old_span) > MAX_SPAN_WORDS or len(new_span) > MAX_SPAN_WORDS:
        return None

    source = " ".join(old_span)
    replacement = " ".join(new_span)
    if source == replacement:
        return None

    # A pure deletion teaches nothing, and two deletion-only shapes reach
    # here with a non-empty new span: intra-word trimming («инглиш» cut back
    # to «глиш») and non-contiguous word removal («очень длинное слово»
    # reduced to «длинное»). Without this, somebody who deletes a word and
    # then pauses to think gets the half-finished deletion learned as a
    # "correction", and a toast for it. Rule: if the edited span adds no
    # text that was not already in the original, there is nothing to
    # remember. Case-insensitive, so a casing-only touch-up is not learned
    # either — it teaches no new vocabulary.
    if _normalized(replacement) in _normalized(source):
        return None

    return LearnCandidate(source=source, replacement=replacement)
