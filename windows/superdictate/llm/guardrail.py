"""Leading-word preservation guardrail for the LLM correction pass.

Port of ``swift/Sources/Parakey/LLMCorrectionGuardrail.swift``, behaviour
for behaviour, including the asymmetries the Swift file argues for at
length. Read that file's comments before changing any threshold here.

The bundled dictation-corrector is fast and very good at foreign-term and
script normalization, but has two failure modes inherited from its synthetic
training data:

1. It occasionally DROPS the input's leading word — «я скачал модель…» →
   «Скачал модель…». For a dictation app this is the worst possible
   corruption: the user's own words silently disappear.
2. It rarely hallucinates an unfamiliar term instead of normalizing it.

Both share one signature: the input's first word does not survive into the
output. This module checks exactly that — with enough fuzziness to let a
legitimate term replacement through («гитхаб» → «GitHub») — and falls back
to the uncorrected input on failure, per the pipeline's never-lose-text
policy. Everything here is deterministic and hermetic: no model, no I/O.
"""

from __future__ import annotations

import re

from ..logging_setup import get as get_logger

log = get_logger("llm.guardrail")

# Letters and digits only; every run of anything else separates words.
_WORD_RE = re.compile(r"[^\W_]+", re.UNICODE)

# U+0410..U+044F — А-Я а-я. `normalized_words` has already lowercased and
# mapped ё away by the time anything asks.
_CYRILLIC_RANGE = range(0x0410, 0x0450)

# Deliberately approximate Latin→Cyrillic mapping, for FUZZY comparison
# only: the edit distance forgives the approximation, so digraphs like "sh"
# and "ya" are intentionally not special-cased. Never use this for display.
_LATIN_TO_CYRILLIC = {
    "a": "а", "b": "б", "c": "ц", "d": "д", "e": "е", "f": "ф",
    "g": "г", "h": "х", "i": "и", "j": "й", "k": "к", "l": "л",
    "m": "м", "n": "н", "o": "о", "p": "п", "q": "к", "r": "р",
    "s": "с", "t": "т", "u": "у", "v": "в", "w": "в", "x": "кс",
    "y": "й", "z": "з",
}


def normalized_words(text: str) -> list[str]:
    """Lowercased, ё→е, punctuation-stripped words."""
    return _WORD_RE.findall(text.lower().replace("ё", "е"))


def edit_distance(lhs: str, rhs: str) -> int:
    """Classic Levenshtein distance."""
    if not lhs:
        return len(rhs)
    if not rhs:
        return len(lhs)
    previous = list(range(len(rhs) + 1))
    for i, a in enumerate(lhs, start=1):
        current = [i]
        for j, b in enumerate(rhs, start=1):
            current.append(min(previous[j] + 1,
                               current[j - 1] + 1,
                               previous[j - 1] + (0 if a == b else 1)))
        previous = current
    return previous[len(rhs)]


def _contains_cyrillic(word: str) -> bool:
    return any(ord(ch) in _CYRILLIC_RANGE for ch in word)


def _approximate_cyrillic(latin: str) -> str:
    return "".join(_LATIN_TO_CYRILLIC.get(ch, ch) for ch in latin.lower())


def preserves_leading_word(text_in: str, text_out: str) -> bool:
    """Whether the first significant word of the input survives the output.

    True when it survives verbatim, as a word-splice ("хаггинг фейс" →
    "HuggingFace"), or as a fuzzy Latin↔Cyrillic transliteration match
    within ``max(1, len // 3)`` edits ("гитхаб" → "GitHub" → "гитхуб",
    distance 1).
    """
    words_in = normalized_words(text_in)
    if not words_in:
        return True
    leading = words_in[0]
    words_out = normalized_words(text_out)

    # A single-character leading word («я», «а», «и»): substring checks are
    # meaningless at this length — they would match inside unrelated words —
    # so require it as one of the first three standalone words.
    if len(leading) <= 1:
        return leading in words_out[:3]

    # Verbatim, possibly shifted by one position.
    if leading in words_out[:2]:
        return True

    # Word-splice: the output fused the input's leading word with its second
    # word. Strictly anchored — the joined prefix must START with the
    # leading word and the remainder must start with the input's second word
    # (or be empty). A mere substring match would also admit hallucinated
    # EXTENSIONS of the leading word («золи» → «Золить…», an observed
    # failure).
    if len(words_in) >= 2:
        joined = "".join(words_out[:3])
        if joined.startswith(leading):
            remainder = joined[len(leading):]
            if not remainder or remainder.startswith(words_in[1]):
                return True

    # Cross-script term replacement ONLY. Same-script (Cyrillic) candidates
    # deliberately get no fuzzy matching: a 1-edit Cyrillic substitution is
    # indistinguishable from the model's hallucinated word forms («золей» →
    # «Золер», distance 1, a real observed failure), while legitimate
    # cross-script term fixes are exactly the Latin-word case. The cost of
    # this asymmetry — a legitimate single-letter Russian spelling fix of the
    # leading word falls back to the input — is the safe side of the
    # never-lose-text policy, and the deterministic vocabulary layer owns
    # Russian-term learning anyway.
    threshold = max(1, len(leading) // 3)
    for candidate in words_out[:2]:
        if _contains_cyrillic(candidate):
            continue
        if edit_distance(leading, _approximate_cyrillic(candidate)) <= threshold:
            return True
    return False


def sanitized_correction(text_in: str, text_out: str) -> str:
    """``text_out`` trimmed, or ``text_in`` unchanged if the check fails.

    Log-only on rejection; never raises, never blocks.
    """
    trimmed = text_out.strip()
    if not trimmed:
        return text_in
    if preserves_leading_word(text_in, trimmed):
        return trimmed
    log.info("Guardrail rejected correction (leading word lost); keeping original text")
    return text_in
