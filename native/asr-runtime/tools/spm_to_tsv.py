#!/usr/bin/env python3
"""Convert a SentencePiece tokenizer.model to the hotword tokenizer asset.

Development tool (spec docs/specs/asr-hotwords-spec.md §5). Writes one line
"<piece>\\t<score>" per piece, in the model's own vocabulary order, so the
native unigram encoder (src/families/hotwords.cpp) needs no protobuf parser.
The scores are the float32 values stored in the model, written with Python's
shortest round-trip repr, so every reader parses the same doubles.

    spm_to_tsv.py <tokenizer.model> <vocab.txt> <out.tsv>

<vocab.txt> is the model's "<piece> <id>" vocabulary (the manifest "tokens"
file); the script refuses to write unless piece i of the tokenizer is the
vocabulary's piece i for every tokenizer piece.

The bundled assets/gigaam_v3_spm.tsv comes from
ai-sage/GigaAM-v3@7655ad717f8122257385bb4b2f373db3697e8680/tokenizer.model
(sha256 828c12c991019eef952a960661f25a92d6ad279591e2ea466b4aeddf1d20a18a, MIT).
"""
import struct
import sys


def varint(data, i):
    result = shift = 0
    while True:
        byte = data[i]
        i += 1
        result |= (byte & 0x7F) << shift
        shift += 7
        if byte < 0x80:
            return result, i


def fields(data):
    """Yields (field number, wire type, value) of one protobuf message."""
    i = 0
    while i < len(data):
        key, i = varint(data, i)
        number, wire = key >> 3, key & 7
        if wire == 0:
            value, i = varint(data, i)
        elif wire == 2:
            length, i = varint(data, i)
            value = data[i:i + length]
            i += length
        elif wire == 5:
            value = data[i:i + 4]
            i += 4
        elif wire == 1:
            value = data[i:i + 8]
            i += 8
        else:
            raise ValueError(f"unsupported protobuf wire type {wire}")
        yield number, wire, value


def read_pieces(path):
    """ModelProto.pieces (field 1): SentencePiece {piece=1, score=2, type=3}."""
    with open(path, "rb") as f:
        data = f.read()
    pieces = []
    model_type = None
    for number, _, value in fields(data):
        if number == 1:
            p = {n: v for n, _, v in fields(value)}
            score = struct.unpack("<f", p.get(2, b"\0\0\0\0"))[0]
            pieces.append((p[1].decode("utf-8"), score, p.get(3, 1)))
        elif number == 2:
            trainer = {n: v for n, _, v in fields(value)}
            model_type = trainer.get(3, 1)  # TrainerSpec.model_type: 1 = UNIGRAM
    return pieces, model_type


def read_vocab(path):
    vocab = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\r\n")
            if line:
                piece, idx = line.rsplit(" ", 1)
                vocab[int(idx)] = piece
    return vocab


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    model_path, vocab_path, out_path = sys.argv[1:]
    pieces, model_type = read_pieces(model_path)
    if model_type != 1:
        sys.exit(f"tokenizer model_type {model_type} is not UNIGRAM (1)")
    vocab = read_vocab(vocab_path)
    for i, (piece, _, _) in enumerate(pieces):
        if vocab.get(i) != piece:
            sys.exit(f"piece {i} {piece!r} != vocabulary piece {vocab.get(i)!r}")
        if "\t" in piece or "\n" in piece or "\r" in piece:
            sys.exit(f"piece {i} {piece!r} contains a tab or newline")
    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        for piece, score, _ in pieces:
            f.write(f"{piece}\t{score!r}\n")
    print(f"{out_path}: {len(pieces)} pieces (vocabulary has {len(vocab)} entries)")


if __name__ == "__main__":
    main()
