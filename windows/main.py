"""Entry point.

Usage::

    python main.py                 # normal launch (tray + control panel)
    python main.py --minimized     # launch to tray only, for autostart
    python main.py --self-test     # run the built-in checks and exit
    python main.py --benchmark-transcribe <profile> <wav...>   # real host, no UI

``--self-test`` mirrors the macOS ``Parakey --self-test all``: it exercises
the pure logic (hotkey state machine, transcript processing, settings
round-trip) without touching the microphone, the keyboard hook or the
model, so CI can run it headlessly.
"""

from __future__ import annotations

import sys

from PySide6.QtCore import QTimer
from PySide6.QtWidgets import QApplication, QMessageBox, QSystemTrayIcon

from superdictate import i18n, paths
from superdictate.app import AppState, DictationController
from superdictate.logging_setup import configure, get as get_logger
from superdictate.settings import Settings
from superdictate.system import (SingleInstance, broadcast_show_panel,
                                 set_app_user_model_id)
from superdictate.ui.history_window import HistoryWindow
from superdictate.ui.panel import ControlPanel
from superdictate.ui.settings_window import SettingsWindow
from superdictate.ui.theme import stylesheet
from superdictate.ui.updates import UpdateWatcher, notification_text
from superdictate.ui.tray import Tray, build_icon
from superdictate.version import VERSION

MODEL_LOAD_DELAY_MS = 120


def main(argv: list[str]) -> int:
    if "--self-test" in argv:
        from superdictate.selftest import run_all

        return 0 if run_all() else 1
    if "--benchmark-transcribe" in argv:
        from superdictate.diagnostics import benchmark_transcribe

        paths.ensure_directories()
        configure(verbose="--verbose" in argv)
        index = argv.index("--benchmark-transcribe")
        return benchmark_transcribe([a for a in argv[index + 1:] if a != "--verbose"])

    paths.ensure_directories()
    log = configure(verbose="--verbose" in argv)
    log.info("SuperDictate %s starting", VERSION)

    # Before QApplication: the identity has to be in place before the first
    # window is created, or the taskbar has already decided what to show.
    set_app_user_model_id()

    instance = SingleInstance()
    if instance.already_running:
        log.info("Another instance is running; asking it to show its panel")
        broadcast_show_panel()
        return 0

    app = QApplication(argv)
    app.setApplicationName("SuperDictate")
    # No display name: Qt would append " - SuperDictate" to every window
    # title, and the control panel already carries the name and version.
    app.setWindowIcon(build_icon())
    # One stylesheet for every window, so dialogs opened later inherit the
    # same look instead of falling back to the raw Windows theme.
    app.setStyleSheet(stylesheet())
    # The tray icon is the service; windows come and go.
    app.setQuitOnLastWindowClosed(False)

    settings = Settings()
    i18n.set_language(settings.interface_language)

    controller = DictationController(settings)

    windows = _Windows(controller)
    tray = Tray(
        controller,
        on_panel=windows.show_panel,
        on_settings=windows.show_settings,
        on_history=windows.toggle_history,
        on_quit=lambda: _quit(app, controller, instance),
    )
    if not QSystemTrayIcon.isSystemTrayAvailable():
        log.warning("No system tray available; the control panel is the only surface")
    tray.show()

    windows.tray = tray
    # The only notification that has somewhere to go when clicked.
    tray.messageClicked.connect(windows.open_update_page)
    controller.history_toggle_requested.connect(windows.toggle_history)
    controller.history_bubbles_requested.connect(windows.show_history_bubbles)
    controller.transcript_edit_requested.connect(windows.show_editor)
    # Anything wrong with the machine goes to the Windows notification
    # centre, where it stays until it is read: "no microphone" is worth
    # coming back to. Anything wrong with the dictation itself goes to the
    # capsule instead, and is gone with it.
    controller.error_raised.connect(windows.show_system_notification)
    controller.dictation_failed.connect(windows.show_dictation_failure)
    controller.transcript_ready.connect(lambda _: windows.refresh_history())
    controller.vocabulary_learned.connect(windows.show_learned_toast)
    controller.state_toast_requested.connect(windows.show_state_toast)
    controller.loading_toast_requested.connect(windows.show_loading_toast)
    controller.state_changed.connect(windows.on_state_changed)
    controller.level_changed.connect(windows.on_level)
    controller.preview_changed.connect(windows.on_preview)

    controller.start()

    watcher = UpdateWatcher(settings, app)
    watcher.update_found.connect(windows.announce_update)
    watcher.start()

    if "--minimized" not in argv:
        windows.show_panel()

    # Only now, with the panel painted (or with nothing on screen at all
    # in the tray-only case), does the model start loading: building the
    # ONNX session holds the GIL for several seconds, and anything drawn
    # during that time would sit there frozen. A posted paint event and a
    # zero timer are not ordered against each other, hence a real delay —
    # a tenth of a second in front of a four-second load costs nothing.
    QTimer.singleShot(MODEL_LOAD_DELAY_MS, controller.load_model)

    app.aboutToQuit.connect(lambda: controller.shutdown())
    return app.exec()


class _Windows:
    """Lazily-built windows, so startup only pays for the tray."""

    def __init__(self, controller) -> None:
        self._controller = controller
        self._panel = None
        self._settings_window = None
        self._history = None
        self._hud = None
        self._bubble = None
        self._editor = None
        self._bubble_history = None
        self._toasts = None
        self._learn_toast = None
        self._state_toasts = None
        self.tray = None
        self._failure_message = ""
        self._update_url = ""

    # -- notifications --------------------------------------------------

    @property
    def toasts(self):
        if self._toasts is None:
            from superdictate.ui.toast import ToastManager

            self._toasts = ToastManager()
        return self._toasts

    def show_learned_toast(self, pairs: list) -> None:
        """Offer an undo for rules the app just learned on its own.

        One toast at a time: a second learn while the first is still up
        replaces it rather than stacking, so the undo always refers to the
        rule the user is actually looking at.
        """
        if not pairs:
            return
        from superdictate.ui.learn_toast import LearnedToast

        if self._learn_toast is not None:
            self._learn_toast.confirm()
        toast = LearnedToast(pairs, on_undo=self._undo_learned)
        self._learn_toast = toast
        toast.destroyed.connect(lambda *_: setattr(self, "_learn_toast", None))
        toast.present()

    def _undo_learned(self, sources: list) -> None:
        removed = sum(1 for source in sources
                      if self._controller.corrections.delete_source(source))
        if removed:
            from superdictate.ui.toast import Level
            from superdictate import i18n

            self.toasts.show(i18n.tr("vocabulary_undone"), Level.INFO)

    @property
    def state_toasts(self):
        if self._state_toasts is None:
            from superdictate.ui.state_toast import StateToastController

            self._state_toasts = StateToastController()
        return self._state_toasts

    def show_state_toast(self, text: str, tone: str) -> None:
        self.state_toasts.show(text, tone)

    def show_loading_toast(self, text: str) -> None:
        """A persistent card while a cold model loads. Empty text dismisses."""
        if text:
            self.state_toasts.show_loading(text)
        else:
            self.state_toasts.dismiss_loading()

    def show_warning(self, message: str) -> None:
        from superdictate.ui.toast import Level

        self.toasts.show(message, Level.WARNING)

    def show_system_notification(self, message: str) -> None:
        """A Windows notification, so it survives being missed."""
        from PySide6.QtWidgets import QSystemTrayIcon

        if self.tray is not None and QSystemTrayIcon.supportsMessages():
            self.tray.showMessage(
                i18n.tr("app_name"), message,
                QSystemTrayIcon.MessageIcon.Warning, 8000)
            return
        # No notification centre to talk to: better an on-screen card than
        # a message that never appears at all.
        self.show_warning(message)

    def announce_update(self, version: str, page_url: str) -> None:
        """A notification, not a browser window.

        The check runs on its own schedule, so whatever the user is doing
        when it finishes has nothing to do with updates. A page that opens
        by itself in the middle of that is an interruption; a notification
        waits in the centre until it is clicked, and clicking it is what
        opens the page.
        """
        from PySide6.QtWidgets import QSystemTrayIcon

        self._update_url = page_url
        if self.tray is None or not QSystemTrayIcon.supportsMessages():
            return
        title, body = notification_text(version)
        self.tray.showMessage(title, body,
                              QSystemTrayIcon.MessageIcon.Information, 12000)

    def open_update_page(self) -> None:
        if not self._update_url:
            return
        from PySide6.QtCore import QUrl
        from PySide6.QtGui import QDesktopServices

        QDesktopServices.openUrl(QUrl(self._update_url))

    def show_dictation_failure(self, icon_name: str, message: str) -> None:
        from superdictate.ui.hud import RESULT_COLOR

        if not self._controller.settings.show_recording_waveform:
            self.show_warning(message)
            return
        self._failure_message = message
        self.on_preview("")
        self.hud.show_result(icon_name, RESULT_COLOR)

    # -- panel / settings / history ------------------------------------

    def show_panel(self) -> None:
        if self._panel is None:
            self._panel = ControlPanel(
                self._controller, self.show_settings, self.toggle_history
            )
        self._panel.show()
        self._panel.raise_()
        self._panel.activateWindow()

    def show_settings(self) -> None:
        window = SettingsWindow(
            self._controller.settings,
            self._controller.corrections,
            self._controller,
            self._panel,
        )
        window.exec()
        if self._panel is not None:
            self._panel.refresh()
        self._apply_hud_settings()

    def toggle_history(self) -> None:
        if self._history is None:
            self._history = HistoryWindow(self._controller)
        self._history.present()

    def refresh_history(self) -> None:
        if self._history is not None and self._history.isVisible():
            self._history.reload()

    # -- HUD ------------------------------------------------------------

    @property
    def hud(self):
        if self._hud is None:
            from superdictate.ui.hud import RecordingHUD

            self._hud = RecordingHUD()
            self._hud.hover_changed.connect(self._on_hud_hover)
            self._apply_hud_settings()
        return self._hud

    def _on_hud_hover(self, inside: bool) -> None:
        """Explain the outcome glyph in the bubble the preview text uses."""
        self.bubble.set_text(self._failure_message if inside else "")

    @property
    def bubble(self):
        if self._bubble is None:
            from superdictate.ui.hud import TranscriptBubble

            self._bubble = TranscriptBubble(self.hud)
            self._apply_hud_settings()
        return self._bubble

    # -- correcting the last dictation ----------------------------------

    @property
    def editor(self):
        if self._editor is None:
            from superdictate.ui.editor import TranscriptEditor

            self._editor = TranscriptEditor(self.hud)
            self._editor.applied.connect(self._controller.apply_transcript_edit)
            self._editor.closed.connect(self._overlay_closed)
        return self._editor

    def show_editor(self, text: str) -> None:
        """The capsule comes back for the look of it; the bubble is the point."""
        self._begin_overlay()
        self.editor.edit(text)

    # -- quick history over the capsule ---------------------------------

    @property
    def bubble_history(self):
        if self._bubble_history is None:
            from superdictate.ui.bubbles import BubbleHistory

            self._bubble_history = BubbleHistory(self.hud)
            self._bubble_history.chosen.connect(self._insert_from_history)
            self._bubble_history.forgotten.connect(
                self._controller.forget_history_entry)
            self._bubble_history.closed.connect(self._overlay_closed)
        return self._bubble_history

    def show_history_bubbles(self, entries: list) -> None:
        self._begin_overlay()
        self.bubble_history.present(entries)

    def _insert_from_history(self, text: str) -> None:
        # The foreground has just been handed back and Windows moves focus
        # asynchronously; typing in the same tick can land in the window on
        # its way out.
        QTimer.singleShot(120, lambda: self._controller.insert_text(text))

    # -- shared overlay plumbing ----------------------------------------

    def _begin_overlay(self) -> None:
        """Capsule up, keyboard hook asleep.

        The hook is paused for as long as one of these windows is up, the
        same way the shortcut recorder pauses it: every key pressed here
        belongs to the overlay, and the dictation key starting a recording
        underneath it would be absurd.
        """
        self._controller.listener.paused = True
        self.hud.show_static()

    def _overlay_closed(self) -> None:
        self._controller.listener.paused = False
        self._controller.listener.reset_state()
        if self._hud is not None:
            self._hud.hide_hud()

    def _apply_hud_settings(self) -> None:
        settings = self._controller.settings
        if self._hud is not None:
            self._hud.configure(
                size=settings.hud_size,
                recording=settings.hud_recording_color,
                transcribing=settings.hud_transcribing_color,
                display_mode=settings.hud_display_mode,
            )

    def on_state_changed(self, value: str) -> None:
        if not self._controller.settings.show_recording_waveform:
            if self._hud is not None:
                self._hud.hide_hud()
            self.on_preview("")
            return
        state = AppState(value)
        if state is AppState.RECORDING:
            self.hud.show_recording()
            return
        if state in (AppState.TRANSCRIBING, AppState.CORRECTING):
            # Both are "the machine is working on it" as far as the capsule
            # is concerned; the difference is what the tray tooltip says.
            self.hud.show_transcribing()
            return
        # Idle. Both windows go now, together. The finished sentence used to
        # hold the bubble open for another couple of seconds, which made the
        # whole HUD outlive a dictation with the preview switched on and
        # vanish immediately with it switched off; the same key press should
        # not clear the screen at two different speeds.
        if self._hud is not None and self._hud.mode != "result":
            self._hud.hide_hud()
        self.on_preview("")

    def on_level(self, level: float) -> None:
        if self._hud is not None:
            self._hud.set_level(level)

    def on_preview(self, text: str) -> None:
        # Nothing to say yet and no bubble built yet: stay lazy.
        if not text and self._bubble is None:
            return
        if not self._controller.settings.show_recording_waveform:
            return
        self.bubble.set_text(text)


def _quit(app: QApplication, controller, instance: SingleInstance) -> None:
    controller.shutdown()
    instance.release()
    app.quit()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
