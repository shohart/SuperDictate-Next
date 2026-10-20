"""Modal dialog that records a new shortcut.

Mirrors the macOS ``HotkeyRecorderController``, including the rule that
global dictation is paused while the window is open: keys pressed here
only build a shortcut, they never start a recording. Escape closes
without changes, and nothing is written until Save is clicked.

Qt's own key events are enough here, the dialog has focus, so there is
no need for a second hook. What Qt does *not* give is the left/right
distinction, so ``nativeEvent`` is used to read the real virtual key code
out of the raw ``MSG``.
"""

from __future__ import annotations

import ctypes
import ctypes.wintypes as wt
from typing import Optional

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QDialog,
    QDialogButtonBox,
    QFrame,
    QLabel,
    QVBoxLayout,
)

from .. import i18n
from ..hotkeys import (
    MOD_ALL,
    MODIFIER_VK_FLAG,
    VK_ESCAPE,
    HotkeyChoice,
)
from ..keynames import hotkey_name

WM_KEYDOWN = 0x0100
WM_SYSKEYDOWN = 0x0104
WM_KEYUP = 0x0101
WM_SYSKEYUP = 0x0105

user32 = ctypes.WinDLL("user32", use_last_error=True)


class MSG(ctypes.Structure):
    _fields_ = [
        ("hwnd", wt.HWND),
        ("message", wt.UINT),
        ("wParam", wt.WPARAM),
        ("lParam", wt.LPARAM),
        ("time", wt.DWORD),
        ("pt", wt.POINT),
    ]


class ShortcutRecorderDialog(QDialog):
    def __init__(self, current: HotkeyChoice, parent=None, title: str = "") -> None:
        super().__init__(parent)
        self.setWindowTitle(title or i18n.tr("recorder_title"))
        self.setModal(True)
        self.setMinimumWidth(420)

        self._pressed_modifiers: set[int] = set()
        self._selected: Optional[HotkeyChoice] = None

        layout = QVBoxLayout(self)
        layout.setSpacing(12)

        instruction = QLabel(i18n.tr("recorder_instruction"))
        instruction.setWordWrap(True)
        layout.addWidget(instruction)

        self._display = QLabel(hotkey_name(current, i18n.language()))
        self._display.setFrameShape(QFrame.Shape.StyledPanel)
        self._display.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self._display.setMinimumHeight(46)
        self._display.setStyleSheet("font-size: 14px; font-weight: 600;")
        layout.addWidget(self._display)

        self._buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Save | QDialogButtonBox.StandardButton.Cancel
        )
        self._buttons.button(QDialogButtonBox.StandardButton.Save).setText(
            i18n.tr("recorder_save"))
        self._buttons.button(QDialogButtonBox.StandardButton.Cancel).setText(
            i18n.tr("settings_cancel"))
        self._buttons.button(QDialogButtonBox.StandardButton.Save).setEnabled(False)
        self._buttons.accepted.connect(self.accept)
        self._buttons.rejected.connect(self.reject)
        layout.addWidget(self._buttons)

    @property
    def selected(self) -> Optional[HotkeyChoice]:
        return self._selected

    def nativeEvent(self, event_type, message):  # noqa: N802 (Qt naming)
        if event_type not in (b"windows_generic_MSG", b"windows_dispatcher_MSG"):
            return False, 0
        msg = MSG.from_address(int(message))

        if msg.message in (WM_KEYDOWN, WM_SYSKEYDOWN):
            self._on_key_down(_side_specific_vk(msg))
            return True, 0
        if msg.message in (WM_KEYUP, WM_SYSKEYUP):
            self._pressed_modifiers.discard(_side_specific_vk(msg))
            return True, 0
        return False, 0

    def _on_key_down(self, vk: int) -> None:
        if vk == VK_ESCAPE:
            self.reject()
            return

        if vk in MODIFIER_VK_FLAG:
            # A modifier can be either the chord's prefix or the shortcut
            # itself. Treat it as the shortcut and let whatever is already
            # held become the required modifiers, pressing Right Shift
            # then Right Alt records "Shift + Right Alt".
            modifiers = self._current_modifier_mask() & ~MODIFIER_VK_FLAG[vk]
            self._pressed_modifiers.add(vk)
            self._select(HotkeyChoice(vk, modifiers))
            return

        self._select(HotkeyChoice(vk, self._current_modifier_mask()))

    def _current_modifier_mask(self) -> int:
        mask = 0
        for vk in self._pressed_modifiers:
            mask |= MODIFIER_VK_FLAG.get(vk, 0)
        return mask & MOD_ALL

    def _select(self, choice: HotkeyChoice) -> None:
        self._selected = choice
        self._display.setText(hotkey_name(choice, i18n.language()))
        self._buttons.button(QDialogButtonBox.StandardButton.Save).setEnabled(True)


def _side_specific_vk(msg: MSG) -> int:
    """Recover VK_LCONTROL / VK_RCONTROL from a generic VK_CONTROL message.

    Window messages report the side-agnostic code; the scan code and the
    extended-key bit in ``lParam`` carry the side, which is exactly what
    ``MapVirtualKeyEx`` with ``MAPVK_VSC_TO_VK_EX`` decodes.
    """
    generic = int(msg.wParam)
    if generic not in (0x10, 0x11, 0x12):  # SHIFT, CONTROL, MENU
        return generic
    scan = (int(msg.lParam) >> 16) & 0xFF
    extended = bool((int(msg.lParam) >> 24) & 1)
    if generic == 0x11:  # Control: only the right one is an extended key
        return 0xA3 if extended else 0xA2
    if generic == 0x12:  # Alt
        return 0xA5 if extended else 0xA4
    resolved = user32.MapVirtualKeyW(scan, 3)  # MAPVK_VSC_TO_VK_EX
    return resolved or generic
