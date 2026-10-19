#!/usr/bin/env python3
"""Reference implementation of the gigaam_rnnt family (development only).

Independent Python/numpy twin of src/families/gigaam_rnnt.cpp, mirroring
onnx-asr 0.12.0 (`GigaamV3E2eRnnt` + `_AsrWithTransducerDecoding`). It writes
the golden transcripts that tests/model_tests.cpp compares against exactly
(spec §2.4, §11.2). Never shipped; the app has no Python dependency.

Requires onnxruntime==1.23.2 (the same version as the native SDK), numpy,
soundfile; `--check-onnx-asr` additionally needs onnx-asr==0.12.0.

    reference_gigaam.py [--check-onnx-asr] <model_dir> <assets_dir> <out_dir> file.wav...

writes, for each input, <out_dir>/<name>.txt (the text) and
<out_dir>/<name>.tokens.json ({"frame_sec", "tokens": [[id, frame, conf]]}).
`--check-onnx-asr` also transcribes each file with onnx-asr itself (CPU, the
same gigaam_v3.onnx preprocessor graph) and fails unless the texts match.
"""
import json
import os
import re
import sys

import numpy as np
import onnxruntime as ort
import soundfile as sf

# onnx-asr's _AsrWithDecoding.DECODE_SPACE_PATTERN: drop a leading space and
# any space not followed by a word character; keep a space before a word.
DECODE_SPACE_PATTERN = re.compile(r"\A\s|\s\B|(\s)\b")
MIN_SAMPLES = 4000  # kMinAudioSeconds (0.25 s) at 16 kHz, as src/audio.cpp pads


def is_control_piece(piece):
    return len(piece) >= 2 and piece[0] == "<" and piece[-1] == ">"


def main():
    argv = sys.argv[1:]
    check = "--check-onnx-asr" in argv
    argv = [a for a in argv if a != "--check-onnx-asr"]
    if len(argv) < 4:
        sys.exit(__doc__)
    model_dir, assets_dir, out_dir, wavs = argv[0], argv[1], argv[2], argv[3:]
    if ort.__version__ != "1.23.2":
        sys.exit(f"onnxruntime {ort.__version__} found; goldens must be made with 1.23.2")

    with open(os.path.join(model_dir, "manifest.json"), encoding="utf-8") as f:
        manifest = json.load(f)
    if manifest["family"] != "gigaam_rnnt":
        sys.exit(f"family {manifest['family']!r} is not gigaam_rnnt")
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
    max_symbols, hidden = p["max_symbols_per_frame"], p["pred_hidden"]
    frame_sec = p["hop_seconds"] * p["subsampling_factor"]

    def run_decoder(token, h, c):
        out, h2, c2 = dec.run(["dec", "h", "c"], {"x": np.array([[token]], np.int64), "h.1": h, "c.1": c})
        return out.transpose(0, 2, 1), h2, c2  # dec [1,1,H] -> joint input [1,H,1]

    def transcribe(x):
        if len(x) < MIN_SAMPLES:
            x = np.pad(x, (0, MIN_SAMPLES - len(x)))
        x = np.clip(np.nan_to_num(x, nan=0.0, posinf=0.0, neginf=0.0), -1.0, 1.0).astype(np.float32)
        feats, flen = pre.run(None, {"waveforms": x[None], "waveforms_lens": np.array([len(x)], np.int64)})
        out, olen = enc.run(["encoded", "encoded_len"], {"audio_signal": feats, "length": flen})
        frames = min(int(olen[0]), out.shape[2])
        e = out[0]
        if not np.isfinite(e[:, :frames]).all():
            sys.exit("encoder returned non-finite values")
        h = np.zeros((1, 1, hidden), np.float32)
        c = np.zeros_like(h)
        # Decoder output for (last emitted token or blank, state); recomputed
        # only after an emission, exactly like onnx-asr's cached state.
        d, h2, c2 = run_decoder(blank, h, c)
        tokens, t, emitted = [], 0, 0
        while t < frames:
            logits = joi.run(["joint"], {"enc": e[None, :, t:t + 1], "dec": d})[0].reshape(-1)
            token = int(logits.argmax())
            if token != blank:
                if not is_control_piece(pieces[token]):
                    z = logits.astype(np.float64) - float(logits.max())
                    conf = float(np.exp(z[token]) / np.exp(z).sum())
                    tokens.append([token, t, conf])
                h, c = h2, c2
                d, h2, c2 = run_decoder(token, h, c)
                emitted += 1
            if token == blank or emitted == max_symbols:
                t += 1
                emitted = 0
        text = "".join(pieces[i] for i, _, _ in tokens).replace("▁", " ")
        text = DECODE_SPACE_PATTERN.sub(lambda m: " " if m.group(1) else "", text)
        return text, tokens

    asr = None
    if check:
        import onnx_asr

        asr = onnx_asr.load_model("gigaam-v3-e2e-rnnt", model_dir, quantization="int8",
                                  providers=["CPUExecutionProvider"],
                                  preprocessor_config={"use_numpy_preprocessors": False,
                                                       "use_conv_preprocessors": False,
                                                       "providers": ["CPUExecutionProvider"]})

    os.makedirs(out_dir, exist_ok=True)
    mismatches = 0
    for wav in wavs:
        audio, rate = sf.read(wav, dtype="float32", always_2d=True)
        if rate != 16000:
            sys.exit(f"{wav}: {rate} Hz, need 16000")
        mono = audio.mean(axis=1)
        text, tokens = transcribe(mono)
        name = os.path.splitext(os.path.basename(wav))[0]
        with open(os.path.join(out_dir, name + ".txt"), "w", encoding="utf-8") as f:
            f.write(text + "\n")
        with open(os.path.join(out_dir, name + ".tokens.json"), "w", encoding="utf-8") as f:
            json.dump({"frame_sec": frame_sec, "tokens": tokens}, f)
            f.write("\n")
        print(f"{name}: {text}")
        if asr is not None:
            theirs = asr.recognize(mono, sample_rate=16000)
            if theirs != text:
                mismatches += 1
                print(f"  onnx-asr differs: {theirs}")
            else:
                print("  onnx-asr: identical")
    if mismatches:
        sys.exit(f"{mismatches} file(s) differ from onnx-asr")


if __name__ == "__main__":
    main()
