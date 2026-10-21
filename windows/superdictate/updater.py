"""Update checking against GitHub Releases.

macOS downloads the release ZIP, verifies its SHA-256, bundle ID, version
and signature, then replaces itself. That whole pipeline is built around
codesign and the ``.app`` layout, neither of which exists here, so the
Windows port stops one step earlier: it reports what is published and
opens the release page. Nothing is downloaded or executed automatically;
the macOS build also never installs without an explicit click.

Both platforms publish to the same repository, so Windows releases are
tagged ``windows-vX.Y.Z`` and published without GitHub's "latest" flag:
the macOS updater reads ``releases/latest`` and must never see one. This
module lists the releases and picks the newest Windows tag, never a macOS
one. If that release carries no installer the check says so plainly.
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

RELEASES_URL = "https://api.github.com/repos/shohart/SuperDictate-Next/releases?per_page=50"
RELEASES_PAGE = "https://github.com/shohart/SuperDictate-Next/releases"
#: Tag prefix of Windows releases; ``v0.7.0`` alone is a macOS release.
WINDOWS_TAG_PREFIX = "windows-v"
CHECK_INTERVAL_SECONDS = 6 * 3600
REQUEST_TIMEOUT = 15

# Only Windows releases get here (by tag), so any installer or archive is
# the right asset; requiring "win" in the name would reject
# "SuperDictate-0.7.0-setup.exe".
_WINDOWS_ASSET = re.compile(r"\.(exe|msi|zip)$", re.IGNORECASE)


@dataclass
class UpdateInfo:
    version: str
    page_url: str
    has_windows_asset: bool
    asset_url: Optional[str] = None
    is_newer: bool = False


def parse_version(raw: str) -> tuple[int, ...]:
    cleaned = raw.strip()
    if cleaned.lower().startswith(WINDOWS_TAG_PREFIX):
        cleaned = cleaned[len(WINDOWS_TAG_PREFIX):]
    cleaned = cleaned.lstrip("vV")
    parts: list[int] = []
    for chunk in re.split(r"[.\-+]", cleaned):
        if chunk.isdigit():
            parts.append(int(chunk))
        else:
            break
    return tuple(parts) or (0,)


def is_newer(candidate: str, current: str = VERSION) -> bool:
    return parse_version(candidate) > parse_version(current)


def newest_windows_release(releases: list) -> Optional[dict]:
    """The newest published ``windows-v*`` release in a releases listing."""
    candidates = [
        release for release in releases
        if isinstance(release, dict)
        and str(release.get("tag_name", "")).lower().startswith(WINDOWS_TAG_PREFIX)
        and not release.get("draft")
    ]
    if not candidates:
        return None
    return max(candidates, key=lambda release: parse_version(str(release["tag_name"])))


def check_latest(timeout: int = REQUEST_TIMEOUT) -> Optional[UpdateInfo]:
    request = urllib.request.Request(
        RELEASES_URL,
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

    release = newest_windows_release(payload if isinstance(payload, list) else [])
    if release is None:
        return None
    tag = str(release["tag_name"]).strip()

    windows_asset = None
    for asset in release.get("assets", []) or []:
        name = str(asset.get("name", ""))
        if _WINDOWS_ASSET.search(name):
            windows_asset = str(asset.get("browser_download_url", "")) or None
            break

    return UpdateInfo(
        version=".".join(str(part) for part in parse_version(tag)),
        page_url=str(release.get("html_url") or RELEASES_PAGE),
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
