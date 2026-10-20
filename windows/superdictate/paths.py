"""Filesystem layout for the Windows port.

The macOS build keeps everything under ``~/Library/Application Support/
SuperDictate`` with the FluidAudio model cache in a sibling directory.
(The app was called SuperDictate here too, before 1.5.0.)
Windows has no equivalent split, so one ``%LOCALAPPDATA%\\SuperDictate`` tree
holds settings, history and the ONNX model cache. Keeping the model inside
the same tree means an uninstall that spares user data also spares the
~600 MB download, matching the macOS uninstall.sh behaviour.
"""

from __future__ import annotations

import logging
import os
from pathlib import Path

# Not logging_setup's helper: that module imports this one, and the
# directories have to exist before logging can be configured at all.
log = logging.getLogger("superdictate.paths")

APP_NAME = "SuperDictate"
BUNDLE_ID = "com.local.superdictate"
# Where the app kept its data under its two previous names, newest first.
# An existing tree is moved into place on first launch, so a rename never
# costs anybody the 640 MB of weights or their history.
LEGACY_APP_NAMES = ("Dictation", "D1CT")


def _local_app_data() -> Path:
    raw = os.environ.get("LOCALAPPDATA")
    if raw:
        return Path(raw)
    return Path.home() / "AppData" / "Local"


_HOME_OVERRIDE = (os.environ.get("DICTATION_HOME")
                  or os.environ.get("D1CT_HOME")
                  or os.environ.get("SUPERDICTATE_HOME"))
BASE_DIR = Path(_HOME_OVERRIDE or (_local_app_data() / APP_NAME))
LEGACY_BASE_DIRS = tuple(_local_app_data() / name for name in LEGACY_APP_NAMES)

SETTINGS_FILE = BASE_DIR / "Settings.json"
HISTORY_FILE = BASE_DIR / "History.json"
USAGE_FILE = BASE_DIR / "Usage.json"
CORRECTIONS_FILE = BASE_DIR / "Corrections.json"
PENDING_DICTATION_FILE = BASE_DIR / "PendingDictation.raw"
# Present only while the app is holding the system output muted. Left
# behind by a run that died mid-recording, and cleared by the next one
# after it unmutes.
MUTE_MARKER_FILE = BASE_DIR / "OutputMuted.flag"
LOG_DIR = BASE_DIR / "Logs"
LOG_FILE = LOG_DIR / "SuperDictate.log"
CRASH_FILE = LOG_DIR / "Crash.log"
MODELS_DIR = BASE_DIR / "Models"
CACHE_DIR = BASE_DIR / "Cache"
SINGLE_INSTANCE_MUTEX = "Global\\SuperDictate.SingleInstance"


def _holds_user_data(directory: Path) -> bool:
    """Whether a tree is somebody's data rather than empty scaffolding.

    Existence is not the test. Every directory here is created on demand —
    an icon written to ``Cache`` is enough to bring the whole tree into
    being — so a check for the directory alone would call a settings file
    and 640 MB of weights "already migrated" and strand them under the old
    name forever.
    """
    return (directory / "Settings.json").exists()


def migrate_legacy_directory() -> bool:
    """Move a pre-rename data tree into place. Returns True if anything moved.

    Never runs once the new tree holds real data, so somebody who has
    started fresh does not have old data pushed back at them. The newest
    previous name wins, so an install that went through both renames does
    not resurrect the older of its two trees.
    """
    if _holds_user_data(BASE_DIR):
        return False
    for legacy in LEGACY_BASE_DIRS:
        if not _holds_user_data(legacy) or BASE_DIR.resolve() == legacy.resolve():
            continue
        moved = False
        try:
            BASE_DIR.mkdir(parents=True, exist_ok=True)
            # Settings.json is what marks a tree as migrated, so it moves
            # last: if anything else is locked — a log file held open by the
            # copy still shutting down, say — the marker stays behind and the
            # next launch finishes the job instead of declaring victory over
            # a half-moved tree.
            for entry in sorted(legacy.iterdir(),
                                key=lambda path: path.name == "Settings.json"):
                target = BASE_DIR / entry.name
                if target.exists():
                    # An empty directory is scaffolding and gives way; a
                    # directory with anything in it is left alone, and the
                    # old copy stays where it is rather than being merged.
                    if target.is_dir() and not any(target.iterdir()):
                        target.rmdir()
                    else:
                        continue
                os.replace(entry, target)
                moved = True
            if moved and not any(legacy.iterdir()):
                legacy.rmdir()
        except OSError as exc:
            log.warning("Could not migrate %s: %s", legacy, exc)
        return moved
    return False


def ensure_directories() -> None:
    migrate_legacy_directory()
    for directory in (BASE_DIR, LOG_DIR, MODELS_DIR, CACHE_DIR):
        directory.mkdir(parents=True, exist_ok=True)


def resource_path(*parts: str) -> Path:
    """Resolve a bundled resource both in-tree and inside a PyInstaller bundle."""
    import sys

    root = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent.parent))
    return root.joinpath(*parts)
