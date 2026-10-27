"""The learn pill: a correction found in an edit, waiting to be saved.

Port of ``swift/Sources/Parakey/VocabularyLearnedToast.swift``, look and
behaviour alike. A capsule in the recording HUD's own fill and stroke, with
one line in it:

    гитхаб  →  GitHub

the arrow in the recording colour. It sits just above the field the
correction was made in (below it when there is no room), or in the
bottom-right corner when the field has no frame.

It appears while the edit watcher waits out its confirm window
(``edit_watch.CONFIRM_SECONDS``):

* the window runs out, or **Enter**: the rule is saved, the pill flashes the
  accent colour with a slight swell, then shrinks and fades out;
* **Escape** or a click anywhere on it: the pair is struck through and
  dimmed, the arrow greys, and after a beat the pill goes; nothing is saved;
* the user edits the word on: the pill follows the new candidate, and goes
  with the plain exit when nothing learnable is left.

The window never takes focus (``WS_EX_NOACTIVATE``), so a click on it does
not steal the caret from the field being edited. Every frame is drawn by
:func:`paint_pill`, which the self-tests and the preview export use too.
"""

from __future__ import annotations

import ctypes
import time
from dataclasses import dataclass
from typing import Callable, Optional

from PySide6.QtCore import QEasingCurve, QPointF, QRectF, Qt, QTimer
from PySide6.QtGui import (QColor, QCursor, QFont, QFontMetrics, QImage,
                           QPainter, QPainterPath, QPen)
from PySide6.QtWidgets import QApplication, QWidget

from ..logging_setup import get as get_logger
from . import hud

log = get_logger("ui.learn_toast")

# Geometry (VocabularyLearnedToastController): a compact single-row capsule.
PILL_HEIGHT = 48.0
HORIZONTAL_PADDING = 16.0
MIN_PILL_WIDTH = 200.0
MAX_PILL_WIDTH = 480.0
FONT_PIXELS = 17
ARROW = "  →  "
#: The window is this much larger than the pill on every side, room for the
#: confirm swell (3 % of the widest pill).
MARGIN = 10

# Timeline, in seconds.
ANIMATE_IN = hud.ANIMATE_IN_SECONDS
ANIMATE_OUT = hud.ANIMATE_OUT_SECONDS
ENTRY_EXIT_SCALE = 0.85
CONFIRM_GLOW = 0.35
CONFIRM_HOLD = 0.2
REJECT_HOLD = 0.25
#: The pill outlives the watcher's confirm window: the save ends it.
SAFETY_LIFETIME = 7.0

FRAME_MS = 8

_OUT = QEasingCurve(QEasingCurve.Type.OutQuad)
_IN = QEasingCurve(QEasingCurve.Type.InQuad)


@dataclass
class PillFrame:
    """Everything one frame depends on; :func:`paint_pill` draws it."""

    source: str
    replacement: str
    accent: QColor
    light: bool
    opacity: float = 1.0
    scale: float = 1.0
    #: 1 at the start of the confirm flash, 0 once it has settled.
    glow: float = 0.0
    rejected: bool = False


def _font() -> QFont:
    font = QFont(QApplication.font())
    font.setPixelSize(FONT_PIXELS)
    font.setWeight(QFont.Weight.Bold)
    return font


def _fit(source: str, replacement: str, metrics: QFontMetrics) -> tuple[str, str]:
    """Middle-elide the words so the line fits the widest pill."""
    room = MAX_PILL_WIDTH - 2 * HORIZONTAL_PADDING - metrics.horizontalAdvance(ARROW)
    if metrics.horizontalAdvance(source) + metrics.horizontalAdvance(replacement) <= room:
        return source, replacement
    half = room / 2
    mode = Qt.TextElideMode.ElideMiddle
    if metrics.horizontalAdvance(source) <= half:
        return source, metrics.elidedText(replacement, mode, int(room - metrics.horizontalAdvance(source)))
    if metrics.horizontalAdvance(replacement) <= half:
        return metrics.elidedText(source, mode, int(room - metrics.horizontalAdvance(replacement))), replacement
    return metrics.elidedText(source, mode, int(half)), metrics.elidedText(replacement, mode, int(half))


def pill_width(source: str, replacement: str) -> float:
    """The measured line plus padding, clamped; a longer line is elided."""
    text = QFontMetrics(_font()).horizontalAdvance(source + ARROW + replacement)
    return min(max(text + 2 * HORIZONTAL_PADDING, MIN_PILL_WIDTH), MAX_PILL_WIDTH)


def paint_pill(painter: QPainter, pill: QRectF, frame: PillFrame) -> None:
    """One frame of the pill, scaled about its centre, at its opacity."""
    colors = hud._make_palette(frame.light)
    painter.save()
    painter.setRenderHint(QPainter.RenderHint.Antialiasing)
    painter.setRenderHint(QPainter.RenderHint.TextAntialiasing)
    painter.setOpacity(max(0.0, min(1.0, frame.opacity)))
    centre = pill.center()
    painter.translate(centre)
    painter.scale(frame.scale, frame.scale)
    painter.translate(-centre)

    radius = pill.height() / 2
    path = QPainterPath()
    path.addRoundedRect(pill, radius, radius)
    glow = max(0.0, min(1.0, frame.glow))
    flash = QColor(frame.accent)
    flash.setAlphaF(0.9)
    painter.fillPath(path, _blend(colors.fill, flash, glow))
    painter.setPen(QPen(_blend(colors.border, frame.accent, glow), 1.0 + 2.0 * glow))
    painter.drawPath(path)

    font = _font()
    metrics = QFontMetrics(font)
    painter.setFont(font)
    source, replacement = _fit(frame.source, frame.replacement, metrics)
    widths = [metrics.horizontalAdvance(part) for part in (source, ARROW, replacement)]
    x = centre.x() - sum(widths) / 2
    baseline = centre.y() + (metrics.ascent() - metrics.descent()) / 2

    text = QColor(colors.text)
    arrow = QColor(frame.accent)
    if frame.rejected:
        text.setAlphaF(colors.text.alphaF() * 0.4)
        arrow = QColor.fromRgbF(0.5, 0.5, 0.5, colors.text.alphaF() * 0.4)
    for part, width, color in zip((source, ARROW, replacement), widths, (text, arrow, text)):
        painter.setPen(color)
        painter.drawText(QPointF(x, baseline), part)
        x += width
    if frame.rejected:
        strike_y = baseline - metrics.xHeight() / 2
        painter.setPen(QPen(text, max(1.0, FONT_PIXELS / 12)))
        left = centre.x() - sum(widths) / 2
        painter.drawLine(QPointF(left, strike_y), QPointF(left + sum(widths), strike_y))
    painter.restore()


def _blend(base: QColor, toward: QColor, t: float) -> QColor:
    """``base`` moved ``t`` of the way to ``toward``, alpha included."""
    return QColor.fromRgbF(
        base.redF() + (toward.redF() - base.redF()) * t,
        base.greenF() + (toward.greenF() - base.greenF()) * t,
        base.blueF() + (toward.blueF() - base.blueF()) * t,
        base.alphaF() + (toward.alphaF() - base.alphaF()) * t)


def frame_by_target(bounds: Optional[QRectF], width: float, height: float) -> QRectF:
    """positionAboveTarget, or positionBottomRight without a field."""
    if bounds is not None and bounds.width() > 0 and bounds.height() > 0:
        area = hud._screen_for(bounds.center()).availableGeometry()
        gap = 12.0
        preferred_y = bounds.top() - gap - height
        fallback_y = bounds.bottom() + gap
        y = preferred_y if preferred_y >= area.top() + 8 else fallback_y
        return hud._clamp_into(QRectF(bounds.left(), y, width, height), area)
    screen = QApplication.screenAt(QCursor.pos()) or QApplication.primaryScreen()
    area = screen.availableGeometry()
    return QRectF(area.right() + 1 - width - 24, area.bottom() + 1 - height - 24, width, height)


class LearnPill(QWidget):
    """One pending correction on screen. Driven by :class:`LearnPillController`."""

    def __init__(self, source: str, replacement: str, accent: QColor,
                 bounds: Optional[QRectF], on_click: Callable[[], None]) -> None:
        super().__init__(None)
        self.setWindowFlags(
            Qt.WindowType.FramelessWindowHint
            | Qt.WindowType.Tool
            | Qt.WindowType.WindowStaysOnTopHint
            | Qt.WindowType.WindowDoesNotAcceptFocus
        )
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating)
        self.setCursor(QCursor(Qt.CursorShape.PointingHandCursor))
        self._on_click = on_click
        self._bounds = bounds
        self.frame = PillFrame(source, replacement, accent, hud.uses_light_background(),
                               opacity=0.0, scale=ENTRY_EXIT_SCALE)
        # "in" -> "shown" -> ("glow" | "reject") -> "out", or "shown" -> "out".
        self._phase, self._phase_started = "in", time.monotonic()
        self._exit_after = 0.0
        self._glow_started: Optional[float] = None
        self._timer = QTimer(self)
        self._timer.setInterval(FRAME_MS)
        self._timer.timeout.connect(self._tick)
        self._place()

    # -- lifecycle ---------------------------------------------------

    @property
    def settled(self) -> bool:
        return self._phase in ("glow", "reject", "out")

    def present(self) -> None:
        self.show()
        _no_activate(self)
        self._timer.start()

    def retarget(self, source: str, replacement: str, bounds: Optional[QRectF]) -> None:
        """The user typed on: show the new candidate in place."""
        self.frame.source, self.frame.replacement = source, replacement
        if bounds is not None:
            self._bounds = bounds
        self._place()
        self.update()

    def confirm(self) -> None:
        if self.settled:
            return
        self._glow_started = time.monotonic()
        self._enter("glow", CONFIRM_HOLD)

    def reject(self) -> None:
        if self.settled:
            return
        self.frame.rejected = True
        self._enter("reject", REJECT_HOLD)

    def leave(self) -> None:
        """Plain exit: the candidate went away with no decision."""
        if self.settled:
            return
        self._enter("out", 0.0)

    def _enter(self, phase: str, exit_after: float) -> None:
        self._phase, self._phase_started = phase, time.monotonic()
        self._exit_after = exit_after
        # Leaving mid-entry starts the exit from full size, as the macOS
        # animations replace one another.
        self._opacity_from = self.frame.opacity
        self._scale_from = 1.0 if phase != "out" else self._base_scale()

    def _base_scale(self) -> float:
        return self.frame.scale - self._swell(time.monotonic())[1]

    def _swell(self, now: float) -> tuple[float, float]:
        """The confirm flash (1 -> 0) and the ~1.03 swell, by now."""
        if self._glow_started is None:
            return 0.0, 0.0
        t = _OUT.valueForProgress(min(1.0, (now - self._glow_started) / CONFIRM_GLOW))
        return 1.0 - t, 0.03 * (1.0 - abs(2.0 * t - 1.0))

    def _tick(self) -> None:
        now = time.monotonic()
        elapsed = now - self._phase_started
        frame = self.frame
        glow, swell = self._swell(now)
        if self._phase == "in":
            t = _OUT.valueForProgress(min(1.0, elapsed / ANIMATE_IN))
            opacity, scale = t, ENTRY_EXIT_SCALE + (1 - ENTRY_EXIT_SCALE) * t
            if elapsed >= ANIMATE_IN:
                self._phase, self._phase_started = "shown", now
        elif self._phase == "shown":
            opacity, scale = 1.0, 1.0
            if elapsed >= SAFETY_LIFETIME:
                self.leave()
        elif self._phase in ("glow", "reject"):
            opacity, scale = 1.0, 1.0
            if elapsed >= self._exit_after:
                self._enter("out", 0.0)
                self._opacity_from, self._scale_from = 1.0, 1.0
        else:  # out
            t = _IN.valueForProgress(min(1.0, elapsed / ANIMATE_OUT))
            opacity = self._opacity_from * (1.0 - t)
            scale = self._scale_from + (ENTRY_EXIT_SCALE - self._scale_from) * t
            if elapsed >= ANIMATE_OUT:
                self._timer.stop()
                self.close()
                self.deleteLater()
                return
        frame.opacity, frame.scale, frame.glow = opacity, scale + swell, glow
        self.update()

    def _place(self) -> None:
        width = pill_width(self.frame.source, self.frame.replacement)
        target = frame_by_target(self._bounds, width, PILL_HEIGHT)
        self.setGeometry(int(round(target.x())) - MARGIN, int(round(target.y())) - MARGIN,
                         int(round(width)) + 2 * MARGIN, int(PILL_HEIGHT) + 2 * MARGIN)

    def _pill_rect(self) -> QRectF:
        return QRectF(MARGIN + 0.5, MARGIN + 0.5,
                      self.width() - 2 * MARGIN - 1.0, self.height() - 2 * MARGIN - 1.0)

    # -- Qt ----------------------------------------------------------

    def mousePressEvent(self, event) -> None:  # noqa: N802 (Qt naming)
        if self._pill_rect().contains(event.position()) and not self.settled:
            self._on_click()
        else:
            event.ignore()

    def paintEvent(self, event) -> None:  # noqa: N802 (Qt naming)
        painter = QPainter(self)
        paint_pill(painter, self._pill_rect(), self.frame)
        painter.end()


class LearnPillController:
    """At most one pill. Bridges the edit watcher's signals and the keys.

    ``set_open(bool)`` tells the keyboard hook whether Enter and Escape
    belong to the pill; ``save_now`` and ``cancel`` reach the watcher.
    """

    def __init__(self, *, accent: Callable[[], QColor],
                 set_open: Callable[[bool], None],
                 save_now: Callable[[], None],
                 cancel: Callable[[], None]) -> None:
        self._accent = accent
        self._set_open = set_open
        self._save_now = save_now
        self._cancel = cancel
        self._pill: Optional[LearnPill] = None

    def _live(self) -> Optional[LearnPill]:
        pill = self._pill
        return pill if pill is not None and not pill.settled else None

    def show_pending(self, source: str, replacement: str, bounds) -> None:
        rect = hud.logical_rect(bounds) if bounds is not None else None
        pill = self._live()
        if pill is not None:
            pill.retarget(source, replacement, rect)
        else:
            pill = LearnPill(source, replacement, self._accent(), rect, self.cancel)
            self._pill = pill
            pill.destroyed.connect(lambda *_: self._forget(pill))
            pill.present()
        self._set_open(True)

    def saved(self) -> None:
        pill = self._live()
        if pill is not None:
            pill.confirm()
        self._set_open(False)

    def cleared(self) -> None:
        pill = self._live()
        if pill is not None:
            pill.leave()
        self._set_open(False)

    def key(self, save: bool) -> None:
        if save:
            self.save_now()
        else:
            self.cancel()

    def save_now(self) -> None:
        if self._live() is None:
            return
        # The pill plays its flash when the watcher reports the save.
        self._save_now()

    def cancel(self) -> None:
        pill = self._live()
        if pill is None:
            return
        pill.reject()
        self._set_open(False)
        self._cancel()

    def _forget(self, pill: LearnPill) -> None:
        if self._pill is pill:
            self._pill = None
            self._set_open(False)


def _no_activate(widget: QWidget) -> None:
    """Clicks reach the pill without moving focus off the field."""
    try:
        user32 = ctypes.windll.user32
        handle = int(widget.winId())
        style = user32.GetWindowLongW(handle, hud.GWL_EXSTYLE)
        user32.SetWindowLongW(handle, hud.GWL_EXSTYLE,
                              style | hud.WS_EX_NOACTIVATE | hud.WS_EX_TOOLWINDOW)
    except Exception:
        pass


def export_preview_frames(directory: str, *, light: bool = False,
                          accent: str = "#ff3b30",
                          source: str = "гитхаб", replacement: str = "GitHub") -> list[str]:
    """PNG frames of the whole timeline (entry, hold, save; reject), for
    checking the look without a live dictation."""
    from pathlib import Path

    out = Path(directory)
    out.mkdir(parents=True, exist_ok=True)
    width = pill_width(source, replacement)
    size = (int(width) + 2 * MARGIN, int(PILL_HEIGHT) + 2 * MARGIN)
    pill = QRectF(MARGIN + 0.5, MARGIN + 0.5, size[0] - 2 * MARGIN - 1.0, size[1] - 2 * MARGIN - 1.0)
    backdrop = QColor("#e8e8ec") if light else QColor("#3a3a40")
    color = QColor(accent)

    def frames():
        steps = 6
        for i in range(steps + 1):
            t = _OUT.valueForProgress(i / steps)
            yield "in", PillFrame(source, replacement, color, light, opacity=t,
                                  scale=ENTRY_EXIT_SCALE + (1 - ENTRY_EXIT_SCALE) * t)
        for i in range(steps + 1):
            g = _OUT.valueForProgress(i / steps)
            yield "save", PillFrame(source, replacement, color, light, glow=1.0 - g,
                                    scale=1.0 + 0.03 * (1.0 - abs(2.0 * g - 1.0)))
        yield "reject", PillFrame(source, replacement, color, light, rejected=True)
        for i in range(1, steps + 1):
            t = _IN.valueForProgress(i / steps)
            yield "out", PillFrame(source, replacement, color, light, rejected=True,
                                   opacity=1.0 - t, scale=1.0 - (1 - ENTRY_EXIT_SCALE) * t)

    written = []
    for index, (name, frame) in enumerate(frames()):
        image = QImage(size[0], size[1], QImage.Format.Format_ARGB32_Premultiplied)
        image.fill(backdrop)
        painter = QPainter(image)
        paint_pill(painter, pill, frame)
        painter.end()
        path = out / f"learn-{index:02d}-{name}.png"
        image.save(str(path))
        written.append(str(path))
    return written
