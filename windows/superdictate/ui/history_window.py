"""Quick history window.

Opened from the tray or from the control panel. macOS calls this the
"quick history": pick a past transcript and it goes straight into the
window you were typing in. This is the whole list, with copying and
deleting; the shortcut, Shift + Right Ctrl, shows only the last few and
shows them as bubbles over the capsule — see
:mod:`superdictate.ui.bubbles`.

The Windows subtlety is focus. Inserting into "the window you were typing
in" only works if this window was never that window, so the target HWND is
captured the moment the window opens and restored with
``SetForegroundWindow`` before the paste.
"""

from __future__ import annotations

import ctypes
import ctypes.wintypes as wt
import time
from datetime import datetime
from typing import Optional

from PySide6.QtCore import Qt, QTimer
from PySide6.QtWidgets import (
    QDialog,
    QHBoxLayout,
    QLabel,
    QListWidget,
    QListWidgetItem,
    QPushButton,
    QStackedWidget,
    QVBoxLayout,
    QWidget,
)

from .. import i18n, inject
from . import icons
from .rows import META_ROLE, PRIMARY_ROLE, HistoryRowDelegate
from .theme import palette, stylesheet

user32 = ctypes.WinDLL("user32", use_last_error=True)
# Without a declared restype ctypes truncates the returned HWND to c_int.
user32.GetForegroundWindow.restype = wt.HWND
user32.SetForegroundWindow.argtypes = [wt.HWND]
user32.SetForegroundWindow.restype = wt.BOOL


def _empty_state(label: QLabel, palette) -> QWidget:
    """A muted microphone over the caption, centred in the whole area."""
    page = QWidget()
    layout = QVBoxLayout(page)
    layout.setContentsMargins(0, 0, 0, 0)
    layout.setSpacing(10)
    layout.addStretch(1)

    glyph = QLabel()
    glyph.setPixmap(icons.pixmap("mic", palette.text_faint, 34))
    glyph.setAlignment(Qt.AlignmentFlag.AlignCenter)
    layout.addWidget(glyph)
    layout.addWidget(label)
    layout.addStretch(1)
    return page


class HistoryWindow(QDialog):
    def __init__(self, controller, parent=None) -> None:
        super().__init__(parent)
        self._controller = controller
        self._previous_window = None

        self.setWindowTitle(i18n.tr("history_title"))
        self.setMinimumSize(560, 440)
        self.setWindowFlag(Qt.WindowType.WindowStaysOnTopHint, True)
        self._palette = palette()
        self.setStyleSheet(stylesheet(self._palette))

        layout = QVBoxLayout(self)
        layout.setContentsMargins(14, 14, 14, 14)
        layout.setSpacing(10)

        self._list = QListWidget()
        self._list.setItemDelegate(HistoryRowDelegate(self._palette, self._list))
        self._list.setMouseTracking(True)          # so rows light up on hover
        self._list.setUniformItemSizes(True)
        self._list.setSpacing(0)
        # A transcript can be a paragraph long. Eliding keeps every row the
        # same shape; a horizontal scrollbar under the list did not.
        self._list.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self._list.itemActivated.connect(lambda _: self._insert_selected())

        # An empty history used to be a single row card reading "Пока
        # пусто", which looks like a transcript you cannot select rather
        # than like an empty list. This sits in the middle of the space
        # instead, where nothing pretends to be a row.
        self._empty = QLabel(i18n.tr("history_empty"))
        self._empty.setObjectName("Caption")
        self._empty.setAlignment(Qt.AlignmentFlag.AlignCenter)

        self._stack = QStackedWidget()
        self._stack.addWidget(self._list)
        self._stack.addWidget(_empty_state(self._empty, self._palette))
        layout.addWidget(self._stack)

        hint = QLabel(i18n.tr("history_hint"))
        hint.setObjectName("Caption")
        layout.addWidget(hint)

        row = QHBoxLayout()
        row.setSpacing(8)
        buttons = (
            ("history_insert", "type", self._insert_selected, True),
            ("history_copy", "words", self._copy_selected, False),
            ("history_delete", "trash", self._delete_selected, False),
            ("history_clear", "trash", self._clear_all, False),
        )
        for label_key, icon_name, handler, primary in buttons:
            button = QPushButton(i18n.tr(label_key))
            colour = self._palette.accent_text if primary else self._palette.text_muted
            button.setIcon(icons.icon(icon_name, colour, 15))
            button.setIconSize(icons.icon_size(15))
            if primary:
                button.setObjectName("Primary")
            button.clicked.connect(handler)
            row.addWidget(button)
        layout.addLayout(row)

    # -- lifecycle ----------------------------------------------------

    def present(self) -> None:
        """Toggle visibility, remembering which window had focus."""
        if self.isVisible():
            self.hide()
            return
        self._previous_window = user32.GetForegroundWindow()
        self.reload()
        self.show()
        self.raise_()
        self.activateWindow()
        if self._list.count():
            self._list.setCurrentRow(0)
        self._list.setFocus()

    def reload(self) -> None:
        limit = self._controller.settings.recent_transcript_limit
        self._list.clear()
        entries = self._controller.history.entries(limit or None)
        self._stack.setCurrentIndex(0 if entries else 1)
        if not entries:
            return
        for index, entry in enumerate(entries):
            stamp = datetime.fromtimestamp(entry.created_at).strftime("%d.%m %H:%M")
            item = QListWidgetItem()
            item.setData(META_ROLE, stamp)
            # The delegate elides; a pre-truncated string would just be
            # elided twice and lose two more characters.
            item.setData(PRIMARY_ROLE, " ".join(entry.text.split()))
            item.setData(Qt.ItemDataRole.UserRole, index)
            item.setToolTip(entry.text)
            self._list.addItem(item)

    def keyPressEvent(self, event) -> None:  # noqa: N802 (Qt naming)
        if event.key() == Qt.Key.Key_Escape:
            self.hide()
            return
        if event.key() in (Qt.Key.Key_Return, Qt.Key.Key_Enter):
            self._insert_selected()
            return
        super().keyPressEvent(event)

    # -- actions ------------------------------------------------------

    def _selected_entry(self):
        item = self._list.currentItem()
        if item is None:
            return None
        index = item.data(Qt.ItemDataRole.UserRole)
        if index is None:
            return None
        limit = self._controller.settings.recent_transcript_limit
        entries = self._controller.history.entries(limit or None)
        return entries[index] if 0 <= index < len(entries) else None

    def _insert_selected(self) -> None:
        entry = self._selected_entry()
        if entry is None:
            return
        self.hide()
        target = self._previous_window
        if target:
            user32.SetForegroundWindow(target)
        # The focus change is asynchronous; pasting in the same tick can
        # land in this window on its way out.
        QTimer.singleShot(120, lambda: self._controller.insert_text(entry.text))

    def _copy_selected(self) -> None:
        entry = self._selected_entry()
        if entry is not None:
            inject.write_clipboard_text(entry.text)

    def _delete_selected(self) -> None:
        item = self._list.currentItem()
        if item is None:
            return
        index = item.data(Qt.ItemDataRole.UserRole)
        if index is None:
            return
        self._controller.history.remove(int(index))
        self.reload()

    def _clear_all(self) -> None:
        self._controller.history.clear()
        self.reload()
