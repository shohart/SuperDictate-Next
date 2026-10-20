"""Fetching the post-processing weights.

The ASR model comes down through ``huggingface_hub``'s ``snapshot_download``
(see :mod:`superdictate.asr`), which is the right tool for a directory of
files. These are single large files pinned to an exact revision and an exact
digest, so they are fetched directly instead: a plain ranged HTTP download
that can be resumed, verified and reported on without a second dependency
deciding what "latest" means.

**Every download is verified before it is used.** A truncated 4.9 GB file
that llama.cpp then refuses to load is a confusing failure; a size and
SHA-256 check at the end of the download is a clear one. The digests are
the macOS build's, computed from the actual bytes.
"""

from __future__ import annotations

import hashlib
import os
import shutil
import threading
import urllib.error
import urllib.request
from dataclasses import dataclass
from enum import Enum
from typing import Callable, Optional

from ..logging_setup import get as get_logger
from .models import ModelPin

log = get_logger("llm.download")

#: Enough of the file to make the request worth its round trip, small enough
#: that cancelling is felt as immediate.
CHUNK_BYTES = 1 << 20

#: How much room to insist on beyond the file itself, so a download cannot
#: fill the disk it is landing on.
HEADROOM_BYTES = 512 * 1024 * 1024


class DownloadState(str, Enum):
    IDLE = "idle"
    DOWNLOADING = "downloading"
    VERIFYING = "verifying"
    READY = "ready"
    FAILED = "failed"
    CANCELLED = "cancelled"


@dataclass
class DownloadProgress:
    state: DownloadState
    downloaded_bytes: int = 0
    total_bytes: int = 0
    message: str = ""

    @property
    def fraction(self) -> float:
        if self.total_bytes <= 0:
            return 0.0
        return min(1.0, self.downloaded_bytes / self.total_bytes)


class DownloadError(Exception):
    pass


def is_present(pin: ModelPin) -> bool:
    """Whether the pinned file is already on disk at the right size.

    Size only, not the digest: hashing five gigabytes on every launch to
    answer "is it there" would cost seconds for a question the size already
    answers. The digest is checked once, when the file arrives.
    """
    try:
        return os.path.getsize(pin.local_path) == pin.size_bytes
    except OSError:
        return False


def local_bytes(pin: ModelPin) -> int:
    for path in (pin.local_path, pin.local_path + ".part"):
        try:
            return os.path.getsize(path)
        except OSError:
            continue
    return 0


def free_space(path: str) -> int:
    try:
        return shutil.disk_usage(os.path.dirname(path) or ".").free
    except OSError:
        return 0


def download(pin: ModelPin, *,
             on_progress: Optional[Callable[[DownloadProgress], None]] = None,
             cancel: Optional[threading.Event] = None) -> bool:
    """Fetch one pinned file. Blocking; call off the UI thread.

    Returns True when the file is on disk and verified. Resumes a partial
    download rather than starting over — these are large files and a
    dropped connection three gigabytes in should not cost all three.
    """
    def report(progress: DownloadProgress) -> None:
        if on_progress is not None:
            try:
                on_progress(progress)
            except Exception:
                log.debug("Download progress callback raised", exc_info=True)

    if is_present(pin):
        report(DownloadProgress(DownloadState.READY, pin.size_bytes,
                                pin.size_bytes))
        return True

    target = pin.local_path
    partial = target + ".part"
    os.makedirs(os.path.dirname(target), exist_ok=True)

    needed = pin.size_bytes - local_bytes(pin) + HEADROOM_BYTES
    available = free_space(target)
    if available and available < needed:
        message = (f"not enough disk space: need {needed // (1 << 20)} MB, "
                   f"have {available // (1 << 20)} MB")
        log.error("%s", message)
        report(DownloadProgress(DownloadState.FAILED, message=message))
        return False

    have = 0
    try:
        have = os.path.getsize(partial)
    except OSError:
        pass
    if have > pin.size_bytes:
        # A partial file bigger than the finished one is not a resume point,
        # it is a different file that happens to share the name.
        log.warning("Discarding oversized partial download for %s", pin.filename)
        os.unlink(partial)
        have = 0

    request = urllib.request.Request(pin.url, headers={
        "User-Agent": "SuperDictate-Windows",
    })
    if have:
        request.add_header("Range", f"bytes={have}-")
        log.info("Resuming %s at %d bytes", pin.filename, have)

    report(DownloadProgress(DownloadState.DOWNLOADING, have, pin.size_bytes))
    try:
        # No proxy handler here on purpose: unlike the loopback host, this
        # is a real internet fetch and must honour a corporate proxy.
        with urllib.request.urlopen(request, timeout=60) as response:
            if have and response.status != 206:
                # The server ignored the range request and is sending the
                # whole file; start over rather than appending to a prefix.
                log.info("Server ignored the range request; restarting %s",
                         pin.filename)
                have = 0
            mode = "ab" if have else "wb"
            with open(partial, mode) as handle:
                while True:
                    if cancel is not None and cancel.is_set():
                        report(DownloadProgress(DownloadState.CANCELLED, have,
                                                pin.size_bytes))
                        return False
                    chunk = response.read(CHUNK_BYTES)
                    if not chunk:
                        break
                    handle.write(chunk)
                    have += len(chunk)
                    report(DownloadProgress(DownloadState.DOWNLOADING, have,
                                            pin.size_bytes))
    except (urllib.error.URLError, OSError) as exc:
        log.warning("Download of %s failed: %s", pin.filename, exc)
        # The partial file stays: the next attempt resumes from it.
        report(DownloadProgress(DownloadState.FAILED, have, pin.size_bytes,
                                message=str(exc)))
        return False

    report(DownloadProgress(DownloadState.VERIFYING, have, pin.size_bytes))
    actual_size = os.path.getsize(partial)
    if actual_size != pin.size_bytes:
        message = f"size mismatch: expected {pin.size_bytes}, got {actual_size}"
        log.error("%s (%s)", message, pin.filename)
        os.unlink(partial)
        report(DownloadProgress(DownloadState.FAILED, message=message))
        return False

    digest = _sha256(partial, cancel)
    if digest is None:
        report(DownloadProgress(DownloadState.CANCELLED))
        return False
    if digest != pin.sha256:
        message = f"checksum mismatch: expected {pin.sha256}, got {digest}"
        log.error("%s (%s)", message, pin.filename)
        # A file that hashes wrong is not a resume point either.
        os.unlink(partial)
        report(DownloadProgress(DownloadState.FAILED, message=message))
        return False

    os.replace(partial, target)
    log.info("Downloaded and verified %s (%d bytes)", pin.filename, pin.size_bytes)
    report(DownloadProgress(DownloadState.READY, pin.size_bytes, pin.size_bytes))
    return True


def _sha256(path: str, cancel: Optional[threading.Event]) -> Optional[str]:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            if cancel is not None and cancel.is_set():
                return None
            block = handle.read(1 << 20)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()
