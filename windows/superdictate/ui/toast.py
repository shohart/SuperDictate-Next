"""On-screen notifications.

Warnings used to go through ``QSystemTrayIcon.showMessage``, which hands
them to the Windows notification centre. That has two problems for a
dictation tool: the banner can be delayed or silently swallowed by Focus
Assist, and "your microphone is busy" is useless three minutes after you
pressed the key. These toasts are drawn by the app itself, so they appear
immediately and disappear on their own.

Like the recording capsule they must never steal focus: the paste goes to
whatever window the user was typing in, so a toast that activated would
send the text to the wrong place.
"""

from __future__ import annotations

import ctypes
import ctypes.wintypes as wt
from enum import Enum

from PySide6.QtCore import (
    Property,
    QEasingCurve,
    QPoint,
    QPropertyAnimation,
    QRectF,
    Qt,
    QTimer,
)
from PySide6.QtGui import QColor, QFont, QFontMetrics, QPainter, QPainterPath
from PySide6.QtWidgets import QApplication, QWidget

from . import icons
from .theme import palette

user32 = ctypes.WinDLL("user32", use_last_error=True)
user32.GetWindowLongW.argtypes = [wt.HWND, ctypes.c_int]
user32.GetWindowLongW.restype = wt.LONG
user32.SetWindowLongW.argtypes = [wt.HWND, ctypes.c_int, wt.LONG]
user32.SetWindowLongW.restype = wt.LONG
GWL_EXSTYLE = -20
WS_EX_NOACTIVATE = 0x08000000
WS_EX_TRANSPARENT = 0x00000020
WS_EX_TOOLWINDOW = 0x00000080

WIDTH = 360
PADDING = 14
ICON_SIZE = 18
GAP = 10
RADIUS = 12
STRIPE = 4
# Bottom right, out of the recording capsule's way: the capsule owns the
# bottom centre, and a warning stacked on top of it hid the waveform.
RIGHT_MARGIN = 24
BOTTOM_MARGIN = 24
FADE_MS = 180
DEFAULT_LIFETIME_MS = 4200


class Level(str, Enum):
    INFO = "info"
    WARNING = "warning"
    ERROR = "error"


_ICONS = {Level.INFO: "info", Level.WARNING: "warning", Level.ERROR: "error"}


class Toast(QWidget):
    """One notification card. Owns its own fade-in, timer and fade-out."""

    def __init__(self, text: str, level: Level, lifetime_ms: int) -> None:
        super().__init__(None)
        self.setWindowFlags(
            Qt.WindowType.FramelessWindowHint
            | Qt.WindowType.Tool
            | Qt.WindowType.WindowStaysOnTopHint
            | Qt.WindowType.WindowDoesNotAcceptFocus
        )
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating)
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)

        self._text = text
        self._level = level
        self._palette = palette()
        self._opacity = 0.0
        self.closed = False

        font = QFont(self.font())
        font.setPointSizeF(9.5)
        self.setFont(font)

        metrics = QFontMetrics(font)
        text_width = WIDTH - 2 * PADDING - ICON_SIZE - GAP
        self._lines = _wrap(text, metrics, text_width)
        height = 2 * PADDING + max(ICON_SIZE,
                                   len(self._lines) * metrics.lineSpacing())
        self.resize(WIDTH, int(height))

        self._fade = QPropertyAnimation(self, b"fadeOpacity", self)
        self._fade.setEasingCurve(QEasingCurve.Type.OutCubic)
        self._fade.finished.connect(self._on_fade_finished)

        self._life = QTimer(self)
        self._life.setSingleShot(True)
        self._life.setInterval(lifetime_ms)
        self._life.timeout.connect(self.dismiss)

    # -- fade property -------------------------------------------------

    def _get_opacity(self) -> float:
        return self._opacity

    def _set_opacity(self, value: float) -> None:
        self._opacity = value
        self.setWindowOpacity(value)

    fadeOpacity = Property(float, _get_opacity, _set_opacity)

    # -- lifecycle -----------------------------------------------------

    def present(self) -> None:
        self._make_click_through()
        self.show()
        self._animate_to(1.0)
        self._life.start()

    def dismiss(self) -> None:
        if self.closed:
            return
        self.closed = True
        self._life.stop()
        self._animate_to(0.0)

    def _animate_to(self, target: float) -> None:
        self._fade.stop()
        self._fade.setDuration(FADE_MS)
        self._fade.setStartValue(self._opacity)
        self._fade.setEndValue(target)
        self._fade.start()

    def _on_fade_finished(self) -> None:
        if self._opacity <= 0.01:
            self.hide()
            self.deleteLater()

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

    # -- painting ------------------------------------------------------

    def paintEvent(self, event) -> None:  # noqa: N802 (Qt naming)
        p = self._palette
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)

        rect = QRectF(0.5, 0.5, self.width() - 1.0, self.height() - 1.0)
        path = QPainterPath()
        path.addRoundedRect(rect, RADIUS, RADIUS)
        painter.fillPath(path, QColor(p.card))

        # A stripe on the leading edge, so severity reads before the text.
        # Clipped to the card: a square-cornered bar drawn over a rounded
        # corner pokes out past the edge and onto the bare background.
        painter.save()
        painter.setClipPath(path)
        painter.fillRect(QRectF(rect.left(), rect.top(), STRIPE, rect.height()),
                         QColor(self._accent()))
        painter.restore()

        # A neutral outline. The stripe and the icon already carry the
        # severity; an accent-coloured border made every toast shout.
        painter.setPen(QColor(p.card_border))
        painter.drawPath(path)

        painter.drawPixmap(
            PADDING, PADDING,
            icons.pixmap(_ICONS[self._level], self._accent(), ICON_SIZE),
        )

        painter.setPen(QColor(p.text))
        metrics = QFontMetrics(self.font())
        x = PADDING + ICON_SIZE + GAP
        y = PADDING + metrics.ascent()
        for line in self._lines:
            painter.drawText(x, int(y), line)
            y += metrics.lineSpacing()
        painter.end()

    def _accent(self) -> str:
        p = self._palette
        return {Level.INFO: p.accent,
                Level.WARNING: p.warning,
                Level.ERROR: p.danger}[self._level]


class ToastManager:
    """Stacks toasts upward from the bottom right of the active screen."""

    MAX_VISIBLE = 3

    def __init__(self) -> None:
        self._toasts: list[Toast] = []

    def show(self, text: str, level: Level = Level.WARNING,
             lifetime_ms: int = DEFAULT_LIFETIME_MS) -> None:
        text = " ".join(str(text).split())
        if not text:
            return
        self._prune()
        # A repeated message re-arms the existing card instead of stacking
        # a second identical one: holding a dead hotkey should not bury
        # the screen in toasts.
        for existing in self._toasts:
            if existing._text == text:
                existing._life.start()
                return
        while len(self._toasts) >= self.MAX_VISIBLE:
            self._toasts.pop(0).dismiss()

        toast = Toast(text, level, lifetime_ms)
        self._toasts.append(toast)
        self._layout()
        toast.present()

    def clear(self) -> None:
        for toast in list(self._toasts):
            toast.dismiss()
        self._toasts.clear()

    def _prune(self) -> None:
        self._toasts = [t for t in self._toasts if not t.closed]

    def _layout(self) -> None:
        self._prune()
        screen = (QApplication.screenAt(_cursor_position())
                  or QApplication.primaryScreen())
        area = screen.availableGeometry()
        y = area.bottom() - BOTTOM_MARGIN
        for toast in reversed(self._toasts):
            y -= toast.height()
            toast.move(QPoint(area.right() - toast.width() - RIGHT_MARGIN, int(y)))
            y -= GAP


def _cursor_position() -> QPoint:
    from PySide6.QtGui import QCursor

    return QCursor.pos()


def _wrap(text: str, metrics: QFontMetrics, width: int) -> list[str]:
    lines: list[str] = []
    current = ""
    for word in text.split():
        candidate = f"{current} {word}".strip()
        if current and metrics.horizontalAdvance(candidate) > width:
            lines.append(current)
            current = word
        else:
            current = candidate
        if len(lines) == 3:
            break
    if current and len(lines) < 3:
        lines.append(current)
    if len(lines) == 3:
        lines[2] = metrics.elidedText(lines[2], Qt.TextElideMode.ElideRight, width)
    return lines or [text]
