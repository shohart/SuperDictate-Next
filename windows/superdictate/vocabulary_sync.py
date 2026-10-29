"""Account sync of the vocabulary between the user's machines.

docs/specs/vocabulary-hygiene-and-sync-spec.md §4, the Windows client of
``server/vocab-sync``. One account (e-mail + password; the first sign-in
creates it) holds one dictionary; every machine signed in to it pushes its
local changes and pulls everyone else's.

* **Token.** Kept DPAPI-protected (CryptProtectData, current user) in
  ``VocabularySync.token`` next to the settings: ``keyring`` is not a
  dependency of this app, pywin32 is. The password is never stored.
* **HTTP.** ``urllib`` with the LLM endpoints' proxy policy
  (``llm.host._opener_for``): the system proxy for the internet server
  unless "Use the system proxy" is off; a loopback/LAN server always direct.
* **Pass.** Push every entry and tombstone stamped since the last pass (in
  batches of 1000), apply what the server returns above our revision, move
  the cursors. One pass at a time.
* **Triggers.** App start (when signed in), 5 s after a local change
  (debounced), every 15 minutes, and the "Sync now" button.
* **Failures.** A network error waits for the next trigger. A 401 drops the
  token: the settings ask the user to sign in again.

One deliberate difference from the spec's cursor: ``last pushed local
stamp`` is the local clock when the pass started, not the newest stamp
pushed. Entries applied from the server keep the *other* machine's
``updated_at``; with a clock ahead of ours that maximum would sit in our
future and hide every local edit made until our clock caught up.
"""

from __future__ import annotations

import json
import sys
import threading
import time
import unicodedata
import urllib.error
import urllib.request
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Callable, Optional

from . import paths
from .logging_setup import get as get_logger
from .version import VERSION

log = get_logger("vocabulary_sync")

TOKEN_FILE = paths.BASE_DIR / "VocabularySync.token"
DEBOUNCE_SECONDS = 5.0
PERIOD_SECONDS = 15 * 60.0
BATCH_SIZE = 1000
REQUEST_TIMEOUT_SECONDS = 30.0
#: The server refuses a whole push for one field over this (server/vocab-sync).
MAX_FIELD = 200
_DPAPI_ENTROPY = b"com.local.superdictate.vocab-sync"

# Error kinds, for the settings to word.
ERROR_NETWORK = "network"
ERROR_UNAUTHORIZED = "unauthorized"
ERROR_WRONG_PASSWORD = "wrong_password"
ERROR_RATE_LIMITED = "rate_limited"
ERROR_INVALID = "invalid"
ERROR_SERVER = "server"
ERROR_SIGNED_OUT = "signed_out"


class SyncError(Exception):
    def __init__(self, kind: str, message: str = "") -> None:
        super().__init__(message or kind)
        self.kind = kind


# -- token storage -----------------------------------------------------------

class MemoryTokenStore:
    """For tests."""

    def __init__(self) -> None:
        self._token: Optional[str] = None

    def load(self) -> Optional[str]:
        return self._token

    def save(self, token: str) -> None:
        self._token = token

    def clear(self) -> None:
        self._token = None


class DpapiTokenStore:
    """The token encrypted for the current Windows user (DPAPI).

    Outside Windows (a checkout on a Mac, for the pure tests) there is no
    DPAPI; the file then holds the token as is, which is fine for a
    development box and never happens in the shipped app.
    """

    def __init__(self, path: Path = TOKEN_FILE) -> None:
        self._path = Path(path)

    def load(self) -> Optional[str]:
        try:
            blob = self._path.read_bytes()
        except OSError:
            return None
        try:
            if sys.platform == "win32":
                import win32crypt

                _, data = win32crypt.CryptUnprotectData(blob, _DPAPI_ENTROPY, None, None, 0)
                blob = bytes(data)
            token = blob.decode("utf-8").strip()
        except Exception as exc:
            log.warning("The sync token could not be read (%s); signing in again is needed", exc)
            return None
        return token or None

    def save(self, token: str) -> None:
        data = token.encode("utf-8")
        if sys.platform == "win32":
            import win32crypt

            data = win32crypt.CryptProtectData(data, "SuperDictate vocabulary sync",
                                               _DPAPI_ENTROPY, None, None, 0)
        self._path.parent.mkdir(parents=True, exist_ok=True)
        temp = self._path.with_suffix(".tmp")
        temp.write_bytes(bytes(data))
        temp.replace(self._path)

    def clear(self) -> None:
        try:
            self._path.unlink()
        except FileNotFoundError:
            pass
        except OSError as exc:
            log.warning("Could not delete the sync token: %s", exc)


# -- status ------------------------------------------------------------------

STATE_SIGNED_OUT = "signed_out"
STATE_REAUTH = "reauth"          # was signed in; the server refused the token
STATE_IDLE = "idle"
STATE_SYNCING = "syncing"
STATE_OK = "ok"
STATE_ERROR = "error"


@dataclass(frozen=True)
class SyncStatus:
    state: str
    email: str = ""
    last_synced_at: float = 0.0
    error: str = ""

    @property
    def signed_in(self) -> bool:
        return self.state not in (STATE_SIGNED_OUT, STATE_REAUTH)


# -- helpers ---------------------------------------------------------------

def _timestamp() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _sendable(text: str) -> bool:
    """What the server's field check accepts (``_clean`` in app.py)."""
    text = unicodedata.normalize("NFC", text).strip()
    return bool(text) and len(text) <= MAX_FIELD and not any(
        unicodedata.category(ch) == "Cc" for ch in text)


def _change_from_record(record) -> dict:
    return {
        "source": record.source,
        "replacement": record.replacement,
        "origin": str(getattr(record.origin, "value", record.origin)),
        "asr_hint": record.asr_hint,
        "deleted": False,
        "updated_at": record.updated_at,
    }


def _change_from_tombstone(tombstone) -> dict:
    return {
        "source": tombstone.source,
        "replacement": "",
        "origin": "manual",
        "asr_hint": None,
        "deleted": True,
        "updated_at": tombstone.deleted_at,
    }


class VocabularySync:
    """The sync client. Blocking calls (``sign_in``, ``sign_out``,
    ``sync_now``) are for a worker thread; :meth:`start` runs the triggers
    on a thread of its own. ``on_status(SyncStatus)`` is called from
    whichever thread changed it."""

    def __init__(self, store, settings, *, tokens=None,
                 on_status: Optional[Callable[[SyncStatus], None]] = None,
                 platform: str = "windows", version: str = VERSION) -> None:
        self._store = store
        self._settings = settings
        self._tokens = tokens if tokens is not None else DpapiTokenStore()
        self._on_status = on_status
        self._client = {"platform": platform, "version": version}
        self._pass_lock = threading.Lock()
        self._wake = threading.Event()
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._due: Optional[float] = None
        self._due_lock = threading.Lock()
        self._status = self._initial_status()
        store.add_listener(self._on_store_change)

    # -- status ----------------------------------------------------------

    def _initial_status(self) -> SyncStatus:
        email = self._settings.vocabulary_sync_email
        synced = self._settings.vocabulary_sync_last_synced_at
        if not self._settings.vocabulary_sync_enabled:
            return SyncStatus(STATE_SIGNED_OUT, email, synced)
        if not self._tokens.load():
            return SyncStatus(STATE_REAUTH, email, synced)
        return SyncStatus(STATE_IDLE, email, synced)

    @property
    def status(self) -> SyncStatus:
        return self._status

    @property
    def signed_in(self) -> bool:
        return self._settings.vocabulary_sync_enabled and bool(self._tokens.load())

    def _set_status(self, status: SyncStatus) -> None:
        self._status = status
        if self._on_status is not None:
            try:
                self._on_status(status)
            except Exception as exc:
                log.debug("Sync status callback failed: %s", exc)

    # -- HTTP --------------------------------------------------------------

    def _request(self, method: str, path: str, body: Optional[dict] = None,
                 token: Optional[str] = None) -> dict:
        from .llm.host import _opener_for

        url = self._settings.vocabulary_sync_server_url.rstrip("/") + path
        data = json.dumps(body, ensure_ascii=False).encode("utf-8") if body is not None else None
        request = urllib.request.Request(url, data=data, method=method, headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": f"SuperDictate/{VERSION} (Windows)",
        })
        if token:
            request.add_header("Authorization", f"Bearer {token}")
        opener = _opener_for(url, self._settings.llm_use_system_proxy)
        try:
            with opener.open(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
                raw = response.read()
        except urllib.error.HTTPError as exc:
            detail = ""
            try:
                detail = str(json.loads(exc.read() or b"{}").get("detail", ""))
            except Exception:
                pass
            if exc.code == 401:
                raise SyncError(ERROR_UNAUTHORIZED, detail) from exc
            if exc.code == 429:
                raise SyncError(ERROR_RATE_LIMITED, detail) from exc
            if exc.code == 422:
                raise SyncError(ERROR_INVALID, detail) from exc
            raise SyncError(ERROR_SERVER, f"HTTP {exc.code} {detail}".strip()) from exc
        except (urllib.error.URLError, OSError, TimeoutError) as exc:
            raise SyncError(ERROR_NETWORK, str(getattr(exc, "reason", exc))) from exc
        if not raw:
            return {}
        try:
            decoded = json.loads(raw)
        except ValueError as exc:
            raise SyncError(ERROR_SERVER, "the response is not JSON") from exc
        if not isinstance(decoded, dict):
            raise SyncError(ERROR_SERVER, "the response is not a JSON object")
        return decoded

    # -- account -----------------------------------------------------------

    def sign_in(self, email: str, password: str) -> bool:
        """Sign in (creating the account for a new e-mail) and run the first,
        full sync. Returns whether the account was created. Raises
        :class:`SyncError`; a failed first sync leaves the user signed in."""
        email = email.strip()
        try:
            response = self._request("POST", "/v1/auth", {
                "email": email, "password": password, "client": self._client})
        except SyncError as exc:
            if exc.kind == ERROR_UNAUTHORIZED:
                raise SyncError(ERROR_WRONG_PASSWORD, str(exc)) from exc
            raise
        token = str(response.get("token") or "")
        if not token:
            raise SyncError(ERROR_SERVER, "no token in the response")
        self._tokens.save(token)
        account = str(response.get("email") or email)
        # A new device, or another account: merge everything, both ways.
        self._settings.update_runtime({
            "vocabulary_sync_enabled": True,
            "vocabulary_sync_email": account,
            "vocabulary_sync_last_server_revision": 0,
            "vocabulary_sync_last_pushed_local_stamp": "",
        })
        created = bool(response.get("created"))
        log.info("Vocabulary sync: signed in as %s%s", account, " (new account)" if created else "")
        self._set_status(SyncStatus(STATE_IDLE, account, self._settings.vocabulary_sync_last_synced_at))
        try:
            self.sync_now()
        except SyncError as exc:
            log.warning("Vocabulary sync: the first sync failed: %s", exc)
        return created

    def sign_out(self) -> None:
        """Revoke the token (best effort) and forget the account state."""
        token = self._tokens.load()
        if token:
            try:
                self._request("DELETE", "/v1/auth", token=token)
            except SyncError as exc:
                log.info("Vocabulary sync: sign-out request failed (%s); token dropped anyway", exc)
        self._tokens.clear()
        self._settings.update_runtime({
            "vocabulary_sync_enabled": False,
            "vocabulary_sync_last_server_revision": 0,
            "vocabulary_sync_last_pushed_local_stamp": "",
            "vocabulary_sync_last_synced_at": 0.0,
        })
        log.info("Vocabulary sync: signed out")
        self._set_status(SyncStatus(STATE_SIGNED_OUT, self._settings.vocabulary_sync_email))

    def _drop_token(self) -> None:
        self._tokens.clear()
        log.warning("Vocabulary sync: the server refused the token; sign in again")
        self._set_status(SyncStatus(STATE_REAUTH, self._settings.vocabulary_sync_email,
                                    self._settings.vocabulary_sync_last_synced_at,
                                    ERROR_UNAUTHORIZED))

    # -- the pass ------------------------------------------------------------

    def sync_now(self) -> int:
        """One full pass (§4.2). Returns how many remote changes were applied."""
        with self._pass_lock:
            token = self._tokens.load()
            if not self._settings.vocabulary_sync_enabled or not token:
                raise SyncError(ERROR_SIGNED_OUT)
            email = self._settings.vocabulary_sync_email
            self._set_status(replace(self._status, state=STATE_SYNCING, email=email, error=""))
            try:
                applied, pushed = self._pass(token)
            except SyncError as exc:
                if exc.kind == ERROR_UNAUTHORIZED:
                    self._drop_token()
                else:
                    log.warning("Vocabulary sync failed (%s): %s", exc.kind, exc)
                    self._set_status(SyncStatus(STATE_ERROR, email,
                                                self._settings.vocabulary_sync_last_synced_at,
                                                exc.kind))
                raise
            synced = time.time()
            self._settings.update_runtime({"vocabulary_sync_last_synced_at": synced})
            if applied or pushed:
                log.info("Vocabulary sync: %d pushed, %d applied from the server", pushed, applied)
            self._set_status(SyncStatus(STATE_OK, email, synced))
            return applied

    def _pass(self, token: str) -> tuple[int, int]:
        since = self._settings.vocabulary_sync_last_server_revision
        stamp = self._settings.vocabulary_sync_last_pushed_local_stamp
        started = _timestamp()
        records, tombstones = self._store.local_changes_since(stamp)
        changes = []
        for record in records:
            if _sendable(record.source) and _sendable(record.replacement):
                changes.append(_change_from_record(record))
            else:
                log.info("Vocabulary sync: %r is too long or malformed for the server; kept local",
                         record.source[:40])
        changes += [_change_from_tombstone(t) for t in tombstones if _sendable(t.source)]

        batches = [changes[i:i + BATCH_SIZE] for i in range(0, len(changes), BATCH_SIZE)] or [[]]
        applied = 0
        for batch in batches:
            response = self._request("POST", "/v1/vocabulary", {
                "since": since, "changes": batch, "client": self._client}, token=token)
            entries = response.get("entries")
            applied += self._store.apply_remote(entries if isinstance(entries, list) else [])
            try:
                since = max(since, int(response.get("revision", since)))
            except (TypeError, ValueError):
                raise SyncError(ERROR_SERVER, "bad revision in the response")
            self._settings.update_runtime({"vocabulary_sync_last_server_revision": since})
        self._settings.update_runtime({"vocabulary_sync_last_pushed_local_stamp": started})
        return applied, len(changes)

    # -- triggers ------------------------------------------------------------

    def _on_store_change(self, kind: str) -> None:
        if kind == "local" and self._thread is not None:
            self.request_sync(DEBOUNCE_SECONDS)

    def request_sync(self, delay: float = 0.0) -> None:
        """Run a pass after ``delay`` seconds; a later request resets the
        wait (the debounce)."""
        with self._due_lock:
            self._due = time.monotonic() + max(0.0, delay)
        self._wake.set()

    def start(self) -> None:
        if self._thread is not None:
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, name="vocabulary-sync", daemon=True)
        self._thread.start()
        if self.signed_in:
            self.request_sync(0.0)

    def stop(self) -> None:
        self._stop.set()
        self._wake.set()
        thread, self._thread = self._thread, None
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout=REQUEST_TIMEOUT_SECONDS + 2)

    def _run(self) -> None:
        next_periodic = time.monotonic() + PERIOD_SECONDS
        while not self._stop.is_set():
            with self._due_lock:
                due = self._due
            now = time.monotonic()
            wake_at = next_periodic if due is None else min(due, next_periodic)
            if wake_at > now:
                self._wake.wait(wake_at - now)
                self._wake.clear()
                continue
            with self._due_lock:
                self._due = None
            next_periodic = time.monotonic() + PERIOD_SECONDS
            if not self.signed_in:
                continue
            try:
                self.sync_now()
            except SyncError:
                pass  # reported through the status; retried on the next trigger
            except Exception:
                log.exception("Vocabulary sync pass crashed")
