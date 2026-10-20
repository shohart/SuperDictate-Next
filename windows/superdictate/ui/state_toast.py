"""The small card that says what just changed, and the one that says wait.

Port of ``swift/Sources/Parakey/StateToast.swift``. Two shapes, one window:

* **State** — «Коррекция · вкл», «Режим · Задача». Two seconds, then gone.
  Shown when a hotkey changes something the user cannot otherwise see: the
  post-processing stages leave no trace in the capsule, so without this a
  press would be indistinguishable from a missed press.
* **Loading** — «Загружается модель…», with no timer. A cold LLM host takes
  tens of seconds to map several gigabytes, and without a card saying so the
  user watches a stalled capsule and concludes the app has hung.

Both sit above the capsule so the eye finds them where it already is,
falling back to the bottom-right corner when the capsule is hidden.

The tone is a coloured dot rather than a coloured card: at this size a
fully-tinted card reads as an alert, and none of these are alerts.
"""

from __future__ import annotations

from typing import Optional

from PySide6.QtCore import (Property, QEasingCurve, QPoint, QPropertyAnimation,
                            QRectF, Qt, QTimer)
from PySide6.QtGui import (QColor, QCursor, QFont, QFontMetrics, QPainter,
                           QPainterPath, QPen)
from PySide6.QtWidgets import QApplication, QWidget

from .theme import palette

PADDING_X = 14
PADDING_Y = 9
RADIUS = 9
DOT = 7
GAP = 9
FADE_MS = 180
BOTTOM_MARGIN = 24
#: The capsule's own bottom margin plus its height plus a gap, so the card
#: clears it rather than landing on it.
ABOVE_CAPSULE_MARGIN = 92

LIFETIME_MS = 2000

#: Tone → dot colour. The three rewrite styles get their own so that
#: cycling through them reads as movement rather than three identical
#: cards; the values are the macOS ones.
_TONES: dict[str, str] = {
    "on": "#30d158",               # systemGreen
    "off": "#8e8e93",              # systemGray
    "polish": "#40c8e0",           # systemTeal
    "structured_task": "#ff9f0a",  # systemOrange
    "official": "#5e5ce6",         # systemIndigo
    "loading": "#0a84ff",          # systemBlue
}


class StateToast(QWidget):
    """One card. Auto-dismissing, or persistent when it is a loading card."""

    def __init__(self, text: str, tone: str = "on",
                 persistent: bool = False) -> None:
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
        self._tone = tone
        self._palette = palette()
        self._opacity = 0.0

        font = QFont(self.font())
        font.setPointSizeF(9.5)
        font.setWeight(QFont.Weight.DemiBold)
        self.setFont(font)
        metrics = QFontMetrics(font)
        width = (PADDING_X * 2 + DOT + GAP + metrics.horizontalAdvance(text))
        self.resize(int(width), int(PADDING_Y * 2 + metrics.height()))

        self._fade = QPropertyAnimation(self, b"fadeOpacity", self)
        self._fade.setEasingCurve(QEasingCurve.Type.OutCubic)
        self._fade.finished.connect(self._on_fade_finished)

        self._life: Optional[QTimer] = None
        if not persistent:
            self._life = QTimer(self)
            self._life.setSingleShot(True)
            self._life.setInterval(LIFETIME_MS)
            self._life.timeout.connect(self.dismiss)

    # -- fade property -----------------------------------------------

    def _get_opacity(self) -> float:
        return self._opacity

    def _set_opacity(self, value: float) -> None:
        self._opacity = value
        self.setWindowOpacity(value)

    fadeOpacity = Property(float, _get_opacity, _set_opacity)

    # -- lifecycle ---------------------------------------------------

    def present(self) -> None:
        self._position()
        self.show()
        self._animate_to(1.0)
        if self._life is not None:
            self._life.start()

    def dismiss(self) -> None:
        if self._life is not None:
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
            self.close()
            self.deleteLater()

    def _position(self) -> None:
        screen = QApplication.screenAt(QCursor.pos()) or QApplication.primaryScreen()
        area = screen.availableGeometry()
        self.move(QPoint(area.center().x() - self.width() // 2,
                         area.bottom() - self.height() - ABOVE_CAPSULE_MARGIN))

    # -- painting ----------------------------------------------------

    def paintEvent(self, event) -> None:  # noqa: N802 (Qt naming)
        p = self._palette
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)

        rect = QRectF(0.5, 0.5, self.width() - 1.0, self.height() - 1.0)
        path = QPainterPath()
        path.addRoundedRect(rect, RADIUS, RADIUS)
        painter.fillPath(path, QColor(p.card))
        painter.setPen(QPen(QColor(p.card_border), 1.0))
        painter.drawPath(path)

        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(QColor(_TONES.get(self._tone, _TONES["on"])))
        centre_y = self.height() / 2.0
        painter.drawEllipse(QRectF(PADDING_X, centre_y - DOT / 2.0, DOT, DOT))

        painter.setPen(QColor(p.text))
        metrics = QFontMetrics(self.font())
        painter.drawText(int(PADDING_X + DOT + GAP),
                         int(centre_y + metrics.ascent() / 2.0 - metrics.descent() / 2.0),
                         self._text)
        painter.end()


class StateToastController:
    """One card at a time, so a burst of hotkeys does not stack up.

    The loading card is tracked separately from the state cards: a state
    change during a cold model load must not dismiss the "please wait" the
    user is relying on.
    """

    def __init__(self) -> None:
        self._current: Optional[StateToast] = None
        self._loading: Optional[StateToast] = None

    def show(self, text: str, tone: str = "on") -> None:
        if self._current is not None:
            self._current.dismiss()
        toast = StateToast(text, tone)
        self._current = toast
        toast.destroyed.connect(lambda *_: self._forget(toast))
        toast.present()

    def show_loading(self, text: str) -> None:
        if self._loading is not None:
            self._loading.dismiss()
        toast = StateToast(text, "loading", persistent=True)
        self._loading = toast
        toast.present()

    def dismiss_loading(self) -> None:
        if self._loading is not None:
            self._loading.dismiss()
            self._loading = None

    def _forget(self, toast: StateToast) -> None:
        if self._current is toast:
            self._current = None
