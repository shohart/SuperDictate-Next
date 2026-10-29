# SuperDictate vocabulary sync

Small FastAPI + SQLite service that syncs the replacement dictionary between
a user's macOS and Windows installs. See the module docstring in `app.py`
for the account and sync model.

- API: `POST /v1/auth` (sign in; the first sign-in with a new e-mail creates
  the account), `DELETE /v1/auth`, `GET /v1/vocabulary?since=N`,
  `POST /v1/vocabulary`, `GET /healthz`.
- Every accepted change is appended to the `events` table (training data;
  the apps tell the user before sign-in).
- Deployed on octopusreborn at `/home/shohart/services/superdictate-sync`
  (`docker compose up -d --build`), published on `10.77.77.2:8095` only;
  Caddy vhost `superdictate.bykovlegal.ru` in
  `/home/shohart/nc-project/caddyfile.conf`.
- Backup: the single file `data/vocab-sync.sqlite` (WAL; use
  `sqlite3 data/vocab-sync.sqlite ".backup out.sqlite"`).
- Tests: `python -m pytest test_app.py` (needs fastapi, httpx, pytest).
