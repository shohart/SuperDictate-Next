"""``SuperDictateOvHost``: the NPU speech-recognition host.

The OpenVINO twin of ``native/asr-runtime/host/onnx_host_main.cpp``: one
helper process, one model, framed IPC v1 on stdin/stdout, so the app talks
to it through the very same :class:`superdictate.onnx_host.OnnxHost`
client. Only the CREATE config differs (``"engine": "openvino"``, a
``device`` and a model ``family``; see :mod:`superdictate.openvino_asr`).

Behaviour kept from the native host: one TRANSCRIBE at a time on a worker
thread (a second one gets BUSY), CANCEL honoured between inference calls,
EOF on stdin ends the process. A model that will not compile for the NPU is
loaded on the CPU instead, and the status says so (``provider_actual`` and
``provider_fallback_reason``), the way the ONNX host reports a provider it
could not get.

Entry points: ``SuperDictateOvHost.exe`` in a packaged build
(``ov_host_main.py``), ``python main.py --openvino-host`` from a checkout.
"""

from __future__ import annotations

import json
import os
import struct
import sys
import threading
import time
from pathlib import Path
from typing import BinaryIO, Optional

import numpy as np

_VERSION = 1
_REQUEST_HEADER = struct.Struct("<4sHHQIQ")
_RESPONSE_HEADER = struct.Struct("<4sHHQI")
_MAX_JSON_BYTES = 1 << 20
_MAX_PCM_BYTES = 30 * 60 * 16000 * 4

TYPE_CREATE, TYPE_TRANSCRIBE, TYPE_STATUS, TYPE_CANCEL, TYPE_SHUTDOWN = 1, 2, 3, 4, 5

# sd_asr_status (native/asr-runtime/include/sd_asr.h)
OK = 0
INVALID_ARGUMENT = 1
INVALID_MODEL = 2
UNSUPPORTED_MODEL_FAMILY = 3
INVALID_AUDIO = 4
MODEL_LOAD_FAILED = 6
INFERENCE_FAILED = 7
CANCELLED = 8
BUSY = 11

_CATEGORY_STATUS = {
    "invalid_model": INVALID_MODEL,
    "inference_failed": INFERENCE_FAILED,
    "cancelled": CANCELLED,
}
_STATUS_NAMES = {
    INVALID_ARGUMENT: "invalid_argument", INVALID_MODEL: "invalid_model",
    UNSUPPORTED_MODEL_FAMILY: "unsupported_model_family", INVALID_AUDIO: "invalid_audio",
    MODEL_LOAD_FAILED: "model_load_failed", INFERENCE_FAILED: "inference_failed",
    CANCELLED: "cancelled", BUSY: "busy",
}


def _log(message: str) -> None:
    try:
        sys.stderr.write(f"SuperDictateOvHost: {message}\n")
        sys.stderr.flush()
    except (OSError, ValueError, AttributeError):
        pass


def _error_body(status: int, message: str) -> dict:
    return {"category": _STATUS_NAMES.get(status, f"status {status}"), "message": message}


class _Host:
    def __init__(self, output: BinaryIO) -> None:
        self._out = output
        self._write_lock = threading.Lock()
        self.model = None
        self.model_id = ""
        self.family = ""
        self.provider_requested = "cpu"
        self.provider_actual = "cpu"
        self.fallback_reason = ""
        self.load_seconds = 0.0
        self._worker: Optional[threading.Thread] = None
        self._running_id: Optional[int] = None
        self._cancel = threading.Event()

    # -- framing -------------------------------------------------------

    def respond(self, request_id: int, status: int, body: dict) -> bool:
        payload = json.dumps(body, ensure_ascii=False).encode("utf-8")
        frame = _RESPONSE_HEADER.pack(b"SDAR", _VERSION, status, request_id, len(payload)) + payload
        with self._write_lock:
            try:
                self._out.write(frame)
                self._out.flush()
                return True
            except (OSError, ValueError):
                return False

    # -- requests ------------------------------------------------------

    def status(self) -> dict:
        if self.model is None:
            return {"state": "empty", "api_version": 1}
        status = {
            "state": "inference" if self._running_id is not None else "ready",
            "engine": "openvino",
            "model_id": self.model_id,
            "family": self.family,
            "provider_requested": self.provider_requested,
            "provider_actual": self.provider_actual,
            "load_seconds": round(self.load_seconds, 3),
            # The fixed input the model takes. Longer audio is cut inside
            # the host as a fallback; the app sizes its pause segments to
            # fit instead (transcription.segment_limits).
            "window_seconds": round(getattr(self.model, "window_samples", 0) / 16000, 3),
        }
        if self.fallback_reason:
            status["provider_fallback_reason"] = self.fallback_reason
        return status

    def create(self, request_id: int, config: dict) -> None:
        from . import openvino_asr

        if self.model is not None:
            self.respond(request_id, INVALID_ARGUMENT,
                         _error_body(INVALID_ARGUMENT, "a model is already loaded in this host"))
            return
        family = str(config.get("family", ""))
        if family not in openvino_asr.FAMILIES:
            self.respond(request_id, UNSUPPORTED_MODEL_FAMILY,
                         _error_body(UNSUPPORTED_MODEL_FAMILY, f"unknown family {family!r}"))
            return
        directory = Path(str(config.get("model_directory", "")))
        cache = config.get("cache_directory")
        cache_directory = Path(str(cache)) if cache else None
        device = str(config.get("device", "NPU")).upper()
        allow_fallback = bool(config.get("allow_cpu_fallback", True))

        started = time.monotonic()
        try:
            try:
                model = openvino_asr.load(family, directory, device, cache_directory)
            except openvino_asr.InvalidModel:
                raise
            except Exception as exc:
                if device == "CPU" or not allow_fallback:
                    raise
                _log(f"{device} compile failed, loading on CPU: {exc}")
                self.fallback_reason = f"{device}: {str(exc).strip().splitlines()[-1][:300]}"
                model = openvino_asr.load(family, directory, "CPU", cache_directory)
        except openvino_asr.InvalidModel as exc:
            self.respond(request_id, INVALID_MODEL, _error_body(INVALID_MODEL, str(exc)))
            return
        except Exception as exc:
            _log(f"model load failed: {exc}")
            self.respond(request_id, MODEL_LOAD_FAILED, _error_body(MODEL_LOAD_FAILED, str(exc)))
            return

        self.model = model
        self.family = family
        self.model_id = str(config.get("model_id", family))
        self.provider_requested = device.lower()
        self.provider_actual = model.device.lower()
        self.load_seconds = time.monotonic() - started
        _log(f"{self.model_id} ready on {model.device} in {self.load_seconds:.1f}s")
        self.respond(request_id, OK, self.status())

    def transcribe(self, request_id: int, options: dict, pcm: bytes) -> None:
        if self.model is None:
            self.respond(request_id, INVALID_ARGUMENT,
                         _error_body(INVALID_ARGUMENT, "no model loaded (send CREATE first)"))
            return
        if self._running_id is not None:
            self.respond(request_id, BUSY, _error_body(BUSY, "another transcription is running"))
            return
        sample_rate = int(options.get("sample_rate", 16000) or 16000)
        if sample_rate != 16000 or not pcm:
            self.respond(request_id, INVALID_AUDIO,
                         _error_body(INVALID_AUDIO, "expected non-empty 16 kHz mono f32 PCM"))
            return
        samples = np.frombuffer(pcm, dtype="<f4")
        timestamps = bool(options.get("timestamps", False))
        if self._worker is not None:
            self._worker.join()
        self._cancel.clear()
        self._running_id = request_id
        self._worker = threading.Thread(target=self._run, args=(request_id, samples, timestamps),
                                        name="transcribe", daemon=True)
        self._worker.start()

    def _run(self, request_id: int, samples: np.ndarray, timestamps: bool) -> None:
        from . import openvino_asr

        started = time.monotonic()
        try:
            transcript = self.model.transcribe(samples, self._cancel.is_set)
            body = {"text": transcript.text,
                    "processing_seconds": round(time.monotonic() - started, 4),
                    "model_id": self.model_id,
                    "provider_actual": self.provider_actual}
            if timestamps:
                body["words"] = [{"w": w.w, "start": round(w.start, 3), "end": round(w.end, 3),
                                  "conf": round(w.conf, 4)} for w in transcript.words]
            status = OK
        except openvino_asr.OvAsrError as exc:
            status = _CATEGORY_STATUS.get(exc.category, INFERENCE_FAILED)
            body = _error_body(status, str(exc))
        except Exception as exc:
            _log(f"inference failed: {exc}")
            status = INFERENCE_FAILED
            body = _error_body(status, str(exc))
        self._running_id = None
        if not self.respond(request_id, status, body):
            _log("stdout closed; exiting")
            os._exit(0)

    def cancel(self, request_id: int, options: dict) -> None:
        target = options.get("target")
        running = self._running_id
        if running is not None and (target is None or target == running):
            self._cancel.set()
            self.respond(request_id, OK, {"cancelled": str(running)})
        else:
            self.respond(request_id, INVALID_ARGUMENT,
                         _error_body(INVALID_ARGUMENT, f"no running request {target}"))

    def stop(self) -> None:
        self._cancel.set()
        if self._worker is not None:
            self._worker.join(timeout=10.0)


def _read_exactly(stream: BinaryIO, count: int) -> Optional[bytes]:
    chunks = []
    remaining = count
    while remaining:
        chunk = stream.read(remaining)
        if not chunk:
            return None
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def serve(stdin: BinaryIO, stdout: BinaryIO) -> int:
    host = _Host(stdout)
    while True:
        header = _read_exactly(stdin, _REQUEST_HEADER.size)
        if header is None:
            host.stop()  # EOF: the parent closed our stdin or died
            return 0
        magic, version, kind, request_id, json_len, pcm_bytes = _REQUEST_HEADER.unpack(header)
        problem = None
        if magic != b"SDAQ":
            problem = "bad magic"
        elif version != _VERSION:
            problem = f"bad version {version}"
        elif json_len > _MAX_JSON_BYTES:
            problem = "json too large"
        elif pcm_bytes > _MAX_PCM_BYTES or pcm_bytes % 4:
            problem = "bad pcm length"
        elif pcm_bytes and kind != TYPE_TRANSCRIBE:
            problem = "pcm not allowed"
        if problem:
            _log(f"framing error: {problem}")
            host.respond(request_id, INVALID_ARGUMENT, _error_body(INVALID_ARGUMENT, problem))
            host.stop()
            return 2

        body = _read_exactly(stdin, json_len) if json_len else b""
        pcm = _read_exactly(stdin, pcm_bytes) if pcm_bytes else b""
        if body is None or pcm is None:
            host.stop()
            return 0
        try:
            options = json.loads(body) if body else {}
        except ValueError:
            options = None
        if not isinstance(options, dict):
            host.respond(request_id, INVALID_ARGUMENT,
                         _error_body(INVALID_ARGUMENT, "options are not a JSON object"))
            continue

        if kind == TYPE_CREATE:
            host.create(request_id, options)
        elif kind == TYPE_TRANSCRIBE:
            host.transcribe(request_id, options, pcm)
        elif kind == TYPE_STATUS:
            host.respond(request_id, OK, host.status())
        elif kind == TYPE_CANCEL:
            host.cancel(request_id, options)
        elif kind == TYPE_SHUTDOWN:
            host.stop()
            host.respond(request_id, OK, {})
            return 0
        else:
            host.respond(request_id, INVALID_ARGUMENT,
                         _error_body(INVALID_ARGUMENT, f"unknown message type {kind}"))


def probe() -> dict:
    """What the NPU path can use on this machine, for ``--probe``."""
    from . import openvino_asr

    import openvino as ov

    core = ov.Core()
    devices = list(core.available_devices)
    result: dict = {"openvino": ov.__version__, "devices": devices, "npu": None}
    if "NPU" in devices:
        try:
            name = str(core.get_property("NPU", "FULL_DEVICE_NAME"))
        except Exception:
            name = "NPU"
        result["npu"] = {"name": name, "driver_build": openvino_asr.npu_driver_build(core)}
    return result


def _std_streams() -> tuple[BinaryIO, BinaryIO]:
    if sys.platform == "win32":
        import msvcrt

        msvcrt.setmode(0, os.O_BINARY)
        msvcrt.setmode(1, os.O_BINARY)
    # Unbuffered raw descriptors: the client counts on every response frame
    # reaching it as soon as it is written, and nothing else may touch stdout.
    return os.fdopen(0, "rb", buffering=0, closefd=False), os.fdopen(1, "wb", buffering=0, closefd=False)


def main(argv: list[str]) -> int:
    if "--probe" in argv:
        stdout = _std_streams()[1]
        try:
            info = probe()
        except Exception as exc:
            info = {"error": str(exc), "devices": [], "npu": None}
        stdout.write((json.dumps(info) + "\n").encode("utf-8"))
        return 0
    stdin, stdout = _std_streams()
    # Anything printed by mistake must not corrupt the frames.
    sys.stdout = sys.stderr
    return serve(stdin, stdout)
