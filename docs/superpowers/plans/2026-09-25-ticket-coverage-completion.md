# Ticket Coverage Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the four remaining gaps against the client's legacy-workflow feedback: Daily/10-Day Inspection and PM/Docking generate tickets in the Daily Work Done pending list; a spare-parts catalog backs Work Done's parts field; a driver master backs Driver Complaint/Breakdown; Coolant Topping gets a day-based bulk entry. Also: Source of Defect manual/auto surfacing, Complete/Pending filter UI, and traceability polish (supervisor on linked sessions).

**Architecture:** Extends the already-merged `tickets` spine (`backend/app/models/ticket.py`, `backend/app/services/tickets.py`) with a second, alternative source shape (`source_inspection_result_id` alongside `source_entry_id`) so inspection failures flow through the exact same completion machinery Breakdown/Coolant/Complaint already use. Two new site-scoped master tables (`spare_parts`, `drivers`) follow `Vehicle`'s scoping, not the tenant-wide `DefectSource`/`DefectType`/`WorkType` pattern. Coolant's day-based entry is a new bulk-write endpoint over the existing per-bus storage shape — no schema change there.

**Tech Stack:** FastAPI + SQLAlchemy async + Alembic + pytest (backend); Flutter + Riverpod + the abstract-repository/fake seam (app).

**Spec:** `docs/superpowers/specs/2026-09-25-ticket-coverage-completion-design.md` (extends `docs/superpowers/specs/2026-09-24-breakdown-work-done-linkage-design.md`)

## Global Constraints

- Extend the merged tickets spine (`Ticket`, `services/tickets.py`) — do not create a second, parallel linkage mechanism.
- No JSONB. Every new field is a real column with a real FK where it references another table (repo CLAUDE.md).
- No dropdown value reaches an entry without an FK to its master table (repo CLAUDE.md) — this is why `driver_id`/`spare_part_ids` resolve server-side against real tables, never stored as free text going forward.
- `spare_parts` and `drivers` are **site-scoped** (`site_code` FK, like `Vehicle`) — not tenant-wide like `DefectSource`/`DefectType`/`WorkType`.
- No new SiteOps permission resources. Gate new endpoints under the existing `em_master:*`, `em_entry:*`, `em_inspection:*` (siteops-platform is prod-only; a new resource needs a platform admin to grant it before anything using it would work).
- Dates are `yyyy-MM-dd` strings; times are `HH:mm` in site wall-clock (IST), not UTC.
- Money/volume/power values are `Decimal`, never `float`, on the backend.
- TDD throughout: a failing test before its implementation, every task.
- Alembic revisions continue sequentially from `0029_breakdown_reported_time_and_backfill` — this plan's migrations are `0030` through `0034`, each `down_revision` pointing at the previous.
- Flutter: when a task changes a backend contract, update the matching abstract repository method *and* its fake in the same task — a drifting fake is worse than no fake (repo CLAUDE.md).
- A master row (`spare_parts`, `drivers`) being deactivated must never break reading a historical entry that references it — resolve-by-id/code ignores `is_active`; only the typeahead/picker list filters on it (same rule already applied to `DefectSource`/`DefectType`/staff).

## Review Focus

1. **Inspection batch, one bad vehicle among several good ones** — a batch submission must be all-or-nothing in one transaction; a duplicate/retired/unknown vehicle in the middle of the list must not leave the earlier vehicles' `InspectionEntry` rows committed while later ones are silently dropped.
2. **Ticket search site-scoping across two source shapes** — an inspection-sourced ticket has no `Entry` row, so its site lives on `InspectionEntry.site_code` via `InspectionResult`, not `Entry.site_code`. `search_tickets` must filter every source kind to the caller's site correctly, or a manager could see another site's pending inspection tickets in the Work Done picker.
3. **`complete_ticket` on an inspection-sourced ticket must not touch `Entry`/`BreakdownEntry`** — the existing function assumes every ticket has `ticket.source_entry`; it needs a clean branch for the inspection-result source instead of a null-attribute crash.
4. **Coolant day-entry partial failure** — one invalid/retired/unknown vehicle among a day's submitted list must roll back the whole batch, not leave some buses topped and others silently missing (which would misreport as "not yet topped" rather than "failed to submit").
5. **Deactivating a spare part or driver must not corrupt history** — an old Work Done entry's `spare_part_ids` and an old complaint's `driver_id` must keep resolving and displaying correctly after the referenced row goes `is_active=false`.

---

## File Structure

**Backend — new files:**
- `backend/app/api/site_masters.py` — `/sites/{code}/spare-parts` and `/sites/{code}/drivers` CRUD (mirrors the vehicles section of `app/api/sites.py`).
- `backend/app/schemas/site_masters.py` — `SparePartOut/Create/Update`, `DriverOut/Create/Update`.
- `backend/alembic/versions/0030_ticket_source_generalization.py` (Task 1)
- `backend/alembic/versions/0031_spare_parts.py` (Task 8)
- `backend/alembic/versions/0032_work_done_spare_parts.py` (Task 9)
- `backend/alembic/versions/0033_drivers.py` (Task 11)
- `backend/alembic/versions/0034_driver_id_fk.py` (Task 12)

**Backend — modified files:**
- `backend/app/models/enums.py` — add `TicketSourceKind`, `TICKET_SOURCE_KIND_ENUM`.
- `backend/app/models/ticket.py` — nullable `source_entry_id`, new `source_inspection_result_id`, new `source_kind`, check constraint.
- `backend/app/models/checklist.py` — `InspectionResult.ticket` back-reference relationship.
- `backend/app/models/master.py` — add `SparePart`, `Driver`.
- `backend/app/models/entry.py` — `WorkDoneEntry` drops `spare_parts_used`, gains `spare_parts` relationship; `DriverComplaintEntry.driver_id`/`BreakdownEntry.driver_id` become FKs.
- `backend/app/services/tickets.py` — `TICKETABLE_REGISTERS` drops `pm_schedule`; `source_kind` stamping; `create_ticket_for_inspection_result`; generalized `ticket_title`/`ticket_entry_date`; `search_tickets` by `source_kind`; `complete_ticket`/`mark_attended` branch cleanly on source shape.
- `backend/app/services/checklists.py` — `record_inspection` raises tickets for `not_ok` results; new `record_inspection_batch`.
- `backend/app/services/entries.py` — `_resolve_spare_parts`/`_set_spare_parts` (mirrors `_resolve_attendees`/`_set_attendees`); `_build_detail` resolves `driver_id` for Driver Complaint/Breakdown; `apply_filters` gains `has_open_ticket`; `serialize_data` gains `entry_origin` and `spare_parts`; `load_linked_sessions` gains `supervisor`.
- `backend/app/services/masters.py` — `resolve_driver`, `resolve_spare_parts` (multi-id, mirrors `_resolve_attendees`'s shape).
- `backend/app/schemas/entry.py` — `WorkDoneData.spare_parts_used` → `spare_part_ids`; `WorkDoneData`/entries-list gain `entry_origin`/`origin` filter; `CoolantDayCreate`/`CoolantDayRow`.
- `backend/app/schemas/ticket.py` — `TicketSearchResult` gains `source_kind`.
- `backend/app/schemas/checklist.py` — `InspectionBatchCreate`/`InspectionBatchItem`/`InspectionBatchOut`; `ResultOut` gains `ticket_id`/`ticket_status`.
- `backend/app/api/tickets.py` — `register` query param → `source_kind`.
- `backend/app/api/entries.py` — `POST /entries/coolant/day`; `origin`/`has_open_ticket` query params on the list endpoint.
- `backend/app/api/checklists.py` — `POST /sites/{code}/inspections/batch`.
- `backend/app/api/__init__.py` — register `site_masters.router`.

**Flutter — new files:**
- `app/lib/models/spare_part.dart` — `SparePart {id, partNo, name}`.
- `app/lib/models/driver.dart` — `Driver {id, driverCode, name}`.

**Flutter — modified files:**
- `app/lib/data/repositories.dart` — `MasterDataRepository.sparePartDirectory()`, `.driverDirectory()`, `.createSparePart()`, `.createDriver()`; `EntryRepository.createCoolantDay()`; `TicketRepository.search()`'s `register` param generalized in call sites (type stays `String?`, no signature change needed).
- `app/lib/data/api/api_repositories.dart` — implementations of the above.
- `app/lib/data/api/field_map.dart` — `'work'` register: drop `'spares'`, add `'sparePartIds': 'spare_part_ids'`.
- `app/lib/data/registers.dart` — `'work'` register: remove the `spares` `FieldDef`; `'breakdown'`/`'complaint'` registers: `driver` `FieldDef` becomes `FieldType.select, optionsFrom: MasterList.drivers, master: true`.
- `app/lib/models/register.dart` — add `MasterList.drivers`.
- `app/lib/screens/register_form_screen.dart` — new `_SparePartsSection` widget (mirrors `_TicketLinkSection`'s attendee multi-select), wired into the Work Done form.
- `app/lib/screens/registers_screen.dart` — Complete/Pending filter chips.
- `app/lib/screens/breakdowns_screen.dart` and wherever `linked_sessions` renders — show `supervisor`; distinguish the first session ("Originally logged") from the `completes_ticket=true` session ("Completed by").
- `app/lib/screens/inspection_form_screen.dart` — multi-bus mode.
- `app/lib/data/entry.dart` / `app/lib/models/entry.dart` — `RegisterEntry.entryOrigin` (read-only), `spare_part_ids`.
- `app/test/support/fake_repositories.dart`, `app/test/support/seed.dart` — fakes for every new repository method.

---

## Task 1: `Ticket` gains a second source shape

**Files:**
- Modify: `backend/app/models/enums.py`
- Modify: `backend/app/models/ticket.py`
- Modify: `backend/app/models/checklist.py:170-196` (`InspectionResult`)
- Create: `backend/alembic/versions/0030_ticket_source_generalization.py`
- Test: `backend/tests/test_tickets.py`

**Interfaces:**
- Produces: `TicketSourceKind` enum (`breakdown, coolant, driver_complaint, daily_inspection, ten_day_inspection, pm_docking`); `Ticket.source_kind: TicketSourceKind`; `Ticket.source_entry_id: str | None`; `Ticket.source_inspection_result_id: str | None`; `Ticket.source_inspection_result: InspectionResult | None`; `InspectionResult.ticket: Ticket | None`.

- [ ] **Step 1: Write the failing test**

```python
# backend/tests/test_tickets.py (append)
async def test_ticket_requires_exactly_one_source(session_factory) -> None:
    async with session_factory() as session:
        with pytest.raises(IntegrityError):
            session.add(
                Ticket(
                    source_entry_id=None,
                    source_inspection_result_id=None,
                    source_kind=TicketSourceKind.breakdown,
                    created_by_id="u1",
                )
            )
            await session.flush()


async def test_ticket_rejects_both_sources_set(session_factory, seeded_entry, seeded_inspection_result) -> None:
    async with session_factory() as session:
        with pytest.raises(IntegrityError):
            session.add(
                Ticket(
                    source_entry_id=seeded_entry.id,
                    source_inspection_result_id=seeded_inspection_result.id,
                    source_kind=TicketSourceKind.daily_inspection,
                    created_by_id="u1",
                )
            )
            await session.flush()
```

Use whatever this file's existing fixtures for a flushed `Entry` and a flushed `InspectionEntry`+`InspectionResult` are named (check `backend/tests/conftest.py` and `backend/tests/test_inspections.py` for the actual fixture names before writing this — do not invent `seeded_entry`/`seeded_inspection_result` if equivalents already exist under different names).

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/python -m pytest backend/tests/test_tickets.py -k source_generalization -v` (run from `backend/`)
Expected: FAIL — `Ticket.__init__() got an unexpected keyword argument 'source_inspection_result_id'` (column doesn't exist yet).

- [ ] **Step 3: Add `TicketSourceKind` to `app/models/enums.py`**

```python
class TicketSourceKind(StrEnum):
    breakdown = "breakdown"
    coolant = "coolant"
    driver_complaint = "driver_complaint"
    daily_inspection = "daily_inspection"
    ten_day_inspection = "ten_day_inspection"
    pm_docking = "pm_docking"
```

Add `TICKET_SOURCE_KIND_ENUM = "ticket_source_kind_enum"` next to `TICKET_STATUS_ENUM` in the Postgres enum type names block at the bottom of the file.

- [ ] **Step 4: Modify `app/models/ticket.py`**

```python
from sqlalchemy import CheckConstraint, Enum, ForeignKey, String
from app.models.enums import TICKET_SOURCE_KIND_ENUM, TICKET_STATUS_ENUM, TicketSourceKind, TicketStatus

if TYPE_CHECKING:
    from app.models.checklist import InspectionResult
    from app.models.entry import Entry


class Ticket(Base):
    """The spine between a source (a register entry, or a failed inspection
    check) and its chain of Work Done sessions.

    Exactly one of `source_entry_id` / `source_inspection_result_id` is set,
    enforced by a check constraint — a ticket's source is either shape, never
    both, never neither.
    """

    __tablename__ = "tickets"
    __table_args__ = (
        CheckConstraint(
            "(source_entry_id IS NULL) != (source_inspection_result_id IS NULL)",
            name="ck_tickets_exactly_one_source",
        ),
    )

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_uuid)
    source_entry_id: Mapped[str | None] = mapped_column(
        String(32), ForeignKey("entries.id", ondelete="CASCADE"), nullable=True, unique=True
    )
    source_inspection_result_id: Mapped[str | None] = mapped_column(
        String(32),
        ForeignKey("inspection_results.id", ondelete="CASCADE"),
        nullable=True,
        unique=True,
    )
    source_kind: Mapped[TicketSourceKind] = mapped_column(
        Enum(
            TicketSourceKind,
            name=TICKET_SOURCE_KIND_ENUM,
            values_callable=lambda e: [m.value for m in e],
        ),
        nullable=False,
    )
    status: Mapped[TicketStatus] = mapped_column(
        Enum(TicketStatus, name=TICKET_STATUS_ENUM, values_callable=lambda e: [m.value for m in e]),
        nullable=False,
        default=TicketStatus.open,
    )
    completed_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
    completed_by_id: Mapped[str | None] = mapped_column(
        String(32), ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
    attended_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
    created_at: Mapped[datetime] = created_at_col()
    created_by_id: Mapped[str] = mapped_column(
        String(32), ForeignKey("users.id", ondelete="RESTRICT"), nullable=False
    )

    source_entry: Mapped["Entry | None"] = relationship(lazy="joined", foreign_keys=[source_entry_id])
    source_inspection_result: Mapped["InspectionResult | None"] = relationship(
        lazy="joined", foreign_keys=[source_inspection_result_id], back_populates="ticket"
    )
    completed_by: Mapped[User | None] = relationship(lazy="joined", foreign_keys=[completed_by_id])
    created_by: Mapped[User] = relationship(lazy="joined", foreign_keys=[created_by_id])
```

- [ ] **Step 5: Add the back-reference on `InspectionResult` (`app/models/checklist.py`)**

Add to `InspectionResult`, after the `item` relationship:

```python
    ticket: Mapped["Ticket | None"] = relationship(
        lazy="selectin", back_populates="source_inspection_result", uselist=False
    )
```

Add `from app.models.ticket import Ticket` under `if TYPE_CHECKING:` at the top of the file (avoids a circular import — `ticket.py` already imports `checklist.py` types under its own `TYPE_CHECKING` guard).

- [ ] **Step 6: Write the migration — `0030_ticket_source_generalization.py`**

```python
"""Ticket gains a second source shape: inspection results.

Revision ID: 0030
Revises: 0029
"""
from alembic import op
import sqlalchemy as sa

revision = "0030"
down_revision = "0029"
branch_labels = None
depends_on = None

TICKET_SOURCE_KIND = sa.Enum(
    "breakdown", "coolant", "driver_complaint",
    "daily_inspection", "ten_day_inspection", "pm_docking",
    name="ticket_source_kind_enum",
)


def upgrade() -> None:
    TICKET_SOURCE_KIND.create(op.get_bind())
    op.add_column(
        "tickets",
        sa.Column("source_kind", TICKET_SOURCE_KIND, nullable=True),
    )
    # Backfill: every existing ticket is entry-sourced; source_kind mirrors
    # the entry's own register (breakdown/coolant/driver_complaint are the
    # only registers that could have raised one before this migration).
    op.execute(
        """
        UPDATE tickets
        SET source_kind = entries.register::text::ticket_source_kind_enum
        FROM entries
        WHERE tickets.source_entry_id = entries.id
        """
    )
    op.alter_column("tickets", "source_kind", nullable=False)

    op.alter_column("tickets", "source_entry_id", nullable=True)
    op.add_column(
        "tickets",
        sa.Column(
            "source_inspection_result_id",
            sa.String(length=32),
            sa.ForeignKey("inspection_results.id", ondelete="CASCADE"),
            nullable=True,
        ),
    )
    op.create_unique_constraint(
        "uq_tickets_source_inspection_result_id", "tickets", ["source_inspection_result_id"]
    )
    op.create_check_constraint(
        "ck_tickets_exactly_one_source",
        "tickets",
        "(source_entry_id IS NULL) != (source_inspection_result_id IS NULL)",
    )


def downgrade() -> None:
    op.drop_constraint("ck_tickets_exactly_one_source", "tickets", type_="check")
    op.drop_constraint("uq_tickets_source_inspection_result_id", "tickets", type_="unique")
    op.drop_column("tickets", "source_inspection_result_id")
    op.alter_column("tickets", "source_entry_id", nullable=False)
    op.drop_column("tickets", "source_kind")
    TICKET_SOURCE_KIND.drop(op.get_bind())
```

Check `backend/alembic/versions/0029_breakdown_reported_time_and_backfill.py`'s actual `revision`/`down_revision` string values before writing this file — Alembic revision ids in this repo may be short hashes rather than the plain `"0029"` shown above (confirm the exact convention from the last two files in `alembic/versions/` and match it, since a mismatched `down_revision` breaks the chain).

- [ ] **Step 7: Run migration and tests**

Run: `.venv/bin/python -m alembic upgrade head` then `.venv/bin/python -m pytest tests/test_tickets.py -v` (from `backend/`)
Expected: migration applies cleanly; both new tests PASS; no existing `test_tickets.py` test regresses (existing tickets all still have `source_entry_id` set and now also `source_kind`).

- [ ] **Step 8: Commit**

```bash
git add backend/app/models/enums.py backend/app/models/ticket.py backend/app/models/checklist.py backend/alembic/versions/0030_ticket_source_generalization.py backend/tests/test_tickets.py
git commit -m "Give Ticket a second source shape: inspection results"
```

---

## Task 2: `services/tickets.py` — inspection-result tickets, generalized title/search/completion

**Files:**
- Modify: `backend/app/services/tickets.py`
- Test: `backend/tests/test_tickets.py`

**Interfaces:**
- Consumes: `Ticket.source_kind`, `Ticket.source_inspection_result_id` (Task 1).
- Produces: `TICKETABLE_REGISTERS` (unchanged shape, `pm_schedule` removed); `create_ticket_for_inspection_result(session, *, result: InspectionResult, creator: User) -> Ticket`; `ticket_title(ticket: Ticket) -> str` (signature changes from `ticket_title(entry)` — every call site updates in this task); `ticket_entry_date(ticket: Ticket) -> date`; `search_tickets(..., source_kind: TicketSourceKind | None, ...)` (param renamed from `register`).

- [ ] **Step 1: Write the failing tests**

```python
# backend/tests/test_tickets.py (append)
async def test_inspection_result_cannot_get_two_tickets(session, failed_inspection_result, staff_user) -> None:
    await tickets.create_ticket_for_inspection_result(
        session, result=failed_inspection_result, creator=staff_user
    )
    with pytest.raises(Conflict):
        await tickets.create_ticket_for_inspection_result(
            session, result=failed_inspection_result, creator=staff_user
        )


async def test_pm_schedule_is_no_longer_ticketable(session, seeded_pm_entry, staff_user) -> None:
    with pytest.raises(Conflict):
        await tickets.create_ticket_for_entry(session, entry=seeded_pm_entry, creator=staff_user)


async def test_ticket_title_for_inspection_source(session, failed_inspection_result, staff_user) -> None:
    ticket = await tickets.create_ticket_for_inspection_result(
        session, result=failed_inspection_result, creator=staff_user
    )
    title = tickets.ticket_title(ticket)
    assert failed_inspection_result.item.label[:20] in title
    assert failed_inspection_result.inspection.vehicle.registration_no in title


async def test_search_tickets_scopes_inspection_source_by_site(
    session, failed_inspection_result, other_site_failed_inspection_result, staff_user
) -> None:
    await tickets.create_ticket_for_inspection_result(session, result=failed_inspection_result, creator=staff_user)
    await tickets.create_ticket_for_inspection_result(
        session, result=other_site_failed_inspection_result, creator=staff_user
    )
    results = await tickets.search_tickets(
        session, site_code=failed_inspection_result.inspection.site_code, source_kind=None, q=None
    )
    ids = {t.id for t in results}
    assert any(
        t.source_inspection_result_id == failed_inspection_result.id for t in results
    )
    assert not any(
        t.source_inspection_result_id == other_site_failed_inspection_result.id for t in results
    )
```

Before writing these, check `backend/tests/test_inspections.py` and `backend/tests/conftest.py` for existing fixtures/helpers that build a failed `InspectionResult` (e.g. a `_fail_inspection` or `_record_inspection` helper) — reuse them rather than hand-building `InspectionEntry`/`InspectionResult` rows, matching this file's existing style.

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv/bin/python -m pytest tests/test_tickets.py -v` (from `backend/`)
Expected: FAIL — `AttributeError: module 'app.services.tickets' has no attribute 'create_ticket_for_inspection_result'`.

- [ ] **Step 3: Rewrite `app/services/tickets.py`**

```python
from __future__ import annotations

from datetime import datetime

from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import Conflict
from app.models.checklist import InspectionEntry, InspectionResult
from app.models.entry import BreakdownEntry, Entry
from app.models.enums import CheckResult, EntryStatus, Register, TicketSourceKind, TicketStatus
from app.models.ticket import Ticket
from app.models.user import User

#: Which register types may ever have a ticket automatically or via "Raise
#: ticket". PM/Docking's ticket path now runs through InspectionEntry (see
#: create_ticket_for_inspection_result) — pm_schedule is retired for entry
#: creation, so it can never be a source here.
TICKETABLE_REGISTERS = frozenset(
    {Register.breakdown, Register.coolant, Register.driver_complaint}
)

_REGISTER_SOURCE_KIND: dict[Register, TicketSourceKind] = {
    Register.breakdown: TicketSourceKind.breakdown,
    Register.coolant: TicketSourceKind.coolant,
    Register.driver_complaint: TicketSourceKind.driver_complaint,
}

#: work_type.code -> the ticket source kind an inspection failure raises.
#: Matches the same literal codes `docking_km.py`'s DOCKING_WORK_TYPE and the
#: seeded catalogue already use ("D.I", "10 DAYS SERVICE", "P.M").
_INSPECTION_WORK_TYPE_SOURCE_KIND: dict[str, TicketSourceKind] = {
    "D.I": TicketSourceKind.daily_inspection,
    "10 DAYS SERVICE": TicketSourceKind.ten_day_inspection,
    "P.M": TicketSourceKind.pm_docking,
}


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
    ticket = Ticket(
        source_entry_id=entry.id,
        source_kind=_REGISTER_SOURCE_KIND[entry.register],
        created_by_id=creator.id,
    )
    session.add(ticket)
    await session.flush()
    return ticket


async def create_ticket_for_inspection_result(
    session: AsyncSession, *, result: InspectionResult, creator: User
) -> Ticket:
    """Automatic — called for every `not_ok` result when an inspection is
    recorded. One ticket per failed check line, not per inspection."""
    existing = await session.scalar(
        select(Ticket).where(Ticket.source_inspection_result_id == result.id)
    )
    if existing is not None:
        raise Conflict("This inspection result already has a ticket")
    work_type_code = result.inspection.work_type.code
    source_kind = _INSPECTION_WORK_TYPE_SOURCE_KIND.get(work_type_code)
    if source_kind is None:
        raise Conflict(f"{work_type_code} is not a ticketable inspection type")
    ticket = Ticket(
        source_inspection_result_id=result.id,
        source_kind=source_kind,
        created_by_id=creator.id,
    )
    session.add(ticket)
    await session.flush()
    return ticket


#: How each register's own text is rendered as a ticket's search title.
_TITLE_FIELD = {
    Register.breakdown: lambda d: d.complaint,
    Register.coolant: lambda d: "Coolant topping",
    Register.driver_complaint: lambda d: d.complaint,
}


def ticket_title(ticket: Ticket) -> str:
    if ticket.source_entry_id is not None:
        entry = ticket.source_entry
        label = _TITLE_FIELD[entry.register](entry.detail)
        bus = entry.vehicle.registration_no
        return f"{label[:60]} · {bus}"
    result = ticket.source_inspection_result
    label = result.item.label
    bus = result.inspection.vehicle.registration_no
    return f"{label[:60]} · {bus}"


def ticket_entry_date(ticket: Ticket):
    if ticket.source_entry_id is not None:
        return ticket.source_entry.entry_date
    return ticket.source_inspection_result.inspection.inspected_on


async def search_tickets(
    session: AsyncSession,
    *,
    site_code: str,
    source_kind: TicketSourceKind | None,
    q: str | None,
) -> list[Ticket]:
    entry_stmt = (
        select(Ticket)
        .join(Entry, Entry.id == Ticket.source_entry_id)
        .where(Entry.site_code == site_code, Ticket.status == TicketStatus.open)
    )
    inspection_stmt = (
        select(Ticket)
        .join(InspectionResult, InspectionResult.id == Ticket.source_inspection_result_id)
        .join(InspectionEntry, InspectionEntry.id == InspectionResult.inspection_id)
        .where(InspectionEntry.site_code == site_code, Ticket.status == TicketStatus.open)
    )
    if source_kind is not None:
        entry_stmt = entry_stmt.where(Ticket.source_kind == source_kind)
        inspection_stmt = inspection_stmt.where(Ticket.source_kind == source_kind)
    if q:
        needle = f"%{q.strip().lower()}%"
        entry_stmt = entry_stmt.where(
            or_(Entry.search_text.like(needle), Ticket.id == q.strip(), Entry.id == q.strip())
        )
        inspection_stmt = inspection_stmt.where(
            or_(InspectionResult.remark.ilike(needle), Ticket.id == q.strip())
        )
    entry_tickets = (await session.scalars(entry_stmt)).unique().all()
    inspection_tickets = (
        [] if source_kind is not None and source_kind not in _INSPECTION_WORK_TYPE_SOURCE_KIND.values()
        else (await session.scalars(inspection_stmt)).unique().all()
    )
    combined = [*entry_tickets, *inspection_tickets]
    combined.sort(key=ticket_entry_date, reverse=True)
    return combined


def mark_attended(ticket: Ticket, at: datetime) -> None:
    if ticket.attended_at is not None:
        return
    ticket.attended_at = at
    if ticket.source_entry_id is not None and ticket.source_entry.register is Register.breakdown:
        detail: BreakdownEntry = ticket.source_entry.breakdown
        detail.attended_time = at.timetz().replace(tzinfo=None)


async def complete_ticket(
    session: AsyncSession, *, ticket: Ticket, completed_by: User, completed_at: datetime
) -> None:
    if ticket.status is TicketStatus.completed:
        raise Conflict("This ticket is already completed")
    ticket.status = TicketStatus.completed
    ticket.completed_at = completed_at
    ticket.completed_by_id = completed_by.id

    if ticket.source_entry_id is None:
        # Inspection-sourced: nothing else to mirror. The result's own
        # ticket_status (surfaced via InspectionResult.ticket) is now
        # "completed" — that's the whole signal back to the inspection.
        return

    source = ticket.source_entry
    source.status = EntryStatus.resolved
    source.updated_at = completed_at
    if source.register is Register.breakdown:
        detail: BreakdownEntry = source.breakdown
        detail.resolved_at = completed_at
        detail.resolved_by_id = completed_by.id
```

- [ ] **Step 4: Update callers of the old `ticket_title(entry)`/`register=` signatures**

`grep -rn "ticket_title\|search_tickets" backend/app --include=*.py` and fix each call site found (expect `backend/app/api/tickets.py`, done in Task 3, and possibly `backend/app/services/entries.py` if it calls `ticket_title` anywhere — check before assuming it doesn't).

- [ ] **Step 5: Run the full ticket test file**

Run: `.venv/bin/python -m pytest tests/test_tickets.py -v` (from `backend/`)
Expected: all PASS, including the four new tests and every pre-existing one (breakdown/coolant/complaint behavior is unchanged — only the internals moved).

- [ ] **Step 6: Commit**

```bash
git add backend/app/services/tickets.py backend/tests/test_tickets.py
git commit -m "Generalize services/tickets.py to inspection-result sources"
```

---

## Task 3: `api/tickets.py` — search by `source_kind`

**Files:**
- Modify: `backend/app/api/tickets.py`
- Modify: `backend/app/schemas/ticket.py`
- Test: `backend/tests/test_tickets.py`

**Interfaces:**
- Consumes: `search_tickets(..., source_kind=...)`, `ticket_title(ticket)`, `ticket_entry_date(ticket)` (Task 2).
- Produces: `GET /tickets/search?source_kind=<kind>&q=<text>` → `TicketSearchResult{ticket_id, title, entry_date, status, source_kind}`.

- [ ] **Step 1: Write the failing test**

```python
# backend/tests/test_tickets.py (append)
async def test_search_endpoint_accepts_source_kind(client, auth_headers, failed_inspection_result) -> None:
    h = await auth_headers
    r = await client.get(
        "/tickets/search",
        params={"site": failed_inspection_result.inspection.site_code, "source_kind": "daily_inspection"},
        headers=h,
    )
    assert r.status_code == 200, r.text
    assert all(t["source_kind"] == "daily_inspection" for t in r.json())
```

Match this repo's existing `client`/`auth_headers` fixture usage exactly as the surrounding tests in `test_tickets.py` already do (some use `await auth_headers(client)` as a function call rather than a fixture — check the file's existing tests before copying this pattern verbatim).

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/python -m pytest tests/test_tickets.py -k source_kind -v` (from `backend/`)
Expected: FAIL — 422 (`source_kind` not a recognized query param yet) or `KeyError: 'source_kind'` on the response body.

- [ ] **Step 3: Update `app/schemas/ticket.py`**

```python
class TicketSearchResult(BaseModel):
    ticket_id: str
    title: str
    entry_date: date_t
    status: str
    source_kind: str
```

- [ ] **Step 4: Update `app/api/tickets.py`**

```python
from app.models.enums import TicketSourceKind

@router.get("/search", response_model=list[TicketSearchResult])
async def search(
    _user: CurrentUser,
    session: SessionDep,
    site: EntrySite,
    source_kind: Annotated[TicketSourceKind | None, Query()] = None,
    q: Annotated[str | None, Query(max_length=200)] = None,
) -> list[TicketSearchResult]:
    tickets = await svc.search_tickets(session, site_code=site, source_kind=source_kind, q=q)
    return [
        TicketSearchResult(
            ticket_id=t.id,
            title=svc.ticket_title(t),
            entry_date=svc.ticket_entry_date(t),
            status=t.status.value,
            source_kind=t.source_kind.value,
        )
        for t in tickets
    ]
```

Remove the now-unused `from app.models.enums import Register` import if nothing else in the file needs it.

- [ ] **Step 5: Run tests**

Run: `.venv/bin/python -m pytest tests/test_tickets.py -v` (from `backend/`)
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add backend/app/api/tickets.py backend/app/schemas/ticket.py backend/tests/test_tickets.py
git commit -m "Search tickets by source_kind, not register"
```

---

## Task 4: Inspection failures raise tickets automatically

**Files:**
- Modify: `backend/app/services/checklists.py:272-420` (`record_inspection`)
- Test: `backend/tests/test_inspections.py`

**Interfaces:**
- Consumes: `tickets.create_ticket_for_inspection_result` (Task 2).
- Produces: `record_inspection(..., actor: User) -> InspectionEntry` now also raises one `Ticket` per `not_ok` result, same transaction. Signature is unchanged (already takes `actor`).

- [ ] **Step 1: Write the failing tests**

```python
# backend/tests/test_inspections.py (append)
async def test_failed_check_raises_one_ticket_per_failure(session, site, vehicle, di_work_type, di_template, staff_user) -> None:
    item_ids = [item.id for item in di_template.items[:2]]
    inspection = await checklists.record_inspection(
        session,
        site_code=site.code,
        vehicle=vehicle,
        work_type=di_work_type,
        inspected_on=date(2026, 9, 25),
        entry_time=None,
        done_by=None,
        supervisor=None,
        odometer_km=None,
        remarks=None,
        results=[
            (item_ids[0], CheckResult.not_ok, None, "brake pad worn"),
            (item_ids[1], CheckResult.not_ok, None, "headlamp dim"),
        ],
        actor=staff_user,
    )
    tickets_raised = (
        await session.scalars(
            select(Ticket).join(InspectionResult, InspectionResult.id == Ticket.source_inspection_result_id)
            .where(InspectionResult.inspection_id == inspection.id)
        )
    ).all()
    assert len(tickets_raised) == 2
    assert {t.source_kind for t in tickets_raised} == {TicketSourceKind.daily_inspection}


async def test_passing_inspection_raises_no_tickets(session, site, vehicle, di_work_type, di_template, staff_user) -> None:
    item_ids = [item.id for item in di_template.items[:2]]
    inspection = await checklists.record_inspection(
        session, site_code=site.code, vehicle=vehicle, work_type=di_work_type,
        inspected_on=date(2026, 9, 25), entry_time=None, done_by=None, supervisor=None,
        odometer_km=None, remarks=None,
        results=[(item_ids[0], CheckResult.ok, None, None), (item_ids[1], CheckResult.ok, None, None)],
        actor=staff_user,
    )
    count = await session.scalar(
        select(func.count()).select_from(Ticket)
        .join(InspectionResult, InspectionResult.id == Ticket.source_inspection_result_id)
        .where(InspectionResult.inspection_id == inspection.id)
    )
    assert count == 0
```

Check `backend/tests/test_inspections.py`'s existing fixtures (`site`, `vehicle`, work-type/template fixtures for D.I) before assuming these exact names — reuse whatever it already has for "a D.I checklist with at least two items."

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv/bin/python -m pytest tests/test_inspections.py -k raises_ticket -v` (from `backend/`)
Expected: FAIL — `assert 0 == 2` (no tickets raised yet).

- [ ] **Step 3: Wire ticket creation into `record_inspection`**

In `app/services/checklists.py`, add the import `from app.services import tickets as ticket_service`. After the existing `await session.flush()` that follows `inspection.results.append(...)` (the flush that gives each `InspectionResult` its id — the one immediately before the odometer-reading block), add:

```python
    for result in inspection.results:
        if result.result is CheckResult.not_ok:
            await ticket_service.create_ticket_for_inspection_result(
                session, result=result, creator=actor
            )
```

Place this *before* the odometer-reading block so a ticket-creation failure (an unticketable work type) surfaces before any side effect runs — though in practice every `is_inspection` work type is one of the three ticketable codes today.

- [ ] **Step 4: Run tests**

Run: `.venv/bin/python -m pytest tests/test_inspections.py tests/test_tickets.py -v` (from `backend/`)
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add backend/app/services/checklists.py backend/tests/test_inspections.py
git commit -m "Raise a ticket for every failed inspection check"
```

---

## Task 5: Inspection results reflect their ticket's status

**Files:**
- Modify: `backend/app/schemas/checklist.py:110-133` (`ResultOut`)
- Modify: `backend/app/api/checklists.py:60-91` (`_inspection_out`)
- Test: `backend/tests/test_inspections.py`

**Interfaces:**
- Consumes: `InspectionResult.ticket` (Task 1).
- Produces: `ResultOut.ticket_id: str | None`, `ResultOut.ticket_status: str | None`.

- [ ] **Step 1: Write the failing test**

```python
# backend/tests/test_inspections.py (append)
async def test_inspection_get_shows_ticket_status_on_failed_result(
    client, auth_headers, site, vehicle, di_work_type, di_template
) -> None:
    h = await auth_headers(client)
    item_id = di_template.items[0].id
    created = (await client.post(
        f"/sites/{site.code}/inspections",
        json={
            "vehicle_id": vehicle.id, "work_type_id": di_work_type.id,
            "inspected_on": "2026-09-25",
            "results": [{"item_id": item_id, "result": "not_ok", "remark": "brake pad worn"}],
        },
        headers=h,
    )).json()
    result = next(r for r in created["results"] if r["item_id"] == item_id)
    assert result["ticket_id"] is not None
    assert result["ticket_status"] == "open"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/python -m pytest tests/test_inspections.py -k ticket_status -v` (from `backend/`)
Expected: FAIL — `KeyError: 'ticket_status'`.

- [ ] **Step 3: Add the fields to `ResultOut`**

```python
class ResultOut(BaseModel):
    item_id: str
    section: str = ""
    label: str = ""
    result: CheckResult
    value: str | None = None
    remark: str | None = None
    ticket_id: str | None = None
    ticket_status: str | None = None
```

- [ ] **Step 4: Populate them in `_inspection_out`**

```python
        results=[
            ResultOut(
                item_id=r.item_id,
                section=r.item.section if r.item else "",
                label=r.item.label if r.item else "",
                result=r.result,
                value=r.value,
                remark=r.remark,
                ticket_id=r.ticket.id if r.ticket else None,
                ticket_status=r.ticket.status.value if r.ticket else None,
            )
            for r in inspection.results
        ],
```

- [ ] **Step 5: Run tests**

Run: `.venv/bin/python -m pytest tests/test_inspections.py -v` (from `backend/`)
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add backend/app/schemas/checklist.py backend/app/api/checklists.py backend/tests/test_inspections.py
git commit -m "Surface a failed inspection result's ticket status"
```

---

## Task 6: Multiple Bus Inspection — batch endpoint

**Files:**
- Modify: `backend/app/schemas/checklist.py`
- Modify: `backend/app/services/checklists.py`
- Modify: `backend/app/api/checklists.py`
- Test: `backend/tests/test_inspections.py`

**Interfaces:**
- Consumes: `checklists.record_inspection` (existing, unchanged signature).
- Produces: `InspectionBatchCreate{work_type_id, inspected_on, entry_time, supervisor, items: list[InspectionBatchItem]}`, `InspectionBatchItem{vehicle_id, odometer_km, milestone_km, done_by, remarks, results}`, `InspectionBatchOut{items: list[InspectionOut]}`; `record_inspection_batch(session, *, site_code, work_type, inspected_on, entry_time, supervisor, items, actor) -> list[InspectionEntry]`; `POST /sites/{code}/inspections/batch`.

- [ ] **Step 1: Write the failing tests**

```python
# backend/tests/test_inspections.py (append)
async def test_batch_inspection_creates_one_entry_per_vehicle(
    client, auth_headers, site, vehicle, other_vehicle, di_work_type, di_template
) -> None:
    h = await auth_headers(client)
    item_id = di_template.items[0].id
    r = await client.post(
        f"/sites/{site.code}/inspections/batch",
        json={
            "work_type_id": di_work_type.id,
            "inspected_on": "2026-09-25",
            "items": [
                {"vehicle_id": vehicle.id, "results": [{"item_id": item_id, "result": "ok"}]},
                {"vehicle_id": other_vehicle.id, "results": [{"item_id": item_id, "result": "not_ok", "remark": "worn"}]},
            ],
        },
        headers=h,
    )
    assert r.status_code == 201, r.text
    body = r.json()
    assert len(body["items"]) == 2
    assert body["items"][1]["failed_count"] == 1


async def test_batch_inspection_rolls_back_entirely_on_one_bad_vehicle(
    client, auth_headers, site, vehicle, di_work_type, di_template
) -> None:
    h = await auth_headers(client)
    item_id = di_template.items[0].id
    r = await client.post(
        f"/sites/{site.code}/inspections/batch",
        json={
            "work_type_id": di_work_type.id,
            "inspected_on": "2026-09-25",
            "items": [
                {"vehicle_id": vehicle.id, "results": [{"item_id": item_id, "result": "ok"}]},
                {"vehicle_id": "not-a-real-vehicle", "results": [{"item_id": item_id, "result": "ok"}]},
            ],
        },
        headers=h,
    )
    assert r.status_code in (400, 404), r.text
    surviving = await client.get(
        f"/sites/{site.code}/inspections",
        params={"work_type_id": di_work_type.id, "from": "2026-09-25", "to": "2026-09-25"},
        headers=h,
    )
    assert surviving.json()["total"] == 0
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv/bin/python -m pytest tests/test_inspections.py -k batch -v` (from `backend/`)
Expected: FAIL — 404 (route doesn't exist).

- [ ] **Step 3: Add schemas to `app/schemas/checklist.py`**

```python
class InspectionBatchItem(BaseModel):
    vehicle_id: str = Field(min_length=1, max_length=64)
    odometer_km: int | None = Field(default=None, ge=0, le=10_000_000)
    milestone_km: int | None = Field(default=None, ge=0, le=10_000_000)
    done_by: str | None = Field(default=None, max_length=1000)
    remarks: str | None = None
    results: list[ResultIn] = Field(default_factory=list)


class InspectionBatchCreate(BaseModel):
    work_type_id: int
    inspected_on: date_t
    entry_time: HHMM | None = None
    supervisor: str | None = Field(default=None, max_length=255)
    items: list[InspectionBatchItem] = Field(min_length=1, max_length=200)


class InspectionBatchOut(BaseModel):
    items: list[InspectionOut]
```

- [ ] **Step 4: Add `record_inspection_batch` to `app/services/checklists.py`**

```python
async def record_inspection_batch(
    session: AsyncSession,
    *,
    site_code: str,
    work_type: WorkType,
    inspected_on: date_t,
    entry_time: time_t | None,
    supervisor: str | None,
    items: list[tuple[str, int | None, int | None, str | None, str | None, list[tuple[str, CheckResult, str | None, str | None]]]],
    actor: User,
) -> list[InspectionEntry]:
    """Multiple Bus Inspection: every vehicle in one transaction — a bad
    vehicle anywhere in the list fails the whole batch, since a partial
    submission would misreport as "not yet inspected" for the buses that
    should have recorded but didn't reach the request at all."""
    out: list[InspectionEntry] = []
    for vehicle_id, odometer_km, milestone_km, done_by, remarks, results in items:
        vehicle = await session.get(Vehicle, vehicle_id)
        if vehicle is None:
            raise NotFound(f"Vehicle {vehicle_id} not found")
        inspection = await record_inspection(
            session,
            site_code=site_code,
            vehicle=vehicle,
            work_type=work_type,
            inspected_on=inspected_on,
            entry_time=entry_time,
            done_by=done_by,
            supervisor=supervisor,
            odometer_km=odometer_km,
            remarks=remarks,
            results=results,
            actor=actor,
            milestone_km=milestone_km,
        )
        out.append(inspection)
    return out
```

`record_inspection` already raises (`NotFound`/`ValidationError`/`Conflict`) rather than swallowing errors, and the caller (`api/checklists.py`) commits once after this returns — an exception here propagates out of the endpoint before any `session.commit()`, so nothing partial persists as long as the endpoint doesn't commit per-item (verify this in Step 5).

- [ ] **Step 5: Add the endpoint to `app/api/checklists.py`**

```python
@router.post(
    "/sites/{code}/inspections/batch",
    response_model=InspectionBatchOut,
    status_code=status.HTTP_201_CREATED,
)
async def record_inspection_batch(
    code: str, payload: InspectionBatchCreate, user: CurrentUser, session: SessionDep
) -> InspectionBatchOut:
    site_code = assert_site_permission(user, code, "em_inspection:write")
    work_type = await session.get(WorkType, payload.work_type_id)
    if work_type is None:
        raise NotFound("Inspection type not found")

    inspections = await checklists.record_inspection_batch(
        session,
        site_code=site_code,
        work_type=work_type,
        inspected_on=payload.inspected_on,
        entry_time=payload.entry_time,
        supervisor=payload.supervisor,
        items=[
            (
                item.vehicle_id, item.odometer_km, item.milestone_km, item.done_by, item.remarks,
                [(r.item_id, r.result, r.value, r.remark) for r in item.results],
            )
            for item in payload.items
        ],
        actor=user,
    )
    for inspection in inspections:
        await audit.record(
            session, actor_id=user.id, action=AuditAction.inspection_recorded,
            object_type="inspection", object_id=inspection.id,
            after={"site": site_code, "work_type": work_type.code, "batch": True, "failed": len(inspection.failed)},
        )
    await session.commit()
    for inspection in inspections:
        await session.refresh(inspection)
    return InspectionBatchOut(items=[_inspection_out(i) for i in inspections])
```

Import `InspectionBatchCreate`, `InspectionBatchOut` in the `from app.schemas.checklist import (...)` block.

- [ ] **Step 6: Run tests**

Run: `.venv/bin/python -m pytest tests/test_inspections.py -v` (from `backend/`)
Expected: all PASS. Confirm the rollback test specifically: no `InspectionEntry` survives when any item in the batch fails (this is the one `session.commit()` at the end of the endpoint doing its job — if it were split into per-item commits this test would catch it).

- [ ] **Step 7: Commit**

```bash
git add backend/app/schemas/checklist.py backend/app/services/checklists.py backend/app/api/checklists.py backend/tests/test_inspections.py
git commit -m "Add Multiple Bus Inspection: one batch endpoint, one transaction"
```

---

## Task 7: Flutter — Multiple Bus Inspection

**Files:**
- Modify: `app/lib/data/repositories.dart`
- Modify: `app/lib/data/api/api_repositories.dart`
- Modify: `app/test/support/fake_repositories.dart`
- Modify: `app/lib/screens/inspection_form_screen.dart`
- Test: `app/test/api_contract_test.dart`

**Interfaces:**
- Consumes: `InspectionRepository.recordInspection({required siteCode, required vehicleId, required workTypeId, required inspectedOn, entryTime, doneBy, supervisor, odometerKm, remarks, milestoneKm, required results})` (existing, `app/lib/data/repositories.dart:384-396`, unchanged).
- Produces: `InspectionRepository.recordInspectionBatch({required String siteCode, required int workTypeId, required String inspectedOn, String? entryTime, String? supervisor, required List<InspectionBatchItem> items}) -> List<InspectionEntry>`; new `InspectionBatchItem{vehicleId, odometerKm, milestoneKm, doneBy, remarks, results}` model in `app/lib/models/inspection.dart` (check that file for where `InspectionEntry`/`InspectionResult` are already defined and add the new type alongside them).

- [ ] **Step 1: Write the failing test**

Add a test to `app/test/api_contract_test.dart` following that file's existing pattern for the single-inspection submit test (locate it first: `grep -n "inspection" app/test/api_contract_test.dart`), asserting a batch submission with 2 vehicles posts to `/inspections/batch` with both items in one request body, and that the fake repository records both.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/api_contract_test.dart` (from `app/`)
Expected: FAIL — method doesn't exist.

- [ ] **Step 3: Add the repository method (abstract + API + fake)**

`repositories.dart`, on `InspectionRepository` (alongside the existing `recordInspection`):

```dart
  Future<List<InspectionEntry>> recordInspectionBatch({
    required String siteCode,
    required int workTypeId,
    required String inspectedOn,
    String? entryTime,
    String? supervisor,
    required List<InspectionBatchItem> items,
  });
```

`api_repositories.dart`: `POST /sites/{code}/inspections/batch`, body matching Task 6's `InspectionBatchCreate` shape, response parsed as `List<InspectionEntry>` from the `items` key. `fake_repositories.dart`: loop `items`, append one fake `InspectionEntry` per vehicle to the fake store, reusing whatever internal helper the fake's existing `recordInspection` already uses to build one.

- [ ] **Step 4: Add a multi-select mode to `inspection_form_screen.dart`**

A toggle ("Single bus" / "Multiple buses") that, in multi mode, replaces the single bus picker with a multi-select vehicle list (reuse whatever chip/checkbox list widget this codebase already uses elsewhere for multi-select — check `register_form_screen.dart`'s attendee picker widget added in the merged ticket branch before building a new one) and shares one checklist/date/time/supervisor across all selected vehicles, submitting via `recordInspectionBatch`.

- [ ] **Step 5: Run tests**

Run: `flutter test` (from `app/`)
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add app/lib/data/repositories.dart app/lib/data/api/api_repositories.dart app/test/support/fake_repositories.dart app/lib/screens/inspection_form_screen.dart app/test/api_contract_test.dart
git commit -m "Add Multiple Bus Inspection to the Flutter client"
```

---

## Task 8: Spare Parts catalog — model, migration, master API

**Files:**
- Modify: `backend/app/models/master.py`
- Create: `backend/alembic/versions/0031_spare_parts.py`
- Create: `backend/app/schemas/site_masters.py`
- Create: `backend/app/api/site_masters.py`
- Modify: `backend/app/api/__init__.py`
- Test: `backend/tests/test_site_masters.py` (new file)

**Interfaces:**
- Produces: `SparePart{id, site_code, part_no, name, is_active}`; `GET/POST /sites/{code}/spare-parts`; `POST /spare-parts/{id}/activate|deactivate`.

- [ ] **Step 1: Write the failing test**

```python
# backend/tests/test_site_masters.py (new file)
from httpx import AsyncClient


async def test_create_and_list_spare_parts(client: AsyncClient, auth_headers) -> None:
    h = await auth_headers(client)
    created = (await client.post(
        "/sites/MBMT/spare-parts", json={"part_no": "SP-1001", "name": "Brake pad set"}, headers=h
    )).json()
    assert created["part_no"] == "SP-1001"

    listed = (await client.get("/sites/MBMT/spare-parts", headers=h)).json()
    assert any(p["part_no"] == "SP-1001" for p in listed["items"])


async def test_spare_part_no_is_unique_per_site(client: AsyncClient, auth_headers) -> None:
    h = await auth_headers(client)
    await client.post("/sites/MBMT/spare-parts", json={"part_no": "SP-2001", "name": "Filter"}, headers=h)
    dup = await client.post(
        "/sites/MBMT/spare-parts", json={"part_no": "SP-2001", "name": "Filter (dup)"}, headers=h
    )
    assert dup.status_code == 409
```

Use whatever this repo's `client`/`auth_headers` fixtures actually are (check `test_units.py`'s imports/usage, which this plan already confirmed works with `client: AsyncClient` + `h = await auth_headers(client)`).

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/python -m pytest tests/test_site_masters.py -v` (from `backend/`)
Expected: FAIL — 404 (route doesn't exist).

- [ ] **Step 3: Add `SparePart` to `app/models/master.py`**

```python
class SparePart(Base):
    """A depot's own stocked-parts catalogue — site-scoped like Vehicle, not
    tenant-wide like DefectSource/DefectType/WorkType: a part number one
    depot stocks means nothing at another."""

    __tablename__ = "spare_parts"
    __table_args__ = (UniqueConstraint("site_code", "part_no", name="uq_spare_parts_site_code_part_no"),)

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_uuid)
    site_code: Mapped[str] = mapped_column(String(50), ForeignKey("sites.code", ondelete="CASCADE"), nullable=False)
    part_no: Mapped[str] = mapped_column(String(64), nullable=False)
    name: Mapped[str] = mapped_column(String(160), nullable=False)
    is_active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True, server_default="true")
```

Check the top of `master.py` for its existing `new_uuid`/`Base` imports (used by `Vehicle`) and follow the same id-generation convention (`String(32), default=new_uuid`) — do not introduce an `Integer` autoincrement id here, since this table is meant to line up with `SparePart.id` being referenced as a string FK from `work_done_spare_parts` in Task 9, matching `Vehicle.id`'s string-uuid convention, not `DefectSource.id`'s integer-autoincrement one.

- [ ] **Step 4: Write the migration — `0031_spare_parts.py`**

```python
"""Add the site-scoped spare_parts catalogue.

Revision ID: 0031
Revises: 0030
"""
from alembic import op
import sqlalchemy as sa

revision = "0031"
down_revision = "0030"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "spare_parts",
        sa.Column("id", sa.String(length=32), primary_key=True),
        sa.Column("site_code", sa.String(length=50), sa.ForeignKey("sites.code", ondelete="CASCADE"), nullable=False),
        sa.Column("part_no", sa.String(length=64), nullable=False),
        sa.Column("name", sa.String(length=160), nullable=False),
        sa.Column("is_active", sa.Boolean, nullable=False, server_default="true"),
        sa.UniqueConstraint("site_code", "part_no", name="uq_spare_parts_site_code_part_no"),
    )


def downgrade() -> None:
    op.drop_table("spare_parts")
```

Confirm the actual `revision`/`down_revision` id format against `0030`'s file (written in Task 1) before finalizing this string — they must match exactly for the chain to resolve.

- [ ] **Step 5: Write `app/schemas/site_masters.py`**

```python
from __future__ import annotations

from pydantic import BaseModel, Field, field_validator


class SparePartOut(BaseModel):
    id: str
    part_no: str
    name: str
    is_active: bool


class SparePartList(BaseModel):
    items: list[SparePartOut]


class SparePartCreate(BaseModel):
    part_no: str = Field(min_length=1, max_length=64)
    name: str = Field(min_length=1, max_length=160)

    @field_validator("part_no")
    @classmethod
    def _upper(cls, v: str) -> str:
        return " ".join(v.split()).upper()

    @field_validator("name")
    @classmethod
    def _strip(cls, v: str) -> str:
        return v.strip()
```

- [ ] **Step 6: Write `app/api/site_masters.py`**

```python
from __future__ import annotations

from fastapi import APIRouter, status
from sqlalchemy import select

from app.deps import CurrentUser, SessionDep, assert_site_permission
from app.errors import Conflict
from app.models.master import SparePart
from app.schemas.site_masters import SparePartCreate, SparePartList, SparePartOut

router = APIRouter(tags=["site-masters"])


def _spare_part_out(row: SparePart) -> SparePartOut:
    return SparePartOut(id=row.id, part_no=row.part_no, name=row.name, is_active=row.is_active)


@router.get("/sites/{code}/spare-parts", response_model=SparePartList)
async def list_spare_parts(code: str, user: CurrentUser, session: SessionDep) -> SparePartList:
    site_code = assert_site_permission(user, code, "em_master:read")
    rows = await session.scalars(
        select(SparePart).where(SparePart.site_code == site_code, SparePart.is_active.is_(True))
        .order_by(SparePart.part_no)
    )
    return SparePartList(items=[_spare_part_out(r) for r in rows])


@router.post("/sites/{code}/spare-parts", response_model=SparePartOut, status_code=status.HTTP_201_CREATED)
async def create_spare_part(
    code: str, payload: SparePartCreate, user: CurrentUser, session: SessionDep
) -> SparePartOut:
    site_code = assert_site_permission(user, code, "em_master:write")
    exists = await session.scalar(
        select(SparePart.id).where(SparePart.site_code == site_code, SparePart.part_no == payload.part_no)
    )
    if exists:
        raise Conflict(f"{payload.part_no} already exists", {"part_no": "duplicate"})
    row = SparePart(site_code=site_code, part_no=payload.part_no, name=payload.name)
    session.add(row)
    await session.commit()
    return _spare_part_out(row)


@router.post("/spare-parts/{part_id}/deactivate", response_model=SparePartOut)
async def deactivate_spare_part(part_id: str, user: CurrentUser, session: SessionDep) -> SparePartOut:
    row = await session.get(SparePart, part_id)
    if row is None:
        from app.errors import NotFound
        raise NotFound("Spare part not found")
    assert_site_permission(user, row.site_code, "em_master:write")
    row.is_active = False
    await session.commit()
    return _spare_part_out(row)
```

- [ ] **Step 7: Register the router**

In `app/api/__init__.py`, add `site_masters` to the import list and `api_router.include_router(site_masters.router)` (place it next to `master.router`).

- [ ] **Step 8: Run migration and tests**

Run: `.venv/bin/python -m alembic upgrade head` then `.venv/bin/python -m pytest tests/test_site_masters.py -v` (from `backend/`)
Expected: migration applies; both tests PASS.

- [ ] **Step 9: Commit**

```bash
git add backend/app/models/master.py backend/alembic/versions/0031_spare_parts.py backend/app/schemas/site_masters.py backend/app/api/site_masters.py backend/app/api/__init__.py backend/tests/test_site_masters.py
git commit -m "Add the site-scoped spare parts catalogue"
```

---

## Task 9: Work Done — spare parts multi-select, replacing free text

**Files:**
- Modify: `backend/app/models/entry.py` (`WorkDoneEntry`)
- Create: `backend/alembic/versions/0032_work_done_spare_parts.py`
- Modify: `backend/app/services/masters.py`
- Modify: `backend/app/services/entries.py`
- Modify: `backend/app/schemas/entry.py`
- Test: `backend/tests/test_entries.py`

**Interfaces:**
- Consumes: `SparePart` (Task 8).
- Produces: `WorkDoneData.spare_part_ids: list[str]` (replaces `spare_parts_used`); `serialize_data`'s Work Done branch returns `"spare_parts": [{part_id, part_no, name}]` instead of `"spare_parts_used"`.

- [ ] **Step 1: Write the failing test**

```python
# backend/tests/test_entries.py (append)
async def test_work_done_persists_multiple_spare_parts(client, auth_headers, site, vehicle, spare_part_a, spare_part_b) -> None:
    h = await auth_headers(client)
    created = (await client.post(
        "/entries",
        json={
            "register": "work_done", "site": site.code,
            "entry_date": "2026-09-25",
            "data": {
                "bus_no": vehicle.registration_no, "reported_defects": "AC not cooling",
                "spare_part_ids": [spare_part_a.id, spare_part_b.id],
            },
        },
        headers=h,
    )).json()
    part_ids = {p["part_id"] for p in created["data"]["spare_parts"]}
    assert part_ids == {spare_part_a.id, spare_part_b.id}


async def test_work_done_rejects_unknown_spare_part_id(client, auth_headers, site, vehicle) -> None:
    h = await auth_headers(client)
    r = await client.post(
        "/entries",
        json={
            "register": "work_done", "site": site.code, "entry_date": "2026-09-25",
            "data": {"bus_no": vehicle.registration_no, "reported_defects": "AC not cooling", "spare_part_ids": ["not-real"]},
        },
        headers=h,
    )
    assert r.status_code == 400
```

Check `test_entries.py`'s existing Work Done creation test for the exact `POST /entries` request shape (register/site/entry_date placement) before copying this verbatim — match whatever's already proven to work in that file rather than guessing the envelope.

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv/bin/python -m pytest tests/test_entries.py -k spare_part -v` (from `backend/`)
Expected: FAIL — `spare_part_ids` rejected as an unknown field (schema still has `spare_parts_used`, `extra="forbid"`).

- [ ] **Step 3: Add `work_done_spare_parts` and drop `spare_parts_used` — `app/models/entry.py`**

```python
class WorkDoneSparePart(Base):
    __tablename__ = "work_done_spare_parts"

    work_done_entry_id: Mapped[str] = mapped_column(
        String(32), ForeignKey("work_done_entries.entry_id", ondelete="CASCADE"), primary_key=True
    )
    spare_part_id: Mapped[str] = mapped_column(
        String(32), ForeignKey("spare_parts.id", ondelete="RESTRICT"), primary_key=True
    )

    spare_part: Mapped["SparePart"] = relationship(lazy="joined")
```

On `WorkDoneEntry`: remove the `spare_parts_used: Mapped[str | None] = mapped_column(Text, nullable=True)` column; add

```python
    spare_parts: Mapped[list["WorkDoneSparePart"]] = relationship(
        cascade="all, delete-orphan", lazy="selectin"
    )
```

Import `SparePart` from `app.models.master` under `TYPE_CHECKING` if not already imported.

- [ ] **Step 4: Write the migration — `0032_work_done_spare_parts.py`**

```python
"""Replace work_done_entries.spare_parts_used with a real catalogue join.

Revision ID: 0032
Revises: 0031
"""
from alembic import op
import sqlalchemy as sa

revision = "0032"
down_revision = "0031"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "work_done_spare_parts",
        sa.Column("work_done_entry_id", sa.String(length=32), sa.ForeignKey("work_done_entries.entry_id", ondelete="CASCADE"), primary_key=True),
        sa.Column("spare_part_id", sa.String(length=32), sa.ForeignKey("spare_parts.id", ondelete="RESTRICT"), primary_key=True),
    )
    # Backfill: every distinct non-null spare_parts_used string becomes one
    # spare_parts row (site-scoped from the entry it came from), split on
    # common delimiters; a value that doesn't split cleanly becomes one row
    # with the whole text as its name. Nothing is dropped.
    op.execute(
        """
        WITH split AS (
            SELECT
                wd.entry_id,
                e.site_code,
                trim(part) AS part_text
            FROM work_done_entries wd
            JOIN entries e ON e.id = wd.entry_id
            CROSS JOIN LATERAL regexp_split_to_table(wd.spare_parts_used, '[,;\\n]') AS part
            WHERE wd.spare_parts_used IS NOT NULL AND trim(wd.spare_parts_used) <> ''
        ),
        deduped AS (
            SELECT DISTINCT site_code, part_text FROM split WHERE part_text <> ''
        ),
        inserted AS (
            INSERT INTO spare_parts (id, site_code, part_no, name, is_active)
            SELECT gen_random_uuid()::text, site_code,
                   'LEGACY-' || substr(md5(part_text), 1, 8), part_text, true
            FROM deduped
            RETURNING id, site_code, name
        )
        INSERT INTO work_done_spare_parts (work_done_entry_id, spare_part_id)
        SELECT s.entry_id, i.id
        FROM split s
        JOIN inserted i ON i.site_code = s.site_code AND i.name = s.part_text
        WHERE s.part_text <> ''
        """
    )
    op.drop_column("work_done_entries", "spare_parts_used")


def downgrade() -> None:
    op.add_column("work_done_entries", sa.Column("spare_parts_used", sa.Text(), nullable=True))
    op.drop_table("work_done_spare_parts")
```

Verify `gen_random_uuid()` is available (the `pgcrypto` extension, or Postgres 13+'s built-in) by checking how other migrations in this repo generate ids server-side — if this repo generates ids application-side only, replace that call with a Python-side loop in the migration (`op.get_bind().execute(...)` per row) rather than assuming the extension is enabled.

- [ ] **Step 5: Add `resolve_spare_parts` to `app/services/masters.py`**

```python
async def resolve_spare_parts(
    session: AsyncSession, spare_part_ids: list[str], *, site_code: str
) -> list["SparePart"]:
    """Mirrors `entries._resolve_attendees`: ids must belong to this site,
    inactive rows still resolve (history keeps reading), unknown ids 400."""
    if not spare_part_ids:
        return []
    from app.models.master import SparePart
    rows = (
        await session.scalars(
            select(SparePart).where(SparePart.id.in_(spare_part_ids), SparePart.site_code == site_code)
        )
    ).unique().all()
    by_id = {p.id: p for p in rows}
    missing = [pid for pid in spare_part_ids if pid not in by_id]
    if missing:
        raise ValidationError(
            f"spare_part_ids: unknown spare part {missing[0]}", {"spare_part_ids": "unknown spare part"}
        )
    seen: set[str] = set()
    ordered = []
    for pid in spare_part_ids:
        if pid not in seen:
            seen.add(pid)
            ordered.append(by_id[pid])
    return ordered
```

Move the `SparePart` import to the top of `masters.py` alongside `DefectSource, DefectType, Vehicle` instead of inlining it, once this function exists.

- [ ] **Step 6: Wire it into `app/services/entries.py`**

In `_build_detail`'s `Register.work_done` branch: remove `spare_parts_used=data.spare_parts_used,` from the `WorkDoneEntry(...)` constructor and remove `data.spare_parts_used` from the returned searchable-values list; add a validate-only call mirroring the attendees call, right after the existing `await _resolve_attendees(...)` line:

```python
        await resolve_spare_parts(session, data.spare_part_ids, site_code=site_code)
```

Add `resolve_spare_parts` to the `from app.services.masters import (...)` import block.

Add `_set_spare_parts`, mirroring `_set_attendees` exactly:

```python
async def _set_spare_parts(
    session: AsyncSession, entry_id: str, detail: WorkDoneEntry, spare_part_ids: list[str], *, site_code: str
) -> None:
    parts = await resolve_spare_parts(session, spare_part_ids, site_code=site_code)
    rows = [
        WorkDoneSparePart(work_done_entry_id=entry_id, spare_part_id=p.id, spare_part=p)
        for p in parts
    ]
    session.add_all(rows)
    set_committed_value(detail, "spare_parts", rows)
```

Import `WorkDoneSparePart` from `app.models.entry`. In both `create_entry` and `update_entry`, inside the existing `if register is Register.work_done:` block (the one that already calls `_set_attendees`), add the matching call:

```python
        await _set_spare_parts(session, entry.id, detail, data.spare_part_ids, site_code=site_code)
```

- [ ] **Step 7: Update `WorkDoneData` and `serialize_data`**

`app/schemas/entry.py`: replace `spare_parts_used: OptText = None` with `spare_part_ids: list[str] = Field(default_factory=list)` on `WorkDoneData`.

`app/services/entries.py`'s `serialize_data`, Work Done branch: replace `"spare_parts_used": d.spare_parts_used,` with

```python
            "spare_parts": [
                {"part_id": sp.spare_part_id, "part_no": sp.spare_part.part_no, "name": sp.spare_part.name}
                for sp in d.spare_parts
            ],
```

- [ ] **Step 8: Run migration and tests**

Run: `.venv/bin/python -m alembic upgrade head` then `.venv/bin/python -m pytest tests/test_entries.py tests/test_tickets.py -v` (from `backend/`)
Expected: migration applies; both new tests PASS; no existing Work Done test regresses (check specifically for any test that still posts `spare_parts_used` — update it to `spare_part_ids` in this same task rather than leaving it broken).

- [ ] **Step 9: Commit**

```bash
git add backend/app/models/entry.py backend/alembic/versions/0032_work_done_spare_parts.py backend/app/services/masters.py backend/app/services/entries.py backend/app/schemas/entry.py backend/tests/test_entries.py
git commit -m "Replace Work Done's free-text spare parts with a catalogue multi-select"
```

---

## Task 10: Flutter — Spare Parts

**Files:**
- Create: `app/lib/models/spare_part.dart`
- Modify: `app/lib/data/repositories.dart`
- Modify: `app/lib/data/api/api_repositories.dart`
- Modify: `app/lib/data/api/field_map.dart`
- Modify: `app/lib/data/registers.dart`
- Modify: `app/lib/screens/register_form_screen.dart`
- Modify: `app/test/support/fake_repositories.dart`
- Test: `app/test/registers_test.dart`, `app/test/api_contract_test.dart`

**Interfaces:**
- Produces: `SparePart{id, partNo, name}`; `MasterDataRepository.sparePartDirectory({required String siteCode}) -> List<SparePart>`; `MasterDataRepository.createSparePart({required String siteCode, required String partNo, required String name}) -> SparePart`.

- [ ] **Step 1: Write `app/lib/models/spare_part.dart`**

```dart
import 'package:flutter/foundation.dart';

@immutable
class SparePart {
  const SparePart({required this.id, required this.partNo, required this.name});

  final String id;
  final String partNo;
  final String name;

  factory SparePart.fromJson(Map<String, dynamic> json) => SparePart(
        id: json['id'] as String,
        partNo: json['part_no'] as String,
        name: json['name'] as String,
      );
}
```

- [ ] **Step 2: Write the failing test**

Locate the merged branch's existing `staffDirectory()` test in `app/test/api_contract_test.dart` (search: `grep -n "staffDirectory" app/test/api_contract_test.dart`) and add an analogous `sparePartDirectory` round-trip test plus a Work Done submission test asserting `sparePartIds` is posted as a list under the `data` key.

- [ ] **Step 3: Run test to verify it fails**

Run: `flutter test test/api_contract_test.dart` (from `app/`)
Expected: FAIL — method doesn't exist.

- [ ] **Step 4: Add the repository methods**

`repositories.dart`, on `MasterDataRepository`:

```dart
  Future<List<SparePart>> sparePartDirectory({required String siteCode});

  Future<SparePart> createSparePart({required String siteCode, required String partNo, required String name});
```

`api_repositories.dart`: implement against `GET /sites/{siteCode}/spare-parts` and `POST /sites/{siteCode}/spare-parts`, mirroring `staffDirectory()`'s implementation shape exactly (same error handling, same base-URL construction).

`fake_repositories.dart`: an in-memory list per site, seeded from `test/support/seed.dart` if that file seeds other master lists (check first), with `createSparePart` appending and returning the new row.

- [ ] **Step 5: Remove the old `spares` field, add the multi-select section**

`registers.dart`: delete the `FieldDef(key: 'spares', ...)` entry from the `'work'` register's `fields` list.

`field_map.dart`: in the `'work'` map, replace `'spares': 'spare_parts_used',` with `'sparePartIds': 'spare_part_ids',`.

`register_form_screen.dart`: add a `_SparePartsSection` widget, structurally mirroring whichever attendee multi-select widget the merged branch added (`grep -n "_TicketLinkSection\|attendee" app/lib/screens/register_form_screen.dart` to find and copy its structure: typeahead search against `sparePartDirectory()`, chip-list of selected parts, an inline "Add '<text>' as new part" affordance calling `createSparePart` when the typed text matches nothing, writing the result into the form's `sparePartIds` field). Wire it into the Work Done form in the same place the old `spares` `FieldDef` used to render.

- [ ] **Step 6: Run tests**

Run: `flutter test` (from `app/`)
Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add app/lib/models/spare_part.dart app/lib/data/repositories.dart app/lib/data/api/api_repositories.dart app/lib/data/api/field_map.dart app/lib/data/registers.dart app/lib/screens/register_form_screen.dart app/test/support/fake_repositories.dart app/test/api_contract_test.dart app/test/registers_test.dart
git commit -m "Add spare parts catalogue multi-select to the Work Done form"
```

---

## Task 11: Driver master — model, migration, master API

**Files:**
- Modify: `backend/app/models/master.py`
- Create: `backend/alembic/versions/0033_drivers.py`
- Modify: `backend/app/schemas/site_masters.py`
- Modify: `backend/app/api/site_masters.py`
- Test: `backend/tests/test_site_masters.py`

**Interfaces:**
- Produces: `Driver{id, site_code, driver_code, name, is_active}`; `GET/POST /sites/{code}/drivers`; `POST /drivers/{id}/deactivate`.

Same pattern as Task 8 exactly — `Driver` instead of `SparePart`, `driver_code` instead of `part_no`. Do not re-derive the shape; copy Task 8's model/schema/router/test structure verbatim with the names swapped, in a single migration `0033_drivers.py` with `down_revision = "0032"`.

- [ ] **Step 1: Write the failing test** (mirrors Task 8 Step 1, `Driver`/`driver_code`/`/sites/{code}/drivers`)
- [ ] **Step 2: Run test to verify it fails**
- [ ] **Step 3: Add `Driver` to `app/models/master.py`** (mirrors Task 8 Step 3)
- [ ] **Step 4: Write the migration `0033_drivers.py`** (mirrors Task 8 Step 4, `down_revision = "0032"`)
- [ ] **Step 5: Add `DriverOut`/`DriverList`/`DriverCreate` to `app/schemas/site_masters.py`** (mirrors Task 8 Step 5)
- [ ] **Step 6: Add the driver endpoints to `app/api/site_masters.py`** (mirrors Task 8 Step 6, same file, new router functions below the spare-parts ones)
- [ ] **Step 7: Run migration and tests**

Run: `.venv/bin/python -m alembic upgrade head` then `.venv/bin/python -m pytest tests/test_site_masters.py -v` (from `backend/`)

- [ ] **Step 8: Commit**

```bash
git add backend/app/models/master.py backend/alembic/versions/0033_drivers.py backend/app/schemas/site_masters.py backend/app/api/site_masters.py backend/tests/test_site_masters.py
git commit -m "Add the site-scoped driver master"
```

---

## Task 12: Driver Complaint and Breakdown get a real `driver_id` FK (fixes a live bug)

**Files:**
- Modify: `backend/app/models/entry.py` (`DriverComplaintEntry`, `BreakdownEntry`)
- Create: `backend/alembic/versions/0034_driver_id_fk.py`
- Modify: `backend/app/services/masters.py`
- Modify: `backend/app/services/entries.py`
- Modify: `backend/app/schemas/entry.py`
- Test: `backend/tests/test_entries.py`

**Interfaces:**
- Consumes: `Driver` (Task 11).
- Produces: `resolve_driver(session, driver_code, *, site_code) -> Driver | None`; `DriverComplaintData.driver_id` / `BreakdownData.driver_id` now resolve against `drivers` and are actually persisted (currently `DriverComplaintEntry`'s `driver_id` is accepted by the schema but **never written** — `_build_detail`'s `Register.driver_complaint` branch doesn't set it at all; confirm this with `grep -n "driver_id" backend/app/services/entries.py` before starting — this task fixes that as part of adding the FK, it is not separate follow-up work).

- [ ] **Step 1: Write the failing tests**

```python
# backend/tests/test_entries.py (append)
async def test_driver_complaint_persists_driver_id(client, auth_headers, site, vehicle, driver) -> None:
    h = await auth_headers(client)
    created = (await client.post(
        "/entries",
        json={
            "register": "driver_complaint", "site": site.code, "entry_date": "2026-09-25",
            "data": {"bus_no": vehicle.registration_no, "complaint": "harsh braking", "driver_id": driver.driver_code},
        },
        headers=h,
    )).json()
    assert created["data"]["driver_id"] == driver.driver_code


async def test_breakdown_rejects_unknown_driver_id(client, auth_headers, site, vehicle) -> None:
    h = await auth_headers(client)
    r = await client.post(
        "/entries",
        json={
            "register": "breakdown", "site": site.code, "entry_date": "2026-09-25",
            "data": {"bus_no": vehicle.registration_no, "complaint": "AC failure", "reported_time": "09:00", "driver_id": "NOT-REAL"},
        },
        headers=h,
    )
    assert r.status_code == 400
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv/bin/python -m pytest tests/test_entries.py -k driver_id -v` (from `backend/`)
Expected: FAIL — `driver_id` currently round-trips as arbitrary free text (no validation), so `test_breakdown_rejects_unknown_driver_id` gets 201 instead of 400; and (separately, confirming the existing bug) `test_driver_complaint_persists_driver_id` gets `created["data"]["driver_id"] is None` even though it was submitted, since `_build_detail` drops it today.

- [ ] **Step 3: Change `driver_id` to an FK on both models — `app/models/entry.py`**

`DriverComplaintEntry`: `driver_id: Mapped[str | None] = mapped_column(String(64), nullable=True)` → `driver_id: Mapped[str | None] = mapped_column(String(32), ForeignKey("drivers.id", ondelete="SET NULL"), nullable=True)`, add `driver: Mapped["Driver | None"] = relationship(lazy="joined")`.

`BreakdownEntry`: same change to its own `driver_id` column.

- [ ] **Step 4: Write the migration `0034_driver_id_fk.py`**

```python
"""driver_complaint_entries.driver_id and breakdown_entries.driver_id
become FKs into the new drivers master, backfilling existing free text.

Revision ID: 0034
Revises: 0033
"""
from alembic import op
import sqlalchemy as sa

revision = "0034"
down_revision = "0033"
branch_labels = None
depends_on = None


def upgrade() -> None:
    for table in ("driver_complaint_entries", "breakdown_entries"):
        op.execute(
            f"""
            WITH src AS (
                SELECT DISTINCT t.driver_id AS text_value, e.site_code
                FROM {table} t
                JOIN entries e ON e.id = t.entry_id
                WHERE t.driver_id IS NOT NULL AND trim(t.driver_id) <> ''
            ),
            inserted AS (
                INSERT INTO drivers (id, site_code, driver_code, name, is_active)
                SELECT gen_random_uuid()::text, site_code,
                       'LEGACY-' || substr(md5(text_value), 1, 8), text_value, true
                FROM src
                RETURNING id, site_code, name
            )
            UPDATE {table} t
            SET driver_id = i.id
            FROM entries e, inserted i
            WHERE e.id = t.entry_id AND e.site_code = i.site_code AND t.driver_id = i.name
            """
        )
        op.alter_column(table, "driver_id", type_=sa.String(length=32), postgresql_using="driver_id::text")
        op.create_foreign_key(
            f"fk_{table}_driver_id_drivers", table, "drivers", ["driver_id"], ["id"], ondelete="SET NULL"
        )


def downgrade() -> None:
    for table in ("driver_complaint_entries", "breakdown_entries"):
        op.drop_constraint(f"fk_{table}_driver_id_drivers", table, type_="foreignkey")
        op.alter_column(table, "driver_id", type_=sa.String(length=64))
```

Note: this UPDATE's `t.driver_id = i.name` join only backfills rows where the migration's own inserted-driver `name` exactly matches the still-old-shaped `driver_id` text at that point in the transaction (it runs before the column's type changes) — verify this against a copy of real data shape before running in an environment with actual production-like free-text `driver_id` values, since the two-CTE self-referential update pattern is the same one already accepted for `spare_parts_used` in Task 9 but is worth a manual `SELECT` sanity check first (`SELECT driver_id FROM breakdown_entries WHERE driver_id IS NOT NULL LIMIT 20` before and after, comparing row counts of non-null values pre/post).

- [ ] **Step 5: Add `resolve_driver` to `app/services/masters.py`**

```python
async def resolve_driver(session: AsyncSession, driver_code: str | None, *, site_code: str) -> "Driver | None":
    if not driver_code:
        return None
    from app.models.master import Driver
    row = await session.scalar(
        select(Driver).where(
            func.lower(Driver.driver_code) == driver_code.strip().lower(), Driver.site_code == site_code
        )
    )
    if row is None:
        raise ValidationError(f"Unknown driver: {driver_code}", {"driver_id": "not in driver master"})
    return row
```

- [ ] **Step 6: Wire it into `_build_detail` — `app/services/entries.py`**

`Register.driver_complaint` branch: add `driver = await resolve_driver(session, data.driver_id, site_code=site_code)` before constructing the row, and add `driver_id=driver.id if driver else None,` to `DriverComplaintEntry(...)` — this is the fix for the bug confirmed in Step 2.

`Register.breakdown` branch: same — resolve, then `driver_id=driver.id if driver else None,` replacing the current `driver_id=data.driver_id,`.

Add `resolve_driver` to the `from app.services.masters import (...)` block.

- [ ] **Step 7: Update `serialize_data`**

Driver Complaint branch: add `"driver_id": d.driver.driver_code if d.driver else None,`.
Breakdown branch: change `"driver_id": d.driver_id,` to `"driver_id": d.driver.driver_code if d.driver else None,`.

- [ ] **Step 8: Run migration and tests**

Run: `.venv/bin/python -m alembic upgrade head` then `.venv/bin/python -m pytest tests/test_entries.py -v` (from `backend/`)
Expected: migration applies; both new tests PASS; every pre-existing breakdown test that posts a `driver_id` now needs a real, resolvable `driver_code` fixture — fix any that break by adding a `driver` fixture rather than loosening the new validation.

- [ ] **Step 9: Commit**

```bash
git add backend/app/models/entry.py backend/alembic/versions/0034_driver_id_fk.py backend/app/services/masters.py backend/app/services/entries.py backend/app/schemas/entry.py backend/tests/test_entries.py
git commit -m "Give driver_id a real FK on Driver Complaint and Breakdown (fixes silently-dropped Driver Complaint driver_id)"
```

---

## Task 13: Flutter — Driver picker

**Files:**
- Create: `app/lib/models/driver.dart`
- Modify: `app/lib/data/repositories.dart`
- Modify: `app/lib/data/api/api_repositories.dart`
- Modify: `app/lib/data/registers.dart`
- Modify: `app/lib/models/register.dart` (`MasterList` enum)
- Modify: `app/test/support/fake_repositories.dart`
- Test: `app/test/registers_test.dart`

**Interfaces:**
- Produces: `Driver{id, driverCode, name}`; `MasterDataRepository.drivers({required String siteCode}) -> List<String>` (driver codes — the existing name-based `FieldType.select` convention, matching `defectSources()`'s shape, not the id-carrying `staffDirectory()` shape, since `driver_id` resolves server-side by code the same way `defect_source` resolves by name); `MasterDataRepository.createDriver(...)`.

- [ ] **Step 1: Write `app/lib/models/driver.dart`** (same shape as Task 10 Step 1's `SparePart`, fields `id`/`driverCode`/`name`)

- [ ] **Step 2: Write the failing test**

Add a `registers_test.dart` (or `api_contract_test.dart`, whichever already tests the `defectSources()`-style pickers — check first) test asserting the `'breakdown'` and `'complaint'` registers' `driver` field is `FieldType.select` sourced from `MasterList.drivers`, and that submitting it posts the selected driver code under `driver_id`.

- [ ] **Step 3: Run test to verify it fails**

Run: `flutter test test/registers_test.dart` (from `app/`)
Expected: FAIL.

- [ ] **Step 4: Add `MasterList.drivers`**

In `app/lib/models/register.dart`'s `MasterList` enum, add `drivers`.

- [ ] **Step 5: Add the repository methods**

`repositories.dart`: `Future<List<String>> drivers({required String siteCode});` on `MasterDataRepository`, mirroring `defectSources()`. `api_repositories.dart`: `GET /sites/{siteCode}/drivers`, mapping each row to its `driver_code`. `fake_repositories.dart`: mirror the existing `defectSources()` fake.

Also add `createDriver` (mirrors `createSparePart` from Task 10) for the inline-add affordance, since a driver typeahead needs the same "not found — add it" path spare parts got.

- [ ] **Step 6: Convert the `driver` field**

`registers.dart`: in both the `'breakdown'` and `'complaint'` register defs (check whether `driver` exists on both or only `breakdown` today — the field_map showed `driver` only under `'breakdown'`; if Driver Complaint's form doesn't have a `driver` `FieldDef` at all yet despite the backend model having the column since the merged branch, add one, since the client's requirement is explicitly about Driver Complaint), change/add:

```dart
      FieldDef(
        key: 'driver',
        label: 'Driver',
        type: FieldType.select,
        optionsFrom: MasterList.drivers,
        master: true,
        width: FieldWidth.half,
      ),
```

`field_map.dart`: confirm/add `'complaint'` register's map gains `'driver': 'driver_id'` (breakdown's already has it).

- [ ] **Step 7: Run tests**

Run: `flutter test` (from `app/`)
Expected: all PASS.

- [ ] **Step 8: Commit**

```bash
git add app/lib/models/driver.dart app/lib/data/repositories.dart app/lib/data/api/api_repositories.dart app/lib/data/registers.dart app/lib/models/register.dart app/lib/data/api/field_map.dart app/test/support/fake_repositories.dart app/test/registers_test.dart
git commit -m "Add a driver picker to Breakdown and Driver Complaint"
```

---

## Task 14: Coolant Topping — day-based bulk entry (backend)

**Files:**
- Modify: `backend/app/schemas/entry.py`
- Modify: `backend/app/services/entries.py`
- Modify: `backend/app/api/entries.py`
- Test: `backend/tests/test_entries.py`

**Interfaces:**
- Consumes: `create_entry` (existing, called once per row inside a new wrapper).
- Produces: `CoolantDayRow{vehicle_id, bcs_litres, tcs_litres, topped_by}`; `CoolantDayCreate{entry_date, supervisor, rows: list[CoolantDayRow]}`; `POST /entries/coolant/day` → `{items: [EntryOut, ...]}`.

- [ ] **Step 1: Write the failing tests**

```python
# backend/tests/test_entries.py (append)
async def test_coolant_day_entry_creates_one_row_per_vehicle(client, auth_headers, site, vehicle, other_vehicle) -> None:
    h = await auth_headers(client)
    r = await client.post(
        "/entries/coolant/day",
        json={
            "site": site.code, "entry_date": "2026-09-25", "supervisor": "R. Mehta",
            "rows": [
                {"vehicle_id": vehicle.id, "bcs_litres": "1.5", "tcs_litres": "0.5", "topped_by": "A"},
                {"vehicle_id": other_vehicle.id, "bcs_litres": "2.0", "tcs_litres": None, "topped_by": "B"},
            ],
        },
        headers=h,
    )
    assert r.status_code == 201, r.text
    assert len(r.json()["items"]) == 2


async def test_coolant_day_entry_rolls_back_on_one_bad_vehicle(client, auth_headers, site, vehicle) -> None:
    h = await auth_headers(client)
    r = await client.post(
        "/entries/coolant/day",
        json={
            "site": site.code, "entry_date": "2026-09-25",
            "rows": [
                {"vehicle_id": vehicle.id, "bcs_litres": "1.5"},
                {"vehicle_id": "NOT-REAL", "bcs_litres": "2.0"},
            ],
        },
        headers=h,
    )
    assert r.status_code == 400
    listing = await client.get(
        "/entries", params={"site": site.code, "register": "coolant", "date_from": "2026-09-25", "date_to": "2026-09-25"}, headers=h
    )
    assert listing.json()["total"] == 0
```

Check whether `resolve_vehicle` takes a registration number or a vehicle id (Task 14's design uses `vehicle_id` for a bulk-entry row rather than `bus_no`/registration text, since the client already has a resolved vehicle list to render the per-row form from — confirm which of `Vehicle.id` vs `registration_no` this plan should key rows by, matching whatever `MasterDataRepository.vehicleNumbers()` already returns to the Flutter form in Task 15, and adjust both this test and Step 3 consistently if `bus_no` turns out to be the right key instead).

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv/bin/python -m pytest tests/test_entries.py -k coolant_day -v` (from `backend/`)
Expected: FAIL — 404 (route doesn't exist).

- [ ] **Step 3: Add schemas to `app/schemas/entry.py`**

```python
class CoolantDayRow(BaseModel):
    vehicle_id: str = Field(min_length=1, max_length=64)
    bcs_litres: Decimal | None = Field(default=None, ge=0, le=999999)
    tcs_litres: Decimal | None = Field(default=None, ge=0, le=999999)
    topped_by: OptText = None


class CoolantDayCreate(BaseModel):
    entry_date: date_t
    supervisor: OptText = None
    rows: list[CoolantDayRow] = Field(min_length=1, max_length=500)
```

- [ ] **Step 4: Add `create_coolant_day` to `app/services/entries.py`**

```python
async def create_coolant_day(
    session: AsyncSession, *, site_code: str, entry_date: date_t, supervisor: str | None,
    rows: list[CoolantDayRow], creator: User,
) -> list[Entry]:
    """One submit action, N per-bus Coolant rows sharing one date — a bad
    vehicle anywhere in the list fails the whole day's submission, same
    reasoning as the inspection batch: a partial day would misreport as
    "not yet topped" for buses that should have recorded but didn't."""
    out: list[Entry] = []
    for row in rows:
        vehicle = await session.get(Vehicle, row.vehicle_id)
        if vehicle is None or vehicle.site_code != site_code:
            raise ValidationError(f"Vehicle {row.vehicle_id} not found on this site", {"vehicle_id": "unknown vehicle"})
        entry = await create_entry(
            session, register=Register.coolant, site_code=site_code, entry_date=entry_date,
            entry_time=None, creator=creator,
            raw_data={
                "bus_no": vehicle.registration_no,
                "bcs_litres": str(row.bcs_litres) if row.bcs_litres is not None else None,
                "tcs_litres": str(row.tcs_litres) if row.tcs_litres is not None else None,
                "topped_by": row.topped_by,
                "supervisor": supervisor,
            },
        )
        out.append(entry)
    return out
```

Import `CoolantDayRow` for the type hint.

- [ ] **Step 5: Add the endpoint to `app/api/entries.py`**

```python
@router.post("/entries/coolant/day", response_model=EntryListOut, status_code=status.HTTP_201_CREATED)
async def create_coolant_day(
    payload: CoolantDayCreate, user: CurrentUser, session: SessionDep,
    site: Annotated[str, Query(min_length=1, max_length=50)],
) -> EntryListOut:
    site_code = assert_site_permission(user, site, "em_entry:write")
    entries = await svc.create_coolant_day(
        session, site_code=site_code, entry_date=payload.entry_date, supervisor=payload.supervisor,
        rows=payload.rows, creator=user,
    )
    await session.commit()
    for e in entries:
        await session.refresh(e)
    return EntryListOut(items=[_entry_out(e) for e in entries])
```

Check the actual existing single-entry-creation endpoint in this file for the exact response-shaping helper name (`_entry_out` is a guess — confirm from the existing `POST /entries` handler) and the exact response-list schema name (`EntryListOut` — confirm against `schemas/entry.py`; it may already be named differently, e.g. `EntryList`) before finalizing this. Match whatever those already are; do not introduce a second, differently-shaped list wrapper if one already exists.

- [ ] **Step 6: Run tests**

Run: `.venv/bin/python -m pytest tests/test_entries.py -v` (from `backend/`)
Expected: all PASS, including the rollback test (one `session.commit()` at the end of the endpoint is what makes this atomic — same mechanism as Task 6's inspection batch).

- [ ] **Step 7: Commit**

```bash
git add backend/app/schemas/entry.py backend/app/services/entries.py backend/app/api/entries.py backend/tests/test_entries.py
git commit -m "Add day-based bulk Coolant Topping entry"
```

---

## Task 15: Flutter — Coolant day-entry screen

**Files:**
- Modify: `app/lib/data/repositories.dart`
- Modify: `app/lib/data/api/api_repositories.dart`
- Modify: `app/test/support/fake_repositories.dart`
- Create: `app/lib/screens/coolant_day_screen.dart`
- Modify: `app/lib/router.dart`
- Test: `app/test/api_contract_test.dart`

**Interfaces:**
- Produces: `EntryRepository.createCoolantDay({required String site, required String entryDate, String? supervisor, required List<CoolantDayRow> rows}) -> List<RegisterEntry>`.

- [ ] **Step 1: Write the failing test**

Add a test to `api_contract_test.dart` asserting a 2-row submission posts one request to `/entries/coolant/day` with both rows in the body (not two separate `POST /entries` calls) and the fake returns 2 created entries.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/api_contract_test.dart` (from `app/`)
Expected: FAIL.

- [ ] **Step 3: Add the repository method**

`repositories.dart`, on `EntryRepository`: `Future<List<RegisterEntry>> createCoolantDay({required String site, required String entryDate, String? supervisor, required List<Map<String, dynamic>> rows});` (a small inline row shape is fine here — this doesn't need its own model class the way `SparePart`/`Driver` did, since it's write-only and never read back as a distinct type).

`api_repositories.dart`: `POST /entries/coolant/day?site=<site>`. `fake_repositories.dart`: loop `rows`, append one fake Coolant entry per row, matching however the fake's `createEntry` already builds one (reuse its internals rather than duplicating entry-construction logic).

- [ ] **Step 4: Build `coolant_day_screen.dart`**

One `DatePicker`, one `TextField` for the submitting supervisor, and a scrollable list/table with one row per active site vehicle (source the vehicle list the same way `register_form_screen.dart`'s bus picker already does — check `MasterDataRepository.vehicleNumbers()`'s usage there) showing inline BCS/TCS litre fields and a topped-by field, with a single submit button calling `createCoolantDay`. Register the route in `router.dart` alongside the other register-specific screens.

- [ ] **Step 5: Run tests**

Run: `flutter test` (from `app/`)
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add app/lib/data/repositories.dart app/lib/data/api/api_repositories.dart app/test/support/fake_repositories.dart app/lib/screens/coolant_day_screen.dart app/lib/router.dart app/test/api_contract_test.dart
git commit -m "Add the Coolant Topping day-entry screen"
```

---

## Task 16: Source of Defect — manual vs auto vs linked

**Files:**
- Modify: `backend/app/services/entries.py` (`serialize_data`, `apply_filters`)
- Modify: `backend/app/api/entries.py` (list endpoint query param)
- Test: `backend/tests/test_entries.py`

**Interfaces:**
- Produces: `serialize_data`'s Work Done branch gains `"entry_origin": "manual" | "linked" | "imported"`; `apply_filters(..., origin: str | None)`; `GET /entries?...&origin=manual|linked|imported`.

- [ ] **Step 1: Write the failing tests**

```python
# backend/tests/test_entries.py (append)
async def test_entry_origin_manual_by_default(client, auth_headers, site, vehicle) -> None:
    h = await auth_headers(client)
    created = (await client.post(
        "/entries",
        json={"register": "work_done", "site": site.code, "entry_date": "2026-09-25",
              "data": {"bus_no": vehicle.registration_no, "reported_defects": "noise"}},
        headers=h,
    )).json()
    assert created["data"]["entry_origin"] == "manual"


async def test_entry_origin_linked_when_ticket_set(client, auth_headers, site, vehicle, open_ticket) -> None:
    h = await auth_headers(client)
    created = (await client.post(
        "/entries",
        json={"register": "work_done", "site": site.code, "entry_date": "2026-09-25",
              "data": {"bus_no": vehicle.registration_no, "reported_defects": "noise", "ticket_id": open_ticket.id}},
        headers=h,
    )).json()
    assert created["data"]["entry_origin"] == "linked"


async def test_origin_filter_matches_only_imported(client, auth_headers, site, imported_work_done_entry, manual_work_done_entry) -> None:
    h = await auth_headers(client)
    r = await client.get("/entries", params={"site": site.code, "register": "work_done", "origin": "imported"}, headers=h)
    ids = {e["id"] for e in r.json()["items"]}
    assert imported_work_done_entry.id in ids
    assert manual_work_done_entry.id not in ids
```

Check `test_imports.py` for whatever fixture already produces an imported (non-null `source_fingerprint`) entry, and reuse it rather than hand-crafting one — an imported entry's shape is specific enough (it goes through the snag-sheet import path, not `POST /entries`) that this repo already has the right fixture somewhere in that file.

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv/bin/python -m pytest tests/test_entries.py -k entry_origin -v` (from `backend/`)
Expected: FAIL — `KeyError: 'entry_origin'`.

- [ ] **Step 3: Add `entry_origin` to `serialize_data`'s Work Done branch**

```python
            "entry_origin": (
                "imported" if entry.source_fingerprint is not None
                else "linked" if d.ticket_id is not None
                else "manual"
            ),
```

`serialize_data(entry)` already has `entry` in scope as the outer function parameter — confirm `entry.source_fingerprint` is the correct attribute name (per the backend audit's earlier finding, it's on `Entry`, not on the Work Done detail row) before writing this line.

- [ ] **Step 4: Add the `origin` filter**

`apply_filters` in `app/services/entries.py`:

```python
def apply_filters(
    stmt: Select, *, site_code: str, register: Register | None, date_from: date_t | None,
    date_to: date_t | None, q: str | None, status: EntryStatus | None,
    origin: str | None = None, has_open_ticket: bool | None = None,  # has_open_ticket added in Task 17
) -> Select:
    ...
    if origin is not None:
        if origin == "imported":
            stmt = stmt.where(Entry.source_fingerprint.is_not(None))
        elif origin == "manual":
            stmt = stmt.where(Entry.source_fingerprint.is_(None)).where(
                ~Entry.id.in_(select(WorkDoneEntry.entry_id).where(WorkDoneEntry.ticket_id.is_not(None)))
            )
        elif origin == "linked":
            stmt = stmt.where(
                Entry.id.in_(select(WorkDoneEntry.entry_id).where(WorkDoneEntry.ticket_id.is_not(None)))
            )
    return stmt
```

Add `origin: Annotated[str | None, Query()] = None` to the list endpoint's parameters in `app/api/entries.py` and thread it through to `apply_filters`.

- [ ] **Step 5: Run tests**

Run: `.venv/bin/python -m pytest tests/test_entries.py -v` (from `backend/`)
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add backend/app/services/entries.py backend/app/api/entries.py backend/tests/test_entries.py
git commit -m "Surface Source of Defect: manual vs linked vs imported"
```

---

## Task 17: Complete/Pending filter (backend)

**Files:**
- Modify: `backend/app/services/entries.py` (`apply_filters`)
- Modify: `backend/app/api/entries.py`
- Test: `backend/tests/test_entries.py`

**Interfaces:**
- Produces: `apply_filters(..., has_open_ticket: bool | None)` (param already stubbed into Task 16's signature — this task implements the body); `GET /entries?...&has_open_ticket=true|false`.

- [ ] **Step 1: Write the failing tests**

```python
# backend/tests/test_entries.py (append)
async def test_has_open_ticket_true_matches_only_open(client, auth_headers, site, open_ticket_entry, completed_ticket_entry, unticketed_entry) -> None:
    h = await auth_headers(client)
    r = await client.get("/entries", params={"site": site.code, "has_open_ticket": "true"}, headers=h)
    ids = {e["id"] for e in r.json()["items"]}
    assert open_ticket_entry.id in ids
    assert completed_ticket_entry.id not in ids
    assert unticketed_entry.id not in ids
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/python -m pytest tests/test_entries.py -k has_open_ticket -v` (from `backend/`)
Expected: FAIL — `has_open_ticket` param accepted (no-op) but filter not applied, so all three entries return.

- [ ] **Step 3: Implement the filter**

```python
    if has_open_ticket is not None:
        exists_open = select(Ticket.id).where(
            Ticket.source_entry_id == Entry.id, Ticket.status == TicketStatus.open
        ).exists()
        stmt = stmt.where(exists_open if has_open_ticket else ~exists_open)
```

Add this inside `apply_filters` (Task 16 already added the parameter to the signature — if Task 16 hasn't landed yet when this task runs, add the parameter here instead). Import `Ticket`, `TicketStatus` if not already imported in `entries.py` (they already are, per `services/tickets.py`'s imports being used elsewhere in this file).

Add `has_open_ticket: Annotated[bool | None, Query()] = None` to the list endpoint in `app/api/entries.py`, threaded through to `apply_filters`.

- [ ] **Step 4: Run tests**

Run: `.venv/bin/python -m pytest tests/test_entries.py -v` (from `backend/`)
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add backend/app/services/entries.py backend/app/api/entries.py backend/tests/test_entries.py
git commit -m "Add a has_open_ticket filter for the Complete/Pending list"
```

---

## Task 18: Traceability — `supervisor` on linked sessions

**Files:**
- Modify: `backend/app/services/entries.py` (`load_linked_sessions`)
- Test: `backend/tests/test_entries.py`

**Interfaces:**
- Produces: `load_linked_sessions`'s per-session dict gains `"supervisor": wd.supervisor`.

- [ ] **Step 1: Write the failing test**

```python
# backend/tests/test_entries.py (append)
async def test_linked_sessions_include_supervisor(client, auth_headers, site, vehicle, breakdown_with_session) -> None:
    h = await auth_headers(client)
    entry = breakdown_with_session
    body = (await client.get(f"/entries/{entry.id}", headers=h)).json()
    assert body["linked_sessions"][0]["supervisor"] is not None
```

Check `test_entries.py` for whatever fixture already builds a breakdown with a linked Work Done session (the merged branch's own tests almost certainly have one, given `linked_sessions` already has coverage per `backend/README.md`) and reuse its name rather than inventing `breakdown_with_session`.

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/python -m pytest tests/test_entries.py -k linked_sessions_include_supervisor -v` (from `backend/`)
Expected: FAIL — `KeyError: 'supervisor'`.

- [ ] **Step 3: Add the field**

In `load_linked_sessions`'s per-session dict construction, add `"supervisor": wd.supervisor,` alongside the existing `"completes_ticket": wd.completes_ticket,`.

- [ ] **Step 4: Run tests**

Run: `.venv/bin/python -m pytest tests/test_entries.py -v` (from `backend/`)
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add backend/app/services/entries.py backend/tests/test_entries.py
git commit -m "Include supervisor in a ticket's linked Work Done sessions"
```

---

## Task 19: Flutter — Complete/Pending filter and Pending list

**Files:**
- Modify: `app/lib/data/repositories.dart`
- Modify: `app/lib/data/api/api_repositories.dart`
- Modify: `app/test/support/fake_repositories.dart`
- Modify: `app/lib/screens/registers_screen.dart`
- Test: `app/test/entries_filter_test.dart`

**Interfaces:**
- Consumes: `has_open_ticket` (Task 17).
- Produces: `EntryRepository.fetchEntries(..., hasOpenTicket: bool?)` — extend the existing method's parameter list (check its exact current signature in `repositories.dart` before adding a parameter with a mismatched name).

- [ ] **Step 1: Write the failing test**

Add a test to `entries_filter_test.dart` (the merged branch already added this file for filter tests — follow its existing pattern) asserting `hasOpenTicket: true` adds `has_open_ticket=true` to the request/fake query.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/entries_filter_test.dart` (from `app/`)
Expected: FAIL.

- [ ] **Step 3: Thread the parameter through**

`repositories.dart`: add `bool? hasOpenTicket` to `EntryRepository.fetchEntries(...)`'s parameter list. `api_repositories.dart`: append `has_open_ticket` to the query string when non-null. `fake_repositories.dart`: filter the in-memory list the same way the fake already handles its other filter params.

- [ ] **Step 4: Add filter chips to `registers_screen.dart`**

Two chips, "Complete" / "Pending", each toggling `hasOpenTicket: false`/`true` on the existing filter state (find how the screen already wires its register/date filters into `fetchEntries` and follow the same state-management pattern — likely a Riverpod provider parameter, check `entries.dart`/`providers.dart`).

- [ ] **Step 5: Run tests**

Run: `flutter test` (from `app/`)
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add app/lib/data/repositories.dart app/lib/data/api/api_repositories.dart app/test/support/fake_repositories.dart app/lib/screens/registers_screen.dart app/test/entries_filter_test.dart
git commit -m "Add Complete/Pending filter chips to Registers"
```

---

## Task 20: Flutter — original-vs-completed session framing

**Files:**
- Modify: `app/lib/screens/breakdowns_screen.dart` (and any other screen rendering `linked_sessions` — grep for it first)
- Test: manual/visual (see Step 3) — no new automated test if this screen has none today; check first and add one if a widget-test harness already covers this screen.

**Interfaces:**
- Consumes: `supervisor` on each linked session (Task 18).

- [ ] **Step 1: Find every `linked_sessions` consumer**

Run: `grep -rn "linked_sessions\|linkedSessions" app/lib/` — confirm `breakdowns_screen.dart` is the only renderer before editing just that file.

- [ ] **Step 2: Render `supervisor`, and distinguish first vs completing session**

In whatever widget currently maps `linked_sessions` to a flat list (`grep -n "linked_sessions\|_LinkedSession" app/lib/screens/breakdowns_screen.dart` to find it exactly), add the supervisor line to each session's display, and give the first item in the list ("Originally logged") and whichever item has `completesTicket == true` ("Completed by") distinct labels/styling instead of uniform rows — the list is already ordered oldest-first per the backend's `order_by(Entry.entry_date, Entry.created_at)`, so the first element is always the original session.

- [ ] **Step 3: Verify in the running app**

Run the app (`flutter run -d chrome`, pointed at the local backend), open a breakdown with more than one linked Work Done session (create one via the app if none exists in seed data), and confirm the original/completed distinction renders correctly.

- [ ] **Step 4: Commit**

```bash
git add app/lib/screens/breakdowns_screen.dart
git commit -m "Distinguish original vs completing session in linked-sessions display"
```

---

## Task 21: Full regression + migration chain sanity

**Files:** none (verification only)

- [ ] **Step 1: Fresh migration chain**

Run (from `backend/`, against a throwaway database if this repo's `docker-compose.yml` supports spinning up a second Postgres, otherwise against the dev DB after confirming with the user it's disposable): `.venv/bin/python -m alembic downgrade base && .venv/bin/python -m alembic upgrade head`
Expected: every migration from `0001` through `0034` applies cleanly in sequence, confirming Tasks 1/8/9/11/12's four new revisions chain correctly off `0029` and each other.

- [ ] **Step 2: Full backend suite**

Run: `.venv/bin/python -m pytest -q` (from `backend/`)
Expected: every test passes — this plan's ~25 new tests plus the 354 pre-existing ones, zero regressions.

- [ ] **Step 3: Full Flutter suite**

Run: `flutter test` (from `app/`)
Expected: all pass.

- [ ] **Step 4: Fix anything red**

If either suite has failures, treat each as its own fix — do not batch-suppress or skip tests to get to green.

---

## Task 22: End-to-end behavioral pass

**Files:** none — this is manual verification in the running app, per the client's explicit ask for behavioral testing beyond unit coverage, propagating to reports.

- [ ] **Step 1: Start the stack**

`cd backend && docker compose up -d` (migrates + seeds), `cd app && flutter run -d chrome` pointed at the local API.

- [ ] **Step 2: Daily Inspection → Work Done → report**

Log in, record a Daily Inspection with at least one `not_ok` result. Confirm: the failure appears in the Registers Pending list (Task 19's filter); open the Work Done ticket picker and confirm the inspection's ticket appears with the right title; complete it via a Work Done session; confirm the inspection's `ticket_status` flips to `completed` (Task 5) when re-fetched; confirm the Daily Maintenance Report / bus history for that date reflects the work (check whatever report already reads Work Done data — `reports/dmr`, `reports/bus-history` — doesn't error and shows the new entry).

- [ ] **Step 3: Ticket carried across a shift change**

Create a Breakdown. Log a Work Done session against its ticket in shift A without marking it complete. Confirm it's still in the Pending list. Log a second session in shift B/next day marking it complete. Confirm the Breakdowns screen shows both sessions with the "Originally logged" / "Completed by" distinction (Task 20) and correct supervisors (Task 18).

- [ ] **Step 4: Coolant day entry**

Submit a day's Coolant Topping for every site vehicle in one action (Task 15). Confirm each bus's individual entry is visible and editable via Registers → Edit.

- [ ] **Step 5: Driver Complaint with a real driver**

Log a Driver Complaint against a driver selected from the new picker (Task 13). Confirm the driver's code appears on the entry, and that raising a ticket on it and completing it through Work Done works end to end (Task 3's driver_complaint register kept its existing raise-ticket path from the merged branch — this step confirms Task 12's FK change didn't break it).

- [ ] **Step 6: Report the outcome**

Summarize which of the five flows worked cleanly and which needed a follow-up fix, before calling the branch of work done.
