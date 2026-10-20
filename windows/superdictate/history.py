"""Transcript history and daily usage statistics.

macOS keeps both inside NSUserDefaults (``recent_transcript_entries_v1``
and ``daily_dictation_usage_v1``). Here they are separate JSON files so a
long history never bloats the settings file the app rewrites on every
preference change.

The archive keeps up to 200 entries regardless of the user's "show last N"
preference, the preference controls what the quick-history window offers
for re-insertion, not how much is retained, exactly as on macOS.
"""

from __future__ import annotations

import json
import os
import threading
from dataclasses import dataclass, field
from datetime import date, datetime
from typing import Optional

from . import paths
from .logging_setup import get as get_logger
from .settings import HISTORY_ARCHIVE_MAX_ENTRIES

log = get_logger("history")


@dataclass
class HistoryEntry:
    text: str
    created_at: float
    audio_seconds: float = 0.0
    transcription_seconds: float = 0.0

    def to_json(self) -> dict:
        return {
            "text": self.text,
            "created_at": self.created_at,
            "audio_seconds": self.audio_seconds,
            "transcription_seconds": self.transcription_seconds,
        }

    @staticmethod
    def from_json(raw: object) -> Optional["HistoryEntry"]:
        if not isinstance(raw, dict):
            return None
        text = str(raw.get("text", "")).strip()
        if not text:
            return None
        try:
            return HistoryEntry(
                text=text,
                created_at=float(raw.get("created_at", 0.0)),
                audio_seconds=float(raw.get("audio_seconds", 0.0)),
                transcription_seconds=float(raw.get("transcription_seconds", 0.0)),
            )
        except (TypeError, ValueError):
            return None


def _write_json(path, payload) -> None:
    paths.ensure_directories()
    temp = f"{path}.tmp"
    try:
        with open(temp, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2)
        os.replace(temp, path)
    except OSError as exc:
        log.warning("Could not write %s: %s", path, exc)
        try:
            os.unlink(temp)
        except OSError:
            pass


def _read_json(path, fallback):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return fallback


class History:
    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._entries: list[HistoryEntry] = []
        self.load()

    def load(self) -> None:
        raw = _read_json(paths.HISTORY_FILE, [])
        if not isinstance(raw, list):
            return
        entries = [entry for entry in (HistoryEntry.from_json(item) for item in raw)
                   if entry is not None]
        with self._lock:
            self._entries = entries[:HISTORY_ARCHIVE_MAX_ENTRIES]

    def save(self) -> None:
        with self._lock:
            payload = [entry.to_json() for entry in self._entries]
        _write_json(paths.HISTORY_FILE, payload)

    def add(self, entry: HistoryEntry) -> None:
        with self._lock:
            self._entries.insert(0, entry)
            del self._entries[HISTORY_ARCHIVE_MAX_ENTRIES:]
        self.save()

    def entries(self, limit: Optional[int] = None) -> list[HistoryEntry]:
        with self._lock:
            items = list(self._entries)
        return items if limit is None else items[:limit]

    def clear(self) -> None:
        with self._lock:
            self._entries = []
        self.save()

    def amend(self, original: str, text: str) -> bool:
        """Rewrite the newest entry, provided it is still ``original``.

        The transcript editor corrects the dictation that just happened.
        If another one has landed in the meantime the archive is left
        alone rather than rewriting whichever entry is now on top.
        """
        with self._lock:
            if not self._entries or self._entries[0].text != original:
                return False
            self._entries[0].text = text
        self.save()
        return True

    def remove(self, index: int) -> None:
        with self._lock:
            if 0 <= index < len(self._entries):
                del self._entries[index]
        self.save()


@dataclass
class DailyUsage:
    day: str  # ISO date
    dictations: int = 0
    audio_seconds: float = 0.0
    characters: int = 0
    words: int = 0

    def to_json(self) -> dict:
        return {
            "day": self.day,
            "dictations": self.dictations,
            "audio_seconds": self.audio_seconds,
            "characters": self.characters,
            "words": self.words,
        }


class UsageStats:
    """Per-day dictation counters, kept for a rolling year."""

    MAX_DAYS = 400

    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._days: dict[str, DailyUsage] = {}
        self.load()

    def load(self) -> None:
        raw = _read_json(paths.USAGE_FILE, [])
        if not isinstance(raw, list):
            return
        days: dict[str, DailyUsage] = {}
        for item in raw:
            if not isinstance(item, dict):
                continue
            day = str(item.get("day", ""))
            if not day:
                continue
            try:
                days[day] = DailyUsage(
                    day=day,
                    dictations=int(item.get("dictations", 0)),
                    audio_seconds=float(item.get("audio_seconds", 0.0)),
                    characters=int(item.get("characters", 0)),
                    words=int(item.get("words", 0)),
                )
            except (TypeError, ValueError):
                continue
        with self._lock:
            self._days = days

    def save(self) -> None:
        with self._lock:
            items = sorted(self._days.values(), key=lambda d: d.day, reverse=True)
            items = items[: self.MAX_DAYS]
            self._days = {item.day: item for item in items}
            payload = [item.to_json() for item in items]
        _write_json(paths.USAGE_FILE, payload)

    def record(self, text: str, audio_seconds: float, when: Optional[datetime] = None) -> None:
        day = (when or datetime.now()).date().isoformat()
        with self._lock:
            usage = self._days.setdefault(day, DailyUsage(day))
            usage.dictations += 1
            usage.audio_seconds += audio_seconds
            usage.characters += len(text)
            usage.words += len(text.split())
        self.save()

    def all_days(self) -> list[DailyUsage]:
        with self._lock:
            return sorted(self._days.values(), key=lambda d: d.day, reverse=True)

    def today(self) -> DailyUsage:
        day = date.today().isoformat()
        with self._lock:
            return self._days.get(day, DailyUsage(day))

    def totals(self) -> DailyUsage:
        total = DailyUsage("all")
        for usage in self.all_days():
            total.dictations += usage.dictations
            total.audio_seconds += usage.audio_seconds
            total.characters += usage.characters
            total.words += usage.words
        return total


class Corrections:
    """The user's replacement dictionary, stored separately so it can be
    hand-edited or synced between machines like the macOS sync file."""

    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._items: list = []
        self.load()

    def load(self) -> None:
        from .settings import Correction

        raw = _read_json(paths.CORRECTIONS_FILE, [])
        items = []
        if isinstance(raw, list):
            for entry in raw:
                if not isinstance(entry, dict):
                    continue
                source = str(entry.get("source", "")).strip()
                replacement = str(entry.get("replacement", "")).strip()
                if source and replacement:
                    items.append(Correction(source, replacement))
        with self._lock:
            self._items = items

    def save(self) -> None:
        with self._lock:
            payload = [item.to_json() for item in self._items]
        _write_json(paths.CORRECTIONS_FILE, payload)

    def all(self) -> list:
        with self._lock:
            return list(self._items)

    def learn(self, pairs) -> int:
        """Record (heard, meant) pairs, one rule per source word.

        A second correction of the same word is the user changing their
        mind, not a second rule: the existing entry is rewritten in place
        so the dictionary cannot end up with two answers for one input.
        """
        from .settings import Correction

        learned = 0
        with self._lock:
            for raw_source, raw_replacement in pairs:
                source = " ".join(str(raw_source).split())
                replacement = " ".join(str(raw_replacement).split())
                if not source or not replacement:
                    continue
                key = source.casefold()
                for index, item in enumerate(self._items):
                    if item.source.casefold() == key:
                        self._items[index] = Correction(source, replacement)
                        break
                else:
                    self._items.append(Correction(source, replacement))
                learned += 1
        if learned:
            self.save()
        return learned

    def replace_all(self, items) -> None:
        with self._lock:
            self._items = list(items)
        self.save()
