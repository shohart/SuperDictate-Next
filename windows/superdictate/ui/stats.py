"""Usage statistics as a grid of cards rather than two lines of text.

Three pieces, all driven by :class:`~superdictate.history.UsageStats`:

* metric tiles, today and all-time totals at a glance;
* a 14-day bar chart, so a change in habit is visible;
* a contribution-style heatmap of the last 17 weeks.

Everything is painted with QPainter: no chart library, no external assets,
and it follows the app palette in both light and dark.
"""

from __future__ import annotations

import math
from datetime import date, timedelta

from PySide6.QtCore import QRectF, Qt
from PySide6.QtGui import QColor, QFont, QPainter, QPainterPath
from PySide6.QtWidgets import (
    QGridLayout,
    QHBoxLayout,
    QLabel,
    QSizePolicy,
    QVBoxLayout,
    QWidget,
)

from .. import i18n
from . import icons
from .theme import Palette, palette

WEEKS = 17
BAR_DAYS = 14
# Where a number stops being read and starts being measured. The tiles are
# one line of large type in a narrow card, and a word count reaches six
# digits within a few months of daily use: "125К" fits and is understood
# at a glance, "125431" is neither.
COMPACT_FROM = 1000


def _card(parent: QWidget | None = None) -> QWidget:
    widget = QWidget(parent)
    widget.setObjectName("Card")
    return widget


def _blend(base: str, other: str, ratio: float) -> QColor:
    a, b = QColor(base), QColor(other)
    return QColor(
        int(a.red() + (b.red() - a.red()) * ratio),
        int(a.green() + (b.green() - a.green()) * ratio),
        int(a.blue() + (b.blue() - a.blue()) * ratio),
    )


class MetricTile(QWidget):
    """One big number with a caption and an icon."""

    def __init__(self, icon_name: str, caption: str, parent=None) -> None:
        super().__init__(parent)
        self.setObjectName("Card")
        # A QWidget *subclass* ignores a stylesheet background unless it
        # opts in; plain QWidget instances get it for free.
        self.setAttribute(Qt.WidgetAttribute.WA_StyledBackground, True)
        self._palette = palette()

        layout = QVBoxLayout(self)
        layout.setContentsMargins(14, 12, 14, 12)
        layout.setSpacing(2)

        head = QHBoxLayout()
        head.setSpacing(6)
        glyph = QLabel()
        glyph.setPixmap(icons.pixmap(icon_name, self._palette.text_faint, 14))
        glyph.setStyleSheet("background: transparent;")
        self._caption = QLabel(caption)
        self._caption.setObjectName("CardTitle")
        head.addWidget(glyph)
        head.addWidget(self._caption)
        head.addStretch(1)
        layout.addLayout(head)

        self._value = QLabel("0")
        self._value.setObjectName("Metric")
        layout.addWidget(self._value)

        self._unit = QLabel("")
        self._unit.setObjectName("MetricUnit")
        layout.addWidget(self._unit)

    def set_value(self, value: str, unit: str = "") -> None:
        self._value.setText(value)
        self._unit.setText(unit)


class BarChart(QWidget):
    """Dictations per day for the last two weeks."""

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self._palette = palette()
        self._values: list[tuple[str, int]] = []
        self.setMinimumHeight(96)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)

    def set_days(self, by_day: dict[str, int]) -> None:
        today = date.today()
        self._values = [
            (
                (today - timedelta(days=offset)).isoformat(),
                by_day.get((today - timedelta(days=offset)).isoformat(), 0),
            )
            for offset in range(BAR_DAYS - 1, -1, -1)
        ]
        self.update()

    def paintEvent(self, event) -> None:  # noqa: N802 (Qt naming)
        if not self._values:
            return
        p = self._palette
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.setPen(Qt.PenStyle.NoPen)

        label_height = 14
        top = 4
        usable = self.height() - label_height - top
        peak = max((value for _, value in self._values), default=0)
        count = len(self._values)
        slot = self.width() / count
        bar_width = min(18.0, slot * 0.62)

        font = QFont(self.font())
        font.setPointSizeF(7.5)
        painter.setFont(font)

        for index, (day, value) in enumerate(self._values):
            centre = slot * (index + 0.5)
            height = (value / peak) * usable if peak else 0.0
            height = max(height, 3.0) if value else 3.0
            rect = QRectF(centre - bar_width / 2, top + usable - height,
                          bar_width, height)
            path = QPainterPath()
            path.addRoundedRect(rect, 4, 4)
            if value:
                ratio = value / peak if peak else 0.0
                painter.setBrush(_blend(p.grid_empty, p.accent, 0.35 + 0.65 * ratio))
            else:
                painter.setBrush(QColor(p.grid_empty))
            painter.fillPath(path, painter.brush())

            # Only label a few ticks, or the axis turns into a smear.
            if index % 3 == 0 or index == count - 1:
                painter.setPen(QColor(p.text_faint))
                painter.drawText(
                    QRectF(centre - slot / 2, self.height() - label_height,
                           slot, label_height),
                    Qt.AlignmentFlag.AlignCenter,
                    day[8:10] + "." + day[5:7],
                )
                painter.setPen(Qt.PenStyle.NoPen)
        painter.end()


class ActivityGrid(QWidget):
    """Contribution-style heatmap: one column per week, one cell per day."""

    CELL = 13
    GAP = 3

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self._palette = palette()
        self._by_day: dict[str, int] = {}
        self.setMinimumHeight(7 * (self.CELL + self.GAP) + 18)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
        self.setMouseTracking(True)

    def set_days(self, by_day: dict[str, int]) -> None:
        self._by_day = by_day
        self.update()

    def _grid_start(self) -> date:
        today = date.today()
        # Monday of the week that starts the window.
        start = today - timedelta(days=(WEEKS - 1) * 7)
        return start - timedelta(days=start.weekday())

    def paintEvent(self, event) -> None:  # noqa: N802 (Qt naming)
        p = self._palette
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.setPen(Qt.PenStyle.NoPen)

        peak = max(self._by_day.values(), default=0)
        start = self._grid_start()
        today = date.today()
        step = self.CELL + self.GAP

        font = QFont(self.font())
        font.setPointSizeF(7.5)
        painter.setFont(font)
        month_row = 12

        last_month = ""
        last_label_week = -3
        for week in range(WEEKS):
            for weekday in range(7):
                day = start + timedelta(days=week * 7 + weekday)
                if day > today:
                    continue
                rect = QRectF(week * step, month_row + weekday * step,
                              self.CELL, self.CELL)
                path = QPainterPath()
                path.addRoundedRect(rect, 3, 3)
                count = self._by_day.get(day.isoformat(), 0)
                if count:
                    ratio = count / peak if peak else 0.0
                    colour = _blend(p.grid_empty, p.accent, 0.3 + 0.7 * ratio)
                else:
                    colour = QColor(p.grid_empty)
                painter.fillPath(path, colour)

            month = i18n.month_abbr((start + timedelta(days=week * 7)).month)
            # A label is three columns wide, so a month that starts one
            # week after the previous label would overprint it ("MarApr").
            if month != last_month:
                last_month = month
                if week - last_label_week >= 3:
                    painter.setPen(QColor(p.text_faint))
                    painter.drawText(QRectF(week * step, 0, step * 3, month_row),
                                     Qt.AlignmentFlag.AlignLeft
                                     | Qt.AlignmentFlag.AlignVCenter, month)
                    painter.setPen(Qt.PenStyle.NoPen)
                    last_label_week = week
        painter.end()

    def mouseMoveEvent(self, event) -> None:  # noqa: N802 (Qt naming)
        step = self.CELL + self.GAP
        week = int(event.position().x() // step)
        weekday = int((event.position().y() - 12) // step)
        if 0 <= week < WEEKS and 0 <= weekday < 7:
            day = self._grid_start() + timedelta(days=week * 7 + weekday)
            if day <= date.today():
                count = self._by_day.get(day.isoformat(), 0)
                self.setToolTip(
                    f"{day.strftime('%d.%m.%Y')}: "
                    f"{count} {i18n.tr('panel_dictations')}"
                )
                return
        self.setToolTip("")


class StatsPanel(QWidget):
    """The whole statistics block: tiles, bars, heatmap."""

    def __init__(self, usage, parent=None) -> None:
        super().__init__(parent)
        self._usage = usage
        self._palette: Palette = palette()

        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(10)

        tiles = QGridLayout()
        tiles.setSpacing(10)
        self._tiles = {
            "today": MetricTile("mic", i18n.tr("stats_today_dictations")),
            "words": MetricTile("words", i18n.tr("stats_today_words")),
            "total": MetricTile("chart", i18n.tr("stats_total_dictations")),
            "time": MetricTile("clock", i18n.tr("stats_total_time")),
        }
        for column, key in enumerate(("today", "words", "total", "time")):
            tiles.addWidget(self._tiles[key], 0, column)
            tiles.setColumnStretch(column, 1)
        layout.addLayout(tiles)

        bars_card = _card()
        bars_layout = QVBoxLayout(bars_card)
        bars_layout.setContentsMargins(14, 12, 14, 10)
        bars_layout.setSpacing(8)
        bars_title = QLabel(i18n.tr("stats_last_14_days"))
        bars_title.setObjectName("CardTitle")
        bars_layout.addWidget(bars_title)
        self._bars = BarChart()
        bars_layout.addWidget(self._bars)
        layout.addWidget(bars_card)

        grid_card = _card()
        grid_layout = QVBoxLayout(grid_card)
        grid_layout.setContentsMargins(14, 12, 14, 12)
        grid_layout.setSpacing(8)
        grid_title = QLabel(i18n.tr("stats_activity"))
        grid_title.setObjectName("CardTitle")
        grid_layout.addWidget(grid_title)
        self._grid = ActivityGrid()
        grid_layout.addWidget(self._grid)
        layout.addWidget(grid_card)

        self.refresh()

    def refresh(self) -> None:
        today = self._usage.today()
        total = self._usage.totals()
        by_day = {day.day: day.dictations for day in self._usage.all_days()}

        self._tiles["today"].set_value(compact(today.dictations),
                                       i18n.tr("stats_unit_today"))
        self._tiles["words"].set_value(compact(today.words),
                                       i18n.tr("stats_unit_words_today"))
        self._tiles["total"].set_value(
            compact(total.dictations),
            f"{compact(total.words)} {i18n.tr('panel_words')}")
        value, unit = _format_duration(total.audio_seconds)
        self._tiles["time"].set_value(value, unit)
        self._bars.set_days(by_day)
        self._grid.set_days(by_day)


def compact(value: int) -> str:
    """1000 and up as "1К" / "1,5К" / "125К" / "2,4М".

    Rounded down, never up: a tile that reads 1,5К for 1590 words is a
    little modest, one that reads 1,6К for 1550 claims words that were
    never said, and rounding up also lets 999 999 arrive as "1000К" when
    it should be "1М".

    The decimal is only kept below ten, where it carries the difference
    between 1,2К and 1,9К; past that the first two digits already say
    everything a tile can say.
    """
    if value < COMPACT_FROM:
        return str(value)
    for limit, key in ((1_000_000_000, "stats_short_billion"),
                       (1_000_000, "stats_short_million"),
                       (COMPACT_FROM, "stats_short_thousand")):
        if value < limit:
            continue
        scaled = value / limit
        if scaled < 10:
            number = f"{math.floor(scaled * 10) / 10:.1f}".removesuffix(".0")
        else:
            number = str(math.floor(scaled))
        if i18n.language() == "ru":
            number = number.replace(".", ",")
        return number + i18n.tr(key)
    return str(value)


def _format_duration(seconds: float) -> tuple[str, str]:
    """Always a clock reading, so the caption never has to name the unit.

    Under a minute it is "0:45" rather than "45": the caption below the
    tile just says "времени", and a bare number under it would be read
    as a count of dictations like the tiles either side of it.
    """
    seconds = int(seconds)
    hours, remainder = divmod(seconds, 3600)
    minutes, secs = divmod(remainder, 60)
    if hours:
        return f"{hours}:{minutes:02d}", i18n.tr("stats_unit_hours")
    return f"{minutes}:{secs:02d}", i18n.tr("stats_unit_minutes")
