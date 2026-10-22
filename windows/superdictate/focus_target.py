"""Where the user is typing, and getting back there before the paste.

Two jobs, both ported from the macOS build:

1. **Placing the capsule at the caret.** macOS asks the Accessibility API
   for the focused element's caret rectangle (FocusedInsertionTargetLocator
   in TextInsertion.swift). Windows has two sources, tried in order:

   * ``GetGUIThreadInfo`` on the foreground thread — the classic Win32
     caret, the same call PolterType uses. Cheap and exact for Win32 edit
     controls, Notepad, most native apps.
   * UI Automation — ``TextPattern2.GetCaretRange`` (or the selection of a
     plain ``TextPattern``) on the focused element. That is what browsers,
     Electron, WPF, UWP and Office expose instead of a Win32 caret.

   Failing a caret, the focused text field's own rectangle is used, and
   failing that the foreground window (the capsule then sits inside its
   lower-left corner, as on macOS).

2. **Pasting where the dictation started.** The target is captured when
   recording starts. Before the paste, if the user has wandered off to
   another window, that window is brought back and the captured element
   (or Win32 focus control) is focused again, so the text lands exactly
   where they began. A window that has since closed is never replaced by
   whatever is in front now: the caller puts the text on the clipboard
   instead (``textInsertionRoute`` → ``abortToClipboard`` on macOS).

Every UI Automation call runs on one dedicated thread. UIA round-trips are
cross-process and stall for as long as a hung target app takes to answer,
which must never be the Qt thread; keeping the COM objects on the thread
that created them also keeps their apartment rules trivially satisfied.

All rectangles here are physical screen pixels, which is what both
``GetGUIThreadInfo`` and UIA report to a per-monitor-DPI-aware process.
The HUD converts them to Qt's logical coordinates.
"""

from __future__ import annotations

import ctypes
import ctypes.wintypes as wt
import os
import queue
import threading
import time
from concurrent.futures import Future
from dataclasses import dataclass, replace
from enum import Enum
from typing import Any, Callable, Optional

from .logging_setup import get as get_logger

log = get_logger("focus")

user32 = ctypes.WinDLL("user32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
dwmapi = ctypes.WinDLL("dwmapi")

# -- geometry -------------------------------------------------------------


@dataclass(frozen=True)
class Rect:
    """Screen rectangle in physical pixels, y growing downward."""

    left: float
    top: float
    width: float
    height: float

    @property
    def right(self) -> float:
        return self.left + self.width

    @property
    def bottom(self) -> float:
        return self.top + self.height

    @property
    def center(self) -> tuple[float, float]:
        return (self.left + self.width / 2.0, self.top + self.height / 2.0)

    def contains(self, x: float, y: float, slack: float = 0.0) -> bool:
        return (self.left - slack <= x <= self.right + slack
                and self.top - slack <= y <= self.bottom + slack)

    def offset(self, dx: float, dy: float) -> "Rect":
        return Rect(self.left + dx, self.top + dy, self.width, self.height)

    def intersects(self, other: "Rect") -> bool:
        return not (other.left >= self.right or other.right <= self.left
                    or other.top >= self.bottom or other.bottom <= self.top)

    @property
    def is_valid(self) -> bool:
        values = (self.left, self.top, self.width, self.height)
        return all(v == v and abs(v) != float("inf") for v in values) \
            and self.width > 0 and self.height > 0


@dataclass(frozen=True)
class TargetIdentity:
    """Same window, same element: what the stabilizer compares."""

    pid: int
    window: int
    element: tuple


@dataclass(frozen=True)
class TargetFrame:
    """FocusedInsertionTargetFrame: the caret (or field) and where to anchor.

    ``frame`` is the caret or text-field rectangle; ``visual_frame`` is
    what the capsule is placed against — the field's left edge on the
    caret's line, so the capsule does not wander right as the user types.
    """

    frame: Rect
    visual_frame: Rect
    kind: str
    identity: TargetIdentity


@dataclass(frozen=True)
class QueryResult:
    pid: int
    process: str
    window: int
    window_frame: Optional[Rect]
    target: Optional[TargetFrame]
    detail: str


@dataclass(frozen=True)
class FieldSnapshot:
    """The focused text field, as edit_watch.py sees it."""

    element: tuple      # UIA runtime id: the same field across polls
    pid: int
    text: str
    caret: Optional[int]  # characters before the caret, when the field says
    secure: bool


@dataclass(frozen=True)
class InsertionTarget:
    """What was focused when recording started (PendingTextInsertionTarget)."""

    window: int
    focus_window: int
    pid: int
    thread: int
    process: str
    token: int  # key of the pinned UIA element on the probe thread, or 0


class RestoreOutcome(str, Enum):
    ALREADY_THERE = "already_there"
    RESTORED = "restored"
    # The window the dictation began in is gone. Pasting into whatever is
    # in front now is exactly the mistake this module exists to prevent.
    TARGET_GONE = "target_gone"
    # Windows refused to hand the foreground back. Same reasoning.
    NOT_ACTIVATED = "not_activated"


# -- Win32 ---------------------------------------------------------------


class GUITHREADINFO(ctypes.Structure):
    _fields_ = [
        ("cbSize", wt.DWORD),
        ("flags", wt.DWORD),
        ("hwndActive", wt.HWND),
        ("hwndFocus", wt.HWND),
        ("hwndCapture", wt.HWND),
        ("hwndMenuOwner", wt.HWND),
        ("hwndMoveSize", wt.HWND),
        ("hwndCaret", wt.HWND),
        ("rcCaret", wt.RECT),
    ]


class MONITORINFO(ctypes.Structure):
    _fields_ = [
        ("cbSize", wt.DWORD),
        ("rcMonitor", wt.RECT),
        ("rcWork", wt.RECT),
        ("dwFlags", wt.DWORD),
    ]


user32.GetForegroundWindow.restype = wt.HWND
user32.GetWindowThreadProcessId.argtypes = [wt.HWND, ctypes.POINTER(wt.DWORD)]
user32.GetWindowThreadProcessId.restype = wt.DWORD
user32.GetGUIThreadInfo.argtypes = [wt.DWORD, ctypes.POINTER(GUITHREADINFO)]
user32.GetGUIThreadInfo.restype = wt.BOOL
user32.ClientToScreen.argtypes = [wt.HWND, ctypes.POINTER(wt.POINT)]
user32.ClientToScreen.restype = wt.BOOL
user32.GetWindowRect.argtypes = [wt.HWND, ctypes.POINTER(wt.RECT)]
user32.GetWindowRect.restype = wt.BOOL
user32.IsWindow.argtypes = [wt.HWND]
user32.IsWindow.restype = wt.BOOL
user32.IsWindowVisible.argtypes = [wt.HWND]
user32.IsWindowVisible.restype = wt.BOOL
user32.IsIconic.argtypes = [wt.HWND]
user32.IsIconic.restype = wt.BOOL
user32.ShowWindow.argtypes = [wt.HWND, ctypes.c_int]
user32.ShowWindow.restype = wt.BOOL
user32.SetForegroundWindow.argtypes = [wt.HWND]
user32.SetForegroundWindow.restype = wt.BOOL
user32.BringWindowToTop.argtypes = [wt.HWND]
user32.BringWindowToTop.restype = wt.BOOL
user32.SetFocus.argtypes = [wt.HWND]
user32.SetFocus.restype = wt.HWND
user32.AttachThreadInput.argtypes = [wt.DWORD, wt.DWORD, wt.BOOL]
user32.AttachThreadInput.restype = wt.BOOL
user32.GetAncestor.argtypes = [wt.HWND, wt.UINT]
user32.GetAncestor.restype = wt.HWND
user32.MonitorFromPoint.argtypes = [wt.POINT, wt.DWORD]
user32.MonitorFromPoint.restype = wt.HMONITOR
user32.GetMonitorInfoW.argtypes = [wt.HMONITOR, ctypes.POINTER(MONITORINFO)]
user32.GetMonitorInfoW.restype = wt.BOOL
user32.PeekMessageW.argtypes = [ctypes.c_void_p, wt.HWND, wt.UINT, wt.UINT, wt.UINT]
user32.PeekMessageW.restype = wt.BOOL
kernel32.GetCurrentThreadId.restype = wt.DWORD
kernel32.OpenProcess.argtypes = [wt.DWORD, wt.BOOL, wt.DWORD]
kernel32.OpenProcess.restype = wt.HANDLE
kernel32.QueryFullProcessImageNameW.argtypes = [
    wt.HANDLE, wt.DWORD, wt.LPWSTR, ctypes.POINTER(wt.DWORD)]
kernel32.QueryFullProcessImageNameW.restype = wt.BOOL
kernel32.CloseHandle.argtypes = [wt.HANDLE]
dwmapi.DwmGetWindowAttribute.argtypes = [wt.HWND, wt.DWORD, ctypes.c_void_p, wt.DWORD]
dwmapi.DwmGetWindowAttribute.restype = ctypes.c_long

GA_ROOT = 2
SW_RESTORE = 9
MONITOR_DEFAULTTONEAREST = 2
DWMWA_EXTENDED_FRAME_BOUNDS = 9
PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
PM_NOREMOVE = 0


def _pid_and_thread(hwnd: int) -> tuple[int, int]:
    pid = wt.DWORD(0)
    thread = user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    return int(pid.value), int(thread)


def _process_name(pid: int) -> str:
    handle = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
    if not handle:
        return "?"
    try:
        size = wt.DWORD(1024)
        buffer = ctypes.create_unicode_buffer(size.value)
        if not kernel32.QueryFullProcessImageNameW(handle, 0, buffer, ctypes.byref(size)):
            return "?"
        return os.path.basename(buffer.value)
    finally:
        kernel32.CloseHandle(handle)


def _window_frame(hwnd: int) -> Optional[Rect]:
    """The visible frame: without the invisible resize borders of Win10+."""
    rect = wt.RECT()
    if dwmapi.DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS,
                                    ctypes.byref(rect), ctypes.sizeof(rect)) != 0:
        if not user32.GetWindowRect(hwnd, ctypes.byref(rect)):
            return None
    frame = Rect(rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top)
    return frame if frame.is_valid else None


def work_area(x: float, y: float) -> Rect:
    """The work area (screen minus taskbar) of the monitor nearest a point."""
    monitor = user32.MonitorFromPoint(wt.POINT(int(x), int(y)), MONITOR_DEFAULTTONEAREST)
    info = MONITORINFO()
    info.cbSize = ctypes.sizeof(MONITORINFO)
    if monitor and user32.GetMonitorInfoW(monitor, ctypes.byref(info)):
        r = info.rcWork
        return Rect(r.left, r.top, r.right - r.left, r.bottom - r.top)
    return Rect(0, 0, 1920, 1080)


def _gui_thread_info(thread: int) -> Optional[GUITHREADINFO]:
    info = GUITHREADINFO()
    info.cbSize = ctypes.sizeof(GUITHREADINFO)
    if not user32.GetGUIThreadInfo(thread, ctypes.byref(info)):
        return None
    return info


def _win32_caret(info: GUITHREADINFO) -> Optional[Rect]:
    """``rcCaret`` is client-space in ``hwndCaret``, often a child control."""
    if not info.hwndCaret:
        return None
    origin = wt.POINT(info.rcCaret.left, info.rcCaret.top)
    if not user32.ClientToScreen(info.hwndCaret, ctypes.byref(origin)):
        return None
    return normalized_caret(Rect(origin.x, origin.y,
                                 info.rcCaret.right - info.rcCaret.left,
                                 info.rcCaret.bottom - info.rcCaret.top))


# -- pure geometry (exercised by the self-tests) --------------------------


def normalized_caret(rect: Rect) -> Optional[Rect]:
    """normalizedCaretRect: a plausible caret, or nothing.

    A control that owns a caret it never shows leaves a collapsed
    rectangle at its client origin; something taller than a line or wider
    than a glyph is a selection or a whole field, not a caret.
    """
    values = (rect.left, rect.top, rect.width, rect.height)
    if not all(v == v and abs(v) != float("inf") for v in values):
        return None
    if rect.width < 0 or rect.height <= 0 or rect.height > 120:
        return None
    if rect.width > max(12.0, rect.height * 1.5):
        return None
    if rect.width == 0:
        return Rect(rect.left, rect.top, 2, rect.height)
    return rect


def is_reasonable_field(frame: Rect, anchor: Rect, area: Rect) -> bool:
    """isReasonableTextInputFrame: a field, not a whole page or window."""
    if not frame.is_valid:
        return False
    cx, cy = anchor.center
    if not frame.contains(cx, cy, slack=8):
        return False
    if frame.width > area.width * 0.92 and frame.height > area.height * 0.55:
        return False
    return frame.height <= area.height * 0.82


def visual_frame(field: Rect, caret: Rect, area: Rect) -> Rect:
    """visualTargetFrame: a document editor exposes its whole page as one
    field; keep the field's left edge but anchor to the caret's line."""
    if field.height > max(220.0, area.height * 0.34):
        return Rect(field.left, caret.top, field.width, caret.height)
    return field


def usable_target(frame: Rect, area: Rect) -> bool:
    """shouldUseRecordingHUDInsertionTarget."""
    if not frame.is_valid:
        return False
    if frame.width > area.width * 0.92 and frame.height > area.height * 0.55:
        return False
    return frame.height <= area.height * 0.82


class TargetStabilizer:
    """RecordingHUDTargetStabilizer: never jump on a single observation.

    A new element in the app the dictation started in is believed at once;
    another element of the confirmed app needs two sightings in a row, and
    a different app three — focus blips (a toast, the Start menu, our own
    windows) come and go within one poll.
    """

    def __init__(self) -> None:
        self.reset(None)

    def reset(self, initial_pid: Optional[int]) -> None:
        self.initial_pid = initial_pid
        self.confirmed: Optional[TargetIdentity] = None
        self._pending: Optional[TargetIdentity] = None
        self._pending_count = 0

    def observe(self, target: Optional[TargetFrame]) -> tuple[str, Optional[TargetFrame]]:
        """Returns ("none" | "update" | "switch", target)."""
        if target is None:
            self._pending = None
            self._pending_count = 0
            return "none", None
        if self.confirmed == target.identity:
            self._pending = None
            self._pending_count = 0
            return "update", target
        if self.confirmed is not None:
            required = 2 if self.confirmed.pid == target.identity.pid else 3
        else:
            required = 1 if self.initial_pid == target.identity.pid else 3
        if self._pending == target.identity:
            self._pending_count += 1
        else:
            self._pending = target.identity
            self._pending_count = 1
        if self._pending_count < required:
            return "none", None
        self.confirmed = target.identity
        self._pending = None
        self._pending_count = 0
        return "switch", target


# -- UI Automation --------------------------------------------------------

UIA_TEXT_PATTERN_ID = 10014
UIA_TEXT_PATTERN2_ID = 10024
UIA_VALUE_PATTERN_ID = 10002
UIA_EDIT_CONTROL = 50004
UIA_DOCUMENT_CONTROL = 50030
TEXT_UNIT_CHARACTER = 0
ENDPOINT_START = 0
ENDPOINT_END = 1
#: Larger fields are not watched for edits (edit_watch.py): the whole text is
#: read on every poll, and a long document is not a dictation box.
MAX_FIELD_CHARS = 200_000


def _load_uia():
    try:
        from comtypes.gen import UIAutomationClient as module  # pre-generated by the build
    except ImportError:
        import comtypes.client

        module = comtypes.client.GetModule("UIAutomationCore.dll")
    return module


class _Uia:
    """The UIA half of the probe. Lives on, and is only called from, the
    probe thread."""

    def __init__(self) -> None:
        import comtypes
        import comtypes.client

        comtypes.CoInitialize()
        self.module = _load_uia()
        self.automation = comtypes.client.CreateObject(
            self.module.CUIAutomation8, interface=self.module.IUIAutomation)
        try:
            # A hung app must cost a poll, not a frozen probe: the defaults
            # are 2 s to connect and 20 s per call.
            tuned = self.automation.QueryInterface(self.module.IUIAutomation2)
            tuned.ConnectionTimeout = 600
            tuned.TransactionTimeout = 400
        except Exception:  # pre-Windows 8 interface set
            pass

    def focused(self, expected_pid: int):
        try:
            element = self.automation.GetFocusedElement()
        except Exception:
            return None
        if not element:
            return None
        try:
            # UIA's focus is desktop-wide and can lag a window switch; an
            # element from another process is not this window's caret.
            if expected_pid and element.CurrentProcessId != expected_pid:
                return None
        except Exception:
            return None
        return element

    @staticmethod
    def runtime_id(element) -> tuple:
        try:
            return tuple(element.GetRuntimeId() or ())
        except Exception:
            return ()

    def same(self, first, second) -> bool:
        try:
            return bool(self.automation.CompareElements(first, second))
        except Exception:
            return False

    @staticmethod
    def bounds(element) -> Optional[Rect]:
        try:
            r = element.CurrentBoundingRectangle
        except Exception:
            return None
        rect = Rect(r.left, r.top, r.right - r.left, r.bottom - r.top)
        return rect if rect.is_valid else None

    def _pattern(self, element, pattern_id: int, interface):
        try:
            unknown = element.GetCurrentPattern(pattern_id)
        except Exception:
            return None
        if not unknown:
            return None
        try:
            return unknown.QueryInterface(interface)
        except Exception:
            return None

    def is_text_input(self, element) -> bool:
        try:
            control = element.CurrentControlType
        except Exception:
            return False
        if control in (UIA_EDIT_CONTROL, UIA_DOCUMENT_CONTROL):
            return True
        if self._pattern(element, UIA_TEXT_PATTERN_ID,
                         self.module.IUIAutomationTextPattern) is not None:
            return True
        value = self._pattern(element, UIA_VALUE_PATTERN_ID,
                              self.module.IUIAutomationValuePattern)
        try:
            return value is not None and not value.CurrentIsReadOnly
        except Exception:
            return False

    def caret(self, element) -> Optional[tuple[Rect, str]]:
        ranges = []
        text2 = self._pattern(element, UIA_TEXT_PATTERN2_ID,
                              self.module.IUIAutomationTextPattern2)
        if text2 is not None:
            try:
                result = text2.GetCaretRange()
                caret_range = result[1] if isinstance(result, tuple) else result
                if caret_range:
                    ranges.append(("caret range", caret_range))
            except Exception:
                pass
        if not ranges:
            text = self._pattern(element, UIA_TEXT_PATTERN_ID,
                                 self.module.IUIAutomationTextPattern)
            if text is not None:
                try:
                    selection = text.GetSelection()
                    if selection and selection.Length > 0:
                        ranges.append(("selection", selection.GetElement(0)))
                except Exception:
                    pass
        for kind, text_range in ranges:
            rect = self._range_caret(text_range)
            if rect is not None:
                return rect, kind
        return None

    def _range_caret(self, text_range) -> Optional[Rect]:
        """The caret edge of a (usually empty) range.

        An empty range has no rectangles in most providers, so the
        character after it is measured (caret = its left edge), and failing
        that the character before it (caret = its right edge, the usual
        case at the end of a line).
        """
        rect = self._first_rect(text_range)
        if rect is not None:
            return normalized_caret(Rect(rect.left, rect.top, 0, rect.height))
        try:
            after = text_range.Clone()
            after.ExpandToEnclosingUnit(TEXT_UNIT_CHARACTER)
            rect = self._first_rect(after)
            if rect is not None:
                return normalized_caret(Rect(rect.left, rect.top, 0, rect.height))
        except Exception:
            pass
        try:
            before = text_range.Clone()
            moved = before.MoveEndpointByUnit(ENDPOINT_START, TEXT_UNIT_CHARACTER, -1)
            if moved:
                rect = self._first_rect(before)
                if rect is not None:
                    return normalized_caret(Rect(rect.right, rect.top, 0, rect.height))
        except Exception:
            pass
        return None

    def field_text(self, element) -> Optional[tuple[str, Optional[int]]]:
        """The whole text of a text field and the caret's character offset.

        TextPattern first, because it also gives the caret (the length of
        the document range up to the selection start); ValuePattern for the
        plain edits that only have that, without a caret. ``None`` for a
        field whose text cannot be read, or one too large to read on every
        poll (a long document).
        """
        text = self._pattern(element, UIA_TEXT_PATTERN_ID, self.module.IUIAutomationTextPattern)
        if text is not None:
            try:
                document = text.DocumentRange
                value = document.GetText(MAX_FIELD_CHARS + 1)
            except Exception:
                value = None
            if value is not None:
                if len(value) > MAX_FIELD_CHARS:
                    return None
                caret = None
                try:
                    selection = text.GetSelection()
                    if selection and selection.Length > 0:
                        before = document.Clone()
                        before.MoveEndpointByRange(ENDPOINT_END, selection.GetElement(0),
                                                   ENDPOINT_START)
                        caret = len(before.GetText(MAX_FIELD_CHARS + 1))
                except Exception:
                    caret = None
                return value, caret
        value_pattern = self._pattern(element, UIA_VALUE_PATTERN_ID,
                                      self.module.IUIAutomationValuePattern)
        if value_pattern is not None:
            try:
                value = value_pattern.CurrentValue
            except Exception:
                return None
            if value is not None and len(value) <= MAX_FIELD_CHARS:
                return str(value), None
        return None

    @staticmethod
    def _first_rect(text_range) -> Optional[Rect]:
        try:
            values = list(text_range.GetBoundingRectangles() or ())
        except Exception:
            return None
        if len(values) < 4:
            return None
        rect = Rect(values[0], values[1], values[2], values[3])
        return rect if rect.height > 0 else None


# -- the probe -------------------------------------------------------------


class FocusProbe:
    """One thread that owns every focus/caret query and the restore.

    ``query()`` and ``capture()`` return futures; ``restore()`` blocks its
    caller (the transcription worker) for at most ``timeout`` seconds.
    """

    def __init__(self) -> None:
        self._jobs: "queue.Queue[Optional[tuple[Callable[[], Any], Future]]]" = queue.Queue()
        self._uia: Optional[_Uia] = None
        self._uia_failed = False
        # Pinned UIA elements of captured insertion targets, by token. Only
        # the most recent few are kept: one per dictation in flight.
        self._pinned: dict[int, Any] = {}
        self._next_token = 1
        self._thread = threading.Thread(target=self._run, name="focus-probe", daemon=True)
        self._thread.start()

    def close(self) -> None:
        self._jobs.put(None)

    # -- public, any thread ---------------------------------------------

    def query(self, own_pids: frozenset[int] = frozenset()) -> Future:
        return self._submit(lambda: self._query(own_pids))

    def capture(self) -> Future:
        return self._submit(self._capture)

    def restore(self, target: InsertionTarget, timeout: float = 1.5) -> RestoreOutcome:
        future = self._submit(lambda: self._restore(target))
        try:
            return future.result(timeout=timeout)
        except Exception as exc:
            log.warning("Focus restore did not finish: %s", exc)
            return (RestoreOutcome.ALREADY_THERE
                    if user32.GetForegroundWindow() == target.window
                    else RestoreOutcome.NOT_ACTIVATED)

    def read_field(self) -> Future:
        """The focused field's text and caret (a :class:`FieldSnapshot`), or None."""
        return self._submit(self._read_field)

    def release(self, target: Optional[InsertionTarget]) -> None:
        if target is not None and target.token:
            self._submit(lambda: self._pinned.pop(target.token, None))

    # -- thread -----------------------------------------------------------

    def _submit(self, work: Callable[[], Any]) -> Future:
        future: Future = Future()
        self._jobs.put((work, future))
        return future

    def _run(self) -> None:
        # AttachThreadInput needs this thread to own an input queue, and a
        # thread gets one the first time it touches the message API.
        msg = ctypes.create_string_buffer(64)
        user32.PeekMessageW(msg, None, 0, 0, PM_NOREMOVE)
        while True:
            job = self._jobs.get()
            if job is None:
                return
            work, future = job
            if not future.set_running_or_notify_cancel():
                continue
            try:
                future.set_result(work())
            except BaseException as exc:  # noqa: BLE001 — handed to the caller
                future.set_exception(exc)

    def _automation(self) -> Optional[_Uia]:
        if self._uia is None and not self._uia_failed:
            try:
                self._uia = _Uia()
            except Exception as exc:
                self._uia_failed = True
                log.warning("UI Automation unavailable, Win32 caret only: %s", exc)
        return self._uia

    def _read_field(self) -> Optional[FieldSnapshot]:
        uia = self._automation()
        if uia is None:
            return None
        element = uia.focused(0)
        if element is None:
            return None
        try:
            pid = int(element.CurrentProcessId)
            secure = bool(element.CurrentIsPassword)
        except Exception:
            return None
        if secure:
            return FieldSnapshot(uia.runtime_id(element), pid, "", None, True)
        read = uia.field_text(element)
        if read is None:
            return None
        text, caret = read
        return FieldSnapshot(uia.runtime_id(element), pid, text, caret, False)

    # -- locating ---------------------------------------------------------

    def _query(self, own_pids: frozenset[int]) -> Optional[QueryResult]:
        foreground = user32.GetForegroundWindow()
        if not foreground:
            return None
        window = user32.GetAncestor(foreground, GA_ROOT) or foreground
        pid, thread = _pid_and_thread(window)
        if pid in own_pids:
            # Our own overlay or settings: not somewhere a dictation goes.
            return None
        window_frame = _window_frame(window)
        info = _gui_thread_info(thread)
        focus_hwnd = int(info.hwndFocus or 0) if info else 0

        target: Optional[TargetFrame] = None
        detail = ""
        caret = _win32_caret(info) if info else None
        uia = self._automation()
        element = uia.focused(pid) if uia is not None else None
        element_id = uia.runtime_id(element) if element is not None else ()
        identity = TargetIdentity(pid, int(window), element_id or (focus_hwnd,))
        is_text = element is not None and uia.is_text_input(element)
        field = uia.bounds(element) if is_text else None
        if caret is not None:
            # A Win32 caret outside the window is a stale one left behind by
            # a control that lost focus without destroying it.
            if window_frame is not None and not window_frame.contains(*caret.center, slack=4):
                caret = None
            else:
                detail = "win32 caret"
        if caret is None and is_text:
            found = uia.caret(element)
            if found is not None:
                caret, detail = found[0], f"uia {found[1]}"
        if caret is not None:
            area = work_area(*caret.center)
            anchor = caret
            if field is not None and is_reasonable_field(field, caret, area):
                anchor = visual_frame(field, caret, area)
            target = TargetFrame(caret, anchor, detail, identity)
        elif field is not None:
            area = work_area(*field.center)
            if is_reasonable_field(field, field, area):
                target = TargetFrame(field, field, "uia text element", identity)
                detail = "uia text element"
        return QueryResult(pid, _process_name(pid), int(window), window_frame,
                           target, detail or "no caret")

    def _capture(self) -> Optional[InsertionTarget]:
        foreground = user32.GetForegroundWindow()
        if not foreground:
            return None
        window = user32.GetAncestor(foreground, GA_ROOT) or foreground
        pid, thread = _pid_and_thread(window)
        info = _gui_thread_info(thread)
        focus_hwnd = int(info.hwndFocus or 0) if info else 0
        token = 0
        uia = self._automation()
        element = uia.focused(pid) if uia is not None else None
        if element is not None:
            token = self._next_token
            self._next_token += 1
            self._pinned[token] = element
            while len(self._pinned) > 4:
                self._pinned.pop(next(iter(self._pinned)))
        target = InsertionTarget(int(window), focus_hwnd, pid, thread,
                                 _process_name(pid), token)
        log.info("Insertion target captured: %s pid=%d window=%#x focus=%#x uia=%s",
                 target.process, pid, target.window, focus_hwnd,
                 "yes" if token else "no")
        return target

    # -- restoring --------------------------------------------------------

    def _restore(self, target: InsertionTarget) -> RestoreOutcome:
        if not user32.IsWindow(target.window):
            log.info("Insertion target %s is gone", target.process)
            self._pinned.pop(target.token, None)
            return RestoreOutcome.TARGET_GONE
        outcome = RestoreOutcome.ALREADY_THERE
        if user32.GetAncestor(user32.GetForegroundWindow() or 0, GA_ROOT) != target.window:
            if not self._activate(target.window):
                log.warning("Could not bring %s back to the foreground", target.process)
                return RestoreOutcome.NOT_ACTIVATED
            outcome = RestoreOutcome.RESTORED
        if self._refocus(target):
            outcome = RestoreOutcome.RESTORED
        if outcome is RestoreOutcome.RESTORED:
            # The app handles WM_SETFOCUS/activation asynchronously; a paste
            # sent in the same instant can arrive before the caret does.
            time.sleep(0.08)
            log.info("Returned to the insertion target in %s", target.process)
        self._pinned.pop(target.token, None)
        return outcome

    def _activate(self, window: int) -> bool:
        if user32.IsIconic(window):
            user32.ShowWindow(window, SW_RESTORE)
        if user32.SetForegroundWindow(window):
            return self._wait_foreground(window)
        # The foreground lock: only the process that owns the foreground,
        # or received the last input, may take it. Sharing the current
        # foreground thread's input state lifts that for this call.
        current = kernel32.GetCurrentThreadId()
        _, foreground_thread = _pid_and_thread(user32.GetForegroundWindow() or 0)
        attached = bool(foreground_thread) and foreground_thread != current and \
            user32.AttachThreadInput(current, foreground_thread, True)
        try:
            user32.BringWindowToTop(window)
            user32.SetForegroundWindow(window)
        finally:
            if attached:
                user32.AttachThreadInput(current, foreground_thread, False)
        if self._wait_foreground(window):
            return True
        # Last resort: our own (marked, hook-ignored) input makes this
        # process the one that "received the last input event".
        from . import inject

        inject.nudge_foreground_lock()
        user32.SetForegroundWindow(window)
        return self._wait_foreground(window)

    @staticmethod
    def _wait_foreground(window: int, timeout: float = 0.4) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if user32.GetAncestor(user32.GetForegroundWindow() or 0, GA_ROOT) == window:
                return True
            time.sleep(0.02)
        return False

    def _refocus(self, target: InsertionTarget) -> bool:
        """Put keyboard focus back on the captured element. True if moved."""
        uia = self._automation()
        element = self._pinned.get(target.token) if target.token else None
        if uia is not None and element is not None:
            current = uia.focused(target.pid)
            if current is not None and uia.same(current, element):
                return False
            try:
                element.SetFocus()
                return True
            except Exception as exc:
                # Browsers rebuild their accessibility tree freely; the
                # element can be gone while the field is still right there.
                log.info("Captured element no longer focusable (%s); "
                         "falling back to the Win32 focus", exc)
        if not target.focus_window or not user32.IsWindow(target.focus_window):
            return False
        info = _gui_thread_info(target.thread)
        if info is not None and int(info.hwndFocus or 0) == target.focus_window:
            return False
        current = kernel32.GetCurrentThreadId()
        if not user32.AttachThreadInput(current, target.thread, True):
            return False
        try:
            user32.SetFocus(target.focus_window)
        finally:
            user32.AttachThreadInput(current, target.thread, False)
        return True


def _shift(rect: Rect, old: Optional[Rect], new: Optional[Rect]) -> Rect:
    if old is None or new is None:
        return rect
    return rect.offset(new.left - old.left, new.top - old.top)


class TargetCache:
    """insertionTargetCache: the last good target per app, for ten minutes.

    Some fields only report a caret while something is happening in them;
    the cache keeps the capsule at the field the user was just typing in,
    moved along with its window if that has moved since.
    """

    MAX_AGE = 10 * 60

    def __init__(self) -> None:
        self._entries: dict[int, tuple[TargetFrame, Optional[Rect], float]] = {}

    def store(self, target: TargetFrame, window_frame: Optional[Rect]) -> None:
        self._entries[target.identity.pid] = (target, window_frame, time.monotonic())

    def lookup(self, result: QueryResult) -> Optional[TargetFrame]:
        entry = self._entries.get(result.pid)
        if entry is None:
            return None
        target, old_window, stored_at = entry
        if time.monotonic() - stored_at > self.MAX_AGE:
            self._entries.pop(result.pid, None)
            return None
        if target.identity.window != result.window:
            return None
        frame = _shift(target.frame, old_window, result.window_frame)
        visual = _shift(target.visual_frame, old_window, result.window_frame)
        if result.window_frame is not None:
            grown = Rect(result.window_frame.left - 80, result.window_frame.top - 80,
                         result.window_frame.width + 160, result.window_frame.height + 160)
            if not grown.intersects(visual):
                return None
        return replace(target, frame=frame, visual_frame=visual,
                       kind=f"{target.kind} cache")
