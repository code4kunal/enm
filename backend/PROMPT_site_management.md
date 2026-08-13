# Backend task: site management, super admins, per-site config and imports

You are working in `backend/` — FastAPI + PostgreSQL, SQLAlchemy 2.0, Alembic,
Pydantic v2, async throughout. Read `README.md` first: it documents the current
contract, the fully-relational entry model, and the deviations already taken.
Keep every convention it describes.

The Flutter client in `../app` is **already written against the API this task
produces**. It probes `GET /sites` at sign-in and runs in a reduced legacy mode
when that 404s, so nothing breaks while you work — but the app's Site section,
super-admin screens and import wizard stay read-only until this lands. Treat
`../app/lib/data/api/api_repositories.dart` as the consumer contract; every path,
field name and status code below is what it already sends and expects.

---

## 1. Rename depot → site

`site` is the tenant unit. One depot, one site. Rename it everywhere: tables,
columns, enums, query parameters, schema fields, service and route names.

| Now | Becomes |
| --- | --- |
| `depots` | `sites` |
| `user_depot_access` | `user_site_access` |
| `depot_code` (all tables) | `site_code` |
| `?depot=` | `?site=` |
| `depot_access` (UserOut/UserCreate/UserUpdate) | `site_access` |
| `EntryOut.depot`, `EntryCreate.depot` | `.site` |
| `GET /master/depots` | `GET /sites` |

This is a breaking change and that is accepted — bump the contract to **v1.1**
and say so in `README.md`. Do **not** keep `depot` aliases: two names for one
concept is how the vocabulary rots. The one exception is the register column
**"Bus No"**, which stays — it is what the paper register says. The master
entity is a *vehicle*; the register *column* is a bus number.

Write a single Alembic revision that renames rather than drops and recreates, so
no data is lost:

```python
op.rename_table("depots", "sites")
op.alter_column("buses", "depot_code", new_column_name="site_code")
# …and every FK, index and constraint name to match
```

`alembic revision --autogenerate` must produce an empty diff afterwards, as it
does today.

---

## 2. Sites become first-class

`sites` today is a seeded lookup. It becomes an admin-managed entity.

```
sites
  code             VARCHAR(16)  PK, uppercase, immutable once entries reference it
  name             VARCHAR(120) NOT NULL
  is_active        BOOL         NOT NULL DEFAULT true
  timezone         VARCHAR(64)  NOT NULL DEFAULT 'Asia/Kolkata'
  address          VARCHAR(255) NOT NULL DEFAULT ''
  commissioned_on  DATE         NULL
  created_at / updated_at
```

Endpoints (all `super_admin` only except the list):

| Method | Path | Notes |
| --- | --- | --- |
| GET | `/sites` | Every site for a super admin; the caller's `site_access` otherwise. Include `vehicle_count` and `user_count` rollups. |
| POST | `/sites` | `{code, name, timezone, address, commissioned_on}`. 409 on duplicate code. |
| PUT | `/sites/{code}` | Name, timezone, address, commissioned_on. **Code is immutable.** |
| POST | `/sites/{code}/activate` | |
| POST | `/sites/{code}/deactivate` | Soft: history retained, no new entries accepted, drops out of the switcher. |

Code format: `^[A-Z0-9][A-Z0-9_-]{1,15}$`, upper-cased on write. Reject a
deactivate that would leave a super admin with nothing to switch to only if you
find that necessary — the client already handles an empty roster.

---

## 3. Roles: add `super_admin`

`Role` becomes `super_admin | manager | supervisor | executive`, most to least
privileged. Add the value to the `role_enum` Postgres type in the migration.

| Capability | super_admin | manager | supervisor | executive |
| --- | --- | --- | --- | --- |
| Reaches every site without a grant | ✅ | — | — | — |
| Onboard / edit / deactivate sites | ✅ | — | — | — |
| Edit tenant-wide master lists | ✅ | — | — | — |
| Maintain a site's vehicles, config, import profiles | ✅ | own sites | — | — |
| Create users | any role | supervisor + executive, own sites only | — | — |
| Read/write entries | ✅ | own sites | own sites | own sites |

Rules that must hold server-side, not just in the UI:

- A super admin's `site_access` is **empty and ignored**. Authorisation asks
  "is this user a super admin, or is `site_code` in `site_access`?" — never
  reads the list for a super admin. Storing every code would go stale the moment
  a site is onboarded.
- `POST /admin/users` rejects a role the caller cannot grant (403), and rejects
  `site_access` entries outside the caller's own sites unless the caller is a
  super admin.
- A user may not deactivate their own account (already true for managers).
- The last active super admin may not be deactivated or demoted. Return 409 with
  a message saying so.
- Deactivating a site does **not** deactivate its users.

Seed one super admin alongside the existing bootstrap manager, driven by
`BOOTSTRAP_SUPERADMIN_USER_ID` / `..._PASSWORD`.

---

## 4. Vehicles replace the read-only bus master

`buses` becomes `vehicles`, editable per site.

```
vehicles
  id                    VARCHAR(32) PK
  registration_no       VARCHAR(32) NOT NULL UNIQUE   -- uppercase, whitespace stripped
  site_code             FK sites.code ON DELETE RESTRICT
  is_active             BOOL NOT NULL DEFAULT true
  make                  VARCHAR(64)  NOT NULL DEFAULT ''
  model                 VARCHAR(64)  NOT NULL DEFAULT ''
  battery_capacity_kwh  NUMERIC(8,2) NULL
```

| Method | Path | Notes |
| --- | --- | --- |
| GET | `/sites/{code}/vehicles?include_inactive=&active=` | |
| POST | `/sites/{code}/vehicles` | 409 on duplicate registration. |
| PUT | `/sites/{code}/vehicles/{id}` | |
| POST | `/vehicles/{id}/activate` \| `/deactivate` | Retired vehicles stay on past entries but leave the entry dropdown. |

Keep `entries.bus_id` pointing at `vehicles.id`. A retired vehicle must still
resolve on historical entries — that is why this is a flag, not a delete.

Master lists become editable too, super-admin only. They currently return bare
strings; they must return objects, and the client already accepts both:

```
GET  /master/defect-sources?include_inactive=true
  -> {"items":[{"id":1,"name":"Driver report","is_active":true,"sort_order":0}]}
POST /master/defect-sources           {name}
PUT  /master/defect-sources/{id}      {name, is_active, sort_order}
```

Same for `/master/defect-types`. Hiding an item must not break entries that
already reference it — filter on `is_active` when serving the dropdown, never
when resolving an existing entry.

---

## 5. Site configuration — the docking schedule

**This is preventive maintenance, not charging.** A "docking schedule" is the
site's service plan, modelled the way paid car servicing works: a service falls
due on whichever comes first, distance or elapsed time. There are no charging
bays, connectors, kW or SoC targets anywhere in this feature.

```
site_configs
  site_code                PK, FK sites.code
  reminder_lead_km         INT NOT NULL DEFAULT 500    -- "due soon" window
  reminder_lead_days       INT NOT NULL DEFAULT 7
  docking_slot_minutes     INT NOT NULL DEFAULT 120    -- bay time per service
  max_vehicles_in_service  INT NOT NULL DEFAULT 0      -- 0 = no cap
  odometer_sync_enabled    BOOL NOT NULL DEFAULT true
  odometer_sync_minutes    INT  NOT NULL DEFAULT 60
  odometer_sync_source     VARCHAR(64) NOT NULL DEFAULT 'telematics'
  odometer_last_synced_at  TIMESTAMPTZ NULL
  updated_at, updated_by_id

service_plans     site_code, code, name, interval_km, interval_days,
                  is_active, notes
                  UNIQUE (site_code, upper(code))
                  -- interval_km = 0 means time-driven only, and vice versa

shift_windows     site_code, shift (A|B|C), start_time, end_time
                  -- end <= start means the window wraps midnight (C shift)
```

```
GET /sites/{code}/config
PUT /sites/{code}/config      -- whole aggregate, replaces plans/shifts
```

Manager (own sites) or super admin.

**Validate on write and return 422.** The client checks the same rules first so
the user sees them before a round trip, but the server is the authority.
`../app/lib/models/site_config.dart` → `validationIssues` is the exact list:

1. No active plan has an interval — nothing would ever fall due.
2. Two plans sharing a code, case-insensitively.
3. A blank plan code.
4. `reminder_lead_km >= interval_km` for any active distance plan — it would
   always read as due.
5. `reminder_lead_days >= interval_days`, likewise.
6. `odometer_sync_minutes < 5`.

### Due calculation

Expose this as `GET /sites/{code}/services/due` and keep it identical to
`../app/lib/models/service_due.dart`, which the client already implements:

- Anchor distance on `vehicles.last_service_km`, or 0 if never serviced. Due at
  `anchor + interval_km`.
- Anchor time on `last_service_on`, else the first odometer sighting, else today.
  Due at `anchor + interval_days`.
- `overdue` when either runway is <= 0; `due_soon` when either is inside its
  reminder lead; the worse of the two wins.
- A vehicle with **no odometer reading at all** returns `unknown` for
  distance-driven plans — never treat a missing reading as 0 km. A stale
  telematics feed has to be visible, not invisible.
- Retired vehicles are excluded.
- Order worst-first.

## 5a. Odometers — the scheduled refresh

Every vehicle master carries a current odometer, and the whole schedule hangs
off it. Add to `vehicles`:

```
odometer_km          INT NOT NULL DEFAULT 0
odometer_updated_at  TIMESTAMPTZ NULL   -- NULL means never synced
last_service_km      INT NULL
last_service_on      DATE NULL
last_service_code    VARCHAR(16) NOT NULL DEFAULT ''

odometer_readings    id, vehicle_id, odometer_km, recorded_at, source
                     -- append-only history; the vehicle row caches the latest
```

| Method | Path | Notes |
| --- | --- | --- |
| POST | `/sites/{code}/vehicles/odometer/sync` | Pull from telematics now. Returns `{readings:[{vehicle_id, registration_no, odometer_km, recorded_at}], synced_at, skipped}`. |
| PUT | `/vehicles/{id}/odometer` | Manual reading, `{odometer_km}`. |
| POST | `/vehicles/{id}/services` | `{plan_code, odometer_km, serviced_on}` — closes out a service and re-anchors the next. |

**Run the pull on a schedule server-side too**, as an APScheduler job alongside
the existing breakdown-SLA scan: every `odometer_sync_minutes`, per site with
`odometer_sync_enabled`. The client also polls on that interval, so the two must
be idempotent — a pull that finds nothing new returns `skipped`, not an error.

**An odometer never moves backwards.** Reject a manual reading lower than the
one on record (422, "odometers do not run backwards"), and silently skip a lower
figure on a bulk import — that is a stale sheet, not a correction.

If no telematics provider is configured, the sync endpoint must succeed with an
empty `readings` list rather than 500. Sites without a feed rely on manual
readings and the odometer import, and the rest of the schedule still works.

## 6. Data import

The point of this feature: **import formats vary per site**. The target shape is
fixed and known; the source is whatever spreadsheet that site already keeps. A
*profile* is the saved translation between the two, so the same monthly sheet is
configured once and replayed.

```
site_import_profiles
  id, site_code, name, target (enum), sheet_name, header_row, skip_rows,
  last_run_at, created_by_id

site_import_mappings
  profile_id, target_key, source_column, constant_value, date_format

site_import_runs
  id, site_code, profile_id, profile_name, target, file_name,
  rows_accepted, rows_rejected, run_at, run_by_id
```

`target` enum: `vehicles`, `defect_sources`, `defect_types`,
`service_schedule`, `odometers`, `work_done`, `coolant`, `driver_complaint`,
`breakdown`, `pm_schedule`.

| Method | Path | Body |
| --- | --- | --- |
| GET | `/sites/{code}/import-profiles` | |
| POST | `/sites/{code}/import-profiles` | profile JSON |
| PUT | `/sites/{code}/import-profiles/{id}` | profile JSON |
| DELETE | `/import-profiles/{id}` | |
| POST | `/sites/{code}/imports/inspect` | multipart `file`, `header_row`, `sheet_name` |
| POST | `/sites/{code}/imports/preview` | multipart `file`, `target`, `header_row`, `skip_rows`, `sheet_name`, `mappings` (JSON string) |
| POST | `/sites/{code}/imports/commit` | `{token}` |
| GET | `/sites/{code}/imports` | run history |

**Parsing belongs here, not in the client.** Accept `.xlsx`, `.xls` and `.csv`
(`openpyxl` + the stdlib `csv` module). The client uploads bytes and renders
what you return; it has a CSV reader only so the offline demo is exercisable.

`inspect` returns:
```json
{"file_name":"fleet.xlsx","sheet_names":["Sheet1"],
 "columns":["Registration No","Make"],
 "sample_rows":[{"Registration No":"MH40LY1894","Make":"EKA"}],
 "total_rows":42}
```
Duplicate or blank headers must be made addressable (`"Make (2)"`,
`"Column 3"`), and **blank rows must not shift the numbering** — every row
number you report has to be the row the user sees in Excel.

`preview` is a dry run: map and validate every row, write nothing, stage the
result under a `token` with a short TTL. Return:
```json
{"token":"…","file_name":"…","target":"vehicles",
 "rows":[{…mapped by target key…}],
 "errors":[{"row_number":3,"field":"Registration No","message":"Required value is blank"}],
 "total_rows":42,"new_count":40,"update_count":2}
```

`commit` consumes the token and applies exactly what was previewed — not a
re-parse. A stale or unknown token is 410 Gone; the client already tells the
user to re-upload.

Validation rules, per target:

- Required target fields blank → reject that row, keep the rest.
- Registration numbers normalised uppercase/no-whitespace before comparison.
- A register, service or odometer row referencing a vehicle not on that
  site's fleet →
  reject with `"{reg} is not on the {SITE} fleet"`.
- A dropdown value not on its master list → reject. Never auto-create master
  rows from an import.
- Dates parsed with the mapping's `date_format` when set, else ISO; a value that
  parses to neither → reject naming the expected format.
- A mapping may carry a `constant_value` instead of a `source_column`, for
  sheets that omit a column the target needs.

Writes are **upsert by natural key**, not blind insert — sites resend the same
monthly sheet and a re-run must not double the fleet:

| Target | Natural key |
| --- | --- |
| vehicles | `registration_no` |
| defect_sources / defect_types | `name`, case-insensitive |
| service_schedule | `(site_code, upper(code))` |
| odometers | `registration_no`; skip a reading lower than the one on record |
| register targets | insert; historical backfill has no stable key |

Backfilled breakdowns land **resolved**, never `open` — a 2024 breakdown must
not light up today's open-breakdown banner.

The target field keys for register imports are the register's own columns plus
`entered_by`; see `../app/lib/data/import_targets.dart`, which derives them from
the register definitions so the two never drift.

---

## 7. Self-service password change

`POST /auth/change-password` already exists and the client already calls it.
Confirm it: requires the current password, enforces a minimum of 8 characters,
clears `must_reset_password`, and revokes every other refresh token while
keeping the calling session alive. Reject a new password equal to the current
one.

`POST /admin/users/{id}/reset-password` must return the generated password in
the response body as `temp_password` — the admin reads it aloud to a mechanic
and it is never retrievable again. Same for the password `POST /admin/users`
generates when `temp_password` is omitted. Set `must_reset_password` on both.

---

## 8. Definition of done

- `alembic upgrade head` on a populated database preserves every existing entry,
  user and access grant.
- `alembic revision --autogenerate` produces an empty diff.
- `make test` passes, with new tests covering: the rename migration round-trip;
  super-admin reach without explicit grants; role-grant restrictions; the
  last-super-admin guard; site deactivation refusing new entries; vehicle
  retire/restore preserving history; each of the six config validation rules;
  the due calculation across overdue / due-soon / no-odometer / never-serviced;
  the odometer scheduler being idempotent and refusing to run backwards;
  import preview/commit for every target; upsert-not-duplicate on re-run;
  row numbers surviving blank rows; token expiry on commit.
- `README.md` updated: the contract version, the rename, the new tables and
  endpoints, and a "Deviations" entry for anything you chose differently.
- `GET /sites` answers for an authenticated user, which is what flips the client
  out of legacy mode.

Then, in `../app`, delete the legacy branches in
`lib/data/api/api_repositories.dart` (`_requireSiteManagement`, the
`/master/depots` and `/master/buses` fallbacks) and the `ApiCapabilities` probe,
and set `scopeParam` to `site` unconditionally. They exist only to bridge this
gap.
