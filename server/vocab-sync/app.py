"""SuperDictate Next vocabulary sync service.

A deliberately small HTTP service that keeps one replacement dictionary per
account in sync between the user's machines (macOS and Windows).

Accounts: an e-mail address and a password. The first sign-in with an
unknown address creates the account; later sign-ins must match the
password. A successful sign-in returns a bearer token the app keeps in the
system keychain / credential store.

Sync model: one row per (account, key), where the key is the normalized
source (Unicode case-folded, whitespace collapsed) — the same rule both
apps use for dedup. Last writer wins on the client-supplied `updated_at`;
deletions travel as tombstones. Every account has a monotonically growing
revision; a client pulls everything above the revision it last saw.

Every accepted change is also appended to `events`, an append-only log kept
to improve the speech model later (the apps say so before the user signs
in).

Storage: one SQLite file (WAL). Runs behind Caddy, which terminates TLS.
"""

from __future__ import annotations

import hashlib
import hmac
import os
import re
import secrets
import sqlite3
import threading
import time
import unicodedata
from contextlib import asynccontextmanager, contextmanager
from typing import Iterator, List, Optional

from fastapi import Depends, FastAPI, Header, HTTPException, Request, Response
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field

DB_PATH = os.environ.get("VOCAB_SYNC_DB", "/data/vocab-sync.sqlite")
MAX_ENTRIES = int(os.environ.get("VOCAB_SYNC_MAX_ENTRIES", "5000"))
MAX_CHANGES_PER_PUSH = 1000
MAX_FIELD = 200
MIN_PASSWORD = 8
# Failed sign-ins tolerated per address and per client IP inside the window.
AUTH_FAIL_LIMIT = 10
AUTH_FAIL_LIMIT_IP = 50
AUTH_FAIL_WINDOW = 15 * 60
SCRYPT = dict(n=2**14, r=8, p=1, dklen=32)
EMAIL_RE = re.compile(r"^[^@\s]{1,64}@[^@\s]{1,255}\.[^@\s]{2,63}$")

@asynccontextmanager
async def _lifespan(_app):
    init_db()
    yield


app = FastAPI(title="SuperDictate vocabulary sync", docs_url=None, redoc_url=None, openapi_url=None,
              lifespan=_lifespan)
_write_lock = threading.Lock()


# --- storage -----------------------------------------------------------------

SCHEMA = """
CREATE TABLE IF NOT EXISTS accounts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    email TEXT NOT NULL UNIQUE,
    salt BLOB NOT NULL,
    password_hash BLOB NOT NULL,
    revision INTEGER NOT NULL DEFAULT 0,
    created_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS tokens (
    token_hash BLOB PRIMARY KEY,
    account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    platform TEXT,
    app_version TEXT,
    created_at REAL NOT NULL,
    last_used_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS entries (
    account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    key TEXT NOT NULL,
    source TEXT NOT NULL,
    replacement TEXT NOT NULL,
    origin TEXT NOT NULL,
    asr_hint INTEGER,
    deleted INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL,
    revision INTEGER NOT NULL,
    PRIMARY KEY (account_id, key)
);
CREATE INDEX IF NOT EXISTS idx_entries_revision ON entries (account_id, revision);
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id INTEGER NOT NULL,
    received_at REAL NOT NULL,
    platform TEXT,
    app_version TEXT,
    source TEXT NOT NULL,
    replacement TEXT NOT NULL,
    origin TEXT NOT NULL,
    asr_hint INTEGER,
    deleted INTEGER NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS auth_failures (
    subject TEXT NOT NULL,
    at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_auth_failures ON auth_failures (subject, at);
"""


def _connect() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH, timeout=30, isolation_level=None)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute("PRAGMA busy_timeout=30000")
    return conn


def init_db() -> None:
    directory = os.path.dirname(DB_PATH)
    if directory:
        os.makedirs(directory, exist_ok=True)
    with _connect() as conn:
        conn.executescript(SCHEMA)


@contextmanager
def db() -> Iterator[sqlite3.Connection]:
    conn = _connect()
    try:
        yield conn
    finally:
        conn.close()


@contextmanager
def write_tx() -> Iterator[sqlite3.Connection]:
    # One writer at a time: SQLite serializes writers anyway, and taking the
    # lock first keeps revision numbering free of races.
    with _write_lock, db() as conn:
        conn.execute("BEGIN IMMEDIATE")
        try:
            yield conn
            conn.execute("COMMIT")
        except BaseException:
            conn.execute("ROLLBACK")
            raise


# --- helpers -----------------------------------------------------------------

def normalized_key(source: str) -> str:
    """Same dedup rule as the apps: case-folded, whitespace collapsed."""
    return " ".join(unicodedata.normalize("NFC", source).casefold().split())


def _hash_password(password: str, salt: bytes) -> bytes:
    return hashlib.scrypt(password.encode("utf-8"), salt=salt, **SCRYPT)


def _token_hash(token: str) -> bytes:
    return hashlib.sha256(token.encode("ascii", "ignore")).digest()


def _client_ip(request: Request) -> str:
    # Caddy sets X-Forwarded-For; the service itself is reachable only
    # through it (published on the host's loopback / private link).
    forwarded = request.headers.get("x-forwarded-for", "")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.client.host if request.client else "?"


def _clean(text: str, field: str) -> str:
    text = unicodedata.normalize("NFC", text).strip()
    if not text or len(text) > MAX_FIELD or any(unicodedata.category(c) == "Cc" for c in text):
        raise HTTPException(422, f"invalid {field}")
    return text


# --- models ------------------------------------------------------------------

class ClientInfo(BaseModel):
    platform: str = Field("", max_length=32)
    version: str = Field("", max_length=32)


class AuthRequest(BaseModel):
    email: str = Field(..., max_length=320)
    password: str = Field(..., max_length=256)
    client: ClientInfo = ClientInfo()


class AuthResponse(BaseModel):
    token: str
    created: bool
    email: str


class Entry(BaseModel):
    source: str = Field(..., max_length=MAX_FIELD * 2)
    replacement: str = Field("", max_length=MAX_FIELD * 2)
    origin: str = Field("manual", max_length=16)
    asr_hint: Optional[bool] = None
    deleted: bool = False
    updated_at: str = Field(..., max_length=40)


class RemoteEntry(Entry):
    revision: int


class PushRequest(BaseModel):
    since: int = 0
    changes: List[Entry] = Field(default_factory=list, max_length=MAX_CHANGES_PER_PUSH)
    client: ClientInfo = ClientInfo()


class SyncResponse(BaseModel):
    revision: int
    entries: List[RemoteEntry]


# --- auth --------------------------------------------------------------------

def _too_many_failures(conn: sqlite3.Connection, subjects: List[str]) -> bool:
    cutoff = time.time() - AUTH_FAIL_WINDOW
    conn.execute("DELETE FROM auth_failures WHERE at < ?", (cutoff,))
    for subject in subjects:
        count = conn.execute("SELECT COUNT(*) FROM auth_failures WHERE subject = ? AND at >= ?",
                             (subject, cutoff)).fetchone()[0]
        if count >= (AUTH_FAIL_LIMIT_IP if subject.startswith("ip:") else AUTH_FAIL_LIMIT):
            return True
    return False


@app.post("/v1/auth", response_model=AuthResponse)
def sign_in(body: AuthRequest, request: Request) -> AuthResponse:
    email = unicodedata.normalize("NFC", body.email).strip().lower()
    if not EMAIL_RE.match(email):
        raise HTTPException(422, "invalid email")
    if len(body.password) < MIN_PASSWORD:
        raise HTTPException(422, f"password must be at least {MIN_PASSWORD} characters")
    subjects = ["email:" + email, "ip:" + _client_ip(request)]
    with write_tx() as conn:
        if _too_many_failures(conn, subjects):
            raise HTTPException(429, "too many failed sign-ins, try again later")
        row = conn.execute("SELECT id, salt, password_hash FROM accounts WHERE email = ?", (email,)).fetchone()
        created = False
        if row is None:
            salt = secrets.token_bytes(16)
            cur = conn.execute(
                "INSERT INTO accounts (email, salt, password_hash, created_at) VALUES (?, ?, ?, ?)",
                (email, salt, _hash_password(body.password, salt), time.time()))
            account_id = cur.lastrowid
            created = True
        else:
            if not hmac.compare_digest(_hash_password(body.password, row["salt"]), row["password_hash"]):
                now = time.time()
                conn.executemany("INSERT INTO auth_failures (subject, at) VALUES (?, ?)",
                                 [(s, now) for s in subjects])
                # Commit the failure even though we answer with an error.
                conn.execute("COMMIT")
                conn.execute("BEGIN IMMEDIATE")
                raise HTTPException(401, "wrong password")
            account_id = row["id"]
        token = secrets.token_urlsafe(32)
        now = time.time()
        conn.execute(
            "INSERT INTO tokens (token_hash, account_id, platform, app_version, created_at, last_used_at)"
            " VALUES (?, ?, ?, ?, ?, ?)",
            (_token_hash(token), account_id, body.client.platform, body.client.version, now, now))
    return AuthResponse(token=token, created=created, email=email)


def current_account(authorization: str = Header("")) -> int:
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or not token:
        raise HTTPException(401, "missing token")
    with db() as conn:
        row = conn.execute("SELECT account_id FROM tokens WHERE token_hash = ?", (_token_hash(token),)).fetchone()
        if row is None:
            raise HTTPException(401, "invalid token")
        conn.execute("UPDATE tokens SET last_used_at = ? WHERE token_hash = ?", (time.time(), _token_hash(token)))
        return int(row["account_id"])


@app.delete("/v1/auth", status_code=204, response_class=Response)
def sign_out(authorization: str = Header("")) -> Response:
    _, _, token = authorization.partition(" ")
    with write_tx() as conn:
        conn.execute("DELETE FROM tokens WHERE token_hash = ?", (_token_hash(token),))
    return Response(status_code=204)


# --- sync --------------------------------------------------------------------

def _changes_since(conn: sqlite3.Connection, account_id: int, since: int) -> SyncResponse:
    revision = conn.execute("SELECT revision FROM accounts WHERE id = ?", (account_id,)).fetchone()[0]
    rows = conn.execute(
        "SELECT source, replacement, origin, asr_hint, deleted, updated_at, revision FROM entries"
        " WHERE account_id = ? AND revision > ? ORDER BY revision", (account_id, since)).fetchall()
    entries = [RemoteEntry(source=r["source"], replacement=r["replacement"], origin=r["origin"],
                           asr_hint=None if r["asr_hint"] is None else bool(r["asr_hint"]),
                           deleted=bool(r["deleted"]), updated_at=r["updated_at"], revision=r["revision"])
               for r in rows]
    return SyncResponse(revision=revision, entries=entries)


@app.get("/v1/vocabulary", response_model=SyncResponse)
def pull(since: int = 0, account_id: int = Depends(current_account)) -> SyncResponse:
    with db() as conn:
        return _changes_since(conn, account_id, max(0, since))


@app.post("/v1/vocabulary", response_model=SyncResponse)
def push(body: PushRequest, account_id: int = Depends(current_account)) -> SyncResponse:
    with write_tx() as conn:
        revision = conn.execute("SELECT revision FROM accounts WHERE id = ?", (account_id,)).fetchone()[0]
        live = conn.execute("SELECT COUNT(*) FROM entries WHERE account_id = ? AND deleted = 0",
                            (account_id,)).fetchone()[0]
        now = time.time()
        for change in body.changes:
            source = _clean(change.source, "source")
            replacement = "" if change.deleted else _clean(change.replacement, "replacement")
            origin = change.origin if change.origin in ("manual", "learned") else "manual"
            key = normalized_key(source)
            existing = conn.execute("SELECT updated_at, deleted FROM entries WHERE account_id = ? AND key = ?",
                                    (account_id, key)).fetchone()
            # Last writer wins; ties go to the server copy (idempotent re-push).
            if existing is not None and existing["updated_at"] >= change.updated_at:
                continue
            if not change.deleted and (existing is None or existing["deleted"]):
                if live >= MAX_ENTRIES:
                    continue
                live += 1
            elif change.deleted and existing is not None and not existing["deleted"]:
                live -= 1
            revision += 1
            hint = None if change.asr_hint is None else int(change.asr_hint)
            conn.execute(
                "INSERT INTO entries (account_id, key, source, replacement, origin, asr_hint, deleted, updated_at,"
                " revision) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
                " ON CONFLICT (account_id, key) DO UPDATE SET source = excluded.source,"
                " replacement = excluded.replacement, origin = excluded.origin, asr_hint = excluded.asr_hint,"
                " deleted = excluded.deleted, updated_at = excluded.updated_at, revision = excluded.revision",
                (account_id, key, source, replacement, origin, hint, int(change.deleted), change.updated_at,
                 revision))
            conn.execute(
                "INSERT INTO events (account_id, received_at, platform, app_version, source, replacement, origin,"
                " asr_hint, deleted, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (account_id, now, body.client.platform, body.client.version, source, replacement, origin, hint,
                 int(change.deleted), change.updated_at))
        conn.execute("UPDATE accounts SET revision = ? WHERE id = ?", (revision, account_id))
        return _changes_since(conn, account_id, max(0, body.since))


_INDEX_HTML = """<!doctype html>
<html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SuperDictate Next — синхронизация словаря</title>
<style>body{font:16px/1.5 -apple-system,system-ui,sans-serif;max-width:36rem;margin:3rem auto;padding:0 1rem;color:#222}
@media (prefers-color-scheme:dark){body{background:#1c1c1e;color:#eee}}</style></head>
<body><h1>SuperDictate Next</h1>
<p>Сервер синхронизации словаря работает. Веб-интерфейса нет: войдите в приложении,
в настройках словаря → «Синхронизация словаря».</p>
<p lang="en">Vocabulary sync server. Sign in from the SuperDictate Next app.</p>
</body></html>"""


@app.get("/", response_class=HTMLResponse, include_in_schema=False)
def index() -> str:
    return _INDEX_HTML


@app.get("/healthz")
def health() -> dict:
    with db() as conn:
        conn.execute("SELECT 1")
    return {"ok": True}
