# Driver Complaint / Breakdown traceability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Driver Complaint and Breakdown records a human-readable
display ID, a real Ticket Detail view (replacing the plain read-only form
as the register's View action), a rewritten Work Done linking flow that
prefills instead of re-asking, an explicit `attended_time`, multi-photo
capture, and GPS/manual location capture.

**Architecture:** Server-stamped display IDs via a race-safe per-kind-per-
year counter table; a new `GET /tickets/{id}` endpoint powers both a new
`/tickets` list screen and the register's existing View button (redirected,
not duplicated); the Work Done form's existing async ticket-search section
is repositioned and extended rather than replaced; photo storage promotes
the existing single-column disk-backed mechanism into a one-to-many table,
reusing its storage functions unchanged.

**Tech Stack:** FastAPI + SQLAlchemy async + Alembic (backend), Flutter +
Riverpod + go_router (app), `flutter_map` (new Flutter dependency, OSM
tiles — no API key).

**Spec:** `docs/superpowers/specs/2026-09-28-driver-complaint-breakdown-traceability-design.md`

## Global Constraints

- Display ID format: `<PREFIX>-<YYYY>-<NNNNNN>`, prefixes exactly as the
  spec's Decisions table lists them (`WD`, `BD`, `DC`, `CT`, `PS` for
  `Entry.register`; `BD`, `DC`, `CT`, `DI`, `TD`, `PM`, `PS` for
  `Ticket.source_kind`).
- `id_counters.kind` is namespaced `f"entry:{register.value}"` /
  `f"ticket:{source_kind.value}"` — Entry and Ticket counters are never
  shared, even where the underlying value string is identical.
- The UI never shows `Ticket.display_id` this pass — every screen that
  identifies a Breakdown/Driver Complaint ticket shows its **source
  entry's** `display_id` instead (see spec's "Where display_id lives" row).
- Photo storage reuses `backend/app/services/storage.py`'s
  `validate_photo`/`save_photo`/`delete_photo` unchanged — no S3, no new
  storage backend.
- `POST`/`DELETE /entries/{id}/photo` (singular) are replaced entirely by
  `POST`/`DELETE /entries/{id}/photos` (plural) for **every** register, not
  only the three this plan's UI touches — one backend surface.
- Editing a Breakdown or Driver Complaint stays on the register form
  (`Routes.editEntry`), unchanged. Only the **View** action's destination
  changes.

## Review Focus

- A driver complaint created through the bulk/import path (not the manual
  form) must still get a ticket and a `display_id` — the auto-ticket logic
  lives in `POST /entries`, so anything bypassing that endpoint (are there
  any? check `services/imports.py`) would silently skip both.
- Two entries submitted in the same request/transaction burst (e.g. a
  double-tap on Save) must not receive the same `display_id` — this is
  exactly what the counter's `ON CONFLICT ... DO UPDATE` is for; Task 1's
  test must actually exercise concurrent allocation, not just sequential.
- A ticket whose source entry was later edited (bus reassigned, complaint
  text changed) must show the **current** entry state on Ticket Detail, not
  a stale snapshot — `GET /tickets/{id}` must re-read the entry live, never
  cache anything from ticket-creation time.
- **Confirmed, not hypothetical**: `services/imports.py` (the snag-sheet
  import) already force-marks every imported `breakdown` row `resolved`
  right after creation specifically so historical data never lights up a
  live open-ticket banner (`imports.py:944-947`) — but that override is
  `Register.breakdown`-only. Task 4 makes `driver_complaint` default to
  `status=open` at creation; imports never calls the ticket-creation code
  (`rg` confirms zero `Ticket` references in `imports.py`), so an imported
  driver complaint would land as `status=open` with no backing ticket —
  a real inconsistency, not a hypothetical. Task 4 includes the fix.
- The existing single-photo Flutter widget (every register except the
  three this plan touches) must keep working unchanged after the backend
  endpoint swap — Task 8's tests must include a register the plan doesn't
  otherwise touch (Coolant) round-tripping one photo through the new
  endpoints.
- A ticket with **no** source entry (inspection-sourced, out of this pass's
  UI scope) must not crash `GET /tickets/{id}` if it's ever hit directly —
  the endpoint must degrade to ticket-only fields rather than assume
  `source_entry` is non-null.

---

## Task 1: `id_counters` table and display-ID allocation

**Files:**
- Create: `backend/alembic/versions/0035_id_counters.py`
- Create: `backend/app/models/id_counter.py`
- Modify: `backend/app/services/entries.py` (new helper)
- Test: `backend/tests/test_id_counters.py`

**Interfaces:**
- Produces: `async def allocate_display_id(session: AsyncSession, *, kind: str, year: int, prefix: str) -> str` in `backend/app/services/id_counters.py` — returns e.g. `"BD-2026-000001"`. Tasks 2 and 3 both call this.

- [ ] **Step 1: Write the failing test**

```python
# backend/tests/test_id_counters.py
from __future__ import annotations

import asyncio

import pytest
from sqlalchemy.ext.asyncio import AsyncSession

from app.services.id_counters import allocate_display_id


async def test_allocate_display_id_formats_and_increments(
    db_session: AsyncSession,
) -> None:
    first = await allocate_display_id(
        db_session, kind="entry:breakdown", year=2026, prefix="BD"
    )
    second = await allocate_display_id(
        db_session, kind="entry:breakdown", year=2026, prefix="BD"
    )
    await db_session.commit()
    assert first == "BD-2026-000001"
    assert second == "BD-2026-000002"


async def test_allocate_display_id_resets_per_year(db_session: AsyncSession) -> None:
    a = await allocate_display_id(
        db_session, kind="entry:breakdown", year=2025, prefix="BD"
    )
    b = await allocate_display_id(
        db_session, kind="entry:breakdown", year=2026, prefix="BD"
    )
    await db_session.commit()
    assert a == "BD-2025-000001"
    assert b == "BD-2026-000001"


async def test_allocate_display_id_kind_is_namespaced(db_session: AsyncSession) -> None:
    """Entry and Ticket counters never share a sequence, even though
    Register.breakdown and TicketSourceKind.breakdown are both the string
    "breakdown" -- the `kind` argument must be the caller's full namespaced
    string, not just the raw enum value."""
    entry_id = await allocate_display_id(
        db_session, kind="entry:breakdown", year=2026, prefix="BD"
    )
    ticket_id = await allocate_display_id(
        db_session, kind="ticket:breakdown", year=2026, prefix="BD"
    )
    await db_session.commit()
    assert entry_id == "BD-2026-000001"
    assert ticket_id == "BD-2026-000001"


async def test_allocate_display_id_is_race_safe(async_engine) -> None:
    from sqlalchemy.ext.asyncio import async_sessionmaker

    maker = async_sessionmaker(async_engine, expire_on_commit=False)

    async def _one() -> str:
        async with maker() as session:
            value = await allocate_display_id(
                session, kind="entry:breakdown", year=2026, prefix="BD"
            )
            await session.commit()
            return value

    results = await asyncio.gather(*[_one() for _ in range(10)])
    assert len(set(results)) == 10
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && pytest tests/test_id_counters.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'app.services.id_counters'`

- [ ] **Step 3: Write the model, migration, and allocator**

```python
# backend/app/models/id_counter.py
from __future__ import annotations

from sqlalchemy import Integer, String
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base


class IdCounter(Base):
    """Backs every `display_id` in the system. One row per (kind, year);
    `kind` is namespaced by the caller (`entry:breakdown`, `ticket:breakdown`,
    ...) so Entry and Ticket sequences never collide even when the
    underlying register/source_kind string is identical."""

    __tablename__ = "id_counters"

    kind: Mapped[str] = mapped_column(String(32), primary_key=True)
    year: Mapped[int] = mapped_column(Integer, primary_key=True)
    next_value: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
```

```python
# backend/app/services/id_counters.py
from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.id_counter import IdCounter


async def allocate_display_id(
    session: AsyncSession, *, kind: str, year: int, prefix: str
) -> str:
    stmt = (
        pg_insert(IdCounter)
        .values(kind=kind, year=year, next_value=2)
        .on_conflict_do_update(
            index_elements=[IdCounter.kind, IdCounter.year],
            set_={"next_value": IdCounter.next_value + 1},
        )
        .returning(IdCounter.next_value)
    )
    result = await session.execute(stmt)
    allocated = result.scalar_one() - 1
    return f"{prefix}-{year}-{allocated:06d}"
```

The `INSERT ... VALUES (..., next_value=2) ON CONFLICT DO UPDATE SET
next_value = next_value + 1 RETURNING next_value` gives back `2` on first
insert (already incremented past the value we want to hand out) and
`current + 1` on every conflict — subtracting 1 in Python yields `1, 2, 3, …`
without a second round trip. Postgres serializes concurrent upserts on the
same primary key, so this is safe without an explicit `SELECT ... FOR
UPDATE`.

```python
# backend/alembic/versions/0035_id_counters.py
"""id_counters -- backs every Entry/Ticket display_id.

Revision ID: 0035
Revises: 0034
Create Date: 2026-09-28
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa

revision = "0035"
down_revision = "0034"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "id_counters",
        sa.Column("kind", sa.String(length=32), nullable=False),
        sa.Column("year", sa.Integer(), nullable=False),
        sa.Column("next_value", sa.Integer(), nullable=False, server_default="1"),
        sa.PrimaryKeyConstraint("kind", "year", name="pk_id_counters"),
    )


def downgrade() -> None:
    op.drop_table("id_counters")
```

Add `IdCounter` to `backend/app/models/__init__.py`'s import list (wherever
sibling models are re-exported for Alembic autogenerate/metadata discovery
— match the existing entries for `Driver`/`SparePart`).

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && alembic upgrade head && pytest tests/test_id_counters.py -v`
Expected: PASS 4/4

- [ ] **Step 5: Commit**

```bash
git add backend/app/models/id_counter.py backend/app/services/id_counters.py \
  backend/alembic/versions/0035_id_counters.py backend/tests/test_id_counters.py \
  backend/app/models/__init__.py
git commit -m "Add id_counters table and race-safe display-id allocator"
```

---

## Task 2: `Entry.display_id`

**Files:**
- Modify: `backend/app/models/entry.py`
- Modify: `backend/app/services/entries.py`
- Modify: `backend/app/schemas/entry.py`
- Create: `backend/alembic/versions/0036_entry_display_id.py`
- Test: `backend/tests/test_entries.py`

**Interfaces:**
- Consumes: `allocate_display_id` from Task 1.
- Produces: `Entry.display_id: str`, non-null, unique. `_DataBase.display_id: str` (read-only) on every entry schema's output, consumed by Task 6 (Ticket Detail) and Task 10 (Flutter prefill).

- [ ] **Step 1: Write the failing test**

```python
# backend/tests/test_entries.py -- add
async def test_entry_gets_a_prefixed_display_id(client: AsyncClient) -> None:
    h = await auth_headers(client)
    r = await client.post("/entries", json=breakdown(), headers=h)
    assert r.status_code == 201, r.text
    assert r.json()["display_id"].startswith("BD-")


async def test_work_done_entry_gets_wd_prefix(client: AsyncClient) -> None:
    h = await auth_headers(client)
    r = await client.post("/entries", json=work_done(), headers=h)
    assert r.status_code == 201, r.text
    assert r.json()["display_id"].startswith("WD-")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && pytest tests/test_entries.py -k display_id -v`
Expected: FAIL with `KeyError: 'display_id'`

- [ ] **Step 3: Add the column, wire allocation, expose in the schema**

`backend/app/models/entry.py`, on `Entry` (near `photo_url`):

```python
    display_id: Mapped[str] = mapped_column(String(20), nullable=False, unique=True)
```

`backend/app/schemas/entry.py`, on `_DataBase` (the shared base every
register's `*Data` inherits, so every register gets this for free):

```python
    # Read-only, server-stamped at creation. Never accepted on write.
    display_id: str = ""
```

Check `_DataBase`'s actual name/location before editing — if entries.py's
`serialize_data`/`serialize_entry` builds the response from a different
shared structure, add `display_id` there instead; the requirement is that
every entry register's GET/POST response includes it, not that any one
particular class owns it.

`backend/app/services/entries.py`, in `create_entry` (the block that builds
`Entry(...)`, right after `entry_date`/`status` are set, before the row is
added — needs `session.flush()` semantics respected, see the note below):

```python
_ENTRY_DISPLAY_PREFIX = {
    Register.work_done: "WD",
    Register.breakdown: "BD",
    Register.driver_complaint: "DC",
    Register.coolant: "CT",
    Register.pm_schedule: "PS",
}


async def create_entry(...) -> Entry:
    ...
    entry = Entry(
        register=register,
        site_code=site_code,
        vehicle=vehicle,
        entry_date=entry_date,
        entry_time=entry_time or _now_ist().time().replace(microsecond=0),
        status=(
            EntryStatus.open
            if register in (Register.breakdown, Register.driver_complaint)
            else EntryStatus.done
        ),
        display_id=await allocate_display_id(
            session,
            kind=f"entry:{register.value}",
            year=entry_date.year,
            prefix=_ENTRY_DISPLAY_PREFIX[register],
        ),
        created_by=creator,
        work_type_id=work_type_id,
    )
    ...
```

Note the `status` line already changes here too — this is Task 4's
"driver complaint auto-opens a ticket" change, folded in now since it
touches the same three lines and splitting it into two edits of the same
`Entry(...)` call would just create a merge headache. Task 4's own test
covers the ticket side; this task's tests only cover `display_id`.

`year=entry_date.year` (not the wall-clock year) — a backdated entry gets
the display id its *recorded* date implies, matching how the paper
registers numbered by the date written on the page, not the day it was
transcribed.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && pytest tests/test_entries.py -k display_id -v`
Expected: PASS 2/2

- [ ] **Step 5: Migration — backfill then constrain**

```python
# backend/alembic/versions/0036_entry_display_id.py
"""entries.display_id -- backfilled per-register, then NOT NULL + unique.

Revision ID: 0036
Revises: 0035
Create Date: 2026-09-28
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa

revision = "0036"
down_revision = "0035"
branch_labels = None
depends_on = None

_PREFIX = {
    "work_done": "WD",
    "breakdown": "BD",
    "driver_complaint": "DC",
    "coolant": "CT",
    "pm_schedule": "PS",
}


def upgrade() -> None:
    op.add_column("entries", sa.Column("display_id", sa.String(length=20), nullable=True))
    conn = op.get_bind()
    for register, prefix in _PREFIX.items():
        rows = conn.execute(
            sa.text(
                "SELECT id, entry_date FROM entries WHERE register = :r "
                "ORDER BY entry_date, created_at"
            ),
            {"r": register},
        ).fetchall()
        counters: dict[int, int] = {}
        for entry_id, entry_date in rows:
            year = entry_date.year
            counters[year] = counters.get(year, 0) + 1
            conn.execute(
                sa.text("UPDATE entries SET display_id = :d WHERE id = :i"),
                {"d": f"{prefix}-{year}-{counters[year]:06d}", "i": entry_id},
            )
        for year, count in counters.items():
            conn.execute(
                sa.text(
                    "INSERT INTO id_counters (kind, year, next_value) "
                    "VALUES (:k, :y, :n) "
                    "ON CONFLICT (kind, year) DO UPDATE SET next_value = :n"
                ),
                {"k": f"entry:{register}", "y": year, "n": count + 1},
            )
    op.alter_column("entries", "display_id", nullable=False)
    op.create_unique_constraint("uq_entries_display_id", "entries", ["display_id"])


def downgrade() -> None:
    op.drop_constraint("uq_entries_display_id", "entries", type_="unique")
    op.drop_column("entries", "display_id")
```

- [ ] **Step 6: Run migration and full backend test suite**

Run: `cd backend && alembic upgrade head && make test-backend`
Expected: migration applies cleanly against seeded dev data; full suite
green (existing tests that assert on entry JSON shape may need
`display_id` added to their expected-keys set — fix any that fail this way,
they are not real regressions).

- [ ] **Step 7: Commit**

```bash
git add backend/app/models/entry.py backend/app/services/entries.py \
  backend/app/schemas/entry.py backend/alembic/versions/0036_entry_display_id.py \
  backend/tests/test_entries.py
git commit -m "Add Entry.display_id, allocated per-register at creation"
```

---

## Task 3: `Ticket.display_id`

**Files:**
- Modify: `backend/app/models/ticket.py`
- Modify: `backend/app/services/tickets.py`
- Create: `backend/alembic/versions/0037_ticket_display_id.py`
- Test: `backend/tests/test_tickets.py`

**Interfaces:**
- Consumes: `allocate_display_id` from Task 1.
- Produces: `Ticket.display_id: str`, non-null, unique. Not surfaced in any
  API response schema this pass (Global Constraints) — the column exists
  for the invariant and for inspection-sourced tickets' future screen, but
  no task in this plan reads it back out.

- [ ] **Step 1: Write the failing test**

```python
# backend/tests/test_tickets.py -- add
async def test_ticket_gets_a_display_id(db_session, ...) -> None:
    # Use whichever existing helper in this file creates a Ticket directly
    # (e.g. via create_ticket_for_entry against a breakdown entry) --
    # mirror the setup of a neighboring test in this file rather than
    # inventing new fixtures.
    ...
    assert ticket.display_id.startswith("BD-")
```

Write this against the actual fixture helpers already in
`test_tickets.py` (read the file first — `breakdown()`, `auth_headers`,
etc. per this repo's established pattern) rather than the pseudocode
above; the assertion (`ticket.display_id` populated, correct prefix) is
what matters, not the exact fixture plumbing.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && pytest tests/test_tickets.py -k display_id -v`
Expected: FAIL — `AttributeError: 'Ticket' object has no attribute 'display_id'`

- [ ] **Step 3: Add the column and wire allocation**

`backend/app/models/ticket.py`:

```python
    display_id: Mapped[str] = mapped_column(String(20), nullable=False, unique=True)
```

`backend/app/services/tickets.py`:

```python
_TICKET_DISPLAY_PREFIX = {
    TicketSourceKind.breakdown: "BD",
    TicketSourceKind.driver_complaint: "DC",
    TicketSourceKind.coolant: "CT",
    TicketSourceKind.daily_inspection: "DI",
    TicketSourceKind.ten_day_inspection: "TD",
    TicketSourceKind.pm_docking: "PM",
    TicketSourceKind.pm_schedule: "PS",
}
```

In both `create_ticket_for_entry` and `create_ticket_for_inspection_result`,
before the `Ticket(...)` constructor call, resolve `source_kind` (each
function already computes it) and the entry/inspection's own date, then
pass:

```python
display_id=await allocate_display_id(
    session,
    kind=f"ticket:{source_kind.value}",
    year=<entry_date or inspection.entry_date>.year,
    prefix=_TICKET_DISPLAY_PREFIX[source_kind],
),
```

Read both functions in full before editing — `create_ticket_for_entry`
already has `entry.entry_date` in scope; `create_ticket_for_inspection_result`
needs the equivalent field off `inspection` (check its exact attribute name,
likely `inspection.entry_date` or via `inspection.entry.entry_date`).

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && pytest tests/test_tickets.py -k display_id -v`
Expected: PASS

- [ ] **Step 5: Migration**

Same backfill shape as Task 2's, keyed by `tickets.source_kind` and each
ticket's `ticket_entry_date()` (the existing helper `services/tickets.py`
already has for sorting — reuse its logic/date source rather than
re-deriving). File `backend/alembic/versions/0037_ticket_display_id.py`,
`down_revision = "0036"`.

- [ ] **Step 6: Run migration and full backend test suite**

Run: `cd backend && alembic upgrade head && make test-backend`
Expected: green.

- [ ] **Step 7: Commit**

```bash
git add backend/app/models/ticket.py backend/app/services/tickets.py \
  backend/alembic/versions/0037_ticket_display_id.py backend/tests/test_tickets.py
git commit -m "Add Ticket.display_id, allocated per-source-kind at creation"
```

---

## Task 4: Driver Complaint auto-opens a ticket

**Files:**
- Modify: `backend/app/api/entries.py`
- Modify: `backend/app/services/imports.py`
- Test: `backend/tests/test_entries.py`, `backend/tests/test_imports.py`

**Interfaces:**
- Consumes: `create_ticket_for_entry` (existing), `Entry.status` change
  already made in Task 2 Step 3.

- [ ] **Step 1: Write the failing test**

```python
# backend/tests/test_entries.py -- add
async def test_driver_complaint_opens_a_ticket_automatically(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    r = await client.post("/entries", json=driver_complaint(), headers=h)
    assert r.status_code == 201, r.text
    assert r.json()["status"] == "open"
    found = await client.get(
        "/tickets/search", params={"site": "MBMT", "q": r.json()["display_id"]},
        headers=h,
    )
    assert len(found.json()) == 1


async def test_driver_complaint_raise_ticket_endpoint_now_conflicts(
    client: AsyncClient,
) -> None:
    """The manual raise_ticket endpoint still exists (used by pre-existing
    complaints and by Coolant), but a freshly-created complaint already has
    one -- calling it again must 409, not silently create a duplicate."""
    h = await auth_headers(client)
    created = await client.post("/entries", json=driver_complaint(), headers=h)
    entry_id = created.json()["id"]
    r = await client.post(f"/entries/{entry_id}/raise_ticket", headers=h)
    assert r.status_code == 409
```

```python
# backend/tests/test_imports.py -- add
async def test_imported_driver_complaint_is_marked_resolved_not_open(
    session, ...  # match this file's existing fixture pattern for driving
    # an import run directly through services.imports (not the API) --
    # copy the setup from the neighboring breakdown-import test in this
    # file, same shape, register='driver_complaint' instead.
) -> None:
    """Mirrors the existing breakdown-import behavior: historical rows must
    not appear as live open work, and (new) must not end up status=open
    with no backing ticket."""
    ...
    assert entry.status == EntryStatus.resolved
```

Check `driver_complaint()` exists as a fixture helper in `test_entries.py`
already (the earlier ticket-coverage-completion work added driver_id
support to this register, so a helper likely already exists) — reuse it,
don't reinvent.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && pytest tests/test_entries.py -k driver_complaint_opens -v`
Expected: FAIL — no ticket found (still requires manual raise).

- [ ] **Step 3: Wire the automatic call**

`backend/app/api/entries.py`, the block reading
`if payload.register is Register.breakdown: await tickets_svc.create_ticket_for_entry(...)`:

```python
    if payload.register in (Register.breakdown, Register.driver_complaint):
        await tickets_svc.create_ticket_for_entry(session, entry=entry, creator=user)
    if payload.register is Register.breakdown:
        await notifications.notify_breakdown_opened(session, entry)
```

(Split the two `if`s rather than nesting — breakdown gets both a ticket
and the existing opened-notification; driver_complaint gets only the
ticket. Don't add a notification for driver_complaint here — out of scope,
not requested.)

`backend/app/services/imports.py`, the block with the comment "A 2024
breakdown must not light up today's open-breakdown banner":

```python
        if register in (Register.breakdown, Register.driver_complaint):
            entry.status = EntryStatus.resolved
            if register is Register.breakdown and entry.breakdown is not None:
                entry.breakdown.resolved_at = datetime.now(UTC)
```

(Extending the existing condition to `driver_complaint`, not adding a
parallel `if` — the `resolved_at` stamp stays breakdown-only since
`DriverComplaintEntry` has no equivalent field; only the status override
generalizes.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && pytest tests/test_entries.py -k driver_complaint -v tests/test_imports.py -k driver_complaint -v`
Expected: PASS

- [ ] **Step 5: Full backend suite**

Run: `cd backend && make test-backend`
Expected: green — watch specifically for any test asserting a fresh driver
complaint's `status == "done"`, which is now `"open"`; fix the assertion,
it's testing the old (soon-to-be-wrong) behavior, not a regression.

- [ ] **Step 6: Commit**

```bash
git add backend/app/api/entries.py backend/app/services/imports.py \
  backend/tests/test_entries.py backend/tests/test_imports.py
git commit -m "Driver Complaint opens a ticket automatically, like Breakdown"
```

---

## Task 5: `GET /tickets/search` status filter + display-id search match

**Files:**
- Modify: `backend/app/api/tickets.py`
- Modify: `backend/app/services/tickets.py`
- Modify: `backend/app/schemas/ticket.py`
- Test: `backend/tests/test_tickets.py`

**Interfaces:**
- Produces: `search_tickets(..., status: Literal["open","completed","all"] = "open")`. `TicketSearchResult.display_id: str` (the **source entry's** display_id — see Global Constraints).
- Consumes: Task 2's `Entry.display_id`.

- [ ] **Step 1: Write the failing test**

```python
# backend/tests/test_tickets.py -- add
async def test_search_default_excludes_completed(client, ...) -> None:
    ...  # create + complete one ticket (reuse resolve_via_work_done from
    # test_entries.py), then:
    r = await client.get("/tickets/search", params={"site": "MBMT"}, headers=h)
    assert all(t["status"] == "open" for t in r.json())


async def test_search_status_all_includes_completed(client, ...) -> None:
    ...
    r = await client.get(
        "/tickets/search", params={"site": "MBMT", "status": "all"}, headers=h
    )
    assert any(t["status"] == "completed" for t in r.json())


async def test_search_matches_source_entry_display_id(client, ...) -> None:
    h = await auth_headers(client)
    bd = await client.post("/entries", json=breakdown(), headers=h)
    display_id = bd.json()["display_id"]
    r = await client.get(
        "/tickets/search", params={"site": "MBMT", "q": display_id}, headers=h
    )
    assert len(r.json()) == 1
    assert r.json()[0]["display_id"] == display_id
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && pytest tests/test_tickets.py -k "search_" -v`
Expected: FAIL — `status=all` request either 422s (unknown param) or still
excludes completed; `display_id` key missing from response.

- [ ] **Step 3: Implement**

`backend/app/schemas/ticket.py`, `TicketSearchResult`:

```python
    display_id: str
```

`backend/app/services/tickets.py`, `search_tickets`: add a `status:
Literal["open", "completed", "all"] = "open"` parameter; the two existing
`Ticket.status == TicketStatus.open` filter clauses (one per sub-query,
entry-sourced and inspection-sourced) become conditional:

```python
def _status_clause(status: str):
    if status == "all":
        return True
    target = TicketStatus.open if status == "open" else TicketStatus.completed
    return Ticket.status == target
```

apply `.where(..., _status_clause(status))` in place of the hardcoded
`Ticket.status == TicketStatus.open` in both sub-queries. Also extend the
existing `q` free-text filter: alongside whatever it already matches
(title/entry fields), add an `Entry.display_id.ilike(f"%{q}%")` clause via
`or_` — check the exact current `q` filter shape before editing (it may
already need `Entry` joined, which the entry-sourced sub-query already
does).

`backend/app/api/tickets.py`, `search`: add the `status` query param and
thread it through; build `display_id` for each result as
`t.source_entry.display_id if t.source_entry is not None else t.display_id`
(the inspection-sourced fallback — never surfaced by this plan's UI, but
keeps the endpoint from crashing if called for one, per Review Focus).

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && pytest tests/test_tickets.py -k "search_" -v`
Expected: PASS

- [ ] **Step 5: Full backend suite**

Run: `cd backend && make test-backend`
Expected: green.

- [ ] **Step 6: Commit**

```bash
git add backend/app/api/tickets.py backend/app/services/tickets.py \
  backend/app/schemas/ticket.py backend/tests/test_tickets.py
git commit -m "tickets/search: status filter (open/completed/all) and display-id match"
```

---

## Task 6: `GET /tickets/{ticket_id}` — Ticket Detail endpoint

**Files:**
- Modify: `backend/app/api/tickets.py`
- Modify: `backend/app/schemas/ticket.py`
- Test: `backend/tests/test_tickets.py`

**Interfaces:**
- Consumes: `serialize_entry` (existing, `services/entries.py`),
  `linked_sessions` (existing, generalize its call site if it's currently
  Breakdown-only plumbing — check `services/tickets.py` /
  wherever it's assembled before this task, per the earlier session's
  "Traceability polish" work).
- Produces: `TicketDetailOut` schema — `ticket_id`, `display_id` (source
  entry's, per Global Constraints), `status`, `source_entry: EntryOut`,
  `linked_sessions: list[...]`, `photos: list[EntryPhotoOut]` (stub empty
  list until Task 8 exists; do not block this task on Task 8 — an empty
  list is a valid, correct response until photos exist).

- [ ] **Step 1: Write the failing test**

```python
# backend/tests/test_tickets.py -- add
async def test_get_ticket_detail_returns_source_entry_and_sessions(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    bd = await client.post("/entries", json=breakdown(), headers=h)
    bd_id = bd.json()["id"]
    from tests.test_entries import resolve_via_work_done
    await resolve_via_work_done(client, h, bd_id)
    found = await client.get(
        "/tickets/search", params={"site": "MBMT", "status": "all", "q": bd.json()["display_id"]},
        headers=h,
    )
    ticket_id = found.json()[0]["ticket_id"]
    detail = await client.get(f"/tickets/{ticket_id}", headers=h)
    assert detail.status_code == 200, detail.text
    body = detail.json()
    assert body["display_id"] == bd.json()["display_id"]
    assert body["source_entry"]["id"] == bd_id
    assert len(body["linked_sessions"]) == 1


async def test_get_ticket_detail_404s_for_another_site(client: AsyncClient) -> None:
    h = await auth_headers(client)
    bd = await client.post("/entries", json=breakdown(), headers=h)
    found = await client.get(
        "/tickets/search",
        params={"site": "MBMT", "q": bd.json()["display_id"]}, headers=h,
    )
    ticket_id = found.json()[0]["ticket_id"]
    other = await other_site_auth_headers(client)  # match this file's existing
    # cross-site fixture helper name -- read the file for the real one.
    r = await client.get(f"/tickets/{ticket_id}", headers=other)
    assert r.status_code == 404
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && pytest tests/test_tickets.py -k "ticket_detail" -v`
Expected: FAIL — 404 Not Found (route doesn't exist).

- [ ] **Step 3: Implement**

```python
# backend/app/schemas/ticket.py -- add
class TicketDetailOut(BaseModel):
    ticket_id: str
    display_id: str
    status: str
    source_entry: EntryOut | None
    linked_sessions: list[dict[str, Any]]  # match whatever shape
    # linked_sessions already returns elsewhere -- reuse its element type,
    # don't invent a new one.
    photos: list[dict[str, Any]] = []
```

```python
# backend/app/api/tickets.py -- add
@router.get("/{ticket_id}", response_model=TicketDetailOut)
async def get_ticket(
    ticket_id: str, user: CurrentUser, session: SessionDep
) -> TicketDetailOut:
    ticket = await session.get(Ticket, ticket_id)
    if ticket is None:
        raise NotFound("Ticket not found")
    site_code = (
        ticket.source_entry.site_code
        if ticket.source_entry is not None
        else ticket.source_inspection_result.inspection.entry_site_code  # match real attr
    )
    assert_site_access(user, site_code)  # match this file's existing site-check helper name
    entry_out = (
        EntryOut(**svc_entries.serialize_entry(ticket.source_entry))
        if ticket.source_entry is not None
        else None
    )
    sessions = await svc.linked_sessions(session, ticket)  # match real existing call shape
    display_id = (
        ticket.source_entry.display_id
        if ticket.source_entry is not None
        else ticket.display_id
    )
    return TicketDetailOut(
        ticket_id=ticket.id,
        display_id=display_id,
        status=ticket.status.value,
        source_entry=entry_out,
        linked_sessions=sessions,
        photos=[],  # Task 8 fills this in
    )
```

Read `services/tickets.py` and `api/entries.py` first to find the *actual*
names of the site-access assertion helper and the linked-sessions
assembly function/shape already in use (the earlier session's ledger
mentions `linked_sessions` generalization) — the pseudocode above names
them by best guess; match reality, not this text, on both counts. This is
exactly the class of "declared 404" behavior Review Focus calls out —
write the cross-site test in Step 1 against whatever that helper actually
does, don't assume.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && pytest tests/test_tickets.py -k "ticket_detail" -v`
Expected: PASS 2/2

- [ ] **Step 5: Full backend suite**

Run: `cd backend && make test-backend`
Expected: green.

- [ ] **Step 6: Commit**

```bash
git add backend/app/api/tickets.py backend/app/schemas/ticket.py backend/tests/test_tickets.py
git commit -m "Add GET /tickets/{id} -- source entry + full session history"
```

---

## Task 7: Work Done `attended_time`

**Files:**
- Modify: `backend/app/models/entry.py`
- Modify: `backend/app/schemas/entry.py`
- Modify: `backend/app/services/entries.py`
- Create: `backend/alembic/versions/0038_work_done_attended_time.py`
- Test: `backend/tests/test_entries.py`

**Interfaces:**
- Consumes: `mark_attended(ticket, at)` (existing, `services/tickets.py`),
  `_session_moment(entry, time)` (existing).

- [ ] **Step 1: Write the failing test**

```python
# backend/tests/test_entries.py -- add
async def test_attended_time_is_used_when_provided(client: AsyncClient) -> None:
    h = await auth_headers(client)
    bd = await client.post("/entries", json=breakdown(), headers=h)
    bd_id = bd.json()["id"]
    found = await client.get(
        "/tickets/search", params={"site": "MBMT", "q": bd.json()["display_id"]},
        headers=h,
    )
    ticket_id = found.json()[0]["ticket_id"]
    payload = work_done()
    payload["data"]["ticket_id"] = ticket_id
    payload["data"]["attended_time"] = "11:05"
    r = await client.post("/entries", json=payload, headers=h)
    assert r.status_code == 201, r.text
    entry = await client.get(f"/entries/{bd_id}", headers=h)
    assert entry.json()["data"]["attended_time"] == "11:05"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && pytest tests/test_entries.py -k attended_time_is_used -v`
Expected: FAIL — either 422 (unknown field, if extra="forbid" catches it
before this) or the breakdown's `attended_time` reflects the session's
submission time instead of `11:05`.

- [ ] **Step 3: Implement**

`backend/app/schemas/entry.py`, `WorkDoneData`:

```python
    attended_time: HHMM | None = None
```

`backend/app/models/entry.py`, `WorkDoneEntry`:

```python
    attended_time: Mapped[time_t | None] = mapped_column(Time, nullable=True)
```

`backend/app/services/entries.py`, the block calling `mark_attended` (the
one with the comment about "the mechanic reached the bus when this session
started"):

```python
    mark_attended(ticket, _session_moment(entry, detail.attended_time))
```

(replacing the bare `_session_moment(entry)` call — `_session_moment`
already accepts an optional time argument per `completion_time`'s call
one line below it, so this is a one-line change, not a new code path.)
Also persist `detail.attended_time` onto the `WorkDoneEntry` row itself
(wherever the other `WorkDoneEntry` fields are assigned from `detail` —
match that pattern) so it round-trips on GET.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && pytest tests/test_entries.py -k attended_time -v`
Expected: PASS

- [ ] **Step 5: Migration**

```python
# backend/alembic/versions/0038_work_done_attended_time.py
"""work_done_entries.attended_time -- explicit, mirrors completion_time.

Revision ID: 0038
Revises: 0037
Create Date: 2026-09-28
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa

revision = "0038"
down_revision = "0037"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "work_done_entries", sa.Column("attended_time", sa.Time(), nullable=True)
    )


def downgrade() -> None:
    op.drop_column("work_done_entries", "attended_time")
```

- [ ] **Step 6: Run migration and full backend test suite**

Run: `cd backend && alembic upgrade head && make test-backend`
Expected: green.

- [ ] **Step 7: Commit**

```bash
git add backend/app/models/entry.py backend/app/schemas/entry.py \
  backend/app/services/entries.py backend/alembic/versions/0038_work_done_attended_time.py \
  backend/tests/test_entries.py
git commit -m "Add explicit Work Done attended_time, mirroring completion_time"
```

---

## Task 8: Multi-photo (`entry_photos`), replacing the single-photo endpoints

**Files:**
- Modify: `backend/app/models/entry.py`
- Create: `backend/app/models/entry_photo.py`
- Modify: `backend/app/api/entries.py`
- Modify: `backend/app/schemas/entry.py`
- Create: `backend/alembic/versions/0039_entry_photos.py`
- Test: `backend/tests/test_entries.py`

**Interfaces:**
- Consumes: `storage.validate_photo`, `storage.save_photo`,
  `storage.delete_photo` (existing, unchanged).
- Produces: `EntryPhotoOut {id, url, caption}`. `POST /entries/{id}/photos`
  → `list[EntryPhotoOut]`. `DELETE /entries/{id}/photos/{photo_id}` → 204.
  Task 6's `TicketDetailOut.photos` consumes this shape.

- [ ] **Step 1: Write the failing test**

```python
# backend/tests/test_entries.py -- add
async def test_upload_two_photos_produces_two_rows(client: AsyncClient) -> None:
    h = await auth_headers(client)
    bd = await client.post("/entries", json=breakdown(), headers=h)
    entry_id = bd.json()["id"]
    jpeg = b"\xff\xd8\xff\xe0" + b"0" * 100  # minimal-enough fake JPEG bytes;
    # match whatever byte fixture the OLD single-photo test in this file
    # already uses for `validate_photo` to accept -- reuse it, don't
    # reinvent a fixture that might fail validate_photo's real checks.
    r1 = await client.post(
        f"/entries/{entry_id}/photos", headers=h,
        files={"photo": ("a.jpg", jpeg, "image/jpeg")},
    )
    r2 = await client.post(
        f"/entries/{entry_id}/photos", headers=h,
        files={"photo": ("b.jpg", jpeg, "image/jpeg")},
    )
    assert r1.status_code == 201, r1.text
    assert len(r2.json()) == 2


async def test_delete_one_photo_leaves_the_other(client: AsyncClient) -> None:
    h = await auth_headers(client)
    bd = await client.post("/entries", json=breakdown(), headers=h)
    entry_id = bd.json()["id"]
    jpeg = b"\xff\xd8\xff\xe0" + b"0" * 100
    photos = (
        await client.post(
            f"/entries/{entry_id}/photos", headers=h,
            files={"photo": ("a.jpg", jpeg, "image/jpeg")},
        )
    ).json()
    photos = (
        await client.post(
            f"/entries/{entry_id}/photos", headers=h,
            files={"photo": ("b.jpg", jpeg, "image/jpeg")},
        )
    ).json()
    to_delete = photos[0]["id"]
    r = await client.delete(f"/entries/{entry_id}/photos/{to_delete}", headers=h)
    assert r.status_code == 204
    remaining = await client.get(f"/entries/{entry_id}", headers=h)
    assert len(remaining.json()["photos"]) == 1
    assert remaining.json()["photos"][0]["id"] != to_delete
```

Find the *existing* single-photo test(s) in `test_entries.py` in the same
pass — Step 3 below deletes the endpoints they exercise, so those tests
must be rewritten (not just left to rot) to hit the new endpoints and
assert the same one-photo behavior still holds for a register this plan
doesn't otherwise touch (per Review Focus — use Coolant).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && pytest tests/test_entries.py -k "photo" -v`
Expected: FAIL — 404 (routes don't exist yet).

- [ ] **Step 3: Implement**

```python
# backend/app/models/entry_photo.py
from __future__ import annotations

from sqlalchemy import ForeignKey, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, created_at_col, new_uuid


class EntryPhoto(Base):
    __tablename__ = "entry_photos"

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_uuid)
    entry_id: Mapped[str] = mapped_column(
        String(32), ForeignKey("entries.id", ondelete="CASCADE"), nullable=False
    )
    storage_key: Mapped[str] = mapped_column(String(255), nullable=False)
    url: Mapped[str] = mapped_column(String(500), nullable=False)
    caption: Mapped[str | None] = mapped_column(String(255), nullable=True)
    uploaded_by_id: Mapped[str | None] = mapped_column(
        String(32), ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
    created_at = created_at_col()
```

Remove `Entry.photo_key` / `Entry.photo_url` columns; add
`photos: Mapped[list[EntryPhoto]] = relationship(lazy="selectin", order_by=EntryPhoto.created_at)`.

`backend/app/api/entries.py`: replace `upload_photo`/`delete_photo`
entirely:

```python
@router.post("/{entry_id}/photos", response_model=list[EntryPhotoOut], status_code=201)
async def upload_photo(
    entry_id: str, user: CurrentUser, session: SessionDep,
    photo: Annotated[UploadFile, File()],
) -> list[EntryPhotoOut]:
    entry = await _load(session, entry_id)
    if not _can_edit(user, entry):
        raise Forbidden("You can only attach photos to your own entries")
    content = await photo.read()
    ext = storage.validate_photo(photo.content_type, len(content))
    key, url = storage.save_photo(entry.id, content, ext)
    session.add(EntryPhoto(entry_id=entry.id, storage_key=key, url=url, uploaded_by_id=user.id))
    await audit.record(
        session, actor_id=user.id, action=AuditAction.entry_photo_set,
        object_type="entry", object_id=entry.id, after={"photo_url": url},
    )
    await session.commit()
    await session.refresh(entry, attribute_names=["photos"])
    return [EntryPhotoOut(id=p.id, url=p.url, caption=p.caption) for p in entry.photos]


@router.delete("/{entry_id}/photos/{photo_id}", status_code=204, response_model=None)
async def delete_photo(
    entry_id: str, photo_id: str, user: CurrentUser, session: SessionDep
) -> None:
    entry = await _load(session, entry_id)
    if not _can_edit(user, entry):
        raise Forbidden("You can only remove photos from your own entries")
    photo = await session.get(EntryPhoto, photo_id)
    if photo is None or photo.entry_id != entry_id:
        raise NotFound("Photo not found")
    key = photo.storage_key
    await session.delete(photo)
    await audit.record(
        session, actor_id=user.id, action=AuditAction.entry_photo_deleted,
        object_type="entry", object_id=entry.id,
    )
    await session.commit()
    storage.delete_photo(key)
```

`backend/app/schemas/entry.py`: add `EntryPhotoOut {id: str, url: str,
caption: str | None}`; add `photos: list[EntryPhotoOut] = []` to
`EntryOut` (read directly from `entry.photos`, not from `*Data` — photos
are entry-level, not register-specific, matching how `photo_url` worked
before).

`serialize_entry` (`services/entries.py`): stop reading
`entry.photo_key`/`photo_url`; populate `photos` from `entry.photos`
instead.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && pytest tests/test_entries.py -k "photo" -v`
Expected: PASS, including the rewritten former-single-photo test(s).

- [ ] **Step 5: Migration**

```python
# backend/alembic/versions/0039_entry_photos.py
"""entry_photos -- one-to-many, replaces entries.photo_key/photo_url.

Revision ID: 0039
Revises: 0038
Create Date: 2026-09-28
"""
from __future__ import annotations

import uuid

from alembic import op
import sqlalchemy as sa

revision = "0039"
down_revision = "0038"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "entry_photos",
        sa.Column("id", sa.String(length=32), primary_key=True),
        sa.Column(
            "entry_id", sa.String(length=32),
            sa.ForeignKey("entries.id", ondelete="CASCADE"), nullable=False,
        ),
        sa.Column("storage_key", sa.String(length=255), nullable=False),
        sa.Column("url", sa.String(length=500), nullable=False),
        sa.Column("caption", sa.String(length=255), nullable=True),
        sa.Column(
            "uploaded_by_id", sa.String(length=32),
            sa.ForeignKey("users.id", ondelete="SET NULL"), nullable=True,
        ),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    conn = op.get_bind()
    rows = conn.execute(
        sa.text(
            "SELECT id, photo_key, photo_url FROM entries WHERE photo_key IS NOT NULL"
        )
    ).fetchall()
    for entry_id, photo_key, photo_url in rows:
        conn.execute(
            sa.text(
                "INSERT INTO entry_photos (id, entry_id, storage_key, url, created_at) "
                "VALUES (:id, :entry_id, :key, :url, now())"
            ),
            {"id": uuid.uuid4().hex, "entry_id": entry_id, "key": photo_key, "url": photo_url},
        )
    op.drop_column("entries", "photo_key")
    op.drop_column("entries", "photo_url")


def downgrade() -> None:
    op.add_column("entries", sa.Column("photo_url", sa.String(length=1024), nullable=True))
    op.add_column("entries", sa.Column("photo_key", sa.String(length=255), nullable=True))
    op.drop_table("entry_photos")
```

- [ ] **Step 6: Run migration and full backend test suite**

Run: `cd backend && alembic upgrade head && make test-backend`
Expected: green.

- [ ] **Step 7: Commit**

```bash
git add backend/app/models/entry.py backend/app/models/entry_photo.py \
  backend/app/api/entries.py backend/app/schemas/entry.py \
  backend/alembic/versions/0039_entry_photos.py backend/tests/test_entries.py
git commit -m "Replace single-photo endpoints with multi-photo entry_photos"
```

---

## Task 9: Location capture on Breakdown / Driver Complaint

**Files:**
- Modify: `backend/app/models/entry.py`
- Modify: `backend/app/models/enums.py`
- Modify: `backend/app/schemas/entry.py`
- Create: `backend/alembic/versions/0040_location_capture.py`
- Test: `backend/tests/test_entries.py`

**Interfaces:**
- Produces: `BreakdownData`/`DriverComplaintData.latitude`, `.longitude`,
  `.location_source: Literal["gps","map","manual"] | None`.

- [ ] **Step 1: Write the failing test**

```python
# backend/tests/test_entries.py -- add
async def test_breakdown_location_round_trips(client: AsyncClient) -> None:
    h = await auth_headers(client)
    payload = breakdown()
    payload["data"]["latitude"] = "19.1197"
    payload["data"]["longitude"] = "72.8468"
    payload["data"]["location_source"] = "gps"
    r = await client.post("/entries", json=payload, headers=h)
    assert r.status_code == 201, r.text
    assert r.json()["data"]["location_source"] == "gps"
    entry = await client.get(f"/entries/{r.json()['id']}", headers=h)
    assert entry.json()["data"]["latitude"] == "19.1197"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && pytest tests/test_entries.py -k location_round_trips -v`
Expected: FAIL — 422 (unrecognized field, `extra="forbid"`).

- [ ] **Step 3: Implement**

`backend/app/models/enums.py`:

```python
class LocationSource(StrEnum):
    gps = "gps"
    map = "map"
    manual = "manual"

LOCATION_SOURCE_ENUM = "location_source"
```

`backend/app/models/entry.py`, on both `BreakdownEntry` and
`DriverComplaintEntry`:

```python
    latitude: Mapped[Decimal | None] = mapped_column(Numeric(9, 6), nullable=True)
    longitude: Mapped[Decimal | None] = mapped_column(Numeric(9, 6), nullable=True)
    location_source: Mapped[LocationSource | None] = mapped_column(
        Enum(LocationSource, name=LOCATION_SOURCE_ENUM,
             values_callable=lambda e: [m.value for m in e]),
        nullable=True,
    )
```

`backend/app/schemas/entry.py`, `BreakdownData` and `DriverComplaintData`:

```python
    latitude: Decimal | None = None
    longitude: Decimal | None = None
    location_source: Literal["gps", "map", "manual"] | None = None
```

Wire both new columns through wherever each register's `*Entry(...)` is
constructed from its `*Data` in `services/entries.py` — match the existing
pattern for a sibling optional field like `loss_km` on `BreakdownEntry`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && pytest tests/test_entries.py -k location_round_trips -v`
Expected: PASS

- [ ] **Step 5: Migration**

```python
# backend/alembic/versions/0040_location_capture.py
"""latitude/longitude/location_source on breakdown_entries and
driver_complaint_entries -- additive to the existing text location/route.

Revision ID: 0040
Revises: 0039
Create Date: 2026-09-28
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa

revision = "0040"
down_revision = "0039"
branch_labels = None
depends_on = None

_location_source = sa.Enum(
    "gps", "map", "manual", name="location_source"
)


def upgrade() -> None:
    _location_source.create(op.get_bind(), checkfirst=True)
    for table in ("breakdown_entries", "driver_complaint_entries"):
        op.add_column(table, sa.Column("latitude", sa.Numeric(9, 6), nullable=True))
        op.add_column(table, sa.Column("longitude", sa.Numeric(9, 6), nullable=True))
        op.add_column(
            table,
            sa.Column("location_source", _location_source, nullable=True),
        )


def downgrade() -> None:
    for table in ("breakdown_entries", "driver_complaint_entries"):
        op.drop_column(table, "location_source")
        op.drop_column(table, "longitude")
        op.drop_column(table, "latitude")
    _location_source.drop(op.get_bind(), checkfirst=True)
```

- [ ] **Step 6: Run migration and full backend test suite**

Run: `cd backend && alembic upgrade head && make test-backend`
Expected: green.

- [ ] **Step 7: Commit**

```bash
git add backend/app/models/entry.py backend/app/models/enums.py \
  backend/app/schemas/entry.py backend/alembic/versions/0040_location_capture.py \
  backend/tests/test_entries.py
git commit -m "Add GPS/manual location capture to Breakdown and Driver Complaint"
```

---

## Task 10: Flutter — repository/model updates for the backend changes

**Files:**
- Modify: `app/lib/models/entry.dart`
- Modify: `app/lib/models/ticket.dart`
- Modify: `app/lib/data/repositories.dart`
- Modify: `app/lib/data/api/api_repositories.dart`
- Modify: `app/test/support/fake_repositories.dart`
- Test: `app/test/api_contract_test.dart`, `app/test/support/fake_repositories_test.dart` (or wherever fakes are exercised — match existing file)

**Interfaces:**
- Consumes: Tasks 2–9's response shapes.
- Produces: `RegisterEntry.displayId`, `RegisterEntry.photos:
  List<EntryPhoto>` (replacing `photoUrl`), `TicketSearchResult.displayId`.
  `EntryRepository.attachPhoto` returns `Future<List<EntryPhoto>>`;
  `removePhoto(entryId, photoId)`. `TicketRepository.get(ticketId)`.

This task is pure model/repository plumbing — no screens yet (Tasks 11–15
build on top of it). Do it as straight TDD against the model/repository
layer's existing unit tests, mirroring exactly how the prior session added
`attendeeLabels`/`sparePartLabels` to `field_map.dart` (same file, same
kind of change, this task extends `models/entry.dart` and
`repositories.dart` instead).

- [ ] **Step 1: Write the failing tests**

```dart
// app/test/api_contract_test.dart -- add
test('entry display_id and multi-photo list parse from wire', () {
  final entry = RegisterEntry.fromJson(<String, dynamic>{
    'id': 'e1', 'register_id': 'breakdown', 'display_id': 'BD-2026-000001',
    'date': '2026-09-28', 'data': <String, dynamic>{},
    'photos': <dynamic>[
      <String, dynamic>{'id': 'p1', 'url': 'http://x/p1.jpg', 'caption': null},
    ],
    // ...whatever other required fields RegisterEntry.fromJson needs --
    // copy them from a neighboring existing test in this file rather than
    // guessing the full required set.
  });
  expect(entry.displayId, 'BD-2026-000001');
  expect(entry.photos, hasLength(1));
  expect(entry.photos.first.url, 'http://x/p1.jpg');
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/api_contract_test.dart --plain-name "display_id and multi-photo"`
Expected: FAIL — `NoSuchMethodError: displayId` / `photos`.

- [ ] **Step 3: Implement**

`app/lib/models/entry.dart`: add `displayId` (required, parsed from
`display_id`); add a small `EntryPhoto {id, url, caption}` class; replace
`photoUrl: String?` with `photos: List<EntryPhoto>` (a
`get photoUrl => photos.isEmpty ? null : photos.first.url` convenience
getter keeps every existing call site that only ever showed one photo
compiling unchanged — check for such call sites before deciding whether to
keep or remove it; keep it if anything outside the three touched
registers reads `photoUrl` directly).

`app/lib/models/ticket.dart`: add `displayId` to `TicketSearchResult`
(parsed from `display_id`), plus whatever context fields Task 11 needs —
add them now since this is the shared parsing task: `busNo`, `driverName`,
`route`, `defectText` (nullable, only present when the backend result
includes them — Task 5's endpoint doesn't add these fields yet; if they're
not on the wire yet, make them nullable here and Task 11 is the one that
actually needs the backend to send them — **flag this**: re-check Task 5's
implementation before this step; if `search_tickets`'s response doesn't
carry them, add a small backend change here rather than blocking Task 11 on
a backend edit disguised as a frontend task. Prefer fixing it forward now:
extend `TicketSearchResult` (backend schema, Task 5's file) with
`bus_no: str`, `driver_name: str | None`, `route: str | None`,
`defect_text: str`, sourced from `t.source_entry` the same way
`ticket_title` already reads register-specific fields — one small
backend addition, same files Task 5 touched, folded into this task's
commit in Step 6 below).

`app/lib/data/repositories.dart`: change `attachPhoto`'s return type to
`Future<List<EntryPhoto>>`; change `removePhoto(String entryId)` to
`removePhoto(String entryId, String photoId)`; add
`Future<TicketDetail> get(String ticketId)` to `TicketRepository` (new
`TicketDetail` model class mirroring `TicketDetailOut`'s shape).

`app/lib/data/api/api_repositories.dart`: update `ApiEntryRepository` and
`ApiTicketRepository` to match — `attachPhoto` posts to
`/entries/$id/photos` (plural) and parses the list response;
`removePhoto` deletes `/entries/$id/photos/$photoId`; `TicketRepository.get`
calls `GET /tickets/$id`.

`app/test/support/fake_repositories.dart`: mirror every signature change —
`FakeEntryRepository`'s in-memory photo list becomes a real list per entry
instead of a single nullable field; `FakeTicketRepository.get` returns a
constructed `TicketDetail` from its in-memory store.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && flutter test test/api_contract_test.dart`
Expected: PASS.

- [ ] **Step 5: Full Flutter test suite**

Run: `cd app && flutter analyze && flutter test`
Expected: `flutter analyze` clean (0 issues — this repo's CI treats
warnings as failures); every existing test that referenced `photoUrl` as a
setter, or called `removePhoto(id)` with one argument, needs updating —
fix each at its call site, these are compile errors, not silent breakage,
so the compiler finds them all.

- [ ] **Step 6: Commit**

```bash
git add app/lib/models/entry.dart app/lib/models/ticket.dart \
  app/lib/data/repositories.dart app/lib/data/api/api_repositories.dart \
  app/test/support/fake_repositories.dart app/test/api_contract_test.dart \
  backend/app/schemas/ticket.py backend/app/api/tickets.py backend/tests/test_tickets.py
git commit -m "Flutter models/repositories for display_id, multi-photo, ticket context"
```

(This commit includes the small backend addition from Step 3 if it turned
out to be needed — one commit, since it's a single small addition
discovered while doing this task, not a separately planned backend task.)

---

## Task 11: Work Done form — reposition and rewrite the ticket-link section

**Files:**
- Modify: `app/lib/screens/register_form_screen.dart`
- Test: `app/test/entries_filter_test.dart` or a new
  `app/test/register_form_screen_test.dart` if this repo has widget tests
  for this screen already — check before choosing the file.

**Interfaces:**
- Consumes: Task 10's `TicketSearchResult` context fields,
  `ticketSearchProvider` (existing).

- [ ] **Step 1: Write the failing test**

This is a widget-level behavior change (field reposition + prefill display)
best verified by a widget test if this repo has a harness for
`RegisterFormScreen` already (check `app/test/` for one before writing a
new one from scratch — matching existing patterns beats inventing a new
test style). Minimum required assertions:

```dart
testWidgets('picking a ticket shows read-only linked-ticket context, not editable fields', (tester) async {
  // Pump RegisterFormScreen(registerId: 'work') with a ProviderScope
  // overriding ticketRepositoryProvider with a FakeTicketRepository seeded
  // with one breakdown-sourced ticket (bus MH04LY9683, driver DRV-1088).
  // Type into the ticket search field, tap the one result.
  // Assert: a Text widget showing 'MH04LY9683' is now present and NOT
  // inside an editable TextField -- the bus field's own TextField (if the
  // register still renders one) must show it is uneditable when linked,
  // or (simpler, matching the spec) the bus/driver/route/defect block is
  // rendered as plain read-only text, not form controls, once a ticket is
  // linked.
});
```

Match this repo's actual existing widget-test scaffolding (`ProviderScope`
overrides, pumping conventions) from a neighboring test file rather than
the sketch above — the sketch states the behavior to assert, not the exact
harness code.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test <chosen file> --plain-name "linked-ticket context"`
Expected: FAIL — no such context block exists yet (current code only sets
`ticketId` and shows a title badge).

- [ ] **Step 3: Implement**

In `register_form_screen.dart`:

1. Move the `_TicketLinkSection` widget instantiation from its current
   position (after `_UnitSection`, before `_SparePartsSection`) to
   immediately after the Shift field inside the main field grid / directly
   above it — read the surrounding layout code first to find the exact
   insertion point the Shift field renders at, and move the section call
   there. The section widget's own internals stay the async-search +
   picked-badge pattern already built (do not rewrite this into
   `AppMultiSelect` — that widget filters a pre-loaded in-memory list, the
   ticket picker needs the existing live server search via
   `ticketSearchProvider`; keep that architecture, just restyle/reposition
   it into a single field rather than register-filter + separate text
   field).
2. Merge the register-filter `AppSelect` and the free-text `AppTextField`
   into one text field whose `onChanged` drives `_query`, with the
   register-filter becoming a small set of filter chips above the results
   (or drop the register filter for the Work Done context entirely — Work
   Done can link to any ticketable register, and now that free text
   matches `display_id` too, users type `BD-` or `DC-` to narrow instead of
   picking a register first; this is a legitimate simplification, do it).
3. On pick (`onSet('ticketId', r.ticketId)`), also render a new read-only
   block below the search field using the context fields from Task 10
   (`r.busNo`, `r.driverName`, `r.route`, `r.defectText`) as plain
   `Text` widgets under labels ("Bus", "Driver", "Route", "Reported"), not
   form fields — this is what "no need to fill all the data again" means:
   informational, not re-editable here (it's still editable at its source,
   via that entry's own Edit action).
4. Everything else in this section (attending mechanics, completion
   checkbox/time) is unchanged in behavior, just visually below the new
   context block instead of below a title badge.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && flutter test <chosen file>`
Expected: PASS.

- [ ] **Step 5: Full Flutter suite**

Run: `cd app && flutter analyze && flutter test`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add app/lib/screens/register_form_screen.dart app/test/
git commit -m "Work Done: ticket link moves to top, prefills context, searches by display id"
```

---

## Task 12: Work Done form — Attended time field

**Files:**
- Modify: `app/lib/screens/register_form_screen.dart`
- Modify: `app/lib/data/api/field_map.dart`
- Test: `app/test/api_contract_test.dart`

**Interfaces:**
- Consumes: Task 7's `attended_time` API field.

- [ ] **Step 1: Write the failing test**

```dart
// app/test/api_contract_test.dart -- add
test('attended_time maps to/from wire on work done', () {
  final wire = RegisterFieldMap.toWire('work', <String, String>{'attendedTime': '11:05'});
  expect(wire['attended_time'], '11:05');
  final back = RegisterFieldMap.fromWire('work', <String, dynamic>{'attended_time': '11:05'});
  expect(back['attendedTime'], '11:05');
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/api_contract_test.dart --plain-name attended_time`
Expected: FAIL — key not in `_toWire['work']` map, so `toWire` drops it.

- [ ] **Step 3: Implement**

`app/lib/data/api/field_map.dart`, `_toWire['work']`: add
`'attendedTime': 'attended_time'`.

`app/lib/screens/register_form_screen.dart`: add an "Attended time" time
field next to the existing "Attended details" field in the Work Done
section, writing to `attendedTime` via `widget.onSet`. Match the existing
time-field widget this form already uses for `completionTime` (same
picker component, same validation shape).

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && flutter test test/api_contract_test.dart --plain-name attended_time`
Expected: PASS.

- [ ] **Step 5: Full Flutter suite**

Run: `cd app && flutter analyze && flutter test`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add app/lib/screens/register_form_screen.dart app/lib/data/api/field_map.dart \
  app/test/api_contract_test.dart
git commit -m "Add Attended time field to Work Done form"
```

---

## Task 13: Multi-photo gallery widget

**Files:**
- Modify: `app/lib/screens/register_form_screen.dart`
- Test: matches Task 11's chosen widget-test file.

**Interfaces:**
- Consumes: Task 10's `List<EntryPhoto>` / `attachPhoto`/`removePhoto`
  signatures.

- [ ] **Step 1: Write the failing test**

```dart
testWidgets('picking two photos shows two thumbnails, removing one leaves one', (tester) async {
  // Pump the form for register 'breakdown'. Simulate two picks via the
  // existing photo-pick callback/test hook this screen already exposes
  // for its single-photo test (find and reuse it). Assert two thumbnail
  // widgets render; tap one's remove control; assert one remains.
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test <file> --plain-name "two photos"`
Expected: FAIL — current state (`_photoBytes`/`_photoFilename`, singular)
can't hold two.

- [ ] **Step 3: Implement**

Replace `_photoBytes`/`_photoFilename`/`_photoRemoved` (singular) with:

```dart
  final List<_PendingPhoto> _newPhotos = <_PendingPhoto>[];
  final Set<String> _removedPhotoIds = <String>{};
```

(`_PendingPhoto {filename, bytes}` — a small local class.) `_hasPhoto`
becomes a photo *count* getter; the single add/remove callbacks become
`_onAddPhoto` (appends) and `_onRemovePhoto(String photoId)` /
`_onRemoveNewPhoto(int index)` (removes a not-yet-saved pick vs. marks an
existing one for removal). On save: for every `_newPhotos` entry, call
`attachPhoto`; for every id in `_removedPhotoIds`, call
`removePhoto(entryId, id)` — same "second, independent action after the
entry is saved" comment this code already has, just looped instead of
singular.

Gate the gallery UI (multi-pick, multiple thumbnails) to
`register.id`  in `{'breakdown', 'complaint', 'work'}`; every other
register keeps rendering exactly the widget it does today, backed by the
same list but only ever showing/allowing index 0 (a one-line difference in
which widget builder runs, not a behavior change for those registers).

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && flutter test <file>`
Expected: PASS.

- [ ] **Step 5: Full Flutter suite**

Run: `cd app && flutter analyze && flutter test`
Expected: clean — this is the step most likely to surface compile errors
in other tests that poked the old singular photo state directly; fix each.

- [ ] **Step 6: Commit**

```bash
git add app/lib/screens/register_form_screen.dart app/test/
git commit -m "Multi-photo gallery for Breakdown, Driver Complaint, Work Done"
```

---

## Task 14: Tickets list screen

**Files:**
- Create: `app/lib/screens/tickets_screen.dart`
- Modify: `app/lib/router.dart`
- Modify: `app/lib/state/providers.dart` (status-aware search provider variant, or extend the existing family key)
- Test: create `app/test/tickets_screen_test.dart` if a screen-test
  pattern exists elsewhere in `app/test/`; otherwise a focused
  provider-level test is the minimum bar — check precedent first.

**Interfaces:**
- Consumes: Task 10's `TicketRepository.search` (existing, extend its
  family key with `status`), Task 5's backend `status` param.

- [ ] **Step 1: Write the failing test**

```dart
// app/test/ (match existing provider-test file, e.g. entries_filter_test.dart style)
test('ticketSearchProvider passes through the status filter', () async {
  // Using FakeTicketRepository seeded with one open and one completed
  // ticket: read ticketSearchProvider with status: 'all' and assert both
  // appear; with the default/'open' status assert only the open one does.
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test <file> --plain-name status`
Expected: FAIL — `ticketSearchProvider`'s family key has no `status` field
yet, or `FakeTicketRepository.search` ignores it.

- [ ] **Step 3: Implement**

Extend `ticketSearchProvider`'s family key record with `status: String`
(default `'open'` at call sites that don't care); thread it into
`TicketRepository.search` (interface, API impl, fake) as a new named
param.

`app/lib/router.dart`: add `Routes.tickets = '/tickets'` and register the
route to a new `TicketsScreen`.

`app/lib/screens/tickets_screen.dart`: a list (site-scoped via
`selectedSiteProvider`, same pattern `registers_screen.dart` uses),
status filter chips (Open / Completed / All), a search field (free text or
display id, same field pattern as the Work Done ticket picker), each row
tappable to `Routes.ticketDetail(ticketId)` (Task 15).

Add a nav entry point to reach `/tickets` — check `shell_screen.dart` (the
app shell's nav rail/drawer) for where other top-level routes
(`Routes.registers`, `Routes.breakdowns`, ...) are listed, and add Tickets
there in the same style. **This is exactly the kind of wiring step a
"disconnected piece" review would catch missing** — a screen with no way
to navigate to it is as good as not existing.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && flutter test <file>`
Expected: PASS.

- [ ] **Step 5: Full Flutter suite**

Run: `cd app && flutter analyze && flutter test`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add app/lib/screens/tickets_screen.dart app/lib/router.dart \
  app/lib/screens/shell_screen.dart app/lib/state/providers.dart \
  app/lib/data/repositories.dart app/lib/data/api/api_repositories.dart \
  app/test/support/fake_repositories.dart app/test/
git commit -m "Add Tickets list screen, reachable from the app shell nav"
```

---

## Task 15: Ticket Detail screen

**Files:**
- Create: `app/lib/screens/ticket_detail_screen.dart`
- Modify: `app/lib/router.dart`
- Modify: `app/lib/screens/registers_screen.dart`
- Test: matches Task 14's chosen pattern.

**Interfaces:**
- Consumes: Task 10's `TicketRepository.get`, Task 6's `TicketDetailOut`
  shape (as parsed by Task 10's `TicketDetail` model).

- [ ] **Step 1: Write the failing test**

```dart
testWidgets('Ticket Detail renders source fields, timeline, and every session', (tester) async {
  // Pump TicketDetailScreen(ticketId: 't1') with ProviderScope overriding
  // ticketRepositoryProvider with a FakeTicketRepository whose get('t1')
  // returns a TicketDetail with 2 linked sessions.
  // Assert: display id text present, both sessions' mechanic names present,
  // reported/attended/completed timeline labels present.
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test <file>`
Expected: FAIL — file doesn't exist.

- [ ] **Step 3: Implement**

`app/lib/screens/ticket_detail_screen.dart` — layout per the two reference
mockups (`Breakdown.pdf`, `Driver Completed.pdf`):
- Header: display id, status badge, vehicle registration, shift.
- "Job & Reported Defect" card: source entry's own fields (date, shift,
  bus, driver, route, the complaint/defect text).
- Reported → Attended → Completed timeline (three timestamps, from the
  ticket + its sessions — reuse whatever date/time formatting helper
  `breakdowns_screen.dart` already has for its linked-sessions display).
- "Work sessions" list: every entry in `linked_sessions`, each showing
  mechanic(s), attended time, completion time (if any), spare parts —
  reuse the "Originally logged" / "Completed by" distinct treatment
  `breakdowns_screen.dart` already implemented for the first/completing
  session (same visual pattern, this screen is a superset of that view).
- Photos: a simple grid of thumbnails from `photos`, tap to view full size
  (a basic `Image.network` in a dialog is enough — no gallery library
  needed for this).
- Location: if `latitude`/`longitude` present, a small static
  `flutter_map` preview with one marker; otherwise omit the card entirely
  (no "not captured" placeholder needed — omission is the correct
  no-data state here, matching how other optional cards on this screen
  should behave).

Add `flutter_map` (and its `latlong2` dependency) to `app/pubspec.yaml`;
run `flutter pub get`.

`app/lib/router.dart`: add
`static String ticketDetail(String ticketId) => '/tickets/$ticketId';`
and register the route.

`app/lib/screens/registers_screen.dart`: for Breakdown/Driver Complaint
rows, change the View button's `onPressed` — if the entry's register is
one of these two, navigate to `Routes.ticketDetail(...)` using the
entry's linked ticket id (the entries list/search result needs to carry
this — check whether `RegisterEntry` already exposes a ticket id for its
own source ticket, distinct from `ticketId` which today means "the ticket
*this* entry links to as a Work Done session"; if not, this is a small
addition to `RegisterEntry`/`serialize_entry`, same shape as the
`display_id` addition in Task 2/10 — do it here, it's the same kind of
plumbing, not a new concern). Every other register's View button keeps
navigating to `Routes.viewEntry(entry.id)` (the existing read-only form),
unchanged.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && flutter test <file>`
Expected: PASS.

- [ ] **Step 5: Full Flutter suite**

Run: `cd app && flutter analyze && flutter test`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add app/lib/screens/ticket_detail_screen.dart app/lib/router.dart \
  app/lib/screens/registers_screen.dart app/pubspec.yaml app/pubspec.lock \
  app/lib/models/entry.dart backend/app/services/entries.py app/test/
git commit -m "Add Ticket Detail screen; Breakdown/Driver Complaint View opens it"
```

---

## Task 16: Location capture UI (GPS / map / manual)

**Files:**
- Modify: `app/lib/screens/register_form_screen.dart`
- Modify: `app/pubspec.yaml`
- Test: matches Task 11's chosen widget-test file.

**Interfaces:**
- Consumes: Task 9's `latitude`/`longitude`/`location_source` fields.

- [ ] **Step 1: Write the failing test**

```dart
testWidgets('location capture widget writes latitude/longitude/location_source on form open', (tester) async {
  // Override the geolocation service provider (new, see Step 3) with a fake
  // that returns a fixed lat/long. Pump the Breakdown form. Assert
  // widget.onSet was called with 'latitude'/'longitude'/'locationSource'
  // matching the fake's values and locationSource == 'gps'.
});

testWidgets('denied GPS falls back to manual entry, not a crash', (tester) async {
  // Fake geolocation service that throws/returns denied. Pump the form.
  // Assert a manual lat/long entry control is shown instead, and no
  // unhandled exception propagates.
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test <file> --plain-name location`
Expected: FAIL — no geolocation call happens at all yet.

- [ ] **Step 3: Implement**

Add `geolocator` and `flutter_map`/`latlong2` (if not already added by
Task 15) to `pubspec.yaml`.

New `app/lib/services/location_service.dart`: thin wrapper —
`Future<LatLng?> currentPosition()` using `Geolocator.getCurrentPosition`
after `Geolocator.checkPermission`/`requestPermission`, returning `null`
(not throwing) on denial or any platform error — the caller decides what
"no GPS" means, the service just reports it cleanly. Expose it via a
Riverpod provider so it's overridable in tests (mirrors how
`ticketRepositoryProvider` etc. are overridden today).

In `register_form_screen.dart`, for Breakdown/Driver Complaint registers
on a **new** entry (not edit — don't override a location someone already
captured), call the location service once in `initState`/on first build;
on success, `widget.onSet` the three fields with `locationSource: 'gps'`.
On `null` (denied/unavailable), show a compact "Location not captured —
tap to set manually" control that opens a small `flutter_map` picker (tap
to drop a pin → `locationSource: 'map'`) with a manual lat/long text-entry
fallback below it (`locationSource: 'manual'`) for the no-map-tiles-loaded
case.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && flutter test <file>`
Expected: PASS.

- [ ] **Step 5: Full Flutter suite**

Run: `cd app && flutter analyze && flutter test`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add app/lib/screens/register_form_screen.dart app/lib/services/location_service.dart \
  app/pubspec.yaml app/pubspec.lock app/test/
git commit -m "Add GPS/map/manual location capture to Breakdown and Driver Complaint forms"
```

---

## Completion

After Task 16's commit, run the full suite one more time
(`cd backend && make test-backend` and `cd app && flutter analyze &&
flutter test`) as a final checkpoint before the whole-branch review.

Per this repo's CLAUDE.md and the standing feedback from the last two
branches: **do not stop at green tests.** Before calling this plan done,
start the stack (`cd backend && docker compose up -d`, `cd app && flutter
run -d chrome --dart-define=...`) and manually walk, in the running app:
1. File a Driver Complaint → confirm its ticket appears in `/tickets`
   unprompted (no manual raise).
2. From Work Done, search by the complaint's display id, link it, confirm
   the context block prefills and nothing needs re-typing.
3. Set an explicit Attended time, then complete it.
4. Open the complaint's Ticket Detail (via Registers → View) and confirm
   both sessions, both timestamps, and the display id all render.
5. Repeat 1–4 for a Breakdown.
6. Attach two photos to one of them; confirm both show on Ticket Detail;
   remove one; confirm the other survives a page refresh.
7. Confirm GPS capture prompts (or gracefully falls back) and the captured
   point renders on Ticket Detail.

This walk is what the final review package should reference as done, not
assumed — note its outcome in the ledger as part of the plan's completion
contract, same weight as a task's own test run.
