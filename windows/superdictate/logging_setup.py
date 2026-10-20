"""Rotating file log plus stderr, mirroring ``~/Library/Logs/SuperDictate*``."""

from __future__ import annotations

import faulthandler
import logging
import logging.handlers
import sys

from . import paths

_configured = False
_crash_file = None  # kept open for the process lifetime on purpose


def configure(verbose: bool = False) -> logging.Logger:
    global _configured
    logger = logging.getLogger("superdictate")
    if _configured:
        return logger

    _guard_standard_streams()
    paths.ensure_directories()
    logger.setLevel(logging.DEBUG if verbose else logging.INFO)
    formatter = logging.Formatter(
        "%(asctime)s %(levelname)-7s %(name)s: %(message)s", "%Y-%m-%d %H:%M:%S"
    )

    file_handler = logging.handlers.RotatingFileHandler(
        paths.LOG_FILE, maxBytes=2 * 1024 * 1024, backupCount=3, encoding="utf-8"
    )
    file_handler.setFormatter(formatter)
    logger.addHandler(file_handler)

    # A windowed PyInstaller build has no stderr; guard so logging never
    # becomes the thing that crashes the app, and do not bother handing
    # lines to the placeholder that replaced it.
    if sys.stderr is not None and not isinstance(sys.stderr, _NullStream):
        stream = logging.StreamHandler(sys.stderr)
        stream.setFormatter(formatter)
        logger.addHandler(stream)

    logger.propagate = False
    _enable_crash_dump()
    _configured = True
    return logger


class _NullStream:
    """Somewhere for output to go when the process has nowhere.

    A windowed build starts with ``sys.stdout`` and ``sys.stderr`` set to
    ``None``, and a library that prints — huggingface_hub draws a download
    bar, for one — dies on ``None.write`` and takes its caller's work with
    it. The app's own logging goes to a file either way, so nothing is
    lost by swallowing this.
    """

    encoding = "utf-8"

    def write(self, text: str) -> int:
        return len(text)

    def flush(self) -> None:
        pass

    def isatty(self) -> bool:
        return False

    def fileno(self) -> int:
        raise OSError("no file descriptor")


def _guard_standard_streams() -> None:
    if sys.stdout is None:
        sys.stdout = _NullStream()
    if sys.stderr is None:
        sys.stderr = _NullStream()


def _enable_crash_dump() -> None:
    """Write a Python traceback when the process dies inside native code.

    An access violation in a DLL takes the interpreter with it: no
    exception, no log line, just a process that is suddenly gone and a
    Windows event that names the module and nothing else. faulthandler
    catches the signal and writes the stack of every thread first, which
    is the difference between "it crashes sometimes" and a file name and
    a line number.
    """
    global _crash_file

    try:
        _crash_file = open(paths.CRASH_FILE, "a", encoding="utf-8")
        faulthandler.enable(file=_crash_file, all_threads=True)
    except OSError as exc:
        logging.getLogger("superdictate").warning(
            "Could not arm the crash handler: %s", exc)


def get(name: str = "") -> logging.Logger:
    base = logging.getLogger("superdictate")
    return base.getChild(name) if name else base
