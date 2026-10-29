"""Painted rows for the history and replacement lists.

Both lists used to be plain ``QListWidget`` items: one string per row,
built by gluing the fields together with spaces ("21.07 09:12   Привет")
or an arrow ("слышится как  →  заменить на"). That renders as one run of text
in a bordered box, so the timestamp competes with the transcript for
attention, a long line pushes a horizontal scrollbar under the list, and
the whole thing reads as a text area rather than a list of things.

Here each row is drawn as its own card with the fields in their own
columns and their own weight: the metadata recedes, the content leads,
and anything too long is elided instead of scrolled.
"""

from __future__ import annotations

from PySide6.QtCore import QEvent, QRectF, QSize, Qt
from PySide6.QtGui import QColor, QFont, QPainter, QPainterPath, QPen
from PySide6.QtWidgets import QStyle, QStyledItemDelegate

from .theme import Palette

# Roles the list widgets fill in; the delegate reads nothing else.
META_ROLE = Qt.ItemDataRole.UserRole + 1
PRIMARY_ROLE = Qt.ItemDataRole.UserRole + 2
SECONDARY_ROLE = Qt.ItemDataRole.UserRole + 3
#: The ASR hint column of the vocabulary list: HINT_ON / HINT_OFF, or
#: HINT_NONE for an entry that can never be a hotword (no box drawn).
HINT_ROLE = Qt.ItemDataRole.UserRole + 4
HINT_NONE, HINT_OFF, HINT_ON = -1, 0, 1

RADIUS = 9
PADDING_X = 12
GAP = 12


class CardRowDelegate(QStyledItemDelegate):
    """A rounded row that reacts to hover and selection."""

    HEIGHT = 40
    META_WIDTH = 92

    def __init__(self, palette: Palette, parent=None) -> None:
        super().__init__(parent)
        self.p = palette

    def sizeHint(self, option, index) -> QSize:  # noqa: N802 (Qt naming)
        return QSize(0, self.HEIGHT)

    def paint(self, painter: QPainter, option, index) -> None:
        painter.save()
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)

        selected = bool(option.state & QStyle.StateFlag.State_Selected)
        hovered = bool(option.state & QStyle.StateFlag.State_MouseOver)
        rect = QRectF(option.rect).adjusted(0, 1.5, 0, -1.5)
        path = QPainterPath()
        path.addRoundedRect(rect, RADIUS, RADIUS)
        if selected:
            painter.fillPath(path, QColor(self.p.accent))
        elif hovered:
            painter.fillPath(path, QColor(self.p.control_hover))
        else:
            painter.fillPath(path, QColor(self.p.control))

        content = rect.adjusted(PADDING_X, 0, -PADDING_X, 0)
        self.paint_content(painter, content, index, selected)
        painter.restore()

    # -- for subclasses ------------------------------------------------

    def paint_content(self, painter: QPainter, rect: QRectF, index,
                      selected: bool) -> None:
        raise NotImplementedError

    def _text_color(self, selected: bool) -> QColor:
        return QColor(self.p.accent_text if selected else self.p.text)

    def _muted_color(self, selected: bool) -> QColor:
        if not selected:
            return QColor(self.p.text_faint)
        # On the accent fill a grey would vanish, so the secondary text
        # is the same near-black at reduced opacity instead.
        colour = QColor(self.p.accent_text)
        colour.setAlpha(150)
        return colour

    @staticmethod
    def _draw(painter: QPainter, rect: QRectF, text: str,
              align=Qt.AlignmentFlag.AlignLeft) -> None:
        elided = painter.fontMetrics().elidedText(
            text, Qt.TextElideMode.ElideRight, int(rect.width()))
        painter.drawText(rect, int(align | Qt.AlignmentFlag.AlignVCenter), elided)


def _smaller(font: QFont, step: int = 2) -> QFont:
    """One notch down, whichever unit the font happens to be sized in.

    The stylesheet sets ``font-size`` in pixels, and a pixel-sized font
    reports ``pointSizeF() == -1``, so adjusting the point size blindly
    would produce a garbage value.
    """
    smaller = QFont(font)
    if font.pixelSize() > 0:
        smaller.setPixelSize(max(9, font.pixelSize() - step))
    else:
        smaller.setPointSizeF(max(7.0, font.pointSizeF() - step * 0.75))
    return smaller


class HistoryRowDelegate(CardRowDelegate):
    """Timestamp in its own column, transcript filling the rest."""

    def paint_content(self, painter, rect, index, selected) -> None:
        meta = str(index.data(META_ROLE) or "")
        text = str(index.data(PRIMARY_ROLE) or index.data(Qt.ItemDataRole.DisplayRole) or "")

        base = QFont(painter.font())
        painter.setFont(_smaller(base))
        painter.setPen(self._muted_color(selected))
        self._draw(painter, QRectF(rect.left(), rect.top(),
                                   self.META_WIDTH, rect.height()), meta)

        painter.setFont(base)
        body = QRectF(rect.left() + self.META_WIDTH + GAP, rect.top(),
                      rect.width() - self.META_WIDTH - GAP, rect.height())
        painter.setPen(self._text_color(selected))
        self._draw(painter, body, text)


class CorrectionRowDelegate(CardRowDelegate):
    """``source  ->  replacement``, each field in its own half, and the ASR
    hint checkbox at the right edge when the list has that column."""

    ARROW = "→"
    ARROW_WIDTH = 22
    HINT_WIDTH = 34
    BOX = 15

    def __init__(self, palette: Palette, parent=None, *, hint_column: bool = False,
                 on_hint_clicked=None) -> None:
        super().__init__(palette, parent)
        self.hint_column = hint_column
        #: ``on_hint_clicked(row)`` when a box is clicked.
        self.on_hint_clicked = on_hint_clicked

    def _hint_rect(self, option_rect) -> QRectF:
        rect = QRectF(option_rect).adjusted(0, 1.5, 0, -1.5).adjusted(PADDING_X, 0, -PADDING_X, 0)
        return QRectF(rect.right() - self.HINT_WIDTH, rect.top(), self.HINT_WIDTH, rect.height())

    def editorEvent(self, event, model, option, index):  # noqa: N802 (Qt naming)
        if (self.hint_column and event.type() == QEvent.Type.MouseButtonRelease
                and event.button() == Qt.MouseButton.LeftButton
                and index.data(HINT_ROLE) not in (None, HINT_NONE)
                and self._hint_rect(option.rect).contains(event.position())):
            if self.on_hint_clicked is not None:
                self.on_hint_clicked(index.row())
            return True
        return super().editorEvent(event, model, option, index)

    def _paint_hint(self, painter: QPainter, area: QRectF, state, selected: bool) -> None:
        if state in (None, HINT_NONE):
            return
        box = QRectF(area.center().x() - self.BOX / 2, area.center().y() - self.BOX / 2,
                     self.BOX, self.BOX)
        painter.save()
        if state == HINT_ON:
            fill = QColor(self.p.accent_text if selected else self.p.accent)
            path = QPainterPath()
            path.addRoundedRect(box, 4, 4)
            painter.fillPath(path, fill)
            tick = QPen(QColor(self.p.accent if selected else self.p.accent_text), 2)
            tick.setCapStyle(Qt.PenCapStyle.RoundCap)
            painter.setPen(tick)
            painter.drawPolyline([box.topLeft() + d for d in (
                _pt(3.5, 7.8), _pt(6.5, 10.8), _pt(11.5, 4.5))])
        else:
            painter.setPen(QPen(self._muted_color(selected), 1.3))
            painter.drawRoundedRect(box, 4, 4)
        painter.restore()

    def paint_content(self, painter, rect, index, selected) -> None:
        source = str(index.data(PRIMARY_ROLE) or "")
        replacement = str(index.data(SECONDARY_ROLE) or "")
        if self.hint_column:
            hint_area = QRectF(rect.right() - self.HINT_WIDTH, rect.top(),
                               self.HINT_WIDTH, rect.height())
            self._paint_hint(painter, hint_area, index.data(HINT_ROLE), selected)
            rect = QRectF(rect.left(), rect.top(), rect.width() - self.HINT_WIDTH - 6,
                          rect.height())

        half = (rect.width() - self.ARROW_WIDTH) / 2.0
        left = QRectF(rect.left(), rect.top(), half, rect.height())
        arrow = QRectF(left.right(), rect.top(), self.ARROW_WIDTH, rect.height())
        right = QRectF(arrow.right(), rect.top(), half, rect.height())

        painter.setPen(self._muted_color(selected))
        self._draw(painter, left, source)
        self._draw(painter, arrow, self.ARROW, Qt.AlignmentFlag.AlignHCenter)

        # The replacement is what actually ends up in the text, so it is
        # the one field that gets full-strength colour.
        bold = QFont(painter.font())
        bold.setWeight(QFont.Weight.DemiBold)
        painter.setFont(bold)
        painter.setPen(self._text_color(selected))
        self._draw(painter, right, replacement)


def _pt(x: float, y: float):
    from PySide6.QtCore import QPointF

    return QPointF(x, y)
