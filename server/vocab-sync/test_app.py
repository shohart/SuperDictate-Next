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


def test_index_page():
    r = client.get("/")
    assert r.status_code == 200
    assert "SuperDictate" in r.text


def _hw(phrase, stamp, enabled=True, deleted=False):
    return {"phrase": phrase, "enabled": enabled, "deleted": deleted, "updated_at": stamp}


def test_hotwords_push_update_disable_delete():
    h = bearer(auth("hw@example.com").json()["token"])
    r = client.post("/v1/vocabulary", headers=h, json={"since": 0, "hotwords": [
        _hw("Дунималова Анаида", "2026-11-05T10:00:00Z")]})
    body = r.json()
    assert r.status_code == 200 and body["revision"] == 1 and body["entries"] == []
    assert [(e["phrase"], e["enabled"], e["deleted"], e["revision"]) for e in body["hotwords"]] == [
        ("Дунималова Анаида", True, False, 1)]
    # Disable (newer), case/whitespace variant maps to the same key.
    r = client.post("/v1/vocabulary", headers=h, json={"since": 1, "hotwords": [
        _hw("дунималова   АНАИДА", "2026-11-05T11:00:00Z", enabled=False)]})
    hw = r.json()["hotwords"]
    assert r.json()["revision"] == 2 and len(hw) == 1 and hw[0]["enabled"] is False and hw[0]["revision"] == 2
    # Re-enable then delete -> tombstone.
    client.post("/v1/vocabulary", headers=h, json={"since": 2, "hotwords": [
        _hw("Дунималова Анаида", "2026-11-05T12:00:00Z")]})
    r = client.post("/v1/vocabulary", headers=h, json={"since": 3, "hotwords": [
        _hw("Дунималова Анаида", "2026-11-05T13:00:00Z", deleted=True)]})
    hw = r.json()["hotwords"]
    assert r.json()["revision"] == 4 and len(hw) == 1 and hw[0]["deleted"] is True
    # Resurrection after the tombstone with a newer stamp works.
    r = client.post("/v1/vocabulary", headers=h, json={"since": 4, "hotwords": [
        _hw("Дунималова Анаида", "2026-11-05T14:00:00Z")]})
    assert r.json()["hotwords"][0]["deleted"] is False


def test_hotwords_pull_by_other_device_and_isolation():
    h = bearer(auth("hw2@example.com").json()["token"])
    client.post("/v1/vocabulary", headers=h, json={
        "changes": [{"source": "гитхаб", "replacement": "GitHub", "updated_at": "2026-11-05T10:00:00Z"}],
        "hotwords": [_hw("АС Москвы", "2026-11-05T10:00:00Z", enabled=False)]})
    other = bearer(auth("hw2@example.com").json()["token"])
    pulled = client.get("/v1/vocabulary?since=0", headers=other).json()
    assert pulled["revision"] == 2
    assert [e["source"] for e in pulled["entries"]] == ["гитхаб"]
    assert [(e["phrase"], e["enabled"]) for e in pulled["hotwords"]] == [("АС Москвы", False)]
    # Only changes above `since` come back.
    assert client.get("/v1/vocabulary?since=2", headers=other).json()["hotwords"] == []
    stranger = bearer(auth("hw3@example.com").json()["token"])
    assert client.get("/v1/vocabulary", headers=stranger).json()["hotwords"] == []


def test_hotwords_last_writer_wins():
    h = bearer(auth("hw4@example.com").json()["token"])
    client.post("/v1/vocabulary", headers=h, json={"hotwords": [_hw("Росреестр", "2026-11-05T10:00:00Z")]})
    # Older and equal stamps lose (a tie keeps the server copy).
    for stamp in ("2026-11-05T09:00:00Z", "2026-11-05T10:00:00Z"):
        r = client.post("/v1/vocabulary", headers=h, json={"since": 1, "hotwords": [
            _hw("росреестр", stamp, enabled=False)]})
        assert r.json()["revision"] == 1 and r.json()["hotwords"] == []
    r = client.post("/v1/vocabulary", headers=h, json={"since": 1, "hotwords": [
        _hw("росреестр", "2026-11-05T10:00:01Z", enabled=False)]})
    assert r.json()["revision"] == 2 and r.json()["hotwords"][0]["enabled"] is False
    # An older delete cannot kill a newer live phrase.
    r = client.post("/v1/vocabulary", headers=h, json={"since": 2, "hotwords": [
        _hw("Росреестр", "2026-11-05T08:00:00Z", deleted=True)]})
    assert r.json()["hotwords"] == []


def test_hotwords_share_revision_and_skip_events():
    h = bearer(auth("hw5@example.com").json()["token"])
    r = client.post("/v1/vocabulary", headers=h, json={
        "changes": [{"source": "ёж", "replacement": "Ёж", "updated_at": "2026-11-05T10:00:00Z"}],
        "hotwords": [_hw("Секретное слово", "2026-11-05T10:00:00Z")]})
    assert r.json()["revision"] == 2
    assert [e["revision"] for e in r.json()["entries"]] == [1]
    assert [e["revision"] for e in r.json()["hotwords"]] == [2]
    with service.db() as conn:
        assert conn.execute("SELECT COUNT(*) FROM events WHERE source = 'Секретное слово'"
                            " OR replacement = 'Секретное слово'").fetchone()[0] == 0


def test_hotwords_validation_and_cap(monkeypatch):
    h = bearer(auth("hw6@example.com").json()["token"])
    assert client.post("/v1/vocabulary", headers=h, json={"hotwords": [
        _hw("   ", "2026-11-05T10:00:00Z")]}).status_code == 422
    monkeypatch.setattr(service, "MAX_HOTWORD_ENTRIES", 2)
    r = client.post("/v1/vocabulary", headers=h, json={"hotwords": [
        _hw("раз", "2026-11-05T10:00:00Z"), _hw("два", "2026-11-05T10:00:00Z"),
        _hw("три", "2026-11-05T10:00:00Z")]})
    assert sorted(e["phrase"] for e in r.json()["hotwords"]) == ["два", "раз"]
    # Deleting frees a slot.
    r = client.post("/v1/vocabulary", headers=h, json={"since": 2, "hotwords": [
        _hw("раз", "2026-11-05T11:00:00Z", deleted=True), _hw("три", "2026-11-05T11:00:00Z")]})
    assert sorted((e["phrase"], e["deleted"]) for e in r.json()["hotwords"]) == [("раз", True), ("три", False)]


def test_old_client_without_hotwords_is_unaffected():
    h = bearer(auth("hw7@example.com").json()["token"])
    r = client.post("/v1/vocabulary", headers=h, json={"since": 0, "changes": [
        {"source": "докер", "replacement": "Docker", "updated_at": "2026-11-05T10:00:00Z"}]})
    assert r.status_code == 200 and r.json()["revision"] == 1 and r.json()["hotwords"] == []
    assert client.get("/v1/vocabulary", headers=h).json()["entries"][0]["replacement"] == "Docker"
