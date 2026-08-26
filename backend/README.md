# Transvolt E&M Maintenance — Backend

FastAPI + PostgreSQL backend implementing the E&M Maintenance API Contract v1.
Base URL: `/api/v1`. Interactive docs: `/api/v1/docs`.

## Quick start

**Local development** (separate env file — preferred):

```bash
cp .env.dev.example .env.dev   # once; edit JWT_SECRET if you like
docker compose --env-file .env.dev up -d --build
curl localhost:8123/api/v1/health
# Web UI: http://localhost:8089  (WEB_PORT in .env.dev)
```

**Alternative** — copy into the default compose env file:

```bash
cp .env.dev.example .env       # or: cp .env.example .env
docker compose up --build -d
```

`.env.example` is the documented general template (includes public-host notes).
`.env.dev` / `.env.dev.example` are local-only defaults (`ENVIRONMENT=development`,
ports `8123` / `8089` / `5433`, `SEED_ON_START=false`). Do not commit `.env` or `.env.dev`.

Bootstrap manager (from the seed): **`TV4021` / `Transvolt@123`** — change it before
anything reaches a real depot. Override with `BOOTSTRAP_USER_ID` / `BOOTSTRAP_PASSWORD`.

Port 8000 busy? Local `.env.dev` already maps API to `8123`. Override with
`API_PORT` / `PUBLIC_BASE_URL` in the env file you pass to compose.

### Local dev + tests

```bash
make venv                     # python3.11 venv + dev deps
docker compose up -d db
make test                     # drops/creates enm_test, runs pytest (44 tests)
make lint
```

Tests run against real Postgres — the schema uses native enums and a `pg_trgm` GIN
index, neither of which SQLite can emulate honestly.

## Architecture

```
app/
  main.py              create_app, CORS, /media mount, APScheduler lifespan
  config.py            pydantic-settings, env-driven
  db.py                async engine + per-request session dependency
  deps.py              auth guards, depot scoping, pagination
  errors.py            AppError -> { "error": { code, message, fields } }
  security.py          bcrypt, access JWT, opaque refresh tokens
  models/              SQLAlchemy 2.0 ORM (see schema below)
  schemas/             Pydantic v2 — per-register data schemas live here
  services/            entries, masters, notifications, fcm, sso, storage, audit
  api/                 auth, master, entries, admin, notifications, health
alembic/versions/      0001_initial_schema.py (hand-written, verified drift-free)
scripts/               entrypoint.sh (wait -> migrate -> seed), seed.py
```

### Data model — fully relational, no JSONB

The contract's unified `data` object is a UI convenience, not a storage strategy.
Each register gets its own table with real columns, real types, and real FKs:

```
entries (header)                 id, register, depot_code, bus_id, entry_date,
                                 entry_time, status, photo_url, photo_key,
                                 search_text, created_by_id, created_at, updated_at
  ├── work_done_entries          shift, reported_defects, defect_source_id,
  │                              defect_type_id, attended_details, spare_parts_used, employee
  ├── coolant_entries            bcs_litres NUMERIC(8,2), tcs_litres, topped_by
  ├── driver_complaint_entries   defect_type_id, complaint, rectification_action, mechanic
  ├── breakdown_entries          driver_id, location, complaint, breakdown_time,
  │                              mechanic_reported_time, attended_time, loss_km,
  │                              attended_details, remarks, resolved_at,
  │                              resolved_by_id, sla_notified_at
  └── pm_schedule_entries        defect_type_id, defects_noticed, action_taken,
                                 balance_job_reason, spare_parts_used, employees
```

Two deliberate denormalizations on the header:

- **`bus_id`** — every register requires a bus, so hoisting it avoids a five-way
  LEFT JOIN for bus filtering, the CSV export, and the registers list.
- **`search_text`** — the `q` param searches "across data fields + created_by name".
  A lowercased haystack is rebuilt on every write and indexed with
  `GIN (search_text gin_trgm_ops)`. Without it, `q` means five joins and no index.

Defect sources and types are FK'd to master tables, so an entry can never carry a
dropdown value that isn't in the master list — the server rejects it at write time.

Indexes: `(depot_code, entry_date)`, `(register, status)`, `(bus_id)`,
`(created_by_id)`, `(entry_date, created_at)`, GIN trgm on `search_text`.

Supporting tables: `depots`, `buses`, `defect_sources`, `defect_types`, `users`,
`user_depot_access`, `refresh_tokens`, `device_tokens`, `notifications`, `audit_logs`.

## Auth

- **`POST /auth/login`** — User ID + password, for ground staff without a mail ID.
  User IDs are normalized to uppercase on both write and login.
- **`POST /auth/sso`** — real Entra ID validation: JWKS signature, `iss`, `aud`, `exp`
  are all verified, then `email` is matched to a user record. Set `MS_TENANT_ID`
  and `MS_CLIENT_ID`; leaving them blank makes the endpoint reject cleanly rather
  than trust an unverified token.
- **24-hour access tokens** (ground team stays signed in through a full shift),
  30-day refresh tokens stored **hashed in the DB** and **rotated on every use** —
  a replayed refresh token is rejected. This is what makes the contract's
  "all tokens revoked" on deactivate actually true: `deactivate` and
  `reset-password` revoke every live refresh row, and `current_user` re-checks
  `is_active` on every request, so a stale access token dies immediately too.
- `POST /auth/change-password` (beyond the contract) clears `must_reset_password`
  and revokes other devices — the first-login reset flow needs somewhere to land.

## Notifications (in-app + FCM)

In-app is the durable channel (`notifications` table, read on app open); FCM is the
delivery channel. **If no FCM credentials are configured, in-app notifications still
work** — push is simply skipped. Triggers:

| Event | Recipients |
|---|---|
| Breakdown created | supervisors + managers of that depot, minus the reporter |
| Breakdown resolved | depot managers + the original reporter |
| Breakdown open past SLA | depot managers, once per breakdown |
| Account reactivated | the user |

The SLA nudge is an APScheduler job (`BREAKDOWN_SLA_SCAN_MINUTES`, default 30) that
flags breakdowns open longer than `BREAKDOWN_SLA_HOURS` (default 4) and stamps
`sla_notified_at` so it never nags twice. Dead FCM tokens are auto-deactivated from
the multicast response.

Endpoints: `GET /notifications`, `GET /notifications/unread-count`,
`POST /notifications/{id}/read`, `POST /notifications/read-all`,
`POST /devices/token` (idempotent), `DELETE /devices/token`.

**FCM setup:** drop the service-account JSON in `secrets/`, then set
`FCM_CREDENTIALS_FILE=/srv/secrets/fcm.json` and `FCM_PROJECT_ID`. The Android
client should subscribe to channel id `enm_alerts`.

## Deviations from the contract, and why

1. **`data` is validated, not stored verbatim.** Unknown keys are rejected
   (`extra="forbid"`) rather than silently persisted.
2. **`entry_time` is accepted on POST/PUT**, defaulting to depot wall-clock (IST)
   rather than UTC. The contract shows it on the Entry object but never says how it
   is set; a mechanic filing at 07:40 IST should not see 02:10.
3. **Extra endpoints**: `/auth/logout`, `/auth/change-password`, `/health/ready`,
   and the notification/device routes above. Nothing in the contract was removed.
4. **`GET /master/depots` returns only the caller's depots** — the contract says the
   picker uses `user.depot_access` for the list and this endpoint for labels, so
   scoping it avoids leaking the full depot roster to every executive.
5. **`GET /entries/export` and `/entries/summary`** are declared before `/{id}`, so
   `export` and `summary` are never captured as entry IDs.
6. **`breakdown.resolved_at`** is included in the breakdown `data` payload; the
   tracker UI needs it and the contract's `data` schema had nowhere else to put it.

## Permissions

- Every scoped endpoint takes `?depot=` and 403s if it is outside `depot_access`.
- Entry edit / photo: creator, or any `supervisor`/`manager` on that depot.
- `/admin/*`: `manager` only. A manager cannot deactivate their own account.
- Entry edits and user activate/deactivate/reset write to `audit_logs` with
  before/after payloads.

## Verified

`44 passed` — auth and revocation, per-register validation and field maps, bus
normalization and depot ownership, depot scoping, breakdown open/resolve/409,
free-text search, period filters, summary counts, edit permissions by role, photo
upload/delete and type rejection, CSV export shape, pagination bounds, admin CRUD
and uniqueness, notification fan-out and SLA scan idempotency.

`alembic revision --autogenerate` produces an empty diff against the models — the
hand-written migration and the ORM agree.

## Production checklist

- Set `JWT_SECRET` (`openssl rand -hex 32`) and rotate the bootstrap password.
- Set `CORS_ORIGINS` to the actual app origins; the default `*` is dev-only.
- Photos are written to a local volume. For multi-instance deploys, swap
  `app/services/storage.py` for S3 + presigned URLs — it is the only module that
  touches the filesystem.
- Put TLS in front of the API and set `PUBLIC_BASE_URL` to the https origin, since
  it is what photo URLs are built from.
