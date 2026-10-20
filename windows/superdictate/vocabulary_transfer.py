"""Reading and writing the dictionary exchange file.

Port of ``swift/Sources/Parakey/CorrectionsTransfer.swift``. The point of
this module is that the file it produces is byte-compatible with the macOS
build's, so a dictionary built up on one machine can be carried to the
other — or to a Mac — and opened without conversion.

The format is a document, not a bare list::

    {
      "schemaVersion": 1,
      "exportedAt": "2026-08-29T09:12:44Z",
      "appVersion": "0.6.0",
      "corrections": [{"source": "гитхаб", "replacement": "GitHub"}]
    }

The envelope earns its keys. ``schemaVersion`` lets a future format change
be refused with a clear message instead of being half-read; ``exportedAt``
and ``appVersion`` answer "where did this file come from" when somebody
mails one in with a complaint about it.

A bare list is still accepted on import, because that is what this port
wrote before it grew this module and what its own settings file has always
looked like. Nothing ever writes a bare list again.
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass
from typing import Sequence

from .version import VERSION

SCHEMA_VERSION = 1

#: A dictionary is a few kilobytes; a few megabytes is already something
#: else entirely. Refusing early keeps a mistyped path from being parsed as
#: JSON at all.
MAX_FILE_BYTES = 4 * 1024 * 1024


class TransferError(Exception):
    """The file is not a dictionary this version can read."""


@dataclass(frozen=True)
class DecodedDocument:
    corrections: list[tuple[str, str]]
    #: How many entries the file held before invalid ones were dropped, so
    #: the caller can say "imported 12 of 14" rather than silently losing
    #: two.
    total_in_file: int
    app_version: str = ""
    exported_at: str = ""

    @property
    def skipped(self) -> int:
        return max(0, self.total_in_file - len(self.corrections))


def encode(corrections: Sequence[tuple[str, str]]) -> str:
    """Serialise to the exchange format, ready to write as UTF-8."""
    document = {
        "schemaVersion": SCHEMA_VERSION,
        "exportedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "appVersion": VERSION,
        "corrections": [{"source": source, "replacement": replacement}
                        for source, replacement in corrections],
    }
    return json.dumps(document, ensure_ascii=False, indent=1)


def decode(raw: str) -> DecodedDocument:
    """Parse either the document format or a bare list.

    Raises :class:`TransferError` with something a person can act on: the
    caller shows the message, so "not a dictionary file" beats a traceback
    about a missing key.
    """
    if len(raw.encode("utf-8")) > MAX_FILE_BYTES:
        raise TransferError(
            f"file is larger than {MAX_FILE_BYTES // (1 << 20)} MB")

    try:
        payload = json.loads(raw)
    except ValueError as exc:
        raise TransferError(f"not valid JSON: {exc}") from exc

    app_version = ""
    exported_at = ""
    if isinstance(payload, dict):
        version = payload.get("schemaVersion")
        if not isinstance(version, int):
            raise TransferError("no schemaVersion — not a dictionary file")
        if version > SCHEMA_VERSION:
            raise TransferError(
                f"written by a newer version (schema {version}, "
                f"this build reads {SCHEMA_VERSION})")
        entries = payload.get("corrections")
        app_version = str(payload.get("appVersion", ""))
        exported_at = str(payload.get("exportedAt", ""))
    elif isinstance(payload, list):
        # The shape this port wrote before the envelope existed.
        entries = payload
    else:
        raise TransferError("not a dictionary file")

    if not isinstance(entries, list):
        raise TransferError("the corrections list is missing or malformed")

    pairs: list[tuple[str, str]] = []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        source = str(entry.get("source", "")).strip()
        replacement = str(entry.get("replacement", "")).strip()
        if source and replacement:
            pairs.append((source, replacement))

    return DecodedDocument(corrections=pairs, total_in_file=len(entries),
                           app_version=app_version, exported_at=exported_at)
