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

Recognition on the Intel NPU runs in a second executable,
SuperDictateOvHost.exe (ov_host_main.py): OpenVINO and the NPU builds of
the models (assets/openvino-models.json, downloaded into Models\\openvino).
It is a console program because it speaks binary frames on stdin/stdout;
the app starts it with CREATE_NO_WINDOW. Both executables share one folder.
"""

import os

from PyInstaller.utils.hooks import (collect_data_files, collect_dynamic_libs,  # noqa: F401
                                     copy_metadata)

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
# The pinned catalog of the NPU models (onnx_models.openvino_catalog_path).
datas += [("assets/openvino-models.json", "assets")]
# silero-vad.dll and superdictate-llm-host.exe (CPU + Vulkan), built by
# tools/build-engines.ps1 from the vendored macOS sources. Optional: without
# the VAD, seams fall back to mel energy; without the host, post-processing
# goes through an OpenAI-compatible API only.
if os.path.isdir("engines"):
    datas += [("engines", "engines")]
else:
    print("WARNING: engines\\ is missing; the build has no Silero VAD")
if os.path.isfile(os.path.join("engines", "superdictate-llm-host.exe")):
    # The correction LoRA belongs to the bundled host (llm/models.py).
    datas += [("assets/models/gec-lora-adapter.gguf", "assets/models"),
              ("assets/models/chat-template-lfm25.jinja", "assets/models")]
binaries = []

hiddenimports = [
    "comtypes.stream",     # pycaw resolves this lazily at runtime
    "pycaw.pycaw",
    # focus_target: the caret and the paste target through UI Automation.
    # build.ps1 generates these before PyInstaller runs.
    "comtypes.gen.UIAutomationClient",
    "comtypes.gen._944DE083_8FB8_45CF_BCB7_C477ACB2F897_0_1_0",
    "comtypes.gen.stdole",
    "sounddevice",
    # vocabulary_sync: the DPAPI-protected sync token, imported lazily.
    "win32crypt",
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
        # OpenVINO belongs to SuperDictateOvHost alone; the app only starts it.
        "openvino", "openvino_telemetry",
    ],
    noarchive=False,
)

pyz = PYZ(a.pure)

# -- SuperDictateOvHost.exe ----------------------------------------------
#
# OpenVINO finds its plugins next to openvino.dll, so its libraries keep
# their openvino\libs layout. Only what the NPU path loads is kept: the
# core, the CPU and NPU plugins with the NPU compiler, the IR reader and
# TBB. The GPU plugin and the ONNX/TF/PyTorch/Paddle/JAX/GGUF frontends
# (~50 MB) are never touched.
_OPENVINO_UNUSED = (
    "openvino_intel_gpu_plugin", "openvino_onnx_frontend", "openvino_tensorflow_frontend",
    "openvino_tensorflow_lite_frontend", "openvino_pytorch_frontend",
    "openvino_paddle_frontend", "openvino_jax_frontend", "openvino_gguf_frontend",
)


def _openvino_needed(entry) -> bool:
    name = os.path.basename(entry[0]).lower()
    return not any(name.startswith(prefix) for prefix in _OPENVINO_UNUSED)


ov_binaries = [b for b in collect_dynamic_libs("openvino") if _openvino_needed(b)]

ov = Analysis(
    ["ov_host_main.py"],
    pathex=[],
    binaries=ov_binaries,
    datas=[],
    hiddenimports=["superdictate.openvino_asr"],
    hookspath=[],
    runtime_hooks=[],
    # The converter (openvino.tools) and its telemetry are for building IR,
    # not for running it.
    excludes=["PySide6", "openvino.tools", "openvino_telemetry",
              "tkinter", "unittest", "pydoc_data"],
    noarchive=False,
)
ov.binaries = [b for b in ov.binaries if _openvino_needed(b)]
ov_pyz = PYZ(ov.pure)

ov_exe = EXE(
    ov_pyz,
    ov.scripts,
    [],
    exclude_binaries=True,
    name="SuperDictateOvHost",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,           # real stdin/stdout for the IPC frames
    disable_windowed_traceback=False,
    icon="assets/SuperDictate.ico",
)

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
    ov_exe,
    ov.binaries,
    ov.datas,
    strip=False,
    upx=False,
    name="SuperDictate",
)
