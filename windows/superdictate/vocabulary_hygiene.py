"""Which learned corrections are worth keeping.

docs/specs/vocabulary-hygiene-and-sync-spec.md §2–§3, the Windows twin of
the macOS ``VocabularyHygiene``. Pure functions only, no store access: the
caller passes the existing entries in and applies the verdict.

Auto-learning stores every short contiguous edit made after a dictation,
and a real dictionary showed what that produces: punctuation-only edits,
grammar fixes of ordinary words, whole-sentence rewrites, typo-of-a-typo
chains and three casings of one term. :func:`review` filters a candidate
before it is ever offered (no pill, no write); :func:`cleanup_plan` runs
the same rules over an existing dictionary for the "Clean up…" preview.

Rules, in order (§2):

1. trim edge punctuation on both sides;
2. reject punctuation/case-only edits of ordinary (not term-like) words;
3. reject replacements without letters or shorter than two characters;
4. reject Russian inflection edits («Запомню → Запомни»);
5. reject content rewrites (transliterated similarity below 0.3);
6. undo: ``replacement → source`` already exists, so the user reverted it;
7. chains: ``replacement → Z`` gives ``source → Z``; ``X → source`` entries
   are rewritten to ``X → replacement``;
8. case unification with an existing entry for the same target.

One deliberate ordering difference from the list: the undo check (6) runs
right after trimming, before rules 2–5. A revert must remove the earlier
rule even when that rule predates this filter and would itself be
rejected by it («Запомню → Запомни» learned by an older build, then put
back by hand).
"""

from __future__ import annotations

import unicodedata
from dataclasses import dataclass, field
from typing import Optional, Sequence, Union

from .asr_hotwords import is_term_like

#: Trimmed from both ends of each side (rule 1), together with whitespace.
EDGE_PUNCTUATION = frozenset(".,!?;:…—–-«»\"'()")

REJECT_EMPTY = "empty"
REJECT_PUNCTUATION = "punctuation"
REJECT_NO_LETTERS = "no-letters"
REJECT_INFLECTION = "inflection"
REJECT_REWRITE = "rewrite"
#: Cleanup only: another entry ends up with the same key.
REJECT_DUPLICATE = "duplicate"
#: Cleanup only: the entry would replace a word with itself.
REJECT_NOOP = "noop"

REWRITE_TRIM = "trim"
REWRITE_CHAIN = "chain"
REWRITE_CASE = "case"

REWRITE_SIMILARITY_FLOOR = 0.3
_INFLECTION_MIN_PREFIX = 3
_INFLECTION_PREFIX_SHARE = 0.6
_INFLECTION_MAX_TAIL = 4
_LOWERCASE_ACRONYM_MAX = 5
_CHAIN_DEPTH = 16

# A simple GOST-like map; only the similarity of the two sides matters.
_TRANSLIT = dict(zip(
    "абвгдеёжзийклмнопрстуфхцчшщъыьэюя",
    ["a", "b", "v", "g", "d", "e", "e", "zh", "z", "i", "y", "k", "l", "m",
     "n", "o", "p", "r", "s", "t", "u", "f", "kh", "ts", "ch", "sh", "sch",
     "", "y", "", "e", "yu", "ya"]))


# -- verdicts --------------------------------------------------------------

@dataclass(frozen=True)
class Accept:
    source: str
    replacement: str
    #: Rule 7b: ``(entry id, new replacement)`` for entries ``X → source``.
    chain_rewrites: tuple[tuple[int, str], ...] = ()


@dataclass(frozen=True)
class Reject:
    reason: str


@dataclass(frozen=True)
class Undo:
    existing_id: int


Verdict = Union[Accept, Reject, Undo]


# -- text helpers ----------------------------------------------------------

def _is_edge(ch: str) -> bool:
    return ch.isspace() or ch in EDGE_PUNCTUATION


def trim_edges(text: str) -> str:
    """Rule 1 for one side: edge punctuation and whitespace removed, inner
    whitespace collapsed."""
    start, end = 0, len(text)
    while start < end and _is_edge(text[start]):
        start += 1
    while end > start and _is_edge(text[end - 1]):
        end -= 1
    return " ".join(text[start:end].split())


def normalized(text: str) -> str:
    """The comparison form for rules 6–8: edges trimmed, NFC, casefolded,
    whitespace collapsed."""
    return " ".join(unicodedata.normalize("NFC", trim_edges(text)).casefold().split())


def _letters_key(text: str) -> str:
    """Rule 2: all punctuation and whitespace removed, lowercased."""
    return "".join(ch for ch in text.lower()
                   if not ch.isspace() and not unicodedata.category(ch).startswith("P"))


def _is_cyrillic_letter(ch: str) -> bool:
    return ch.isalpha() and ("CYRILLIC" in unicodedata.name(ch, ""))


def _is_cyrillic_word(text: str) -> bool:
    return bool(text) and all(_is_cyrillic_letter(ch) for ch in text)


def _uppercase_count(text: str) -> int:
    return sum(1 for ch in text if ch.isupper())


def transliterate(text: str) -> str:
    """Latin lowercase letters and digits only."""
    out = []
    for ch in text.lower():
        if ch in _TRANSLIT:
            out.append(_TRANSLIT[ch])
        elif ch.isascii() and ch.isalnum():
            out.append(ch)
        elif ch.isdigit():
            out.append(str(unicodedata.digit(ch, 0)))
        elif ch.isalpha():
            decomposed = unicodedata.normalize("NFKD", ch)
            out.append("".join(c for c in decomposed if c.isascii() and c.isalpha()))
    return "".join(out)


def levenshtein(a: str, b: str) -> int:
    if len(a) < len(b):
        a, b = b, a
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i]
        for j, cb in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1,
                               previous[j - 1] + (ca != cb)))
        previous = current
    return previous[-1]


def similarity(source: str, replacement: str) -> float:
    a, b = transliterate(source), transliterate(replacement)
    longest = max(len(a), len(b))
    if longest == 0:
        return 1.0
    return 1.0 - levenshtein(a, b) / longest


def _is_acronym(replacement: str) -> bool:
    """«MCP», «IS-60», or a short lowercase Latin one like «ssh»."""
    if len(replacement) >= 2 and all(
            ("A" <= ch <= "Z") or ch.isdigit() or ch == "-" for ch in replacement):
        return any("A" <= ch <= "Z" for ch in replacement)
    return 2 <= len(replacement) <= _LOWERCASE_ACRONYM_MAX and all(
        "a" <= ch <= "z" for ch in replacement)


def _is_inflection(source: str, replacement: str) -> bool:
    if not (_is_cyrillic_word(source) and _is_cyrillic_word(replacement)):
        return False
    if _uppercase_count(replacement) >= 2:
        return False
    a, b = source.lower(), replacement.lower()
    prefix = 0
    while prefix < min(len(a), len(b)) and a[prefix] == b[prefix]:
        prefix += 1
    return (prefix >= _INFLECTION_MIN_PREFIX
            and prefix >= _INFLECTION_PREFIX_SHARE * min(len(a), len(b))
            and len(a) - prefix <= _INFLECTION_MAX_TAIL
            and len(b) - prefix <= _INFLECTION_MAX_TAIL)


# -- the rules -------------------------------------------------------------

def quality_reason(source: str, replacement: str) -> Optional[str]:
    """Rules 2–5 on already trimmed sides; the rejection reason or None."""
    if not source:
        return REJECT_EMPTY
    if _letters_key(source) == _letters_key(replacement) and not is_term_like(replacement):
        return REJECT_PUNCTUATION
    if len(replacement) < 2 or not any(ch.isalpha() for ch in replacement):
        return REJECT_NO_LETTERS
    if _is_inflection(source, replacement):
        return REJECT_INFLECTION
    if not _is_acronym(replacement) and similarity(source, replacement) < REWRITE_SIMILARITY_FLOOR:
        return REJECT_REWRITE
    return None


def review_manual(source: str, replacement: str) -> Verdict:
    """The manual editor: rule 1 and rule 3 only (the user is explicit)."""
    source, replacement = trim_edges(source), trim_edges(replacement)
    if not source:
        return Reject(REJECT_EMPTY)
    if len(replacement) < 2 or not any(ch.isalpha() for ch in replacement):
        return Reject(REJECT_NO_LETTERS)
    return Accept(source, replacement)


def _newest(entries: Sequence) -> object:
    return max(entries, key=lambda e: (str(e.updated_at), int(e.id)))


def _is_manual(entry) -> bool:
    return str(getattr(entry.origin, "value", entry.origin)) == "manual"


def _unified_case(replacement: str, others: Sequence) -> str:
    """Rule 8: the casing an existing entry already uses for this target."""
    folded = normalized(replacement)
    group = [e for e in others if normalized(e.replacement) == folded]
    if not group:
        return replacement
    manual = [e for e in group if _is_manual(e)]
    return trim_edges(_newest(manual or group).replacement)


def review(source: str, replacement: str, existing: Sequence) -> Verdict:
    """A learned candidate against the current dictionary.

    ``existing``: records with ``id``, ``source``, ``replacement``,
    ``origin`` and ``updated_at`` (:class:`vocabulary.Record`).
    """
    source, replacement = trim_edges(source), trim_edges(replacement)
    if not source:
        return Reject(REJECT_EMPTY)
    source_key, replacement_key = normalized(source), normalized(replacement)

    # Rule 6, early (see the module docstring).
    for entry in existing:
        if normalized(entry.source) == replacement_key and normalized(entry.replacement) == source_key:
            return Undo(int(entry.id))

    reason = quality_reason(source, replacement)
    if reason is not None:
        return Reject(reason)

    # Rule 7a: the target is itself corrected further.
    for entry in existing:
        if normalized(entry.source) == replacement_key:
            target = trim_edges(entry.replacement)
            if target and normalized(target) != source_key:
                replacement = target
                replacement_key = normalized(target)
            break

    # Rule 8. A case fix of the source itself («Github → GitHub») is the
    # user choosing the casing, so it is kept as typed.
    others = [e for e in existing if normalized(e.source) != source_key]
    if source.casefold() != replacement.casefold():
        replacement = _unified_case(replacement, others)

    # Rule 7b: chains ending at this source collapse onto the new target.
    rewrites = []
    for entry in others:
        if normalized(entry.replacement) == source_key and normalized(entry.source) != replacement_key:
            if entry.replacement != replacement:
                rewrites.append((int(entry.id), replacement))
    return Accept(source, replacement, tuple(rewrites))


# -- cleaning an existing dictionary (§3) ----------------------------------

@dataclass(frozen=True)
class CleanupDeletion:
    record: object
    reason: str


@dataclass(frozen=True)
class CleanupRewrite:
    record: object
    source: str
    replacement: str
    reasons: tuple[str, ...]


@dataclass
class CleanupPlan:
    deletions: list[CleanupDeletion] = field(default_factory=list)
    rewrites: list[CleanupRewrite] = field(default_factory=list)

    @property
    def duplicates(self) -> list[CleanupDeletion]:
        return [d for d in self.deletions if d.reason == REJECT_DUPLICATE]

    @property
    def is_empty(self) -> bool:
        return not self.deletions and not self.rewrites


def _store_key(text: str) -> str:
    """The dictionary's own dedup key (NFC, casefold, whitespace collapsed)."""
    return " ".join(unicodedata.normalize("NFC", text).casefold().split())


def cleanup_plan(records: Sequence) -> CleanupPlan:
    """Rules 1–5 and 7–8 over the **learned** entries; manual ones are never
    touched. Nothing is written: the caller shows the plan and applies it."""
    plan = CleanupPlan()
    manual = [r for r in records if _is_manual(r)]
    learned = [r for r in records if not _is_manual(r)]

    # Rules 1–5.
    state: dict[int, list] = {}          # id -> [record, source, replacement, reasons]
    for record in learned:
        source, replacement = trim_edges(record.source), trim_edges(record.replacement)
        reason = quality_reason(source, replacement)
        if reason is not None:
            plan.deletions.append(CleanupDeletion(record, reason))
            continue
        reasons = [REWRITE_TRIM] if (source, replacement) != (record.source, record.replacement) else []
        state[int(record.id)] = [record, source, replacement, reasons]

    # Duplicates that collapse into one key: a manual entry always wins,
    # otherwise the most recently updated learned one.
    manual_keys = {_store_key(r.source) for r in manual}
    by_key: dict[str, list] = {}
    for item in state.values():
        by_key.setdefault(_store_key(item[1]), []).append(item)
    for key, items in by_key.items():
        keep = None if key in manual_keys else _newest([i[0] for i in items])
        for item in items:
            if item[0] is not keep:
                plan.deletions.append(CleanupDeletion(item[0], REJECT_DUPLICATE))
                del state[int(item[0].id)]

    # Rule 7: follow chains to their final target.
    targets: dict[str, str] = {}
    for record in manual:
        targets[normalized(record.source)] = trim_edges(record.replacement)
    for _, source, replacement, _ in state.values():
        targets.setdefault(normalized(source), replacement)
    for item in state.values():
        _, source, replacement, reasons = item
        visited = {normalized(source)}
        target = replacement
        for _ in range(_CHAIN_DEPTH):
            key = normalized(target)
            if key in visited or key not in targets:
                break
            visited.add(key)
            target = targets[key]
        if normalized(target) != normalized(source) and target != replacement:
            item[2] = target
            reasons.append(REWRITE_CHAIN)

    # Rule 8: one casing per target. Case fixes («Github → GitHub») are
    # the user's explicit casing: they neither vote nor change.
    def is_case_fix(source: str, replacement: str) -> bool:
        return source.casefold() == replacement.casefold()

    voters: dict[str, list] = {}
    for record in manual:
        replacement = trim_edges(record.replacement)
        voters.setdefault(replacement.casefold(), []).append(
            (record, replacement, True))
    for record, source, replacement, _ in state.values():
        if not is_case_fix(source, replacement):
            voters.setdefault(replacement.casefold(), []).append((record, replacement, False))
    for item in state.values():
        record, source, replacement, reasons = item
        if is_case_fix(source, replacement):
            continue
        group = voters.get(replacement.casefold(), [])
        if len({g[1] for g in group}) < 2:
            continue
        pool = [g for g in group if g[2]] or group
        winner = max(pool, key=lambda g: (str(g[0].updated_at), int(g[0].id)))
        if winner[1] != replacement:
            item[2] = winner[1]
            reasons.append(REWRITE_CASE)

    for record, source, replacement, reasons in state.values():
        if source == replacement:
            plan.deletions.append(CleanupDeletion(record, REJECT_NOOP))
        elif reasons:
            plan.rewrites.append(CleanupRewrite(record, source, replacement, tuple(reasons)))
    return plan
