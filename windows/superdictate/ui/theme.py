"""Colours and the application stylesheet.

The panel used to lean on Qt's own palette roles, which is why several
values rendered as near-invisible grey-on-grey under the Windows dark
theme: ``palette(mid)`` is a border colour, not a text colour. Everything
here is stated explicitly instead, with a light and a dark variant, so a
value that is meant to be readable is readable.
"""

from __future__ import annotations

import winreg
from dataclasses import dataclass


@dataclass(frozen=True)
class Palette:
    window: str
    card: str
    card_border: str
    text: str
    text_muted: str      # readable secondary text, not a border colour
    text_faint: str      # captions only
    accent: str
    accent_hover: str    # the accent one step away from the surface
    accent_text: str
    control: str
    control_hover: str
    control_border: str
    field: str
    grid_empty: str
    ok: str
    busy: str
    danger: str
    warning: str

    @property
    def is_dark(self) -> bool:
        return self is DARK


DARK = Palette(
    window="#16171a",
    card="#202126",
    card_border="#2e3038",
    text="#f2f2f7",
    text_muted="#a9adb8",
    text_faint="#787d89",
    # White, and so too light to carry white text: the accent's foreground
    # is near-black in both themes. Hovering has to darken rather than
    # lighten here, since there is nothing above white to move toward.
    accent="#ffffff",
    accent_hover="#dcdee6",
    accent_text="#14161a",
    control="#2b2d34",
    control_hover="#343740",
    control_border="#3a3d47",
    field="#1a1b1f",
    grid_empty="#26282f",
    ok="#30d158",
    busy="#0a84ff",
    danger="#ff453a",
    warning="#ff9f0a",
)

LIGHT = Palette(
    window="#f4f5f7",
    card="#ffffff",
    card_border="#e2e4ea",
    text="#14161a",
    text_muted="#5b6070",
    text_faint="#8d92a1",
    # The dark theme's white on a white card would be an invisible button
    # and an invisible tick, so the light theme takes the same neutral
    # accent from the other end of the scale.
    accent="#14161a",
    accent_hover="#2f333d",
    accent_text="#ffffff",
    control="#ffffff",
    control_hover="#eef0f4",
    control_border="#d3d6de",
    field="#ffffff",
    grid_empty="#e8eaef",
    ok="#248a3d",
    busy="#0a6dd6",
    danger="#d70015",
    warning="#b25000",
)


def system_is_dark() -> bool:
    try:
        with winreg.OpenKey(
            winreg.HKEY_CURRENT_USER,
            r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
        ) as key:
            return winreg.QueryValueEx(key, "AppsUseLightTheme")[0] == 0
    except OSError:
        return True


def palette() -> Palette:
    return DARK if system_is_dark() else LIGHT


def stylesheet(p: Palette | None = None) -> str:
    from . import icons

    p = p or palette()
    check = icons.stylesheet_url("check", p.accent_text, 13, 2.6)
    return f"""
    QWidget {{
        background: {p.window};
        color: {p.text};
        font-family: 'Segoe UI Variable Text', 'Segoe UI', sans-serif;
        font-size: 13px;
    }}
    QDialog, QMainWindow {{ background: {p.window}; }}

    #Card {{
        background: {p.card};
        border: 1px solid {p.card_border};
        border-radius: 12px;
    }}
    #CardTitle {{
        color: {p.text_faint};
        font-size: 11px;
        font-weight: 600;
        letter-spacing: 0.6px;
        text-transform: uppercase;
        background: transparent;
    }}
    #Key   {{ color: {p.text_muted}; background: transparent; }}
    #Value {{ color: {p.text}; font-weight: 600; background: transparent; }}
    #Caption {{ color: {p.text_faint}; font-size: 11px; background: transparent; }}
    /* Plain containers: a QWidget used only to lay other widgets out takes
       the window background from the rule above and paints a darker slab
       over the card it sits in. */
    #Hint, #Plain {{ background: transparent; }}
    #Metric {{ color: {p.text}; font-size: 26px; font-weight: 700;
               background: transparent; }}
    #MetricUnit {{ color: {p.text_muted}; font-size: 11px; background: transparent; }}
    #Shortcut {{
        background: {p.control};
        border: 1px solid {p.control_border};
        border-radius: 6px;
        padding: 3px 9px;
        font-weight: 600;
        color: {p.text};
    }}

    QPushButton {{
        background: {p.control};
        border: 1px solid {p.control_border};
        border-radius: 8px;
        padding: 7px 14px;
        color: {p.text};
    }}
    QPushButton:hover {{ background: {p.control_hover}; }}
    QPushButton:disabled {{ color: {p.text_faint}; }}
    QPushButton#Primary {{
        background: {p.accent};
        border: 1px solid {p.accent};
        color: {p.accent_text};
        font-weight: 600;
    }}
    QPushButton#Primary:hover {{ background: {p.accent_hover}; }}
    /* A button that reads as part of the sentence next to it: the
       disclosure arrow beside a setting, the small remove control on a
       word. A framed button there would compete with the setting it
       belongs to. */
    QPushButton#Link {{
        background: transparent;
        border: none;
        border-radius: 6px;
        padding: 3px 6px;
        color: {p.text_muted};
    }}
    QPushButton#Link:hover {{ background: {p.control_hover}; color: {p.text}; }}
    QPushButton#Link:disabled {{ color: {p.text_faint}; }}

    QLineEdit, QComboBox, QSpinBox, QDoubleSpinBox, QListWidget, QPlainTextEdit {{
        background: {p.field};
        border: 1px solid {p.control_border};
        border-radius: 8px;
        padding: 6px 8px;
        color: {p.text};
        selection-background-color: {p.accent};
        selection-color: {p.accent_text};
    }}
    QComboBox::drop-down {{ border: none; width: 22px; }}
    /* No spin arrows anywhere. Qt draws them as two stacked native
       half-buttons that ignore the rest of this stylesheet and look
       glued on; the value is typed or scrolled instead. */
    QSpinBox::up-button, QSpinBox::down-button,
    QDoubleSpinBox::up-button, QDoubleSpinBox::down-button {{
        width: 0; height: 0; border: none;
    }}
    QComboBox QAbstractItemView {{
        background: {p.card};
        border: 1px solid {p.card_border};
        selection-background-color: {p.accent};
        selection-color: {p.accent_text};
        outline: none;
    }}
    /* The rows are drawn by a delegate, so the view itself is just a
       transparent surface: a field border around a list of cards read as
       a box inside a box. */
    QListWidget {{
        background: transparent;
        border: none;
        padding: 0;
        outline: none;
    }}

    QCheckBox, QRadioButton {{ background: transparent; spacing: 8px; }}
    QCheckBox::indicator, QRadioButton::indicator {{ width: 17px; height: 17px; }}
    QCheckBox::indicator {{
        border: 1px solid {p.control_border};
        border-radius: 5px;
        background: {p.field};
    }}
    QCheckBox::indicator:checked {{
        background: {p.accent};
        border-color: {p.accent};
        image: url("{check}");
    }}
    QCheckBox::indicator:hover {{ border-color: {p.accent}; }}
    QCheckBox:disabled {{ color: {p.text_faint}; }}

    /* No frame around the pane: every section inside is already a card,
       and a card drawn inside a card left a visible dead margin between
       the two borders and a large empty box under a short tab. */
    QTabWidget::pane {{
        border: none;
        background: transparent;
    }}
    QTabBar::tab {{
        background: transparent;
        color: {p.text_muted};
        padding: 8px 14px;
        margin-right: 2px;
        border-radius: 8px;
    }}
    QTabBar::tab:selected {{ background: {p.control}; color: {p.text}; }}
    QTabBar::tab:hover:!selected {{ color: {p.text}; }}

    QProgressBar {{
        background: {p.field};
        border: 1px solid {p.control_border};
        border-radius: 7px;
        height: 14px;
        text-align: center;
        color: {p.text_muted};
        font-size: 10px;
    }}
    QProgressBar::chunk {{ background: {p.accent}; border-radius: 6px; }}

    QScrollBar:vertical {{
        background: transparent; width: 10px; margin: 2px;
    }}
    QScrollBar::handle:vertical {{
        background: {p.control_border}; border-radius: 5px; min-height: 24px;
    }}
    QScrollBar::add-line, QScrollBar::sub-line {{ height: 0; }}
    QScrollBar::add-page, QScrollBar::sub-page {{ background: transparent; }}

    QToolTip {{
        background: {p.card};
        color: {p.text};
        border: 1px solid {p.card_border};
        padding: 5px 7px;
        border-radius: 6px;
    }}
    """
