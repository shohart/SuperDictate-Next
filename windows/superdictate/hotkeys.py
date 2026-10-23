"""Global hotkey capture via a low-level Windows keyboard hook.

macOS uses a ``CGEventTap`` on keyDown/keyUp/flagsChanged and diffs the
modifier flags, because Right Command never produces a keyDown. Windows'
``WH_KEYBOARD_LL`` is friendlier: it reports explicit down/up events and
already separates left from right modifiers (``VK_LCONTROL`` vs
``VK_RCONTROL``), so the flag-diffing disappears while the surrounding
state machine stays a faithful port of ``HotkeyShortcutState`` /
``HotkeyTransitionState`` from ``main.swift``.

The hook lives on its own thread with a private message loop. Putting it
on the Qt thread would work (Qt pumps messages) but a slow repaint would
blow the ``LowLevelHooksTimeout`` budget and Windows would silently evict
the hook. The callback therefore only mutates the state machine and posts
actions to a queue; all real work happens on the Qt side.
"""

from __future__ import annotations

import ctypes
import ctypes.wintypes as wt
import threading
import time
from collections import deque
from dataclasses import dataclass, field
from enum import Enum
from typing import Callable, Iterable, Optional

user32 = ctypes.WinDLL("user32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

WH_KEYBOARD_LL = 13
WM_KEYDOWN = 0x0100
WM_KEYUP = 0x0101
WM_SYSKEYDOWN = 0x0104
WM_SYSKEYUP = 0x0105
LLKHF_INJECTED = 0x00000010
HC_ACTION = 0

# On a layout with AltGr (Russian is one, US English is not) Windows turns
# every Right Alt press into "Left Ctrl + Right Alt": a Left Ctrl down is
# synthesised just before Right Alt goes down, and its up just after Right
# Alt goes up. That Ctrl is not a key anybody pressed. Counted as one, it
# made Right Alt record as "Ctrl + Alt", and a Right Alt shortcut work in
# English and not in Russian. The low-level hook tells it apart by this
# scan code, a real Left Ctrl is 0x1D; window messages lose the high bit,
# so they get the timestamp instead (``is_altgr_phantom_time``).
ALTGR_PHANTOM_SCAN = 0x21D

# Modifier bit mask. Deliberately side-agnostic, mirroring the way macOS
# stores `requiredModifiers` as CGEventFlags while the primary key stays
# side-specific: "Right Shift + Right Alt" requires *a* shift, but the
# primary key must be the right-hand Alt.
MOD_CTRL = 1 << 0
MOD_ALT = 1 << 1
MOD_SHIFT = 1 << 2
MOD_WIN = 1 << 3
MOD_ALL = MOD_CTRL | MOD_ALT | MOD_SHIFT | MOD_WIN

VK_LSHIFT, VK_RSHIFT = 0xA0, 0xA1
VK_LCONTROL, VK_RCONTROL = 0xA2, 0xA3
VK_LMENU, VK_RMENU = 0xA4, 0xA5
VK_LWIN, VK_RWIN = 0x5B, 0x5C
VK_ESCAPE = 0x1B

MODIFIER_VK_FLAG: dict[int, int] = {
    VK_LSHIFT: MOD_SHIFT,
    VK_RSHIFT: MOD_SHIFT,
    VK_LCONTROL: MOD_CTRL,
    VK_RCONTROL: MOD_CTRL,
    VK_LMENU: MOD_ALT,
    VK_RMENU: MOD_ALT,
    VK_LWIN: MOD_WIN,
    VK_RWIN: MOD_WIN,
}


@dataclass(frozen=True)
class HotkeyChoice:
    """A key plus the modifiers that must be held with it."""

    vk: int
    modifiers: int = 0

    @property
    def is_modifier(self) -> bool:
        return self.vk in MODIFIER_VK_FLAG

    @property
    def modifier_flag(self) -> Optional[int]:
        return MODIFIER_VK_FLAG.get(self.vk)

    def to_json(self) -> dict:
        return {"vk": self.vk, "modifiers": self.modifiers}

    @staticmethod
    def from_json(raw: object, fallback: "HotkeyChoice") -> "HotkeyChoice":
        if not isinstance(raw, dict):
            return fallback
        try:
            vk = int(raw["vk"])
            modifiers = int(raw.get("modifiers", 0)) & MOD_ALL
        except (KeyError, TypeError, ValueError):
            return fallback
        if not 1 <= vk <= 0xFE or vk == VK_ESCAPE:
            return fallback
        # A modifier cannot require its own side-agnostic flag: "Right
        # Ctrl + Ctrl" is not a chord, it is the same physical key.
        flag = MODIFIER_VK_FLAG.get(vk)
        if flag is not None:
            modifiers &= ~flag
        return HotkeyChoice(vk, modifiers)


DEFAULT_HOTKEY = HotkeyChoice(VK_RCONTROL)
# A chord built on Right Ctrl only works if the modifier is held first:
# Right Ctrl starts a dictation the instant it goes down, and once it has,
# the modifier arriving afterwards completes a chord whose primary key has
# already fired. With Shift that is no constraint — nobody presses a key
# and reaches for Shift afterwards — which is why quick history has always
# worked. With Alt it is fatal, since "Ctrl + Alt" is taken in that order
# as often as not, so the editor sits on a primary key that does nothing
# by itself and works pressed either way round.
DEFAULT_HISTORY_HOTKEY = HotkeyChoice(VK_RCONTROL, MOD_SHIFT)
DEFAULT_EDIT_HOTKEY = HotkeyChoice(VK_RMENU, MOD_SHIFT)
# Post-processing shortcuts. Three constraints ruled out the obvious
# choices, in this order:
#
#  * The macOS build puts these on F13/F14 — keys a Mac keyboard has and
#    almost no PC keyboard does, so copying them ships a default nobody can
#    press.
#  * Anything built on the right-hand modifiers collides with the shortcuts
#    already here: dictation is bare Right Ctrl, history is Shift + Right
#    Ctrl, the editor is Shift + Right Alt. A chord sharing those keys is
#    answered by whichever is tried first, and the self-tests caught exactly
#    that.
#  * Alt+Shift and Ctrl+Shift are how Windows switches keyboard layout.
#    Taking either from somebody who types in two languages is not a
#    trade worth making for a shortcut they press a few times a day.
#
# Ctrl+Alt+letter is what is left, and it is safe here for a reason worth
# stating: dictation listens for the RIGHT Ctrl specifically, so pressing
# Left Ctrl to start this chord cannot begin a recording. All three are
# rebindable.
VK_C = 0x43
VK_R = 0x52
VK_S = 0x53
DEFAULT_CORRECTION_HOTKEY = HotkeyChoice(VK_C, MOD_CTRL | MOD_ALT)
DEFAULT_REWRITE_HOTKEY = HotkeyChoice(VK_R, MOD_CTRL | MOD_ALT)
DEFAULT_REWRITE_STYLE_HOTKEY = HotkeyChoice(VK_S, MOD_CTRL | MOD_ALT)
# The alternate finish ("enterHotkey" on macOS, Right Command + Option
# there): pressed while a recording runs, it ends it and finishes the other
# way -- pastes and presses Enter when the primary shortcut only pastes, and
# the reverse. Built on the dictation key, like the macOS default, so it is
# the same key with one modifier more.
DEFAULT_ENTER_HOTKEY = HotkeyChoice(VK_RCONTROL, MOD_ALT)


class TriggerMode(str, Enum):
    HOLD = "hold"
    TOGGLE = "toggle"


class Action(str, Enum):
    PRESS = "press"
    RELEASE = "release"
    # Ends the recording with the opposite completion behaviour
    # (macOS .releaseAlternate).
    RELEASE_ALTERNATE = "release_alternate"
    CANCEL = "cancel"
    SHOW_HISTORY = "show_history"
    SHOW_EDITOR = "show_editor"
    # Post-processing, all three driven from the keyboard because that is
    # where dictation happens: reaching for a settings window to turn
    # correction off for one sentence costs more than the correction saves.
    TOGGLE_CORRECTION = "toggle_correction"
    TOGGLE_REWRITE = "toggle_rewrite"
    CYCLE_REWRITE_STYLE = "cycle_rewrite_style"
    REJECTED_BUSY_PRESS = "rejected_busy_press"


class _Edge(str, Enum):
    PRESS = "press"
    RELEASE = "release"
    SUPPRESS = "suppress"
    PASS = "pass"


@dataclass
class _Event:
    vk: int
    is_down: bool
    modifiers: int  # full modifier mask *after* applying this event
    is_repeat: bool = False


@dataclass
class _Result:
    suppress: bool = False
    actions: list[Action] = field(default_factory=list)


_PASS = _Result(False, [])


def _suppress_only() -> _Result:
    return _Result(True, [])


@dataclass
class _Consumed:
    """What a shortcut made of an event, and whether to eat the event.

    These are two different questions and conflating them is what made an
    early build swallow every Shift press: the editor chord requires
    Shift, so Shift "belonged" to a shortcut and was suppressed even when
    the chord never completed. A modifier must always reach the
    foreground app, only the chord's primary key is ever eaten.
    """

    edge: _Edge
    suppress: bool = False


_CONSUMED_PASS = _Consumed(_Edge.PASS, False)


class _ShortcutState:
    """Port of ``HotkeyShortcutState`` from main.swift."""

    def __init__(self) -> None:
        self.primary_down = False
        self.shortcut_down = False
        self.suppressing_chord_release = False

    @property
    def is_engaged(self) -> bool:
        return self.primary_down or self.shortcut_down or self.suppressing_chord_release

    def reset(self) -> None:
        self.primary_down = False
        self.shortcut_down = False
        self.suppressing_chord_release = False

    def consume(self, event: _Event, shortcut: HotkeyChoice) -> _Consumed:
        if not shortcut.is_modifier:
            # A plain key (F13, Pause…): it is its own primary, so every
            # edge that belongs to the shortcut is safe to eat.
            if event.vk != shortcut.vk:
                return _CONSUMED_PASS
            if event.is_down:
                if event.is_repeat:
                    return (_Consumed(_Edge.SUPPRESS, True) if self.shortcut_down
                            else _CONSUMED_PASS)
                if (event.modifiers & MOD_ALL) != shortcut.modifiers:
                    return _CONSUMED_PASS
                self.shortcut_down = True
                return _Consumed(_Edge.PRESS, True)
            if self.shortcut_down:
                self.shortcut_down = False
                return _Consumed(_Edge.RELEASE, True)
            return _CONSUMED_PASS

        primary_mask = shortcut.modifier_flag
        assert primary_mask is not None

        event_flag = MODIFIER_VK_FLAG.get(event.vk)
        is_required_modifier_event = bool(event_flag and (shortcut.modifiers & event_flag))
        if event.vk != shortcut.vk and not is_required_modifier_event:
            return _CONSUMED_PASS

        # Only the primary key is ever eaten. Suppressing a required
        # modifier would break it system-wide: with the editor on
        # "Shift + Right Alt", eating Shift costs the user every capital
        # letter and every Shift-click.
        is_primary = event.vk == shortcut.vk

        if self.suppressing_chord_release:
            all_modifiers = shortcut.modifiers | primary_mask
            if is_primary:
                self.primary_down = False
            if not (event.modifiers & all_modifiers):
                self.suppressing_chord_release = False
                self.primary_down = False
                self.shortcut_down = False
            return _Consumed(_Edge.SUPPRESS, is_primary)

        if is_primary:
            self.primary_down = event.is_down

        expected = shortcut.modifiers | primary_mask
        requirements_met = (event.modifiers & MOD_ALL) == expected
        is_now_down = self.primary_down and requirements_met

        if is_now_down and not self.shortcut_down:
            self.shortcut_down = True
            return _Consumed(_Edge.PRESS, is_primary)
        if self.shortcut_down and not is_now_down:
            # The chord can break by releasing either part; the edge fires
            # either way, but only a primary release is swallowed.
            self.shortcut_down = False
            self.suppressing_chord_release = shortcut.modifiers != 0
            return _Consumed(_Edge.RELEASE, is_primary)
        if self.shortcut_down and is_primary:
            return _Consumed(_Edge.SUPPRESS, True)
        return _CONSUMED_PASS


class HotkeyStateMachine:
    """Port of ``HotkeyTransitionState``.

    Pure logic, no Windows API, the self-tests drive it directly.
    """

    def __init__(self) -> None:
        self._standard = _ShortcutState()
        self._history = _ShortcutState()
        self._edit = _ShortcutState()
        self._correction = _ShortcutState()
        self._rewrite = _ShortcutState()
        self._rewrite_style = _ShortcutState()
        self._enter = _ShortcutState()
        self._toggle_active = False
        self._suppress_escape_up = False
        self._was_recording = False

    def reset_all(self) -> None:
        self._standard.reset()
        self._history.reset()
        self._edit.reset()
        self._correction.reset()
        self._rewrite.reset()
        self._rewrite_style.reset()
        self._enter.reset()
        self._toggle_active = False
        self._suppress_escape_up = False
        self._was_recording = False

    def reset_toggle(self) -> None:
        self._toggle_active = False

    def transition(
        self,
        event: _Event,
        *,
        hotkey: HotkeyChoice,
        trigger_mode: TriggerMode,
        is_recording: bool,
        can_start_recording: bool = True,
        history_hotkey: HotkeyChoice = DEFAULT_HISTORY_HOTKEY,
        edit_hotkey: Optional[HotkeyChoice] = DEFAULT_EDIT_HOTKEY,
        correction_hotkey: HotkeyChoice = DEFAULT_CORRECTION_HOTKEY,
        rewrite_hotkey: HotkeyChoice = DEFAULT_REWRITE_HOTKEY,
        rewrite_style_hotkey: HotkeyChoice = DEFAULT_REWRITE_STYLE_HOTKEY,
        enter_hotkey: Optional[HotkeyChoice] = None,
    ) -> _Result:
        # Recording-start edge (macOS adoptPrimaryModifierDown): an
        # alternate finish built on the dictation key itself has that key
        # down already -- pressing it is what started the recording -- but
        # its state only listens while recording, so it never saw the
        # press. Adopted here, the first modifier pressed mid-recording can
        # complete the chord. Harmless when the key is up by now: the chord
        # still needs the real modifier state to match.
        if (is_recording and not self._was_recording and enter_hotkey is not None
                and hotkey.is_modifier and enter_hotkey.vk == hotkey.vk):
            self._enter.primary_down = True
        self._was_recording = is_recording

        if event.vk == VK_ESCAPE:
            return self._transition_escape(event, is_recording)

        if enter_hotkey is not None and (is_recording or self._enter.is_engaged):
            finished = self._transition_enter(event, is_recording, enter_hotkey)
            if finished is not None:
                return finished

        # The chords are tried before the bare dictation key, and this is
        # not a nicety: quick history is built on the dictation key itself,
        # so whichever is asked first answers for both. Each returns None
        # when the event was not its.
        for state, shortcut, action in (
            (self._history, history_hotkey, Action.SHOW_HISTORY),
            (self._edit, edit_hotkey, Action.SHOW_EDITOR),
            # More specific chords first: the style shortcut carries one
            # modifier more than the rewrite toggle and shares its key, so
            # asking the toggle first would answer for both.
            (self._rewrite_style, rewrite_style_hotkey, Action.CYCLE_REWRITE_STYLE),
            (self._rewrite, rewrite_hotkey, Action.TOGGLE_REWRITE),
            (self._correction, correction_hotkey, Action.TOGGLE_CORRECTION),
        ):
            if shortcut is None:
                continue  # not assigned
            handled = self._transition_chord(
                state, event, is_recording, shortcut, action)
            if handled is not None:
                return handled

        consumed = self._standard.consume(event, hotkey)
        if consumed.edge == _Edge.PASS:
            return _PASS

        if trigger_mode == TriggerMode.HOLD:
            actions: list[Action] = []
            if consumed.edge == _Edge.PRESS:
                actions.append(Action.PRESS)
            elif consumed.edge == _Edge.RELEASE:
                actions.append(Action.RELEASE)
            return _Result(consumed.suppress, actions)

        # Toggle: every press flips, releases are no-ops.
        if consumed.edge != _Edge.PRESS:
            return _Result(consumed.suppress, [])
        if self._toggle_active:
            self._toggle_active = False
            return _Result(consumed.suppress, [Action.RELEASE])
        if not can_start_recording:
            # A press the app would reject must not flip the toggle,
            # otherwise the next press emits a discarded .release and
            # only the third press records.
            return _Result(consumed.suppress, [Action.REJECTED_BUSY_PRESS])
        self._toggle_active = True
        return _Result(consumed.suppress, [Action.PRESS])

    def _transition_enter(self, event: _Event, is_recording: bool,
                          enter_hotkey: HotkeyChoice) -> Optional[_Result]:
        """The alternate finish: only while recording (or finishing a chord
        it started), so outside a recording its keys belong to everything
        else. ``None`` when the event was not its."""
        consumed = self._enter.consume(event, enter_hotkey)
        if consumed.edge == _Edge.PRESS and is_recording:
            self._standard.reset()
            self._toggle_active = False
            return _Result(consumed.suppress, [Action.RELEASE_ALTERNATE])
        if consumed.edge != _Edge.PASS and consumed.suppress:
            return _suppress_only()
        return None

    def _transition_chord(
        self, state: _ShortcutState, event: _Event, is_recording: bool,
        shortcut: HotkeyChoice, action: Action,
    ) -> Optional[_Result]:
        """A shortcut that fires on the press alone, with no release edge.

        Returns ``None`` when the event was not its, so the caller can
        offer it to the dictation shortcut and then to the app.
        """
        consumed = state.consume(event, shortcut)
        if consumed.edge == _Edge.PRESS:
            self._standard.reset()
            if not is_recording:
                self._toggle_active = False
            return _Result(consumed.suppress, [action])
        if consumed.edge in (_Edge.RELEASE, _Edge.SUPPRESS) and consumed.suppress:
            return _suppress_only()
        # Anything not actually eaten (a bare modifier, above all) must
        # fall through to the dictation shortcut and then to the app.
        return None

    def _transition_escape(self, event: _Event, is_recording: bool) -> _Result:
        if event.is_down:
            if event.is_repeat and self._suppress_escape_up:
                return _suppress_only()
            if not is_recording:
                return _PASS
            self._suppress_escape_up = True
            return _suppress_only() if event.is_repeat else _Result(True, [Action.CANCEL])
        if self._suppress_escape_up:
            self._suppress_escape_up = False
            return _suppress_only()
        return _PASS


def is_altgr_phantom(vk: int, scan_code: int) -> bool:
    return vk == VK_LCONTROL and scan_code == ALTGR_PHANTOM_SCAN


# Timestamps of recent phantom Ctrl events, as the hook saw them. A window
# message carries the same time (``GetMessageTime``), which is how the
# shortcut recorder recognises the phantom among its own messages.
_phantom_times: "deque[int]" = deque(maxlen=16)
_phantom_lock = threading.Lock()


def note_altgr_phantom_time(timestamp: int) -> None:
    with _phantom_lock:
        _phantom_times.append(timestamp)


def is_altgr_phantom_time(timestamp: int) -> bool:
    with _phantom_lock:
        return timestamp in _phantom_times


def held_modifier_mask(is_held: Callable[[int], bool], *, phantom_ctrl_down: bool,
                       real_lctrl_down: bool) -> int:
    """The side-agnostic mask of what is held, the AltGr Ctrl taken out.

    Windows' own key state counts the phantom Left Ctrl as held, so while
    it is down Left Ctrl only counts if the hook saw a real press of it.
    """
    mask = 0
    for vk, flag in MODIFIER_VK_FLAG.items():
        if vk == VK_LCONTROL and phantom_ctrl_down:
            held = real_lctrl_down
        else:
            held = is_held(vk)
        if held:
            mask |= flag
    return mask


class KBDLLHOOKSTRUCT(ctypes.Structure):
    _fields_ = [
        ("vkCode", wt.DWORD),
        ("scanCode", wt.DWORD),
        ("flags", wt.DWORD),
        ("time", wt.DWORD),
        # ULONG_PTR, carried by value, see INJECTED_MARKER below.
        ("dwExtraInfo", ctypes.c_size_t),
    ]


HOOKPROC = ctypes.WINFUNCTYPE(
    ctypes.c_ssize_t, ctypes.c_int, wt.WPARAM, ctypes.POINTER(KBDLLHOOKSTRUCT)
)

user32.SetWindowsHookExW.restype = wt.HHOOK
user32.SetWindowsHookExW.argtypes = [ctypes.c_int, HOOKPROC, wt.HINSTANCE, wt.DWORD]
user32.CallNextHookEx.restype = ctypes.c_ssize_t
user32.CallNextHookEx.argtypes = [
    wt.HHOOK,
    ctypes.c_int,
    wt.WPARAM,
    ctypes.POINTER(KBDLLHOOKSTRUCT),
]
user32.UnhookWindowsHookEx.argtypes = [wt.HHOOK]
user32.SetTimer.restype = ctypes.c_size_t
user32.SetTimer.argtypes = [wt.HWND, ctypes.c_size_t, wt.UINT, ctypes.c_void_p]
user32.KillTimer.argtypes = [wt.HWND, ctypes.c_size_t]
kernel32.GetCurrentThread.restype = wt.HANDLE
kernel32.SetThreadPriority.argtypes = [wt.HANDLE, ctypes.c_int]

WM_TIMER = 0x0113
THREAD_PRIORITY_HIGHEST = 2
#: How often the keyboard hook is re-installed; see HotkeyListener._run.
HOOK_REFRESH_SECONDS = 30.0
# Undeclared, ctypes would return a c_int and the 0x8000 "held" bit of the
# c_short result could not be tested reliably.
user32.GetAsyncKeyState.argtypes = [ctypes.c_int]
user32.GetAsyncKeyState.restype = ctypes.c_short

# Marker written into dwExtraInfo of every event SendInput generates on
# our behalf, so the hook can tell our synthetic Ctrl+V apart from a real
# one even when another tool clears LLKHF_INJECTED.
INJECTED_MARKER = 0x5D1C7A7E


class HotkeyListener:
    """Owns the hook thread and hands decoded actions to a callback."""

    def __init__(self, on_actions: Callable[[Iterable[Action]], None]) -> None:
        self._on_actions = on_actions
        self._machine = HotkeyStateMachine()
        self._down_keys: set[int] = set()
        self._phantom_ctrl_down = False
        self._thread: Optional[threading.Thread] = None
        self._thread_id: int = 0
        self._hook = None
        self._proc = HOOKPROC(self._callback)
        self._lock = threading.Lock()
        self._running = False

        # Live configuration, updated from the Qt thread.
        self.hotkey = DEFAULT_HOTKEY
        self.history_hotkey = DEFAULT_HISTORY_HOTKEY
        self.edit_hotkey = DEFAULT_EDIT_HOTKEY
        self.correction_hotkey = DEFAULT_CORRECTION_HOTKEY
        self.rewrite_hotkey = DEFAULT_REWRITE_HOTKEY
        self.rewrite_style_hotkey = DEFAULT_REWRITE_STYLE_HOTKEY
        #: None turns the alternate finish off.
        self.enter_hotkey: Optional[HotkeyChoice] = DEFAULT_ENTER_HOTKEY
        self.trigger_mode = TriggerMode.TOGGLE
        self.is_recording_active: Callable[[], bool] = lambda: False
        self.can_start_recording: Callable[[], bool] = lambda: True
        # While the shortcut recorder window is open the listener stays
        # installed but stops acting, mirroring the macOS behaviour where
        # keys only record a new shortcut and never start dictation.
        self.paused = False

    # -- lifecycle ---------------------------------------------------

    def start(self) -> None:
        if self._thread is not None:
            return
        self._running = True
        self._thread = threading.Thread(target=self._run, name="hotkey-hook", daemon=True)
        self._thread.start()
        for _ in range(200):  # ~2s
            if self._hook:
                return
            time.sleep(0.01)

    def stop(self) -> None:
        self._running = False
        if self._thread_id:
            user32.PostThreadMessageW(self._thread_id, 0x0012, 0, 0)  # WM_QUIT
        if self._thread:
            self._thread.join(timeout=2.0)
        self._thread = None

    @property
    def installed(self) -> bool:
        return bool(self._hook)

    def reset_state(self) -> None:
        with self._lock:
            self._machine.reset_all()
            self._down_keys.clear()
            self._phantom_ctrl_down = False

    def reset_toggle(self) -> None:
        with self._lock:
            self._machine.reset_toggle()

    # -- internals ---------------------------------------------------

    def _run(self) -> None:
        self._thread_id = kernel32.GetCurrentThreadId()
        # The callback has to answer within LowLevelHooksTimeout or Windows
        # removes the hook, silently and for good. When every core is busy
        # (a background NPU compile in SuperDictateOvHost takes minutes) a
        # normal-priority thread can miss that deadline, after which the
        # shortcut is dead until the app restarts. So the hook thread runs
        # at high priority -- it only ever wakes for a keystroke -- and...
        kernel32.SetThreadPriority(kernel32.GetCurrentThread(), THREAD_PRIORITY_HIGHEST)
        self._hook = user32.SetWindowsHookExW(WH_KEYBOARD_LL, self._proc, None, 0)
        if not self._hook:
            return
        # ...the hook is re-installed every HOOK_REFRESH_SECONDS, because an
        # eviction cannot be detected: the new hook goes in first, then the
        # old one comes out, so no keystroke falls between the two.
        timer = user32.SetTimer(None, 0, int(HOOK_REFRESH_SECONDS * 1000), None)
        msg = wt.MSG()
        while self._running and user32.GetMessageW(ctypes.byref(msg), None, 0, 0) > 0:
            if msg.message == WM_TIMER and not msg.hWnd:
                self._refresh_hook()
                continue
            user32.TranslateMessage(ctypes.byref(msg))
            user32.DispatchMessageW(ctypes.byref(msg))
        if timer:
            user32.KillTimer(None, timer)
        if self._hook:
            user32.UnhookWindowsHookEx(self._hook)
            self._hook = None

    def _refresh_hook(self) -> None:
        fresh = user32.SetWindowsHookExW(WH_KEYBOARD_LL, self._proc, None, 0)
        if not fresh:
            return  # keep the one we have; try again next time
        stale, self._hook = self._hook, fresh
        if stale:
            user32.UnhookWindowsHookEx(stale)

    def _modifier_mask(self, event_vk: int, event_is_down: bool) -> int:
        """What is held right now, asked of Windows rather than remembered.

        An accumulated set only knows what the hook was shown, and it is
        shown less than everything: it starts blind to keys already held
        when it installs, it deliberately skips its own injected releases,
        and a hook earlier in the chain can eat an event outright. Once the
        set drifts, the state machine suppresses a key-up whose key-down it
        never suppressed, and the foreground app is left believing the key
        is still down. That is the "a key is stuck and nothing types" bug.

        The event being processed is applied on top: the low-level hook
        runs before Windows updates its own key state, so GetAsyncKeyState
        does not report this keystroke yet.
        """
        def is_held(vk: int) -> bool:
            if vk == event_vk:
                return event_is_down
            return bool(user32.GetAsyncKeyState(vk) & 0x8000)

        return held_modifier_mask(
            is_held, phantom_ctrl_down=self._phantom_ctrl_down,
            real_lctrl_down=(event_is_down if event_vk == VK_LCONTROL
                             else VK_LCONTROL in self._down_keys))

    def _callback(self, code: int, wparam: int, lparam) -> int:
        if code != HC_ACTION:
            return user32.CallNextHookEx(None, code, wparam, lparam)

        info = lparam[0]
        # Never react to our own SendInput traffic, or the paste's Ctrl
        # would re-enter the state machine and cancel the dictation that
        # triggered it. Only *our* events are filtered, identified by the
        # marker: a blanket LLKHF_INJECTED test would also deafen us to
        # AutoHotkey remaps, Remote Desktop, the on-screen keyboard and
        # keyboard macro software, all of which are legitimate input.
        if info.dwExtraInfo == INJECTED_MARKER:
            return user32.CallNextHookEx(None, code, wparam, lparam)

        vk = info.vkCode
        is_down = wparam in (WM_KEYDOWN, WM_SYSKEYDOWN)

        if is_altgr_phantom(vk, info.scanCode):
            # Not a key press: invisible to the shortcuts, untouched for
            # the app, which needs it to type AltGr characters.
            note_altgr_phantom_time(info.time)
            with self._lock:
                self._phantom_ctrl_down = is_down
            return user32.CallNextHookEx(None, code, wparam, lparam)

        with self._lock:
            is_repeat = is_down and vk in self._down_keys
            if is_down:
                self._down_keys.add(vk)
            else:
                self._down_keys.discard(vk)
            if self.paused:
                return user32.CallNextHookEx(None, code, wparam, lparam)

            event = _Event(vk=vk, is_down=is_down,
                           modifiers=self._modifier_mask(vk, is_down),
                           is_repeat=is_repeat)
            try:
                result = self._machine.transition(
                    event,
                    hotkey=self.hotkey,
                    history_hotkey=self.history_hotkey,
                    edit_hotkey=self.edit_hotkey,
                    correction_hotkey=self.correction_hotkey,
                    rewrite_hotkey=self.rewrite_hotkey,
                    rewrite_style_hotkey=self.rewrite_style_hotkey,
                    enter_hotkey=self.enter_hotkey,
                    trigger_mode=self.trigger_mode,
                    is_recording=self.is_recording_active(),
                    can_start_recording=self.can_start_recording(),
                )
            except Exception:  # a raising hook is an evicted hook
                return user32.CallNextHookEx(None, code, wparam, lparam)

        if result.actions:
            try:
                self._on_actions(result.actions)
            except Exception:
                pass

        if result.suppress:
            return 1
        return user32.CallNextHookEx(None, code, wparam, lparam)
