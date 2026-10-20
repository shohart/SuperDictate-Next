"""System tray icon.

This is the Windows counterpart of the macOS menu bar item, and it is
what keeps the app alive: closing every window leaves the tray icon, the
keyboard hook and the loaded model in place.

The glyph is the product artwork (assets/SuperDictate.png), so the tray, the
taskbar, the window frames and the installer all show the same thing.
State is signalled by a small dot in the corner instead of by recolouring
the artwork: the mark is a gradient, and tinting it red or blue would turn
it into a different picture every few seconds.
"""

from __future__ import annotations

from functools import lru_cache

from PySide6.QtCore import QRectF, Qt
from PySide6.QtGui import QAction, QColor, QIcon, QPainter, QPixmap
from PySide6.QtWidgets import QMenu, QSystemTrayIcon

from .. import i18n, paths
from ..app import AppState

# None means "no badge": the idle state should look like the plain logo.
_STATE_COLORS: dict[AppState, str | None] = {
    AppState.STARTING: "#8e8e93",
    AppState.DOWNLOADING: "#8e8e93",
    AppState.LOADING: "#8e8e93",
    AppState.READY: None,
    AppState.RECORDING: "#ff453a",
    AppState.TRANSCRIBING: "#0a84ff",
    AppState.FAILED: "#ff9f0a",
}


@lru_cache(maxsize=8)
def _artwork(size: int) -> QPixmap:
    source = QPixmap(str(paths.resource_path("assets", "SuperDictate.png")))
    if source.isNull():
        return QPixmap()
    return source.scaled(
        size, size,
        Qt.AspectRatioMode.KeepAspectRatio,
        Qt.TransformationMode.SmoothTransformation,
    )


def build_icon(badge: str | None = None, size: int = 64) -> QIcon:
    """The product mark, optionally with a state dot in the corner."""
    art = _artwork(size)
    if art.isNull():
        return QIcon()
    if badge is None:
        return QIcon(art)

    pixmap = QPixmap(art)
    painter = QPainter(pixmap)
    painter.setRenderHint(QPainter.RenderHint.Antialiasing)
    diameter = size * 0.34
    painter.setPen(Qt.PenStyle.NoPen)
    painter.setBrush(QColor(badge))
    painter.drawEllipse(
        QRectF(size - diameter, size - diameter, diameter, diameter))
    painter.end()
    return QIcon(pixmap)


class Tray(QSystemTrayIcon):
    def __init__(self, controller, *, on_panel, on_settings, on_history, on_quit) -> None:
        super().__init__()
        self._controller = controller
        self._on_panel = on_panel

        menu = QMenu()
        self._toggle_action = QAction(i18n.tr("tray_start"), menu)
        self._toggle_action.triggered.connect(self._toggle_dictation)
        menu.addAction(self._toggle_action)
        menu.addSeparator()

        for label_key, handler in (
            ("tray_open_panel", on_panel),
            ("tray_settings", on_settings),
            ("tray_history", on_history),
        ):
            action = QAction(i18n.tr(label_key), menu)
            action.triggered.connect(lambda _=False, h=handler: h())
            menu.addAction(action)

        menu.addSeparator()
        quit_action = QAction(i18n.tr("tray_quit"), menu)
        quit_action.triggered.connect(lambda: on_quit())
        menu.addAction(quit_action)

        self.setContextMenu(menu)
        self.activated.connect(self._on_activated)
        controller.state_changed.connect(self._on_state_changed)
        self._apply_state(controller.state)

    def _on_activated(self, reason) -> None:
        if reason in (
            QSystemTrayIcon.ActivationReason.Trigger,
            QSystemTrayIcon.ActivationReason.DoubleClick,
        ):
            self._on_panel()

    def _toggle_dictation(self) -> None:
        if self._controller.state is AppState.RECORDING:
            self._controller.finish_recording(
                self._controller.settings.primary_completion_behavior)
        else:
            self._controller.begin_recording()

    def _on_state_changed(self, value: str) -> None:
        self._apply_state(AppState(value))

    def _apply_state(self, state: AppState) -> None:
        self.setIcon(build_icon(_STATE_COLORS.get(state)))
        label = {
            AppState.STARTING: "status_starting",
            AppState.DOWNLOADING: "status_downloading",
            AppState.LOADING: "status_loading",
            AppState.READY: "status_ready",
            AppState.RECORDING: "status_recording",
            AppState.TRANSCRIBING: "status_transcribing",
            AppState.CORRECTING: "status_correcting",
            AppState.FAILED: "status_failed",
        }.get(state, "status_starting")
        self.setToolTip(f"{i18n.tr('app_name')}: {i18n.tr(label)}")
        self._toggle_action.setText(
            i18n.tr("tray_stop") if state is AppState.RECORDING
            else i18n.tr("tray_start")
        )
        self._toggle_action.setEnabled(state in (AppState.READY, AppState.RECORDING))
