"""Small Windows integrations: output muting, feedback sounds, autostart
and single-instance enforcement.

Each of these replaces a macOS-specific mechanism:

===========================  ==========================================
macOS                        Windows
===========================  ==========================================
CoreAudio default device     ``IAudioEndpointVolume`` via pycaw
``NSSound`` system sounds    generated tones via ``winsound``
``~/Library/LaunchAgents``   ``HKCU\\...\\CurrentVersion\\Run``
PID file in Application      a named kernel mutex
Support
===========================  ==========================================
"""

from __future__ import annotations

import atexit
import ctypes
import ctypes.wintypes as wt
import io
import math
import os
import struct
import sys
import threading
import time
import wave
from functools import lru_cache
from typing import Callable, Optional

from . import paths
from .logging_setup import get as get_logger

log = get_logger("system")

user32 = ctypes.WinDLL("user32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)


# -- system output mute --------------------------------------------------


def _speaker_interface(interface_type):
    """Activate a COM interface on the default playback device.

    ``AudioUtilities.GetSpeakers()`` used to hand back the raw IMMDevice;
    since pycaw 2024 it hands back an ``AudioDevice`` wrapper, which has no
    ``Activate``. Calling it regardless is how muting quietly stopped
    working: the AttributeError was caught, logged and swallowed.

    The result is obtained through ``QueryInterface`` rather than
    ``ctypes.cast``. Casting builds a second Python object over the same
    COM pointer without adding a reference to it, so the two objects
    together release one reference twice; the object is freed while the
    app still holds a pointer to it, and the next garbage collection to
    touch that pointer takes the whole process down with an access
    violation, far from anything to do with audio.
    """
    from comtypes import CLSCTX_ALL
    from pycaw.pycaw import AudioUtilities

    device = AudioUtilities.GetSpeakers()
    device = getattr(device, "_dev", device)
    unknown = device.Activate(interface_type._iid_, CLSCTX_ALL, None)
    return unknown.QueryInterface(interface_type)


class OutputMute:
    """Mutes the default playback device for the duration of a recording.

    macOS mutes so the microphone does not pick up whatever is playing.
    The same reasoning applies here, but the device mute flag outlives the
    process that set it: whatever kills the app mid-recording — a crash, a
    killed task, a power loss — leaves the machine silent, with nothing on
    screen to connect the silence to this app.

    So the mute is guarded twice. ``atexit`` covers an orderly exit and an
    unhandled exception, and a marker file on disk covers everything else:
    it is written before the device is touched and removed after it is put
    back, so the next launch can see that the last one muted and never
    unmuted, and undo it.
    """

    def __init__(self) -> None:
        self._previous: Optional[bool] = None
        self._lock = threading.Lock()
        atexit.register(self.restore)

    def _endpoint(self):
        from pycaw.pycaw import IAudioEndpointVolume

        return _speaker_interface(IAudioEndpointVolume)

    def mute(self) -> None:
        with self._lock:
            if self._previous is not None:
                return
            try:
                import comtypes

                comtypes.CoInitialize()
                volume = self._endpoint()
                self._previous = bool(volume.GetMute())
                if not self._previous:
                    # Written first: a marker that arrives after the mute
                    # would be missing in exactly the case it exists for.
                    _write_mute_marker()
                    volume.SetMute(1, None)
            except Exception as exc:
                log.warning("Could not mute system output: %s", exc)
                self._previous = None

    def restore(self) -> None:
        with self._lock:
            if self._previous is None:
                return
            was_muted = self._previous
            self._previous = None
            if was_muted:
                return
            try:
                import comtypes

                comtypes.CoInitialize()
                self._endpoint().SetMute(0, None)
                _clear_mute_marker()
            except Exception as exc:
                log.warning("Could not restore system output: %s", exc)

    @staticmethod
    def recover() -> bool:
        """Undo a mute left behind by a previous run. Returns True if it did.

        Called at startup. The marker means the last run muted the device
        and never got as far as putting it back, so the user has been
        looking at a silent machine with no idea why.
        """
        if not paths.MUTE_MARKER_FILE.exists():
            return False
        try:
            import comtypes

            comtypes.CoInitialize()
            _speaker_interface(_endpoint_volume_type()).SetMute(0, None)
            log.info("Restored system output muted by a previous run")
        except Exception as exc:
            log.warning("Could not restore output after a previous run: %s", exc)
            return False
        finally:
            _clear_mute_marker()
        return True


def _endpoint_volume_type():
    from pycaw.pycaw import IAudioEndpointVolume

    return IAudioEndpointVolume


def _write_mute_marker() -> None:
    try:
        paths.MUTE_MARKER_FILE.write_text("muted", encoding="utf-8")
    except OSError as exc:
        log.warning("Could not write the mute marker: %s", exc)


def _clear_mute_marker() -> None:
    try:
        paths.MUTE_MARKER_FILE.unlink(missing_ok=True)
    except OSError as exc:
        log.warning("Could not clear the mute marker: %s", exc)


# -- media pause ---------------------------------------------------------


VK_MEDIA_PLAY_PAUSE = 0xB3
KEYEVENTF_KEYUP = 0x0002
# Anything quieter than this is background hiss from a session that is open
# but not playing; anything louder is something the user is listening to.
_AUDIBLE_PEAK = 0.004
# One reading can land in a gap between words or beats, so a few are taken.
# The whole probe runs before the recorder opens, so it is kept to 30 ms:
# any longer and the delay would eat the start of the first word.
_PEAK_SAMPLES = 3
_PEAK_INTERVAL = 0.015


class MediaPause:
    """Presses the play/pause media key around a recording.

    Muting silences the speakers but the video keeps running, so the
    dictation costs you the part you were watching. The media key is what a
    keyboard would send, so whatever owns playback — a player, a browser
    tab — handles it the way it handles the real thing.

    The key is a toggle, which makes an unconditional press dangerous: with
    nothing playing it would *start* something. So playback is confirmed
    first by metering the output device, and the key is only pressed again
    afterwards if this class was the one that paused it.
    """

    def __init__(self) -> None:
        self._paused = False
        self._lock = threading.Lock()

    @staticmethod
    def _something_is_playing() -> bool:
        from pycaw.api.endpointvolume import IAudioMeterInformation

        meter = _speaker_interface(IAudioMeterInformation)
        for index in range(_PEAK_SAMPLES):
            if float(meter.GetPeakValue()) > _AUDIBLE_PEAK:
                return True
            if index + 1 < _PEAK_SAMPLES:
                time.sleep(_PEAK_INTERVAL)
        return False

    @staticmethod
    def _tap() -> None:
        user32.keybd_event(VK_MEDIA_PLAY_PAUSE, 0, 0, 0)
        user32.keybd_event(VK_MEDIA_PLAY_PAUSE, 0, KEYEVENTF_KEYUP, 0)

    def pause(self) -> None:
        """Pause playback if there is any.

        Runs before the output is muted and before the start cue: a muted
        device meters as silence, and our own cue would meter as music.
        """
        with self._lock:
            if self._paused:
                return
            try:
                import comtypes

                comtypes.CoInitialize()
                if not self._something_is_playing():
                    return
                self._tap()
                self._paused = True
            except Exception as exc:
                log.warning("Could not pause playback: %s", exc)
                self._paused = False

    def resume(self) -> None:
        with self._lock:
            if not self._paused:
                return
            self._paused = False
            try:
                self._tap()
            except Exception as exc:
                log.warning("Could not resume playback: %s", exc)


# -- feedback sounds -----------------------------------------------------


CUE_SAMPLE_RATE = 44100


@lru_cache(maxsize=8)
def _cue(segments: tuple[tuple[int, int], ...], volume: float = 0.22) -> bytes:
    """Render a sequence of (frequency Hz, duration ms) tones to a WAV.

    A frequency of zero is silence. The phase carries across segments and
    the whole clip gets a short attack and release, because a sine that
    starts or stops at a non-zero value clicks, and a click is exactly the
    kind of cheap-sounding detail these cues exist to avoid.
    """
    total = sum(CUE_SAMPLE_RATE * ms // 1000 for _, ms in segments)
    attack = int(CUE_SAMPLE_RATE * 0.004)
    release = int(CUE_SAMPLE_RATE * 0.020)
    frames = bytearray()
    phase = 0.0
    index = 0

    for frequency, milliseconds in segments:
        count = CUE_SAMPLE_RATE * milliseconds // 1000
        step = 2.0 * math.pi * frequency / CUE_SAMPLE_RATE
        for _ in range(count):
            if index < attack:
                envelope = index / attack
            elif index > total - release:
                envelope = max(0.0, (total - index) / release)
            else:
                envelope = 1.0
            sample = math.sin(phase) if frequency else 0.0
            frames += struct.pack("<h", int(32767 * volume * envelope * sample))
            phase += step
            index += 1

    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(CUE_SAMPLE_RATE)
        out.writeframes(bytes(frames))
    return buffer.getvalue()


class Sounds:
    """Short non-blocking cues for start / stop / error.

    Start and stop play bundled WAV files, the product's own recording
    cue and the same cue reversed, so the two are obviously a pair and
    obviously opposite. They used to be Windows system event sounds,
    which meant "recording started" was whatever the user's theme
    assigned to Asterisk: often a long chime, sometimes the same sound as
    an error dialog, and on a silent theme nothing at all.

    Error and rejected stay synthesised. They fire while the user is
    already annoyed and want to be plain and short, not branded.
    """

    _FILES = {
        "start": "record-start.wav",
        "stop": "record-stop.wav",
    }
    _TONES: dict[str, tuple[tuple[int, int], ...]] = {
        "error": ((330, 90), (0, 45), (330, 110)),
        "rejected": ((420, 55),),
    }

    def __init__(self, enabled: bool = True) -> None:
        self.enabled = enabled

    def play(self, event: str, then: Optional[Callable[[], None]] = None) -> None:
        """Play a cue, and run ``then`` once it has finished sounding.

        ``then`` exists for one caller: muting the system output at the
        start of a recording. The mute silences the speakers, so a cue
        played into it is a cue nobody hears; waiting for the last sample
        is the difference between a start sound and no start sound at all.

        It runs on the cue's own thread, never on the caller's, and it runs
        even when sounds are switched off or the cue could not be played —
        whatever it is meant to do still has to happen.
        """
        if not self.enabled:
            if then is not None:
                threading.Thread(target=then, name="after-cue",
                                 daemon=True).start()
            return

        blocking = then is not None

        def worker() -> None:
            try:
                import winsound

                # SND_ASYNC returns as soon as playback starts; without it
                # PlaySound returns when the sound is over, which is what
                # a follow-up action has to wait for.
                mode = 0 if blocking else winsound.SND_ASYNC
                name = self._FILES.get(event)
                if name is not None:
                    path = paths.resource_path("assets", name)
                    if path.exists():
                        winsound.PlaySound(str(path),
                                           winsound.SND_FILENAME | mode)
                        return
                    log.warning("Cue %s is missing from the build", name)
                segments = self._TONES.get(event)
                if segments is None:
                    return
                # SND_MEMORY with SND_ASYNC needs the buffer to outlive the
                # call; the lru_cache is what keeps it alive.
                winsound.PlaySound(_cue(segments), winsound.SND_MEMORY | mode)
            except Exception as exc:
                log.debug("Could not play the %s cue: %s", event, exc)
            finally:
                if then is not None:
                    then()

        threading.Thread(target=worker, name="sound", daemon=True).start()


# -- autostart -----------------------------------------------------------

_RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"
_RUN_VALUE = "SuperDictate"
# The app was called D1CT before 1.8.0 (and SuperDictate before 1.5.0).
# Its autostart entry names an executable that is no longer installed, so
# it is cleared whenever this one is written or removed; left alone it
# would fail silently at every login.
_LEGACY_RUN_VALUES = ("D1CT", "SuperDictate")


def _launch_command() -> str:
    """The command Windows runs at login, tray-only.

    ``--minimized`` is the whole point of the entry: a copy started by
    the system should appear in the tray and wait for the hotkey, not
    throw a window over whatever the user is logging in to do. The
    installer writes the flag too, but this function overwrites what the
    installer wrote whenever settings are saved, so leaving it out here
    silently undid it for anyone who ever opened the settings window.
    """
    executable = sys.executable
    if getattr(sys, "frozen", False):
        return f'"{executable}" --minimized'
    script = paths.resource_path("main.py")
    return f'"{executable}" "{script}" --minimized'


def autostart_enabled() -> bool:
    import winreg

    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, _RUN_KEY) as key:
            value, _ = winreg.QueryValueEx(key, _RUN_VALUE)
            return bool(value)
    except OSError:
        return False


def _autostart_command() -> Optional[str]:
    import winreg

    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, _RUN_KEY) as key:
            value, _ = winreg.QueryValueEx(key, _RUN_VALUE)
            return str(value)
    except OSError:
        return None


def _autostart_target(command: str) -> str:
    """The executable a Run entry names, unquoted."""
    if not command.startswith('"'):
        return command.split(" ", 1)[0]
    end = command.find('"', 1)
    return command[1:end] if end > 0 else command[1:]


def repair_autostart() -> None:
    """Bring a stale login entry up to date. Two ways it goes stale.

    One: it was written before ``--minimized`` was included, so the app
    came up with its window over everything at every login.

    Two: it names an executable that is no longer there. Installs made
    when the app was called D1CT sat in a folder of that name, and the
    installer that finally moves them leaves any entry the user wrote
    from inside the app pointing at the old path.

    Repointing is only ever done by a frozen build: a copy run from a
    source checkout has no business aiming the installed app's autostart
    at a working directory.
    """
    current = _autostart_command()
    if current is None:
        return

    same_executable = f'"{sys.executable}"' in current
    if same_executable and "--minimized" in current:
        return

    orphaned = (getattr(sys, "frozen", False)
                and not os.path.exists(_autostart_target(current)))
    if not (same_executable or orphaned):
        return
    if set_autostart(True):
        log.info("Autostart entry repaired: %s -> %s", current, _launch_command())


def set_autostart(enabled: bool) -> bool:
    import winreg

    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, _RUN_KEY, 0,
                            winreg.KEY_SET_VALUE) as key:
            for legacy in _LEGACY_RUN_VALUES:
                try:
                    winreg.DeleteValue(key, legacy)
                except FileNotFoundError:
                    pass
            if enabled:
                winreg.SetValueEx(key, _RUN_VALUE, 0, winreg.REG_SZ, _launch_command())
            else:
                try:
                    winreg.DeleteValue(key, _RUN_VALUE)
                except FileNotFoundError:
                    pass
        return True
    except OSError as exc:
        log.warning("Could not update autostart: %s", exc)
        return False


# -- window plumbing -----------------------------------------------------

# Declared rather than left to ctypes' c_int default, so handles survive
# intact on a 64-bit build.
user32.GetForegroundWindow.restype = wt.HWND
user32.RegisterWindowMessageW.argtypes = [wt.LPCWSTR]
user32.RegisterWindowMessageW.restype = wt.UINT
user32.PostMessageW.argtypes = [wt.HWND, wt.UINT, wt.WPARAM, wt.LPARAM]
user32.PostMessageW.restype = wt.BOOL
kernel32.CreateMutexW.argtypes = [ctypes.c_void_p, wt.BOOL, wt.LPCWSTR]
kernel32.CreateMutexW.restype = wt.HANDLE
kernel32.CloseHandle.argtypes = [wt.HANDLE]
kernel32.CloseHandle.restype = wt.BOOL


# -- single instance -----------------------------------------------------


class SingleInstance:
    """A named mutex, checked before the UI is built.

    macOS writes a PID file and signals the running control panel; the
    Windows equivalent is a kernel mutex plus a broadcast window message
    so a second launch surfaces the existing window instead of racing it
    for the keyboard hook.
    """

    def __init__(self, name: str = paths.SINGLE_INSTANCE_MUTEX) -> None:
        self._handle = kernel32.CreateMutexW(None, False, name)
        # ctypes saves and restores the thread's last-error value around
        # every call when the library was opened with use_last_error, so
        # calling GetLastError() through it reads back ctypes' own restored
        # value rather than CreateMutexW's. ctypes.get_last_error() is the
        # one that returns what the call actually set.
        self.already_running = ctypes.get_last_error() == 183  # ERROR_ALREADY_EXISTS

    def release(self) -> None:
        if self._handle:
            kernel32.CloseHandle(self._handle)
            self._handle = None


SHOW_PANEL_MESSAGE = "SuperDictate.ShowControlPanel"

# The identity Windows groups taskbar buttons and pinned shortcuts by. The
# installer stamps the same string onto the shortcuts it creates.
APP_USER_MODEL_ID = "local.SuperDictate"


def set_app_user_model_id(app_id: str = APP_USER_MODEL_ID) -> None:
    """Claim an explicit taskbar identity, before any window exists.

    Without one, Windows derives an identity from the executable path and
    keeps the icon it cached for it — which is why the tray, drawn by this
    process from the current artwork, updated after a rebrand while the
    taskbar button kept showing the old picture.
    """
    try:
        ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID(app_id)
    except Exception as exc:  # pragma: no cover - shell32 is always there
        log.warning("Could not set the app user model id: %s", exc)


def register_show_message() -> int:
    return user32.RegisterWindowMessageW(SHOW_PANEL_MESSAGE)


def broadcast_show_panel() -> None:
    HWND_BROADCAST = 0xFFFF
    user32.PostMessageW(HWND_BROADCAST, register_show_message(), 0, 0)
