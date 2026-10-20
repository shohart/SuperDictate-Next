"""The toast shown when a correction has just been learned, with an undo.

Port of ``swift/Sources/Parakey/VocabularyLearnedToast.swift``. The
interaction model is the macOS one exactly: the rule is already written when
the toast appears, the toast is the window in which to take it back, and
letting it time out keeps it.

    «Запомнил: гитхаб → GitHub»            [Отменить]

Seven seconds, then it fades and the rule stands. Escape or a click on
*Отменить* removes it again; Enter confirms immediately and dismisses.

Why an undo rather than a confirmation prompt: learning is worth having
precisely because it costs the user nothing, and a dialog on every
hand-correction would cost more attention than the feature saves. The one
thing that must not happen is a rule learned from a typo the user meant to
keep — so the toast stays on screen long enough to notice, and reversing it
is one key.

Unlike :class:`superdictate.ui.toast.Toast` this window accepts the mouse:
it has a button. It still never takes focus, so it cannot steal a keystroke
from whatever the user is typing into.
"""

from __future__ import annotations

from typing import Callable, Optional, Sequence

from PySide6.QtCore import (Property, QEasingCurve, QPoint, QPropertyAnimation,
                            QRectF, Qt, QTimer, Signal)
from PySide6.QtGui import (QColor, QCursor, QFont, QFontMetrics, QPainter,
                           QPainterPath)
from PySide6.QtWidgets import QApplication, QWidget

from .. import i18n
from ..logging_setup import get as get_logger
from .theme import palette

log = get_logger("ui.learn_toast")

WIDTH = 380
PADDING = 14
RADIUS = 10
STRIPE = 3
GAP = 10
FADE_MS = 180
BOTTOM_MARGIN = 24

#: Matches the macOS toast's own auto-dismiss window. Long enough to read a
#: two-word rule and reach for Escape, short enough not to sit in the way.
LIFETIME_MS = 7000

UNDO_HEIGHT = 22


class LearnedToast(QWidget):
    """One learned-rule card. Confirms on timeout, reverses on demand."""

    #: Emitted with the source words whose rules should be removed again.
    undone = Signal(list)

    def __init__(self, pairs: Sequence[tuple[str, str]],
                 on_undo: Optional[Callable[[list[str]], None]] = None) -> None:
        super().__init__(None)
        self.setWindowFlags(
            Qt.WindowType.FramelessWindowHint
            | Qt.WindowType.Tool
            | Qt.WindowType.WindowStaysOnTopHint
            | Qt.WindowType.WindowDoesNotAcceptFocus
        )
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating)
        # Deliberately NOT WA_TransparentForMouseEvents: this toast has a
        # button, which is the whole point of it.

        self._pairs = list(pairs)
        self._palette = palette()
        self._opacity = 0.0
        self._undo_hover = False
        self._settled = False
        if on_undo is not None:
            self.undone.connect(on_undo)

        font = QFont(self.font())
        font.setPointSizeF(9.5)
        self.setFont(font)
        metrics = QFontMetrics(font)

        self._lines = [self._describe(source, replacement)
                       for source, replacement in self._pairs]
        text_height = max(1, len(self._lines)) * metrics.lineSpacing()
        self.resize(WIDTH, int(2 * PADDING + text_height + GAP + UNDO_HEIGHT))

        self._undo_label = i18n.tr("vocabulary_undo")
        self._undo_rect = QRectF(
            WIDTH - PADDING - metrics.horizontalAdvance(self._undo_label) - 16,
            self.height() - PADDING - UNDO_HEIGHT,
            metrics.horizontalAdvance(self._undo_label) + 16,
            UNDO_HEIGHT,
        )
        self.setMouseTracking(True)
        self.setCursor(QCursor(Qt.CursorShape.ArrowCursor))

        self._fade = QPropertyAnimation(self, b"fadeOpacity", self)
        self._fade.setEasingCurve(QEasingCurve.Type.OutCubic)
        self._fade.finished.connect(self._on_fade_finished)

        self._life = QTimer(self)
        self._life.setSingleShot(True)
        self._life.setInterval(LIFETIME_MS)
        self._life.timeout.connect(self.confirm)

    @staticmethod
    def _describe(source: str, replacement: str) -> str:
        return f"{source} → {replacement}"

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
        self._life.start()

    def confirm(self) -> None:
        """Keep the rules and fade out. The timeout path, and Enter."""
        if self._settled:
            return
        self._settled = True
        self._dismiss()

    def undo(self) -> None:
        """Take the rules back, then fade out. Escape, and the button."""
        if self._settled:
            return
        self._settled = True
        sources = [source for source, _ in self._pairs]
        log.info("Undoing %d learned correction(s)", len(sources))
        self.undone.emit(sources)
        self._dismiss()

    def _dismiss(self) -> None:
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
                         area.bottom() - self.height() - BOTTOM_MARGIN))

    # -- input -------------------------------------------------------

    def mousePressEvent(self, event) -> None:  # noqa: N802 (Qt naming)
        if self._undo_rect.contains(event.position()):
            self.undo()
        else:
            event.ignore()

    def mouseMoveEvent(self, event) -> None:  # noqa: N802 (Qt naming)
        hovering = self._undo_rect.contains(event.position())
        if hovering != self._undo_hover:
            self._undo_hover = hovering
            self.setCursor(QCursor(Qt.CursorShape.PointingHandCursor if hovering
                                   else Qt.CursorShape.ArrowCursor))
            self.update()

    def leaveEvent(self, event) -> None:  # noqa: N802 (Qt naming)
        if self._undo_hover:
            self._undo_hover = False
            self.update()

    def handle_key(self, is_escape: bool) -> bool:
        """Called by the hotkey hook while this toast is up.

        Returns True when the key was consumed, so the hook can suppress it
        rather than letting Escape reach whatever is underneath.
        """
        if self._settled:
            return False
        if is_escape:
            self.undo()
        else:
            self.confirm()
        return True

    # -- painting ----------------------------------------------------

    def paintEvent(self, event) -> None:  # noqa: N802 (Qt naming)
        p = self._palette
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)

        rect = QRectF(0.5, 0.5, self.width() - 1.0, self.height() - 1.0)
        path = QPainterPath()
        path.addRoundedRect(rect, RADIUS, RADIUS)
        painter.fillPath(path, QColor(p.card))

        painter.save()
        painter.setClipPath(path)
        painter.fillRect(QRectF(rect.left(), rect.top(), STRIPE, rect.height()),
                         QColor(p.accent))
        painter.restore()

        painter.setPen(QColor(p.card_border))
        painter.drawPath(path)

        metrics = QFontMetrics(self.font())
        painter.setPen(QColor(p.text))
        x = PADDING + STRIPE + GAP
        y = PADDING + metrics.ascent()
        heading = i18n.tr("vocabulary_learned_title")
        painter.drawText(x, int(y), heading)
        y += metrics.lineSpacing()
        for line in self._lines:
            painter.drawText(x, int(y), line)
            y += metrics.lineSpacing()

        painter.setPen(QColor(p.accent if self._undo_hover else p.text_muted))
        painter.drawText(self._undo_rect, Qt.AlignmentFlag.AlignCenter,
                         self._undo_label)
        painter.end()
