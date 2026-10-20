"""Update checking against GitHub Releases.

macOS downloads the release ZIP, verifies its SHA-256, bundle ID, version
and signature, then replaces itself. That whole pipeline is built around
codesign and the ``.app`` layout, neither of which exists here, so the
Windows port stops one step earlier: it reports what is published and
opens the release page. Nothing is downloaded or executed automatically;
the macOS build also never installs without an explicit click.

If the upstream release carries no Windows asset the check says so
plainly rather than offering a macOS ZIP the user cannot run.
"""

from __future__ import annotations

import json
import re
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Optional

from .logging_setup import get as get_logger
from .version import VERSION

log = get_logger("updater")

LATEST_RELEASE_URL = "https://api.github.com/repos/shohart/SuperDictate-Next/releases/latest"
RELEASES_PAGE = "https://github.com/shohart/SuperDictate-Next/releases/latest"
CHECK_INTERVAL_SECONDS = 6 * 3600
REQUEST_TIMEOUT = 15

# The releases this checks are Windows-only, so any installer or archive
# is the right asset; requiring "win" in the name would reject
# "SuperDictate-0.6.0-setup.exe".
_WINDOWS_ASSET = re.compile(r"\.(exe|msi|zip)$", re.IGNORECASE)


@dataclass
class UpdateInfo:
    version: str
    page_url: str
    has_windows_asset: bool
    asset_url: Optional[str] = None
    is_newer: bool = False


def parse_version(raw: str) -> tuple[int, ...]:
    cleaned = raw.strip().lstrip("vV")
    parts: list[int] = []
    for chunk in re.split(r"[.\-+]", cleaned):
        if chunk.isdigit():
            parts.append(int(chunk))
        else:
            break
    return tuple(parts) or (0,)


def is_newer(candidate: str, current: str = VERSION) -> bool:
    return parse_version(candidate) > parse_version(current)


def check_latest(timeout: int = REQUEST_TIMEOUT) -> Optional[UpdateInfo]:
    request = urllib.request.Request(
        LATEST_RELEASE_URL,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": f"SuperDictate-Windows/{VERSION}",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, ValueError, OSError) as exc:
        log.warning("Update check failed: %s", exc)
        return None

    tag = str(payload.get("tag_name") or payload.get("name") or "").strip()
    if not tag:
        return None

    windows_asset = None
    for asset in payload.get("assets", []) or []:
        name = str(asset.get("name", ""))
        if _WINDOWS_ASSET.search(name):
            windows_asset = str(asset.get("browser_download_url", "")) or None
            break

    return UpdateInfo(
        version=tag.lstrip("vV"),
        page_url=str(payload.get("html_url") or RELEASES_PAGE),
        has_windows_asset=windows_asset is not None,
        asset_url=windows_asset,
        is_newer=is_newer(tag),
    )


class PeriodicChecker:
    """Checks at most once per interval, on demand."""

    def __init__(self) -> None:
        self._last_check = 0.0
        self._last_result: Optional[UpdateInfo] = None

    def maybe_check(self, force: bool = False) -> Optional[UpdateInfo]:
        now = time.monotonic()
        if not force and now - self._last_check < CHECK_INTERVAL_SECONDS:
            return self._last_result
        self._last_check = now
        self._last_result = check_latest()
        return self._last_result
