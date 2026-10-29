"""Tests for the vocabulary sync service: python -m pytest test_app.py"""
import os
import tempfile

os.environ["VOCAB_SYNC_DB"] = os.path.join(tempfile.mkdtemp(), "t.sqlite")

from fastapi.testclient import TestClient  # noqa: E402

import app as service  # noqa: E402

service.init_db()
client = TestClient(service.app)


def auth(email="a@example.com", password="secret-pass"):
    return client.post("/v1/auth", json={"email": email, "password": password,
                                         "client": {"platform": "test", "version": "0"}})


def bearer(token):
    return {"Authorization": f"Bearer {token}"}


def test_first_sign_in_registers_then_requires_password():
    r = auth("new@example.com")
    assert r.status_code == 200 and r.json()["created"] is True
    r = auth("NEW@example.com")
    assert r.status_code == 200 and r.json()["created"] is False
    assert auth("new@example.com", "wrong-password").status_code == 401


def test_validation():
    assert auth("not-an-email").status_code == 422
    assert auth("x@example.com", "short").status_code == 422


def test_push_pull_last_writer_wins_and_tombstones():
    token = auth("sync@example.com").json()["token"]
    h = bearer(token)
    r = client.post("/v1/vocabulary", headers=h, json={"since": 0, "changes": [
        {"source": "гитхаб", "replacement": "GitHub", "origin": "manual", "updated_at": "2026-10-29T10:00:00Z"},
        {"source": "Эс эйч", "replacement": "ssh", "origin": "learned", "asr_hint": True,
         "updated_at": "2026-10-29T10:00:00Z"}]})
    assert r.status_code == 200
    body = r.json()
    assert body["revision"] == 2 and len(body["entries"]) == 2
    # Older change loses; case-variant source maps to the same key.
    r = client.post("/v1/vocabulary", headers=h, json={"since": 2, "changes": [
        {"source": "ГИТХАБ", "replacement": "Github", "updated_at": "2026-10-28T00:00:00Z"}]})
    assert r.json()["revision"] == 2 and r.json()["entries"] == []
    # Newer delete wins and travels as a tombstone.
    r = client.post("/v1/vocabulary", headers=h, json={"since": 2, "changes": [
        {"source": "гитхаб", "deleted": True, "updated_at": "2026-10-29T11:00:00Z"}]})
    entries = r.json()["entries"]
    assert len(entries) == 1 and entries[0]["deleted"] is True and entries[0]["revision"] == 3
    # Another device pulls everything.
    other = bearer(auth("sync@example.com").json()["token"])
    pulled = client.get("/v1/vocabulary?since=0", headers=other).json()
    assert pulled["revision"] == 3
    assert {(e["source"], e["deleted"]) for e in pulled["entries"]} == {("гитхаб", True), ("Эс эйч", False)}


def test_accounts_are_isolated_and_token_required():
    h1 = bearer(auth("one@example.com").json()["token"])
    h2 = bearer(auth("two@example.com").json()["token"])
    client.post("/v1/vocabulary", headers=h1, json={"changes": [
        {"source": "докер", "replacement": "Docker", "updated_at": "2026-10-29T10:00:00Z"}]})
    assert client.get("/v1/vocabulary", headers=h2).json()["entries"] == []
    assert client.get("/v1/vocabulary").status_code == 401
    assert client.get("/v1/vocabulary", headers=bearer("nope")).status_code == 401


def test_sign_out_revokes_token():
    token = auth("out@example.com").json()["token"]
    assert client.delete("/v1/auth", headers=bearer(token)).status_code == 204
    assert client.get("/v1/vocabulary", headers=bearer(token)).status_code == 401


def test_rate_limit():
    with service.db() as conn:
        conn.execute("DELETE FROM auth_failures")
    auth("rl@example.com")
    for _ in range(service.AUTH_FAIL_LIMIT):
        assert auth("rl@example.com", "wrong-password").status_code == 401
    assert auth("rl@example.com").status_code == 429
    # Other addresses from the same IP still get in.
    assert auth("rl-other@example.com").status_code == 200


def test_events_log_every_accepted_change():
    h = bearer(auth("ev@example.com").json()["token"])
    client.post("/v1/vocabulary", headers=h, json={"changes": [
        {"source": "клод", "replacement": "Claude", "updated_at": "2026-10-29T10:00:00Z"}]})
    with service.db() as conn:
        rows = conn.execute("SELECT source, replacement, platform FROM events WHERE source = 'клод'").fetchall()
    assert [tuple(r) for r in rows] == [("клод", "Claude", "")]
