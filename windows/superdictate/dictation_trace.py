"""What each stage of a dictation produced, kept on this machine only, for
finding where the text went wrong. The history already holds the final text;
this adds what recognition wrote before the rules and the corrector changed
it. macOS: ``DictationTrace.swift``."""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Optional

from . import paths
from .logging_setup import get as get_logger

log = get_logger("dictation_trace")

TRACE_FILE = paths.BASE_DIR / "DictationTrace.jsonl"
DEFAULT_MAX_LINES = 2000


def record(asr: str, rules: str, final: str, *, path: Optional[Path] = None,
           max_lines: int = DEFAULT_MAX_LINES) -> None:
    """Never raises: a disk problem must not touch a dictation. The file is
    cut back to ``max_lines`` once it reaches twice that."""
    from .vocabulary import _timestamp

    target = Path(path or TRACE_FILE)
    line = json.dumps({"at": _timestamp(), "asr": asr, "rules": rules, "final": final}, ensure_ascii=False)
    try:
        with open(target, "a", encoding="utf-8") as handle:
            handle.write(line + "\n")
        lines = target.read_text(encoding="utf-8").splitlines()
        if len(lines) >= max_lines * 2:
            temp = target.with_suffix(".tmp")
            temp.write_text("\n".join(lines[-max_lines:]) + "\n", encoding="utf-8")
            os.replace(temp, target)
    except OSError as exc:
        log.debug("Could not write the dictation trace: %s", exc)
