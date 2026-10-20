"""The transcript editor: the preview bubble, but you can type in it.

One shortcut brings the capsule back on screen with the last dictation
above it, and that bubble is a real text field — caret, arrow keys, click
between two letters, selection. Enter keeps the edit, Escape drops it. No
window frame, no buttons, nothing else on screen.

Everything about it runs against the grain of the rest of :mod:`hud`,
which exists precisely so the HUD never takes focus: the capsule carries
``WS_EX_NOACTIVATE`` and ``WS_EX_TRANSPARENT`` so a click falls through to
whatever the user was typing in. This window wants the opposite, and on
Windows wanting it is not enough — a process that does not own the
foreground cannot simply call ``SetForegroundWindow``. The usual remedy is
to borrow the foreground thread's input queue for the duration of the
call, which is what :func:`_take_foreground` does.

The window the user came from is remembered on the way in and handed the
foreground back on the way out, so correcting a word never costs them the
place they were typing.
"""

from __future__ import annotations

import ctypes
import ctypes.wintypes as wt
from typing import Optional

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
from PySide6.QtGui import (
    QFont,
    QPainter,
    QPainterPath,
    QPen,
    QTextCursor,
)
from PySide6.QtWidgets import QApplication, QTextEdit, QWidget

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

# Wide enough that correcting a word does not reflow the whole sentence,
# narrow enough to stay a bubble. The width is chosen when the editor
# opens and then held: text that rewrapped under the caret on every
# keystroke would be unusable.
MIN_WIDTH = 380
MAX_SCREEN_FRACTION = 0.5
PADDING_X = 16
PADDING_Y = 7
# Past this the field scrolls instead of climbing further up the screen.
MAX_LINES = 6
# The same gap the preview bubble leaves above the capsule.
GAP = 9
CORNER_RADIUS = 16
SELECTION_FILL = "#3f5f9e"

user32 = ctypes.WinDLL("user32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
user32.GetForegroundWindow.restype = wt.HWND
user32.SetForegroundWindow.argtypes = [wt.HWND]
user32.GetWindowThreadProcessId.argtypes = [wt.HWND, ctypes.c_void_p]
user32.GetWindowThreadProcessId.restype = wt.DWORD
user32.AttachThreadInput.argtypes = [wt.DWORD, wt.DWORD, wt.BOOL]
user32.IsWindow.argtypes = [wt.HWND]


def _take_foreground(handle: int) -> None:
    """Put ``handle`` in front, from a process that is not in front.

    Windows refuses ``SetForegroundWindow`` to an application the user is
    not currently interacting with — which is exactly our situation, since
    the request arrives through a global keyboard hook while somebody
    else's window is active. Attaching to that window's input queue makes
    the two threads share one notion of focus for the length of the call,
    and the refusal no longer applies. The attachment is undone straight
    away; leaving it in place would tie our message loop to theirs.
    """
    if not handle:
        return
    foreground = user32.GetForegroundWindow()
    ours = kernel32.GetCurrentThreadId()
    theirs = (user32.GetWindowThreadProcessId(foreground, None)
              if foreground else 0)
    attached = bool(theirs and theirs != ours
                    and user32.AttachThreadInput(theirs, ours, True))
    try:
        user32.SetForegroundWindow(wt.HWND(handle))
    finally:
        if attached:
            user32.AttachThreadInput(theirs, ours, False)


class _Field(QTextEdit):
    """The text area. Enter and Escape belong to the editor, not to it."""

    accepted = Signal()
    cancelled = Signal()

    def keyPressEvent(self, event) -> None:  # noqa: N802 (Qt naming)
        key = event.key()
        if key == Qt.Key.Key_Escape:
            self.cancelled.emit()
            return
        if key in (Qt.Key.Key_Return, Qt.Key.Key_Enter):
            # Shift+Enter is how you get an actual line break, the same
            # bargain every chat window makes.
            if event.modifiers() & Qt.KeyboardModifier.ShiftModifier:
                super().keyPressEvent(event)
                return
            self.accepted.emit()
            return
        super().keyPressEvent(event)


class TranscriptEditor(QWidget):
    """The editable bubble. ``applied`` carries the text Enter was pressed on."""

    applied = Signal(str)
    closed = Signal()

    def __init__(self, anchor: Optional[QWidget] = None) -> None:
        super().__init__(None)
        # No WindowDoesNotAcceptFocus and no BypassWindowManagerHint here,
        # unlike every other HUD window: this one is meant to be typed in.
        self.setWindowFlags(
            Qt.WindowType.FramelessWindowHint
            | Qt.WindowType.Tool
            | Qt.WindowType.WindowStaysOnTopHint
        )
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)

        self._anchor = anchor
        self._opacity = 0.0
        self._previous_window = 0
        self._width = MIN_WIDTH
        self._closing = False
        self._settled = False

        font = QFont()
        font.setFamilies(["Segoe UI Variable Display", "Segoe UI Semibold",
                          "Segoe UI", "sans-serif"])
        font.setPointSizeF(10.5)
        font.setWeight(QFont.Weight.Medium)

        self._field = _Field(self)
        self._field.setFont(font)
        self._field.setFrameShape(QTextEdit.Shape.NoFrame)
        self._field.setLineWrapMode(QTextEdit.LineWrapMode.WidgetWidth)
        self._field.setVerticalScrollBarPolicy(
            Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self._field.setHorizontalScrollBarPolicy(
            Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self._field.setStyleSheet(
            "QTextEdit {"
            " background: transparent;"
            " border: none;"
            f" color: {BUBBLE_TEXT.name()};"
            f" selection-background-color: {SELECTION_FILL};"
            f" selection-color: {BUBBLE_TEXT.name()};"
            " }"
        )
        self._field.document().setDocumentMargin(0)
        # Centred, like the preview bubble's text and the capsule's bars.
        # Left-aligned text in a bubble sized to the text puts the last
        # word hard against the right edge and leaves a ragged gap on the
        # second line.
        option = self._field.document().defaultTextOption()
        option.setAlignment(Qt.AlignmentFlag.AlignHCenter)
        self._field.document().setDefaultTextOption(option)
        # Placed by hand rather than by a layout. A QTextEdit asks for
        # several lines' worth of minimum height, and a layout honours
        # that: the bubble came out twice as tall as its one line of text
        # and then refused to grow, because the second line still fitted
        # inside the minimum.
        self._field.setMinimumSize(0, 0)
        self._field.accepted.connect(self._accept)
        self._field.cancelled.connect(self.cancel)
        self._field.textChanged.connect(self._relayout)

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

    def edit(self, text: str) -> None:
        """Show the bubble on ``text``, with the caret at the end of it."""
        self._closing = False
        self._settled = False
        self._previous_window = int(user32.GetForegroundWindow() or 0)
        self._width = self._preferred_width(text)

        self._field.blockSignals(True)
        self._field.setPlainText(text)
        # setPlainText builds the block with the widget's own alignment,
        # not the document default, so it has to be said again here.
        self._field.selectAll()
        self._field.setAlignment(Qt.AlignmentFlag.AlignHCenter)
        self._field.blockSignals(False)
        self._field.moveCursor(QTextCursor.MoveOperation.End)

        self._relayout()
        self.setWindowOpacity(0.0)
        self._opacity = 0.0
        self.show()
        self.raise_()
        self.activateWindow()
        _take_foreground(int(self.winId()))
        self._field.setFocus(Qt.FocusReason.OtherFocusReason)
        self._animate_to(1.0, ANIMATE_IN_SECONDS)

    def _accept(self) -> None:
        self.applied.emit(self._field.toPlainText().strip())
        self._close()

    def cancel(self) -> None:
        self._close()

    def _close(self) -> None:
        if self._closing:
            return
        self._closing = True
        self._field.clearFocus()
        self._animate_to(0.0, ANIMATE_OUT_SECONDS)
        # The window the dictation was typed into gets the foreground back
        # before the fade has even finished, so the caret returns to where
        # the user left it rather than a quarter of a second later.
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
        # Clicking into another window says "done here" as plainly as
        # Escape does, and without this an editor that failed to take
        # focus in the first place could not be dismissed at all.
        if (incoming.type() == QEvent.Type.WindowDeactivate
                and self._settled and not self._closing):
            self.cancel()
        return super().event(incoming)

    # -- geometry ------------------------------------------------------

    def _screen(self):
        if self._anchor is not None and self._anchor.isVisible():
            return (QApplication.screenAt(self._anchor.geometry().center())
                    or QApplication.primaryScreen())
        return (QApplication.screenAt(_cursor_position())
                or QApplication.primaryScreen())

    def _preferred_width(self, text: str) -> int:
        area = self._screen().availableGeometry()
        limit = int(area.width() * MAX_SCREEN_FRACTION)
        wanted = (self._field.fontMetrics().horizontalAdvance(text)
                  + PADDING_X * 2 + 8)
        return max(min(MIN_WIDTH, limit), min(limit, wanted))

    def _relayout(self) -> None:
        """Size to the text and sit above the capsule, growing upward."""
        inner = self._width - PADDING_X * 2
        document = self._field.document()
        document.setTextWidth(inner)
        line = self._field.fontMetrics().lineSpacing()
        text_height = max(line, min(line * MAX_LINES,
                                    int(document.size().height()) + 1))
        height = text_height + PADDING_Y * 2

        area = self._screen().availableGeometry()
        if self._anchor is not None and self._anchor.isVisible():
            capsule = self._anchor.geometry()
            bottom = capsule.top() - GAP
            centre_x = capsule.center().x()
        else:
            bottom = area.bottom() - BOTTOM_MARGIN
            centre_x = area.center().x()
        corner = _clamped_to_screen(
            QPoint(int(centre_x - self._width // 2), int(bottom - height)),
            self._width, height)
        self.setGeometry(QRect(corner.x(), corner.y(), self._width, height))
        self._field.ensureCursorVisible()

    def resizeEvent(self, event) -> None:  # noqa: N802 (Qt naming)
        self._field.setGeometry(PADDING_X, PADDING_Y,
                                max(1, self.width() - PADDING_X * 2),
                                max(1, self.height() - PADDING_Y * 2))
        super().resizeEvent(event)

    # -- painting ------------------------------------------------------

    def paintEvent(self, event) -> None:  # noqa: N802 (Qt naming)
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        rect = QRectF(0.5, 0.5, self.width() - 1.0, self.height() - 1.0)
        radius = min(CORNER_RADIUS, rect.height() / 2.0)
        path = QPainterPath()
        path.addRoundedRect(rect, radius, radius)
        painter.fillPath(path, CAPSULE_FILL)
        painter.setPen(QPen(CAPSULE_BORDER, 1.0))
        painter.drawPath(path)
        painter.end()
