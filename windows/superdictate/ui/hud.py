"""The floating recording capsule.

A frameless, translucent, always-on-top window that shows a live waveform
while recording and a travelling shimmer while transcribing, the macOS
recording HUD, with its geometry constants carried over verbatim
(64x38 base, the same size multipliers, the same animate-in/out timings).

Two Windows-specific requirements shape the implementation:

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
import random
import time
from typing import Optional

from PySide6.QtCore import (
    Property,
    QEasingCurve,
    QPoint,
    QPointF,
    QPropertyAnimation,
    QRect,
    QRectF,
    Qt,
    QTimer,
    Signal,
)
from PySide6.QtGui import (
    QColor,
    QFont,
    QLinearGradient,
    QPainter,
    QPainterPath,
    QPen,
)
from PySide6.QtWidgets import QApplication, QWidget

from ..settings import AccentColor, ColorSpec, HUDDisplayMode, HUDSize
from . import icons

BASE_WIDTH = 64.0
BASE_HEIGHT = 38.0
ANIMATE_IN_SECONDS = 0.32
ANIMATE_OUT_SECONDS = 0.23
# Only needed to catch a screen change or a taskbar resize mid-recording.
TARGET_REFRESH_INTERVAL_MS = 700
BOTTOM_MARGIN = 24
FRAME_INTERVAL_MS = 16  # ~60 fps
BAR_COUNT = 5
# How long the outcome glyph stays up after a dictation that produced
# nothing, and how often the cursor is checked against the capsule.
RESULT_HOLD_MS = 3600
# Timer mode. The capsule starts as level bars whatever the setting says and
# only becomes a timer once a dictation has run long enough to be worth
# timing: for the two-second "yes, ok" the bars are the useful feedback, and
# a clock that appears instantly turns every dictation into a stopwatch you
# feel watched by. The macOS build picks the same ten seconds.
TIMER_ACTIVATION_SECONDS = 10.0
TIMER_TRANSITION_SECONDS = 0.8
HOVER_POLL_MS = 120
# The outcome glyph — a clock for a clip that was too short, a crossed-out
# microphone for speech that came back empty. It used to be amber, which
# read as an error; neither case is one, and white matches the accent.
RESULT_COLOR = "#ffffff"
# The shape the bars hold when the capsule is on screen for decoration
# rather than for a recording. Symmetrical, so it reads as a resting
# waveform and not as a moment frozen out of a real one.
STATIC_BARS = (0.30, 0.52, 0.70, 0.52, 0.30)
# The capsule and the transcript bubble are always dark. There used to be a
# light rendering and a setting to pick between it, the dark one and one
# that followed the Windows theme; a white capsule over a light window is
# nearly invisible, and it is a floating overlay rather than part of any
# window, so it has no theme to agree with in the first place.
CAPSULE_FILL = QColor(28, 28, 30, 214)
CAPSULE_BORDER = QColor(255, 255, 255, 38)
BUBBLE_TEXT = QColor(236, 236, 240)

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


class RecordingHUD(QWidget):
    """States: hidden -> recording -> transcribing -> result -> hidden.

    The whole HUD leaves the moment the dictation is over, whether or not
    the live preview was on: holding the finished sentence open for a
    couple of seconds made the same key press clear the screen at two
    different speeds depending on a setting.
    """

    # True when the pointer moves over the capsule, false when it leaves.
    # The window is click-through, so this is polled rather than delivered
    # as enter/leave events, which never arrive with WS_EX_TRANSPARENT.
    hover_changed = Signal(bool)

    def __init__(self) -> None:
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

        self._mode = "hidden"
        self._level = 0.0
        self._smoothed_level = 0.0
        self._phase = 0.0
        self._opacity = 0.0
        self._bar_levels = [0.15] * BAR_COUNT
        # When the current recording began, for the timer readout. None
        # whenever nothing is being recorded.
        self._recording_started_at: Optional[float] = None
        self.display_mode = HUDDisplayMode.LEVEL_BARS

        self.size_preset = HUDSize.STANDARD
        self.recording_color = ColorSpec.of(AccentColor.RED)
        self.transcribing_color = ColorSpec.of(AccentColor.BLUE)

        self._frame_timer = QTimer(self)
        self._frame_timer.setInterval(FRAME_INTERVAL_MS)
        self._frame_timer.timeout.connect(self._tick)

        self._follow_timer = QTimer(self)
        self._follow_timer.setInterval(TARGET_REFRESH_INTERVAL_MS)
        self._follow_timer.timeout.connect(self._reposition)

        self._fade = QPropertyAnimation(self, b"fadeOpacity", self)
        self._fade.finished.connect(self._fade_finished)

        self._result_icon = ""
        self._result_color = RESULT_COLOR
        self._hovered = False
        self._hover_timer = QTimer(self)
        self._hover_timer.setInterval(HOVER_POLL_MS)
        self._hover_timer.timeout.connect(self._poll_hover)
        self._hold_timer = QTimer(self)
        self._hold_timer.setSingleShot(True)
        self._hold_timer.timeout.connect(self._result_expired)

        self._apply_size()

    @property
    def mode(self) -> str:
        return self._mode

    # -- configuration ------------------------------------------------

    def configure(self, *, size: HUDSize, recording: ColorSpec,
                  transcribing: ColorSpec,
                  display_mode: "HUDDisplayMode" = None) -> None:
        self.size_preset = size
        self.recording_color = recording
        self.transcribing_color = transcribing
        if display_mode is not None:
            self.display_mode = display_mode
        self._apply_size()
        self.update()

    def _apply_size(self) -> None:
        scale = self.size_preset.scale
        self.resize(int(BASE_WIDTH * scale), int(BASE_HEIGHT * scale))

    # -- fade property ------------------------------------------------

    def _get_opacity(self) -> float:
        return self._opacity

    def _set_opacity(self, value: float) -> None:
        self._opacity = value
        self.setWindowOpacity(value)

    fadeOpacity = Property(float, _get_opacity, _set_opacity)

    # -- state --------------------------------------------------------

    def show_recording(self) -> None:
        self._mode = "recording"
        self._bar_levels = [0.15] * BAR_COUNT
        self._recording_started_at = time.monotonic()
        self._reposition()
        self._make_click_through()
        self.show()
        self._frame_timer.start()
        self._follow_timer.start()
        self._animate_to(1.0, ANIMATE_IN_SECONDS)

    def show_transcribing(self) -> None:
        if self._mode == "hidden":
            self.show_recording()
        self._mode = "transcribing"
        # The clock stops with the recording: what the timer measured is how
        # long the user spoke, not how long the machine then thought.
        self._recording_started_at = None
        self.update()

    def show_static(self) -> None:
        """The capsule with nothing going on inside it.

        The transcript editor brings it back because the correction
        belongs to the dictation it came from and should look like it.
        It is decoration and only decoration: no frame timer runs, the
        bars hold one shape, and the window stays as click-through as it
        is during a recording.
        """
        self._mode = "static"
        self._bar_levels = list(STATIC_BARS)
        self._frame_timer.stop()
        self._hold_timer.stop()
        self._reposition()
        self._make_click_through()
        self.show()
        self._follow_timer.start()
        self._animate_to(1.0, ANIMATE_IN_SECONDS)
        self.update()

    def show_result(self, icon_name: str, color: str) -> None:
        """Report the outcome in place of the waveform.

        A dictation that produced no text used to raise the same kind of
        card as "the microphone is unplugged", which is the wrong weight
        for something the user fixes by speaking again. The capsule they
        are already looking at says it instead, and the reason is one
        hover away.
        """
        self._result_icon = icon_name
        self._result_color = color
        self._mode = "result"
        self._frame_timer.stop()
        self._reposition()
        self._make_click_through()
        self.show()
        self._follow_timer.start()
        self._hover_timer.start()
        self._hold_timer.start(RESULT_HOLD_MS)
        self._animate_to(1.0, ANIMATE_IN_SECONDS)
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
        if self._mode == "hidden":
            return
        self._mode = "hiding"
        self._follow_timer.stop()
        self._hold_timer.stop()
        self._hover_timer.stop()
        if self._hovered:
            self._hovered = False
            self.hover_changed.emit(False)
        self._animate_to(0.0, ANIMATE_OUT_SECONDS)

    def set_level(self, level: float) -> None:
        self._level = max(0.0, min(1.0, level))

    def _animate_to(self, target: float, seconds: float) -> None:
        self._fade.stop()
        self._fade.setDuration(int(seconds * 1000))
        self._fade.setStartValue(self._opacity)
        self._fade.setEndValue(target)
        self._fade.start()

    def _fade_finished(self) -> None:
        if self._opacity <= 0.01:
            self._mode = "hidden"
            self._frame_timer.stop()
            self.hide()

    # -- placement ----------------------------------------------------

    def _reposition(self) -> None:
        """Bottom centre of the active screen, always.

        The capsule used to follow the text caret. In practice that made
        it jump to wherever a window happened to put its cursor, docking
        it to the top of some apps, and it moved while you spoke. A fixed
        spot above the taskbar is predictable and never covers what you
        are typing into.
        """
        screen = (QApplication.screenAt(_cursor_position())
                  or QApplication.primaryScreen())
        area = screen.availableGeometry()
        target = QPoint(
            area.center().x() - self.width() // 2,
            area.bottom() - self.height() - BOTTOM_MARGIN,
        )
        target = _clamped_to_screen(target, self.width(), self.height())
        if target != self.pos():
            self.move(target)

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

    # -- animation ----------------------------------------------------

    def _tick(self) -> None:
        if self._mode == "recording":
            # Ease toward the measured level so a single loud syllable
            # doesn't snap every bar to full height.
            self._smoothed_level += (self._level - self._smoothed_level) * 0.35
            self._phase += 0.16 + self._smoothed_level * 0.10
            for index in range(BAR_COUNT):
                wave = 0.5 + 0.5 * math.sin(self._phase * (1.0 + index * 0.22) + index)
                target = 0.12 + self._smoothed_level * wave * 1.5
                target += random.uniform(-0.02, 0.02)
                self._bar_levels[index] += (
                    max(0.08, min(1.0, target)) - self._bar_levels[index]
                ) * 0.4
        elif self._mode == "transcribing":
            self._phase += 0.11
            for index in range(BAR_COUNT):
                wave = 0.5 + 0.5 * math.sin(self._phase * 2.0 - index * 0.9)
                self._bar_levels[index] += (0.2 + wave * 0.55 - self._bar_levels[index]) * 0.3
        self.update()

    # -- painting -----------------------------------------------------

    def paintEvent(self, event) -> None:  # noqa: N802 (Qt naming)
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)

        rect = QRectF(0.5, 0.5, self.width() - 1.0, self.height() - 1.0)
        radius = rect.height() / 2.0

        background, border = self._background_colors()
        path = QPainterPath()
        path.addRoundedRect(rect, radius, radius)
        painter.fillPath(path, background)
        painter.setPen(QPen(border, 1.0))
        painter.drawPath(path)

        if self._mode == "result":
            glyph = int(min(self.width(), self.height()) * 0.56)
            painter.drawPixmap(
                int((self.width() - glyph) / 2), int((self.height() - glyph) / 2),
                icons.pixmap(self._result_icon, self._result_color, glyph, 2.0),
            )
            painter.end()
            return

        spec = (self.recording_color if self._mode in ("recording", "static")
                else self.transcribing_color)

        # Timer mode crosses over from the bars rather than replacing them,
        # so a dictation that ends before the changeover never shows a clock
        # at all and one that runs long changes over without a jump.
        blend = self._timer_blend()
        if blend < 1.0:
            painter.save()
            painter.setOpacity(1.0 - blend)
            self._paint_bars(painter, spec)
            painter.restore()
        if blend > 0.0:
            painter.save()
            painter.setOpacity(blend)
            self._paint_timer(painter, spec, rect, radius)
            painter.restore()
        painter.end()

    def _timer_blend(self) -> float:
        """0 = level bars, 1 = timer, in between while crossing over."""
        if self.display_mode is not HUDDisplayMode.TIMER_OUTLINE:
            return 0.0
        if self._recording_started_at is None:
            return 0.0
        elapsed = time.monotonic() - self._recording_started_at
        progress = (elapsed - TIMER_ACTIVATION_SECONDS) / TIMER_TRANSITION_SECONDS
        progress = max(0.0, min(1.0, progress))
        # Smootherstep: no visible start or end to the crossover.
        return progress * progress * progress * (progress * (progress * 6 - 15) + 10)

    def _paint_timer(self, painter: QPainter, spec: ColorSpec,
                     rect: QRectF, radius: float) -> None:
        """The capsule outline as a level meter, with MM:SS in the middle.

        The filled fraction of the perimeter grows from the bottom centre
        symmetrically up both sides with the audio level, so the capsule
        still shows the microphone is hearing something while the digits
        answer "how long have I been talking".
        """
        scale = self.size_preset.scale
        stroke = 2.4 * scale
        # Inset by half the widest stroke drawn here, so the glow at full
        # level stays inside the widget instead of being clipped in half.
        inset = (stroke + 3.0 * scale) / 2.0
        outline = rect.adjusted(inset, inset, -inset, -inset)
        outline_radius = outline.height() / 2.0

        base = QColor(spec.start)
        unfilled = QColor(base)
        unfilled.setAlphaF(0.14)
        painter.setBrush(Qt.BrushStyle.NoBrush)
        painter.setPen(QPen(unfilled, stroke))
        painter.drawRoundedRect(outline, outline_radius, outline_radius)

        level = max(0.0, min(1.0, self._smoothed_level))
        if level > 0.001:
            arc = self._outline_fill_path(outline, outline_radius, level)
            glow = QColor(base)
            glow.setAlphaF(0.18 + 0.55 * level)
            pen = QPen(glow, stroke + 3.0 * scale * level)
            pen.setCapStyle(Qt.PenCapStyle.RoundCap)
            painter.setPen(pen)
            painter.drawPath(arc)

            solid = QColor(base)
            solid.setAlphaF(0.85 + 0.15 * level)
            pen = QPen(solid, stroke)
            pen.setCapStyle(Qt.PenCapStyle.RoundCap)
            painter.setPen(pen)
            painter.drawPath(arc)

        elapsed = (time.monotonic() - self._recording_started_at
                   if self._recording_started_at is not None else 0.0)
        font = QFont(self.font())
        font.setPointSizeF(9.0 * scale)
        font.setWeight(QFont.Weight.DemiBold)
        # Monospaced digits: without them the readout jitters sideways every
        # time a 1 replaces a 0.
        font.setStyleHint(QFont.StyleHint.Monospace)
        painter.setFont(font)
        painter.setPen(QColor(BUBBLE_TEXT))
        painter.drawText(rect, Qt.AlignmentFlag.AlignCenter,
                         format_elapsed(elapsed))

    @staticmethod
    def _outline_fill_path(rect: QRectF, radius: float,
                           fraction: float) -> QPainterPath:
        """Two arcs from the bottom centre, one up each side.

        Qt has no "fraction of a rounded rectangle's perimeter" primitive,
        and approximating the capsule with an ellipse is close enough at
        this size (the straight runs are short relative to the caps) while
        keeping the growth perfectly symmetrical, which is what the eye
        actually reads.
        """
        path = QPainterPath()
        span = 180.0 * max(0.0, min(1.0, fraction))
        # Qt angles: 0° is 3 o'clock, positive is counter-clockwise. 270° is
        # the bottom centre, where both arcs start.
        path.arcMoveTo(rect, 270.0)
        path.arcTo(rect, 270.0, span)
        path.arcMoveTo(rect, 270.0)
        path.arcTo(rect, 270.0, -span)
        return path

    def _paint_bars(self, painter: QPainter, spec: ColorSpec) -> None:
        scale = self.size_preset.scale
        bar_width = 3.0 * scale
        gap = 3.2 * scale
        total_width = BAR_COUNT * bar_width + (BAR_COUNT - 1) * gap
        left = (self.width() - total_width) / 2.0
        max_height = self.height() * 0.52
        center_y = self.height() / 2.0

        painter.setPen(Qt.PenStyle.NoPen)
        if spec.is_gradient:
            # Across the whole run of bars rather than per bar, so the
            # ramp reads as one object instead of five striped ones.
            ramp = QLinearGradient(QPointF(left, 0.0),
                                   QPointF(left + total_width, 0.0))
            ramp.setColorAt(0.0, QColor(spec.start))
            ramp.setColorAt(1.0, QColor(spec.end))
            painter.setBrush(ramp)
        else:
            painter.setBrush(QColor(spec.start))
        for index, level in enumerate(self._bar_levels):
            height = max(bar_width, max_height * level)
            bar = QRectF(
                left + index * (bar_width + gap),
                center_y - height / 2.0,
                bar_width,
                height,
            )
            painter.drawRoundedRect(bar, bar_width / 2.0, bar_width / 2.0)

    def _background_colors(self) -> tuple[QColor, QColor]:
        return CAPSULE_FILL, CAPSULE_BORDER


class TranscriptBubble(QWidget):
    """A second, smaller capsule above the first, showing partial text.

    One line, always. The text is elided from the left so the words being
    said right now stay put at the right-hand edge; growing the bubble
    upward instead would move it under the cursor mid-sentence, and that
    is the behaviour the capsule itself was moved away from.
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
        self.update()

    def hide_bubble(self) -> None:
        self._text = ""
        if not self.isVisible():
            return
        # Shrink back into itself on the way out, the reverse of the pop.
        self._animate_shape(_seeded(self.geometry(), 0.94),
                            int(ANIMATE_OUT_SECONDS * 1000),
                            QEasingCurve.Type.InCubic)
        self._animate_to(0.0, ANIMATE_OUT_SECONDS)

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

        if self._anchor is not None and self._anchor.isVisible():
            capsule = self._anchor.geometry()
            bottom = capsule.top() - self.GAP
            centre_x = capsule.center().x()
        else:
            bottom = area.bottom() - BOTTOM_MARGIN
            centre_x = area.center().x()
        corner = _clamped_to_screen(
            QPoint(centre_x - width // 2, bottom - self.HEIGHT),
            width, self.HEIGHT)
        return QRect(corner.x(), corner.y(), width, self.HEIGHT)

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

        rect = QRectF(0.5, 0.5, self.width() - 1.0, self.height() - 1.0)
        radius = rect.height() / 2.0
        path = QPainterPath()
        path.addRoundedRect(rect, radius, radius)
        painter.fillPath(path, CAPSULE_FILL)
        painter.setPen(QPen(CAPSULE_BORDER, 1.0))
        painter.drawPath(path)

        inner = rect.adjusted(self.PADDING, 0, -self.PADDING, 0)
        elided = self.fontMetrics().elidedText(
            self._text, Qt.TextElideMode.ElideLeft, int(inner.width())
        )
        painter.setPen(BUBBLE_TEXT)
        painter.drawText(inner,
                         Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter,
                         elided)
        painter.end()


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
