from __future__ import annotations

from datetime import UTC, datetime
from datetime import date as date_t
from datetime import time as time_t
from decimal import Decimal
from typing import Any
from zoneinfo import ZoneInfo

from pydantic import ValidationError as PydanticValidationError
from sqlalchemy import Select, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.errors import ValidationError
from app.models.entry import (
    BreakdownEntry,
    CoolantEntry,
    DriverComplaintEntry,
    Entry,
    PMScheduleEntry,
    WorkDoneEntry,
)
from app.models.enums import EntryStatus, Register
from app.models.master import Vehicle
from app.models.user import User
from app.schemas.entry import REGISTER_DATA_SCHEMAS
from app.services.masters import (
    resolve_defect_source,
    resolve_defect_type,
    resolve_vehicle,
)

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


async def _build_detail(
    session: AsyncSession, register: Register, data: Any
) -> tuple[Any, list[Any]]:
    """Return (detail_row, searchable_values) for the register subtype table."""
    if register is Register.work_done:
        src = await resolve_defect_source(session, data.defect_source)
        typ = await resolve_defect_type(session, data.defect_type)
        row = WorkDoneEntry(
            shift=data.shift,
            reported_defects=data.reported_defects,
            defect_source=src,
            defect_type=typ,
            attended_details=data.attended_details,
            spare_parts_used=data.spare_parts_used,
            employee=data.employee,
            supervisor=data.supervisor,
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
        row = BreakdownEntry(
            driver_id=data.driver_id,
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
            data.driver_id,
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
    await session.flush()
    return entry


async def update_entry(
    session: AsyncSession,
    entry: Entry,
    *,
    entry_date: date_t | None,
    entry_time: time_t | None,
    raw_data: dict[str, Any],
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
    if old_detail is not None:
        await session.delete(old_detail)
        await session.flush()
        setattr(entry, entry.register.value, None)

    detail, searchable = await _build_detail(session, entry.register, data)
    setattr(entry, entry.register.value, detail)
    entry.search_text = _search_text(entry, vehicle, entry.created_by, searchable)
    entry.updated_at = datetime.now(UTC)

    await session.flush()
    return entry


# --- read path -------------------------------------------------------------


def _num(value: Decimal | None) -> float | None:
    return None if value is None else float(value)


def _hhmm(value: time_t | None) -> str | None:
    return None if value is None else value.strftime("%H:%M")


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
            "employee": d.employee,
            "supervisor": d.supervisor,
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
            "driver_id": d.driver_id,
            "location": d.location,
            "complaint": d.complaint,
            "breakdown_time": _hhmm(d.breakdown_time),
            "mechanic_reported_time": _hhmm(d.mechanic_reported_time),
            "attended_time": _hhmm(d.attended_time),
            "loss_km": _num(d.loss_km),
            "attended_details": d.attended_details,
            "remarks": d.remarks,
            "supervisor": d.supervisor,
            "resolved_at": (
                d.resolved_at.isoformat() if d.resolved_at else None
            ),
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


#: The person each register names as having done the work. The register is a
#: record of what a mechanic did, so that name — not the account that typed it
#: in — is who the entry belongs to.
REPORTER_COLUMN = {
    Register.work_done: "employee",
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
    skip = {"bus_no", "resolved_at"}
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
