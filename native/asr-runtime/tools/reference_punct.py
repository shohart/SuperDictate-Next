#!/usr/bin/env python3
"""Reference for the modernbert_punct family -> golden JSONL (dev only).

Tokenizes with Hugging Face `tokenizers`, runs the model with ONNX Runtime,
and merges the labels with the same policy as src/families/punct_text.cpp.
The C++ family must reproduce every line exactly (tests/punct_tests.cpp).

    venv: onnxruntime==1.23.2 numpy tokenizers
    python3 reference_punct.py <installed model dir> <cases.txt> > golden.jsonl

Each output line: {"text": input, "ids": [[ids of word 1], ...], "output": text}.
"""
import json
import sys

import numpy as np
import onnxruntime as ort
from tokenizers import Tokenizer

ELLIPSIS, EN_DASH, EM_DASH = "…", "–", "—"
END_MARKS = ".,?:;!"


def is_dash_token(token):
    return bool(token) and all(c in "-" + EN_DASH + EM_DASH for c in token)


def strip_trailing_marks(core):
    end = ""
    while core and (core[-1] in END_MARKS or core[-1] == ELLIPSIS):
        end = core[-1] + end
        core = core[:-1]
    return core, end


def has_sentence_end(marks):
    return any(c in ".!?" + ELLIPSIS for c in marks)


def upper(ch):
    cp = ord(ch)
    if (ord("a") <= cp <= ord("z") or (0xE0 <= cp <= 0xFE and cp != 0xF7)
            or (0x3B1 <= cp <= 0x3C9 and cp != 0x3C2) or 0x430 <= cp <= 0x44F):
        return chr(cp - 0x20)
    if 0x450 <= cp <= 0x45F:
        return chr(cp - 0x50)
    return ch


def capitalize_first_letter(word):
    for i, ch in enumerate(word):
        if ch.isalnum() or ch == "_":
            return word[:i] + upper(ch) + word[i + 1:]
    return word


def split_words(text):
    words = []  # [core, end, dash]
    for token in text.split():
        if is_dash_token(token):
            if words and not words[-1][2]:
                words[-1][2] = token
            continue
        core, end = strip_trailing_marks(token)
        if not core:
            if words:
                words[-1][1] += end
            continue
        words.append([core, end, ""])
    return words


def merge(words, labels):
    joined = " ".join(w[0] for w in words)
    new_dash = EM_DASH if any(0x400 <= ord(c) <= 0x4FF for c in joined) else "-"
    out, capitalize_next = [], False
    for (core, end, dash), label in zip(words, labels):
        mark, new_end = "", False
        if has_sentence_end(end):
            mark = "?" if end == "." and label == "?" else end
            new_end = label in (".", "?")
        elif ";" in end or dash:
            mark = end
        elif label in (".", "?"):
            mark, new_end = label, True
        elif label in (",", ":"):
            mark = label
        elif label == "-" and not dash:
            dash = new_dash
        piece = (capitalize_first_letter(core) if capitalize_next else core) + mark
        if dash:
            piece += " " + dash
        out.append(piece)
        capitalize_next = new_end
    return " ".join(out)


def main():
    model_dir, cases = sys.argv[1], sys.argv[2]
    manifest = json.load(open(f"{model_dir}/manifest.json", encoding="utf-8"))
    params = manifest["params"]
    tok = Tokenizer.from_file(f"{model_dir}/{manifest['files']['tokenizer']['path']}")
    options = ort.SessionOptions()
    options.intra_op_num_threads = 1
    session = ort.InferenceSession(f"{model_dir}/{manifest['files']['model']['path']}", options)
    chunk, overlap = params["chunk_tokens"], params["overlap_tokens"]

    for line in open(cases, encoding="utf-8"):
        text = line.rstrip("\n")
        if not text or text.startswith("#"):
            continue
        words = split_words(text)
        if not words:
            print(json.dumps({"text": text, "ids": [], "output": text}, ensure_ascii=False))
            continue
        word_ids = [tok.encode(w[0], add_special_tokens=False).ids for w in words]
        ids, last = [], []
        for piece in word_ids:
            ids += piece
            last.append(len(ids) - 1)
        token_labels = [0] * len(ids)
        start = 0
        while True:
            end = min(len(ids), start + chunk)
            x = np.array([[params["cls_id"]] + ids[start:end] + [params["sep_id"]]], dtype=np.int64)
            logits = session.run(["logits"], {"input_ids": x, "attention_mask": np.ones_like(x)})[0][0]
            keep_to = end if end == len(ids) else end - overlap
            for k in range(start, keep_to):
                token_labels[k] = int(logits[k - start + 1].argmax())
            if end == len(ids):
                break
            start = end - overlap
        labels = [params["labels"][token_labels[i]] for i in last]
        print(json.dumps({"text": text, "ids": word_ids, "output": merge(words, labels)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
