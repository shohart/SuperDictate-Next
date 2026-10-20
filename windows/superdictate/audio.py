"""Microphone capture.

macOS uses ``AVAudioEngine`` with a tap on the input node; the Windows port
uses PortAudio through ``sounddevice``, preferring the WASAPI host API so
device names match what the user sees in Windows settings and so shared
mode gives us the low latency the HUD's level meter needs.

Constants are carried over from ``main.swift`` unchanged: 16 kHz mono
float32, a 20-minute auto-stop, and a 0.25 s minimum clip below which a
recording is discarded as an accidental tap.
"""

from __future__ import annotations

import struct
import threading
import time
from dataclasses import dataclass
from typing import Callable, Optional

import numpy as np

from . import paths
from .logging_setup import get as get_logger

log = get_logger("audio")

SAMPLE_RATE = 16_000
MAX_RECORDING_SECONDS = 20 * 60
MIN_CLIP_SECONDS = 0.25
BLOCK_FRAMES = 512  # 32 ms, smooth enough for the waveform, cheap enough to log

PENDING_MAGIC = b"SDPD"
PENDING_VERSION = 1
PENDING_HEADER_SIZE = 16
PENDING_MAX_SECONDS = 30 * 60

# Stop-on-silence. The threshold is RMS amplitude, chosen well above room
# tone but below quiet speech; the delay is what the user asked for.
DEFAULT_SILENCE_STOP_SECONDS = 2.5
SILENCE_RMS_THRESHOLD = 0.012
SPEECH_RMS_THRESHOLD = 0.03


@dataclass(frozen=True)
class InputDevice:
    index: int
    name: str
    is_default: bool

    @property
    def key(self) -> str:
        """Stable identifier for settings: PortAudio indices shuffle when
        devices are plugged in, so the name is what gets persisted."""
        return self.name


def list_input_devices() -> list[InputDevice]:
    import sounddevice as sd

    try:
        devices = sd.query_devices()
        default_index = sd.default.device[0]
    except Exception as exc:  # no audio subsystem, no devices
        log.warning("Could not enumerate input devices: %s", exc)
        return []

    preferred_hostapi = _wasapi_index()
    result: list[InputDevice] = []
    seen: set[str] = set()
    for index, device in enumerate(devices):
        if device.get("max_input_channels", 0) < 1:
            continue
        if preferred_hostapi is not None and device.get("hostapi") != preferred_hostapi:
            continue
        name = str(device.get("name", "")).strip()
        if not name or name in seen:
            continue
        seen.add(name)
        result.append(InputDevice(index, name, index == default_index))
    return result


def _wasapi_index() -> Optional[int]:
    import sounddevice as sd

    try:
        for index, api in enumerate(sd.query_hostapis()):
            if "WASAPI" in str(api.get("name", "")).upper():
                return index
    except Exception:
        pass
    return None


def resolve_device(name: str) -> Optional[int]:
    """Map a persisted device name back to a PortAudio index."""
    if not name:
        return None
    for device in list_input_devices():
        if device.name == name:
            return device.index
    log.warning("Configured input device %r is gone; falling back to default", name)
    return None


def device_sample_rate(device_index: Optional[int]) -> int:
    """The rate a device will actually open at.

    WASAPI in shared mode only accepts the endpoint's own mix rate, asking
    a 48 kHz microphone for 16 kHz fails outright with "Invalid sample
    rate", which is why every explicitly-chosen device used to be rejected
    while the system default (routed through MME, which resamples for us)
    worked. So we take whatever the device offers and resample ourselves.
    """
    import sounddevice as sd

    try:
        info = sd.query_devices(device_index if device_index is not None else None,
                                "input")
        rate = int(round(float(info["default_samplerate"])))
        return rate if rate > 0 else SAMPLE_RATE
    except Exception as exc:
        log.warning("Could not read the device's sample rate (%s); assuming %d Hz",
                    exc, SAMPLE_RATE)
        return SAMPLE_RATE


def _antialias_filter(source_rate: int, taps: int = 101) -> np.ndarray:
    """Windowed-sinc low-pass just under the 16 kHz Nyquist frequency.

    Decimating without this folds everything above 8 kHz back into the
    speech band as aliasing, which the model hears as noise.
    """
    cutoff = 0.9 * (SAMPLE_RATE / 2) / source_rate  # cycles per source sample
    n = np.arange(taps) - (taps - 1) / 2
    kernel = 2 * cutoff * np.sinc(2 * cutoff * n)
    kernel *= np.hamming(taps)
    return (kernel / np.sum(kernel)).astype(np.float32)


def resample_to_16k(samples: np.ndarray, source_rate: int) -> np.ndarray:
    """Convert captured audio to the 16 kHz mono the model expects."""
    if samples.size == 0 or source_rate == SAMPLE_RATE:
        return samples.astype(np.float32, copy=False)

    working = samples.astype(np.float32, copy=False)
    if source_rate > SAMPLE_RATE:
        working = np.convolve(working, _antialias_filter(source_rate), mode="same")

    duration = working.size / source_rate
    out_count = int(round(duration * SAMPLE_RATE))
    if out_count <= 0:
        return np.zeros(0, dtype=np.float32)
    # Linear interpolation is adequate once the signal is band-limited.
    source_positions = np.arange(working.size, dtype=np.float64)
    target_positions = np.arange(out_count, dtype=np.float64) * (source_rate / SAMPLE_RATE)
    return np.interp(target_positions, source_positions, working).astype(np.float32)


class Recorder:
    """One recording session at a time, owned by the app state machine."""

    def __init__(
        self,
        on_level: Optional[Callable[[float], None]] = None,
        on_auto_stop: Optional[Callable[[], None]] = None,
    ) -> None:
        self._on_level = on_level
        self._on_auto_stop = on_auto_stop
        self._stream = None
        self._chunks: list[np.ndarray] = []
        self._lock = threading.Lock()
        self._started_at = 0.0
        self._recording = False
        self._pending_handle = None
        self._auto_stop_fired = False
        self._capture_rate = SAMPLE_RATE
        self.last_error: Optional[str] = None

        # Stop-on-silence. Counting only starts once the speaker has
        # actually said something, so a pause before the first word never
        # ends the recording.
        self.silence_stop_enabled = False
        self.silence_stop_seconds = DEFAULT_SILENCE_STOP_SECONDS
        self._heard_speech = False
        self._silence_started_at = 0.0

    @property
    def capture_rate(self) -> int:
        return self._capture_rate

    @property
    def is_recording(self) -> bool:
        return self._recording

    @property
    def elapsed(self) -> float:
        return time.monotonic() - self._started_at if self._recording else 0.0

    def start(self, device_name: str = "") -> bool:
        import sounddevice as sd

        if self._recording:
            return True
        self.last_error = None
        with self._lock:
            self._chunks = []
        self._auto_stop_fired = False
        self._heard_speech = False
        self._silence_started_at = 0.0
        device_index = resolve_device(device_name)

        # 16 kHz first (no resampling to pay for), then the device's own
        # rate, which is the only one WASAPI shared mode will grant.
        native_rate = device_sample_rate(device_index)
        candidates = [SAMPLE_RATE] if native_rate == SAMPLE_RATE else [SAMPLE_RATE, native_rate]

        last_error: Optional[Exception] = None
        for rate in candidates:
            try:
                stream = sd.InputStream(
                    samplerate=rate,
                    channels=1,
                    dtype="float32",
                    blocksize=max(256, int(BLOCK_FRAMES * rate / SAMPLE_RATE)),
                    device=device_index,
                    callback=self._callback,
                )
                stream.start()
            except Exception as exc:
                last_error = exc
                log.debug("Device rejected %d Hz: %s", rate, exc)
                continue
            self._stream = stream
            self._capture_rate = rate
            break
        else:
            self.last_error = str(last_error)
            log.error("Could not open input stream: %s", last_error)
            self._stream = None
            return False

        self._open_pending_file()
        self._started_at = time.monotonic()
        self._recording = True
        log.info("Recording started (device=%s, %d Hz%s)",
                 device_name or "system default", self._capture_rate,
                 "" if self._capture_rate == SAMPLE_RATE else ", resampling to 16 kHz")
        return True

    def stop(self) -> np.ndarray:
        if not self._recording:
            return np.zeros(0, dtype=np.float32)
        self._recording = False
        try:
            if self._stream is not None:
                self._stream.stop()
                self._stream.close()
        except Exception as exc:
            log.warning("Error closing input stream: %s", exc)
        finally:
            self._stream = None

        self._close_pending_file()
        with self._lock:
            chunks = self._chunks
            self._chunks = []
        if not chunks:
            return np.zeros(0, dtype=np.float32)
        captured = np.concatenate(chunks).astype(np.float32, copy=False)
        return resample_to_16k(captured, self._capture_rate)

    def snapshot(self, max_seconds: float = 0.0) -> np.ndarray:
        """Everything captured so far, leaving the recording running.

        ``max_seconds`` trims to the most recent stretch before resampling
        rather than after, because the anti-alias convolution is the
        expensive part and this runs on a timer while the microphone is
        still open.
        """
        with self._lock:
            chunks = list(self._chunks)
        if not chunks:
            return np.zeros(0, dtype=np.float32)
        captured = np.concatenate(chunks).astype(np.float32, copy=False)
        if max_seconds > 0:
            limit = int(max_seconds * self._capture_rate)
            if captured.size > limit:
                captured = captured[-limit:]
        return resample_to_16k(captured, self._capture_rate)

    def discard(self) -> None:
        self.stop()
        clear_pending_dictation()

    # -- stream callback ---------------------------------------------

    def _callback(self, indata, frames, time_info, status) -> None:
        if status:
            log.debug("Input stream status: %s", status)
        samples = indata[:, 0].copy()
        with self._lock:
            self._chunks.append(samples)
        self._append_pending(samples)

        rms = float(np.sqrt(np.mean(np.square(samples)))) if frames else 0.0
        if self._on_level is not None:
            # A light expansion so quiet speech still animates the meter.
            try:
                self._on_level(min(1.0, rms * 6.0))
            except Exception:
                pass

        if (
            not self._auto_stop_fired
            and (self.elapsed >= MAX_RECORDING_SECONDS or self._silence_elapsed(rms))
            and self._on_auto_stop is not None
        ):
            self._auto_stop_fired = True
            try:
                self._on_auto_stop()
            except Exception:
                pass

    def _silence_elapsed(self, rms: float) -> bool:
        """True once the speaker has gone quiet for long enough to stop.

        Two thresholds with a gap between them, so a voice hovering right
        at the cutoff does not flicker the timer on and off.
        """
        if not self.silence_stop_enabled:
            return False

        now = time.monotonic()
        if rms >= SPEECH_RMS_THRESHOLD:
            self._heard_speech = True
            self._silence_started_at = 0.0
            return False
        if not self._heard_speech:
            # Nothing said yet, the user is still gathering their thoughts.
            return False
        if rms >= SILENCE_RMS_THRESHOLD:
            return False

        if self._silence_started_at == 0.0:
            self._silence_started_at = now
            return False
        return (now - self._silence_started_at) >= self.silence_stop_seconds

    # -- crash recovery ----------------------------------------------
    #
    # Audio is streamed to disk as it arrives so a power loss or a crash
    # mid-dictation leaves a recoverable clip, exactly like the macOS
    # pending-dictation file. Header: magic, version, sample rate, and a
    # reserved word to keep it 16 bytes.

    def _open_pending_file(self) -> None:
        try:
            paths.ensure_directories()
            handle = open(paths.PENDING_DICTATION_FILE, "wb")
            handle.write(
                struct.pack("<4sIII", PENDING_MAGIC, PENDING_VERSION,
                            self._capture_rate, 0)
            )
            handle.flush()
            self._pending_handle = handle
        except OSError as exc:
            log.warning("Could not open pending dictation file: %s", exc)
            self._pending_handle = None

    def _append_pending(self, samples: np.ndarray) -> None:
        handle = self._pending_handle
        if handle is None:
            return
        try:
            if handle.tell() >= PENDING_HEADER_SIZE + PENDING_MAX_SECONDS * SAMPLE_RATE * 4:
                return
            handle.write(samples.tobytes())
        except (OSError, ValueError):
            self._pending_handle = None

    def _close_pending_file(self) -> None:
        handle = self._pending_handle
        self._pending_handle = None
        if handle is None:
            return
        try:
            handle.flush()
            handle.close()
        except OSError:
            pass


def read_pending_dictation() -> Optional[np.ndarray]:
    """Recover audio left behind by a crash, if it is long enough to matter."""
    try:
        with open(paths.PENDING_DICTATION_FILE, "rb") as handle:
            header = handle.read(PENDING_HEADER_SIZE)
            if len(header) < PENDING_HEADER_SIZE:
                return None
            magic, version, rate, _ = struct.unpack("<4sIII", header)
            if magic != PENDING_MAGIC or version != PENDING_VERSION or rate <= 0:
                return None
            payload = handle.read(PENDING_MAX_SECONDS * rate * 4)
    except OSError:
        return None

    usable = len(payload) - (len(payload) % 4)
    if usable <= 0:
        return None
    samples = np.frombuffer(payload[:usable], dtype=np.float32)
    if samples.size < MIN_CLIP_SECONDS * rate:
        return None
    # The clip was written at whatever rate the device ran at.
    return resample_to_16k(samples.copy(), rate)


def clear_pending_dictation() -> None:
    try:
        paths.PENDING_DICTATION_FILE.unlink()
    except OSError:
        pass
