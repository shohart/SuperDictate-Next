"""Pack assets/SuperDictate.png into assets/SuperDictate.ico.

Windows wants a multi-size .ico for the executable, the installer and the
Explorer entry. The artwork is a single square PNG, so this only rescales
it; the tray builds its own QIcon from the same file at runtime.

Part of the build: ``build.ps1`` runs this before PyInstaller, so the .ico
always matches the artwork in the repository. Run it by hand from the
repository root after changing that artwork::

    python tools/make_icon.py
"""

from __future__ import annotations

import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from PySide6.QtCore import QBuffer, QByteArray, Qt  # noqa: E402
from PySide6.QtGui import QGuiApplication, QPixmap  # noqa: E402

SIZES = (16, 24, 32, 48, 64, 128, 256)
SOURCE = ROOT / "assets" / "SuperDictate.png"


def png_bytes(source: QPixmap, size: int) -> bytes:
    scaled = source.scaled(
        size, size,
        Qt.AspectRatioMode.KeepAspectRatio,
        Qt.TransformationMode.SmoothTransformation,
    )
    # The QByteArray must outlive the QBuffer that writes into it.
    storage = QByteArray()
    buffer = QBuffer(storage)
    buffer.open(QBuffer.OpenModeFlag.WriteOnly)
    scaled.save(buffer, "PNG")
    buffer.close()
    return bytes(storage)


def build_ico(images: list[tuple[int, bytes]]) -> bytes:
    header = struct.pack("<HHH", 0, 1, len(images))
    offset = len(header) + 16 * len(images)
    entries, blobs = b"", b""
    for size, data in images:
        entries += struct.pack(
            "<BBBBHHII",
            0 if size >= 256 else size,   # 0 means 256
            0 if size >= 256 else size,
            0, 0, 1, 32, len(data), offset,
        )
        blobs += data
        offset += len(data)
    return header + entries + blobs


def main() -> int:
    app = QGuiApplication(sys.argv)  # noqa: F841 - needed for QPixmap
    source = QPixmap(str(SOURCE))
    if source.isNull():
        print(f"missing or unreadable artwork: {SOURCE}", file=sys.stderr)
        return 1
    images = [(size, png_bytes(source, size)) for size in SIZES]
    target = ROOT / "assets" / "SuperDictate.ico"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(build_ico(images))
    print(f"wrote {target} ({target.stat().st_size} bytes, {len(images)} sizes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
