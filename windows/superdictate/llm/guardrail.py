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
policy. It also checks the word count, like the macOS guardrail: the
prompt forbids adding or removing words, so a large drift is the model
dropping a tail or echoing an example, never an edit. Everything here is
deterministic and hermetic: no model, no I/O.

One deliberate difference: the corrector is trained to delete filler words
(«ну короче завтра…» → «Завтра…»), so both checks look at the input with its
unambiguous fillers removed. Otherwise every correctly cleaned dictation
that starts with «ну» would be reverted as "leading word lost".
"""

from __future__ import annotations

import re

from ..logging_setup import get as get_logger
from ..textproc import remove_filler_words

log = get_logger("llm.guardrail")

# Letters and digits only; every run of anything else separates words.
_WORD_RE = re.compile(r"[^\W_]+", re.UNICODE)

# Fillers the VoiceScribe corrector deletes by design, so a dropped one is
# an edit, not a lost word. Same list as LLMCorrectionGuardrail.swift;
# both self-tests check it against fixtures/llm-correction-guardrail.json,
# which says where each entry comes from (the model card's policy and a
# probe of the real model). Words the model keeps and that are often real
# words («вот», «это», «просто», «слушай», «в общем»…) are not here.
MODEL_REMOVED_FILLERS: tuple[str, ...] = (
    "э", "ээ", "эм", "м", "мм", "ам", "аа",
    "ну", "типа", "короче", "короче говоря", "так сказать", "значит",
    "um", "uh", "ah", "er", "erm", "hm",
)

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


def preserves_word_count(text_in: str, text_out: str) -> bool:
    """Whether ``text_out`` has roughly as many words: within ``max(2, 10 %)``.

    The floor of 2 absorbs legitimate term merges («гит хаб» → «GitHub»,
    «пул реквест» → «pull request») on short inputs.
    """
    count_in = len(normalized_words(text_in))
    count_out = len(normalized_words(text_out))
    return abs(count_out - count_in) <= max(2, count_in // 10)


def without_model_removed_fillers(text: str) -> str:
    """``text`` as the corrector is expected to leave it, filler-wise."""
    return remove_filler_words(text, MODEL_REMOVED_FILLERS)[0]


def sanitized_correction(text_in: str, text_out: str) -> str:
    """``text_out`` trimmed, or ``text_in`` unchanged if a check fails.

    Log-only on rejection; never raises, never blocks.
    """
    trimmed = text_out.strip()
    if not trimmed:
        return text_in
    # Compared with the fillers gone, but either form counts: the model may
    # also leave a filler in.
    candidates = (without_model_removed_fillers(text_in) or text_in, text_in)
    if not any(preserves_leading_word(c, trimmed) for c in candidates):
        log.info("Guardrail rejected correction (leading word lost); keeping original text")
        return text_in
    if not any(preserves_word_count(c, trimmed) for c in candidates):
        log.info("Guardrail rejected correction (word count %d → %d); keeping original text",
                 len(normalized_words(text_in)), len(normalized_words(trimmed)))
        return text_in
    return trimmed


def correction_chunks(text: str, max_characters: int = 500) -> list[str]:
    """Sentence-bounded pieces of at most ``max_characters``, one request each.

    Port of ``LLMCorrectionGuardrail.correctionChunks``. The corrector was
    trained on short utterances and fails far more often on long inputs
    (macOS, 4-minute dictation: no rejected pieces at 500 chars, whole-text
    garbage at 1500); a failed piece then falls back to its own raw text,
    not the whole dictation's. A sentence longer than the limit is cut at
    the last space before it. Joining with " " restores the text up to
    whitespace runs.
    """
    trimmed = text.strip()
    if len(trimmed) <= max_characters:
        return [trimmed] if trimmed else []

    sentences: list[str] = []
    sentence = ""
    previous = ""
    for character in trimmed:
        if character.isspace() and previous and previous in ".!?…":
            sentences.append(sentence)
            sentence = ""
        elif not (character.isspace() and not sentence):
            sentence += character
        previous = character
    if sentence:
        sentences.append(sentence)

    chunks: list[str] = []
    current = ""
    for piece in sentences:
        while len(piece) > max_characters:
            if current:
                chunks.append(current)
                current = ""
            cut = piece.rfind(" ", 0, max_characters)
            if cut <= 0:
                cut = max_characters
            chunks.append(piece[:cut].strip())
            piece = piece[cut:].strip()
        if not current:
            current = piece
        elif len(current) + 1 + len(piece) <= max_characters:
            current += " " + piece
        else:
            chunks.append(current)
            current = piece
    if current:
        chunks.append(current)
    return [chunk for chunk in chunks if chunk]
