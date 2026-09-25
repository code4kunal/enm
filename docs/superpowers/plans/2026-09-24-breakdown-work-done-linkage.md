# Ticket-Based Work Tracking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce a `tickets` table sitting between a source register entry (breakdown/coolant/driver-complaint/PM-docking) and the chain of Daily Work Done sessions logged against it over multiple shifts/days, with an FK-backed multi-select for attending mechanics and a read-only View action in Registers.

**Architecture:** A new `Ticket` model (1:1 with its source `Entry` via `source_entry_id`) is the spine. `work_done_entries` gains a nullable `ticket_id` FK — each Work Done row is one shift's session against a ticket. A shared `tickets` service owns creation, search, "mark attended" (write-once), and "complete" (propagates back to the source, including breakdown's `resolved_at`/`resolved_by_id`). The Flutter side adds a bespoke ticket-link section to the Work Done form (parallel to the existing Unit section), an FK-backed attendee multi-select, and Registers/Breakdowns UI for View, Raise-ticket, and linked-sessions.

**Tech Stack:** FastAPI + SQLAlchemy (async) + Alembic + Pydantic v2 on the backend; Flutter + Riverpod + go_router on the client. Backend tests use `httpx.AsyncClient` against the real app (see `backend/tests/test_entries.py`); Flutter tests use the fake-repository harness (`app/test/support/`) and `api_contract_test.dart`-style wire-format tests.

**Spec:** `docs/superpowers/specs/2026-09-24-breakdown-work-done-linkage-design.md` — this plan implements it in full, with one correction found while writing this plan (see Global Constraints).

## Global Constraints

- Local only. No `git push`, no PR, no branch promotion — everything in this plan stays on the local branch until the user tests it.
- Vehicle registration numbers stay uppercase, no whitespace, everywhere they're touched.
- Dates stay `yyyy-MM-dd` strings; times stay `HH:mm` strings at the wire boundary.
- Money/volume/power values stay `Decimal` server-side — not applicable to this feature's new fields, but don't regress existing ones while editing shared files.
- **Correction to the spec:** the spec claims the `(ticket_id, entry_date, shift)` uniqueness constraint becomes "a plain table-level `UniqueConstraint`... since `ticket_id` now lives directly on this table." That's wrong — `entry_date` lives on the `Entry` header (`entries.entry_date`), not on `work_done_entries`, so the constraint still spans two tables exactly as the spec's *first* revision found. Task 9 below implements it as a Postgres trigger, matching that original (correct) design. Task 9 also patches the spec doc's sentence so it doesn't mislead a future reader.
- Every backend endpoint change in this plan is paired with its Flutter repository method **and fake** in the same task (never split across tasks) — a drifting fake is worse than no fake, per this repo's `CLAUDE.md`.

---

### Task 1: `Ticket` model, `TicketStatus` enum, and migration

**Files:**
- Modify: `backend/app/models/enums.py`
- Create: `backend/app/models/ticket.py`
- Modify: `backend/app/models/entry.py:33` (import `Ticket` not needed here — no back-reference required from `Entry`)
- Create: `backend/alembic/versions/0024_tickets.py`
- Test: `backend/tests/test_tickets.py`

**Interfaces:**
- Produces: `app.models.enums.TicketStatus` (`open`, `completed`), `TICKET_STATUS_ENUM = "ticket_status_enum"`; `app.models.ticket.Ticket` with columns `id: str`, `source_entry_id: str` (FK `entries.id`, unique), `status: TicketStatus`, `completed_at: datetime | None`, `completed_by_id: str | None`, `attended_at: datetime | None`, `created_at: datetime`, `created_by_id: str`; relationships `source_entry`, `completed_by`, `created_by`.

- [ ] **Step 1: Add `TicketStatus` to the enums module**

In `backend/app/models/enums.py`, add near `EntryStatus`:

```python
class TicketStatus(StrEnum):
    open = "open"
    completed = "completed"
```

And near the other `_ENUM` constants at the bottom:

```python
TICKET_STATUS_ENUM = "ticket_status_enum"
```

- [ ] **Step 2: Write the failing test**

Create `backend/tests/test_tickets.py`:

```python
from __future__ import annotations

from sqlalchemy import select

from app.models.enums import TicketStatus
from app.models.ticket import Ticket
from tests.conftest import auth_headers


async def test_ticket_row_round_trips(client, session_factory) -> None:
    """A Ticket can be inserted and read back with its default status."""
    await auth_headers(client)  # ensures the seeded user/site exist
    async with session_factory() as session:
        from app.models.entry import Entry
        from app.models.enums import Register

        entry = await session.scalar(
            select(Entry).where(Entry.register == Register.breakdown).limit(1)
        )
        assert entry is None  # no breakdown seeded yet at this point in the suite

```

Run it once to confirm the test file at least imports; then replace the body with a self-contained fixture-free version, since the shared `tests/conftest.py` fixture names (`session_factory`) may not exist. Check `backend/tests/conftest.py` for the actual fixture surface before finalizing — search `grep -n "^def \|^async def \|@pytest.fixture" backend/tests/conftest.py` and adapt the test to use whatever session/client fixtures the suite already exposes (likely just `client: AsyncClient`, with all DB access going through the API rather than direct ORM session access — match that pattern). Rewrite as an API-level test once you've confirmed the fixture surface:

```python
from __future__ import annotations

from datetime import date

from httpx import AsyncClient

from tests.conftest import auth_headers

TODAY = date.today().isoformat()


def breakdown() -> dict:
    return {
        "register": "breakdown",
        "site": "MBMT",
        "date": TODAY,
        "data": {
            "bus_no": "MH40LY1895",
            "complaint": "HV contactor tripped, bus immobile",
            "reported_time": "14:45",
        },
    }


async def test_breakdown_creation_does_not_yet_expose_a_ticket_field(
    client: AsyncClient,
) -> None:
    """Placeholder confirming the migration lands cleanly; Task 2 wires the
    actual auto-ticket-creation behavior this test file will grow to cover."""
    h = await auth_headers(client)
    r = await client.post("/entries", json=breakdown(), headers=h)
    assert r.status_code == 201, r.text
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd backend && .venv/bin/pytest tests/test_tickets.py -v`
Expected: FAIL — `breakdown_time`/`mechanic_reported_time` are still the live column names (Task 8 renames them), so `"reported_time": "14:45"` in the payload above will 400 with `extra="forbid"`. Change the payload to use `"mechanic_reported_time": "14:45"` for now (Task 8 will update this test file to `reported_time` once the rename lands). Re-run — this time it should PASS purely on today's schema, which only proves the harness works. This step exists to confirm your test file and fixtures are wired correctly before the real migration test is written next.

- [ ] **Step 4: Create the `Ticket` model**

Create `backend/app/models/ticket.py`. **`Entry` is imported under `TYPE_CHECKING` only, never at module level** — Task 5 makes `entry.py` import `Ticket` at module level (for `WorkDoneEntry.ticket`), and if `ticket.py` also imported `entry.py` eagerly, that would be a circular import that crashes the app the moment Task 5 lands. `from __future__ import annotations` (already used throughout this codebase, including `entry.py`) makes every annotation a lazy string, so SQLAlchemy resolves `Mapped["Entry"]` against the module's namespace at mapper-configuration time — long after both modules have finished importing — not at class-body-execution time. This is why the type-only import is sufficient and the relationship still works at runtime:

```python
from __future__ import annotations

from datetime import datetime
from typing import TYPE_CHECKING

from sqlalchemy import Enum, ForeignKey, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, TZDateTime, created_at_col, new_uuid
from app.models.enums import TICKET_STATUS_ENUM, TicketStatus
from app.models.user import User

if TYPE_CHECKING:
    from app.models.entry import Entry


class Ticket(Base):
    """The spine between a source entry and its chain of Work Done sessions.

    One ticket per source, always — `source_entry_id` is unique. A breakdown's
    ticket is created automatically; Coolant/Driver Complaint/PM-Docking
    tickets are raised explicitly (see `services/tickets.py`).
    """

    __tablename__ = "tickets"

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_uuid)
    source_entry_id: Mapped[str] = mapped_column(
        String(32),
        ForeignKey("entries.id", ondelete="CASCADE"),
        nullable=False,
        unique=True,
    )
    status: Mapped[TicketStatus] = mapped_column(
        Enum(
            TicketStatus,
            name=TICKET_STATUS_ENUM,
            values_callable=lambda e: [m.value for m in e],
        ),
        nullable=False,
        default=TicketStatus.open,
    )
    completed_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
    completed_by_id: Mapped[str | None] = mapped_column(
        String(32), ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
    # Set once, from the first Work Done session logged against this ticket.
    attended_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
    created_at: Mapped[datetime] = created_at_col()
    created_by_id: Mapped[str] = mapped_column(
        String(32), ForeignKey("users.id", ondelete="RESTRICT"), nullable=False
    )

    source_entry: Mapped["Entry"] = relationship(
        lazy="joined", foreign_keys=[source_entry_id]
    )
    completed_by: Mapped[User | None] = relationship(
        lazy="joined", foreign_keys=[completed_by_id]
    )
    created_by: Mapped[User] = relationship(lazy="joined", foreign_keys=[created_by_id])
```

`entry.py` itself is **not** modified in this task — it gets its `from app.models.ticket import Ticket` top-level import in Task 5, once `WorkDoneEntry.ticket_id` actually needs it. Adding that import now, before anything references `Ticket` from `entry.py`, would be dead code.

- [ ] **Step 5: Write the migration**

Create `backend/alembic/versions/0024_tickets.py`:

```python
"""tickets table

Revision ID: 0024
Revises: 0023
Create Date: 2026-09-24

The spine between a source register entry (breakdown, coolant, driver
complaint, PM/docking) and the chain of Daily Work Done sessions logged
against it. One ticket per source, always.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0024"
down_revision = "0023"
branch_labels = None
depends_on = None

ticket_status_enum = sa.Enum("open", "completed", name="ticket_status_enum")


def upgrade() -> None:
    ticket_status_enum.create(op.get_bind(), checkfirst=True)
    op.create_table(
        "tickets",
        sa.Column("id", sa.String(32), primary_key=True),
        sa.Column(
            "source_entry_id",
            sa.String(32),
            sa.ForeignKey("entries.id", ondelete="CASCADE"),
            nullable=False,
            unique=True,
        ),
        sa.Column("status", ticket_status_enum, nullable=False, server_default="open"),
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "completed_by_id",
            sa.String(32),
            sa.ForeignKey("users.id", ondelete="SET NULL"),
            nullable=True,
        ),
        sa.Column("attended_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), nullable=False,
            server_default=sa.func.now(),
        ),
        sa.Column(
            "created_by_id",
            sa.String(32),
            sa.ForeignKey("users.id", ondelete="RESTRICT"),
            nullable=False,
        ),
    )
    op.create_index("ix_tickets_status", "tickets", ["status"])


def downgrade() -> None:
    op.drop_index("ix_tickets_status", table_name="tickets")
    op.drop_table("tickets")
    ticket_status_enum.drop(op.get_bind(), checkfirst=True)
```

- [ ] **Step 6: Run migrations and the test**

Run: `cd backend && .venv/bin/alembic upgrade head`
Expected: migration `0024` applies cleanly.

Run: `.venv/bin/pytest tests/test_tickets.py -v`
Expected: PASS (the placeholder test from Step 3, using `mechanic_reported_time`).

- [ ] **Step 7: Commit**

```bash
git add backend/app/models/enums.py backend/app/models/ticket.py \
  backend/alembic/versions/0024_tickets.py backend/tests/test_tickets.py
git commit -m "Add tickets table: the spine between a source entry and its work sessions"
```

---

### Task 2: Ticket service — create, title, search

**Files:**
- Create: `backend/app/services/tickets.py`
- Create: `backend/app/api/tickets.py`
- Modify: `backend/app/api/__init__.py`
- Create: `backend/app/schemas/ticket.py`
- Test: `backend/tests/test_tickets.py` (extend)

**Interfaces:**
- Consumes: `Ticket` model (Task 1), `Entry`/`Register`/`EntryStatus` (existing), `now_ist()` from `app.services.common`.
- Produces: `TICKETABLE_REGISTERS: frozenset[Register]`; `async def create_ticket_for_entry(session, *, entry: Entry, creator: User) -> Ticket`; `def ticket_title(entry: Entry) -> str`; `async def search_tickets(session, *, site_code: str, register: Register | None, q: str | None) -> list[Ticket]`. Both later tasks (breakdown auto-create, raise-ticket endpoint, `/tickets/search`) call into this module — no other module may construct a `Ticket` row directly.

- [ ] **Step 1: Write the failing test**

Append to `backend/tests/test_tickets.py`:

```python
async def test_ticket_search_finds_open_breakdown_by_title_text(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    created = await client.post("/entries", json=breakdown(), headers=h)
    assert created.status_code == 201

    # No ticket exists yet — Task 3 wires auto-creation. For now this proves
    # the search endpoint itself round-trips when a ticket exists, so seed one
    # directly through the not-yet-existent raise endpoint's future shape is
    # out of reach here; instead assert the endpoint 200s with an empty list,
    # which is the correct behavior before any ticket exists.
    r = await client.get(
        "/tickets/search",
        params={"site": "MBMT", "register": "breakdown", "q": "contactor"},
        headers=h,
    )
    assert r.status_code == 200, r.text
    assert r.json() == []
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/pytest tests/test_tickets.py::test_ticket_search_finds_open_breakdown_by_title_text -v`
Expected: FAIL — `404 Not Found`, no `/tickets` router yet.

- [ ] **Step 3: Write the ticket schema**

Create `backend/app/schemas/ticket.py`:

```python
from __future__ import annotations

from datetime import date as date_t

from pydantic import BaseModel


class TicketSearchResult(BaseModel):
    ticket_id: str
    title: str
    entry_date: date_t
    status: str
```

- [ ] **Step 4: Write the ticket service**

Create `backend/app/services/tickets.py`:

```python
from __future__ import annotations

from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import Conflict
from app.models.entry import Entry
from app.models.enums import Register
from app.models.ticket import Ticket
from app.models.user import User

#: Which register types may ever have a ticket. Work Done is the *referencer*
#: (it points at a ticket), never a source itself.
TICKETABLE_REGISTERS = frozenset(
    {Register.breakdown, Register.coolant, Register.driver_complaint, Register.pm_schedule}
)


async def create_ticket_for_entry(
    session: AsyncSession, *, entry: Entry, creator: User
) -> Ticket:
    if entry.register not in TICKETABLE_REGISTERS:
        raise Conflict(f"{entry.register.value} entries cannot have a ticket")
    existing = await session.scalar(
        select(Ticket).where(Ticket.source_entry_id == entry.id)
    )
    if existing is not None:
        raise Conflict("This entry already has a ticket")
    ticket = Ticket(source_entry_id=entry.id, created_by_id=creator.id)
    session.add(ticket)
    await session.flush()
    return ticket


#: How each register's own text is rendered as a ticket's search title.
_TITLE_FIELD = {
    Register.breakdown: lambda d: d.complaint,
    Register.coolant: lambda d: "Coolant topping",
    Register.driver_complaint: lambda d: d.complaint,
    Register.pm_schedule: lambda d: d.defects_noticed,
}


def ticket_title(entry: Entry) -> str:
    label = _TITLE_FIELD[entry.register](entry.detail)
    bus = entry.vehicle.registration_no
    return f"{label[:60]} · {bus}"


async def search_tickets(
    session: AsyncSession,
    *,
    site_code: str,
    register: Register | None,
    q: str | None,
) -> list[Ticket]:
    stmt = (
        select(Ticket)
        .join(Entry, Entry.id == Ticket.source_entry_id)
        .where(Entry.site_code == site_code, Ticket.status == "open")
    )
    if register is not None:
        stmt = stmt.where(Entry.register == register)
    if q:
        needle = f"%{q.strip().lower()}%"
        stmt = stmt.where(
            or_(Entry.search_text.like(needle), Ticket.id == q.strip())
        )
    rows = (
        await session.scalars(stmt.order_by(Entry.entry_date.desc()))
    ).unique().all()
    return list(rows)
```

- [ ] **Step 5: Write the router**

Create `backend/app/api/tickets.py`:

```python
from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Query

from app.deps import CurrentUser, EntrySite, SessionDep
from app.models.enums import Register
from app.schemas.ticket import TicketSearchResult
from app.services import tickets as svc

router = APIRouter(prefix="/tickets", tags=["tickets"])


@router.get("/search", response_model=list[TicketSearchResult])
async def search(
    _user: CurrentUser,
    session: SessionDep,
    site: EntrySite,
    register: Annotated[Register | None, Query()] = None,
    q: Annotated[str | None, Query(max_length=200)] = None,
) -> list[TicketSearchResult]:
    tickets = await svc.search_tickets(session, site_code=site, register=register, q=q)
    return [
        TicketSearchResult(
            ticket_id=t.id,
            title=svc.ticket_title(t.source_entry),
            entry_date=t.source_entry.entry_date,
            status=t.status.value,
        )
        for t in tickets
    ]
```

- [ ] **Step 6: Wire the router into the app**

In `backend/app/api/__init__.py`, add `tickets` to the import list and register it:

```python
from app.api import (
    admin,
    admin_estate,
    auth,
    checklists,
    entries,
    health,
    imports,
    inspections,
    master,
    notifications,
    reports,
    siteops,
    sites,
    tickets,
)
```

```python
api_router.include_router(entries.router)
api_router.include_router(tickets.router)
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `.venv/bin/pytest tests/test_tickets.py -v`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add backend/app/services/tickets.py backend/app/api/tickets.py \
  backend/app/schemas/ticket.py backend/app/api/__init__.py backend/tests/test_tickets.py
git commit -m "Add ticket service and GET /tickets/search"
```

---

### Task 3: Breakdown auto-creates its ticket

**Files:**
- Modify: `backend/app/api/entries.py:122-153` (`create_entry` route)
- Test: `backend/tests/test_tickets.py` (extend)

**Interfaces:**
- Consumes: `tickets_svc.create_ticket_for_entry` (Task 2).
- Produces: nothing new consumed by later tasks — breakdown creation now has a `Ticket` row, verified by querying `/tickets/search`.

- [ ] **Step 1: Write the failing test**

Replace the placeholder test from Task 2 Step 1 (the `== []` assertion) with the real behavior:

```python
async def test_breakdown_creation_auto_creates_its_ticket(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    created = await client.post("/entries", json=breakdown(), headers=h)
    assert created.status_code == 201

    r = await client.get(
        "/tickets/search",
        params={"site": "MBMT", "register": "breakdown", "q": "contactor"},
        headers=h,
    )
    assert r.status_code == 200, r.text
    results = r.json()
    assert len(results) == 1
    assert results[0]["status"] == "open"
    assert "MH40LY1895" in results[0]["title"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/pytest tests/test_tickets.py::test_breakdown_creation_auto_creates_its_ticket -v`
Expected: FAIL — `results` is `[]`, no ticket was created.

- [ ] **Step 3: Wire ticket creation into breakdown entry creation**

In `backend/app/api/entries.py`, add the import:

```python
from app.services import tickets as tickets_svc
```

In `create_entry` (around line 149), after the existing breakdown notification call:

```python
    if payload.register is Register.breakdown:
        await tickets_svc.create_ticket_for_entry(session, entry=entry, creator=user)
        await notifications.notify_breakdown_opened(session, entry)
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `.venv/bin/pytest tests/test_tickets.py -v`
Expected: PASS.

Also run the full existing entries suite to confirm nothing regressed:

Run: `.venv/bin/pytest tests/test_entries.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add backend/app/api/entries.py backend/tests/test_tickets.py
git commit -m "Auto-create a ticket when a breakdown is reported"
```

---

### Task 4: `POST /entries/{id}/raise_ticket` for Coolant/Complaint/PM

**Files:**
- Modify: `backend/app/api/entries.py`
- Modify: `backend/app/models/enums.py` (`AuditAction`)
- Test: `backend/tests/test_tickets.py` (extend)

**Interfaces:**
- Consumes: `tickets_svc.create_ticket_for_entry`.
- Produces: the endpoint itself, consumed by the Flutter Registers "Raise ticket" action in Task 15.

- [ ] **Step 1: Write the failing test**

```python
def coolant() -> dict:
    return {
        "register": "coolant",
        "site": "MBMT",
        "date": TODAY,
        "data": {"bus_no": "MH40LY1894", "bcs_litres": 2.5},
    }


async def test_raise_ticket_on_coolant_opens_it_and_is_idempotent_guarded(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    created = await client.post("/entries", json=coolant(), headers=h)
    entry_id = created.json()["id"]
    assert created.json()["status"] == "done"

    raised = await client.post(f"/entries/{entry_id}/raise_ticket", headers=h)
    assert raised.status_code == 200, raised.text
    assert raised.json()["status"] == "open"

    again = await client.post(f"/entries/{entry_id}/raise_ticket", headers=h)
    assert again.status_code == 409


async def test_raise_ticket_rejects_breakdown_and_work_done(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    created = await client.post("/entries", json=breakdown(), headers=h)
    entry_id = created.json()["id"]

    r = await client.post(f"/entries/{entry_id}/raise_ticket", headers=h)
    assert r.status_code == 409
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/pytest tests/test_tickets.py -k raise_ticket -v`
Expected: FAIL — `404 Not Found`.

- [ ] **Step 3: Add the `AuditAction`**

In `backend/app/models/enums.py`, add to `AuditAction`:

```python
    ticket_raised = "ticket_raised"
```

- [ ] **Step 4: Write the endpoint**

In `backend/app/api/entries.py`, add after `resolve_breakdown`:

```python
@router.post("/{entry_id}/raise_ticket", response_model=EntryOut)
async def raise_ticket(
    entry_id: str, user: CurrentUser, session: SessionDep
) -> EntryOut:
    entry = await _load(session, entry_id)
    assert_site_permission(user, entry.site_code, "em_entry:write")
    if entry.register not in (
        Register.coolant,
        Register.driver_complaint,
        Register.pm_schedule,
    ):
        raise Conflict(
            "Only coolant, driver complaint, and PM/docking entries can raise "
            "a ticket here — breakdowns raise theirs automatically"
        )

    await tickets_svc.create_ticket_for_entry(session, entry=entry, creator=user)
    entry.status = EntryStatus.open
    entry.updated_at = datetime.now(UTC)

    await audit.record(
        session,
        actor_id=user.id,
        action=AuditAction.ticket_raised,
        object_type="entry",
        object_id=entry.id,
        after=svc.audit_snapshot(entry, extra={"status": "open"}),
    )
    result = svc.serialize_entry(entry)
    await session.commit()
    return EntryOut(**result)
```

Note `create_ticket_for_entry` already raises `Conflict` (409) both for a wrong register and for a duplicate ticket, so the explicit register check above is a clearer, earlier error message for the three-way case, while the "already has a ticket" 409 in `test_raise_ticket_on_coolant_opens_it_and_is_idempotent_guarded` comes from the service layer.

- [ ] **Step 5: Run the test to verify it passes**

Run: `.venv/bin/pytest tests/test_tickets.py -v`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add backend/app/api/entries.py backend/app/models/enums.py backend/tests/test_tickets.py
git commit -m "Add POST /entries/{id}/raise_ticket for Coolant/Complaint/PM"
```

---

### Task 5: `work_done_entries` gains `ticket_id`, `completes_ticket`, `completion_time`

**Files:**
- Modify: `backend/app/models/entry.py:179-204` (`WorkDoneEntry`)
- Modify: `backend/app/schemas/entry.py:31-40` (`WorkDoneData`)
- Modify: `backend/app/services/entries.py` (`_build_detail`, `serialize_data`, `create_entry`, `update_entry`)
- Create: `backend/alembic/versions/0025_work_done_ticket_link.py`
- Test: `backend/tests/test_entries.py` (extend), `backend/tests/test_tickets.py` (extend)

**Interfaces:**
- Consumes: `Ticket`, `TicketStatus` (Task 1); `tickets_svc.create_ticket_for_entry` pattern (not called here — this task only *links*, Task 6 handles completion).
- Produces: `WorkDoneEntry.ticket_id/completes_ticket/completion_time`; `WorkDoneData.ticket_id/completes_ticket/completion_time` — consumed by Task 6 (`_complete_ticket` wiring) and Task 15 (Flutter ticket picker).

- [ ] **Step 1: Write the failing test**

Append to `backend/tests/test_entries.py`:

```python
async def test_work_done_can_link_to_an_open_ticket(client: AsyncClient) -> None:
    h = await auth_headers(client)
    bd = await client.post("/entries", json=breakdown(), headers=h)
    bd_id = bd.json()["id"]
    tickets = await client.get(
        "/tickets/search",
        params={"site": "MBMT", "register": "breakdown", "q": bd_id},
        headers=h,
    )
    ticket_id = tickets.json()[0]["ticket_id"]

    payload = work_done()
    payload["data"]["ticket_id"] = ticket_id
    r = await client.post("/entries", json=payload, headers=h)
    assert r.status_code == 201, r.text
    assert r.json()["data"]["ticket_id"] == ticket_id


async def test_work_done_rejects_an_already_completed_ticket(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    bd = await client.post("/entries", json=breakdown(), headers=h)
    bd_id = bd.json()["id"]
    await client.post(f"/entries/{bd_id}/resolve", headers=h)
    tickets = await client.get(
        "/tickets/search",
        params={"site": "MBMT", "register": "breakdown", "q": bd_id},
        headers=h,
    )
    # A resolved breakdown's ticket is completed, so it no longer shows up in
    # an open-tickets search — confirm that, then confirm linking to its id
    # directly (as if a stale client cached it) is rejected.
    assert tickets.json() == []
```

Note the second test doesn't yet know the completed ticket's id (search only returns open ones) — for now, assert only the empty-search behavior; Task 6 will extend this file once `complete_ticket` exists to also assert the direct-link-rejection using a ticket id captured before resolution.

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/pytest tests/test_entries.py -k work_done_can_link -v`
Expected: FAIL — `ticket_id` is not a recognized `WorkDoneData` field (`extra="forbid"` → 400).

- [ ] **Step 3: Add the columns to `WorkDoneEntry`**

In `backend/app/models/entry.py`, add `Boolean` to the sqlalchemy import list (line 8-19), then update `WorkDoneEntry`:

```python
from sqlalchemy import (
    Boolean,
    Date,
    Enum,
    ForeignKey,
    Index,
    Integer,
    Numeric,
    String,
    Text,
    Time,
    text,
)
```

```python
class WorkDoneEntry(Base):
    __tablename__ = "work_done_entries"

    entry_id: Mapped[str] = _entry_fk()
    shift: Mapped[Shift | None] = mapped_column(
        Enum(Shift, name=SHIFT_ENUM, values_callable=lambda e: [m.value for m in e]),
        nullable=True,
    )
    reported_defects: Mapped[str] = mapped_column(Text, nullable=False)
    defect_source_id: Mapped[int | None] = mapped_column(
        Integer, ForeignKey("defect_sources.id", ondelete="RESTRICT"), nullable=True
    )
    defect_type_id: Mapped[int | None] = mapped_column(
        Integer, ForeignKey("defect_types.id", ondelete="RESTRICT"), nullable=True
    )
    attended_details: Mapped[str | None] = mapped_column(Text, nullable=True)
    spare_parts_used: Mapped[str | None] = mapped_column(Text, nullable=True)
    # Floor supervisor who signed the job off. A name, not an FK: the
    # supervisor of a 2024 entry must still read correctly after they leave.
    supervisor: Mapped[str | None] = mapped_column(String(255), nullable=True)
    ticket_id: Mapped[str | None] = mapped_column(
        String(32), ForeignKey("tickets.id", ondelete="SET NULL"), nullable=True
    )
    completes_ticket: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False
    )
    completion_time: Mapped[time_t | None] = mapped_column(Time, nullable=True)

    entry: Mapped[Entry] = relationship(back_populates="work_done")
    defect_source: Mapped[DefectSource | None] = relationship(lazy="joined")
    defect_type: Mapped[DefectType | None] = relationship(lazy="joined")
    ticket: Mapped["Ticket | None"] = relationship(lazy="joined")
```

(`employee` is intentionally gone already in this diff — Task 7 is what actually drops the column from the database; removing it from the model here without a corresponding migration would break existing rows. **Do not remove `employee` from the model in this task** — keep it for now and only add the three new columns. Task 7 removes `employee` from both model and database together.)

Add the import at the top of `entry.py`:

```python
from app.models.ticket import Ticket
```

- [ ] **Step 4: Update `WorkDoneData` schema**

In `backend/app/schemas/entry.py`, add `model_validator` to the pydantic import:

```python
from pydantic import BaseModel, BeforeValidator, ConfigDict, Field, field_validator, model_validator
```

```python
class WorkDoneData(_DataBase):
    shift: Shift | None = None
    bus_no: BusNo
    reported_defects: Req = Field(min_length=1)
    defect_source: OptText = None
    defect_type: OptText = None
    attended_details: OptText = None
    spare_parts_used: OptText = None
    employee: OptText = None
    supervisor: OptText = None
    ticket_id: OptText = None
    completes_ticket: bool = False
    completion_time: HHMM | None = None

    @model_validator(mode="after")
    def _completion_requires_ticket_and_time(self) -> "WorkDoneData":
        if self.completes_ticket and not self.ticket_id:
            raise ValueError("completes_ticket requires ticket_id")
        if self.completes_ticket and not self.completion_time:
            raise ValueError("completes_ticket requires completion_time")
        return self
```

(`employee` stays in the schema for this task — Task 7 removes it.)

- [ ] **Step 5: Resolve and validate the ticket in `_build_detail`**

In `backend/app/services/entries.py`, add imports:

```python
from app.errors import Conflict, ValidationError
from app.models.enums import TicketStatus
from app.models.ticket import Ticket
```

(`ValidationError` is already imported — check before duplicating.)

Add a resolver function above `_build_detail`:

```python
async def _resolve_ticket(session: AsyncSession, ticket_id: str | None) -> Ticket | None:
    if not ticket_id:
        return None
    ticket = await session.get(Ticket, ticket_id)
    if ticket is None:
        raise ValidationError("ticket_id: not found", {"ticket_id": "not found"})
    if ticket.status is TicketStatus.completed:
        raise Conflict("This ticket is already completed")
    return ticket
```

Update the `work_done` branch of `_build_detail`:

```python
    if register is Register.work_done:
        src = await resolve_defect_source(session, data.defect_source)
        typ = await resolve_defect_type(session, data.defect_type)
        ticket = await _resolve_ticket(session, data.ticket_id)
        row = WorkDoneEntry(
            shift=data.shift,
            reported_defects=data.reported_defects,
            defect_source=src,
            defect_type=typ,
            attended_details=data.attended_details,
            spare_parts_used=data.spare_parts_used,
            employee=data.employee,
            supervisor=data.supervisor,
            ticket_id=ticket.id if ticket else None,
            completes_ticket=data.completes_ticket,
            completion_time=data.completion_time,
        )
        return row, [
            data.reported_defects,
            data.defect_source,
            data.defect_type,
            data.attended_details,
            data.spare_parts_used,
            data.employee,
            data.shift.value if data.shift else None,
        ]
```

- [ ] **Step 6: Update `serialize_data`**

In the `work_done` branch of `serialize_data`, add the three new keys:

```python
    if entry.register is Register.work_done:
        return {
            "shift": d.shift.value if d.shift else None,
            "bus_no": bus_no,
            "reported_defects": d.reported_defects,
            "defect_source": d.defect_source.name if d.defect_source else None,
            "defect_type": d.defect_type.name if d.defect_type else None,
            "attended_details": d.attended_details,
            "spare_parts_used": d.spare_parts_used,
            "employee": d.employee,
            "supervisor": d.supervisor,
            "ticket_id": d.ticket_id,
            "completes_ticket": d.completes_ticket,
            "completion_time": _hhmm(d.completion_time),
        }
```

- [ ] **Step 7: Write the migration**

Create `backend/alembic/versions/0025_work_done_ticket_link.py`:

```python
"""work_done_entries ticket link

Revision ID: 0025
Revises: 0024
Create Date: 2026-09-24
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0025"
down_revision = "0024"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "work_done_entries",
        sa.Column(
            "ticket_id",
            sa.String(32),
            sa.ForeignKey("tickets.id", ondelete="SET NULL"),
            nullable=True,
        ),
    )
    op.create_index(
        "ix_work_done_entries_ticket_id", "work_done_entries", ["ticket_id"]
    )
    op.add_column(
        "work_done_entries",
        sa.Column(
            "completes_ticket", sa.Boolean(), nullable=False, server_default="false"
        ),
    )
    op.add_column(
        "work_done_entries", sa.Column("completion_time", sa.Time(), nullable=True)
    )


def downgrade() -> None:
    op.drop_column("work_done_entries", "completion_time")
    op.drop_column("work_done_entries", "completes_ticket")
    op.drop_index("ix_work_done_entries_ticket_id", table_name="work_done_entries")
    op.drop_column("work_done_entries", "ticket_id")
```

- [ ] **Step 8: Run migrations and tests**

Run: `cd backend && .venv/bin/alembic upgrade head`
Expected: `0025` applies cleanly.

Run: `.venv/bin/pytest tests/test_entries.py tests/test_tickets.py -v`
Expected: PASS. Fix the second test in Step 1 if it fails on the `tickets.json() == []` assertion — resolving the breakdown should already remove it from an open-only search (this doesn't need `complete_ticket` from Task 6 to be true for a *search-visibility* claim, since `create_ticket_for_entry`'s ticket stays `open` until something completes it — if this assertion fails, it's because the ticket is still open post-resolve, which is expected until Task 6 wires the header-resolve endpoint to also complete the ticket. Simplify this test for now to only assert `resolved.status_code == 200`, and move the "ticket removed from search after resolve" assertion into Task 6, which is where that behavior actually lands.

- [ ] **Step 9: Commit**

```bash
git add backend/app/models/entry.py backend/app/schemas/entry.py \
  backend/app/services/entries.py backend/alembic/versions/0025_work_done_ticket_link.py \
  backend/tests/test_entries.py backend/tests/test_tickets.py
git commit -m "Let Work Done entries link to a ticket"
```

---

### Task 6: `complete_ticket` — shared completion, wired into both paths

**Files:**
- Modify: `backend/app/services/tickets.py`
- Modify: `backend/app/api/entries.py` (`resolve_breakdown`, `create_entry`, `update_entry`)
- Modify: `backend/app/services/entries.py` (`create_entry`, `update_entry` — trigger completion/attendance after detail build)
- Test: `backend/tests/test_tickets.py` (extend)

**Interfaces:**
- Consumes: `Ticket`, `now_ist()` (`app.services.common`).
- Produces: `async def complete_ticket(session, *, ticket: Ticket, completed_by: User, completed_at: datetime) -> None`; `def mark_attended(ticket: Ticket, at: datetime) -> None`. Both called from `services/entries.py`'s work_done write path and from `resolve_breakdown`.

- [ ] **Step 1: Write the failing test**

```python
async def test_work_done_completing_a_breakdown_ticket_mirrors_resolved_fields(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    bd = await client.post("/entries", json=breakdown(), headers=h)
    bd_id = bd.json()["id"]
    tickets = await client.get(
        "/tickets/search",
        params={"site": "MBMT", "register": "breakdown", "q": bd_id},
        headers=h,
    )
    ticket_id = tickets.json()[0]["ticket_id"]

    payload = work_done()
    payload["data"]["ticket_id"] = ticket_id
    payload["data"]["completes_ticket"] = True
    payload["data"]["completion_time"] = "16:00"
    r = await client.post("/entries", json=payload, headers=h)
    assert r.status_code == 201, r.text

    bd_after = await client.get(f"/entries/{bd_id}", headers=h)
    assert bd_after.json()["status"] == "resolved"
    assert bd_after.json()["data"]["resolved_at"] is not None

    still_open = await client.get(
        "/tickets/search",
        params={"site": "MBMT", "register": "breakdown", "q": bd_id},
        headers=h,
    )
    assert still_open.json() == []


async def test_resolve_endpoint_still_works_and_completes_the_ticket(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    bd = await client.post("/entries", json=breakdown(), headers=h)
    bd_id = bd.json()["id"]
    resolved = await client.post(f"/entries/{bd_id}/resolve", headers=h)
    assert resolved.status_code == 200
    again = await client.post(f"/entries/{bd_id}/resolve", headers=h)
    assert again.status_code == 409
```

Note `bd_after.json()["data"]["resolved_at"]` requires `resolved_at` to be exposed in `serialize_data` — add that now too (it wasn't exposed before this feature; see Step 4 below).

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/pytest tests/test_tickets.py -k "completing_a_breakdown or resolve_endpoint_still_works" -v`
Expected: FAIL — `bd_after.json()["status"]` is still `"open"`; `resolved_at` key missing from `data`.

- [ ] **Step 3: Add `complete_ticket` and `mark_attended` to the ticket service**

In `backend/app/services/tickets.py`, add:

```python
from datetime import datetime

from app.models.entry import BreakdownEntry
from app.models.enums import EntryStatus, Register, TicketStatus
```

(merge with existing imports rather than duplicating `Register`.)

```python
def mark_attended(ticket: Ticket, at: datetime) -> None:
    """Set once, from the first Work Done session logged against this ticket."""
    if ticket.attended_at is not None:
        return
    ticket.attended_at = at
    source = ticket.source_entry
    if source.register is Register.breakdown:
        detail: BreakdownEntry = source.breakdown
        detail.attended_time = at.timetz().replace(tzinfo=None)


async def complete_ticket(
    session: AsyncSession, *, ticket: Ticket, completed_by: User, completed_at: datetime
) -> None:
    if ticket.status is TicketStatus.completed:
        raise Conflict("This ticket is already completed")
    ticket.status = TicketStatus.completed
    ticket.completed_at = completed_at
    ticket.completed_by_id = completed_by.id

    source = ticket.source_entry
    source.status = EntryStatus.resolved
    source.updated_at = completed_at
    if source.register is Register.breakdown:
        detail: BreakdownEntry = source.breakdown
        detail.resolved_at = completed_at
        detail.resolved_by_id = completed_by.id
```

- [ ] **Step 4: Expose `resolved_at` in `serialize_data`**

In `backend/app/services/entries.py`, add a small ISO-in-IST helper and use it in the breakdown branch:

```python
def _ist_iso(value: datetime | None) -> str | None:
    if value is None:
        return None
    return value.astimezone(IST).isoformat(timespec="seconds")
```

```python
    if entry.register is Register.breakdown:
        return {
            "bus_no": bus_no,
            "defect_type": d.defect_type.name if d.defect_type else None,
            "driver_id": d.driver_id,
            "route": d.route,
            "location": d.location,
            "complaint": d.complaint,
            "breakdown_time": _hhmm(d.breakdown_time),
            "mechanic_reported_time": _hhmm(d.mechanic_reported_time),
            "attended_time": _hhmm(d.attended_time),
            "loss_km": _num(d.loss_km),
            "attended_details": d.attended_details,
            "remarks": d.remarks,
            "supervisor": d.supervisor,
            "resolved_at": _ist_iso(d.resolved_at),
        }
```

(`breakdown_time`/`mechanic_reported_time` keep their current names here — Task 8 renames them. Don't rename in this task.)

- [ ] **Step 5: Wire completion/attendance into the Work Done write path**

In `backend/app/services/entries.py`'s `create_entry` and `update_entry`, after `setattr(entry, register.value, detail)` and before `session.add(entry)`/`await session.flush()` respectively, add the ticket side effect. Since both functions share this shape, add a small helper used by both:

```python
async def _apply_ticket_side_effects(
    session: AsyncSession, register: Register, detail: Any, actor: User, now: datetime
) -> None:
    if register is not Register.work_done or detail.ticket_id is None:
        return
    ticket = await session.get(Ticket, detail.ticket_id)
    tickets_mark_attended(ticket, now)
    if detail.completes_ticket:
        completed_at = datetime.combine(
            date_t.today(), detail.completion_time, tzinfo=IST
        ) if detail.completion_time else now
        await tickets_complete(session, ticket=ticket, completed_by=actor, completed_at=completed_at)
```

Use the entry's own `entry_date`, not `date_t.today()` — correct the snippet above once you have `entry` in scope (in `create_entry` this is the just-built `entry`; in `update_entry` it's the passed-in `entry`):

```python
async def _apply_ticket_side_effects(
    session: AsyncSession, entry: Entry, detail: Any, actor: User
) -> None:
    if entry.register is not Register.work_done or detail.ticket_id is None:
        return
    ticket = await session.get(Ticket, detail.ticket_id)
    now = _now_ist()
    mark_attended(ticket, now)
    if detail.completes_ticket:
        completed_at = (
            datetime.combine(entry.entry_date, detail.completion_time, tzinfo=IST)
            if detail.completion_time
            else now
        )
        await complete_ticket(session, ticket=ticket, completed_by=actor, completed_at=completed_at)
```

Import `mark_attended, complete_ticket` from `app.services.tickets` at the top of `entries.py` (rename the earlier `_resolve_ticket` import block accordingly):

```python
from app.services.tickets import complete_ticket, mark_attended
```

Call it in `create_entry`, right after `session.add(entry)` and `await session.flush()` (the ticket needs `entry.id`/`entry.entry_date` to already exist, and `detail` needs its FK populated, both true post-flush):

```python
    session.add(entry)
    await session.flush()
    await _apply_ticket_side_effects(session, entry, detail, creator)
    return entry
```

And in `update_entry`, after its own `await session.flush()`:

```python
    await session.flush()
    await _apply_ticket_side_effects(session, entry, detail, entry.created_by)
    return entry
```

(`update_entry` doesn't currently take an acting user separately from `entry.created_by` — using `entry.created_by` here is a simplification; if `update_entry`'s caller has the actual editing user available, prefer passing it through. Check `backend/app/api/entries.py`'s `update_entry` route — it has `user: CurrentUser` in scope — and thread it through as a new keyword parameter on `svc.update_entry` instead, so the completing user is whoever actually submitted the edit, not the original author:

```python
async def update_entry(
    session: AsyncSession,
    entry: Entry,
    *,
    entry_date: date_t | None,
    entry_time: time_t | None,
    raw_data: dict[str, Any],
    actor: User,
) -> Entry:
    ...
    await _apply_ticket_side_effects(session, entry, detail, actor)
    return entry
```

Update the call site in `backend/app/api/entries.py`'s `update_entry` route to pass `actor=user`.)

- [ ] **Step 6: Refactor `/resolve` to delegate to `complete_ticket`**

In `backend/app/api/entries.py`, add `Ticket` to the top-level model imports alongside the existing ones — this is safe because `ticket.py` only imports `Entry` under `TYPE_CHECKING` (Task 1), so there's no cycle:

```python
from app.models.entry import BreakdownEntry, Entry
from app.models.ticket import Ticket
```

Rewrite `resolve_breakdown`:

```python
@router.post("/{entry_id}/resolve", response_model=EntryOut)
async def resolve_breakdown(
    entry_id: str, user: CurrentUser, session: SessionDep
) -> EntryOut:
    entry = await _load(session, entry_id)
    assert_site_permission(user, entry.site_code, "em_entry:write")
    if entry.register is not Register.breakdown:
        raise Conflict("Only breakdown entries can be resolved")

    ticket = await session.scalar(
        select(Ticket).where(Ticket.source_entry_id == entry.id)
    )
    if ticket is None:
        raise Conflict("This breakdown has no ticket")

    await tickets_svc.complete_ticket(
        session, ticket=ticket, completed_by=user, completed_at=datetime.now(UTC)
    )
    entry.updated_at = datetime.now(UTC)

    await audit.record(
        session,
        actor_id=user.id,
        action=AuditAction.entry_resolved,
        object_type="entry",
        object_id=entry.id,
        after=svc.audit_snapshot(entry, extra={"status": "resolved"}),
    )
    await notifications.notify_breakdown_resolved(session, entry, user)
    result = svc.serialize_entry(entry)
    await session.commit()
    return EntryOut(**result)
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `.venv/bin/pytest tests/test_tickets.py tests/test_entries.py -v`
Expected: PASS, including the `again.status_code == 409` case (now raised by `complete_ticket`, not a bespoke `entry.status is EntryStatus.resolved` check).

- [ ] **Step 8: Commit**

```bash
git add backend/app/services/tickets.py backend/app/services/entries.py \
  backend/app/api/entries.py backend/tests/test_tickets.py
git commit -m "Complete tickets from either the resolve endpoint or a Work Done session"
```

---

### Task 7: `work_done_attendees` — FK-backed multi-select

**Files:**
- Modify: `backend/app/models/entry.py`
- Modify: `backend/app/schemas/entry.py`
- Modify: `backend/app/services/entries.py` (`_build_detail`, `serialize_data`, `reporter_name`/`REPORTER_COLUMN`)
- Create: `backend/alembic/versions/0026_work_done_attendees.py`
- Test: `backend/tests/test_entries.py` (extend)

**Interfaces:**
- Produces: `WorkDoneAttendee` model; `WorkDoneData.attendee_user_ids: list[str]`. Consumed by Flutter Task 14/15 (the multi-select posts a list of `users.id` values).

- [ ] **Step 1: Write the failing test**

```python
async def test_work_done_attendees_round_trip_by_user_id(client: AsyncClient) -> None:
    h = await auth_headers(client)
    me = await client.get("/auth/me", headers=h)
    my_id = me.json()["id"]

    payload = work_done()
    payload["data"]["attendee_user_ids"] = [my_id]
    r = await client.post("/entries", json=payload, headers=h)
    assert r.status_code == 201, r.text
    attendees = r.json()["data"]["attendees"]
    assert attendees == [{"user_id": my_id, "name": me.json()["name"]}]
```

Check `/auth/me`'s actual response shape first (`grep -n '"id"\|"name"' backend/app/api/auth.py` or read `backend/app/schemas/user.py`) and adjust the field names above to match exactly — don't guess.

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/pytest tests/test_entries.py -k attendees_round_trip -v`
Expected: FAIL — `attendee_user_ids` rejected by `extra="forbid"`.

- [ ] **Step 3: Add the `WorkDoneAttendee` model**

In `backend/app/models/entry.py`, add after `WorkDoneEntry`:

```python
class WorkDoneAttendee(Base):
    """One engineer/mechanic who worked a Work Done session — a multi-select,
    replacing the old single free-text `employee` column."""

    __tablename__ = "work_done_attendees"

    work_done_entry_id: Mapped[str] = mapped_column(
        String(32),
        ForeignKey("work_done_entries.entry_id", ondelete="CASCADE"),
        primary_key=True,
    )
    user_id: Mapped[str] = mapped_column(
        String(32), ForeignKey("users.id", ondelete="RESTRICT"), primary_key=True
    )

    user: Mapped[User] = relationship(lazy="joined")
```

Add the relationship to `WorkDoneEntry`:

```python
    attendees: Mapped[list[WorkDoneAttendee]] = relationship(
        cascade="all, delete-orphan", lazy="selectin"
    )
```

- [ ] **Step 4: Update `WorkDoneData`**

```python
class WorkDoneData(_DataBase):
    shift: Shift | None = None
    bus_no: BusNo
    reported_defects: Req = Field(min_length=1)
    defect_source: OptText = None
    defect_type: OptText = None
    attended_details: OptText = None
    spare_parts_used: OptText = None
    employee: OptText = None
    supervisor: OptText = None
    ticket_id: OptText = None
    completes_ticket: bool = False
    completion_time: HHMM | None = None
    attendee_user_ids: list[str] = Field(default_factory=list)

    @model_validator(mode="after")
    def _completion_requires_ticket_and_time(self) -> "WorkDoneData":
        if self.completes_ticket and not self.ticket_id:
            raise ValueError("completes_ticket requires ticket_id")
        if self.completes_ticket and not self.completion_time:
            raise ValueError("completes_ticket requires completion_time")
        return self
```

- [ ] **Step 5: Resolve attendees in `_build_detail`, and set them post-flush**

Attendees are a child collection keyed by `entry_id`, which doesn't exist until the parent `WorkDoneEntry` row is flushed — same ordering constraint as the ticket side effects in Task 6. Add a resolver and a setter used from `create_entry`/`update_entry`:

```python
async def _resolve_attendees(session: AsyncSession, user_ids: list[str]) -> list[User]:
    if not user_ids:
        return []
    users = (
        await session.scalars(select(User).where(User.id.in_(user_ids)))
    ).all()
    found = {u.id for u in users}
    missing = [uid for uid in user_ids if uid not in found]
    if missing:
        raise ValidationError(
            f"attendee_user_ids: unknown user {missing[0]}",
            {"attendee_user_ids": "unknown user"},
        )
    return list(users)
```

Call it in `_build_detail`'s `work_done` branch to validate eagerly (fail fast before any row is built), but the actual `WorkDoneAttendee` rows are created after flush since they need `entry_id`:

```python
    if register is Register.work_done:
        src = await resolve_defect_source(session, data.defect_source)
        typ = await resolve_defect_type(session, data.defect_type)
        ticket = await _resolve_ticket(session, data.ticket_id)
        await _resolve_attendees(session, data.attendee_user_ids)  # validate only
        row = WorkDoneEntry(
            shift=data.shift,
            reported_defects=data.reported_defects,
            defect_source=src,
            defect_type=typ,
            attended_details=data.attended_details,
            spare_parts_used=data.spare_parts_used,
            employee=data.employee,
            supervisor=data.supervisor,
            ticket_id=ticket.id if ticket else None,
            completes_ticket=data.completes_ticket,
            completion_time=data.completion_time,
        )
        return row, [...]  # unchanged
```

In `create_entry`, after `await session.flush()` and before the ticket side effects, set attendees (validated users are cheap to re-fetch; simplest correct approach — avoid threading them through the tuple return, which would touch every other register's `_build_detail` branch signature):

```python
    session.add(entry)
    await session.flush()
    if register is Register.work_done:
        users = await _resolve_attendees(session, data.attendee_user_ids)
        detail.attendees = [WorkDoneAttendee(user_id=u.id) for u in users]
        await session.flush()
    await _apply_ticket_side_effects(session, entry, detail, creator)
    return entry
```

Do the equivalent in `update_entry` — since `update_entry` deletes and rebuilds `old_detail` wholesale already, attendees are naturally cleared with the old detail row (cascade) and need re-setting the same way after the new detail is flushed:

```python
    detail, searchable = await _build_detail(session, entry.register, data)
    setattr(entry, entry.register.value, detail)
    entry.search_text = _search_text(entry, vehicle, entry.created_by, searchable)
    entry.updated_at = datetime.now(UTC)
    await session.flush()
    if entry.register is Register.work_done:
        users = await _resolve_attendees(session, data.attendee_user_ids)
        detail.attendees = [WorkDoneAttendee(user_id=u.id) for u in users]
        await session.flush()
    await _apply_ticket_side_effects(session, entry, detail, actor)
    return entry
```

Import `WorkDoneAttendee` and `User` (already imported) at the top of `entries.py`.

- [ ] **Step 6: Update `serialize_data` and `reporter_name`/`REPORTER_COLUMN`**

```python
    if entry.register is Register.work_done:
        return {
            "shift": d.shift.value if d.shift else None,
            "bus_no": bus_no,
            "reported_defects": d.reported_defects,
            "defect_source": d.defect_source.name if d.defect_source else None,
            "defect_type": d.defect_type.name if d.defect_type else None,
            "attended_details": d.attended_details,
            "spare_parts_used": d.spare_parts_used,
            "employee": d.employee,
            "supervisor": d.supervisor,
            "ticket_id": d.ticket_id,
            "completes_ticket": d.completes_ticket,
            "completion_time": _hhmm(d.completion_time),
            "attendees": [
                {"user_id": a.user_id, "name": a.user.name} for a in d.attendees
            ],
        }
```

```python
def reporter_name(entry: Entry) -> str:
    detail = entry.detail
    if entry.register is Register.work_done and detail is not None:
        if detail.attendees:
            return detail.attendees[0].user.name
        if (detail.employee or "").strip():
            return detail.employee.strip()
        return entry.created_by.name
    if detail is not None:
        column = REPORTER_COLUMN.get(entry.register)
        if column and entry.register is not Register.breakdown:
            value = (getattr(detail, column, None) or "").strip()
            if value:
                return value
    return entry.created_by.name
```

(`REPORTER_COLUMN` no longer needs a `work_done` entry since it's now handled above the generic branch — remove `Register.work_done: "employee"` from the dict, but keep the `employee` fallback in `reporter_name` itself until Task 8 actually drops the column.)

- [ ] **Step 7: Write the migration**

Create `backend/alembic/versions/0026_work_done_attendees.py`:

```python
"""work_done_attendees

Revision ID: 0026
Revises: 0025
Create Date: 2026-09-24
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0026"
down_revision = "0025"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "work_done_attendees",
        sa.Column(
            "work_done_entry_id",
            sa.String(32),
            sa.ForeignKey("work_done_entries.entry_id", ondelete="CASCADE"),
            primary_key=True,
        ),
        sa.Column(
            "user_id",
            sa.String(32),
            sa.ForeignKey("users.id", ondelete="RESTRICT"),
            primary_key=True,
        ),
    )


def downgrade() -> None:
    op.drop_table("work_done_attendees")
```

- [ ] **Step 8: Run migrations and tests**

Run: `.venv/bin/alembic upgrade head`
Run: `.venv/bin/pytest tests/test_entries.py tests/test_tickets.py -v`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add backend/app/models/entry.py backend/app/schemas/entry.py \
  backend/app/services/entries.py backend/alembic/versions/0026_work_done_attendees.py \
  backend/tests/test_entries.py
git commit -m "Add FK-backed multi-select attendees for Work Done sessions"
```

---

### Task 8: Drop `employee` from Work Done

**Files:**
- Modify: `backend/app/models/entry.py`
- Modify: `backend/app/schemas/entry.py`
- Modify: `backend/app/services/entries.py`
- Create: `backend/alembic/versions/0027_drop_work_done_employee.py`
- Test: `backend/tests/test_entries.py` (extend), `backend/tests/test_tickets.py` (fix the `work_done()` fixture's `"employee"` key)

**Interfaces:**
- Consumes: `WorkDoneAttendee` (Task 7).
- Produces: nothing new — this is a removal.

- [ ] **Step 1: Update the fixtures and write the failing test**

In `backend/tests/test_entries.py`, remove `"employee": "S. Pawar",` from the `work_done()` fixture (used across many existing tests — check each still passes without it; none of the existing assertions in `test_entries.py` reference `body["data"]["employee"]` per the earlier read of this file, so this should be safe).

Add:

```python
async def test_work_done_no_longer_accepts_employee(client: AsyncClient) -> None:
    h = await auth_headers(client)
    payload = work_done()
    payload["data"]["employee"] = "S. Pawar"
    r = await client.post("/entries", json=payload, headers=h)
    assert r.status_code == 400
    assert "employee" in r.json()["error"]["fields"] or "employee" in r.json()["error"]["message"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/pytest tests/test_entries.py -k no_longer_accepts_employee -v`
Expected: FAIL — `employee` is still accepted (201, not 400).

- [ ] **Step 3: Remove `employee` from the model, schema, and service code**

`backend/app/models/entry.py` — remove the `employee` column from `WorkDoneEntry`.

`backend/app/schemas/entry.py` — remove `employee: OptText = None` from `WorkDoneData`.

`backend/app/services/entries.py`:
- `_build_detail`'s `work_done` branch: remove `employee=data.employee,` and remove `data.employee,` from the searchable list.
- `serialize_data`'s `work_done` branch: remove `"employee": d.employee,`.
- `reporter_name`: remove the `employee` fallback block added in Task 7 Step 6 (attendees-or-created_by only now):

```python
def reporter_name(entry: Entry) -> str:
    detail = entry.detail
    if entry.register is Register.work_done and detail is not None:
        if detail.attendees:
            return detail.attendees[0].user.name
        return entry.created_by.name
    if detail is not None:
        column = REPORTER_COLUMN.get(entry.register)
        if column and entry.register is not Register.breakdown:
            value = (getattr(detail, column, None) or "").strip()
            if value:
                return value
    return entry.created_by.name
```

- [ ] **Step 4: Write the migration**

Create `backend/alembic/versions/0027_drop_work_done_employee.py`:

```python
"""drop work_done_entries.employee

Revision ID: 0027
Revises: 0026
Create Date: 2026-09-24

Replaced by work_done_attendees (Task 7) — same tradeoff already accepted
for breakdown_time: old rows keep this text only in audit-log snapshots
taken at write time, not in the live schema going forward.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0027"
down_revision = "0026"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.drop_column("work_done_entries", "employee")


def downgrade() -> None:
    op.add_column(
        "work_done_entries", sa.Column("employee", sa.String(255), nullable=True)
    )
```

- [ ] **Step 5: Run migrations and the full backend suite**

Run: `.venv/bin/alembic upgrade head`
Run: `.venv/bin/pytest -v`
Expected: PASS across the whole suite — this is the point to catch any other test file referencing Work Done's `employee` field. Fix any stragglers found (search first: `grep -rn '"employee"' backend/tests/`).

- [ ] **Step 6: Commit**

```bash
git add backend/app/models/entry.py backend/app/schemas/entry.py \
  backend/app/services/entries.py backend/alembic/versions/0027_drop_work_done_employee.py \
  backend/tests/test_entries.py backend/tests/test_tickets.py
git commit -m "Drop Work Done's free-text employee column"
```

---

### Task 9: One Work Done session per ticket per shift (trigger-enforced), and the spec correction

**Files:**
- Create: `backend/alembic/versions/0028_work_done_shift_uniqueness.py`
- Modify: `docs/superpowers/specs/2026-09-24-breakdown-work-done-linkage-design.md`
- Test: `backend/tests/test_entries.py` (extend)

**Interfaces:**
- Produces: a database-level guarantee; no new Python interface. `IntegrityError` (or its FastAPI-mapped 500 unless caught) surfaces when violated — Step 4 below maps it to a clean 409.

- [ ] **Step 1: Write the failing test**

```python
async def test_two_sessions_same_ticket_date_shift_is_rejected(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    bd = await client.post("/entries", json=breakdown(), headers=h)
    bd_id = bd.json()["id"]
    tickets = await client.get(
        "/tickets/search",
        params={"site": "MBMT", "register": "breakdown", "q": bd_id},
        headers=h,
    )
    ticket_id = tickets.json()[0]["ticket_id"]

    first = work_done()
    first["data"]["ticket_id"] = ticket_id
    r1 = await client.post("/entries", json=first, headers=h)
    assert r1.status_code == 201, r1.text

    second = work_done()
    second["data"]["ticket_id"] = ticket_id  # same shift ("A"), same date, same ticket
    r2 = await client.post("/entries", json=second, headers=h)
    assert r2.status_code == 409, r2.text


async def test_two_tickets_same_bus_same_shift_both_get_sessions(
    client: AsyncClient,
) -> None:
    """Ticket-scoped, not vehicle-scoped — resolves the same-shift limitation."""
    h = await auth_headers(client)
    bd1 = await client.post("/entries", json=breakdown(), headers=h)
    coolant_payload = coolant()
    coolant_payload["data"]["bus_no"] = "MH40LY1895"  # same bus as the breakdown
    bd2_source = await client.post("/entries", json=coolant_payload, headers=h)
    raised = await client.post(
        f"/entries/{bd2_source.json()['id']}/raise_ticket", headers=h
    )
    assert raised.status_code == 200

    t1 = (
        await client.get(
            "/tickets/search",
            params={"site": "MBMT", "register": "breakdown", "q": bd1.json()["id"]},
            headers=h,
        )
    ).json()[0]["ticket_id"]
    t2 = (
        await client.get(
            "/tickets/search",
            params={"site": "MBMT", "register": "coolant", "q": bd2_source.json()["id"]},
            headers=h,
        )
    ).json()[0]["ticket_id"]

    wd1 = work_done(bus="MH40LY1895")
    wd1["data"]["ticket_id"] = t1
    wd2 = work_done(bus="MH40LY1895")
    wd2["data"]["ticket_id"] = t2

    r1 = await client.post("/entries", json=wd1, headers=h)
    r2 = await client.post("/entries", json=wd2, headers=h)
    assert r1.status_code == 201, r1.text
    assert r2.status_code == 201, r2.text
```

- [ ] **Step 2: Run tests to verify the first fails and the second already passes**

Run: `.venv/bin/pytest tests/test_entries.py -k "same_ticket_date_shift or same_bus_same_shift" -v`
Expected: `test_two_sessions_same_ticket_date_shift_is_rejected` FAILS (no constraint yet, both inserts succeed → 201, not 409). `test_two_tickets_same_bus_same_shift_both_get_sessions` should already PASS, since nothing today prevents it — this test exists to lock in that the *coming* constraint doesn't regress this case.

- [ ] **Step 3: Write the trigger migration**

Create `backend/alembic/versions/0028_work_done_shift_uniqueness.py`:

```python
"""one work done session per ticket per shift per day

Revision ID: 0028
Revises: 0027
Create Date: 2026-09-24

A plain table-level UniqueConstraint can't express this: `entry_date` lives
on the `entries` header, `ticket_id`/`shift` live on `work_done_entries`.
Enforced with a trigger instead of an app-level check-then-insert, which
would race under two devices submitting the same shift concurrently.
Scoped to `ticket_id IS NOT NULL` — unlinked/general work has no such limit.
"""
from __future__ import annotations

from alembic import op

revision = "0028"
down_revision = "0027"
branch_labels = None
depends_on = None

_FUNCTION = """
CREATE OR REPLACE FUNCTION check_work_done_shift_uniqueness() RETURNS trigger AS $$
DECLARE
    conflict_id varchar;
BEGIN
    IF NEW.ticket_id IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT wd.entry_id INTO conflict_id
    FROM work_done_entries wd
    JOIN entries e ON e.id = wd.entry_id
    JOIN entries new_e ON new_e.id = NEW.entry_id
    WHERE wd.ticket_id = NEW.ticket_id
      AND wd.shift IS NOT DISTINCT FROM NEW.shift
      AND e.entry_date = new_e.entry_date
      AND wd.entry_id != NEW.entry_id
    LIMIT 1;
    IF conflict_id IS NOT NULL THEN
        RAISE EXCEPTION
            'work_done_shift_uniqueness: ticket % already has a session for this date/shift (entry %)',
            NEW.ticket_id, conflict_id
            USING ERRCODE = 'unique_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
"""

_TRIGGER = """
CREATE TRIGGER trg_work_done_shift_uniqueness
BEFORE INSERT OR UPDATE ON work_done_entries
FOR EACH ROW EXECUTE FUNCTION check_work_done_shift_uniqueness();
"""


def upgrade() -> None:
    op.execute(_FUNCTION)
    op.execute(_TRIGGER)


def downgrade() -> None:
    op.execute("DROP TRIGGER IF EXISTS trg_work_done_shift_uniqueness ON work_done_entries")
    op.execute("DROP FUNCTION IF EXISTS check_work_done_shift_uniqueness()")
```

- [ ] **Step 4: Map the Postgres error to a clean 409**

The trigger raises with `ERRCODE = 'unique_violation'` (Postgres code `23505`), which SQLAlchemy surfaces as `sqlalchemy.exc.IntegrityError` wrapping an `asyncpg.exceptions.UniqueViolationError`. Catch it where the flush happens. In `backend/app/services/entries.py`, wrap the `create_entry`/`update_entry` flush calls:

```python
from sqlalchemy.exc import IntegrityError
```

```python
    session.add(entry)
    try:
        await session.flush()
    except IntegrityError as exc:
        if "work_done_shift_uniqueness" in str(exc.orig):
            raise Conflict(
                "This ticket already has a Work Done session for this date and shift"
            ) from exc
        raise
```

Apply the same wrapping to `update_entry`'s flush. Import `Conflict` from `app.errors` at the top of `entries.py` (check if already imported before adding — it may already be, from `_resolve_ticket`'s use in Task 5/6).

- [ ] **Step 5: Run migrations and tests**

Run: `.venv/bin/alembic upgrade head`
Run: `.venv/bin/pytest tests/test_entries.py -v`
Expected: PASS.

- [ ] **Step 6: Correct the spec doc**

In `docs/superpowers/specs/2026-09-24-breakdown-work-done-linkage-design.md`, find the "Uniqueness constraint" decision-table row and the "New constraint" bullet under `work_done_entries` in the Data Model section. Replace the claim that it "becomes a plain table-level `UniqueConstraint`... since `ticket_id` now lives directly on this table" with the corrected trigger-based explanation (mirroring the Global Constraints note at the top of this plan). This is a documentation-only edit — no code changes.

- [ ] **Step 7: Commit**

```bash
git add backend/alembic/versions/0028_work_done_shift_uniqueness.py \
  backend/app/services/entries.py backend/tests/test_entries.py \
  docs/superpowers/specs/2026-09-24-breakdown-work-done-linkage-design.md
git commit -m "Enforce one Work Done session per ticket per shift via DB trigger"
```

---

### Task 10: `breakdown_entries` — drop `breakdown_time`, rename to `reported_time`, backfill tickets

**Files:**
- Modify: `backend/app/models/entry.py` (`BreakdownEntry`)
- Modify: `backend/app/schemas/entry.py` (`BreakdownData`)
- Modify: `backend/app/services/entries.py` (`_build_detail`, `serialize_data`)
- Modify: `backend/app/services/notifications.py` (grep for `breakdown_time`/`mechanic_reported_time` usage first — SLA logic likely reads one of these)
- Modify: `app/... ` — **not this task**, Flutter changes are Task 19.
- Create: `backend/alembic/versions/0029_breakdown_reported_time_and_backfill.py`
- Test: `backend/tests/test_entries.py`, `backend/tests/test_tickets.py` (fix all `breakdown()` fixtures)

**Interfaces:**
- Produces: `BreakdownEntry.reported_time` (renamed, `NOT NULL`); `breakdown_time` column gone. Backfills a `Ticket` row for every pre-existing breakdown.

- [ ] **Step 1: Check for other readers of the columns being changed**

Run: `grep -rn "breakdown_time\|mechanic_reported_time" backend/app/` — read every hit before editing. At minimum expect `models/entry.py`, `schemas/entry.py`, `services/entries.py`; check `services/notifications.py` and `services/dmr.py`/`services/reports.py` too, since the DMR/breakdown-loss reporting reads breakdown fields — if any of those reference `breakdown_time` specifically (not `mechanic_reported_time`/`attended_time`), update them to stop, since the field is being removed entirely (not renamed).

- [ ] **Step 2: Write the failing test**

Update every `breakdown()` fixture in `backend/tests/test_entries.py` and `backend/tests/test_tickets.py` to use `"reported_time"` instead of `"mechanic_reported_time"`, and remove `"breakdown_time"` entirely:

```python
def breakdown() -> dict:
    return {
        "register": "breakdown",
        "site": "MBMT",
        "date": TODAY,
        "data": {
            "bus_no": "MH40LY1895",
            "driver_id": "DRV221",
            "route": "7",
            "location": "Kashimira signal",
            "complaint": "HV contactor tripped, bus immobile",
            "reported_time": "14:45",
            "loss_km": 18.5,
        },
    }
```

Update `test_breakdown_opens_and_resolves_once` (`backend/tests/test_entries.py`), which currently asserts `entry["data"]["breakdown_time"] == "14:20"` — remove that assertion (the field no longer exists) and add `assert entry["data"]["reported_time"] == "14:45"`.

Add a new test for the required-field behavior:

```python
async def test_breakdown_requires_reported_time(client: AsyncClient) -> None:
    h = await auth_headers(client)
    payload = breakdown()
    del payload["data"]["reported_time"]
    r = await client.post("/entries", json=payload, headers=h)
    assert r.status_code == 400
    assert r.json()["error"]["fields"].get("reported_time") == "required"
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `.venv/bin/pytest tests/test_entries.py tests/test_tickets.py -v`
Expected: FAIL — `reported_time`/`breakdown_time` don't exist yet as named; every `breakdown()`-fixture-using test that touches these fields breaks until the schema/model catch up.

- [ ] **Step 4: Update the model**

In `backend/app/models/entry.py`'s `BreakdownEntry`, replace:

```python
    breakdown_time: Mapped[time_t | None] = mapped_column(Time, nullable=True)
    mechanic_reported_time: Mapped[time_t | None] = mapped_column(Time, nullable=True)
    attended_time: Mapped[time_t | None] = mapped_column(Time, nullable=True)
```

with:

```python
    reported_time: Mapped[time_t] = mapped_column(Time, nullable=False)
    attended_time: Mapped[time_t | None] = mapped_column(Time, nullable=True)
```

- [ ] **Step 5: Update the schema**

In `backend/app/schemas/entry.py`'s `BreakdownData`, replace:

```python
    breakdown_time: HHMM | None = None
    mechanic_reported_time: HHMM | None = None
    attended_time: HHMM | None = None
```

with:

```python
    reported_time: HHMM
```

(`attended_time` is removed from the writable schema entirely now — it's server-computed via `mark_attended`, Task 6. A client that still sends it will get a clean `extra="forbid"` 400, which is correct: nothing should be writing it directly anymore.)

- [ ] **Step 6: Update `_build_detail` and `serialize_data`**

`_build_detail`'s breakdown branch:

```python
    if register is Register.breakdown:
        typ = await resolve_defect_type(session, data.defect_type)
        row = BreakdownEntry(
            defect_type=typ,
            driver_id=data.driver_id,
            route=data.route,
            location=data.location,
            complaint=data.complaint,
            reported_time=data.reported_time,
            loss_km=data.loss_km,
            attended_details=data.attended_details,
            remarks=data.remarks,
            supervisor=data.supervisor,
        )
```

`serialize_data`'s breakdown branch:

```python
    if entry.register is Register.breakdown:
        return {
            "bus_no": bus_no,
            "defect_type": d.defect_type.name if d.defect_type else None,
            "driver_id": d.driver_id,
            "route": d.route,
            "location": d.location,
            "complaint": d.complaint,
            "reported_time": _hhmm(d.reported_time),
            "attended_time": _hhmm(d.attended_time),
            "loss_km": _num(d.loss_km),
            "attended_details": d.attended_details,
            "remarks": d.remarks,
            "supervisor": d.supervisor,
            "resolved_at": _ist_iso(d.resolved_at),
        }
```

- [ ] **Step 7: Write the migration — rename, backfill, drop, backfill tickets**

Create `backend/alembic/versions/0029_breakdown_reported_time_and_backfill.py`:

```python
"""breakdown reported_time + backfill tickets for existing breakdowns

Revision ID: 0029
Revises: 0028
Create Date: 2026-09-24

Collapses breakdown timing to reported_time/attended_time/resolved_at.
breakdown_time (the moment of breakdown itself, distinct from when it was
reported) is dropped — confirmed acceptable data loss on existing rows.
Every pre-existing breakdown gets a backfilled ticket so it shows up in the
new linked-sessions UI immediately; historical Work Done rows are not
retroactively linked (no reliable way to infer which session belongs to
which breakdown — this feature closes that gap only going forward).
"""
from __future__ import annotations

import uuid

import sqlalchemy as sa
from alembic import op

revision = "0029"
down_revision = "0028"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # 1. Backfill nulls before the column becomes NOT NULL — closest available
    #    signal for pre-existing rows is the header's own entry_time.
    op.execute(
        """
        UPDATE breakdown_entries be
        SET mechanic_reported_time = e.entry_time
        FROM entries e
        WHERE be.entry_id = e.id
          AND be.mechanic_reported_time IS NULL
          AND e.entry_time IS NOT NULL
        """
    )
    # A handful of rows may still be null if entry_time itself was never set —
    # fall back to midnight rather than leaving the migration stuck.
    op.execute(
        "UPDATE breakdown_entries SET mechanic_reported_time = '00:00' "
        "WHERE mechanic_reported_time IS NULL"
    )

    op.alter_column(
        "breakdown_entries",
        "mechanic_reported_time",
        new_column_name="reported_time",
        existing_type=sa.Time(),
        nullable=False,
    )
    op.drop_column("breakdown_entries", "breakdown_time")

    # 2. Backfill a ticket for every existing breakdown.
    connection = op.get_bind()
    rows = connection.execute(
        sa.text(
            "SELECT e.id, e.created_by_id, e.status, be.resolved_at, be.resolved_by_id "
            "FROM entries e JOIN breakdown_entries be ON be.entry_id = e.id "
            "WHERE e.register = 'breakdown'"
        )
    ).fetchall()
    for row in rows:
        ticket_id = uuid.uuid4().hex
        status = "completed" if row.status == "resolved" else "open"
        connection.execute(
            sa.text(
                "INSERT INTO tickets "
                "(id, source_entry_id, status, completed_at, completed_by_id, "
                " attended_at, created_at, created_by_id) "
                "VALUES (:id, :source_entry_id, :status, :completed_at, "
                " :completed_by_id, NULL, now(), :created_by_id)"
            ),
            {
                "id": ticket_id,
                "source_entry_id": row.id,
                "status": status,
                "completed_at": row.resolved_at,
                "completed_by_id": row.resolved_by_id,
                "created_by_id": row.created_by_id,
            },
        )


def downgrade() -> None:
    # Tickets backfilled by this migration are not distinguishable from ones
    # created normally after upgrade — downgrade leaves them in place
    # (harmless: `tickets` is dropped in Task 1's downgrade if you roll back
    # that far) and only reverses the column change.
    op.add_column(
        "breakdown_entries", sa.Column("breakdown_time", sa.Time(), nullable=True)
    )
    op.alter_column(
        "breakdown_entries",
        "reported_time",
        new_column_name="mechanic_reported_time",
        existing_type=sa.Time(),
        nullable=True,
    )
```

- [ ] **Step 8: Run migrations and the full backend suite**

Run: `.venv/bin/alembic upgrade head`
Run: `.venv/bin/pytest -v`
Expected: PASS across the whole suite.

- [ ] **Step 9: Commit**

```bash
git add backend/app/models/entry.py backend/app/schemas/entry.py \
  backend/app/services/entries.py \
  backend/alembic/versions/0029_breakdown_reported_time_and_backfill.py \
  backend/tests/test_entries.py backend/tests/test_tickets.py
git commit -m "Collapse breakdown timing to reported/attended/resolved, backfill tickets"
```

---

### Task 11: Breakdown GET response gains `linked_sessions`

**Files:**
- Modify: `backend/app/schemas/entry.py` (`EntryOut`, or a breakdown-specific extension)
- Modify: `backend/app/api/entries.py` (`get_entry`)
- Test: `backend/tests/test_tickets.py` (extend)

**Interfaces:**
- Produces: `EntryOut.linked_sessions: list[dict] | None` — consumed by Flutter Task 18 (Breakdowns screen linked-sessions list).

- [ ] **Step 1: Write the failing test**

```python
async def test_breakdown_get_lists_its_linked_work_done_sessions(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    me = await client.get("/auth/me", headers=h)
    my_id = me.json()["id"]
    bd = await client.post("/entries", json=breakdown(), headers=h)
    bd_id = bd.json()["id"]
    ticket_id = (
        await client.get(
            "/tickets/search",
            params={"site": "MBMT", "register": "breakdown", "q": bd_id},
            headers=h,
        )
    ).json()[0]["ticket_id"]

    wd = work_done()
    wd["data"]["ticket_id"] = ticket_id
    wd["data"]["attendee_user_ids"] = [my_id]
    await client.post("/entries", json=wd, headers=h)

    bd_after = await client.get(f"/entries/{bd_id}", headers=h)
    sessions = bd_after.json()["linked_sessions"]
    assert len(sessions) == 1
    assert sessions[0]["shift"] == "A"
    assert sessions[0]["attendees"] == [{"user_id": my_id, "name": me.json()["name"]}]
    assert sessions[0]["completes_ticket"] is False


async def test_non_breakdown_get_has_no_linked_sessions(client: AsyncClient) -> None:
    h = await auth_headers(client)
    created = await client.post("/entries", json=coolant(), headers=h)
    got = await client.get(f"/entries/{created.json()['id']}", headers=h)
    assert got.json()["linked_sessions"] is None
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv/bin/pytest tests/test_tickets.py -k linked_sessions -v`
Expected: FAIL — `KeyError`/`None` for `linked_sessions`, key doesn't exist in the response.

- [ ] **Step 3: Add `linked_sessions` to `EntryOut` and populate it**

In `backend/app/schemas/entry.py`, add to `EntryOut`:

```python
class EntryOut(BaseModel):
    id: str
    register: Register
    site: str
    date: date_t
    entry_time: HHMM | None
    entered_by: str = ""
    created_by: UserBrief
    created_at: ISTDateTime
    updated_at: ISTDateTime | None
    status: EntryStatus
    photo_url: str | None
    data: dict[str, Any]
    #: Work Done sessions logged against this entry's ticket. Populated only
    #: for entries that can have a ticket (breakdown, coolant, driver
    #: complaint, PM/docking); null everywhere else, including work_done
    #: entries themselves.
    linked_sessions: list[dict[str, Any]] | None = None
```

In `backend/app/services/entries.py`, add a function that builds this list, used by both `get_entry` and (optionally) list/update responses if useful later — keep it scoped to `get_entry` only for now per the spec:

```python
async def load_linked_sessions(
    session: AsyncSession, entry: Entry
) -> list[dict[str, Any]] | None:
    if entry.register not in TICKETABLE_REGISTERS:
        return None
    ticket = await session.scalar(select(Ticket).where(Ticket.source_entry_id == entry.id))
    if ticket is None:
        return []
    rows = (
        await session.scalars(
            select(WorkDoneEntry)
            .join(Entry, Entry.id == WorkDoneEntry.entry_id)
            .where(WorkDoneEntry.ticket_id == ticket.id)
            .order_by(Entry.entry_date, Entry.created_at)
        )
    ).unique().all()
    out = []
    for wd in rows:
        wd_entry = await session.get(Entry, wd.entry_id)
        out.append(
            {
                "entry_id": wd.entry_id,
                "entry_date": wd_entry.entry_date.isoformat(),
                "shift": wd.shift.value if wd.shift else None,
                "reported_defects": wd.reported_defects,
                "attendees": [
                    {"user_id": a.user_id, "name": a.user.name} for a in wd.attendees
                ],
                "completes_ticket": wd.completes_ticket,
            }
        )
    return out
```

Import `TICKETABLE_REGISTERS` from `app.services.tickets` (rather than redefining it) at the top of `entries.py`.

In `backend/app/api/entries.py`'s `get_entry`:

```python
@router.get("/{entry_id}", response_model=EntryOut)
async def get_entry(
    entry_id: str, user: CurrentUser, session: SessionDep
) -> EntryOut:
    entry = await _load(session, entry_id)
    assert_site_permission(user, entry.site_code, "em_entry:read")
    result = svc.serialize_entry(entry)
    result["linked_sessions"] = await svc.load_linked_sessions(session, entry)
    return EntryOut(**result)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `.venv/bin/pytest tests/test_tickets.py -v`
Expected: PASS.

- [ ] **Step 5: Run the full backend suite one more time**

Run: `.venv/bin/pytest -v`
Expected: PASS. This closes out the backend half of the plan.

- [ ] **Step 6: Commit**

```bash
git add backend/app/schemas/entry.py backend/app/services/entries.py \
  backend/app/api/entries.py backend/tests/test_tickets.py
git commit -m "Expose linked Work Done sessions on a breakdown's GET response"
```

---

### Task 12: Flutter — `Ticket` model, `TicketRepository`, API + Fake implementations

**Files:**
- Create: `app/lib/models/ticket.dart`
- Modify: `app/lib/data/repositories.dart`
- Modify: `app/lib/data/api/api_repositories.dart`
- Modify: `app/test/support/fake_repositories.dart`
- Modify: `app/lib/state/providers.dart` (repository provider wiring)
- Test: `app/test/api_contract_test.dart` (extend)

**Interfaces:**
- Produces: `TicketSearchResult{ticketId, title, entryDate, status}`; `abstract interface class TicketRepository { Future<List<TicketSearchResult>> search({required String site, String? register, String? q}); Future<RegisterEntry> raiseTicket(String entryId); }`. Consumed by Task 15 (Work Done form ticket picker) and Task 17 (Registers "Raise ticket" action).

- [ ] **Step 1: Write the failing test**

`api_contract_test.dart`'s real harness is `clientServing(Map<String, ({int status, String body})>)` (loads bodies via `fixture('name')` from `test/fixtures/*.json`) for parsing tests, and a raw `http.testing.MockClient` + `ApiClient(baseUrl: ..., httpClient: mock)` for tests that need to inspect the outbound request or that don't have a captured fixture yet (see `test('the create body uses the API field names', ...)` at line ~101). `/tickets/search` is a brand-new endpoint with no captured fixture, so use the inline-`MockClient` style:

```dart
group('ticket search', () {
  test('a ticket search result parses onto TicketSearchResult', () async {
    final mock = MockClient((http.Request request) async {
      return http.Response(
        jsonEncode(<dynamic>[
          <String, dynamic>{
            'ticket_id': 't1',
            'title': 'HV contactor tripped · MH40LY1895',
            'entry_date': '2026-09-24',
            'status': 'open',
          },
        ]),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });
    final client = ApiClient(baseUrl: 'http://api.test/api/v1', httpClient: mock);

    final results = await ApiTicketRepository(client).search(site: 'MBMT');
    expect(results, hasLength(1));
    expect(results.first.title, contains('MH40LY1895'));
  });
});
```

Add `import 'package:transvolt_em/models/ticket.dart';` to the test file's imports. The response is a **bare JSON array** (per the backend's `response_model=list[TicketSearchResult]` from Task 2), not an `{"items": [...]}` envelope — `ApiTicketRepository.search` must parse it as `json as List<dynamic>` directly, no `itemsOf()` unwrap.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/api_contract_test.dart -N "ticket search"`
Expected: FAIL — `ApiTicketRepository` doesn't exist.

- [ ] **Step 3: Create the `Ticket` model**

Create `app/lib/models/ticket.dart`:

```dart
import 'package:flutter/foundation.dart';

/// One open ticket, as returned by a title/ID search — the picker's option,
/// not the full ticket record (the app never needs more than this to link
/// a Work Done session to it).
@immutable
class TicketSearchResult {
  const TicketSearchResult({
    required this.ticketId,
    required this.title,
    required this.entryDate,
    required this.status,
  });

  final String ticketId;
  final String title;
  final String entryDate;
  final String status;

  factory TicketSearchResult.fromJson(Map<String, dynamic> json) =>
      TicketSearchResult(
        ticketId: json['ticket_id'] as String,
        title: json['title'] as String,
        entryDate: json['entry_date'] as String,
        status: json['status'] as String,
      );
}
```

- [ ] **Step 4: Add `TicketRepository` to `repositories.dart`**

In `app/lib/data/repositories.dart`, add near the Entries section:

```dart
// ─── Tickets ──────────────────────────────────────────────────────────────

/// Search for an open ticket to link a Work Done session to, and raise a new
/// ticket on a source entry that doesn't have one yet (breakdowns get theirs
/// automatically and never need [raiseTicket]).
abstract interface class TicketRepository {
  Future<List<TicketSearchResult>> search({
    required String site,
    String? register,
    String? q,
  });

  Future<RegisterEntry> raiseTicket(String entryId);
}
```

Add the import at the top: `import '../models/ticket.dart';`.

- [ ] **Step 5: Implement `ApiTicketRepository`**

In `app/lib/data/api/api_repositories.dart`, add near `ApiEntryRepository`:

```dart
class ApiTicketRepository implements TicketRepository {
  ApiTicketRepository(this._api);

  final ApiClient _api;

  @override
  Future<List<TicketSearchResult>> search({
    required String site,
    String? register,
    String? q,
  }) async {
    final json = await _api.get(
      '/tickets/search',
      query: <String, String>{
        'site': site,
        if (register != null) 'register': register,
        if (q != null && q.isNotEmpty) 'q': q,
      },
    );
    return (json as List<dynamic>)
        .map((j) => TicketSearchResult.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<RegisterEntry> raiseTicket(String entryId) async {
    final json = await _api.post('/entries/$entryId/raise_ticket');
    return _entryFromWire(json as Map<String, dynamic>);
  }
}
```

`raiseTicket` needs the same wire-parsing `ApiEntryRepository._fromWire` already does — that method is currently private (`_fromWire`) to `ApiEntryRepository`. Extract it to a top-level function `_entryFromWire` in this file (used by both classes) rather than duplicating the parsing logic:

- Rename `ApiEntryRepository._fromWire` to a top-level function `_entryFromWire(Map<String, dynamic> json)` (move it out of the class body, drop the `RegisterEntry` in front since it's already top-level-scoped in the file).
- Update every call site inside `ApiEntryRepository` (`fetchEntries`, `createEntry`, `updateEntry`, `setStatus`) from `_fromWire(...)` to `_entryFromWire(...)`.

Import `TicketSearchResult` at the top: `import '../../models/ticket.dart';`.

- [ ] **Step 6: Implement `FakeTicketRepository`**

In `app/test/support/fake_repositories.dart`, add:

```dart
class FakeTicketRepository implements TicketRepository {
  FakeTicketRepository(this._store);

  final FakeStore _store;

  @override
  Future<List<TicketSearchResult>> search({
    required String site,
    String? register,
    String? q,
  }) async {
    await Future<void>.delayed(_latency);
    final needle = (q ?? '').toLowerCase();
    return _store.entries
        .where((e) => e.site == site)
        .where((e) => e.isOpen || e.registerId != kBreakdownRegisterId)
        .where((e) => register == null || e.registerId == register)
        .where((e) => needle.isEmpty || entrySummary(e).toLowerCase().contains(needle))
        .map(
          (e) => TicketSearchResult(
            ticketId: e.id,
            title: '${entrySummary(e)} · ${e.busNumber}',
            entryDate: e.date,
            status: 'open',
          ),
        )
        .toList();
  }

  @override
  Future<RegisterEntry> raiseTicket(String entryId) async {
    await Future<void>.delayed(_latency);
    final i = _store.entries.indexWhere((e) => e.id == entryId);
    if (i == -1) throw ApiException('Entry $entryId not found');
    final updated = _store.entries[i].copyWith(status: EntryStatus.open);
    _store.entries[i] = updated;
    return updated;
  }
}
```

This fake is a simplification (it treats the source entry's own id as the "ticket id", since the fake store has no separate ticket concept) — good enough for widget/provider tests that only need a plausible round trip, not real ticket semantics. Add the import `import 'package:transvolt_em/models/ticket.dart';` and `import 'package:transvolt_em/data/registers.dart';` (for `kBreakdownRegisterId`, `entrySummary`) at the top if not already present.

- [ ] **Step 7: Wire the provider**

In `app/lib/state/providers.dart`, find where `entryRepositoryProvider` is defined and add a sibling:

```dart
final ticketRepositoryProvider = Provider<TicketRepository>((ref) {
  return useFakes
      ? FakeTicketRepository(ref.watch(fakeStoreProvider))
      : ApiTicketRepository(ref.watch(apiClientProvider));
});
```

Match whatever conditional (`useFakes`, an environment flag, etc.) the existing `entryRepositoryProvider` definition actually uses — read it first and mirror it exactly rather than inventing a new switch.

- [ ] **Step 8: Run the test to verify it passes**

Run: `flutter test test/api_contract_test.dart -N "ticket search"`
Expected: PASS.

Run the full Flutter test suite to catch any other break from the `_fromWire` → `_entryFromWire` rename:

Run: `flutter test`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add app/lib/models/ticket.dart app/lib/data/repositories.dart \
  app/lib/data/api/api_repositories.dart app/test/support/fake_repositories.dart \
  app/lib/state/providers.dart app/test/api_contract_test.dart
git commit -m "Add TicketRepository with API and fake implementations"
```

---

### Task 13: Flutter — `StaffMember` (ID-carrying) and `MasterDataRepository.staffDirectory()`

**Files:**
- Modify: `app/lib/models/site.dart` (or a new small file, `app/lib/models/staff.dart` — prefer the latter to avoid growing `site.dart` further; check its current size first)
- Modify: `app/lib/data/repositories.dart`
- Modify: `app/lib/data/api/api_repositories.dart`
- Modify: `app/test/support/fake_repositories.dart`
- Modify: `app/lib/state/providers.dart`
- Test: `app/test/api_contract_test.dart` (extend)

**Interfaces:**
- Produces: `StaffMember{id, name}`; `MasterDataRepository.staffDirectory({required String siteCode}) -> Future<List<StaffMember>>`. Consumed by Task 15's attendee multi-select. Leaves `staff()`, `technicianStaff()`, `supervisorStaff()`, `mechanicStaff()` (all `List<String>`) completely untouched — this is a pure addition, not a replacement, since those are still used by Coolant/Complaint/PM's own single-select fields.

- [ ] **Step 1: Write the failing test**

`/master/staff` responses are `itemsOf()`-wrapped (the existing `staff()` implementation at `api_repositories.dart:132-138` calls `itemsOf(json)`), unlike `/tickets/search`'s bare list — mirror that envelope shape:

```dart
group('staff directory', () {
  test('staff directory keeps the id the backend returns', () async {
    final mock = MockClient((http.Request request) async {
      return http.Response(
        jsonEncode(<String, dynamic>{
          'items': <dynamic>[
            <String, dynamic>{
              'id': 'u1',
              'name': 'S. Pawar',
              'user_id': 'TV4022',
              'role': 'executive',
            },
          ],
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });
    final client = ApiClient(baseUrl: 'http://api.test/api/v1', httpClient: mock);

    final staff = await ApiMasterDataRepository(client)
        .staffDirectory(siteCode: 'MBMT');
    expect(staff, hasLength(1));
    expect(staff.first.id, 'u1');
    expect(staff.first.name, 'S. Pawar');
  });
});
```

Add `import 'package:transvolt_em/models/staff.dart';` to the test file's imports.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/api_contract_test.dart -N "staff directory"`
Expected: FAIL — `staffDirectory` doesn't exist.

- [ ] **Step 3: Add the `StaffMember` model**

Create `app/lib/models/staff.dart`:

```dart
import 'package:flutter/foundation.dart';

/// One person from the site's staff roster, with the id the backend needs
/// for an FK-backed pick — unlike the plain-name lists elsewhere in
/// [MasterDataRepository], which exist for free-text-equivalent single
/// selects that don't need to survive a round trip as an id.
@immutable
class StaffMember {
  const StaffMember({required this.id, required this.name});

  final String id;
  final String name;

  factory StaffMember.fromJson(Map<String, dynamic> json) => StaffMember(
        id: json['id'] as String,
        name: json['name'] as String,
      );
}
```

- [ ] **Step 4: Add `staffDirectory` to the repository interface**

In `app/lib/data/repositories.dart`, add to `MasterDataRepository`:

```dart
  /// The site's staff, with ids — for the Work Done attending-mechanics
  /// multi-select, which needs an FK to post, not just a display name.
  Future<List<StaffMember>> staffDirectory({required String siteCode});
```

Add the import: `import '../models/staff.dart';`.

- [ ] **Step 5: Implement in `ApiMasterDataRepository` and `FakeMasterDataRepository`**

In `app/lib/data/api/api_repositories.dart`, add next to `staff()`:

```dart
  @override
  Future<List<StaffMember>> staffDirectory({required String siteCode}) async {
    final json = await _api.get(
      '/master/staff',
      query: <String, String>{'site': siteCode},
    );
    return itemsOf(json)
        .map((j) => StaffMember.fromJson(j as Map<String, dynamic>))
        .toList();
  }
```

Import `StaffMember` at the top.

In `app/test/support/fake_repositories.dart`, add next to `staff()`:

```dart
  @override
  Future<List<StaffMember>> staffDirectory({required String siteCode}) async {
    await Future<void>.delayed(_latency);
    return _store.users
        .where((u) => u.active && u.canAccess(siteCode))
        .map((u) => StaffMember(id: u.id, name: u.name))
        .toList();
  }
```

`_store.users` is `List<AppUser>` (`app/test/support/fake_store.dart:39`), and `AppUser.id` (`app/lib/models/app_user.dart:86`) is the field to use — confirmed the same id space the real API's `StaffOut.id` and `users.id` FK target use, not the `userId` login handle.

- [ ] **Step 6: Run the test to verify it passes**

Run: `flutter test test/api_contract_test.dart -N "staff directory"`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/lib/models/staff.dart app/lib/data/repositories.dart \
  app/lib/data/api/api_repositories.dart app/test/support/fake_repositories.dart \
  app/test/api_contract_test.dart
git commit -m "Add ID-carrying staffDirectory() for the attendee multi-select"
```

---

### Task 14: Flutter — field-map and register-def changes for Work Done

**Files:**
- Modify: `app/lib/data/registers.dart` (`kRegisters`, 'work' entry)
- Modify: `app/lib/data/api/field_map.dart`
- Test: `app/test/api_contract_test.dart` (`group('field map', ...)`)

**Interfaces:**
- Consumes: nothing new.
- Produces: the wire-key mapping later tasks' UI code relies on: `_values['ticketId']` ↔ `ticket_id`, `_values['completesTicket']` ↔ `completes_ticket` (as `"true"`/`""`), `_values['completionTime']` ↔ `completion_time`, `_values['attendeeUserIds']` (comma-joined) ↔ `attendee_user_ids` (JSON array).

- [ ] **Step 1: Write the failing test**

In `app/test/api_contract_test.dart`'s `group('field map', ...)`, add:

```dart
test('work done ticket-link keys round-trip, including the attendee list', () {
  final wire = RegisterFieldMap.toWire('work', <String, String>{
    'ticketId': 't1',
    'completesTicket': 'true',
    'completionTime': '16:00',
    'attendeeUserIds': 'u1,u2',
  });
  expect(wire['ticket_id'], 't1');
  expect(wire['completes_ticket'], true);
  expect(wire['completion_time'], '16:00');
  expect(wire['attendee_user_ids'], <String>['u1', 'u2']);

  final back = RegisterFieldMap.fromWire('work', <String, dynamic>{
    'ticket_id': 't1',
    'completes_ticket': true,
    'completion_time': '16:00',
    'attendees': <dynamic>[
      <String, dynamic>{'user_id': 'u1', 'name': 'A'},
      <String, dynamic>{'user_id': 'u2', 'name': 'B'},
    ],
  });
  expect(back['ticketId'], 't1');
  expect(back['completesTicket'], 'true');
  expect(back['completionTime'], '16:00');
  expect(back['attendeeUserIds'], 'u1,u2');
});

test('employee is no longer a work-done field-map key', () {
  final wire = RegisterFieldMap.toWire('work', <String, String>{'employee': 'X'});
  expect(wire.containsKey('employee'), isFalse);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/api_contract_test.dart -N "field map"`
Expected: FAIL — none of the new keys are mapped yet; `employee` is still mapped.

- [ ] **Step 3: Update `field_map.dart`**

In the `'work'` entry of `_toWire`, remove `'employee': 'employee',` and add:

```dart
    'work': <String, String>{
      'shift': 'shift',
      'bus': 'bus_no',
      'defects': 'reported_defects',
      'source': 'defect_source',
      'defectType': 'defect_type',
      'attended': 'attended_details',
      'spares': 'spare_parts_used',
      'supervisor': 'supervisor',
      'ticketId': 'ticket_id',
      'completesTicket': 'completes_ticket',
      'completionTime': 'completion_time',
      'attendeeUserIds': 'attendee_user_ids',
    },
```

Add two new special-cased key sets alongside `_numericWireKeys`:

```dart
  /// Fields the API sends/accepts as a JSON boolean, not a string.
  static const Set<String> _boolWireKeys = <String>{'completes_ticket'};

  /// Fields the API sends/accepts as a JSON array — the form stores them as
  /// a single comma-joined string, same trick `_numericWireKeys` uses for
  /// numbers.
  static const Set<String> _listWireKeys = <String>{'attendee_user_ids'};
```

Update `toWire` to check these before falling through to the plain-string branch:

```dart
  static Map<String, dynamic> toWire(
    String registerId,
    Map<String, String> data,
  ) {
    final map = _toWire[registerId];
    if (map == null) return <String, dynamic>{};

    final out = <String, dynamic>{};
    for (final entry in data.entries) {
      final wireKey = map[entry.key];
      if (wireKey == null) continue;
      final value = entry.value.trim();
      if (value.isEmpty) continue;

      if (_numericWireKeys.contains(wireKey)) {
        final number = num.tryParse(value);
        if (number != null) out[wireKey] = number;
        continue;
      }
      if (_boolWireKeys.contains(wireKey)) {
        out[wireKey] = value == 'true';
        continue;
      }
      if (_listWireKeys.contains(wireKey)) {
        out[wireKey] = value.split(',').where((s) => s.isNotEmpty).toList();
        continue;
      }
      out[wireKey] = value;
    }
    return out;
  }
```

Update `fromWire` similarly — `attendees` (a list of `{user_id, name}` objects, not `attendee_user_ids`) needs a bespoke reverse mapping since the read shape differs from the write shape (the API never echoes back `attendee_user_ids` — it echoes `attendees` with names attached, per Task 7/11's `serialize_data`). Handle this as a special case rather than trying to force it through the generic `_fromWire` map:

```dart
  static Map<String, String> fromWire(
    String registerId,
    Map<String, dynamic> data,
  ) {
    final map = _fromWire[registerId];
    final out = <String, String>{};
    if (map == null) return out;

    for (final entry in data.entries) {
      if (registerId == 'work' && entry.key == 'attendees') {
        final ids = (entry.value as List<dynamic>? ?? <dynamic>[])
            .map((a) => (a as Map<String, dynamic>)['user_id'] as String)
            .join(',');
        out['attendeeUserIds'] = ids;
        continue;
      }
      final appKey = map[entry.key];
      if (appKey == null) continue;
      final value = entry.value;
      if (value == null) continue;
      if (value is bool) {
        out[appKey] = value.toString();
        continue;
      }
      out[appKey] = value is String ? value : _printNumber(value);
    }
    return out;
  }
```

(The display *names* the `attendees` payload carries are dropped here — `fromWire`'s job is only to seed the editable form state, and the multi-select widget (Task 15) re-fetches display names from `staffDirectory()` live rather than trusting a stale name embedded in old entry data.)

- [ ] **Step 4: Update `registers.dart`**

Remove the `employee` `FieldDef` from the `'work'` register's `fields` list (`registers.dart:69-76`). Leave `supervisor` untouched.

- [ ] **Step 5: Run the test to verify it passes**

Run: `flutter test test/api_contract_test.dart -N "field map"`
Expected: PASS.

Run the full suite to catch any widget test still expecting an `employee` field on Work Done:

Run: `flutter test`
Expected: PASS (fix any stragglers found).

- [ ] **Step 6: Commit**

```bash
git add app/lib/data/registers.dart app/lib/data/api/field_map.dart app/test/api_contract_test.dart
git commit -m "Wire ticket-link and attendee fields into Work Done's field map"
```

---

### Task 15: Flutter — `_TicketLinkSection` on the Work Done form

**Files:**
- Modify: `app/lib/screens/register_form_screen.dart`
- Test: manual verification via `flutter run -d chrome` (this widget is interaction-heavy; the existing test suite doesn't have a precedent for testing `_FieldGrid`-adjacent bespoke sections like `_UnitSection` with automated widget tests, so match that precedent — no new widget test file for this task, verify by running the app, per the Testing section of the spec doc and this repo's actual practice of testing this layer through `api_contract_test.dart`/`entries_filter_test.dart` at the provider level, not full widget trees)

**Interfaces:**
- Consumes: `TicketRepository.search` (Task 12), `MasterDataRepository.staffDirectory` (Task 13), the field-map keys from Task 14.
- Produces: nothing new consumed by later tasks — this is leaf UI.

- [ ] **Step 1: Add the ticket-search and staff-directory providers**

In `app/lib/state/providers.dart`, add:

```dart
/// Family-keyed so a debounce-driven search per (site, register, query)
/// doesn't need its own StatefulWidget-managed cache.
final ticketSearchProvider = FutureProvider.family<
    List<TicketSearchResult>, ({String site, String? register, String q})>(
  (ref, key) async {
    if (key.site.isEmpty || key.q.trim().length < 2) {
      return const <TicketSearchResult>[];
    }
    return ref.watch(ticketRepositoryProvider).search(
          site: key.site,
          register: key.register,
          q: key.q.trim(),
        );
  },
);

final staffDirectoryProvider = FutureProvider<List<StaffMember>>((ref) async {
  final repo = ref.watch(masterDataRepositoryProvider);
  final site = ref.watch(sessionProvider.select((s) => s.site));
  if (site.isEmpty) return const <StaffMember>[];
  try {
    return await repo.staffDirectory(siteCode: site);
  } catch (_) {
    return const <StaffMember>[];
  }
});
```

Add imports for `TicketSearchResult` and `StaffMember` at the top of `providers.dart`.

- [ ] **Step 2: Build `_TicketLinkSection`**

`AppSelect`, `SegmentedField`, and `PickerField` (`app/lib/widgets/form_controls.dart`) have no `enabled`/`readOnly` constructor parameter — only `AppTextField` does. Task 16 handles read-only rendering uniformly with `AbsorbPointer` rather than threading a param through every control type; this section doesn't need to account for that.

In `app/lib/screens/register_form_screen.dart`, add a new widget parallel to `_UnitSection`:

```dart
/// Work Done's link to a ticket (breakdown/coolant/complaint/PM), its
/// attending-mechanics multi-select, and — only once a ticket is picked —
/// the "mark ticket complete" flag and its time.
///
/// A ticket is not a [FieldDef]: picking one needs a live, register-filtered
/// search against `/tickets/search`, which the static master-list-driven
/// [FieldType.select] machinery in `_Field` has no way to express. This
/// mirrors [_UnitSection]'s precedent of a bespoke, non-FieldDef block
/// bolted onto the Work Done form specifically.
class _TicketLinkSection extends ConsumerStatefulWidget {
  const _TicketLinkSection({
    required this.values,
    required this.onSet,
    required this.onPickTime,
  });

  final Map<String, String> values;
  final void Function(String key, String value) onSet;
  final Future<void> Function(String key) onPickTime;

  @override
  ConsumerState<_TicketLinkSection> createState() => _TicketLinkSectionState();
}

class _TicketLinkSectionState extends ConsumerState<_TicketLinkSection> {
  String? _registerFilter;
  String _query = '';
  String _pickedTitle = '';

  @override
  Widget build(BuildContext context) {
    final site = ref.watch(sessionProvider.select((s) => s.site));
    final staff = ref.watch(staffDirectoryProvider).valueOrNull ?? const <StaffMember>[];
    final searchKey = (site: site, register: _registerFilter, q: _query);
    final results = _query.trim().length < 2
        ? const <TicketSearchResult>[]
        : ref.watch(ticketSearchProvider(searchKey)).valueOrNull ??
            const <TicketSearchResult>[];

    final selectedIds = widget.values['attendeeUserIds']
            ?.split(',')
            .where((s) => s.isNotEmpty)
            .toSet() ??
        <String>{};
    final hasTicket = (widget.values['ticketId'] ?? '').isNotEmpty;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
      decoration: BoxDecoration(
        color: T.card,
        borderRadius: T.cardShape,
        border: Border.all(color: T.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Link to', style: AppText.sans(size: 15, weight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            'Optional — attach this session to the breakdown, coolant, '
            'complaint, or PM ticket it was worked against.',
            style: AppText.sans(size: 12.5, color: T.secondary, height: 1.4),
          ),
          const SizedBox(height: 12),
          if (hasTicket)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                TagBadge(
                  label: _pickedTitle.isEmpty ? 'Linked ticket' : _pickedTitle,
                  background: T.subtleFill,
                  foreground: T.secondary,
                ),
                InkWell(
                  onTap: () => setState(() {
                    widget.onSet('ticketId', '');
                    widget.onSet('completesTicket', '');
                    widget.onSet('completionTime', '');
                    _pickedTitle = '';
                  }),
                  child: Text(
                    'Remove',
                    style: AppText.sans(size: 12, weight: FontWeight.w600, color: T.red),
                  ),
                ),
              ],
            )
          else ...<Widget>[
            AppSelect(
              value: _registerFilter,
              options: const <String>['breakdown', 'coolant', 'complaint', 'pm'],
              placeholder: 'Which register…',
              onChanged: (v) => setState(() => _registerFilter = v),
            ),
            const SizedBox(height: 8),
            AppTextField(
              controller: TextEditingController(text: _query),
              placeholder: 'Search by title or ID…',
              onChanged: (v) => setState(() => _query = v),
            ),
            if (results.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              for (final r in results)
                InkWell(
                  onTap: () => setState(() {
                    widget.onSet('ticketId', r.ticketId);
                    _pickedTitle = r.title;
                    _query = '';
                  }),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(r.title, style: AppText.sans(size: 13.5)),
                  ),
                ),
            ],
          ],
          const SizedBox(height: 16),
          const FieldLabel(label: 'Attending mechanic(s)'),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final s in staff)
                FilterChip(
                  label: Text(s.name),
                  selected: selectedIds.contains(s.id),
                  onSelected: (picked) => setState(() {
                    final next = Set<String>.of(selectedIds);
                    picked ? next.add(s.id) : next.remove(s.id);
                    widget.onSet('attendeeUserIds', next.join(','));
                  }),
                ),
            ],
          ),
          if (hasTicket) ...<Widget>[
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                Checkbox(
                  value: widget.values['completesTicket'] == 'true',
                  onChanged: (checked) => setState(
                    () => widget.onSet('completesTicket', (checked ?? false).toString()),
                  ),
                ),
                Text('Mark ticket resolved', style: AppText.sans(size: 13.5)),
              ],
            ),
            if (widget.values['completesTicket'] == 'true') ...<Widget>[
              const SizedBox(height: 8),
              const FieldLabel(label: 'Resolved at', required: true),
              const SizedBox(height: 6),
              PickerField(
                display: widget.values['completionTime'] ?? '',
                placeholder: '--:--',
                onTap: () => widget.onPickTime('completionTime'),
              ),
            ],
          ],
        ],
      ),
    );
  }
}
```

- [ ] **Step 3: Mount `_TicketLinkSection` and validate before save**

In `_RegisterFormScreenState.build()`, after the existing `if (register.id == 'work') ... _UnitSection(...)` block, add:

```dart
              if (register.id == 'work') ...<Widget>[
                const SizedBox(height: 16),
                _TicketLinkSection(
                  values: _values,
                  onSet: (k, v) => setState(() => _set(k, v)),
                  onPickTime: _pickTime,
                ),
              ],
```

In `_save()`, add a pre-flight check alongside the existing `missing` required-fields check (mirrors the backend's `completes_ticket requires ticket_id`/`completion_time` validators, so the user sees the error before a round trip rather than after):

```dart
    if (_values['completesTicket'] == 'true' &&
        (_values['completionTime'] ?? '').isEmpty) {
      ref.read(toastProvider.notifier).show('Resolved-at time required');
      return;
    }
```

- [ ] **Step 4: Manual verification**

Run: `cd backend && docker compose up -d` (starts the API on `:8000`), then `cd app && flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8000/api/v1` (flag confirmed at `app/lib/data/api/api_client.dart:21,30`). Sign in with the bootstrap login `TV4021` / `Transvolt@123` per `CLAUDE.md`.

Walk through: report a breakdown → open a new Daily Work Done entry → search "breakdown" in the ticket picker → confirm the just-reported breakdown appears → pick it → pick an attending mechanic → check "Mark ticket resolved" → pick a time → save → confirm the breakdown's status flips (visible on the Breakdowns screen, Task 18 makes this fully visible but the status pill from existing code should already reflect it).

- [ ] **Step 5: Commit**

```bash
git add app/lib/screens/register_form_screen.dart app/lib/state/providers.dart
git commit -m "Add ticket-link and attending-mechanics section to the Work Done form"
```

---

### Task 16: Flutter — Registers screen View action (read-only)

**Files:**
- Modify: `app/lib/screens/registers_screen.dart` (`_ResultRow`)
- Modify: `app/lib/screens/register_form_screen.dart` (`RegisterFormScreen`, `_FieldGrid`, `_Field`)
- Modify: `app/lib/router.dart` (a new route, or a query-param variant of the existing edit route — check the existing `Routes.editEntry` shape before deciding)

**Interfaces:**
- Consumes: nothing new.
- Produces: `RegisterFormScreen(readOnly: bool)` — a widget-level flag; other tasks don't depend on it.

- [ ] **Step 1: Add a `readOnly` flag to `RegisterFormScreen`**

In `register_form_screen.dart`:

```dart
class RegisterFormScreen extends ConsumerStatefulWidget {
  const RegisterFormScreen({
    super.key,
    this.registerId,
    this.entryId,
    this.onClose,
    this.readOnly = false,
  });

  final String? registerId;
  final String? entryId;
  final VoidCallback? onClose;
  final bool readOnly;
  ...
```

Thread `readOnly` down to `_FieldGrid` and `_Field` (both need a new `required this.readOnly` constructor param). Confirmed in `app/lib/widgets/form_controls.dart`: `AppTextField` has an `enabled` param (default `true`, line 109/118), but `AppSelect`, `SegmentedField`, and `PickerField` have none — so a per-widget `enabled` thread-through isn't available uniformly. Use `AbsorbPointer` wrapping the whole `_control()` result plus a dimmed opacity instead, in `_Field.build()`:

```dart
  @override
  Widget build(BuildContext context) {
    final control = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FieldLabel(label: def.label, required: def.required, master: def.isMasterBacked),
        _control(),
      ],
    );
    return readOnly ? AbsorbPointer(child: Opacity(opacity: 0.7, child: control)) : control;
  }
```

In `_RegisterFormScreenState.build()`, hide the Save button and the Unit/TicketLink sections' editability when `widget.readOnly`:

```dart
              if (!widget.readOnly && register.id == 'work') ...<Widget>[
                const SizedBox(height: 16),
                _UnitSection(...),
              ],
              if (!widget.readOnly && register.id == 'work') ...<Widget>[
                const SizedBox(height: 16),
                _TicketLinkSection(...),
              ],
              const SizedBox(height: 16),
              if (!widget.readOnly)
                Row(
                  children: <Widget>[
                    OutlineActionButton(label: 'Cancel', onPressed: _saving ? null : _close, ...),
                    ...
                  ],
                )
              else
                OutlineActionButton(label: 'Close', onPressed: _close, fontSize: 16),
```

Pass `readOnly: widget.readOnly` into the `_FieldGrid(...)` constructor call.

- [ ] **Step 2: Add a route for view mode**

`Routes.editEntry` is `static String editEntry(String entryId) => '/entry/edit/$entryId';` (`app/lib/router.dart:39`), registered as `GoRoute(path: '/entry/edit/:entryId', ...)` building `RegisterFormScreen(entryId: state.pathParameters['entryId'])` (`app/lib/router.dart:182-190`). Add a matching path-based route rather than a query param, mirroring this exact shape:

```dart
  static String editEntry(String entryId) => '/entry/edit/$entryId';

  static String viewEntry(String entryId) => '/entry/view/$entryId';
```

```dart
          GoRoute(
            path: '/entry/view/:entryId',
            pageBuilder: (context, state) => NoTransitionPage<void>(
              key: state.pageKey,
              child: PageBody(
                child: RegisterFormScreen(
                  entryId: state.pathParameters['entryId'],
                  readOnly: true,
                ),
              ),
            ),
          ),
```

Add this new `GoRoute` right after the existing `/entry/edit/:entryId` one (`app/lib/router.dart:182-190`).

- [ ] **Step 3: Add the View button to `_ResultRow`**

In `registers_screen.dart`'s `_ResultRow.build()`, add a View button next to Edit:

```dart
              const SizedBox(width: 10),
              OutlineActionButton(
                label: 'View',
                onPressed: () => context.go(Routes.viewEntry(entry.id)),
                fontSize: 12.5,
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
              ),
              const SizedBox(width: 8),
              OutlineActionButton(
                label: 'Edit',
                onPressed: () => context.go(Routes.editEntry(entry.id)),
                accent: T.green,
                fontSize: 12.5,
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
              ),
```

- [ ] **Step 4: Manual verification**

Run the app, open Registers, click View on any row, confirm the form renders with every field disabled and only a Close button. Click Edit on the same row, confirm it's still fully editable (no regression).

- [ ] **Step 5: Commit**

```bash
git add app/lib/screens/registers_screen.dart app/lib/screens/register_form_screen.dart app/lib/router.dart
git commit -m "Add a read-only View action to Registers, alongside Edit"
```

---

### Task 17: Flutter — "Raise ticket" action in Registers

**Files:**
- Modify: `app/lib/screens/registers_screen.dart` (`_ResultRow`)
- Modify: `app/lib/state/entries.dart` (`EntriesController`, new `raiseTicket` method)

**Interfaces:**
- Consumes: `TicketRepository.raiseTicket` (Task 12).

- [ ] **Step 1: Add `raiseTicket` to `EntriesController`**

In `app/lib/state/entries.dart`:

```dart
  Future<void> raiseTicket(String entryId) async {
    final saved = await ref.read(ticketRepositoryProvider).raiseTicket(entryId);
    _replaceAll((list) => list.map((e) => e.id == saved.id ? saved : e).toList());
  }
```

Import `ticketRepositoryProvider` (already exported via `providers.dart`, already imported in this file).

- [ ] **Step 2: Add the button to `_ResultRow`**

In `registers_screen.dart`, gate a "Raise ticket" button to Coolant/Complaint/PM rows that are still `done` (i.e., have no ticket yet — `!entry.isOpen`, since raising flips status to `open`):

```dart
              if (<String>['coolant', 'complaint', 'pm'].contains(entry.registerId) &&
                  !entry.isOpen) ...<Widget>[
                const SizedBox(width: 8),
                OutlineActionButton(
                  label: 'Raise ticket',
                  onPressed: () async {
                    await ref.read(entriesProvider.notifier).raiseTicket(entry.id);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Ticket raised')),
                      );
                    }
                  },
                  fontSize: 12.5,
                  padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
                ),
              ],
```

Check whether this codebase's toast pattern is `ref.read(toastProvider.notifier).show(...)` (used everywhere else, per `register_form_screen.dart`) rather than a raw `ScaffoldMessenger` — use the established `toastProvider` pattern instead of the snippet above, for consistency:

```dart
                  onPressed: () async {
                    await ref.read(entriesProvider.notifier).raiseTicket(entry.id);
                    ref.read(toastProvider.notifier).show('Ticket raised');
                  },
```

(`_ResultRow` needs `WidgetRef ref` in scope — it's already a `ConsumerWidget`, confirmed from the earlier read of this file, so `ref` is already a build parameter.)

- [ ] **Step 3: Manual verification**

Run the app, create a Coolant entry, confirm "Raise ticket" appears, click it, confirm it disappears afterward (since `entry.isOpen` becomes true) and a toast confirms.

- [ ] **Step 4: Commit**

```bash
git add app/lib/screens/registers_screen.dart app/lib/state/entries.dart
git commit -m "Add a Raise ticket action for Coolant/Complaint/PM rows"
```

---

### Task 18: Flutter — Breakdowns screen linked-sessions list, and timing field updates

**Files:**
- Modify: `app/lib/screens/breakdowns_screen.dart`
- Modify: `app/lib/data/api/field_map.dart` (`'breakdown'` map)
- Modify: `app/lib/data/api/api_repositories.dart` (`_entryFromWire`, to also parse `linked_sessions`)
- Modify: `app/lib/models/entry.dart` (`RegisterEntry`, add `linkedSessions`)

**Interfaces:**
- Consumes: `linked_sessions` from the breakdown GET response (Task 11).
- Produces: `RegisterEntry.linkedSessions: List<Map<String, dynamic>>` — read-only display data, no further consumers in this plan.

- [ ] **Step 1: Update `field_map.dart`'s `'breakdown'` map**

Drop `'t_bd': 'breakdown_time'`, rename `'t_mech': 'mechanic_reported_time'` to `'t_reported': 'reported_time'`:

```dart
    'breakdown': <String, String>{
      'bus': 'bus_no',
      'defectType': 'defect_type',
      'driver': 'driver_id',
      'route': 'route',
      'loc': 'location',
      'complaint': 'complaint',
      't_reported': 'reported_time',
      't_att': 'attended_time',
      'loss': 'loss_km',
      'attended': 'attended_details',
      'remarks': 'remarks',
      'supervisor': 'supervisor',
    },
```

- [ ] **Step 2: Update `breakdowns_screen.dart`'s metrics row**

In `_BreakdownCard.build()`:

```dart
          Wrap(
            spacing: 16,
            runSpacing: 6,
            children: <Widget>[
              _Metric(label: 'Reported', value: d['t_reported'] ?? '—'),
              _Metric(label: 'Attended', value: d['t_att'] ?? '—'),
              _Metric(
                label: 'Time taken',
                value: Dates.elapsed(d['t_reported'], d['t_att']),
              ),
              _Metric(label: 'Loss KM', value: '${d['loss'] ?? '0'} km'),
            ],
          ),
```

- [ ] **Step 3: Add `linkedSessions` to `RegisterEntry`**

In `app/lib/models/entry.dart`, add:

```dart
  const RegisterEntry({
    ...
    this.linkedSessions = const <Map<String, dynamic>>[],
  });

  ...
  final List<Map<String, dynamic>> linkedSessions;
```

Thread it through `copyWith`, `toJson`/`fromJson` (append `linkedSessions` to both, following the exact pattern the other fields already use), and `withPhotoUrl` (carry it through unchanged, same as every other field that constructor already copies verbatim).

- [ ] **Step 4: Parse `linked_sessions` in `_entryFromWire`**

In `api_repositories.dart`'s `_entryFromWire` (renamed in Task 12):

```dart
    return RegisterEntry(
      ...
      linkedSessions: (json['linked_sessions'] as List<dynamic>? ?? <dynamic>[])
          .map((s) => s as Map<String, dynamic>)
          .toList(),
    );
```

- [ ] **Step 5: Render the linked-sessions list on `_BreakdownCard`**

```dart
          if (entry.linkedSessions.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            const Divider(height: 1, color: T.border),
            const SizedBox(height: 10),
            Text(
              'LINKED WORK DONE',
              style: AppText.sans(size: 10, color: T.muted),
            ),
            const SizedBox(height: 6),
            for (final session in entry.linkedSessions)
              InkWell(
                onTap: () => context.go(Routes.editEntry(session['entry_id'] as String)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          '${session['entry_date']} · Shift ${session['shift'] ?? '—'} · '
                          '${(session['attendees'] as List<dynamic>).map((a) => (a as Map)['name']).join(', ')}',
                          style: AppText.sans(size: 13),
                        ),
                      ),
                      if (session['completes_ticket'] == true)
                        TagBadge(label: 'Resolved this', background: T.greenTint, foreground: T.green),
                    ],
                  ),
                ),
              ),
          ],
```

- [ ] **Step 6: Manual verification**

Run the app, report a breakdown, log a linked Work Done session against it (per Task 15's flow), navigate to Breakdowns, confirm the card shows "LINKED WORK DONE" with the session listed, and that "Reported"/"Attended" metrics show correctly (no more "B/Down").

- [ ] **Step 7: Commit**

```bash
git add app/lib/screens/breakdowns_screen.dart app/lib/data/api/field_map.dart \
  app/lib/data/api/api_repositories.dart app/lib/models/entry.dart
git commit -m "Show linked Work Done sessions on the Breakdowns screen"
```

---

### Task 19: Flutter — `EntryStatus` three-value fix

**Files:**
- Modify: `app/lib/models/entry.dart` (`EntryStatus`)
- Modify: `app/lib/data/api/api_repositories.dart` (`_entryFromWire`, `ApiEntryRepository.setStatus`)
- Modify: `app/lib/state/entries.dart` (`resolveBreakdown`)
- Modify: `app/test/support/fake_repositories.dart` (`FakeEntryRepository.setStatus`, if it special-cases status values)
- Test: `app/test/api_contract_test.dart`

**Interfaces:**
- Produces: `EntryStatus.resolved` as a real, distinct value — no other task in this plan depends on it, but it removes a latent bug this feature's own resolve/complete paths would otherwise make more visible (a resolved breakdown and a merely-`done` entry were indistinguishable client-side).

- [ ] **Step 1: Write the failing test**

Use the same inline-`MockClient` style as Tasks 12/13 (no captured fixture has a `"resolved"` status yet):

```dart
test('a resolved breakdown parses as EntryStatus.resolved, not done', () async {
  final mock = MockClient((http.Request request) async {
    final body = jsonDecode(fixture('entry_create')) as Map<String, dynamic>;
    body['status'] = 'resolved';
    return http.Response(
      jsonEncode(body), 200,
      headers: <String, String>{'content-type': 'application/json'},
    );
  });
  final client = ApiClient(baseUrl: 'http://api.test/api/v1', httpClient: mock);

  final entry = await ApiEntryRepository(client).createEntry(
    const RegisterEntry(
      id: '', registerId: 'breakdown', date: '2026-08-13', time: '09:29',
      site: 'MBMT', enteredBy: '', data: <String, String>{'bus': 'MH40LY1894'},
    ),
  );
  expect(entry.status, EntryStatus.resolved);
});
```

This reuses the existing `entry_create.json` fixture as a base and overrides just its `status` field, rather than requiring a newly captured fixture.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/api_contract_test.dart -N "resolved breakdown parses"`
Expected: FAIL — status collapses to `EntryStatus.done`.

- [ ] **Step 3: Extend `EntryStatus` and fix the parsing/write paths**

In `app/lib/models/entry.dart`:

```dart
enum EntryStatus { open, done, resolved }
```

In `api_repositories.dart`'s `_entryFromWire`:

```dart
      status: switch (json['status'] as String?) {
        'open' => EntryStatus.open,
        'resolved' => EntryStatus.resolved,
        _ => EntryStatus.done,
      },
```

In `ApiEntryRepository.setStatus`:

```dart
  @override
  Future<RegisterEntry> setStatus(String entryId, EntryStatus status) async {
    if (status != EntryStatus.resolved) {
      throw const ApiException('Only resolving a breakdown is supported');
    }
    final json = await _api.post('/entries/$entryId/resolve');
    return _entryFromWire(json as Map<String, dynamic>);
  }
```

In `app/lib/state/entries.dart`'s `resolveBreakdown`:

```dart
  Future<void> resolveBreakdown(String entryId) async {
    final saved = await ref
        .read(entryRepositoryProvider)
        .setStatus(entryId, EntryStatus.resolved);
    _replaceAll((list) => list.map((e) => e.id == saved.id ? saved : e).toList());
  }
```

In `app/test/support/fake_repositories.dart`'s `FakeEntryRepository.setStatus`, check whether it special-cases the passed `status` value anywhere (the earlier read of this file showed it just does `entry.copyWith(status: status)` — no special-casing, so it already accepts any `EntryStatus` and needs no change; confirm this is still true after reading its current body once more before skipping this file).

- [ ] **Step 4: Check every `isOpen`/status-comparison call site for a `resolved`-vs-`done` assumption**

Run: `grep -rn "EntryStatus.done\|EntryStatus.open\|\.isOpen\b" app/lib/` and check each hit. `RegisterEntry.isOpen` (`status == EntryStatus.open`) is unaffected by adding a third value. Any `switch` on `EntryStatus` elsewhere in the codebase (search first — there may be none besides the ones just touched) needs a `resolved` case added or it won't compile, since Dart's exhaustiveness checking on enums will flag a non-exhaustive switch.

- [ ] **Step 5: Run the test and the full suite**

Run: `flutter test test/api_contract_test.dart -N "resolved breakdown parses"`
Expected: PASS.

Run: `flutter test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/lib/models/entry.dart app/lib/data/api/api_repositories.dart \
  app/lib/state/entries.dart app/test/api_contract_test.dart
git commit -m "Give the Flutter client a real resolved status, distinct from done"
```

---

## Final verification

- [ ] Run the full backend suite: `cd backend && .venv/bin/pytest -v` — expect PASS.
- [ ] Run the full Flutter suite: `cd app && flutter test` — expect PASS.
- [ ] Run `cd backend && .venv/bin/alembic upgrade head` against a clean database and confirm it reaches `0029` with no errors.
- [ ] Manually walk the whole flow in the running app (`flutter run -d chrome`): report a breakdown → confirm its ticket exists (via a Work Done entry search) → log two Work Done sessions across two different days against it, the second marking it resolved → confirm the breakdown shows resolved with both sessions listed → raise a ticket on a Coolant entry → confirm it can also receive a linked Work Done session → open Registers and confirm View/Edit both work on every register type.
- [ ] Confirm nothing was pushed, branched, or opened as a PR — this stays local per the Global Constraints, until the user says otherwise.
