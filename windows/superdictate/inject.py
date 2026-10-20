"""Putting the transcript into whatever the user was typing in.

macOS finds the focused element through the Accessibility API and pastes
via a synthesized Command+V. Windows has no equivalent permission gate,
so the flow is simpler but needs three pieces of care the Mac does not:

1. **Stuck modifiers.** In hold mode the user is still physically holding
   the hotkey when the paste fires. Sending Ctrl+V while Right Shift is
   down produces Ctrl+Shift+V, which many apps map to "paste as plain
   text" or nothing at all. Physically-down modifiers are released first.
2. **Clipboard ownership.** The clipboard is a shared, single-owner
   resource; another app can hold it open. Opening is retried, and the
   previous text is restored once the target app has had time to read.
3. **Telling our own input apart.** Every synthetic event carries a magic
   value in ``dwExtraInfo`` so the keyboard hook can ignore it, otherwise
   the paste's own Ctrl would re-enter the hotkey state machine.

``KEYEVENTF_UNICODE`` typing is kept as a fallback for apps that refuse a
clipboard paste (some remote-desktop and game overlays), and it is what
gets used when the clipboard cannot be opened at all.
"""

from __future__ import annotations

import ctypes
import ctypes.wintypes as wt
import time
from typing import Optional

from .hotkeys import (
    INJECTED_MARKER,
    VK_LCONTROL,
    VK_LMENU,
    VK_LSHIFT,
    VK_LWIN,
    VK_RCONTROL,
    VK_RMENU,
    VK_RSHIFT,
    VK_RWIN,
)
from .logging_setup import get as get_logger

log = get_logger("inject")

user32 = ctypes.WinDLL("user32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

INPUT_KEYBOARD = 1
KEYEVENTF_KEYUP = 0x0002
KEYEVENTF_UNICODE = 0x0004
KEYEVENTF_EXTENDEDKEY = 0x0001

VK_CONTROL = 0x11
VK_V = 0x56
VK_RETURN = 0x0D

CF_UNICODETEXT = 13
GMEM_MOVEABLE = 0x0002

_ALL_MODIFIERS = (
    VK_LSHIFT, VK_RSHIFT, VK_LCONTROL, VK_RCONTROL,
    VK_LMENU, VK_RMENU, VK_LWIN, VK_RWIN,
)
_EXTENDED_KEYS = {VK_RCONTROL, VK_RMENU, VK_RWIN, VK_LWIN}


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [
        ("wVk", wt.WORD),
        ("wScan", wt.WORD),
        ("dwFlags", wt.DWORD),
        ("time", wt.DWORD),
        # ULONG_PTR, a plain integer, not a pointer. It carries
        # INJECTED_MARKER by value, which is what the hook compares against.
        ("dwExtraInfo", ctypes.c_size_t),
    ]


class _INPUTUNION(ctypes.Union):
    _fields_ = [("ki", KEYBDINPUT), ("padding", ctypes.c_byte * 32)]


class INPUT(ctypes.Structure):
    _anonymous_ = ("u",)
    _fields_ = [("type", wt.DWORD), ("u", _INPUTUNION)]


user32.SendInput.argtypes = [wt.UINT, ctypes.POINTER(INPUT), ctypes.c_int]
user32.SendInput.restype = wt.UINT
user32.GetAsyncKeyState.argtypes = [ctypes.c_int]
user32.GetAsyncKeyState.restype = ctypes.c_short
user32.MapVirtualKeyW.argtypes = [wt.UINT, wt.UINT]
user32.MapVirtualKeyW.restype = wt.UINT

# Handles and pointers must be declared, or ctypes defaults to c_int and
# truncates them to 32 bits on a 64-bit build, GlobalLock would then hand
# back a garbage address and the memmove below would fault.
user32.OpenClipboard.argtypes = [wt.HWND]
user32.OpenClipboard.restype = wt.BOOL
user32.CloseClipboard.restype = wt.BOOL
user32.EmptyClipboard.restype = wt.BOOL
user32.GetClipboardData.argtypes = [wt.UINT]
user32.GetClipboardData.restype = wt.HANDLE
user32.SetClipboardData.argtypes = [wt.UINT, wt.HANDLE]
user32.SetClipboardData.restype = wt.HANDLE
kernel32.GlobalAlloc.argtypes = [wt.UINT, ctypes.c_size_t]
kernel32.GlobalAlloc.restype = wt.HGLOBAL
kernel32.GlobalLock.argtypes = [wt.HGLOBAL]
kernel32.GlobalLock.restype = ctypes.c_void_p
kernel32.GlobalUnlock.argtypes = [wt.HGLOBAL]
kernel32.GlobalUnlock.restype = wt.BOOL
kernel32.GlobalFree.argtypes = [wt.HGLOBAL]
kernel32.GlobalFree.restype = wt.HGLOBAL


def _make_input(vk: int, unicode_char: str = "", key_up: bool = False) -> INPUT:
    entry = INPUT()
    entry.type = INPUT_KEYBOARD
    flags = KEYEVENTF_KEYUP if key_up else 0
    if unicode_char:
        entry.ki.wVk = 0
        entry.ki.wScan = ord(unicode_char)
        flags |= KEYEVENTF_UNICODE
    else:
        entry.ki.wVk = vk
        entry.ki.wScan = user32.MapVirtualKeyW(vk, 0)
        if vk in _EXTENDED_KEYS:
            flags |= KEYEVENTF_EXTENDEDKEY
    entry.ki.dwFlags = flags
    entry.ki.time = 0
    entry.ki.dwExtraInfo = INJECTED_MARKER
    return entry


def _send(inputs: list[INPUT]) -> bool:
    if not inputs:
        return True
    array = (INPUT * len(inputs))(*inputs)
    sent = user32.SendInput(len(inputs), array, ctypes.sizeof(INPUT))
    if sent != len(inputs):
        log.warning("SendInput sent %d of %d events (error %d)",
                    sent, len(inputs), ctypes.get_last_error())
        return False
    return True


def _pressed_modifiers() -> list[int]:
    return [vk for vk in _ALL_MODIFIERS if user32.GetAsyncKeyState(vk) & 0x8000]


def release_modifiers() -> list[int]:
    """Lift every physically-held modifier and report which ones they were."""
    held = _pressed_modifiers()
    if held:
        _send([_make_input(vk, key_up=True) for vk in held])
        time.sleep(0.005)
    return held


def clear_stuck_modifiers() -> list[int]:
    """Send a key-up for every modifier that is *not* physically held.

    A crash or a kill from Task Manager can end the process between a
    suppressed key-down and the key-up that would have balanced it, and the
    foreground app is then left believing Ctrl or Shift is still down:
    typing produces shortcuts instead of letters. A key-up for a key that
    is genuinely up is a no-op everywhere else, so this is safe to fire on
    every launch, and it never fights a modifier the user is really
    holding.
    """
    down = set(_pressed_modifiers())
    stray = [vk for vk in _ALL_MODIFIERS if vk not in down]
    if stray:
        _send([_make_input(vk, key_up=True) for vk in stray])
    return stray


# -- clipboard -----------------------------------------------------------


def _open_clipboard(attempts: int = 12) -> bool:
    for index in range(attempts):
        if user32.OpenClipboard(None):
            return True
        time.sleep(0.02 * (index + 1))
    return False


def read_clipboard_text() -> Optional[str]:
    if not _open_clipboard():
        return None
    try:
        handle = user32.GetClipboardData(CF_UNICODETEXT)
        if not handle:
            return None
        pointer = kernel32.GlobalLock(handle)
        if not pointer:
            return None
        try:
            return ctypes.c_wchar_p(pointer).value
        finally:
            kernel32.GlobalUnlock(handle)
    finally:
        user32.CloseClipboard()


def write_clipboard_text(text: str) -> bool:
    if not _open_clipboard():
        return False
    try:
        user32.EmptyClipboard()
        buffer = ctypes.create_unicode_buffer(text)
        size = ctypes.sizeof(buffer)
        handle = kernel32.GlobalAlloc(GMEM_MOVEABLE, size)
        if not handle:
            return False
        pointer = kernel32.GlobalLock(handle)
        if not pointer:
            kernel32.GlobalFree(handle)
            return False
        ctypes.memmove(pointer, ctypes.byref(buffer), size)
        kernel32.GlobalUnlock(handle)
        if not user32.SetClipboardData(CF_UNICODETEXT, handle):
            kernel32.GlobalFree(handle)
            return False
        return True  # the clipboard owns the handle now
    finally:
        user32.CloseClipboard()


# -- public API ----------------------------------------------------------


def type_unicode(text: str, chunk_delay: float = 0.0) -> bool:
    """Send text as synthetic Unicode keystrokes, no clipboard involved."""
    ok = True
    # Batched so a long transcript is not thousands of separate SendInput
    # calls, but small enough that apps with input queues keep up.
    batch: list[INPUT] = []
    for char in text:
        if char == "\n":
            batch.extend([_make_input(VK_RETURN), _make_input(VK_RETURN, key_up=True)])
        else:
            batch.extend([_make_input(0, char), _make_input(0, char, key_up=True)])
        if len(batch) >= 64:
            ok = _send(batch) and ok
            batch = []
            if chunk_delay:
                time.sleep(chunk_delay)
    if batch:
        ok = _send(batch) and ok
    return ok


def paste_text(
    text: str,
    *,
    press_enter: bool = False,
    enter_delay_ms: int = 120,
    restore_clipboard: bool = True,
) -> bool:
    """Insert `text` at the caret. Returns False if nothing could be sent."""
    if not text:
        return True

    release_modifiers()

    previous = read_clipboard_text() if restore_clipboard else None
    if not write_clipboard_text(text):
        log.warning("Clipboard unavailable; falling back to Unicode typing")
        typed = type_unicode(text)
        if typed and press_enter:
            _press_enter(enter_delay_ms)
        return typed

    ok = _send([
        _make_input(VK_CONTROL),
        _make_input(VK_V),
        _make_input(VK_V, key_up=True),
        _make_input(VK_CONTROL, key_up=True),
    ])

    if press_enter:
        _press_enter(enter_delay_ms)

    if restore_clipboard and previous is not None:
        # The target app reads the clipboard asynchronously, so restoring
        # immediately would race the paste it was meant to serve.
        _schedule_clipboard_restore(previous)
    return ok


def _press_enter(delay_ms: int) -> None:
    # Some apps (Electron, VMs, remote sessions) need a beat to process the
    # paste before they can handle a keystroke, same reason macOS made
    # this delay configurable.
    time.sleep(max(0, min(500, delay_ms)) / 1000.0)
    _send([_make_input(VK_RETURN), _make_input(VK_RETURN, key_up=True)])


def _schedule_clipboard_restore(previous: str, delay: float = 0.6) -> None:
    import threading

    def restore() -> None:
        time.sleep(delay)
        if not write_clipboard_text(previous):
            log.debug("Could not restore previous clipboard contents")

    threading.Thread(target=restore, name="clipboard-restore", daemon=True).start()
