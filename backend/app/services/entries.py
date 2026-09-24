from __future__ import annotations

from datetime import UTC, datetime
from datetime import date as date_t
from datetime import time as time_t
from decimal import Decimal
from typing import Any
from zoneinfo import ZoneInfo

from pydantic import ValidationError as PydanticValidationError
from sqlalchemy import Select, func, or_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm.attributes import set_committed_value

from app.config import settings
from app.errors import Conflict, ValidationError
from app.models.entry import (
    BreakdownEntry,
    CoolantEntry,
    DriverComplaintEntry,
    Entry,
    PMScheduleEntry,
    WorkDoneAttendee,
    WorkDoneEntry,
)
from app.models.enums import EntryStatus, Register, TicketStatus
from app.models.ticket import Ticket
from app.models.master import Vehicle
from app.models.user import User
from app.schemas.entry import REGISTER_DATA_SCHEMAS
from app.services.masters import (
    resolve_defect_source,
    resolve_defect_type,
    resolve_vehicle,
)
from app.services.tickets import complete_ticket, mark_attended

IST = ZoneInfo(settings.timezone)


def _now_ist() -> datetime:
    """Entry times are site wall-clock, not UTC."""
    return datetime.now(IST)


# --- validation ------------------------------------------------------------


#: Retired: inspections hold this now, with their own checklist and their own
#: form. The enum value stays so historical rows still read, but nothing new
#: may be written to it.
RETIRED_REGISTERS = frozenset({Register.pm_schedule})


def validate_data(register: Register, raw: dict[str, Any]) -> Any:
    """Validate the register-specific `data` payload, surfacing a `fields` map."""
    if register in RETIRED_REGISTERS:
        raise ValidationError(
            "PM Schedule Attention has been replaced by Inspections — record "
            "it against the inspection's own checklist instead.",
            {"register": "retired"},
        )
    schema = REGISTER_DATA_SCHEMAS[register]
    if not isinstance(raw, dict):
        raise ValidationError("data must be an object", {"data": "expected object"})
    try:
        return schema.model_validate(raw)
    except PydanticValidationError as exc:
        fields: dict[str, str] = {}
        for err in exc.errors():
            key = ".".join(str(p) for p in err["loc"]) or "data"
            msg = err.get("msg", "invalid")
            if err["type"] in {"missing", "string_too_short"}:
                msg = "required"
            fields.setdefault(key, msg)
        first = next(iter(fields.items()))
        raise ValidationError(f"{first[0]}: {first[1]}", fields) from exc


# --- search haystack -------------------------------------------------------


def _search_text(
    entry: Entry, vehicle: Vehicle, creator: User, parts: list[Any]
) -> str:
    chunks = [
        vehicle.registration_no,
        entry.register.value,
        creator.name,
        creator.user_id,
    ]
    chunks += [str(p) for p in parts if p not in (None, "")]
    return " ".join(chunks).lower()


# --- write path ------------------------------------------------------------


async def _resolve_ticket(
    session: AsyncSession, ticket_id: str | None, *, existing_ticket_id: str | None = None
) -> Ticket | None:
    if not ticket_id:
        return None
    ticket = await session.get(Ticket, ticket_id)
    if ticket is None:
        raise ValidationError("ticket_id: not found", {"ticket_id": "not found"})
    # A completed ticket can't be newly attached to — but an edit that
    # resubmits an entry's own already-completed ticket unchanged (the
    # GET-then-PUT-the-whole-form-back contract) isn't a new attachment.
    if ticket.status is TicketStatus.completed and ticket_id != existing_ticket_id:
        raise Conflict("This ticket is already completed")
    return ticket


async def _resolve_attendees(session: AsyncSession, user_ids: list[str]) -> list[User]:
    if not user_ids:
        return []
    users = (
        await session.scalars(select(User).where(User.id.in_(user_ids)))
    ).all()
    by_id = {u.id: u for u in users}
    missing = [uid for uid in user_ids if uid not in by_id]
    if missing:
        raise ValidationError(
            f"attendee_user_ids: unknown user {missing[0]}",
            {"attendee_user_ids": "unknown user"},
        )
    # `IN (...)` gives no ordering guarantee — rebuild in submission order
    # (deduped, first occurrence wins) since `reporter_name` treats the first
    # attendee as the primary one.
    seen: set[str] = set()
    ordered: list[User] = []
    for uid in user_ids:
        if uid not in seen:
            seen.add(uid)
            ordered.append(by_id[uid])
    return ordered


async def _set_attendees(
    session: AsyncSession, entry_id: str, detail: WorkDoneEntry, user_ids: list[str]
) -> None:
    """Set a flushed `WorkDoneEntry`'s attendees.

    `detail.attendees = [...]` would make the ORM fetch the *old* collection
    first (it's a persistent row once flushed) — a lazy load that raises
    `MissingGreenlet` outside an awaited call. Add the rows directly instead,
    and seed the in-memory collection with `set_committed_value` so the same
    request's response can read `detail.attendees` without triggering one.
    """
    users = await _resolve_attendees(session, user_ids)
    rows = [
        WorkDoneAttendee(work_done_entry_id=entry_id, user_id=u.id, user=u)
        for u in users
    ]
    session.add_all(rows)
    set_committed_value(detail, "attendees", rows)


async def _build_detail(
    session: AsyncSession,
    register: Register,
    data: Any,
    *,
    existing_ticket_id: str | None = None,
) -> tuple[Any, list[Any]]:
    """Return (detail_row, searchable_values) for the register subtype table."""
    if register is Register.work_done:
        src = await resolve_defect_source(session, data.defect_source)
        typ = await resolve_defect_type(session, data.defect_type)
        ticket = await _resolve_ticket(
            session, data.ticket_id, existing_ticket_id=existing_ticket_id
        )
        await _resolve_attendees(session, data.attendee_user_ids)  # validate only
        row = WorkDoneEntry(
            shift=data.shift,
            reported_defects=data.reported_defects,
            defect_source=src,
            defect_type=typ,
            attended_details=data.attended_details,
            spare_parts_used=data.spare_parts_used,
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
            data.shift.value if data.shift else None,
        ]

    if register is Register.coolant:
        row = CoolantEntry(
            bcs_litres=data.bcs_litres,
            tcs_litres=data.tcs_litres,
            topped_by=data.topped_by,
            supervisor=data.supervisor,
        )
        return row, [data.topped_by, data.supervisor]

    if register is Register.driver_complaint:
        typ = await resolve_defect_type(session, data.defect_type)
        row = DriverComplaintEntry(
            defect_type=typ,
            complaint=data.complaint,
            rectification_action=data.rectification_action,
            mechanic=data.mechanic,
            supervisor=data.supervisor,
        )
        return row, [
            data.complaint,
            data.defect_type,
            data.rectification_action,
            data.mechanic,
        ]

    if register is Register.breakdown:
        typ = await resolve_defect_type(session, data.defect_type)
        row = BreakdownEntry(
            defect_type=typ,
            driver_id=data.driver_id,
            route=data.route,
            location=data.location,
            complaint=data.complaint,
            breakdown_time=data.breakdown_time,
            mechanic_reported_time=data.mechanic_reported_time,
            attended_time=data.attended_time,
            loss_km=data.loss_km,
            attended_details=data.attended_details,
            remarks=data.remarks,
            supervisor=data.supervisor,
        )
        return row, [
            data.complaint,
            data.defect_type,
            data.driver_id,
            data.route,
            data.location,
            data.attended_details,
            data.remarks,
        ]

    typ = await resolve_defect_type(session, data.defect_type)
    row = PMScheduleEntry(
        defect_type=typ,
        defects_noticed=data.defects_noticed,
        action_taken=data.action_taken,
        balance_job_reason=data.balance_job_reason,
        spare_parts_used=data.spare_parts_used,
        employees=data.employees,
        supervisor=data.supervisor,
    )
    return row, [
        data.defects_noticed,
        data.defect_type,
        data.action_taken,
        data.balance_job_reason,
        data.spare_parts_used,
        data.employees,
    ]


async def _apply_ticket_side_effects(
    session: AsyncSession, entry: Entry, detail: Any, actor: User
) -> None:
    if entry.register is not Register.work_done or detail.ticket_id is None:
        return
    ticket = await session.get(Ticket, detail.ticket_id)
    now = _now_ist()
    mark_attended(ticket, now)
    if detail.completes_ticket and ticket.status is not TicketStatus.completed:
        completed_at = (
            datetime.combine(entry.entry_date, detail.completion_time, tzinfo=IST)
            if detail.completion_time
            else now
        )
        await complete_ticket(session, ticket=ticket, completed_by=actor, completed_at=completed_at)


async def _flush_catching_shift_conflict(session: AsyncSession) -> None:
    """Flush, mapping the `work_done_shift_uniqueness` trigger's raise to a 409.

    A plain check-then-insert in Python would race under two devices
    submitting the same ticket/shift concurrently, so the constraint lives
    in a DB trigger (migration 0028) instead. Postgres reports it as a
    `unique_violation` (23505), which asyncpg/SQLAlchemy surface here as an
    `IntegrityError` wrapping the trigger's own message.
    """
    try:
        await session.flush()
    except IntegrityError as exc:
        if "work_done_shift_uniqueness" in str(exc.orig):
            raise Conflict(
                "This ticket already has a Work Done session for this date and shift"
            ) from exc
        raise


async def create_entry(
    session: AsyncSession,
    *,
    register: Register,
    site_code: str,
    entry_date: date_t,
    entry_time: time_t | None,
    raw_data: dict[str, Any],
    creator: User,
    work_type_id: int | None = None,
) -> Entry:
    data = validate_data(register, raw_data)
    vehicle = await resolve_vehicle(
        session, registration_no=data.bus_no, site_code=site_code
    )

    entry = Entry(
        register=register,
        site_code=site_code,
        vehicle=vehicle,
        entry_date=entry_date,
        entry_time=entry_time or _now_ist().time().replace(microsecond=0),
        status=(
            EntryStatus.open if register is Register.breakdown else EntryStatus.done
        ),
        created_by=creator,
        # What kind of job this was. The scheduler reads it to see that a
        # booked inspection actually happened.
        work_type_id=work_type_id,
    )
    detail, searchable = await _build_detail(session, register, data)
    setattr(entry, register.value, detail)
    entry.search_text = _search_text(entry, vehicle, creator, searchable)

    session.add(entry)
    await _flush_catching_shift_conflict(session)
    if register is Register.work_done:
        await _set_attendees(session, entry.id, detail, data.attendee_user_ids)
        await session.flush()
    await _apply_ticket_side_effects(session, entry, detail, creator)
    return entry


async def update_entry(
    session: AsyncSession,
    entry: Entry,
    *,
    entry_date: date_t | None,
    entry_time: time_t | None,
    raw_data: dict[str, Any],
    actor: User,
) -> Entry:
    """Replace the register payload wholesale (the UI submits the full form)."""
    data = validate_data(entry.register, raw_data)
    vehicle = await resolve_vehicle(
        session, registration_no=data.bus_no, site_code=entry.site_code
    )

    if entry_date is not None:
        entry.entry_date = entry_date
    if entry_time is not None:
        entry.entry_time = entry_time
    entry.vehicle = vehicle

    old_detail = entry.detail
    old_ticket_id = getattr(old_detail, "ticket_id", None)
    if old_detail is not None:
        await session.delete(old_detail)
        await session.flush()
        setattr(entry, entry.register.value, None)

    detail, searchable = await _build_detail(
        session, entry.register, data, existing_ticket_id=old_ticket_id
    )
    setattr(entry, entry.register.value, detail)
    entry.search_text = _search_text(entry, vehicle, entry.created_by, searchable)
    entry.updated_at = datetime.now(UTC)

    await _flush_catching_shift_conflict(session)
    if entry.register is Register.work_done:
        await _set_attendees(session, entry.id, detail, data.attendee_user_ids)
        await session.flush()
    await _apply_ticket_side_effects(session, entry, detail, actor)
    return entry


# --- read path -------------------------------------------------------------


def _num(value: Decimal | None) -> float | None:
    return None if value is None else float(value)


def _hhmm(value: time_t | None) -> str | None:
    return None if value is None else value.strftime("%H:%M")


def _ist_iso(value: datetime | None) -> str | None:
    if value is None:
        return None
    return value.astimezone(IST).isoformat(timespec="seconds")


def serialize_data(entry: Entry) -> dict[str, Any]:
    """Rebuild the register-specific `data` object the UI posted."""
    bus_no = entry.vehicle.registration_no
    d = entry.detail
    if d is None:  # defensive: orphaned header
        return {"bus_no": bus_no}

    if entry.register is Register.work_done:
        return {
            "shift": d.shift.value if d.shift else None,
            "bus_no": bus_no,
            "reported_defects": d.reported_defects,
            "defect_source": d.defect_source.name if d.defect_source else None,
            "defect_type": d.defect_type.name if d.defect_type else None,
            "attended_details": d.attended_details,
            "spare_parts_used": d.spare_parts_used,
            "supervisor": d.supervisor,
            "ticket_id": d.ticket_id,
            "completes_ticket": d.completes_ticket,
            "completion_time": _hhmm(d.completion_time),
            "attendees": [
                {"user_id": a.user_id, "name": a.user.name} for a in d.attendees
            ],
        }
    if entry.register is Register.coolant:
        return {
            "bus_no": bus_no,
            "bcs_litres": _num(d.bcs_litres),
            "tcs_litres": _num(d.tcs_litres),
            "topped_by": d.topped_by,
            "supervisor": d.supervisor,
        }
    if entry.register is Register.driver_complaint:
        return {
            "bus_no": bus_no,
            "defect_type": d.defect_type.name if d.defect_type else None,
            "complaint": d.complaint,
            "rectification_action": d.rectification_action,
            "mechanic": d.mechanic,
            "supervisor": d.supervisor,
        }
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
    return {
        "bus_no": bus_no,
        "defect_type": d.defect_type.name if d.defect_type else None,
        "defects_noticed": d.defects_noticed,
        "action_taken": d.action_taken,
        "balance_job_reason": d.balance_job_reason,
        "spare_parts_used": d.spare_parts_used,
        "employees": d.employees,
        "supervisor": d.supervisor,
    }


def audit_snapshot(
    entry: Entry, *, extra: dict[str, Any] | None = None
) -> dict[str, Any]:
    """Audit after/before payload — always names register, site, date, bus.

    `serialize_data` alone is the form fields; without register the trail cannot
    tell a breakdown from a complaint.
    """
    out: dict[str, Any] = {
        "register": entry.register.value,
        "site": entry.site_code,
        "date": entry.entry_date.isoformat(),
        "status": entry.status.value,
        **serialize_data(entry),
    }
    if extra:
        out.update(extra)
    return out


#: The person each register names as having done the work. The register is a
#: record of what a mechanic did, so that name — not the account that typed it
#: in — is who the entry belongs to.
REPORTER_COLUMN = {
    Register.coolant: "topped_by",
    Register.driver_complaint: "mechanic",
    Register.breakdown: "attended_details",
    Register.pm_schedule: "employees",
}


def reporter_name(entry: Entry) -> str:
    """Who the entry is attributed to.

    Falls back to the account that recorded it, which is the honest answer when
    the register itself names nobody.
    """
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


def serialize_entry(entry: Entry) -> dict[str, Any]:
    return {
        "id": entry.id,
        "entered_by": reporter_name(entry),
        "register": entry.register,
        "site": entry.site_code,
        "date": entry.entry_date,
        "entry_time": entry.entry_time,
        "created_by": {
            "id": entry.created_by.id,
            "name": entry.created_by.name,
            "user_id": entry.created_by.user_id,
        },
        "created_at": entry.created_at,
        "updated_at": entry.updated_at,
        "status": entry.status,
        "photo_url": entry.photo_url,
        "data": serialize_data(entry),
    }


DETAIL_COLUMNS = {
    Register.work_done: ("reported_defects", "attended_details"),
    Register.coolant: ("topped_by",),
    Register.driver_complaint: ("complaint", "rectification_action"),
    Register.breakdown: ("complaint", "attended_details"),
    Register.pm_schedule: ("defects_noticed", "action_taken"),
}


def csv_details(entry: Entry) -> str:
    """Flatten the register payload into one human-readable CSV cell."""
    data = serialize_data(entry)
    skip = {"bus_no"}
    parts = [
        f"{k.replace('_', ' ').title()}: {v}"
        for k, v in data.items()
        if k not in skip and v not in (None, "")
    ]
    return " | ".join(parts)


def resolve_period(
    period: str | None, date_from: date_t | None, date_to: date_t | None, today: date_t
) -> tuple[date_t | None, date_t | None]:
    """Explicit date_from/date_to always win over the `period` convenience param."""
    if date_from or date_to:
        return date_from, date_to
    if period == "today":
        return today, today
    if period == "last7":
        return today.fromordinal(today.toordinal() - 6), today
    if period == "month":
        return today.replace(day=1), today
    return None, None


def apply_filters(
    stmt: Select,
    *,
    site_code: str,
    register: Register | None,
    date_from: date_t | None,
    date_to: date_t | None,
    q: str | None,
    status: EntryStatus | None,
) -> Select:
    stmt = stmt.where(Entry.site_code == site_code)
    if register is not None:
        stmt = stmt.where(Entry.register == register)
    if date_from is not None:
        stmt = stmt.where(Entry.entry_date >= date_from)
    if date_to is not None:
        stmt = stmt.where(Entry.entry_date <= date_to)
    if status is not None:
        stmt = stmt.where(
            Entry.register == Register.breakdown, Entry.status == status
        )
    if q:
        needle = f"%{q.strip().lower()}%"
        stmt = stmt.where(
            or_(Entry.search_text.like(needle), Entry.id == q.strip())
        )
    return stmt


async def count_entries(session: AsyncSession, stmt: Select) -> int:
    subq = stmt.with_only_columns(Entry.id).order_by(None).subquery()
    return int(await session.scalar(select(func.count()).select_from(subq)) or 0)
