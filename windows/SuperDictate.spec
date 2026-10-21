# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller build for SuperDictate.

One-folder rather than one-file: Qt, ONNX Runtime and the engine hosts
are large native DLLs, and a one-file build would unpack them to a
temporary directory on every launch, adding seconds to a hotkey-driven app that is meant to sit in the
tray from login.

Speech recognition runs in SuperDictateOnnxHost.exe, the native host
shared with the macOS build. tools\build-onnx-host.ps1 stages it with
onnxruntime.dll, the pinned model catalog and the bundled feature graphs
into onnx-asr\, which travels into the build as is. The app itself never
imports ONNX Runtime.

The speech model is NOT bundled. It is ~600 MB, it is licensed
separately, and the app already downloads it on first run with a progress
bar into %LOCALAPPDATA%\\SuperDictate\\Models\\onnx.
"""

import os

from PyInstaller.utils.hooks import collect_data_files, copy_metadata  # noqa: F401

if not os.path.isfile(os.path.join("onnx-asr", "SuperDictateOnnxHost.exe")):
    raise SystemExit("onnx-asr\\ is not staged: run tools\\build-onnx-host.ps1 first")

datas = []
# The tray icon is drawn from the product mark at runtime, so the PNG has
# to travel with the build; the .ico only covers the window/taskbar icon
# that Windows reads from the executable itself.
datas += [("assets/SuperDictate.png", "assets")]
# The recording cues are played straight off disk by winsound.
datas += [("assets/record-start.wav", "assets"),
          ("assets/record-stop.wav", "assets")]
datas += [("onnx-asr", "onnx-asr")]
# silero-vad.dll, and in experimental builds superdictate-llm-host.exe,
# built by tools/build-engines.ps1 from the vendored macOS sources.
# Optional: without the VAD, seams fall back to mel energy. Release builds
# have no LLM host: post-processing goes through an OpenAI-compatible API.
if os.path.isdir("engines"):
    datas += [("engines", "engines")]
else:
    print("WARNING: engines\\ is missing; the build has no Silero VAD")
if os.path.isfile(os.path.join("engines", "superdictate-llm-host.exe")):
    # The correction LoRA belongs to the bundled host (llm/models.py).
    datas += [("assets/models/gec-lora-adapter.gguf", "assets/models")]
binaries = []

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
