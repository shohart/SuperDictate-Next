#!/usr/bin/env python3
"""Reference implementation of the nemo_tdt family (development only).

Independent Python/numpy twin of src/families/nemo_tdt.cpp, used to write
the golden transcripts that tests/model_tests.cpp compares against exactly
(spec §2.4, §11.2). Never shipped; the app has no Python dependency.

Requires onnxruntime==1.23.2 (the same version as the native SDK), numpy,
soundfile.

    reference_tdt.py <model_dir> <assets_dir> <out_dir> file.wav...
writes <out_dir>/<name>.txt for each input (and copies nothing else).
"""
import json
import os
import sys

import numpy as np
import onnxruntime as ort
import soundfile as sf


def main():
    if len(sys.argv) < 5:
        sys.exit(__doc__)
    model_dir, assets_dir, out_dir, wavs = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
    if ort.__version__ != "1.23.2":
        sys.exit(f"onnxruntime {ort.__version__} found; goldens must be made with 1.23.2")

    with open(os.path.join(model_dir, "manifest.json"), encoding="utf-8") as f:
        manifest = json.load(f)
    p = manifest["params"]
    files = manifest["files"]

    def path(role):
        spec = files[role]
        return os.path.join(assets_dir, spec["bundled"]) if "bundled" in spec else os.path.join(model_dir, spec["path"])

    options = ort.SessionOptions()
    options.intra_op_num_threads = 4
    session = lambda role: ort.InferenceSession(path(role), options, providers=["CPUExecutionProvider"])
    pre, enc, dec, joi = session("preprocessor"), session("encoder"), session("decoder"), session("joiner")

    pieces = {}
    with open(path("tokens"), encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\r\n")
            if line:
                token, idx = line.rsplit(" ", 1)
                pieces[int(idx)] = token

    vocab, blank = p["vocab_size"], p["blank_id"]
    durations, max_symbols = p["durations"], p["max_symbols_per_frame"]
    layers, hidden = p["pred_rnn_layers"], p["pred_hidden"]

    def run_decoder(token, h, c):
        out, _, h2, c2 = dec.run(None, {"targets": np.array([[token]], np.int32),
                                        "target_lengths": np.array([1], np.int32), "h": h, "c": c})
        return out, h2, c2

    def transcribe(x):
        if len(x) < 4000:
            x = np.pad(x, (0, 4000 - len(x)))
        x = np.clip(np.nan_to_num(x, nan=0.0, posinf=0.0, neginf=0.0), -1.0, 1.0).astype(np.float32)
        feats, flen = pre.run(None, {"waveforms": x[None], "waveforms_lens": np.array([len(x)], np.int64)})
        out, olen = enc.run(None, {"audio_signal": feats, "length": flen})
        frames = min(int(olen[0]), out.shape[2])
        e = out[0]
        h = np.zeros((layers, 1, hidden), np.float32)
        c = np.zeros_like(h)
        d, h2, c2 = run_decoder(blank, h, c)
        tokens, t, emitted = [], 0, 0
        while t < frames:
            logits = joi.run(None, {"encoder_out": e[None, :, t:t + 1], "decoder_out": d})[0].reshape(-1)
            token = int(logits[:vocab].argmax())
            skip = durations[int(logits[vocab:].argmax())]
            if token != blank:
                piece = pieces[token]
                if not (len(piece) >= 2 and piece[0] == "<" and piece[-1] == ">"):
                    tokens.append(token)
                h, c = h2, c2
                d, h2, c2 = run_decoder(token, h, c)
                emitted += 1
            if skip > 0:
                t += skip
                emitted = 0
            elif token == blank or emitted >= max_symbols:
                t += 1
                emitted = 0
        return "".join(pieces[i] for i in tokens).replace("▁", " ").strip(" ")

    os.makedirs(out_dir, exist_ok=True)
    for wav in wavs:
        audio, rate = sf.read(wav, dtype="float32", always_2d=True)
        if rate != 16000:
            sys.exit(f"{wav}: {rate} Hz, need 16000")
        text = transcribe(audio.mean(axis=1))
        name = os.path.splitext(os.path.basename(wav))[0]
        with open(os.path.join(out_dir, name + ".txt"), "w", encoding="utf-8") as f:
            f.write(text + "\n")
        print(f"{name}: {text}")


if __name__ == "__main__":
    main()
