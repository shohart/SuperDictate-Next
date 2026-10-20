"""Quick history as a stack of bubbles over the capsule.

The same idea as the transcript editor: a shortcut brings the capsule back
on screen, and the thing above it is the interface. Here it is not one
editable bubble but a short stack of them, newest at the bottom, each
sized to its own text the way the live preview bubble is. Arrow keys move
the selection, Enter drops the chosen transcript into the window the user
came from, Delete forgets one, Escape closes.

Only the last few entries are here. The full history — copy, clear, the
whole list — is still the window opened from the tray and the control
panel; this is the one-keystroke path back to something just said.

Like :mod:`superdictate.ui.editor` and unlike the rest of the HUD, this
window takes focus, which on Windows a background process cannot simply
ask for; see :func:`superdictate.ui.editor._take_foreground`.
"""

from __future__ import annotations

import ctypes
import ctypes.wintypes as wt
from typing import Optional, Sequence

from PySide6.QtCore import (
    Property,
    QEvent,
    QPoint,
    QPropertyAnimation,
    QRect,
    QRectF,
    Qt,
    Signal,
)
from PySide6.QtGui import QColor, QFont, QPainter, QPainterPath, QPen
from PySide6.QtWidgets import QApplication, QWidget

from .editor import _take_foreground
from .hud import (
    ANIMATE_IN_SECONDS,
    ANIMATE_OUT_SECONDS,
    BOTTOM_MARGIN,
    BUBBLE_TEXT,
    CAPSULE_BORDER,
    CAPSULE_FILL,
    _clamped_to_screen,
    _cursor_position,
)

# Enough to cover "the thing I said a moment ago and the few before it".
# More than this and picking with arrow keys stops being faster than
# opening the real history window.
MAX_ENTRIES = 6
ROW_HEIGHT = 32
ROW_SPACING = 6
PADDING = 17
MIN_WIDTH = 96
MAX_SCREEN_FRACTION = 0.5
# The same gap the preview bubble leaves above the capsule.
GAP = 9

# The selected bubble is lifted out of the stack rather than outlined in a
# colour: the accent already belongs to the capsule's bars, and a coloured
# ring around one bubble made the stack look like an error state.
SELECTED_FILL = QColor(58, 58, 62, 236)
SELECTED_BORDER = QColor(255, 255, 255, 92)
DIM_TEXT = QColor(236, 236, 240, 140)

user32 = ctypes.WinDLL("user32", use_last_error=True)
user32.GetForegroundWindow.restype = wt.HWND
user32.IsWindow.argtypes = [wt.HWND]


class BubbleHistory(QWidget):
    """The stack. ``chosen`` carries the text Enter was pressed on."""

    chosen = Signal(str)
    # The index within the entries this stack was given, so the caller can
    # delete from the real history without this window knowing about it.
    forgotten = Signal(int)
    closed = Signal()

    def __init__(self, anchor: Optional[QWidget] = None) -> None:
        super().__init__(None)
        # Focusable, unlike the capsule and the preview bubble: the arrow
        # keys have to arrive somewhere.
        self.setWindowFlags(
            Qt.WindowType.FramelessWindowHint
            | Qt.WindowType.Tool
            | Qt.WindowType.WindowStaysOnTopHint
        )
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setMouseTracking(True)
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)

        self._anchor = anchor
        self._entries: list[str] = []
        self._rows: list[QRect] = []
        self._selected = 0
        self._opacity = 0.0
        self._previous_window = 0
        self._closing = False
        self._settled = False

        font = QFont()
        font.setFamilies(["Segoe UI Variable Display", "Segoe UI Semibold",
                          "Segoe UI", "sans-serif"])
        font.setPointSizeF(10.5)
        font.setWeight(QFont.Weight.Medium)
        font.setLetterSpacing(QFont.SpacingType.PercentageSpacing, 100.5)
        self.setFont(font)

        self._fade = QPropertyAnimation(self, b"fadeOpacity", self)
        self._fade.finished.connect(self._fade_finished)

    def set_anchor(self, anchor: QWidget) -> None:
        self._anchor = anchor

    # -- fade property -------------------------------------------------

    def _get_opacity(self) -> float:
        return self._opacity

    def _set_opacity(self, value: float) -> None:
        self._opacity = value
        self.setWindowOpacity(value)

    fadeOpacity = Property(float, _get_opacity, _set_opacity)

    # -- opening and closing -------------------------------------------

    def present(self, entries: Sequence[str]) -> None:
        """Show the newest ``entries`` bottom-up, newest selected."""
        self._closing = False
        self._settled = False
        self._previous_window = int(user32.GetForegroundWindow() or 0)
        self._entries = [" ".join(text.split())
                         for text in entries[:MAX_ENTRIES]]
        self._selected = 0

        self._relayout()
        self.setWindowOpacity(0.0)
        self._opacity = 0.0
        self.show()
        self.raise_()
        self.activateWindow()
        _take_foreground(int(self.winId()))
        self.setFocus(Qt.FocusReason.OtherFocusReason)
        self._animate_to(1.0, ANIMATE_IN_SECONDS)

    def _choose(self) -> None:
        if not self._entries:
            self.cancel()
            return
        text = self._entries[self._selected]
        self._close()
        # After the close, so the window it goes to is already back in
        # front by the time anyone acts on this.
        self.chosen.emit(text)

    def _forget(self) -> None:
        """Drop the selected entry and stay open on what is left."""
        if not self._entries:
            return
        index = self._selected
        self.forgotten.emit(index)
        del self._entries[index]
        if not self._entries:
            self.cancel()
            return
        self._selected = min(index, len(self._entries) - 1)
        self._relayout()
        self.update()

    def cancel(self) -> None:
        self._close()

    def _close(self) -> None:
        if self._closing:
            return
        self._closing = True
        self.clearFocus()
        self._animate_to(0.0, ANIMATE_OUT_SECONDS)
        if self._previous_window and user32.IsWindow(wt.HWND(self._previous_window)):
            _take_foreground(self._previous_window)
        self.closed.emit()

    def _animate_to(self, target: float, seconds: float) -> None:
        self._fade.stop()
        self._fade.setDuration(int(seconds * 1000))
        self._fade.setStartValue(self._opacity)
        self._fade.setEndValue(target)
        self._fade.start()

    def _fade_finished(self) -> None:
        if self._opacity <= 0.01:
            self.hide()
        else:
            self._settled = True

    def event(self, incoming) -> bool:
        # Clicking into another window says "done here", the same bargain
        # the editor makes — and the only way out if the window failed to
        # take focus and the keys are going elsewhere.
        if (incoming.type() == QEvent.Type.WindowDeactivate
                and self._settled and not self._closing):
            self.cancel()
        return super().event(incoming)

    # -- input ---------------------------------------------------------

    def keyPressEvent(self, event) -> None:  # noqa: N802 (Qt naming)
        key = event.key()
        if key == Qt.Key.Key_Escape:
            self.cancel()
            return
        if key in (Qt.Key.Key_Return, Qt.Key.Key_Enter):
            self._choose()
            return
        if key == Qt.Key.Key_Delete:
            self._forget()
            return
        # Up walks back in time, which is up the screen: the newest entry
        # sits at the bottom, nearest the capsule.
        if key in (Qt.Key.Key_Up, Qt.Key.Key_Down) and self._entries:
            step = 1 if key == Qt.Key.Key_Up else -1
            self._selected = max(0, min(len(self._entries) - 1,
                                        self._selected + step))
            self.update()
            return
        super().keyPressEvent(event)

    def mouseMoveEvent(self, event) -> None:  # noqa: N802 (Qt naming)
        index = self._row_at(event.position().toPoint())
        if index is not None and index != self._selected:
            self._selected = index
            self.update()

    def mousePressEvent(self, event) -> None:  # noqa: N802 (Qt naming)
        index = self._row_at(event.position().toPoint())
        if index is None:
            return
        self._selected = index
        self._choose()

    def _row_at(self, point: QPoint) -> Optional[int]:
        for index, rect in enumerate(self._rows):
            if rect.contains(point):
                return index
        return None

    # -- geometry ------------------------------------------------------

    def _screen(self):
        if self._anchor is not None and self._anchor.isVisible():
            return (QApplication.screenAt(self._anchor.geometry().center())
                    or QApplication.primaryScreen())
        return (QApplication.screenAt(_cursor_position())
                or QApplication.primaryScreen())

    def _relayout(self) -> None:
        """Size to the widest bubble and sit above the capsule."""
        area = self._screen().availableGeometry()
        limit = int(area.width() * MAX_SCREEN_FRACTION)
        metrics = self.fontMetrics()
        widths = [max(MIN_WIDTH,
                      min(limit, metrics.horizontalAdvance(text) + PADDING * 2 + 4))
                  for text in self._entries] or [MIN_WIDTH]
        width = max(widths)
        count = max(1, len(self._entries))
        height = count * ROW_HEIGHT + (count - 1) * ROW_SPACING

        if self._anchor is not None and self._anchor.isVisible():
            capsule = self._anchor.geometry()
            bottom = capsule.top() - GAP
            centre_x = capsule.center().x()
        else:
            bottom = area.bottom() - BOTTOM_MARGIN
            centre_x = area.center().x()
        corner = _clamped_to_screen(
            QPoint(int(centre_x - width // 2), int(bottom - height)),
            width, height)
        self.setGeometry(QRect(corner.x(), corner.y(), width, height))

        # Each bubble keeps its own width and is centred, so the stack
        # reads as a conversation rather than as a list control.
        self._rows = []
        for index, own_width in enumerate(widths[:len(self._entries)]):
            top = height - (index + 1) * ROW_HEIGHT - index * ROW_SPACING
            self._rows.append(QRect((width - own_width) // 2, top,
                                    own_width, ROW_HEIGHT))

    # -- painting ------------------------------------------------------

    def paintEvent(self, event) -> None:  # noqa: N802 (Qt naming)
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        metrics = self.fontMetrics()

        for index, rect in enumerate(self._rows):
            selected = index == self._selected
            body = QRectF(rect).adjusted(0.5, 0.5, -0.5, -0.5)
            radius = body.height() / 2.0
            path = QPainterPath()
            path.addRoundedRect(body, radius, radius)
            painter.fillPath(path, SELECTED_FILL if selected else CAPSULE_FILL)
            painter.setPen(QPen(SELECTED_BORDER if selected else CAPSULE_BORDER,
                                1.0))
            painter.drawPath(path)

            inner = body.adjusted(PADDING, 0, -PADDING, 0)
            # Elided from the right, unlike the live preview: a past
            # transcript is recognised by how it starts.
            text = metrics.elidedText(self._entries[index],
                                      Qt.TextElideMode.ElideRight,
                                      int(inner.width()))
            painter.setPen(BUBBLE_TEXT if selected else DIM_TEXT)
            painter.drawText(inner,
                             Qt.AlignmentFlag.AlignLeft
                             | Qt.AlignmentFlag.AlignVCenter,
                             text)
        painter.end()
