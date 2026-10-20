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
"""

from __future__ import annotations

import json
import sqlite3
import threading
import time
from dataclasses import dataclass
from enum import Enum
from typing import Iterable, Optional, Sequence

from . import paths
from .logging_setup import get as get_logger

log = get_logger("vocabulary")

DB_FILE = paths.BASE_DIR / "corrections.sqlite"

#: The longest word span either side of a learned correction. A longer edit
#: is prose editing, not a vocabulary fix.
MAX_SPAN_WORDS = 3


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
"""


def _normalized(text: str) -> str:
    """Canonical comparison form: casefolded, whitespace collapsed.

    ``casefold`` rather than ``lower`` because this list is mostly Russian
    and has to fold «Ё»/«ё» and the German ß-class edge cases the same way
    everywhere.
    """
    return " ".join(text.casefold().split())


def _timestamp() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


class VocabularyStore:
    """Thread-safe access to the dictionary.

    Reached from the Qt thread (the manager window) and from the
    transcription worker (applying corrections, learning new ones), so every
    statement runs under one lock on one connection. The list is small and
    the writes are rare; a connection pool would be complexity for nothing.
    """

    def __init__(self, path: Optional[str] = None) -> None:
        self._lock = threading.RLock()
        self._path = str(path or DB_FILE)
        self._db = sqlite3.connect(self._path, check_same_thread=False)
        self._db.row_factory = sqlite3.Row
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
            self._db.commit()

    def close(self) -> None:
        with self._lock:
            self._db.close()

    # -- reads -------------------------------------------------------

    def all(self) -> list[Record]:
        with self._lock:
            rows = self._db.execute(
                "SELECT id, source, replacement, origin, created_at, updated_at "
                "FROM corrections ORDER BY source COLLATE NOCASE ASC;"
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

    # -- writes ------------------------------------------------------

    def upsert(self, source: str, replacement: str,
               origin: Origin = Origin.MANUAL) -> Optional[Record]:
        """Add a rule, or rewrite the existing one for the same source.

        A second correction of the same word is the user changing their
        mind, not a second rule: the dictionary must never hold two answers
        for one input.
        """
        source = " ".join(source.split())
        replacement = " ".join(replacement.split())
        if not source or not replacement:
            return None

        now = _timestamp()
        with self._lock:
            existing = self.find(source)
            if existing is not None:
                self._db.execute(
                    "UPDATE corrections SET source = ?, replacement = ?, "
                    "origin = ?, updated_at = ? WHERE id = ?;",
                    (source, replacement, origin.value, now, existing.id),
                )
                self._db.commit()
                return Record(existing.id, source, replacement, origin,
                              existing.created_at, now)
            cursor = self._db.execute(
                "INSERT INTO corrections (source, replacement, origin, "
                "created_at, updated_at) VALUES (?, ?, ?, ?, ?);",
                (source, replacement, origin.value, now, now),
            )
            self._db.commit()
            return Record(int(cursor.lastrowid), source, replacement,
                          origin, now, now)

    def learn(self, pairs: Iterable[tuple[str, str]]) -> list[Record]:
        """Record ``(heard, meant)`` pairs, one rule per source word.

        Returns the records written, so the caller can offer an undo for
        exactly what it just learned. Marked :attr:`Origin.LEARNED` so the
        manager window can tell the user's own entries from the ones the
        app worked out on its own.
        """
        written: list[Record] = []
        for source, replacement in pairs:
            record = self.upsert(source, replacement, Origin.LEARNED)
            if record is not None:
                written.append(record)
        return written

    def delete(self, record_id: int) -> bool:
        with self._lock:
            cursor = self._db.execute("DELETE FROM corrections WHERE id = ?;",
                                      (record_id,))
            self._db.commit()
        return cursor.rowcount > 0

    def delete_source(self, source: str) -> bool:
        """Delete by source word — what the learned-toast's undo calls."""
        existing = self.find(source)
        return self.delete(existing.id) if existing else False

    def replace_all(self, records: Iterable) -> None:
        """Wholesale replacement, for an import or a settings-window save.

        Accepts ``(source, replacement)`` tuples or anything with those two
        attributes — the settings window hands over the ``Correction``
        objects its list widget holds, and rewriting that window to build
        tuples would be churn for nothing.
        """
        pairs: list[tuple[str, str]] = []
        for item in records:
            if isinstance(item, (tuple, list)) and len(item) == 2:
                pairs.append((str(item[0]), str(item[1])))
            else:
                source = getattr(item, "source", None)
                replacement = getattr(item, "replacement", None)
                if source is not None and replacement is not None:
                    pairs.append((str(source), str(replacement)))
        records = pairs
        now = _timestamp()
        with self._lock:
            self._db.execute("DELETE FROM corrections;")
            self._db.executemany(
                "INSERT OR REPLACE INTO corrections (source, replacement, "
                "origin, created_at, updated_at) VALUES (?, ?, ?, ?, ?);",
                [(" ".join(s.split()), " ".join(r.split()),
                  Origin.MANUAL.value, now, now)
                 for s, r in records
                 if s.strip() and r.strip()],
            )
            self._db.commit()

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


def _record(row: sqlite3.Row) -> Record:
    try:
        origin = Origin(row["origin"])
    except ValueError:
        origin = Origin.MANUAL
    return Record(int(row["id"]), str(row["source"]), str(row["replacement"]),
                  origin, str(row["created_at"]), str(row["updated_at"]))


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
