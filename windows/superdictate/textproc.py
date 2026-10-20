"""Deterministic transcript post-processing.

Straight port of the three passes in ``main.swift``, in the same order the
macOS app applies them:

1. ``SpeechModelTextRepair``: Parakeet TDT v3 emits ``<unk>`` where a
   Russian "ё" belongs; repair it for ru/auto, drop it elsewhere.
2. ``TranscriptCorrector``: the user's replacement dictionary. Runs
   before filler removal so explicit corrections always win.
3. ``FillerWordRemover``: conservative interjection stripping.

Swift's ``NSRegularExpression`` and Python's ``re`` agree on the syntax
used here except for ``\\p{L}``/``\\p{N}``, which Python lacks; the Unicode
character classes below are the equivalent, since Python's ``\\w`` is
already Unicode-aware and ``[^\\W\\d_]`` is exactly "a Unicode letter".
"""

from __future__ import annotations

import re
from functools import lru_cache
from typing import Iterable, Sequence

from .settings import Correction, TextStyle

# `\p{L}\p{N}` in Swift. Python's `\w` == letters + digits + underscore,
# so letters-or-digits is `\w` minus underscore.
_LETTER_OR_DIGIT = r"[^\W_]"

_UNK_TOKEN = "<unk>"


# -- 1. model text repair ------------------------------------------------


def repair_model_text(text: str, language: str = "auto") -> str:
    if _UNK_TOKEN not in text.lower():
        return text

    replace_with_yo = language in ("auto", "ru")
    result: list[str] = []
    index = 0
    lowered = text.lower()
    while index < len(text):
        if lowered.startswith(_UNK_TOKEN, index):
            if replace_with_yo:
                result.append("Ё" if _should_capitalize_yo(result) else "ё")
            index += len(_UNK_TOKEN)
        else:
            result.append(text[index])
            index += 1

    out = "".join(result)
    if not replace_with_yo:
        out = re.sub(r"\s+([.,!?;:])", r"\1", out)
        out = re.sub(r"[ \t]+", " ", out).strip()
    return out


def _should_capitalize_yo(prefix: Iterable[str]) -> bool:
    for char in reversed(list(prefix)):
        if char.isspace():
            continue
        return char in ".!?"
    return True


# -- 2. user corrections -------------------------------------------------


def normalized_corrections(corrections: Sequence[Correction]) -> list[Correction]:
    seen: set[str] = set()
    cleaned: list[Correction] = []
    for correction in corrections:
        source = " ".join(correction.source.split())
        replacement = correction.replacement.strip()
        if not source or not replacement:
            continue
        key = source.casefold()
        if key in seen:
            continue
        seen.add(key)
        cleaned.append(Correction(source, replacement))
    return cleaned


def _correction_pattern(source: str) -> str | None:
    parts = [re.escape(part) for part in source.split()]
    if not parts:
        return None
    # `_` is excluded from the boundary the same way Swift's
    # `(?<![\p{L}\p{N}_])` does, so `foo_bar` is not a match for `bar`.
    return r"(?<![^\W_]|_)" + r"\s+".join(parts) + r"(?![^\W_]|_)"


def apply_corrections(
    text: str, corrections: Sequence[Correction]
) -> tuple[str, int]:
    active = sorted(
        normalized_corrections(corrections),
        key=lambda c: (-len(c.source), c.source.casefold()),
    )
    if not text or not active:
        return text, 0

    matches: list[tuple[int, int, str]] = []
    for correction in active:
        pattern = _correction_pattern(correction.source)
        if pattern is None:
            continue
        try:
            regex = re.compile(pattern, re.IGNORECASE | re.UNICODE)
        except re.error:
            continue
        for match in regex.finditer(text):
            start, end = match.span()
            # Longest-source-first ordering plus this overlap guard is
            # what makes the result independent of dictionary order.
            if any(start < other_end and other_start < end
                   for other_start, other_end, _ in matches):
                continue
            matches.append((start, end, correction.replacement))

    if not matches:
        return text, 0

    rewritten = text
    for start, end, replacement in sorted(matches, key=lambda m: -m[0]):
        rewritten = rewritten[:start] + replacement + rewritten[end:]
    return rewritten, len(matches)


# -- 3. filler words -----------------------------------------------------

# The words offered in the settings, with the pattern each one matches.
# A pattern of ``None`` means "the word itself", which is also what a word
# the user types gets: predictable, and it cannot quietly eat a longer
# word that starts the same way.
#
# Trailing-letter repeats are spelled out where a real filler stretches
# ("ummm", "эээ"). "er"/"erm" deliberately have no quantifier, so the real
# word "err" survives.
#
# Which of these start out enabled is decided in ``settings``: an "эм" can
# only ever be a hesitation, but "это", "вот" and "значит" are ordinary
# words that happen to also be used as filler, and a dictation app that
# deletes them uninvited is worse than one that leaves them in.
PRESET_FILLERS: tuple[tuple[str, str | None], ...] = (
    # Russian hesitation sounds.
    ("э", "э+"),
    ("эм", "э+м+"),
    ("ээ", "э{2,}"),
    ("м", "м+"),
    ("мм", "м{2,}"),
    ("ам", "а+м+"),
    ("аа", "а{2,}"),
    ("ну", "ну+"),
    # Russian verbal tics: phrases that are almost never anything else.
    ("как бы", None),
    ("типа", None),
    ("короче", None),
    ("это самое", None),
    ("так сказать", None),
    ("в общем", None),
    ("в принципе", None),
    ("собственно", None),
    ("допустим", None),
    ("слушай", None),
    ("понимаешь", None),
    ("знаешь", None),
    # Russian words that are filler only sometimes; off by default.
    ("это", None),
    ("вот", None),
    ("значит", None),
    ("просто", None),
    ("реально", None),
    ("походу", None),
    ("блин", None),
    # English.
    ("um", "um+"),
    ("uh", "uh+"),
    ("ah", "ah+"),
    ("er", "er"),
    ("erm", "erm"),
    ("hm", "hm+"),
    ("like", None),
    ("you know", None),
    ("i mean", None),
    ("actually", None),
    ("basically", None),
)

_PRESET_PATTERNS = dict(PRESET_FILLERS)

_SENTENCE_TERMINATORS = ".!?"
_BOUNDARY_WRAPPERS = "\"'“”‘’([{"
_ORPHAN_SEPARATORS = ",.;:!?"


def _pattern_for(word: str) -> str:
    """The regex a single entry contributes.

    Spaces become "one or more spaces" so a two-word tic still matches when
    the model puts a wider gap in, and a word the settings do not know is
    escaped whole: whatever the user typed, and nothing else.
    """
    known = _PRESET_PATTERNS.get(word.strip().lower())
    if known is not None:
        return known
    return r"\s+".join(re.escape(part) for part in word.split())


@lru_cache(maxsize=8)
def _filler_regex(words: tuple[str, ...]) -> re.Pattern[str] | None:
    """Cached because it is rebuilt for every dictation from a settings list.

    Longest first, so "это самое" is matched as one tic rather than as
    "это" followed by a stray "самое".
    """
    ordered = sorted({word.strip() for word in words if word.strip()},
                     key=len, reverse=True)
    if not ordered:
        return None
    return re.compile(
        r"(?<![^\W_]|['\-])(?:" + "|".join(_pattern_for(w) for w in ordered)
        + r")(?![^\W_]|['\-])",
        re.IGNORECASE | re.UNICODE,
    )


def remove_filler_words(text: str,
                        words: Sequence[str] | None = None) -> tuple[str, int]:
    if not text:
        return text, 0
    if words is None:
        from .settings import DEFAULT_FILLER_WORDS

        words = DEFAULT_FILLER_WORDS
    regex = _filler_regex(tuple(words))
    if regex is None:
        return text, 0
    matches = list(regex.finditer(text))
    if not matches:
        return text, 0

    targets = _capitalization_targets(matches, text)

    result = text
    for match in reversed(matches):
        start, end = match.span()
        result = result[:start] + result[end:]

    # Clean up the artifacts removal leaves behind, in the same order as
    # the Swift implementation, the order matters, e.g. pass 3 can glue a
    # comma onto terminal punctuation that pass 4 then has to unglue.
    result = re.sub(r"\s*,(?:\s*,)+", ",", result)
    result = re.sub(r"([.!?])\s+[,.;:!?]+\s*", r"\1 ", result)
    result = re.sub(r"\s+([.,!?;:])", r"\1", result)
    result = re.sub(r",+([.!?;:])", r"\1", result)
    result = re.sub(r"\s+", " ", result)
    result = re.sub(r"^[\s,.;:!?]+", "", result)
    result = result.strip()
    result = _restore_capitalization(result, targets)
    return result, len(matches)


def _capitalization_targets(matches, text: str) -> set[object]:
    """Which sentence starts lost their capital to a removed filler.

    ``"start"`` for the very beginning of the text, or the 1-based ordinal
    of the sentence terminator the filler followed.
    """
    targets: set[object] = set()
    for match in matches:
        if not match.group(0)[:1].isupper():
            continue
        target = _capitalization_target(match.start(), text)
        if target is not None:
            targets.add(target)
    return targets


def _capitalization_target(start: int, text: str) -> object | None:
    index = start
    while index > 0:
        previous = index - 1
        char = text[previous]
        if char.isspace() or char in _BOUNDARY_WRAPPERS:
            index = previous
            continue
        if char not in _SENTENCE_TERMINATORS:
            return None
        ordinal = sum(1 for c in text[: previous + 1] if c in _SENTENCE_TERMINATORS)
        return ("after", ordinal)
    return "start"


def _restore_capitalization(text: str, targets: set[object]) -> str:
    if not targets or not text:
        return text

    sentence_targets = {ordinal for kind, ordinal in
                        (t for t in targets if isinstance(t, tuple))}
    result: list[str] = []
    terminator_ordinal = 0
    capitalize_next = "start" in targets

    for char in text:
        if capitalize_next:
            if char.islower():
                result.append(char.upper())
                capitalize_next = False
                continue
            if char.isalnum():
                capitalize_next = False

        result.append(char)

        if char in _SENTENCE_TERMINATORS:
            terminator_ordinal += 1
            if terminator_ordinal in sentence_targets:
                capitalize_next = True
        elif capitalize_next and not char.isspace() \
                and char not in _BOUNDARY_WRAPPERS \
                and char not in _ORPHAN_SEPARATORS:
            capitalize_next = False

    return "".join(result)


# -- 4. numbers as digits ------------------------------------------------
#
# Parakeet writes numbers out in words. "Позвони на двадцать три" is not
# what anyone wants in a phone field, so spoken numerals are folded back
# into digits. Only 0-999 is handled: past that, speech starts mixing in
# units and cases ("тысяча двести", "две тысячи") that a table cannot
# resolve, and a half-converted "2 тысячи 200" is worse than the words.

_UNITS_RU = {
    "ноль": 0, "нуль": 0,
    "один": 1, "одна": 1, "одно": 1,
    "два": 2, "две": 2,
    "три": 3, "четыре": 4, "пять": 5, "шесть": 6,
    "семь": 7, "восемь": 8, "девять": 9,
}
_TEENS_RU = {
    "десять": 10, "одиннадцать": 11, "двенадцать": 12, "тринадцать": 13,
    "четырнадцать": 14, "пятнадцать": 15, "шестнадцать": 16,
    "семнадцать": 17, "восемнадцать": 18, "девятнадцать": 19,
}
_TENS_RU = {
    "двадцать": 20, "тридцать": 30, "сорок": 40, "пятьдесят": 50,
    "шестьдесят": 60, "семьдесят": 70, "восемьдесят": 80, "девяносто": 90,
}
_HUNDREDS_RU = {
    "сто": 100, "двести": 200, "триста": 300, "четыреста": 400,
    "пятьсот": 500, "шестьсот": 600, "семьсот": 700, "восемьсот": 800,
    "девятьсот": 900,
}

_UNITS_EN = {
    "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4,
    "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
}
_TEENS_EN = {
    "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
    "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
    "nineteen": 19,
}
_TENS_EN = {
    "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
    "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
}

_NUMBER_TOKEN = re.compile(r"[^\W\d_]+", re.UNICODE)


def _numeral_value(word: str, language: str) -> tuple[Optional[int], str]:
    """The value of one spoken numeral and which place it occupies."""
    lowered = word.lower()
    tables = ((_HUNDREDS_RU, "hundreds"), (_TENS_RU, "tens"),
              (_TEENS_RU, "teens"), (_UNITS_RU, "units"))
    if language == "en":
        tables = ((_TENS_EN, "tens"), (_TEENS_EN, "teens"),
                  (_UNITS_EN, "units"))
    for table, place in tables:
        if lowered in table:
            return table[lowered], place
    return None, ""


_PLACE_ORDER = {"hundreds": 3, "tens": 2, "teens": 2, "units": 1}


def numbers_as_digits(text: str, language: str = "ru") -> str:
    """Fold spoken numerals into digits: "двадцать три" -> "23".

    Words are only joined while each one names a smaller place than the
    last, which is what keeps "два три" (two separate numbers, as in a
    dictated code) from silently becoming "23", and stops "сто сто" from
    becoming anything at all.
    """
    if not text:
        return text
    tokens = list(_NUMBER_TOKEN.finditer(text))
    if not tokens:
        return text

    pieces: list[str] = []
    cursor = 0
    index = 0
    while index < len(tokens):
        value, place = _numeral_value(tokens[index].group(0), language)
        if value is None:
            index += 1
            continue

        total = value
        last_place = _PLACE_ORDER[place]
        end = index
        # "теens" already spend the tens place, so nothing may follow them.
        while place != "teens" and end + 1 < len(tokens):
            # Only a plain space may join two numerals; a comma or a full
            # stop between them means two numbers, not one.
            gap = text[tokens[end].end():tokens[end + 1].start()]
            if gap.strip():
                break
            next_value, next_place = _numeral_value(
                tokens[end + 1].group(0), language)
            if next_value is None or _PLACE_ORDER[next_place] >= last_place:
                break
            total += next_value
            last_place = _PLACE_ORDER[next_place]
            place = next_place
            end += 1

        start_offset = tokens[index].start()
        pieces.append(text[cursor:start_offset])
        pieces.append(str(total))
        cursor = tokens[end].end()
        index = end + 1

    pieces.append(text[cursor:])
    return "".join(pieces)


# -- 5. text style -------------------------------------------------------


# The whole run of marks is captured, so "..." and "?!" are recognised as
# one break rather than two. The trailing word is matched without its own
# punctuation, so the stop that ends *it* is still there for the next pass
# of the same scan.
_SENTENCE_BREAK = re.compile(r"([.!?]+)[ \t]+([^\s.!?]+)")


def _is_acronym(word: str) -> bool:
    """Two or more letters, all upper case: HTTP, ГОСТ, USB-C.

    The old test asked whether the first two *characters* were upper
    case, which counts a space as upper case, so a sentence opening with
    a one-letter word ("Я думаю") was mistaken for an acronym and kept
    its capital in the informal style.
    """
    letters = [char for char in word if char.isalpha()]
    return len(letters) >= 2 and all(char.isupper() for char in letters)


def _lower_first_word(text: str) -> str:
    head = text.split(maxsplit=1)[0] if text.split() else ""
    if not head or _is_acronym(head):
        return text
    return text[:1].lower() + text[1:]


# A word, hyphens and apostrophes included, so "USB-C" and "don't" are
# each one word rather than two halves.
_WORD = re.compile(r"[^\W_]+(?:['\-][^\W_]+)*", re.UNICODE)


def _lower_all_words(text: str) -> str:
    """Every word in lower case, acronyms excepted.

    The casual style has no capitals at all, not just no capital at the
    start. Lowering only the word after a full stop left everything the
    model capitalised for its own reasons ("привет, Как дела?") standing.
    """
    return _WORD.sub(
        lambda m: m.group(0) if _is_acronym(m.group(0)) else m.group(0).lower(),
        text,
    )


def _soften_sentence_breaks(text: str) -> str:
    """Run the sentences together the way speech does.

    A full stop between two sentences becomes a comma. Anything else, a
    question mark, an exclamation, an ellipsis, stays as it is, because
    it carries a tone a comma cannot. Case is not this pass's business;
    the final stop is left to the caller, which removes it.
    """
    def replace(match: re.Match) -> str:
        marks = match.group(1)
        return f"{',' if marks == '.' else marks} {match.group(2)}"

    return _SENTENCE_BREAK.sub(replace, text)


def apply_text_style(text: str, style: TextStyle) -> str:
    """Trim the model's sentence punctuation to the chosen register.

    Only a trailing full stop goes: "?" and "!" carry meaning that the
    user dictated on purpose, and an ellipsis is not a full stop either.
    """
    if style is TextStyle.FORMAL or not text:
        return text

    stripped = text.rstrip()
    if style is TextStyle.CASUAL:
        stripped = _lower_all_words(_soften_sentence_breaks(stripped))
    if stripped.endswith(".") and not stripped.endswith(".."):
        stripped = stripped[:-1].rstrip()
    if not stripped:
        return stripped

    if style is TextStyle.INFORMAL:
        stripped = _lower_first_word(stripped)
    return stripped


# -- pipeline ------------------------------------------------------------


def process_transcript(
    raw: str,
    *,
    language: str = "auto",
    corrections: Sequence[Correction] = (),
    strip_fillers: bool = False,
    filler_words: Sequence[str] | None = None,
    digits: bool = False,
    style: TextStyle = TextStyle.FORMAL,
) -> tuple[str, int, int]:
    """Returns (text, corrections applied, fillers removed)."""
    text = repair_model_text(raw.strip(), language=language)
    text, applied = apply_corrections(text, corrections)
    removed = 0
    if strip_fillers:
        text, removed = remove_filler_words(text, filler_words)
    if digits:
        # After corrections, so a replacement rule can still spell a
        # number out in words and have it converted like any other.
        text = numbers_as_digits(
            text, "en" if language.startswith("en") else "ru")
    # Style last: it works on the finished sentence, so filler removal
    # cannot re-expose a full stop that this pass already took off.
    text = apply_text_style(text.strip(), style)
    return text.strip(), applied, removed


# What counts as one token when a hand-corrected transcript is compared
# with the model's own. Letters and digits, plus the inner hyphen and
# apostrophe that hold "какой-то" and "don't" together.
_WORD_RE = re.compile(r"[^\W_]+(?:[-'’][^\W_]+)*", re.UNICODE)


def _learnable(source: str, replacement: str) -> bool:
    """Whether a pair is worth remembering at all.

    A difference only in case or only in punctuation is not a
    misrecognition, it is the text style setting or a comma the user moved.
    Storing those would make the dictionary rewrite correct text.
    """
    if not source or not replacement:
        return False
    if source == replacement:
        return False
    def bare(phrase: str) -> str:
        # Joined with the space kept, not dropped: "не много" for
        # "немного" is a genuine correction, and running the words
        # together here would make it look like a comma had moved.
        return " ".join(_WORD_RE.findall(phrase)).casefold()

    return bare(source) != bare(replacement)


def learned_corrections(heard: str, meant: str) -> list[tuple[str, str]]:
    """The word pairs implied by an edit, as (what came out, what it was).

    Only substitutions are learnable. A word the user simply deleted has
    nothing to be replaced by, and a word they inserted has nothing to
    replace, so both sides of a pair must exist for it to be a rule; the
    dictionary rejects a half of one in any case.

    Runs of the same length are paired word by word, which is the common
    case of one misheard word among many. A run of a different length is
    kept whole — "не мог" for "немного" is a real rule, and splitting it
    would produce two wrong ones.
    """
    from difflib import SequenceMatcher

    before = _WORD_RE.findall(heard)
    after = _WORD_RE.findall(meant)
    if not before or not after:
        return []

    matcher = SequenceMatcher(
        None, [word.casefold() for word in before],
        [word.casefold() for word in after], autojunk=False)
    pairs: list[tuple[str, str]] = []
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag != "replace":
            continue
        if i2 - i1 == j2 - j1:
            candidates = list(zip(before[i1:i2], after[j1:j2]))
        else:
            candidates = [(" ".join(before[i1:i2]), " ".join(after[j1:j2]))]
        pairs.extend(pair for pair in candidates if _learnable(*pair))
    return pairs
