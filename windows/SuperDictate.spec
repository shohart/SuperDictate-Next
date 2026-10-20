# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller build for SuperDictate.

One-folder rather than one-file: onnxruntime ships large native DLLs, and
a one-file build would unpack ~200 MB to a temporary directory on every
launch, adding seconds to a hotkey-driven app that is meant to sit in the
tray from login.

The speech model is NOT bundled. It is ~640 MB, it is licensed
separately, and the app already downloads it on first run with a progress
bar into %LOCALAPPDATA%\\SuperDictate\\Models.
"""

from PyInstaller.utils.hooks import (
    collect_data_files,
    collect_dynamic_libs,
    copy_metadata,
)

datas = collect_data_files("onnx_asr")
# onnx_asr/__init__.py reads its own version through importlib.metadata at
# import time, which raises PackageNotFoundError unless the dist-info is
# shipped alongside the code.
datas += copy_metadata("onnx-asr")
datas += copy_metadata("onnxruntime")
# The tray icon is drawn from the product mark at runtime, so the PNG has
# to travel with the build; the .ico only covers the window/taskbar icon
# that Windows reads from the executable itself.
datas += [("assets/SuperDictate.png", "assets")]
# The recording cues are played straight off disk by winsound.
datas += [("assets/record-start.wav", "assets"),
          ("assets/record-stop.wav", "assets")]
binaries = collect_dynamic_libs("onnxruntime")

hiddenimports = [
    "comtypes.stream",     # pycaw resolves this lazily at runtime
    "pycaw.pycaw",
    "sounddevice",
]

a = Analysis(
    ["main.py"],
    pathex=[],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    runtime_hooks=[],
    # PySide6-Essentials still carries modules this app never touches;
    # dropping them saves roughly 150 MB in the output folder.
    excludes=[
        "PySide6.QtQml", "PySide6.QtQuick", "PySide6.QtQuick3D",
        "PySide6.QtWebEngineCore", "PySide6.QtWebEngineWidgets",
        "PySide6.Qt3DCore", "PySide6.QtMultimedia", "PySide6.QtCharts",
        "PySide6.QtDataVisualization", "PySide6.QtPdf", "PySide6.QtSql",
        "PySide6.QtTest", "PySide6.QtDesigner",
        "tkinter", "unittest", "pydoc_data",
    ],
    noarchive=False,
)

pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="SuperDictate",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=False,          # tray app: a console window would flash on login
    disable_windowed_traceback=False,
    icon="assets/SuperDictate.ico",
)

coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    name="SuperDictate",
)
