#!/usr/bin/env python3
"""Reference implementation of the nemo_tdt family (development only).

Independent Python/numpy twin of src/families/nemo_tdt.cpp, used to write
the golden transcripts that tests/model_tests.cpp compares against exactly
(spec §2.4, §11.2). Never shipped; the app has no Python dependency.

Requires onnxruntime==1.23.2 (the same version as the native SDK), numpy,
and soundfile (without it, 16-bit PCM WAVs are read with the wave module).

    reference_tdt.py [--hotwords <file> [--hotwords-score x]] <model_dir> <assets_dir> <out_dir> file.wav...
writes <out_dir>/<name>.txt and <name>.tokens.json ({"frame_sec", "tokens":
[[id, frame, conf]]}) for each input. With --hotwords (one phrase per line;
docs/specs/asr-hotwords-spec.md §4-§5, tools/reference_hotwords.py) it
decodes with the phrases boosted (default score 2.0) and writes
<name>.hw.txt and <name>.hw.tokens.json instead.
"""
import json
import os
import sys

import numpy as np
import onnxruntime as ort

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import reference_hotwords as hw  # noqa: E402


def read_audio(path):
    """-> (mono float32 samples, rate). soundfile when available, else 16-bit PCM via wave."""
    try:
        import soundfile as sf
    except ImportError:
        import wave
        with wave.open(path, "rb") as w:
            if w.getsampwidth() != 2 or w.getcomptype() != "NONE":
                sys.exit(f"{path}: only 16-bit PCM WAV can be read without soundfile")
            data = np.frombuffer(w.readframes(w.getnframes()), "<i2").astype(np.float32) / 32768.0
            return data.reshape(-1, w.getnchannels()).mean(axis=1), w.getframerate()
    audio, rate = sf.read(path, dtype="float32", always_2d=True)
    return audio.mean(axis=1), rate


def take_option(argv, name):
    if name not in argv:
        return None
    i = argv.index(name)
    if i + 1 >= len(argv):
        sys.exit(f"missing value for {name}")
    value = argv[i + 1]
    del argv[i:i + 2]
    return value


def main():
    argv = sys.argv[1:]
    hotwords_file = take_option(argv, "--hotwords")
    hotwords_score = take_option(argv, "--hotwords-score")
    if len(argv) < 4:
        sys.exit(__doc__)
    model_dir, assets_dir, out_dir, wavs = argv[0], argv[1], argv[2], argv[3:]
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

    frame_sec = p["hop_seconds"] * p["subsampling_factor"]
    root = None
    if hotwords_file is not None:
        score = hw.clamp_score(hotwords_score if hotwords_score is not None else hw.DEFAULT_SCORE)
        root, used, skipped = hw.compile_hotwords(hw.load_phrases(hotwords_file), score, hw.BpeTokenizer(pieces))
        print(f"# hotwords: {used} used, score {score}, skipped {skipped}")

    def softmax_prob(token_logits, token):
        z = token_logits.astype(np.float64) - float(token_logits.max())
        return float(np.exp(z[token]) / np.exp(z).sum())

    def transcribe(x):
        if len(x) < 4000:
            x = np.pad(x, (0, 4000 - len(x)))
        x = np.clip(np.nan_to_num(x, nan=0.0, posinf=0.0, neginf=0.0), -1.0, 1.0).astype(np.float32)
        feats, flen = pre.run(None, {"waveforms": x[None], "waveforms_lens": np.array([len(x)], np.int64)})
        # Full frame count, not flen (see nemo_tdt.cpp: the int8 encoder
        # returns all-NaN when the length leaves a padded encoder frame).
        out, olen = enc.run(None, {"audio_signal": feats, "length": np.array([feats.shape[2]], np.int64)})
        frames = min(int(olen[0]), out.shape[2])
        e = out[0]
        h = np.zeros((layers, 1, hidden), np.float32)
        c = np.zeros_like(h)
        d, h2, c2 = run_decoder(blank, h, c)
        tokens, t, emitted = [], 0, 0
        if root is not None:
            return decode_biased(e, frames, h, c, d, h2, c2)
        while t < frames:
            logits = joi.run(None, {"encoder_out": e[None, :, t:t + 1], "decoder_out": d})[0].reshape(-1)
            token = int(logits[:vocab].argmax())
            skip = durations[int(logits[vocab:].argmax())]
            if token != blank:
                piece = pieces[token]
                if not (len(piece) >= 2 and piece[0] == "<" and piece[-1] == ">"):
                    tokens.append([token, t, softmax_prob(logits[:vocab], token)])
                h, c = h2, c2
                d, h2, c2 = run_decoder(token, h, c)
                emitted += 1
            if skip > 0:
                t += skip
                emitted = 0
            elif token == blank or emitted >= max_symbols:
                t += 1
                emitted = 0
        return text_of(tokens), tokens

    def text_of(tokens):
        return "".join(pieces[i] for i, _, _ in tokens).replace("▁", " ").strip(" ")

    def decode_biased(e, frames, h, c, d, h2, c2):
        """Greedy TDT with hotword boosting and rollback (spec §4.2-§4.3)."""
        bias = hw.Biasing(root)
        tokens, t, emitted, saved = [], 0, 0, None
        while True:
            if t >= frames:
                if not bias.at_end():
                    break
                t, emitted, h, c, d, h2, c2, n = saved
                del tokens[n:]
                bias.rolled_back(t, n)
                continue
            logits = joi.run(None, {"encoder_out": e[None, :, t:t + 1], "decoder_out": d})[0].reshape(-1)
            token = int(bias.boost(logits[:vocab], t, len(tokens)).argmax())
            skip = durations[int(logits[vocab:].argmax())]
            if token != blank:
                piece = pieces[token]
                action = bias.on_token(piece, token, t, len(tokens))
                if action == "rollback":
                    t, emitted, h, c, d, h2, c2, n = saved
                    del tokens[n:]
                    bias.rolled_back(t, n)
                    continue
                if action == "snapshot":
                    saved = (t, emitted, h, c, d, h2, c2, len(tokens))
                if not (len(piece) >= 2 and piece[0] == "<" and piece[-1] == ">"):
                    tokens.append([token, t, softmax_prob(logits[:vocab], token)])
                h, c = h2, c2
                d, h2, c2 = run_decoder(token, h, c)
                emitted += 1
            if skip > 0:
                t += skip
                emitted = 0
            elif token == blank or emitted >= max_symbols:
                t += 1
                emitted = 0
        return text_of(tokens), tokens

    os.makedirs(out_dir, exist_ok=True)
    suffix = ".hw" if root is not None else ""
    for wav in wavs:
        audio, rate = read_audio(wav)
        if rate != 16000:
            sys.exit(f"{wav}: {rate} Hz, need 16000")
        text, tokens = transcribe(audio)
        name = os.path.splitext(os.path.basename(wav))[0]
        with open(os.path.join(out_dir, name + suffix + ".txt"), "w", encoding="utf-8") as f:
            f.write(text + "\n")
        with open(os.path.join(out_dir, name + suffix + ".tokens.json"), "w", encoding="utf-8") as f:
            json.dump({"frame_sec": frame_sec, "tokens": tokens}, f)
            f.write("\n")
        print(f"{name}: {text}")


if __name__ == "__main__":
    main()
