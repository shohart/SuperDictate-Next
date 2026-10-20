"""Human-readable names for virtual key codes, in Russian and English.

macOS ships two parallel tables (`hotkeyKeyName` and `localizedHotkeyName`);
this is the same idea keyed by Windows VK codes. Anything not in the table
falls back to whatever the active keyboard layout prints for that key, via
``MapVirtualKeyW`` + ``GetKeyNameTextW``, so layout-specific keys still get
a sensible label instead of "VK 0xDB".
"""

from __future__ import annotations

import ctypes
import ctypes.wintypes as wt

from .hotkeys import (
    MOD_ALT,
    MOD_CTRL,
    MOD_SHIFT,
    MOD_WIN,
    HotkeyChoice,
)

user32 = ctypes.WinDLL("user32", use_last_error=True)

_NAMES: dict[int, tuple[str, str]] = {
    0xA0: ("Левый Shift", "Left Shift"),
    0xA1: ("Правый Shift", "Right Shift"),
    0xA2: ("Левый Ctrl", "Left Ctrl"),
    0xA3: ("Правый Ctrl", "Right Ctrl"),
    0xA4: ("Левый Alt", "Left Alt"),
    0xA5: ("Правый Alt", "Right Alt"),
    0x5B: ("Левый Win", "Left Win"),
    0x5C: ("Правый Win", "Right Win"),
    0x5D: ("Меню", "Menu"),
    0x14: ("Caps Lock", "Caps Lock"),
    0x09: ("Tab", "Tab"),
    0x0D: ("Enter", "Enter"),
    0x20: ("Пробел", "Space"),
    0x08: ("Backspace", "Backspace"),
    0x2E: ("Delete", "Delete"),
    0x2D: ("Insert", "Insert"),
    0x24: ("Home", "Home"),
    0x23: ("End", "End"),
    0x21: ("Page Up", "Page Up"),
    0x22: ("Page Down", "Page Down"),
    0x25: ("Стрелка влево", "Left Arrow"),
    0x26: ("Стрелка вверх", "Up Arrow"),
    0x27: ("Стрелка вправо", "Right Arrow"),
    0x28: ("Стрелка вниз", "Down Arrow"),
    0x13: ("Pause", "Pause"),
    0x2C: ("Print Screen", "Print Screen"),
    0x91: ("Scroll Lock", "Scroll Lock"),
    0x90: ("Num Lock", "Num Lock"),
    0x1B: ("Escape", "Escape"),
}
for _i in range(1, 25):  # F1..F24
    _NAMES[0x6F + _i] = (f"F{_i}", f"F{_i}")


def key_name(vk: int, language: str = "ru") -> str:
    pair = _NAMES.get(vk)
    if pair is not None:
        return pair[0] if language == "ru" else pair[1]
    layout_name = _layout_key_name(vk)
    if layout_name:
        return layout_name
    return f"VK 0x{vk:02X}"


def _layout_key_name(vk: int) -> str:
    scan = user32.MapVirtualKeyW(vk, 0)  # MAPVK_VK_TO_VSC
    if not scan:
        return ""
    buffer = ctypes.create_unicode_buffer(64)
    # bits 16-23 carry the scan code; bit 25 asks for a side-agnostic name.
    if user32.GetKeyNameTextW(scan << 16, buffer, len(buffer)) <= 0:
        return ""
    return buffer.value.strip()


_MOD_LABELS: list[tuple[int, str, str]] = [
    (MOD_CTRL, "Ctrl", "Ctrl"),
    (MOD_ALT, "Alt", "Alt"),
    (MOD_SHIFT, "Shift", "Shift"),
    (MOD_WIN, "Win", "Win"),
]


def hotkey_name(choice: HotkeyChoice, language: str = "ru") -> str:
    parts = [
        (ru if language == "ru" else en)
        for flag, ru, en in _MOD_LABELS
        if choice.modifiers & flag
    ]
    parts.append(key_name(choice.vk, language))
    return " + ".join(parts)
