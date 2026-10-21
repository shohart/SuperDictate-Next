"""The floating recording capsule.

A port of the macOS ``RecordingHUDView`` (HUDViews.swift) and the panel
logic around it in ParakeyApp.swift, drawing for drawing:

* **Reveal.** The capsule grows out of a 6 px dot with a slight overshoot,
  the fill fading in ahead of the content; hiding plays the same timeline
  backwards. Nothing fades the window itself.
* **Recording.** Eight bars under a cosine envelope, an idle travelling
  murmur plus the voice level; the capsule itself breathes with the voice.
  In timer mode the bars cross over, after ten seconds, into a perimeter
  level meter with the elapsed MM:SS in the middle.
* **Transcribing.** The bars resolve left to right from the recording
  colour into the transcribing colour, then loop a reverse pulse.
* **Correcting.** (LLM correction or rewrite.) A luminous front sweeps
  left to right and re-forms the wave behind it into a gradient from the
  transcribing colour to the correcting colour, white-hot at the crossing.
* **Error.** A yellow exclamation mark, for a moment.
* **Background.** Light, dark or following the Windows app theme; the
  ``contrast`` colour is black on light and white on dark.

Placement follows the macOS rules: just above the line the caret is on
(the text field's left edge, so it does not drift right while you type),
below it when there is no room above, inside the lower-left of the window
when no caret can be found, and at the top centre of the screen when there
is not even a window. While recording it keeps following the caret, gliding
for small moves and fading out and back in for a jump to another field.

Two Windows-specific requirements shape the window:

* **It must never take focus.** The paste goes to whatever window the
  user was typing in, so the HUD carries ``WS_EX_NOACTIVATE`` and
  ``WS_EX_TRANSPARENT``: clicks fall through to the app underneath and
  focus never moves.
* **It must not appear in the taskbar or Alt+Tab.** ``Qt.Tool`` plus
  ``WS_EX_TOOLWINDOW`` handles that.
"""

from __future__ import annotations

import ctypes
import ctypes.wintypes as wt
import math
import os
import time
from dataclasses import dataclass
from typing import Optional

from PySide6.QtCore import (
    Property,
    QEasingCurve,
    QPoint,
    QPointF,
    QPropertyAnimation,
    QRect,
    QRectF,
    QSize,
    Qt,
    QTimer,
    Signal,
)
from PySide6.QtGui import (
    QColor,
    QFont,
    QPainter,
    QPainterPath,
    QPen,
)
from PySide6.QtWidgets import QApplication, QWidget

from .. import focus_target
from ..focus_target import QueryResult, Rect, TargetCache, TargetFrame, TargetStabilizer
from ..logging_setup import get as get_logger
from ..settings import (
    AccentColor,
    ColorSpec,
    HUDBackgroundStyle,
    HUDDisplayMode,
    HUDSize,
)
from . import icons

log = get_logger("hud")

# -- constants (Constants.swift) -------------------------------------------

BASE_WIDTH = 64.0
BASE_HEIGHT = 38.0
ANIMATE_IN_SECONDS = 0.32
ANIMATE_OUT_SECONDS = 0.23
TRANSCRIBING_RESOLVE_SECONDS = 0.20
TRANSCRIBING_MIN_VISIBLE_SECONDS = 0.24
TARGET_REFRESH_INTERVAL_MS = 160
TARGET_FOLLOW_RESPONSE = 22.0
# How long the capsule waits for the first caret lookup before appearing
# anyway, at the fallback spot. The lookup normally answers in a few ms.
INITIAL_TARGET_WAIT_MS = 220
RECORDING_BASE_PHASE_SPEED = 16.96
RECORDING_LEVEL_PHASE_SPEED = 10.08
TRANSCRIBING_PHASE_SPEED = 10.2
CORRECTING_PHASE_SPEED = 6.4
CORRECTING_SWEEP_RADIANS = 20.48
ERROR_FLASH_MS = 1500
FRAME_INTERVAL_MS = 8  # paced by dt, so this is only the ceiling (~120 fps)
BOTTOM_MARGIN = 24
# Timer mode. The capsule opens as level bars whatever the setting says and
# only becomes a timer once the dictation has run long enough to be worth
# timing: ten seconds, then a half-second crossover, as on macOS.
TIMER_ACTIVATION_SECONDS = 10.0
TIMER_TRANSITION_SECONDS = 0.5
BAR_COUNT = 8
# How long the outcome glyph stays up after a dictation that produced
# nothing, and how often the cursor is checked against the capsule.
RESULT_HOLD_MS = 3600
HOVER_POLL_MS = 120
RESULT_COLOR = "#ffffff"
ERROR_YELLOW = QColor(255, 204, 0)

user32 = ctypes.WinDLL("user32", use_last_error=True)
# The HWND argument must be declared, or ctypes passes it as a c_int.
user32.GetWindowLongW.argtypes = [wt.HWND, ctypes.c_int]
user32.GetWindowLongW.restype = wt.LONG
user32.SetWindowLongW.argtypes = [wt.HWND, ctypes.c_int, wt.LONG]
user32.SetWindowLongW.restype = wt.LONG
GWL_EXSTYLE = -20
WS_EX_NOACTIVATE = 0x08000000
WS_EX_TRANSPARENT = 0x00000020
WS_EX_TOOLWINDOW = 0x00000080


def format_elapsed(seconds: float) -> str:
    """MM:SS, matching the macOS readout (which never rolls over to hours)."""
    total = max(0, int(seconds))
    return f"{total // 60:02d}:{total % 60:02d}"


def phase_speed(mode: str, level: float) -> float:
    """recordingHUDPhaseSpeed, in radians per second."""
    if mode == "recording":
        return RECORDING_BASE_PHASE_SPEED + max(0.0, min(1.0, level)) * RECORDING_LEVEL_PHASE_SPEED
    if mode == "transcribing":
        return TRANSCRIBING_PHASE_SPEED
    if mode == "correcting":
        return CORRECTING_PHASE_SPEED
    return 0.0


def smoothstep(edge0: float, edge1: float, value: float) -> float:
    if edge0 == edge1:
        return 1.0 if value >= edge1 else 0.0
    t = max(0.0, min(1.0, (value - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)


def smootherstep(edge0: float, edge1: float, value: float) -> float:
    if edge0 == edge1:
        return 1.0 if value >= edge1 else 0.0
    t = max(0.0, min(1.0, (value - edge0) / (edge1 - edge0)))
    return t * t * t * (t * (t * 6 - 15) + 10)


def timer_blend(elapsed: float) -> float:
    """0 = level bars, 1 = timer, in between while crossing over."""
    progress = (elapsed - TIMER_ACTIVATION_SECONDS) / TIMER_TRANSITION_SECONDS
    return smootherstep(0.0, 1.0, max(0.0, min(1.0, progress)))


# -- theme -----------------------------------------------------------------


def windows_prefers_light() -> bool:
    """The Windows *app* theme (Settings → Personalisation → Colours)."""
    try:
        import winreg

        with winreg.OpenKey(
                winreg.HKEY_CURRENT_USER,
                r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize") as key:
            value, _ = winreg.QueryValueEx(key, "AppsUseLightTheme")
            return bool(value)
    except OSError:
        return False


@dataclass(frozen=True)
class CapsulePalette:
    """Shared by the capsule and every bubble that sits on it."""

    light: bool
    fill: QColor
    border: QColor
    text: QColor
    dim_text: QColor
    selected_fill: QColor
    selected_border: QColor
    selection: QColor


def _make_palette(light: bool) -> CapsulePalette:
    if light:
        return CapsulePalette(
            light=True,
            fill=QColor.fromRgbF(1.0, 1.0, 1.0, 0.84),
            border=QColor.fromRgbF(0.0, 0.0, 0.0, 0.14),
            text=QColor.fromRgbF(0.0, 0.0, 0.0, 0.85),
            dim_text=QColor.fromRgbF(0.0, 0.0, 0.0, 0.55),
            selected_fill=QColor.fromRgbF(0.90, 0.90, 0.92, 0.96),
            selected_border=QColor.fromRgbF(0.0, 0.0, 0.0, 0.30),
            selection=QColor("#b7cdf5"),
        )
    return CapsulePalette(
        light=False,
        fill=QColor.fromRgbF(0.0, 0.0, 0.0, 0.96),
        border=QColor.fromRgbF(0.22, 0.22, 0.22, 0.26),
        text=QColor.fromRgbF(1.0, 1.0, 1.0, 0.92),
        dim_text=QColor(236, 236, 240, 140),
        selected_fill=QColor(58, 58, 62, 236),
        selected_border=QColor(255, 255, 255, 92),
        selection=QColor("#3f5f9e"),
    )


_background_style = HUDBackgroundStyle.SYSTEM


def set_background_style(style: HUDBackgroundStyle) -> None:
    global _background_style
    _background_style = style


def uses_light_background() -> bool:
    """shouldUseLightBackground."""
    if _background_style is HUDBackgroundStyle.LIGHT:
        return True
    if _background_style is HUDBackgroundStyle.DARK:
        return False
    return windows_prefers_light()


def palette() -> CapsulePalette:
    return _make_palette(uses_light_background())


# Kept for the overlays that import them; the live values come from
# ``palette()``.
CAPSULE_FILL = _make_palette(False).fill
CAPSULE_BORDER = _make_palette(False).border
BUBBLE_TEXT = QColor(236, 236, 240)


# -- colour helpers ----------------------------------------------------------


def _mix(a: QColor, b: QColor, t: float) -> QColor:
    """NSColor.blended(withFraction:of:)."""
    t = max(0.0, min(1.0, t))
    return QColor.fromRgbF(a.redF() + (b.redF() - a.redF()) * t,
                           a.greenF() + (b.greenF() - a.greenF()) * t,
                           a.blueF() + (b.blueF() - a.blueF()) * t,
                           1.0)


def _alpha(color: QColor, alpha: float) -> QColor:
    result = QColor(color)
    result.setAlphaF(max(0.0, min(1.0, alpha)))
    return result


def _color_at(spec: ColorSpec, fraction: float) -> QColor:
    """One colour, or a point along the bar row's gradient."""
    start = QColor(spec.start)
    if not spec.is_gradient:
        return start
    return _mix(start, QColor(spec.end), fraction)


def _rounded(painter: QPainter, rect: QRectF, color: QColor) -> None:
    radius = min(rect.width(), rect.height()) / 2.0
    path = QPainterPath()
    path.addRoundedRect(rect, radius, radius)
    painter.fillPath(path, color)


def outline_fill_path(capsule: QRectF, fraction: float) -> QPainterPath:
    """recordingHUDOutlineFillPath: the lit part of the capsule's outline.

    Both halves start at the bottom centre and climb their own side —
    along the bottom straight, round the end cap, back along the top —
    until together they cover ``fraction`` of the perimeter, meeting at
    the top centre at 1.
    """
    fraction = max(0.0, min(1.0, fraction))
    path = QPainterPath()
    if fraction >= 1.0:
        r = capsule.height() / 2.0
        path.addRoundedRect(capsule, r, r)
        return path
    radius = capsule.height() / 2.0
    cx, cy = capsule.center().x(), capsule.center().y()
    half_straight = max(0.0, capsule.width() - capsule.height()) / 2.0
    arc_length = math.pi * radius
    lit = fraction * (2 * half_straight + arc_length)

    for direction in (-1.0, 1.0):
        remaining = lit
        path.moveTo(cx, capsule.bottom())
        first = min(remaining, half_straight)
        path.lineTo(cx + direction * first, capsule.bottom())
        remaining -= first
        if remaining <= 0:
            continue
        arc = min(remaining, arc_length)
        centre_x = cx + direction * half_straight
        steps = max(2, int(36 * arc / arc_length))
        for step in range(1, steps + 1):
            theta = (arc / arc_length) * math.pi * step / steps
            path.lineTo(centre_x + direction * radius * math.sin(theta),
                        cy + radius * math.cos(theta))
        remaining -= arc
        if remaining <= 0:
            continue
        third = min(remaining, half_straight)
        path.lineTo(centre_x - direction * third, capsule.top())
    return path


# -- coordinates -------------------------------------------------------------


def logical_rect(rect: Rect) -> QRectF:
    """Physical screen pixels (Win32, UIA) to Qt's logical coordinates.

    Qt keeps each screen's top-left at its native position and scales the
    rest by that screen's device pixel ratio.
    """
    cx, cy = rect.center
    for screen in QApplication.screens():
        geometry = screen.geometry()
        ratio = screen.devicePixelRatio()
        native = QRectF(geometry.x(), geometry.y(),
                        geometry.width() * ratio, geometry.height() * ratio)
        if native.contains(QPointF(cx, cy)):
            ox, oy = geometry.x(), geometry.y()
            return QRectF(ox + (rect.left - ox) / ratio,
                          oy + (rect.top - oy) / ratio,
                          rect.width / ratio, rect.height / ratio)
    return QRectF(rect.left, rect.top, rect.width, rect.height)


def _screen_for(point: QPointF):
    return QApplication.screenAt(point.toPoint()) or QApplication.primaryScreen()


def _clamp_into(rect: QRectF, area: QRect, margin: float = 12.0) -> QRectF:
    x = min(max(rect.x(), area.left() + margin), area.right() + 1 - rect.width() - margin)
    y = min(max(rect.y(), area.top() + margin), area.bottom() + 1 - rect.height() - margin)
    return QRectF(x, y, rect.width(), rect.height())


def frame_above_target(target: QRectF, width: float, height: float) -> QRectF:
    """recordingHUDFrameAboveTarget: over the caret's line, left-aligned."""
    area = _screen_for(target.center()).availableGeometry()
    gap = 12.0
    x = target.left() + 6
    preferred_y = target.top() - gap - 8 - height
    fallback_y = target.bottom() + gap
    y = preferred_y if preferred_y >= area.top() + 8 else fallback_y
    return _clamp_into(QRectF(x, y, width, height), area)


def frame_inside_window(window: QRectF, width: float, height: float) -> QRectF:
    """recordingHUDFrameInsideFallbackWindow: the window's lower left."""
    area = _screen_for(window.center()).availableGeometry()
    inset = min(180.0, max(28.0, window.width() * 0.15))
    rise = min(96.0, max(44.0, window.height() * 0.14))
    return _clamp_into(QRectF(window.left() + inset, window.bottom() - rise - height,
                              width, height), area)


def frame_on_screen(width: float, height: float) -> QRectF:
    """No window at all: top centre of the screen under the pointer."""
    area = _screen_for(QPointF(_cursor_position())).availableGeometry()
    return QRectF(area.center().x() - width / 2.0, area.top() + 96, width, height)


# -- the capsule ---------------------------------------------------------------


class RecordingHUD(QWidget):
    """States: hidden -> recording -> transcribing -> correcting -> hidden.

    Also ``error`` (a short flash), ``result`` (an outcome glyph for a
    dictation that produced nothing, explained on hover) and ``static``
    (decoration under the transcript editor and the history bubbles).
    """

    # True when the pointer moves over the capsule, false when it leaves.
    # The window is click-through, so this is polled rather than delivered
    # as enter/leave events, which never arrive with WS_EX_TRANSPARENT.
    hover_changed = Signal(bool)

    def __init__(self, probe: Optional[focus_target.FocusProbe] = None) -> None:
        super().__init__(None)
        self.setWindowFlags(
            Qt.WindowType.FramelessWindowHint
            | Qt.WindowType.Tool
            | Qt.WindowType.WindowStaysOnTopHint
            | Qt.WindowType.WindowDoesNotAcceptFocus
            | Qt.WindowType.BypassWindowManagerHint
        )
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating)
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)

        self._probe = probe
        self._own_pids = frozenset({os.getpid()})

        self._mode = "hidden"
        self._mode_before_hide = "recording"
        self._mode_changed_at = time.monotonic()
        # Fixed age for the frame exporter; None means "since the mode began".
        self._transcribing_age_override: Optional[float] = None
        self._level = 0.0
        self._smoothed_level = 0.0
        self._phase = 0.0
        self._recording_started_at: Optional[float] = None
        self._transcribing_since: Optional[float] = None
        self._last_frame_at: Optional[float] = None

        # The reveal timeline: linear here, each layer applies its own curve.
        self._reveal = 0.0
        self._reveal_from = 0.0
        self._reveal_to = 0.0
        self._reveal_started: Optional[float] = None
        self._reveal_duration = 0.0
        self._reveal_done = None

        self.display_mode = HUDDisplayMode.LEVEL_BARS
        self.size_preset = HUDSize.STANDARD
        self.background_style = HUDBackgroundStyle.SYSTEM
        self.recording_color = ColorSpec.of(AccentColor.RED)
        self.transcribing_color = ColorSpec.of(AccentColor.BLUE)
        self.correcting_color = ColorSpec.of(AccentColor.PURPLE)
        self._light = False

        self._frame_timer = QTimer(self)
        self._frame_timer.setTimerType(Qt.TimerType.PreciseTimer)
        self._frame_timer.setInterval(FRAME_INTERVAL_MS)
        self._frame_timer.timeout.connect(self._tick)

        # Placement.
        self._target_frame: Optional[QRectF] = None   # logical, the visual frame
        self._window_frame: Optional[QRectF] = None   # logical, the fallback
        self._stabilizer = TargetStabilizer()
        self._cache = TargetCache()
        self._session = 0
        self._query_in_flight = False
        self._waiting_initial = False
        self._retargeting = False
        self._refresh_timer = QTimer(self)
        self._refresh_timer.setInterval(TARGET_REFRESH_INTERVAL_MS)
        self._refresh_timer.timeout.connect(lambda: self._request_target(initial=False))
        self._initial_timeout = QTimer(self)
        self._initial_timeout.setSingleShot(True)
        self._initial_timeout.timeout.connect(self._initial_target_timed_out)

        self._result_icon = ""
        self._hovered = False
        self._hover_timer = QTimer(self)
        self._hover_timer.setInterval(HOVER_POLL_MS)
        self._hover_timer.timeout.connect(self._poll_hover)
        self._hold_timer = QTimer(self)
        self._hold_timer.setSingleShot(True)
        self._hold_timer.timeout.connect(self._result_expired)
        self._error_timer = QTimer(self)
        self._error_timer.setSingleShot(True)
        self._error_timer.timeout.connect(self.hide_hud)
        self._deferred_hide = QTimer(self)
        self._deferred_hide.setSingleShot(True)
        self._deferred_hide.timeout.connect(self._hide_now)

        self._apply_size()

    @property
    def mode(self) -> str:
        return self._mode

    # -- configuration --------------------------------------------------

    def configure(self, *, size: HUDSize, recording: ColorSpec,
                  transcribing: ColorSpec,
                  correcting: Optional[ColorSpec] = None,
                  background: Optional[HUDBackgroundStyle] = None,
                  display_mode: Optional[HUDDisplayMode] = None) -> None:
        self.size_preset = size
        self.recording_color = recording
        self.transcribing_color = transcribing
        if correcting is not None:
            self.correcting_color = correcting
        if background is not None:
            self.background_style = background
            set_background_style(background)
        if display_mode is not None:
            self.display_mode = display_mode
        self._refresh_theme()
        self._apply_size()
        self.update()

    def _refresh_theme(self) -> None:
        # Re-read each time the capsule appears: "system" should follow a
        # theme change without a restart.
        self._light = uses_light_background()

    def _apply_size(self) -> None:
        scale = self.size_preset.scale
        self.resize(int(round(BASE_WIDTH * scale)), int(round(BASE_HEIGHT * scale)))

    def _colors(self, spec: ColorSpec) -> ColorSpec:
        return spec.resolved(self._light)

    # -- state ----------------------------------------------------------

    def _set_mode(self, mode: str) -> None:
        if mode != self._mode:
            self._mode_changed_at = time.monotonic()
        self._mode = mode

    def show_recording(self) -> None:
        self._cancel_holds()
        self._set_mode("recording")
        self._recording_started_at = time.monotonic()
        self._transcribing_since = None
        self._smoothed_level = 0.0
        self._refresh_theme()
        self._begin_tracking()

    def show_transcribing(self) -> None:
        self._cancel_holds()
        if self._mode in ("hidden", "hiding"):
            self._set_mode("transcribing")
            self._appear()
        self._set_mode("transcribing")
        self._transcribing_since = time.monotonic()
        # The clock stops with the recording: what the timer measured is
        # how long the user spoke, not how long the machine then thought.
        self._recording_started_at = None
        self._stop_tracking()
        self._ensure_running()
        self.update()

    def show_correcting(self) -> None:
        """showCorrectingHUD: only over a capsule that is already up."""
        if self._mode not in ("recording", "transcribing", "correcting"):
            return
        self._set_mode("correcting")
        self._recording_started_at = None
        self._stop_tracking()
        self._ensure_running()
        self.update()

    def show_error(self) -> None:
        """flashErrorFeedback: a yellow "!" for a moment, then gone."""
        self._cancel_holds()
        self._transcribing_since = None
        self._recording_started_at = None
        self._stop_tracking()
        visible = self._mode not in ("hidden", "hiding")
        self._set_mode("error")
        if not visible:
            self._place_once()
            self._appear()
        else:
            self._reveal_to_value(1.0, ANIMATE_IN_SECONDS)
        self._error_timer.start(ERROR_FLASH_MS)
        self.update()

    def show_static(self) -> None:
        """The capsule with nothing going on inside it.

        The transcript editor and the history bubbles bring it back
        because they belong to the dictation the capsule stands for. It is
        decoration only: the bars hold one shape and nothing animates.
        """
        self._cancel_holds()
        self._stop_tracking()
        self._set_mode("static")
        self._refresh_theme()
        self._place_once()
        self._appear()
        self.update()

    def show_result(self, icon_name: str, color: str = RESULT_COLOR) -> None:
        """Report the outcome in place of the waveform.

        A dictation that produced no text gets a glyph in the capsule the
        user is already looking at, and the reason is one hover away.
        """
        self._cancel_holds()
        self._stop_tracking()
        self._result_icon = icon_name
        visible = self._mode not in ("hidden", "hiding")
        self._set_mode("result")
        if not visible:
            self._place_once()
            self._appear()
        else:
            self._reveal_to_value(1.0, ANIMATE_IN_SECONDS)
        self._hover_timer.start()
        self._hold_timer.start(RESULT_HOLD_MS)
        self.update()

    def _result_expired(self) -> None:
        # Still being read: keep it up rather than yanking the explanation
        # out from under the pointer.
        if self._hovered:
            self._hold_timer.start(RESULT_HOLD_MS)
            return
        self.hide_hud()

    def _poll_hover(self) -> None:
        inside = self.isVisible() and self.geometry().contains(_cursor_position())
        if inside != self._hovered:
            self._hovered = inside
            self.hover_changed.emit(inside)

    def hide_hud(self) -> None:
        """finishBusyHUD: a transcription never flashes by unseen."""
        if self._mode in ("hidden", "hiding"):
            return
        if self._transcribing_since is not None and self._mode in ("transcribing", "correcting"):
            remaining = TRANSCRIBING_MIN_VISIBLE_SECONDS - (time.monotonic() - self._transcribing_since)
            if remaining > 0:
                self._deferred_hide.start(int(remaining * 1000))
                return
        self._hide_now()

    def _hide_now(self) -> None:
        if self._mode in ("hidden", "hiding"):
            return
        # Not _set_mode: the transcribing wave's clock must not restart
        # for the quarter second it takes to shrink away.
        self._mode_before_hide = self._mode
        self._mode = "hiding"
        self._transcribing_since = None
        self._stop_tracking()
        self._hold_timer.stop()
        self._hover_timer.stop()
        self._error_timer.stop()
        if self._hovered:
            self._hovered = False
            self.hover_changed.emit(False)
        self._reveal_to_value(0.0, ANIMATE_OUT_SECONDS, self._finish_hide)

    def _finish_hide(self) -> None:
        if self._mode != "hiding":
            return
        self._mode = "hidden"
        self._frame_timer.stop()
        self._last_frame_at = None
        self._target_frame = None
        self._window_frame = None
        self.hide()

    def _cancel_holds(self) -> None:
        self._deferred_hide.stop()
        self._error_timer.stop()
        self._hold_timer.stop()
        self._hover_timer.stop()

    def set_level(self, level: float) -> None:
        self._level = max(0.0, min(1.0, level))

    # -- reveal timeline ------------------------------------------------

    def _appear(self) -> None:
        """animateRecordingHUDIn: at the final spot, growing from a dot."""
        self._reveal = 0.0
        self.setGeometry(self._desired_geometry().toRect())
        self._make_click_through()
        self.show()
        self._reveal_to_value(1.0, ANIMATE_IN_SECONDS)

    def _reveal_to_value(self, target: float, seconds: float, done=None) -> None:
        self._reveal_from = self._reveal
        self._reveal_to = target
        distance = abs(target - self._reveal)
        self._reveal_duration = max(1.0 / 120.0, seconds * distance)
        self._reveal_started = time.monotonic()
        self._reveal_done = done
        self._ensure_running()

    def _advance_reveal(self, now: float) -> None:
        if self._reveal_started is None:
            return
        progress = min(1.0, max(0.0, (now - self._reveal_started) / self._reveal_duration))
        self._reveal = self._reveal_from + (self._reveal_to - self._reveal_from) * progress
        if progress >= 1.0:
            self._reveal_started = None
            done, self._reveal_done = self._reveal_done, None
            if done is not None:
                done()

    def _ensure_running(self) -> None:
        if not self._frame_timer.isActive():
            self._last_frame_at = time.monotonic()
            self._frame_timer.start()

    # -- placement ------------------------------------------------------

    def _begin_tracking(self) -> None:
        """requestRecordingHUDTarget(isInitial: true)."""
        self._session += 1
        self._query_in_flight = False
        self._stabilizer.reset(None)
        self._target_frame = None
        self._window_frame = None
        visible = self.isVisible() and self._mode not in ("hidden", "hiding")
        if self._probe is None:
            if not visible:
                self._appear()
            return
        self._waiting_initial = not visible
        self._request_target(initial=True)
        if self._waiting_initial:
            self._initial_timeout.start(INITIAL_TARGET_WAIT_MS)
        else:
            self._reveal_to_value(1.0, ANIMATE_IN_SECONDS)
        self._refresh_timer.start()

    def _stop_tracking(self) -> None:
        self._session += 1
        self._refresh_timer.stop()
        self._initial_timeout.stop()
        self._query_in_flight = False
        if self._waiting_initial:
            self._waiting_initial = False

    def _place_once(self) -> None:
        """One synchronous lookup for the overlays that do not track."""
        self._target_frame = None
        self._window_frame = None
        if self._probe is None:
            return
        try:
            result = self._probe.query(self._own_pids).result(timeout=0.25)
        except Exception:
            return
        if result is None:
            return
        if result.window_frame is not None:
            self._window_frame = logical_rect(result.window_frame)
        target = result.target or self._cache.lookup(result)
        if target is not None and self._usable(target):
            self._target_frame = logical_rect(target.visual_frame)

    def _initial_target_timed_out(self) -> None:
        if self._waiting_initial:
            self._waiting_initial = False
            if self._mode == "recording":
                self._appear()

    def _request_target(self, *, initial: bool) -> None:
        if self._probe is None or self._query_in_flight:
            return
        self._query_in_flight = True
        session = self._session
        future = self._probe.query(self._own_pids)

        def delivered(done) -> None:
            # Called on the probe thread; hop to the Qt thread.
            QTimer.singleShot(0, self, lambda: self._target_arrived(done, session, initial))

        future.add_done_callback(delivered)

    def _target_arrived(self, future, session: int, initial: bool) -> None:
        if session != self._session:
            return
        self._query_in_flight = False
        try:
            result: Optional[QueryResult] = future.result()
        except Exception as exc:
            log.debug("Caret lookup failed: %s", exc)
            result = None

        if result is not None:
            if initial:
                self._stabilizer.reset(result.pid)
            if result.window_frame is not None:
                self._window_frame = logical_rect(result.window_frame)
            live = result.target if result.target is not None and self._usable(result.target) else None
            observed = live or self._cache.lookup(result)
            decision, target = self._stabilizer.observe(observed)
            if target is not None:
                previous = self._target_frame
                self._target_frame = logical_rect(target.visual_frame)
                if live is not None:
                    self._cache.store(live, result.window_frame)
                if decision == "switch" and not initial and self.isVisible():
                    self._animate_retarget(previous)
            if initial:
                kind = (live.kind if live is not None
                        else ("cache" if observed is not None else "none"))
                log.info("HUD target at recording start: %s in %s (%s)",
                         kind, result.process, result.detail)

        if initial and self._waiting_initial:
            self._waiting_initial = False
            self._initial_timeout.stop()
            if self._mode == "recording":
                self._appear()

    def _usable(self, target: TargetFrame) -> bool:
        cx, cy = target.visual_frame.center
        return focus_target.usable_target(target.visual_frame,
                                          focus_target.work_area(cx, cy))

    def _desired_geometry(self) -> QRectF:
        width, height = float(self.width()), float(self.height())
        if self._target_frame is not None:
            return frame_above_target(self._target_frame, width, height)
        if self._window_frame is not None:
            return frame_inside_window(self._window_frame, width, height)
        return frame_on_screen(width, height)

    def _follow(self, dt: float) -> None:
        """moveRecordingHUDTowardInsertionTarget: an exponential glide."""
        if self._retargeting or self._reveal < 1.0 or not self.isVisible():
            return
        target = self._desired_geometry()
        current = QRectF(self.geometry())
        dx = target.center().x() - current.center().x()
        dy = target.center().y() - current.center().y()
        if abs(dx) < 0.5 and abs(dy) < 0.5:
            if current.toRect().topLeft() != target.toRect().topLeft():
                self.move(target.toRect().topLeft())
            return
        response = 1.0 - math.exp(-TARGET_FOLLOW_RESPONSE * dt)
        nx = current.x() + dx * response
        ny = current.y() + dy * response
        self.move(QPoint(int(round(nx)), int(round(ny))))

    def _animate_retarget(self, previous: Optional[QRectF]) -> None:
        """A different field: fade out here, reappear over there."""
        if self._mode != "recording" or self._target_frame is None:
            return
        target = self._desired_geometry()
        here = QRectF(self.geometry())
        distance = math.hypot(target.center().x() - here.center().x(),
                              target.center().y() - here.center().y())
        if distance <= 8:
            return
        if previous is not None and \
                math.hypot(previous.center().x() - self._target_frame.center().x(),
                           previous.center().y() - self._target_frame.center().y()) < 3 and \
                abs(previous.width() - self._target_frame.width()) < 3 and \
                abs(previous.height() - self._target_frame.height()) < 3:
            return
        self._retargeting = True

        def jump() -> None:
            self._retargeting = False
            if self._mode != "recording":
                return
            self.move(self._desired_geometry().toRect().topLeft())
            self._reveal_to_value(1.0, ANIMATE_IN_SECONDS)

        self._reveal_to_value(0.0, ANIMATE_OUT_SECONDS, jump)

    def _make_click_through(self) -> None:
        """Qt's transparent-for-mouse-events is per-widget; the window
        itself still activates on click without these extended styles."""
        try:
            handle = int(self.winId())
        except Exception:
            return
        style = user32.GetWindowLongW(handle, GWL_EXSTYLE)
        user32.SetWindowLongW(
            handle, GWL_EXSTYLE,
            style | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW,
        )

    # -- animation ------------------------------------------------------

    def _tick(self) -> None:
        now = time.monotonic()
        previous = self._last_frame_at if self._last_frame_at is not None else now
        dt = max(0.001, min(0.05, now - previous))
        self._last_frame_at = now
        self._advance_reveal(now)
        if self._mode == "hidden":
            return
        if self._mode == "recording":
            # Ease toward the measured level so a single loud syllable
            # doesn't snap every bar to full height.
            self._smoothed_level += (self._level - self._smoothed_level) * min(1.0, dt * 22.0)
        self._phase += dt * phase_speed(self._mode, self._smoothed_level)
        self._follow(dt)
        self.update()
        if self._mode in ("static", "result", "error") and self._reveal_started is None:
            # Nothing moves in these; stop burning frames until the next change.
            self._frame_timer.stop()

    # -- painting -------------------------------------------------------

    def paintEvent(self, event) -> None:  # noqa: N802 (Qt naming)
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        self.render_frame(painter, QRectF(0, 0, self.width(), self.height()))
        painter.end()

    def render_frame(self, painter: QPainter, bounds: QRectF,
                     *, now: Optional[float] = None) -> None:
        """drawFloatingWaveformOnly. Public for the frame exporter."""
        reveal = max(0.0, min(1.0, self._reveal))
        if reveal <= 0.001:
            return
        scale = self.size_preset.scale
        audio = math.pow(max(0.0, min(1.0, self._smoothed_level)), 0.82)
        settle_peak, overshoot = 0.68, 0.10
        if reveal <= settle_peak:
            grow = (1 + overshoot) * smootherstep(0, settle_peak, reveal)
        else:
            grow = (1 + overshoot) - overshoot * smootherstep(settle_peak, 1, reveal)
        capsule_alpha = smootherstep(0, 0.34, reveal)
        content_alpha = smootherstep(0.16, 0.78, reveal)
        start_diameter = 6 * scale
        final = bounds.adjusted(4 * scale, 4 * scale, -4 * scale, -4 * scale)
        breathing = smootherstep(0.82, 1, reveal)
        idle_breath = 0.0032 + 0.0018 * math.sin(self._phase * 0.31)
        voice_breath = 0.0
        if self._mode == "recording":
            voice_breath = audio * (0.014 + 0.008 * ((math.sin(self._phase * 0.87) + 1) / 2))
        live_scale = 1 + (idle_breath + voice_breath) * breathing
        width = (start_diameter + (final.width() - start_diameter) * grow) * live_scale
        height = (start_diameter + (final.height() - start_diameter) * grow) * live_scale
        capsule = QRectF(bounds.center().x() - width / 2, bounds.center().y() - height / 2,
                         width, height)
        path = QPainterPath()
        path.addRoundedRect(capsule, height / 2, height / 2)

        colors = _make_palette(self._light)
        painter.fillPath(path, _alpha(colors.fill, colors.fill.alphaF() * capsule_alpha))
        painter.setPen(QPen(_alpha(colors.border, colors.border.alphaF() * capsule_alpha),
                            1 * scale))
        painter.drawPath(path)
        if content_alpha <= 0.001:
            return

        painter.save()
        painter.setClipPath(path)
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setOpacity(content_alpha)
        # While shrinking away the capsule keeps drawing what it showed.
        mode = self._mode if self._mode != "hiding" else self._mode_before_hide
        if mode == "transcribing":
            self._paint_transcribing(painter, capsule, now)
        elif mode == "correcting":
            self._paint_correcting(painter, capsule)
        elif mode == "error":
            self._paint_error(painter, capsule)
        elif mode == "result":
            self._paint_result(painter, capsule)
        elif mode == "static":
            self._paint_level_bars(painter, capsule, audio=0.32, phase=2.2)
        else:
            elapsed = ((now or time.monotonic()) - self._recording_started_at
                       if self._recording_started_at is not None else 0.0)
            blend = (timer_blend(elapsed)
                     if self.display_mode is HUDDisplayMode.TIMER_OUTLINE
                     and self._recording_started_at is not None else 0.0)
            if blend < 1.0:
                painter.setOpacity(content_alpha * (1 - blend))
                self._paint_level_bars(painter, capsule, audio=audio, phase=self._phase)
            if blend > 0.0:
                painter.setOpacity(content_alpha * blend)
                self._paint_timer(painter, capsule, elapsed)
        painter.restore()

    def _bar_geometry(self, capsule: QRectF, *, max_factor: float, max_points: float,
                      min_points: float):
        scale = self.size_preset.scale
        bar_width = 2.05 * scale
        bar_gap = 2.55 * scale
        min_height = min_points * scale
        max_height = min(capsule.height() * max_factor, max_points * scale)
        total = BAR_COUNT * bar_width + (BAR_COUNT - 1) * bar_gap
        return bar_width, bar_gap, min_height, max_height, capsule.center().x() - total / 2

    def _paint_level_bars(self, painter: QPainter, capsule: QRectF, *,
                          audio: float, phase: float) -> None:
        scale = self.size_preset.scale
        bar_width, bar_gap, min_h, max_h, start_x = self._bar_geometry(
            capsule, max_factor=0.58, max_points=13.2, min_points=3.0)
        center_y = capsule.center().y()
        center_index = (BAR_COUNT - 1) / 2
        spec = self._colors(self.recording_color)
        for index in range(BAR_COUNT):
            i = float(index)
            normalized = (i - center_index) / max(center_index, 1)
            envelope = math.pow(max(0.0, math.cos(normalized * math.pi / 2)), 0.62)
            traveling = (math.sin(phase * 1.02 - normalized * 2.85) + 1) / 2
            counter = (math.sin(phase * 1.57 + i * 1.17) + 1) / 2
            slow = (math.sin(phase * 0.23 + i * 2.11) + 1) / 2
            gain = 0.72 + 0.28 * slow
            idle = 0.14 + 0.075 * traveling + 0.055 * counter * envelope
            bias = 0.22 + 0.78 * envelope
            voice = audio * bias * (0.18 + 0.42 * traveling + 0.14 * counter) * gain
            activity = min(0.88, idle + voice)
            height = min_h + (max_h - min_h) * activity
            x = start_x + i * (bar_width + bar_gap)
            rect = QRectF(x, center_y - height / 2, bar_width, height)
            color = _color_at(spec, i / (BAR_COUNT - 1))
            _rounded(painter, rect.adjusted(-1.1 * scale, -1.1 * scale, 1.1 * scale, 1.1 * scale),
                     _alpha(color, 0.07 + 0.10 * activity))
            _rounded(painter, rect, _alpha(color, 0.74 + 0.26 * activity))

    def _paint_timer(self, painter: QPainter, capsule: QRectF, elapsed: float) -> None:
        """drawTimerOutlineFill: the outline as a level meter, MM:SS inside."""
        scale = self.size_preset.scale
        stroke = 2.4 * scale
        inset = (stroke + 3.0 * scale) / 2
        outline = capsule.adjusted(inset, inset, -inset, -inset)
        accent = QColor(self._colors(self.recording_color).start)
        level = max(0.0, min(1.0, self._smoothed_level))
        painter.setBrush(Qt.BrushStyle.NoBrush)
        painter.setPen(QPen(_alpha(accent, 0.14), stroke))
        painter.drawRoundedRect(outline, outline.height() / 2, outline.height() / 2)
        if level > 0.001:
            lit = outline_fill_path(outline, level)
            pen = QPen(_alpha(accent, 0.18 + 0.55 * level), stroke + 3.0 * scale * level)
            pen.setCapStyle(Qt.PenCapStyle.RoundCap)
            pen.setJoinStyle(Qt.PenJoinStyle.RoundJoin)
            painter.setPen(pen)
            painter.drawPath(lit)
            pen = QPen(_alpha(accent, 0.85 + 0.15 * level), stroke)
            pen.setCapStyle(Qt.PenCapStyle.RoundCap)
            pen.setJoinStyle(Qt.PenJoinStyle.RoundJoin)
            painter.setPen(pen)
            painter.drawPath(lit)
        font = QFont()
        font.setFamilies(["Segoe UI Variable Text", "Segoe UI"])
        font.setPixelSize(max(8, int(round(12 * scale))))
        font.setWeight(QFont.Weight.DemiBold)
        # Segoe's digits are tabular, so the readout does not jitter
        # sideways every time a 1 replaces a 0.
        painter.setFont(font)
        painter.setPen(_make_palette(self._light).text)
        painter.drawText(capsule, Qt.AlignmentFlag.AlignCenter, format_elapsed(elapsed))

    def _paint_transcribing(self, painter: QPainter, capsule: QRectF,
                            now: Optional[float]) -> None:
        """drawTranscribingWave: resolve red→blue left to right, then loop."""
        scale = self.size_preset.scale
        bar_width, bar_gap, min_h, max_h, start_x = self._bar_geometry(
            capsule, max_factor=0.60, max_points=14.6, min_points=3.2)
        center_y = capsule.center().y()
        center_index = (BAR_COUNT - 1) / 2
        age = max(0.0, (now or time.monotonic()) - self._mode_changed_at) \
            if self._transcribing_age_override is None else self._transcribing_age_override
        resolve = min(1.0, age / TRANSCRIBING_RESOLVE_SECONDS)
        loop = max(0.0, age - TRANSCRIBING_RESOLVE_SECONDS)
        recording = self._colors(self.recording_color)
        transcribing = self._colors(self.transcribing_color)
        for index in range(BAR_COUNT):
            i = float(index)
            normalized = (i - center_index) / max(center_index, 1)
            envelope = math.pow(max(0.0, math.cos(normalized * math.pi / 2)), 0.62)
            progress = i / (BAR_COUNT - 1)
            conversion = smoothstep(progress - 0.34, progress + 0.08, resolve)
            front = max(0.0, 1 - abs(resolve - progress) / 0.18) * (1 - smoothstep(0.82, 1, resolve))
            reverse_head = 1 - math.fmod(loop * 3.8, 1.0)
            reverse_pulse = max(0.0, 1 - abs(reverse_head - progress) / 0.24)
            loop_wave = (math.sin(loop * 6.2 + i * 0.56) + 1) / 2
            loop_counter = (math.sin(loop * 2.8 + i * 1.27) + 1) / 2
            lift = front * (0.48 + 0.30 * envelope)
            blue = conversion * (0.14 * loop_wave + 0.08 * loop_counter * envelope + 0.34 * reverse_pulse)
            red = (1 - conversion) * (0.16 + 0.12 * envelope)
            activity = min(0.94, 0.15 + 0.24 * envelope + red + blue + lift)
            height = min_h + (max_h - min_h) * activity
            x = start_x + i * (bar_width + bar_gap)
            rect = QRectF(x, center_y - height / 2, bar_width, height)
            fill = _mix(_color_at(recording, progress), _color_at(transcribing, progress), conversion)
            _rounded(painter, rect.adjusted(-1.35 * scale, -1.45 * scale, 1.35 * scale, 1.45 * scale),
                     _alpha(fill, 0.055 + 0.12 * front + 0.10 * reverse_pulse + 0.045 * conversion))
            _rounded(painter, rect,
                     _alpha(fill, 0.58 + 0.26 * front + 0.20 * reverse_pulse + 0.14 * conversion))

    def _paint_correcting(self, painter: QPainter, capsule: QRectF) -> None:
        """drawCorrectingWave: a front re-forms the wave into a gradient."""
        scale = self.size_preset.scale
        bar_width, bar_gap, min_h, max_h, start_x = self._bar_geometry(
            capsule, max_factor=0.60, max_points=14.6, min_points=3.2)
        center_y = capsule.center().y()
        sweep = math.fmod(self._phase / CORRECTING_SWEEP_RADIANS, 1.0)
        transcribing = self._colors(self.transcribing_color)
        correcting = self._colors(self.correcting_color)
        black, white = QColor(0, 0, 0), QColor(255, 255, 255)
        for index in range(BAR_COUNT):
            i = float(index)
            x_norm = i / (BAR_COUNT - 1)
            behind = sweep - x_norm
            if behind < 0:
                behind += 1
            band = smoothstep(0.03, 0.20, behind) * (1 - smoothstep(0.52, 0.92, behind))
            dist = min(abs(sweep - x_norm), 1 - abs(sweep - x_norm))
            flash = math.exp(-((dist * dist) / (2 * 0.05 * 0.05)))
            raw = (0.26 + 0.10 * math.sin(2 * math.pi * 4 * sweep + i * 0.85)
                   + 0.07 * math.sin(2 * math.pi * 7 * sweep + i * 1.9))
            refined = 0.58 + 0.13 * math.sin(2 * math.pi * 2 * sweep - i * 0.32)
            activity = min(1.0, raw + (refined - raw) * band + 0.34 * flash)
            height = min_h + (max_h - min_h) * activity
            x = start_x + i * (bar_width + bar_gap)
            rect = QRectF(x, center_y - height / 2, bar_width, height)
            color = _mix(_color_at(transcribing, x_norm), _color_at(correcting, x_norm), x_norm)
            color = _mix(color, black, 0.30 * (1 - band))
            color = _mix(color, white, flash * 0.75)
            _rounded(painter, rect.adjusted(-1.35 * scale, -1.45 * scale, 1.35 * scale, 1.45 * scale),
                     _alpha(color, min(1.0, 0.05 + 0.16 * band + 0.30 * flash)))
            _rounded(painter, rect, _alpha(color, min(1.0, 0.60 + 0.34 * band + 0.40 * flash)))

    def _paint_error(self, painter: QPainter, capsule: QRectF) -> None:
        """drawErrorIndicator: a static yellow exclamation mark."""
        scale = self.size_preset.scale
        stem_w = 2.4 * scale
        stem_h = min(capsule.height() * 0.38, 9 * scale)
        dot = 2.4 * scale
        gap = 2.0 * scale
        total = stem_h + gap + dot
        top = capsule.center().y() - total / 2
        color = _alpha(ERROR_YELLOW, 0.88)
        _rounded(painter, QRectF(capsule.center().x() - stem_w / 2, top, stem_w, stem_h), color)
        painter.setBrush(color)
        painter.drawEllipse(QRectF(capsule.center().x() - dot / 2, top + stem_h + gap, dot, dot))

    def _paint_result(self, painter: QPainter, capsule: QRectF) -> None:
        glyph = int(min(capsule.width(), capsule.height()) * 0.56)
        ink = "#000000" if self._light else RESULT_COLOR
        painter.drawPixmap(int(capsule.center().x() - glyph / 2),
                           int(capsule.center().y() - glyph / 2),
                           icons.pixmap(self._result_icon, ink, glyph, 2.0))


def export_animation_frames(directory: str, *, size: HUDSize = HUDSize.STANDARD,
                            light: bool = False, timer: bool = False,
                            fps: int = 60) -> int:
    """exportRecordingHUDAnimationFrames: the whole life of a capsule as PNGs.

    Reveal, recording to a synthetic voice, transcribing, correcting and
    the shrink away, rendered at 4x with the real drawing code. With
    ``timer`` the recording runs past the ten-second changeover.
    """
    from PySide6.QtGui import QImage

    os.makedirs(directory, exist_ok=True)
    hud = RecordingHUD(None)
    hud.configure(size=size, recording=ColorSpec.of(AccentColor.RED),
                  transcribing=ColorSpec.of(AccentColor.BLUE),
                  correcting=ColorSpec.of(AccentColor.PURPLE),
                  background=HUDBackgroundStyle.LIGHT if light else HUDBackgroundStyle.DARK,
                  display_mode=HUDDisplayMode.TIMER_OUTLINE if timer else HUDDisplayMode.LEVEL_BARS)
    pixel = 4
    width, height = hud.width(), hud.height()
    lead, recording_for, transcribing_for, correcting_for, tail = (
        0.35, 11.5 if timer else 6.2, 2.4, 4.0, 0.5)
    stages = [lead, ANIMATE_IN_SECONDS, recording_for, transcribing_for,
              correcting_for, ANIMATE_OUT_SECONDS, tail]
    marks = [sum(stages[:i + 1]) for i in range(len(stages))]
    total = marks[-1]
    count = int(round(total * fps))
    base = 1000.0
    for index in range(count):
        t = index / fps
        level = 0.0
        hud._transcribing_age_override = None
        if t < marks[0]:
            reveal, mode = 0.0, "recording"
        elif t < marks[1]:
            reveal, mode = (t - marks[0]) / ANIMATE_IN_SECONDS, "recording"
        elif t < marks[2]:
            reveal, mode = 1.0, "recording"
            voice = t - marks[1]
            syllables = math.pow(max(0.0, math.sin(voice * 8.7 + 0.35)), 0.58)
            phrasing = 0.58 + 0.42 * ((math.sin(voice * 2.15 - 0.7) + 1) / 2)
            detail = 0.78 + 0.22 * ((math.sin(voice * 13.4 + 1.8) + 1) / 2)
            level = min(0.94, 0.10 + 0.78 * syllables * phrasing * detail)
        elif t < marks[3]:
            reveal, mode = 1.0, "transcribing"
            hud._transcribing_age_override = t - marks[2]
        elif t < marks[4]:
            reveal, mode = 1.0, "correcting"
        elif t < marks[5]:
            reveal, mode = 1.0 - (t - marks[4]) / ANIMATE_OUT_SECONDS, "correcting"
        else:
            reveal, mode = 0.0, "correcting"
        hud._mode = mode
        hud._reveal = max(0.0, min(1.0, reveal))
        hud._smoothed_level = level
        hud._recording_started_at = base + marks[1] if mode == "recording" else None
        hud._phase += phase_speed(mode, level) / fps
        image = QImage(width * pixel, height * pixel, QImage.Format.Format_ARGB32_Premultiplied)
        image.fill(Qt.GlobalColor.transparent)
        painter = QPainter(image)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.scale(pixel, pixel)
        hud.render_frame(painter, QRectF(0, 0, width, height), now=base + t)
        painter.end()
        image.save(os.path.join(directory, f"frame-{index:05d}.png"))
    hud.deleteLater()
    return count


class TranscriptBubble(QWidget):
    """A second, smaller capsule above the first, showing partial text.

    One line, always. The text is elided from the left so the words being
    said right now stay put at the right-hand edge. It sits above the
    capsule, or below it when the capsule is near the top of the screen.
    """

    HEIGHT = 32
    PADDING = 17
    GAP = 9
    MIN_WIDTH = 96
    MAX_SCREEN_FRACTION = 0.5
    # Appearing is a small overshooting pop; growing with the sentence is
    # a plain ease, because an overshoot on every new word would wobble.
    GROW_MS = 260
    RESIZE_MS = 190

    def __init__(self, anchor: Optional[QWidget] = None) -> None:
        super().__init__(None)
        self.setWindowFlags(
            Qt.WindowType.FramelessWindowHint
            | Qt.WindowType.Tool
            | Qt.WindowType.WindowStaysOnTopHint
            | Qt.WindowType.WindowDoesNotAcceptFocus
            | Qt.WindowType.BypassWindowManagerHint
        )
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating)
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)

        self._anchor = anchor
        self._text = ""
        self._opacity = 0.0

        # Segoe UI Variable Display is the Windows 11 face cut for short
        # runs of large-ish text; it is noticeably cleaner here than the
        # body face at the same size, and falls back on Windows 10.
        font = QFont()
        font.setFamilies(["Segoe UI Variable Display", "Segoe UI Semibold",
                          "Segoe UI", "sans-serif"])
        font.setPointSizeF(10.5)
        font.setWeight(QFont.Weight.Medium)
        font.setLetterSpacing(QFont.SpacingType.PercentageSpacing, 100.5)
        self.setFont(font)

        self._fade = QPropertyAnimation(self, b"fadeOpacity", self)
        self._fade.finished.connect(self._fade_finished)
        self._shape = QPropertyAnimation(self, b"geometry", self)
        self._follow = QTimer(self)
        self._follow.setInterval(16)
        self._follow.timeout.connect(self._track_anchor)
        self.resize(self.MIN_WIDTH, self.HEIGHT)

    def set_anchor(self, anchor: QWidget) -> None:
        self._anchor = anchor

    # -- fade property ------------------------------------------------

    def _get_opacity(self) -> float:
        return self._opacity

    def _set_opacity(self, value: float) -> None:
        self._opacity = value
        self.setWindowOpacity(value)

    fadeOpacity = Property(float, _get_opacity, _set_opacity)

    # -- content ------------------------------------------------------

    def set_text(self, text: str) -> None:
        text = " ".join(text.split())
        if text == self._text:
            return
        self._text = text
        if not text:
            self.hide_bubble()
            return

        target = self._target_rect()
        if self.isVisible():
            # Already up: widen or narrow into the new sentence instead of
            # snapping, so the bubble reads as one object growing with the
            # speech rather than a series of differently-sized bubbles.
            self._animate_shape(target, self.RESIZE_MS,
                                QEasingCurve.Type.OutCubic)
        else:
            self.setGeometry(_seeded(target))
            self._make_click_through()
            self.show()
            self._animate_shape(target, self.GROW_MS,
                                QEasingCurve.Type.OutBack)
            self._animate_to(1.0, ANIMATE_IN_SECONDS)
        self._follow.start()
        self.update()

    def hide_bubble(self) -> None:
        self._text = ""
        self._follow.stop()
        if not self.isVisible():
            return
        # Shrink back into itself on the way out, the reverse of the pop.
        self._animate_shape(_seeded(self.geometry(), 0.94),
                            int(ANIMATE_OUT_SECONDS * 1000),
                            QEasingCurve.Type.InCubic)
        self._animate_to(0.0, ANIMATE_OUT_SECONDS)

    def _track_anchor(self) -> None:
        """Keep riding on the capsule as it follows the caret."""
        if not self._text or self._shape.state() == QPropertyAnimation.State.Running:
            return
        target = self._target_rect()
        if target.topLeft() != self.geometry().topLeft():
            self.move(target.topLeft())

    def _animate_shape(self, target: QRect, milliseconds: int,
                       curve: QEasingCurve.Type) -> None:
        self._shape.stop()
        self._shape.setDuration(milliseconds)
        self._shape.setEasingCurve(curve)
        self._shape.setStartValue(self.geometry())
        self._shape.setEndValue(target)
        self._shape.start()

    def _animate_to(self, target: float, seconds: float) -> None:
        self._fade.stop()
        self._fade.setDuration(int(seconds * 1000))
        self._fade.setStartValue(self._opacity)
        self._fade.setEndValue(target)
        self._fade.start()

    def _fade_finished(self) -> None:
        if self._opacity <= 0.01:
            self.hide()

    # -- geometry -----------------------------------------------------

    def _screen(self):
        if self._anchor is not None and self._anchor.isVisible():
            return (QApplication.screenAt(self._anchor.geometry().center())
                    or QApplication.primaryScreen())
        return (QApplication.screenAt(_cursor_position())
                or QApplication.primaryScreen())

    def _target_rect(self) -> QRect:
        """Where and how wide the bubble wants to be for its current text."""
        area = self._screen().availableGeometry()
        limit = int(area.width() * self.MAX_SCREEN_FRACTION)
        # A couple of pixels of slack: sized to exactly the text advance,
        # rounding leaves the last glyph a hair short and the whole line
        # gets elided when it would have fitted.
        wanted = self.fontMetrics().horizontalAdvance(self._text) + self.PADDING * 2 + 4
        width = max(self.MIN_WIDTH, min(limit, wanted))
        return QRect(bubble_corner(self._anchor, width, self.HEIGHT, self.GAP),
                     QSize(width, self.HEIGHT))

    def _make_click_through(self) -> None:
        try:
            handle = int(self.winId())
        except Exception:
            return
        style = user32.GetWindowLongW(handle, GWL_EXSTYLE)
        user32.SetWindowLongW(
            handle, GWL_EXSTYLE,
            style | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW,
        )

    # -- painting -----------------------------------------------------

    def paintEvent(self, event) -> None:  # noqa: N802 (Qt naming)
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        colors = palette()

        rect = QRectF(0.5, 0.5, self.width() - 1.0, self.height() - 1.0)
        radius = rect.height() / 2.0
        path = QPainterPath()
        path.addRoundedRect(rect, radius, radius)
        painter.fillPath(path, colors.fill)
        painter.setPen(QPen(colors.border, 1.0))
        painter.drawPath(path)

        inner = rect.adjusted(self.PADDING, 0, -self.PADDING, 0)
        elided = self.fontMetrics().elidedText(
            self._text, Qt.TextElideMode.ElideLeft, int(inner.width())
        )
        painter.setPen(colors.text)
        painter.drawText(inner,
                         Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter,
                         elided)
        painter.end()


def bubble_corner(anchor: Optional[QWidget], width: int, height: int, gap: int) -> QPoint:
    """Top-left of an overlay riding on the capsule.

    Centred on the capsule and above it; below it when the capsule sits
    too close to the top of the screen (a caret on a window's first line).
    Without a visible capsule, the bottom centre of the screen.
    """
    if anchor is not None and anchor.isVisible():
        capsule = anchor.geometry()
        area = (QApplication.screenAt(capsule.center())
                or QApplication.primaryScreen()).availableGeometry()
        centre_x = capsule.center().x()
        top = capsule.top() - gap - height
        if top < area.top() + 4:
            top = capsule.bottom() + 1 + gap
    else:
        area = (QApplication.screenAt(_cursor_position())
                or QApplication.primaryScreen()).availableGeometry()
        centre_x = area.center().x()
        top = area.bottom() - BOTTOM_MARGIN - height
    return _clamped_to_screen(QPoint(int(centre_x - width // 2), int(top)), width, height)


def _seeded(target: QRect, scale: float = 0.86) -> QRect:
    """A smaller rectangle sharing ``target``'s centre.

    The bubble grows out of this on the way in and falls back into it on
    the way out, so it expands from the middle instead of unrolling from
    a corner.
    """
    width = max(1, int(target.width() * scale))
    height = max(1, int(target.height() * (scale - 0.16)))
    return QRect(target.center().x() - width // 2,
                 target.center().y() - height // 2, width, height)


def _cursor_position() -> QPoint:
    from PySide6.QtGui import QCursor

    return QCursor.pos()


def _clamped_to_screen(point: QPoint, width: int, height: int) -> QPoint:
    screen = QApplication.screenAt(point) or QApplication.primaryScreen()
    area = screen.availableGeometry()
    x = max(area.left(), min(point.x(), area.right() - width))
    y = max(area.top(), min(point.y(), area.bottom() - height))
    return QPoint(int(x), int(y))
