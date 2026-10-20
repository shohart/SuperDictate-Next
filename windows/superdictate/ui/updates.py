"""Background update checking, on top of the plain HTTP checker.

The settings have carried a "check for updates" switch since the first
release, but nothing ever read it: the only check that ran was the button
on the Advanced tab. This is what the switch turns on.

Two rules shape it. The check never interrupts: it reports through the
Windows notification centre, where a missed message waits instead of
stealing the keyboard focus of whatever is being typed into. And it never
repeats itself: one notification per published version, remembered across
launches, so an update the user has decided to skip stays skipped.
"""

from __future__ import annotations

import threading

from PySide6.QtCore import QObject, QTimer, Signal

from .. import i18n
from ..logging_setup import get as get_logger
from ..updater import CHECK_INTERVAL_SECONDS, check_latest

log = get_logger("updates")

# Late enough to be behind the model load, which is what the first seconds
# after launch are for.
FIRST_CHECK_DELAY_MS = 20_000


class UpdateWatcher(QObject):
    """Checks on a timer and announces anything newer exactly once."""

    update_found = Signal(str, str)  # version, page url

    def __init__(self, settings, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self._settings = settings
        self._busy = False

        self._timer = QTimer(self)
        self._timer.setInterval(CHECK_INTERVAL_SECONDS * 1000)
        self._timer.timeout.connect(self.check)

    def start(self) -> None:
        QTimer.singleShot(FIRST_CHECK_DELAY_MS, self.check)
        self._timer.start()

    def check(self) -> None:
        if self._busy or not self._settings.check_for_updates:
            return
        self._busy = True
        # A blocking HTTPS request on the Qt thread would freeze every
        # window for as long as GitHub takes to answer.
        threading.Thread(target=self._check_now, name="update-check",
                         daemon=True).start()

    def _check_now(self) -> None:
        try:
            info = check_latest()
        finally:
            self._busy = False
        if info is None or not info.is_newer or not info.has_windows_asset:
            return
        if info.version == self._settings.last_seen_version:
            return
        self._settings.last_seen_version = info.version
        log.info("Update available: %s", info.version)
        # Queued across the thread boundary by Qt, so the notification is
        # raised on the thread that owns the tray icon.
        self.update_found.emit(info.version, info.page_url)


def notification_text(version: str) -> tuple[str, str]:
    return i18n.tr("app_name"), i18n.tr("update_notification", version=version)
