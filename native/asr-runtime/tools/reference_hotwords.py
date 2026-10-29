"""Reference hotwords (vocabulary biasing) for reference_tdt.py and
reference_gigaam.py (development only).

Independent Python twin of src/families/hotwords.cpp, written from the spec
docs/specs/asr-hotwords-spec.md §4-§5: the phrase tokenizers (SentencePiece
BPE from tokens.txt, SentencePiece unigram from a "<piece>\\t<score>" file),
the boosting trie and the greedy match bookkeeping with rollback. The
decoder loops that use it live in the two reference scripts.
"""
import numpy as np

WORD_START = "▁"
MAX_PHRASES = 1000
MAX_PHRASE_TOKENS = 32
MAX_PHRASE_CODE_POINTS = 512
DEFAULT_SCORE = 2.0
MIN_SCORE, MAX_SCORE = 0.5, 5.0


def is_control_piece(piece):
    return len(piece) >= 2 and piece[0] == "<" and piece[-1] == ">"


def clamp_score(score):
    return min(MAX_SCORE, max(MIN_SCORE, float(score)))


def normalize(phrase):
    """Whitespace runs -> U+2581, a leading U+2581, no case folding."""
    words = phrase.split()
    return WORD_START + WORD_START.join(words) if words else ""


def is_boundary(piece):
    """boundary(token): starts with U+2581 or the first code point is not a letter/digit."""
    return piece.startswith(WORD_START) or not piece[:1].isalnum()


def too_long(text):
    return len(text) > MAX_PHRASE_CODE_POINTS + 1


class BpeTokenizer:
    """SentencePiece BPE from the vocabulary order alone: merge the adjacent
    pair whose concatenation is a vocabulary piece with the lowest id."""

    def __init__(self, pieces):
        self.ids = {}
        for idx in sorted(pieces):
            if not is_control_piece(pieces[idx]):
                self.ids[pieces[idx]] = idx

    def encode(self, phrase):
        text = normalize(phrase)
        if not text or too_long(text) or any(ch not in self.ids for ch in text):
            return None
        symbols = list(text)
        while len(symbols) > 1:
            candidates = [(self.ids[a + b], i) for i, (a, b) in enumerate(zip(symbols, symbols[1:]))
                          if a + b in self.ids]
            if not candidates:
                break
            _, i = min(candidates)
            symbols[i:i + 2] = [symbols[i] + symbols[i + 1]]
        return [self.ids[s] for s in symbols]


class UnigramTokenizer:
    """SentencePiece unigram: Viterbi segmentation maximising the summed
    piece scores, read from a tsv in vocabulary order."""

    def __init__(self, tsv_path, pieces):
        self.pieces = {}
        with open(tsv_path, encoding="utf-8") as f:
            rows = [line.rstrip("\r\n").split("\t") for line in f if line.rstrip("\r\n")]
        for idx, (piece, score) in enumerate(rows):
            if pieces.get(idx) != piece:
                raise ValueError(f"tokenizer piece {idx} {piece!r} != vocabulary {pieces.get(idx)!r}")
            if not is_control_piece(piece):
                self.pieces[piece] = (float(score), idx)
        self.max_len = max(len(p) for p in self.pieces)

    def encode(self, phrase):
        text = normalize(phrase)
        n = len(text)
        if not text or too_long(text):
            return None
        score = [None] * (n + 1)
        back = [0] * (n + 1)
        score[0] = 0.0
        for end in range(1, n + 1):
            for start in range(max(0, end - self.max_len), end):
                entry = self.pieces.get(text[start:end])
                if entry is None or score[start] is None:
                    continue
                total = score[start] + entry[0]
                # Ties keep the earliest start, as a forward Viterbi pass would.
                if score[end] is None or total > score[end]:
                    score[end], back[end] = total, start
        if score[n] is None:
            return None
        out, end = [], n
        while end > 0:
            start = back[end]
            out.append(self.pieces[text[start:end]][1])
            end = start
        return out[::-1]


class TrieNode:
    __slots__ = ("children", "score", "end")

    def __init__(self, score=0.0):
        self.children, self.score, self.end = {}, score, False


def compile_hotwords(phrases, score, tokenizer):
    """-> (root, used, skipped). Exact duplicates merge; untokenizable, over
    32-token and past-1000 phrases are skipped."""
    root, used, skipped, seen = TrieNode(), 0, [], set()
    for phrase in phrases:
        if phrase in seen:
            continue
        seen.add(phrase)
        ids = tokenizer.encode(phrase) if used < MAX_PHRASES else None
        if not ids or len(ids) > MAX_PHRASE_TOKENS:
            skipped.append(phrase)
            continue
        node = root
        for tok in ids:
            child = node.children.get(tok)
            if child is None:
                child = node.children[tok] = TrieNode(score)
            child.score = max(child.score, score)
            node = child
        node.end = True
        used += 1
    return root, used, skipped


def load_phrases(path):
    with open(path, encoding="utf-8") as f:
        return [line.rstrip("\r\n") for line in f if line.strip()]


class Biasing:
    """Match state of spec §4.3. The decoder keeps its own snapshot; this
    class says when to take it (accept -> "snapshot") or restore it."""

    def __init__(self, root):
        self.root = root
        self.node = root
        self.pending = False
        self.matching = False  # a snapshot is held for the current match
        self.suppress = None

    def boost(self, logits, t, count):
        """log_softmax(logits) (float64) plus the boost of the current node's children."""
        z = logits.astype(np.float64)
        top = z.max()
        lp = z - (top + np.log(np.exp(z - top).sum()))
        if self.node is not self.root or self.suppress != (t, count):
            for tok, child in self.node.children.items():
                lp[tok] += child.score
        return lp

    def on_token(self, piece, tok, t, count):
        """-> "accept", "snapshot" (save state, then accept) or "rollback"."""
        if self.pending and tok not in self.node.children:
            if not is_boundary(piece):
                return "rollback"
            self.node, self.pending, self.matching = self.root, False, False
        at_suppressed_root = self.node is self.root and self.suppress == (t, count)
        if tok in self.node.children and not at_suppressed_root:
            starting = self.node is self.root
            self.node = self.node.children[tok]
            self.pending = self.node.end
            if starting:
                self.matching = True
                return "snapshot"
            return "accept"
        return "rollback" if self.node is not self.root else "accept"

    def at_end(self):
        """True when an unfinished match must be rolled back at the end."""
        if self.pending:
            self.pending, self.matching = False, False
        return self.matching

    def rolled_back(self, t, count):
        self.node, self.pending, self.matching, self.suppress = self.root, False, False, (t, count)
