"""SVG icon set.

Emoji were replaced by these because emoji are a font dependency: they
render at whatever size and colour the system font decides, they differ
between Windows versions, and they cannot follow the app's accent colour.
Each icon here is a stroked path on a 24x24 grid, recoloured at render
time and cached per (name, colour, size).

Paths are stroke-only and share a 1.8px weight so the set looks like one
family. `render` returns a QIcon; `pixmap` returns the bitmap directly.
"""

from __future__ import annotations

from functools import lru_cache

from PySide6.QtCore import QByteArray, QSize, Qt
from PySide6.QtGui import QIcon, QPainter, QPixmap
from PySide6.QtSvg import QSvgRenderer

# 24x24 viewBox, stroked, no fills.
_PATHS: dict[str, str] = {
    "mic": "M12 3a3 3 0 0 1 3 3v6a3 3 0 0 1-6 0V6a3 3 0 0 1 3-3z"
           "M5 11a7 7 0 0 0 14 0M12 18v3M8 21h8",
    "settings": "M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6z"
                "M19.4 15a1.6 1.6 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1"
                "a1.6 1.6 0 0 0-1.8-.3 1.6 1.6 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1"
                "a1.6 1.6 0 0 0-1-1.5 1.6 1.6 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8"
                "l.1-.1a1.6 1.6 0 0 0 .3-1.8 1.6 1.6 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1"
                "a1.6 1.6 0 0 0 1.5-1 1.6 1.6 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8"
                "l.1.1a1.6 1.6 0 0 0 1.8.3H9a1.6 1.6 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1"
                "a1.6 1.6 0 0 0 1 1.5 1.6 1.6 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8"
                "l-.1.1a1.6 1.6 0 0 0-.3 1.8V9a1.6 1.6 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1"
                "a1.6 1.6 0 0 0-1.5 1z",
    "history": "M3 12a9 9 0 1 0 3-6.7M3 4v4h4M12 7v5l3 2",
    "chart": "M4 20V10M10 20V4M16 20v-7M22 20H2",
    "download": "M12 3v12M7 11l5 5 5-5M4 21h16",
    "refresh": "M21 12a9 9 0 1 1-2.6-6.4M21 3v6h-6",
    "keyboard": "M3 6h18v12H3zM7 10h.01M11 10h.01M15 10h.01M17 10h.01"
                "M7 14h10",
    "language": "M3 12h18M12 3a15 15 0 0 1 0 18 15 15 0 0 1 0-18z"
                "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18z",
    "sparkles": "M12 3l1.8 4.7L18.5 9.5 13.8 11.3 12 16l-1.8-4.7L5.5 9.5 10.2 7.7z"
                "M19 15l.9 2.3 2.3.9-2.3.9-.9 2.3-.9-2.3-2.3-.9 2.3-.9z",
    "palette": "M12 3a9 9 0 1 0 0 18c1 0 1.7-.8 1.7-1.7 0-.5-.2-.9-.5-1.2"
               "-.3-.3-.5-.7-.5-1.2 0-1 .8-1.7 1.7-1.7H16a5 5 0 0 0 5-5c0-4-4-7-9-7z"
               "M7.5 12h.01M10 8h.01M14 7.5h.01M17.5 10h.01",
    "replace": "M4 7h9M4 7l3-3M4 7l3 3M20 17h-9M20 17l-3-3M20 17l-3 3",
    "sliders": "M4 6h10M18 6h2M4 12h4M12 12h8M4 18h8M16 18h4"
               "M16 6a2 2 0 1 0 0 .01M10 12a2 2 0 1 0 0 .01M14 18a2 2 0 1 0 0 .01",
    "check": "M4 12.5l5 5L20 6.5",
    "clock": "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 7v5l3.5 2",
    "volume": "M11 5L6 9H3v6h3l5 4zM15.5 8.5a5 5 0 0 1 0 7M18.5 5.5a9 9 0 0 1 0 13",
    "type": "M4 7V5h16v2M12 5v14M9 19h6",
    "trash": "M4 7h16M9 7V5h6v2M6 7l1 13h10l1-13M10 11v6M14 11v6",
    "plus": "M12 5v14M5 12h14",
    # The disclosure arrow. Two of them rather than one rotated icon: a
    # rotation would have to be animated to read as the same triangle
    # moving, and a static rotated glyph just looks like a different icon.
    "chevron-right": "M9 5l7 7-7 7",
    "chevron-down": "M5 9l7 7 7-7",
    "close": "M6 6l12 12M18 6L6 18",
    "cpu": "M7 7h10v10H7zM4 10h3M4 14h3M17 10h3M17 14h3"
           "M10 4v3M14 4v3M10 17v3M14 17v3",
    "info": "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 11v5M12 8h.01",
    "help": "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18z"
            "M9.6 9.3a2.5 2.5 0 0 1 4.9.7c0 1.7-2.5 2-2.5 3.5M12 17h.01",
    "warning": "M12 3.5L2 20.5h20zM12 10v4.5M12 17.5h.01",
    "error": "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM9 9l6 6M15 9l-6 6",
    "words": "M4 6h16M4 12h16M4 18h10",
}

_STROKE_TEMPLATE = (
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" '
    'fill="none" stroke="{color}" stroke-width="{width}" '
    'stroke-linecap="round" stroke-linejoin="round">'
    '<path d="{path}"/></svg>'
)


def svg_source(name: str, color: str, width: float = 1.8) -> str:
    """The raw SVG, useful for embedding somewhere other than a QIcon."""
    return _STROKE_TEMPLATE.format(color=color, width=width,
                                   path=_PATHS.get(name, _PATHS["info"]))


@lru_cache(maxsize=256)
def pixmap(name: str, color: str, size: int = 18, width: float = 1.8) -> QPixmap:
    renderer = QSvgRenderer(QByteArray(svg_source(name, color, width).encode()))
    result = QPixmap(size, size)
    result.fill(Qt.GlobalColor.transparent)
    painter = QPainter(result)
    painter.setRenderHint(QPainter.RenderHint.Antialiasing)
    renderer.render(painter)
    painter.end()
    return result


def icon(name: str, color: str, size: int = 18, width: float = 1.8) -> QIcon:
    return QIcon(pixmap(name, color, size, width))


@lru_cache(maxsize=32)
def stylesheet_url(name: str, color: str, size: int = 14,
                   width: float = 2.4) -> str:
    """A ``url(...)`` path for Qt stylesheets.

    Stylesheets cannot take a QIcon and this app has no compiled .qrc, so
    the glyph is materialised as a PNG in the app directory. Without it a
    checked QCheckBox is just a filled blue square with no tick.
    """
    from .. import paths

    cache = paths.CACHE_DIR
    cache.mkdir(parents=True, exist_ok=True)
    target = cache / f"{name}-{color.lstrip('#')}-{size}.png"
    if not target.exists():
        pixmap(name, color, size, width).save(str(target), "PNG")
    return target.as_posix()


@lru_cache(maxsize=64)
def swatch(color: str, size: int = 14) -> QIcon:
    """A filled colour chip, for choosing a colour rather than a concept."""
    from PySide6.QtCore import QRectF
    from PySide6.QtGui import QColor

    result = QPixmap(size, size)
    result.fill(Qt.GlobalColor.transparent)
    painter = QPainter(result)
    painter.setRenderHint(QPainter.RenderHint.Antialiasing)
    painter.setBrush(QColor(color))
    painter.setPen(QColor(0, 0, 0, 70))
    inset = 0.5
    painter.drawRoundedRect(
        QRectF(inset, inset, size - 2 * inset, size - 2 * inset), 4, 4)
    painter.end()
    return QIcon(result)


@lru_cache(maxsize=64)
def gradient_swatch(start: str, end: str, size: int = 14) -> QIcon:
    """A chip split across two colours, for a gradient setting."""
    from PySide6.QtCore import QPointF, QRectF
    from PySide6.QtGui import QColor, QLinearGradient

    result = QPixmap(size, size)
    result.fill(Qt.GlobalColor.transparent)
    painter = QPainter(result)
    painter.setRenderHint(QPainter.RenderHint.Antialiasing)
    gradient = QLinearGradient(QPointF(0, 0), QPointF(size, size))
    gradient.setColorAt(0.0, QColor(start))
    gradient.setColorAt(1.0, QColor(end))
    painter.setBrush(gradient)
    painter.setPen(QColor(0, 0, 0, 70))
    inset = 0.5
    painter.drawRoundedRect(
        QRectF(inset, inset, size - 2 * inset, size - 2 * inset), 4, 4)
    painter.end()
    return QIcon(result)


def icon_size(size: int = 18) -> QSize:
    return QSize(size, size)
