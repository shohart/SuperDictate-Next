"""Which vocabulary entries become ASR hotwords.

Port of ``swift/Sources/Parakey/AsrHotwordSelection.swift``
(docs/specs/asr-hotwords-spec.md §6). Pure functions only: the store
(:meth:`vocabulary.VocabularyStore.asr_hotword_phrases`), the "ASR hint"
column of the vocabulary list and the self-tests all go through this one
rule, and it has to give exactly the macOS answer for the same dictionary,
because the two apps share one database schema and one sync account.

The phrase is the entry's replacement with its edges trimmed. An entry is
never a hotword when the phrase is shorter than two characters, has no
letter, has more than four words, or differs from the source only by
punctuation, case or spacing. Otherwise the per-entry ``asr_hint`` decides
(``None`` = automatic, ``True`` = always, ``False`` = never); automatic
means every manual entry, and a learned one only when it is "term-like".
"""

from __future__ import annotations

import unicodedata
from dataclasses import dataclass
from typing import Iterable, Optional

MAX_PHRASES = 1000
MAX_WORDS = 4
MIN_CHARACTERS = 2

#: The two weights the settings offer (spec §3): 2.0 is the measured sweet
#: spot, 3.0 fixes more terms at a small regression risk.
STRENGTH_SCORES = {"normal": 2.0, "strong": 3.0}
DEFAULT_STRENGTH = "normal"

#: Trimmed from both ends of a replacement (spec §6), with whitespace.
_EDGE_CHARACTERS = frozenset(".,!?;:—–-«»\"'")

ORIGIN_MANUAL = "manual"
ORIGIN_LEARNED = "learned"


@dataclass(frozen=True)
class HotwordsConfiguration:
    """What one dictation hands the speech host. An empty list means the
    unbiased path, bit-identical to a build without hotwords (spec §7)."""

    phrases: tuple[str, ...]
    score: float

    @property
    def active(self) -> bool:
        return bool(self.phrases)


DISABLED = HotwordsConfiguration(phrases=(), score=STRENGTH_SCORES[DEFAULT_STRENGTH])


def strength_score(strength: str) -> float:
    return STRENGTH_SCORES.get(strength, STRENGTH_SCORES[DEFAULT_STRENGTH])


def _is_edge(ch: str) -> bool:
    return ch.isspace() or ch in _EDGE_CHARACTERS


def phrase_from_replacement(replacement: str) -> str:
    """The replacement as a candidate phrase: edges trimmed, the inner text
    exactly as written (case variants hurt recognition, spec §3)."""
    start, end = 0, len(replacement)
    while start < end and _is_edge(replacement[start]):
        start += 1
    while end > start and _is_edge(replacement[end - 1]):
        end -= 1
    return replacement[start:end]


def comparison_key(text: str) -> str:
    """Case, punctuation and whitespace removed: two strings with the same
    key differ only by a punctuation, case or spacing edit."""
    return "".join(ch for ch in text.lower()
                   if not ch.isspace() and not unicodedata.category(ch).startswith("P"))


def eligible_phrase(source: str, replacement: str) -> Optional[str]:
    """The phrase for an entry, or ``None`` when the entry can never be a
    hotword. An explicit hint does not override these rules."""
    phrase = phrase_from_replacement(replacement)
    if len(phrase) < MIN_CHARACTERS or not any(ch.isalpha() for ch in phrase):
        return None
    if len(phrase.split()) > MAX_WORDS:
        return None
    if comparison_key(phrase) == comparison_key(source):
        return None
    return phrase


def _is_latin_letter(ch: str) -> bool:
    if not ch.isalpha():
        return False
    code = ord(ch)
    if 0x41 <= code <= 0x5A or 0x61 <= code <= 0x7A:
        return True
    if 0xC0 <= code <= 0x24F:
        return code not in (0xD7, 0xF7)
    return 0x1E00 <= code <= 0x1EFF


def is_term_like(phrase: str) -> bool:
    """A Latin letter or a digit, or at least two uppercase letters
    (ЕГРЮЛ, DDR4, TickTick). Shared with the learning hygiene (§2)."""
    uppercase = 0
    for ch in phrase:
        if _is_latin_letter(ch) or unicodedata.category(ch) == "Nd":
            return True
        if ch.isupper():
            uppercase += 1
            if uppercase >= 2:
                return True
    return False


def automatic_decision(phrase: str, origin: str) -> bool:
    """The decision for an eligible phrase whose ``asr_hint`` is NULL."""
    if str(getattr(origin, "value", origin)) == ORIGIN_MANUAL:
        return True
    return is_term_like(phrase)


def is_effective(source: str, replacement: str, origin: str,
                 hint: Optional[bool]) -> bool:
    """Whether the entry is boosted: skip rules first, then the explicit
    hint, then the automatic rule."""
    phrase = eligible_phrase(source, replacement)
    if phrase is None:
        return False
    return hint if hint is not None else automatic_decision(phrase, origin)


def phrases(records: Iterable) -> list[str]:
    """The hotword list for ``records`` (anything with ``source``,
    ``replacement``, ``origin`` and ``asr_hint``), in their order: exact
    duplicates merged, at most :data:`MAX_PHRASES`."""
    seen: set[str] = set()
    result: list[str] = []
    for record in records:
        phrase = eligible_phrase(record.source, record.replacement)
        if phrase is None or phrase in seen:
            continue
        hint = getattr(record, "asr_hint", None)
        if not (hint if hint is not None else automatic_decision(phrase, record.origin)):
            continue
        seen.add(phrase)
        result.append(phrase)
        if len(result) == MAX_PHRASES:
            break
    return result
