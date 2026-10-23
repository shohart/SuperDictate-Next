"""Speech recognition on the Intel NPU, through OpenVINO.

The NPU models are OpenVINO IR, not ONNX, so ``SuperDictateOnnxHost``
cannot load them; this module is their counterpart of
``native/asr-runtime/src/families``. It runs only inside
``SuperDictateOvHost`` (:mod:`superdictate.openvino_host`), never in the app
process, for the same reason the ONNX runtime lives in a helper: graph
compilation is seconds to minutes of native work the panel must not wait on.

Two families, decoded exactly like their ONNX twins:

* **Parakeet TDT 0.6B v3** (``nemo_tdt``, FluidInference OpenVINO layout):
  a static 15 s log-mel graph, the encoder on the NPU, the LSTM prediction
  net and the joint on the CPU, greedy TDT decoding.
* **GigaAM v3 e2e RNN-T** (``gigaam_rnnt``): log-mel features matching the
  bundled ``gigaam_v3.onnx`` graph, the NPU-calibrated static 30 s encoder,
  greedy RNN-T decoding.

The NPU compiles only static shapes, so each model sees fixed windows. A
recording longer than one window is cut into windows that overlap (3 s for
Parakeet, 4 s for GigaAM); the cut sits in the middle of each overlap and
:func:`stitch` joins the words across it. The app's own segmentation keeps
most requests inside one window.
"""

from __future__ import annotations

import json
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional, Sequence

import numpy as np

SAMPLE_RATE = 16000
WORD_START = "▁"

#: NPU compiler properties from the GigaAM NPU model card: they cut its first
#: compile from ~90 to ~3.5 minutes with no effect on the weights. Each one is
#: set on its own and a rejected one is skipped, so older plugins still load.
_NPU_PROPERTIES = {
    "PERFORMANCE_HINT": "LATENCY",
    "MODEL_PRIORITY": "HIGH",
    "NPU_TURBO": "YES",
    "COMPILATION_NUM_THREADS": 8,
}
#: Compile with the NPU compiler that ships inside the OpenVINO wheel, not
#: the one inside the graphics driver. On driver 32.0.100.3159 (Core Ultra 5
#: 225H, October 2026) the driver's compiler rejects GigaAM's hybrid
#: INT8/FP16 encoder ("ConvertLayers2VPU Pass failed") and takes the whole
#: process down — no exception — when asked for the QDQ optimisation; the
#: bundled one compiles both models, GigaAM in ~4 minutes. It also means
#: the result depends on the OpenVINO version we pin, not on whatever driver
#: the user happens to have.
_NPU_PLUGIN_COMPILER = {"NPU_COMPILER_TYPE": "PLUGIN", "NPU_QDQ_OPTIMIZATION_AGGRESSIVE": "YES"}


class OvAsrError(RuntimeError):
    category = "inference_failed"


class InvalidModel(OvAsrError):
    category = "invalid_model"


class Cancelled(OvAsrError):
    category = "cancelled"


@dataclass(frozen=True)
class Token:
    id: int
    t: float            # seconds from the start of the audio
    conf: float


@dataclass
class Word:
    w: str
    start: float
    end: float
    conf: float


@dataclass
class Transcript:
    text: str
    words: list[Word]


# -- devices --------------------------------------------------------------

def _core(cache_directory: Optional[Path]):
    import openvino as ov

    core = ov.Core()
    if cache_directory is not None:
        cache_directory.mkdir(parents=True, exist_ok=True)
        core.set_property({"CACHE_DIR": str(cache_directory)})
    return core


def available_devices() -> list[str]:
    import openvino as ov

    return list(ov.Core().available_devices)


def npu_name() -> Optional[str]:
    """The NPU's marketing name, or ``None`` when OpenVINO sees no NPU."""
    import openvino as ov

    core = ov.Core()
    if "NPU" not in core.available_devices:
        return None
    try:
        return str(core.get_property("NPU", "FULL_DEVICE_NAME"))
    except Exception:
        return "NPU"


def npu_driver_build(core) -> int:
    """The last field of the NPU driver version (3159 for 32.0.100.3159), or 0."""
    try:
        return int(core.get_property("NPU", "NPU_DRIVER_VERSION"))
    except Exception:
        return 0


def _configure_npu(core) -> None:
    try:
        # Both or neither: the QDQ option is only safe with this compiler.
        core.set_property("NPU", dict(_NPU_PLUGIN_COMPILER))
    except Exception:
        pass  # a plugin without its own compiler: the driver's, plain options
    for key, value in _NPU_PROPERTIES.items():
        try:
            core.set_property("NPU", {key: value})
        except Exception:
            pass  # not supported by this plugin or driver


# -- tokens ---------------------------------------------------------------

def _varint(data: bytes, index: int) -> tuple[int, int]:
    value, shift = 0, 0
    while True:
        byte = data[index]
        index += 1
        value |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return value, index
        shift += 7


def sentencepiece_pieces(path: Path) -> list[str]:
    """Piece strings of a SentencePiece ``ModelProto``, in id order.

    Field 1 of the model is the repeated ``SentencePiece``; field 1 of that
    is the piece. Reading the two fields by hand spares the app a protobuf
    or sentencepiece dependency for one list of strings.
    """
    data = path.read_bytes()
    pieces: list[str] = []
    index = 0
    while index < len(data):
        key, index = _varint(data, index)
        field, wire = key >> 3, key & 7
        if wire == 0:
            _, index = _varint(data, index)
        elif wire == 1:
            index += 8
        elif wire == 5:
            index += 4
        elif wire == 2:
            length, index = _varint(data, index)
            body = data[index:index + length]
            index += length
            if field == 1:
                pieces.append(_first_string_field(body))
        else:
            raise InvalidModel(f"{path.name}: unsupported protobuf wire type {wire}")
    if not pieces:
        raise InvalidModel(f"{path.name}: no pieces")
    return pieces


def _first_string_field(message: bytes) -> str:
    index = 0
    while index < len(message):
        key, index = _varint(message, index)
        field, wire = key >> 3, key & 7
        if wire == 2:
            length, index = _varint(message, index)
            if field == 1:
                return message[index:index + length].decode("utf-8")
            index += length
        elif wire == 0:
            _, index = _varint(message, index)
        elif wire == 1:
            index += 8
        elif wire == 5:
            index += 4
        else:
            break
    raise InvalidModel("SentencePiece entry without a piece")


def is_control_piece(piece: str) -> bool:
    return len(piece) >= 2 and piece[0] == "<" and piece[-1] == ">"


def _softmax_probability(logits: np.ndarray, token: int) -> float:
    shifted = logits.astype(np.float64) - float(logits.max())
    exp = np.exp(shifted)
    return float(exp[token] / exp.sum())


# -- text and words (family_util.cpp) -------------------------------------

def words_word_start_rule(tokens: Sequence[Token], pieces: Sequence[str], frame_sec: float,
                          audio_end: float) -> Transcript:
    """NeMo rule: a piece starting with U+2581 starts a word (nemo_tdt.cpp)."""
    words: list[Word] = []
    text = ""
    for token in tokens:
        piece = pieces[token.id]
        word_start = piece.startswith(WORD_START)
        body = piece[1:] if word_start else piece
        if word_start or not words:
            if words:
                words[-1].end = min(words[-1].end, token.t)
            words.append(Word(body, token.t, token.t + frame_sec, token.conf))
        else:
            word = words[-1]
            word.w += body
            word.end = token.t + frame_sec
            word.conf = min(word.conf, token.conf)
        text += (" " + body) if word_start else body
    if words:
        words[-1].end = min(words[-1].end, audio_end)
    return Transcript(text.strip(" "), [w for w in words if w.w])


def _is_word_char(ch: str) -> bool:
    return ch.isalnum() or ch == "_"


def words_space_rule(tokens: Sequence[Token], pieces: Sequence[str], frame_sec: float,
                     audio_end: float) -> Transcript:
    """onnx-asr GigaAM rule: ``re.sub(r"\\A\\s|\\s\\B|(\\s)\\b", ...)``.

    A space survives only when it is not first and the next character is a
    word character (build_text_and_words_space_rule in family_util.cpp).
    """
    chars: list[tuple[str, int]] = []
    for k, token in enumerate(tokens):
        for ch in pieces[token.id]:
            chars.append((" " if ch == WORD_START else ch, k))

    words: list[Word] = []
    text: list[str] = []
    last_token = -1

    def start_word(k: int) -> None:
        nonlocal last_token
        token = tokens[k]
        if words:
            words[-1].end = min(words[-1].end, token.t)
        words.append(Word("", token.t, token.t + frame_sec, token.conf))
        last_token = k

    for i, (ch, k) in enumerate(chars):
        if ch.isspace():
            kept = i > 0 and i + 1 < len(chars) and _is_word_char(chars[i + 1][0])
            if kept:
                text.append(" ")
                start_word(k)
            continue
        if not words:
            start_word(k)
        word = words[-1]
        if k != last_token:
            token = tokens[k]
            word.end = token.t + frame_sec
            word.conf = min(word.conf, token.conf)
            last_token = k
        word.w += ch
        text.append(ch)
    if words:
        words[-1].end = min(words[-1].end, audio_end)
    return Transcript("".join(text), [w for w in words if w.w])


# -- GigaAM features ------------------------------------------------------
#
# The bundled gigaam_v3.onnx feature graph cannot go through OpenVINO: its
# ONNX frontend converts STFT only with a static signal shape, and the graph
# reshapes its input dynamically. These are the same five ops in numpy:
# periodic Hann, |rfft|^2, the HTK mel matrix torchaudio builds, clamp, log.
# The graph stores that matrix rounded to bfloat16; this one is exact, as in
# GigaAM's own FeatureExtractor, so the two differ by ~0.01 on average, all
# of it in near-silent bins.

_GIGAAM_N_FFT = 320
_GIGAAM_HOP = 160
_GIGAAM_MELS = 64


def _htk_mel_filterbank(n_freqs: int, n_mels: int, sample_rate: int) -> np.ndarray:
    """torchaudio ``melscale_fbanks(norm=None, mel_scale="htk")``, [n_freqs, n_mels]."""
    all_freqs = np.linspace(0, sample_rate // 2, n_freqs)
    to_mel = lambda f: 2595.0 * np.log10(1.0 + f / 700.0)  # noqa: E731
    to_hz = lambda m: 700.0 * (10.0 ** (m / 2595.0) - 1.0)  # noqa: E731
    f_pts = to_hz(np.linspace(to_mel(0.0), to_mel(sample_rate / 2), n_mels + 2))
    f_diff = f_pts[1:] - f_pts[:-1]
    slopes = f_pts[None, :] - all_freqs[:, None]
    down = -slopes[:, :-2] / f_diff[:-1]
    up = slopes[:, 2:] / f_diff[1:]
    return np.maximum(0.0, np.minimum(down, up))


_GIGAAM_WINDOW = (0.5 - 0.5 * np.cos(2 * np.pi * np.arange(_GIGAAM_N_FFT) / _GIGAAM_N_FFT))
_GIGAAM_FBANK = _htk_mel_filterbank(_GIGAAM_N_FFT // 2 + 1, _GIGAAM_MELS, SAMPLE_RATE)


def gigaam_features(samples: np.ndarray) -> tuple[np.ndarray, int]:
    """Log-mel features ``[64, frames]`` and their count (center=False STFT)."""
    if samples.size < _GIGAAM_N_FFT:
        return np.zeros((_GIGAAM_MELS, 0), dtype=np.float32), 0
    frames = (samples.size - _GIGAAM_N_FFT) // _GIGAAM_HOP + 1
    index = np.arange(_GIGAAM_N_FFT)[None, :] + _GIGAAM_HOP * np.arange(frames)[:, None]
    spectrum = np.fft.rfft(samples.astype(np.float64)[index] * _GIGAAM_WINDOW, axis=1)
    power = spectrum.real ** 2 + spectrum.imag ** 2
    mel = np.clip(power @ _GIGAAM_FBANK, 1e-9, 1e9)
    return np.log(mel).T.astype(np.float32), frames


# -- windows --------------------------------------------------------------

def plan_windows(sample_count: int, window: int, overlap: int) -> list[tuple[int, int, float, float]]:
    """``(start, end, keep_from, keep_until)`` sample/second spans.

    Windows advance by ``window - overlap``; the last one is pulled back so it
    ends at the audio's end and stays full. A word belongs to the window whose
    keep span holds its start: the middle of each overlap is the cut.
    """
    if sample_count <= window:
        return [(0, sample_count, float("-inf"), float("inf"))]
    stride = window - overlap
    starts = list(range(0, sample_count - window, stride)) + [sample_count - window]
    spans = []
    for index, start in enumerate(starts):
        end = start + window
        keep_from = float("-inf") if index == 0 else (start + starts[index - 1] + window) / 2 / SAMPLE_RATE
        keep_until = float("inf") if index == len(starts) - 1 else (starts[index + 1] + end) / 2 / SAMPLE_RATE
        spans.append((start, end, keep_from, keep_until))
    return spans


#: How far before its keep span a window may still contribute a word the
#: previous window missed. Less than half of either model's overlap, so a
#: window never reaches back to its own cold start.
_STITCH_REACH_SECONDS = 1.0
#: The same word heard by two windows starts up to a frame or two apart.
_SAME_WORD_SECONDS = 0.5


def stitch(kept: list[Word], words: Sequence[Word], keep_from: float, keep_until: float,
           frame_sec: float) -> list[Word]:
    """Append one window's words to what the earlier windows kept.

    A plain cut at ``keep_from`` loses or doubles the word sitting on it:
    two windows put the same word a frame apart, one on each side of the
    cut (seen on the NPU: 11.20 s in one window, 11.14 s in the next, cut at
    11.19 s). So the words near the cut are judged against the last word the
    earlier windows kept: one before the cut (up to ``_STITCH_REACH_SECONDS``
    before it) is new only if it starts more than two frames after that
    word; one after the cut is dropped only if it is that same word again.
    Words of this window are never compared with each other: two real words
    can start two frames apart.
    """
    out = list(kept)
    prior = kept[-1] if kept else None
    for word in words:
        if word.start >= keep_until or word.start < keep_from - _STITCH_REACH_SECONDS:
            continue
        if prior is not None:
            repeated = word.w == prior.w and word.start <= prior.start + _SAME_WORD_SECONDS
            if repeated or (word.start < keep_from and word.start <= prior.start + 2 * frame_sec):
                continue
        out.append(word)
    return out


# -- families -------------------------------------------------------------

CancelCheck = Callable[[], bool]


#: How long a load waits for the NPU compile before it starts on the CPU and
#: lets the compile finish in the background. A cached blob loads in 1-3 s;
#: a first compile of the GigaAM encoder takes minutes (4-5 on a Core Ultra 5
#: 225H on mains power, longer on battery). Nobody should wait that out, nor
#: lose it to an app restart and start again from zero.
NPU_QUICK_WAIT_SECONDS = 15.0

#: Set by the host to its log: background compile outcomes are reported here.
on_event: Optional[Callable[[str], None]] = None


class _below_normal_priority:
    """This process at BELOW_NORMAL_PRIORITY_CLASS for the duration (Windows)."""

    _BELOW_NORMAL = 0x4000
    _NORMAL = 0x20

    def __enter__(self):
        self._set(self._BELOW_NORMAL)
        return self

    def __exit__(self, *exc) -> None:
        self._set(self._NORMAL)

    @staticmethod
    def _set(priority_class: int) -> None:
        import sys

        if sys.platform != "win32":
            return
        try:
            import ctypes

            kernel32 = ctypes.WinDLL("kernel32")
            kernel32.GetCurrentProcess.restype = ctypes.c_void_p
            kernel32.SetPriorityClass.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
            kernel32.SetPriorityClass(kernel32.GetCurrentProcess(), priority_class)
        except Exception:
            pass  # a priority is an optimisation, never a reason to fail


def _emit(message: str) -> None:
    if on_event is not None:
        try:
            on_event(message)
        except Exception:
            pass


class EncoderSlot:
    """The encoder of one model, on the NPU as soon as it is compiled.

    Everything else (features, prediction net, joint) is small and always
    runs on the CPU. For the encoder an NPU compile starts in the background;
    if it is done within :data:`NPU_QUICK_WAIT_SECONDS` (a cached blob is)
    the model starts on the NPU. Otherwise it starts on the CPU right away,
    same weights, same text, and :meth:`swap` moves it to the NPU between
    two requests once the compile finishes. A compile that fails leaves it
    on the CPU, with the reason in :attr:`npu_error`.
    """

    def __init__(self, path: Path, device: str, cache_directory: Optional[Path],
                 quick_wait: float = NPU_QUICK_WAIT_SECONDS) -> None:
        self.path = path
        self.device = ""
        self.compiled = None
        self.request = None
        self.npu_error = ""
        self._pending = None
        self._lock = threading.Lock()
        self._compiling = threading.Event()
        if not path.is_file():
            raise InvalidModel(f"missing model file {path.name}")
        if device != "NPU":
            self._use(_compile(_core(cache_directory), path, device), device)
            return

        done = threading.Event()
        self._compiling.set()

        def build() -> None:
            started = time.monotonic()
            try:
                core = _core(cache_directory)
                _configure_npu(core)
                # Minutes of compiler threads on every core: below normal,
                # so the rest of the machine (the app's keyboard hook first
                # of all) keeps the CPU it needs. Dictation on the CPU in
                # this process meanwhile is only a few hundred ms a request.
                with _below_normal_priority():
                    compiled = _compile(core, path, "NPU")
                with self._lock:
                    self._pending = compiled
                _emit(f"{path.name}: NPU ready after {time.monotonic() - started:.0f}s")
            except Exception as exc:
                lines = str(exc).strip().splitlines() or [type(exc).__name__]
                self.npu_error = lines[-1][:300]
                _emit(f"{path.name}: NPU compile failed, staying on the CPU: {self.npu_error}")
            finally:
                self._compiling.clear()
                done.set()

        threading.Thread(target=build, name="npu-compile", daemon=True).start()
        if done.wait(quick_wait):
            self.swap()
        if self.device != "NPU":
            if not self.npu_error:
                _emit(f"{path.name}: compiling for the NPU in the background; "
                      f"running on the CPU meanwhile")
            # No CACHE_DIR: the CPU copy is a stopgap, and its blob would be
            # another gigabyte on disk for Parakeet.
            self._use(_compile(_core(None), path, "CPU"), "CPU")

    @property
    def compiling(self) -> bool:
        return self._compiling.is_set()

    def _use(self, compiled, device: str) -> None:
        self.compiled = compiled
        self.request = compiled.create_infer_request()
        self.device = device

    def swap(self) -> bool:
        """Move to the NPU if its compile has finished. Call between requests."""
        with self._lock:
            pending, self._pending = self._pending, None
        if pending is None:
            return False
        self._use(pending, "NPU")
        return True

    @property
    def outputs(self):
        return self.compiled.outputs

    @property
    def inputs(self):
        return self.compiled.inputs


class OvFamily:
    """One loaded model. ``transcribe`` is not reentrant; the host serialises."""

    window_samples: int
    overlap_samples: int
    frame_sec: float
    load_seconds: float = 0.0
    encoder: EncoderSlot

    @property
    def device(self) -> str:
        return self.encoder.device

    @property
    def note(self) -> str:
        """Why the encoder is not (yet) on the NPU it was asked for, or ``""``."""
        if self.encoder.device == "NPU":
            return ""
        if self.encoder.compiling:
            return "NPU: compiling in the background, running on the CPU meanwhile"
        if self.encoder.npu_error:
            return f"NPU: {self.encoder.npu_error}"
        return ""

    def transcribe(self, samples: np.ndarray, cancelled: CancelCheck = lambda: False) -> Transcript:
        self.encoder.swap()
        samples = np.ascontiguousarray(samples, dtype=np.float32)
        spans = plan_windows(samples.size, self.window_samples, self.overlap_samples)
        if len(spans) == 1:
            tokens = self._decode_window(samples, 0.0, cancelled)
            return self._build(tokens, samples.size / SAMPLE_RATE)
        kept: list[Word] = []
        for start, end, keep_from, keep_until in spans:
            offset = start / SAMPLE_RATE
            tokens = self._decode_window(samples[start:end], offset, cancelled)
            piece = self._build(tokens, end / SAMPLE_RATE)
            kept = stitch(kept, piece.words, keep_from, keep_until, self.frame_sec)
        return Transcript(" ".join(w.w for w in kept), kept)

    def _decode_window(self, samples: np.ndarray, offset: float, cancelled: CancelCheck) -> list[Token]:
        raise NotImplementedError

    def _build(self, tokens: list[Token], audio_end: float) -> Transcript:
        raise NotImplementedError

    @staticmethod
    def _check(cancelled: CancelCheck) -> None:
        if cancelled():
            raise Cancelled("request cancelled")


def _compile(core, path: Path, device: str):
    if not path.is_file():
        raise InvalidModel(f"missing model file {path.name}")
    return core.compile_model(core.read_model(str(path)), device)


def _port(compiled, name: str):
    for port in compiled.inputs + compiled.outputs:
        if name in port.get_names():
            return port
    raise InvalidModel(f"graph has no tensor named {name!r}")


class ParakeetTdt(OvFamily):
    """FluidInference ``parakeet-tdt-0.6b-v3-ov`` layout."""

    BLANK = 8192
    DURATIONS = (0, 1, 2, 3, 4)
    MAX_SYMBOLS = 10
    LAYERS = 2
    HIDDEN = 640

    def __init__(self, directory: Path, device: str, cache_directory: Optional[Path]) -> None:
        started = time.monotonic()
        core = _core(cache_directory)
        vocab = json.loads((directory / "parakeet_vocab.json").read_text(encoding="utf-8"))
        self.pieces = list(vocab["id_to_token"])
        if len(self.pieces) != self.BLANK:
            raise InvalidModel("parakeet vocabulary is not 8192 pieces")

        self.mel = _compile(core, directory / "parakeet_melspectogram.xml", "CPU")
        self.encoder = EncoderSlot(directory / "parakeet_encoder.xml", device, cache_directory)
        self.decoder = _compile(core, directory / "parakeet_decoder.xml", "CPU")
        self.joint = _compile(core, directory / "parakeet_joint.xml", "CPU")

        self.window_samples = int(self.mel.inputs[0].get_shape()[1])
        self.overlap_samples = 3 * SAMPLE_RATE
        mel_frames = int(self.mel.outputs[0].get_shape()[2])
        enc_frames = int(self.encoder.outputs[0].get_shape()[2])
        self.frame_sec = 0.01 * round(mel_frames / enc_frames)  # 8x subsampling
        logits = int(self.joint.outputs[0].get_shape()[-1])
        if logits != self.BLANK + 1 + len(self.DURATIONS):
            raise InvalidModel(f"parakeet joint width {logits}")

        self._mel = self.mel.create_infer_request()
        self._dec = self.decoder.create_infer_request()
        self._joint = self.joint.create_infer_request()
        self._dec_out = [_port(self.decoder, n) for n in ("decoder_output", "h_out", "c_out")]
        self.load_seconds = time.monotonic() - started

    def _decoder_step(self, token: int, h: np.ndarray, c: np.ndarray):
        result = self._dec.infer({"targets": np.array([[token]], dtype=np.int64),
                                  "h_in": h, "c_in": c})
        return (result[self._dec_out[0]].reshape(1, 1, self.HIDDEN).copy(),
                result[self._dec_out[1]].copy(), result[self._dec_out[2]].copy())

    def _decode_window(self, samples, offset, cancelled):
        padded = np.zeros((1, self.window_samples), dtype=np.float32)
        padded[0, :samples.size] = samples
        mel = self._mel.infer({"input_signals": padded,
                               "input_length": np.array([samples.size], dtype=np.int64)})
        features = mel[self.mel.outputs[0]]
        feature_len = int(mel[self.mel.outputs[1]].reshape(-1)[0])
        self._check(cancelled)

        enc = self.encoder.request.infer({
            "melspectogram": features,
            "melspectogram_length": np.array([feature_len], dtype=np.int32)})
        encoded = enc[self.encoder.outputs[0]][0]                 # [D, T]
        frames = min(int(enc[self.encoder.outputs[1]].reshape(-1)[0]), encoded.shape[1])
        frame_major = np.ascontiguousarray(encoded[:, :frames].T)
        self._check(cancelled)

        h = np.zeros((self.LAYERS, 1, self.HIDDEN), dtype=np.float32)
        c = np.zeros_like(h)
        dec_out, h_next, c_next = self._decoder_step(self.BLANK, h, c)
        tokens: list[Token] = []
        t = emitted = 0
        while t < frames:
            self._check(cancelled)
            logits = self._joint.infer({"encoder_outputs": frame_major[t].reshape(1, 1, -1),
                                        "decoder_outputs": dec_out})[0].reshape(-1)
            token = int(np.argmax(logits[:self.BLANK + 1]))
            skip = self.DURATIONS[int(np.argmax(logits[self.BLANK + 1:]))]
            if token != self.BLANK:
                if not is_control_piece(self.pieces[token]):
                    tokens.append(Token(token, offset + t * self.frame_sec,
                                        _softmax_probability(logits[:self.BLANK + 1], token)))
                h, c = h_next, c_next
                dec_out, h_next, c_next = self._decoder_step(token, h, c)
                emitted += 1
            if skip > 0:
                t += skip
                emitted = 0
            elif token == self.BLANK or emitted >= self.MAX_SYMBOLS:
                t += 1
                emitted = 0
        return tokens

    def _build(self, tokens, audio_end):
        return words_word_start_rule(tokens, self.pieces, self.frame_sec, audio_end)


class GigaamRnnt(OvFamily):
    """GigaAM v3 e2e RNN-T: canonical decoder/joint plus the static NPU encoder."""

    BLANK = 1024
    MAX_SYMBOLS = 3
    HIDDEN = 320

    def __init__(self, directory: Path, device: str, cache_directory: Optional[Path]) -> None:
        started = time.monotonic()
        core = _core(cache_directory)
        self.pieces = sentencepiece_pieces(directory / "tokenizer.model")
        if len(self.pieces) != self.BLANK:
            raise InvalidModel(f"GigaAM tokenizer has {len(self.pieces)} pieces, expected 1024")

        self.encoder = EncoderSlot(directory / "v3_e2e_rnnt_encoder_static.xml", device,
                                   cache_directory)
        self.decoder = _compile(core, directory / "v3_e2e_rnnt_decoder.xml", "CPU")
        self.joint = _compile(core, directory / "v3_e2e_rnnt_joint.xml", "CPU")

        self.feature_frames = int(self.encoder.inputs[0].get_shape()[2])   # 3000
        self.feature_dim = int(self.encoder.inputs[0].get_shape()[1])      # 64
        enc_frames = int(self.encoder.outputs[0].get_shape()[2])           # 750
        self.frame_sec = 0.01 * round(self.feature_frames / enc_frames)
        # center=False STFT, win 320, hop 160: the largest input whose
        # features still fit the static encoder.
        self.window_samples = (self.feature_frames - 1) * 160 + 320
        self.overlap_samples = 4 * SAMPLE_RATE

        self._dec = self.decoder.create_infer_request()
        self._joint = self.joint.create_infer_request()
        self._dec_out = [_port(self.decoder, n) for n in ("dec", "h", "c")]
        self.load_seconds = time.monotonic() - started

    def _decoder_step(self, token: int, h: np.ndarray, c: np.ndarray):
        result = self._dec.infer({"x": np.array([[token]], dtype=np.int64), "h.1": h, "c.1": c})
        return (result[self._dec_out[0]].reshape(1, self.HIDDEN, 1).copy(),
                result[self._dec_out[1]].copy(), result[self._dec_out[2]].copy())

    def _decode_window(self, samples, offset, cancelled):
        if samples.size < _GIGAAM_N_FFT:
            return []
        features, valid = gigaam_features(samples)
        valid = min(valid, self.feature_frames)
        padded = np.zeros((1, self.feature_dim, self.feature_frames), dtype=np.float32)
        padded[0, :, :valid] = features[:, :valid]
        self._check(cancelled)

        enc = self.encoder.request.infer({"audio_signal": padded,
                                          "length": np.array([valid], dtype=np.int64)})
        encoded = enc[self.encoder.outputs[0]][0]
        frames = min(int(enc[self.encoder.outputs[1]].reshape(-1)[0]), encoded.shape[1])
        frame_major = np.ascontiguousarray(encoded[:, :frames].T)
        self._check(cancelled)

        h = np.zeros((1, 1, self.HIDDEN), dtype=np.float32)
        c = np.zeros_like(h)
        dec_out, h_next, c_next = self._decoder_step(self.BLANK, h, c)
        tokens: list[Token] = []
        t = emitted = 0
        while t < frames:
            self._check(cancelled)
            logits = self._joint.infer({"enc": frame_major[t].reshape(1, -1, 1),
                                        "dec": dec_out})[0].reshape(-1)
            token = int(np.argmax(logits))
            if token != self.BLANK:
                if not is_control_piece(self.pieces[token]):
                    tokens.append(Token(token, offset + t * self.frame_sec,
                                        _softmax_probability(logits, token)))
                h, c = h_next, c_next
                dec_out, h_next, c_next = self._decoder_step(token, h, c)
                emitted += 1
            if token == self.BLANK or emitted >= self.MAX_SYMBOLS:
                t += 1
                emitted = 0
        return tokens

    def _build(self, tokens, audio_end):
        return words_space_rule(tokens, self.pieces, self.frame_sec, audio_end)


FAMILIES = ("nemo_tdt_ov", "gigaam_rnnt_ov")


def load(family: str, directory: Path, device: str, cache_directory: Optional[Path]) -> OvFamily:
    if family == "nemo_tdt_ov":
        return ParakeetTdt(directory, device, cache_directory)
    if family == "gigaam_rnnt_ov":
        return GigaamRnnt(directory, device, cache_directory)
    raise InvalidModel(f"unknown OpenVINO model family {family!r}")

