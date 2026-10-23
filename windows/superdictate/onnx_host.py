"""Client for ``SuperDictateOnnxHost``, the native speech-recognition host.

Port of ``OnnxAsrEngine.swift``. The app never loads ONNX Runtime itself
(docs/specs/cross-platform-onnx-asr-spec.md §3): one helper process holds one
model and speaks framed IPC v1 over its stdin/stdout
(``native/asr-runtime/src/ipc.h``, spec §8)::

    request : "SDAQ" | u16 version=1 | u16 type | u64 request_id | u32 json_len | u64 pcm_bytes | json | pcm f32
    response: "SDAR" | u16 version=1 | u16 status | u64 request_id | u32 json_len | json

Same safety rules as the macOS client: exact read loops, one request at a
time, a hard per-request timeout that first sends CANCEL (honoured between
ONNX Runtime runs) and kills the process if that does not end the request.
A dead host reports ``is_alive == False``; the owner starts a new one.

Keeping the runtime out of the Python process also keeps its 3–4 s of
graph construction off the GIL, which used to freeze the panel while the
model loaded.
"""

from __future__ import annotations

import json
import os
import struct
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional, Sequence

import numpy as np

from .logging_setup import get as get_logger

log = get_logger("onnx_host")

_VERSION = 1
_REQUEST_HEADER = struct.Struct("<4sHHQIQ")
_RESPONSE_HEADER = struct.Struct("<4sHHQI")
_MAX_JSON_BYTES = 1 << 20

TYPE_CREATE = 1
TYPE_TRANSCRIBE = 2
TYPE_STATUS = 3
TYPE_CANCEL = 4
TYPE_SHUTDOWN = 5

STATUS_OK = 0
STATUS_CANCELLED = 8

#: How long CANCEL gets to end a request before the process is killed.
_CANCEL_GRACE_SECONDS = 5.0


class OnnxHostError(RuntimeError):
    #: True when the process can no longer be used.
    kills_host = False


class HostExited(OnnxHostError):
    kills_host = True


class InvalidResponse(OnnxHostError):
    kills_host = True


class TimedOut(OnnxHostError):
    kills_host = True


class NativeError(OnnxHostError):
    def __init__(self, category: str, message: str) -> None:
        super().__init__(f"ONNX ASR {category}: {message}")
        self.category = category


@dataclass(frozen=True)
class HostWord:
    text: str
    start: float
    end: float


@dataclass(frozen=True)
class HostTranscription:
    text: str
    processing_seconds: float
    words: tuple[HostWord, ...]


def timeout_seconds(sample_count: int, sample_rate: int = 16000) -> float:
    """Generous bound: a minute plus real time, far above any measured RTF."""
    return 60.0 + sample_count / sample_rate


def _request_frame(kind: int, request_id: int, body: bytes, pcm: bytes = b"") -> bytes:
    return _REQUEST_HEADER.pack(b"SDAQ", _VERSION, kind, request_id, len(body), len(pcm)) + body + pcm


def _assign_kill_on_close_job(process: subprocess.Popen) -> object:
    """Tie the host's lifetime to ours.

    POSIX hosts notice re-parenting; Windows has no such signal, and a
    parent killed from Task Manager can leave its pipes open in a stuck
    state. A job object with KILL_ON_JOB_CLOSE ends the host with the last
    handle to the job — ours — whatever way this process goes. Best effort:
    without pywin32 the stdin-EOF contract still applies.
    """
    if sys.platform != "win32":
        return None
    try:
        import win32api
        import win32con
        import win32job

        job = win32job.CreateJobObject(None, "")
        info = win32job.QueryInformationJobObject(job, win32job.JobObjectExtendedLimitInformation)
        info["BasicLimitInformation"]["LimitFlags"] |= win32job.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        win32job.SetInformationJobObject(job, win32job.JobObjectExtendedLimitInformation, info)
        handle = win32api.OpenProcess(win32con.PROCESS_SET_QUOTA | win32con.PROCESS_TERMINATE,
                                      False, process.pid)
        try:
            win32job.AssignProcessToJobObject(job, handle)
        finally:
            win32api.CloseHandle(handle)
        return job
    except Exception as exc:
        log.debug("Could not put the ONNX host in a job object: %s", exc)
        return None


class OnnxHost:
    """One running ``SuperDictateOnnxHost`` with one loaded model."""

    def __init__(self, command: Sequence[str], *, cwd: Optional[Path] = None,
                 stderr_path: Optional[Path] = None) -> None:
        creationflags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        self._stderr = subprocess.DEVNULL
        if stderr_path:
            try:
                stderr_path.parent.mkdir(parents=True, exist_ok=True)
                self._stderr = open(stderr_path, "ab")
            except OSError:
                pass  # diagnostics only; never a reason not to start
        self._process = subprocess.Popen(
            list(command),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self._stderr,
            creationflags=creationflags,
            cwd=str(cwd) if cwd else None,
        )
        self._job = _assign_kill_on_close_job(self._process)
        self._write_lock = threading.Lock()
        self._request_lock = threading.Lock()
        self._next_id = 1
        self.is_alive = True
        self.provider_actual = "cpu"
        self.provider_fallback_reason = ""
        self.model_id = ""
        self.load_seconds = 0.0
        #: Longest audio the model takes in one pass; 0 means any length.
        self.window_seconds = 0.0

    # -- lifecycle ------------------------------------------------------

    def create(self, *, model_directory: Path, assets_directory: Path, threads: int,
               expected_model_id: Optional[str] = None) -> None:
        config: dict = {
            "engine": "onnxruntime",
            "model_directory": str(model_directory),
            "assets_directory": str(assets_directory),
            "provider": "auto",
            "intra_op_threads": int(threads),
        }
        if expected_model_id:
            config["model_id"] = expected_model_id
        self.create_with(config, timeout=120.0)

    def create_with(self, config: dict, *, timeout: float) -> None:
        """CREATE with a host-specific config (``SuperDictateOvHost`` takes its own)."""
        started = time.monotonic()
        status, _ = self._round_trip(TYPE_CREATE, config, b"", timeout=timeout)
        self.load_seconds = time.monotonic() - started
        self.provider_actual = str(status.get("provider_actual", "cpu"))
        self.provider_fallback_reason = str(status.get("provider_fallback_reason", ""))
        self.model_id = str(status.get("model_id", ""))
        try:
            self.window_seconds = float(status.get("window_seconds", 0.0) or 0.0)
        except (TypeError, ValueError):
            self.window_seconds = 0.0

    def refresh_status(self, timeout: float = 5.0) -> None:
        """Ask the host where it runs now (SuperDictateOvHost moves a model
        from the CPU to the NPU when its background compile finishes)."""
        status, _ = self._round_trip(TYPE_STATUS, {}, b"", timeout=timeout)
        provider = status.get("provider_actual")
        if isinstance(provider, str) and provider:
            self.provider_actual = provider
            self.provider_fallback_reason = str(status.get("provider_fallback_reason", "") or "")

    def shutdown(self) -> None:
        if not self.is_alive:
            self._close()
            return
        self.is_alive = False
        try:
            self._write(_request_frame(TYPE_SHUTDOWN, self._take_id(), b"{}"))
        except OSError:
            pass
        self._close()

    def _close(self) -> None:
        try:
            if self._process.stdin:
                self._process.stdin.close()
        except OSError:
            pass
        try:
            self._process.wait(timeout=3.0)
        except subprocess.TimeoutExpired:
            self._process.kill()
        if self._stderr is not subprocess.DEVNULL:
            try:
                self._stderr.close()
            except OSError:
                pass

    def kill(self) -> None:
        self.is_alive = False
        try:
            self._process.kill()
        except OSError:
            pass

    # -- requests -------------------------------------------------------

    def transcribe(self, samples: np.ndarray, *, timestamps: bool = False,
                   sample_rate: int = 16000) -> HostTranscription:
        pcm = np.ascontiguousarray(samples, dtype="<f4")
        if pcm.size == 0:
            raise OnnxHostError("empty audio")
        options = {"timestamps": bool(timestamps), "sample_rate": int(sample_rate)}
        result, _ = self._round_trip(TYPE_TRANSCRIBE, options, pcm.tobytes(),
                                     timeout=timeout_seconds(pcm.size, sample_rate))
        text = result.get("text")
        if not isinstance(text, str):
            raise InvalidResponse("missing text")
        # SuperDictateOvHost reports its device on every response: a model
        # that started on the CPU moves to the NPU once its compile is done.
        provider = result.get("provider_actual")
        if isinstance(provider, str) and provider:
            self.provider_actual = provider
            self.provider_fallback_reason = str(result.get("provider_fallback_reason", "") or "")
        words = tuple(
            HostWord(text=str(item.get("w", "")), start=float(item.get("start", 0.0)),
                     end=float(item.get("end", 0.0)))
            for item in result.get("words", ()) if isinstance(item, dict)
        )
        return HostTranscription(text=text,
                                 processing_seconds=float(result.get("processing_seconds", 0.0)),
                                 words=words)

    def _take_id(self) -> int:
        request_id = self._next_id
        self._next_id += 1
        return request_id

    def _write(self, frame: bytes) -> None:
        with self._write_lock:
            stdin = self._process.stdin
            if stdin is None:
                raise OSError("host stdin is closed")
            stdin.write(frame)
            stdin.flush()

    def _round_trip(self, kind: int, options: dict, pcm: bytes, *,
                    timeout: float) -> tuple[dict, bytes]:
        with self._request_lock:
            if not self.is_alive:
                raise HostExited("SuperDictateOnnxHost is not running")
            request_id = self._take_id()
            cancel_id = self._take_id()
            body = json.dumps(options).encode("utf-8")
            try:
                self._write(_request_frame(kind, request_id, body, pcm))
            except OSError as exc:
                self.is_alive = False
                raise HostExited(f"SuperDictateOnnxHost exited ({self._process.poll()})") from exc

            timed_out = threading.Event()
            finished = threading.Event()

            def on_deadline() -> None:
                timed_out.set()
                cancel = json.dumps({"target": request_id}).encode("utf-8")
                try:
                    self._write(_request_frame(TYPE_CANCEL, cancel_id, cancel))
                except OSError:
                    pass
                if not finished.wait(_CANCEL_GRACE_SECONDS):
                    log.warning("ONNX host ignored CANCEL; killing it")
                    self.kill()

            watchdog = threading.Timer(timeout, on_deadline)
            watchdog.daemon = True
            watchdog.start()
            try:
                while True:
                    status, response_id, payload = self._read_response()
                    if response_id != request_id:
                        continue  # the acknowledgement of our own CANCEL
                    if status == STATUS_OK:
                        try:
                            decoded = json.loads(payload)
                        except ValueError:
                            decoded = None
                        if not isinstance(decoded, dict):
                            raise InvalidResponse("body is not a JSON object")
                        return decoded, payload
                    if status == STATUS_CANCELLED and timed_out.is_set():
                        raise TimedOut(f"ONNX transcription timed out after {timeout:.0f} s")
                    try:
                        error = json.loads(payload) if payload else {}
                    except ValueError:
                        error = {}
                    raise NativeError(str(error.get("category", f"status {status}")),
                                      str(error.get("message", "")))
            except OnnxHostError as exc:
                if isinstance(exc, HostExited) and timed_out.is_set():
                    self.is_alive = False
                    raise TimedOut(f"ONNX transcription timed out after {timeout:.0f} s") from exc
                if exc.kills_host:
                    self.is_alive = False
                    self.kill()
                raise
            finally:
                finished.set()
                watchdog.cancel()

    def _read_response(self) -> tuple[int, int, bytes]:
        header = self._read_exactly(_RESPONSE_HEADER.size)
        magic, version, status, request_id, length = _RESPONSE_HEADER.unpack(header)
        if magic != b"SDAR":
            raise InvalidResponse("bad magic")
        if version != _VERSION:
            raise InvalidResponse(f"version {version}")
        if length > _MAX_JSON_BYTES:
            raise InvalidResponse(f"json_len {length}")
        payload = self._read_exactly(length) if length else b""
        return status, request_id, payload

    def _read_exactly(self, count: int) -> bytes:
        stdout = self._process.stdout
        if stdout is None:
            raise HostExited("host stdout is closed")
        chunks = []
        remaining = count
        while remaining:
            chunk = stdout.read(remaining)
            if not chunk:
                raise HostExited(f"SuperDictateOnnxHost exited ({self._process.poll()})")
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)


def physical_core_count() -> int:
    """Physical cores; half the logical count when Windows will not say."""
    if sys.platform == "win32":
        try:
            import ctypes
            from ctypes import wintypes

            kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
            RelationProcessorCore = 0
            length = wintypes.DWORD(0)
            kernel32.GetLogicalProcessorInformationEx(RelationProcessorCore, None, ctypes.byref(length))
            buffer = (ctypes.c_byte * length.value)()
            if kernel32.GetLogicalProcessorInformationEx(RelationProcessorCore, buffer,
                                                         ctypes.byref(length)):
                count, offset = 0, 0
                while offset < length.value:
                    # SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX: Relationship, Size, ...
                    size = int.from_bytes(bytes(buffer[offset + 4:offset + 8]), "little")
                    if size <= 0:
                        break
                    count += 1
                    offset += size
                if count > 0:
                    return count
        except Exception:
            pass
    return max(1, (os.cpu_count() or 2) // 2)


def resolved_thread_count(physical_cores: Optional[int] = None,
                          override: Optional[str] = None) -> int:
    """Every physical core but two, clamped to 2..16 — the macOS policy.

    The encoder is matmul-bound, so hyper-threads do not help; nothing else
    needs the CPU while a dictation is transcribed, because the LLM runs on
    the GPU. ``SUPERDICTATE_ASR_THREADS`` (1..32) overrides it for
    diagnostics; anything else in it is ignored.
    """
    cores = physical_core_count() if physical_cores is None else physical_cores
    default = max(2, min(16, cores - 2))
    raw = os.environ.get("SUPERDICTATE_ASR_THREADS") if override is None else override
    try:
        parsed = int(raw) if raw is not None else None
    except ValueError:
        parsed = None
    if parsed is not None and 1 <= parsed <= 32:
        return parsed
    return default
