"""The control panel.

macOS keeps this deliberately compact: service status, missing
permissions, and an available update, with the gear opening settings in a
separate window. The Windows panel keeps that shape and drops the
permissions block, Windows has no per-app Accessibility or Input
Monitoring gate to chase, replacing it with what actually varies here:
which compute device the model ended up on, and which microphone is in
use.

The layout is a grid of cards. An earlier version used ``QGroupBox`` with
``palette(mid)`` for the values, which under the Windows dark theme
rendered the model, compute and microphone rows as grey-on-grey and made
them look empty; every colour is now stated explicitly in
:mod:`superdictate.ui.theme`.

Closing this window leaves the tray icon and the keyboard hook running,
matching macOS where closing the panel leaves the background agent alive.
"""

from __future__ import annotations

from PySide6.QtCore import QPointF, Qt, QTimer
from PySide6.QtGui import QColor, QLinearGradient, QPainter
from PySide6.QtWidgets import (
    QGridLayout,
    QHBoxLayout,
    QLabel,
    QMainWindow,
    QProgressBar,
    QPushButton,
    QScrollArea,
    QVBoxLayout,
    QWidget,
)

from .. import asr, i18n
from ..app import AppState
from ..keynames import hotkey_name
from ..version import VERSION
from . import icons
from .stats import StatsPanel
from .theme import palette, stylesheet

_STATE_LABELS = {
    AppState.STARTING: "status_starting",
    AppState.DOWNLOADING: "status_downloading",
    AppState.LOADING: "status_loading",
    AppState.READY: "status_ready",
    AppState.RECORDING: "status_recording",
    AppState.TRANSCRIBING: "status_transcribing",
    AppState.CORRECTING: "status_correcting",
    AppState.FAILED: "status_failed",
}


class StatusDot(QWidget):
    """A painted dot; the old text bullet inherited the label's font."""

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self._color = QColor("#8e8e93")
        self._end: QColor | None = None
        self.setFixedSize(14, 14)

    def set_color(self, color: str, end: str | None = None) -> None:
        self._color = QColor(color)
        self._end = QColor(end) if end else None
        self.update()

    def paintEvent(self, event) -> None:  # noqa: N802 (Qt naming)
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.setPen(Qt.PenStyle.NoPen)
        halo = QColor(self._color)
        halo.setAlpha(60)
        painter.setBrush(halo)
        painter.drawEllipse(0, 0, 14, 14)
        if self._end is not None:
            fill = QLinearGradient(QPointF(4, 4), QPointF(10, 10))
            fill.setColorAt(0.0, self._color)
            fill.setColorAt(1.0, self._end)
            painter.setBrush(fill)
        else:
            painter.setBrush(self._color)
        painter.drawEllipse(4, 4, 6, 6)
        painter.end()


def _card() -> QWidget:
    widget = QWidget()
    widget.setObjectName("Card")
    return widget


def _card_title(text: str) -> QLabel:
    label = QLabel(text)
    label.setObjectName("CardTitle")
    return label


class ControlPanel(QMainWindow):
    def __init__(self, controller, open_settings, open_history) -> None:
        super().__init__()
        self._controller = controller
        self._open_settings = open_settings
        self._open_history = open_history
        self._palette = palette()

        self.setWindowTitle(f"{i18n.tr('app_name')} {VERSION}")
        self.setMinimumSize(560, 640)
        # Tall enough that the statistics block is visible without scrolling
        # on a normal display; the scroll area covers smaller screens.
        self.resize(600, 880)
        self.setStyleSheet(stylesheet(self._palette))

        # The actions stay in a fixed footer rather than inside the scroll
        # area: with the statistics block the content is taller than the
        # window, and buttons that scroll out of reach are not buttons.
        root = QWidget()
        self.setCentralWidget(root)
        root_layout = QVBoxLayout(root)
        root_layout.setContentsMargins(0, 0, 0, 0)
        root_layout.setSpacing(0)

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QScrollArea.Shape.NoFrame)
        root_layout.addWidget(scroll, 1)

        central = QWidget()
        scroll.setWidget(central)
        layout = QVBoxLayout(central)
        layout.setContentsMargins(18, 18, 18, 12)
        layout.setSpacing(12)

        layout.addWidget(self._build_status_card())
        layout.addWidget(self._build_service_card())
        layout.addWidget(_card_title(i18n.tr("panel_shortcuts")))
        layout.addWidget(self._build_shortcuts_card())
        layout.addWidget(_card_title(i18n.tr("panel_statistics")))
        self._stats = StatsPanel(controller.usage)
        layout.addWidget(self._stats)
        layout.addStretch(1)

        footer = QWidget()
        footer_layout = QVBoxLayout(footer)
        footer_layout.setContentsMargins(18, 10, 18, 14)
        footer_layout.setSpacing(6)
        footer_layout.addLayout(self._build_actions())
        root_layout.addWidget(footer)

        controller.state_changed.connect(lambda _: self.refresh())
        controller.progress_changed.connect(self._on_progress)
        controller.settings_applied.connect(self.refresh)
        controller.device_changed.connect(self.refresh)
        controller.transcript_ready.connect(lambda _: self._stats.refresh())

        self._usage_timer = QTimer(self)
        self._usage_timer.setInterval(15_000)
        self._usage_timer.timeout.connect(self._stats.refresh)
        self._usage_timer.start()

        self.refresh()

    # -- layout -------------------------------------------------------

    def _build_status_card(self) -> QWidget:
        """State and the restart button, on their own.

        These two used to sit on top of the model/compute/microphone
        grid in one tall card. They answer a different question, "is it
        running, and can I kick it", so they get their own strip.
        """
        card = _card()
        outer = QVBoxLayout(card)
        outer.setContentsMargins(16, 12, 16, 12)
        outer.setSpacing(10)

        head = QHBoxLayout()
        head.setSpacing(10)
        self._status_dot = StatusDot()
        self._status_text = QLabel(i18n.tr("status_starting"))
        self._status_text.setStyleSheet(
            "font-size: 15px; font-weight: 600; background: transparent;")
        restart = QPushButton(i18n.tr("panel_restart"))
        restart.setIcon(icons.icon("refresh", self._palette.text_muted, 16))
        restart.setIconSize(icons.icon_size(16))
        restart.clicked.connect(self._controller.reload_model)
        head.addWidget(self._status_dot)
        head.addWidget(self._status_text)
        head.addStretch(1)
        head.addWidget(restart)
        outer.addLayout(head)

        self._progress = QProgressBar()
        self._progress.setRange(0, 100)
        self._progress.setVisible(False)
        outer.addWidget(self._progress)
        return card

    def _build_service_card(self) -> QWidget:
        card = _card()
        outer = QVBoxLayout(card)
        outer.setContentsMargins(16, 14, 16, 14)
        outer.setSpacing(12)

        grid = QGridLayout()
        grid.setHorizontalSpacing(14)
        grid.setVerticalSpacing(9)
        grid.setColumnStretch(2, 1)
        rows = (
            ("sparkles", "panel_model", "_model_label"),
            ("cpu", "panel_compute", "_compute_label"),
            ("mic", "panel_microphone", "_microphone_label"),
        )
        for row, (icon_name, label_key, attribute) in enumerate(rows):
            glyph = QLabel()
            glyph.setPixmap(icons.pixmap(icon_name, self._palette.text_faint, 16))
            glyph.setStyleSheet("background: transparent;")
            key = QLabel(i18n.tr(label_key))
            key.setObjectName("Key")
            value = QLabel("-")
            value.setObjectName("Value")
            value.setAlignment(Qt.AlignmentFlag.AlignRight
                               | Qt.AlignmentFlag.AlignVCenter)
            value.setWordWrap(True)
            grid.addWidget(glyph, row, 0)
            grid.addWidget(key, row, 1)
            grid.addWidget(value, row, 2)
            setattr(self, attribute, value)
        outer.addLayout(grid)
        return card

    def _build_shortcuts_card(self) -> QWidget:
        card = _card()
        grid = QGridLayout(card)
        grid.setContentsMargins(16, 14, 16, 14)
        grid.setHorizontalSpacing(14)
        grid.setVerticalSpacing(10)
        grid.setColumnStretch(2, 1)

        self._shortcut_labels: dict[str, QLabel] = {}
        self._shortcut_keys: dict[str, QLabel] = {}
        rows = (
            ("mic", "panel_hotkey", "hotkey"),
            # The alternate finish; its name follows what it does (refresh).
            ("keyboard", "panel_hotkey_enter", "enter_hotkey"),
            ("clock", "panel_hotkey_history", "history_hotkey"),
        )
        for row, (icon_name, label_key, attribute) in enumerate(rows):
            glyph = QLabel()
            glyph.setPixmap(icons.pixmap(icon_name, self._palette.text_faint, 16))
            glyph.setStyleSheet("background: transparent;")
            key = QLabel(i18n.tr(label_key))
            key.setObjectName("Key")
            value = QLabel("-")
            value.setObjectName("Shortcut")
            value.setAlignment(Qt.AlignmentFlag.AlignCenter)
            grid.addWidget(glyph, row, 0)
            grid.addWidget(key, row, 1)
            grid.addWidget(value, row, 2, Qt.AlignmentFlag.AlignRight)
            self._shortcut_labels[attribute] = value
            self._shortcut_keys[attribute] = key
        return card

    def _build_actions(self) -> QHBoxLayout:
        buttons = QHBoxLayout()
        buttons.setSpacing(8)

        self._settings_button = QPushButton(i18n.tr("tray_settings"))
        self._settings_button.setObjectName("Primary")
        self._settings_button.setIcon(
            icons.icon("settings", self._palette.accent_text, 16))
        self._settings_button.setIconSize(icons.icon_size(16))
        self._settings_button.clicked.connect(lambda: self._open_settings())

        self._history_button = QPushButton(i18n.tr("tray_history"))
        self._history_button.setIcon(
            icons.icon("history", self._palette.text_muted, 16))
        self._history_button.setIconSize(icons.icon_size(16))
        self._history_button.clicked.connect(lambda: self._open_history())

        # No update button here: checking for updates is a once-in-a-while
        # errand, and it sat next to the two things this window is for.
        # It lives on the Advanced tab of the settings now.
        buttons.addWidget(self._settings_button)
        buttons.addWidget(self._history_button)
        buttons.addStretch(1)
        return buttons

    # -- refresh ------------------------------------------------------

    def refresh(self) -> None:
        state = self._controller.state
        settings = self._controller.settings
        self._status_text.setText(i18n.tr(_STATE_LABELS.get(state, "status_starting")))
        self._status_dot.set_color(self._state_color(state))

        for attribute, label in self._shortcut_labels.items():
            label.setText(hotkey_name(getattr(settings, attribute), i18n.language()))
        alternate = settings.primary_completion_behavior.opposite
        self._shortcut_keys["enter_hotkey"].setText(i18n.tr(
            "panel_hotkey_enter" if alternate.presses_enter else "panel_hotkey_insert"))
        if not settings.alternate_completion_enabled:
            self._shortcut_labels["enter_hotkey"].setText("-")

        self._model_label.setText(i18n.tr(
            "settings_model_gigaam_v3"
            if settings.speech_model_profile == asr.PROFILE_GIGAAM_V3
            else "settings_model_parakeet_ultra"))
        model = getattr(self._controller, "_model", None)
        if (state is AppState.LOADING and model is not None
                and model.backend == asr.BACKEND_NPU):
            self._status_text.setText(i18n.tr("status_loading_npu"))
        if model is not None and model.active_providers:
            providers = ", ".join(model.active_providers).upper()
            # Threads are a CPU setting; the NPU has none to show.
            self._compute_label.setText(
                providers if providers == "NPU" else f"{providers} · {model.threads}")
            self._compute_label.setToolTip(model.fallback_reason)
        else:
            self._compute_label.setText("-")
            self._compute_label.setToolTip("")
        self._microphone_label.setText(
            settings.input_device or i18n.tr("settings_device_default"))
        self._stats.refresh()

    def _state_color(self, state: AppState) -> str:
        # Ready used to be a colour the settings let you pick. It is one
        # dot on one window, so the choice cost more attention than it was
        # worth; it is the theme's green now, like every other "fine" here.
        p = self._palette
        return {
            AppState.READY: p.ok,
            AppState.RECORDING: p.danger,
            AppState.TRANSCRIBING: p.busy,
            AppState.FAILED: p.danger,
        }.get(state, p.text_faint)

    def _on_progress(self, progress) -> None:
        if progress.state is asr.State.DOWNLOADING and progress.total_bytes:
            self._progress.setVisible(True)
            self._progress.setRange(0, 100)
            self._progress.setValue(int(progress.fraction * 100))
            self._progress.setFormat(
                f"%p%  ({progress.downloaded_bytes // (1024 * 1024)} / "
                f"{progress.total_bytes // (1024 * 1024)} MB)"
            )
        elif progress.state is asr.State.LOADING:
            self._progress.setVisible(True)
            self._progress.setRange(0, 0)
        else:
            self._progress.setRange(0, 100)
            self._progress.setVisible(False)

    # -- window behaviour ---------------------------------------------

    def closeEvent(self, event) -> None:  # noqa: N802 (Qt naming)
        # Closing hides; the tray icon keeps the service alive, the same
        # way closing the macOS panel leaves the LaunchAgent running.
        event.ignore()
        self.hide()
