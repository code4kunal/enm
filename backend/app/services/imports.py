"""Spreadsheet import: preview, staging and commit.

`preview` is a dry run — every row mapped and validated, nothing written — and
`commit` applies exactly what was previewed rather than re-parsing, so what the
user approved is what lands.
"""
from __future__ import annotations

import hashlib
import json
import re
import secrets
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from datetime import date as date_t
from datetime import time as time_t
from decimal import Decimal, InvalidOperation

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import AppError, ValidationError
from app.models.checklist import InspectionEntry
from app.models.entry import Entry
from app.models.enums import EntryStatus, ImportTarget, Register, Shift
from app.models.master import DefectSource, DefectType, Vehicle, WorkType
from app.models.site_config import ServicePlan
from app.models.user import User
from app.schemas.site_import import ColumnMappingIO, RowErrorOut
from app.services import entries as entry_service
from app.services import odometer as odometer_service
from app.services.import_targets import (
    NUMERIC_WIRE_KEYS,
    REGISTER_FIELD_MAP,
    SNAG_TO_REGISTER,
    TIME_WIRE_KEYS,
    fields_for,
)
from app.services.masters import normalize_registration_no
from app.services.spreadsheet import SourceRow

#: A staged preview is short-lived by design: the file it describes is held in
#: memory and the fleet it validated against can move underneath it.
PREVIEW_TTL = timedelta(minutes=30)

TRUE_WORDS = {"y", "yes", "true", "t", "1", "active", "on"}
FALSE_WORDS = {"n", "no", "false", "f", "0", "inactive", "off", "retired"}


class Gone(AppError):
    code = "GONE"
    http_status = 410


@dataclass(slots=True)
class StagedPreview:
    token: str
    site_code: str
    target: ImportTarget
    file_name: str
    rows: list[dict[str, str]]
    row_numbers: list[int]
    errors: list[RowErrorOut]
    total_rows: int
    new_count: int
    update_count: int
    created_at: datetime
    created_by_id: str


class PreviewStore:
    """Process-local staging for previewed uploads.

    Single-process by design: the API runs one uvicorn worker per container and
    a preview is a 30-minute scratch artifact, not state worth a table. Move it
    to Redis before running more than one worker.
    """

    def __init__(self) -> None:
        self._items: dict[str, StagedPreview] = {}

    def put(self, staged: StagedPreview) -> None:
        self._sweep()
        self._items[staged.token] = staged

    def take(self, token: str, site_code: str) -> StagedPreview:
        self._sweep()
        staged = self._items.pop(token, None)
        if staged is None or staged.site_code != site_code:
            raise Gone(
                "That preview has expired — upload the file again",
                {"token": "expired or unknown"},
            )
        return staged

    def _sweep(self) -> None:
        cutoff = datetime.now(UTC) - PREVIEW_TTL
        for token in [t for t, s in self._items.items() if s.created_at < cutoff]:
            del self._items[token]


previews = PreviewStore()


# --- value coercion --------------------------------------------------------


@dataclass(slots=True)
class RowResult:
    values: dict[str, str] = field(default_factory=dict)
    errors: list[RowErrorOut] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.errors


def parse_bool(raw: str, default: bool = True) -> bool:
    text = raw.strip().lower()
    if not text:
        return default
    if text in TRUE_WORDS:
        return True
    if text in FALSE_WORDS:
        return False
    return default


def parse_int(raw: str) -> int | None:
    text = raw.strip().replace(",", "")
    if not text:
        return None
    try:
        return int(Decimal(text))
    except (InvalidOperation, ValueError):
        return None


def parse_decimal(raw: str) -> Decimal | None:
    text = raw.strip().replace(",", "")
    if not text:
        return None
    try:
        return Decimal(text)
    except InvalidOperation:
        return None


#: Excel-style patterns the mapping's `date_format` may use, mapped to strptime.
_DATE_TOKENS = [
    ("yyyy", "%Y"),
    ("yy", "%y"),
    ("MMMM", "%B"),
    ("MMM", "%b"),
    ("MM", "%m"),
    ("dd", "%d"),
    ("HH", "%H"),
    ("mm", "%M"),
    ("ss", "%S"),
]


def _to_strptime(pattern: str) -> str:
    out = pattern
    for token, code in _DATE_TOKENS:
        out = out.replace(token, code)
    return out


def parse_date(raw: str, date_format: str | None) -> date_t | None:
    text = raw.strip()
    if not text:
        return None
    if date_format:
        try:
            return datetime.strptime(text, _to_strptime(date_format)).date()
        except ValueError:
            return None
    # ISO first, then the two forms Indian depot sheets actually use.
    for fmt in ("%Y-%m-%d", "%d/%m/%Y", "%d-%m-%Y", "%Y/%m/%d"):
        try:
            return datetime.strptime(text[:10], fmt).date()
        except ValueError:
            continue
    return None


def parse_time(raw: str) -> time_t | None:
    text = raw.strip()
    if not text:
        return None
    for fmt in ("%H:%M", "%H:%M:%S", "%I:%M %p", "%I:%M%p"):
        try:
            return datetime.strptime(text, fmt).time().replace(second=0)
        except ValueError:
            continue
    return None


# --- mapping ---------------------------------------------------------------


def apply_mappings(
    row: SourceRow, mappings: list[ColumnMappingIO]
) -> dict[str, str]:
    """Read one source row into target-field terms."""
    out: dict[str, str] = {}
    for mapping in mappings:
        if mapping.constant_value and mapping.constant_value.strip():
            out[mapping.target_key] = mapping.constant_value.strip()
        elif mapping.source_column.strip():
            out[mapping.target_key] = row.get(mapping.source_column).strip()
    return out


def _date_format_for(mappings: list[ColumnMappingIO], key: str) -> str | None:
    for mapping in mappings:
        if mapping.target_key == key:
            return mapping.date_format
    return None


# --- validation ------------------------------------------------------------


def _validate_row(
    *,
    target: ImportTarget,
    site_code: str,
    row_number: int,
    values: dict[str, str],
    mappings: list[ColumnMappingIO],
    fleet: dict[str, Vehicle],
    sources: dict[str, str],
    types: dict[str, str],
    work_types: dict[str, WorkType] | None = None,
) -> RowResult:
    result = RowResult(values=dict(values))

    for spec in fields_for(target):
        if spec.required and not values.get(spec.key, "").strip():
            result.errors.append(
                RowErrorOut(
                    row_number=row_number,
                    field=spec.label,
                    message="Required value is blank",
                )
            )

    if not result.ok:
        return result

    register = target.register
    is_snag = target is ImportTarget.snag_report

    if is_snag:
        # The row's own TYPE OF WORK decides which register it lands in, so an
        # unknown or unrouted code is fatal for that row — never a silent drop.
        code = normalize_work_type(result.values.get("work_type", ""))
        result.values["work_type"] = code
        work_type = (work_types or {}).get(code)
        if work_type is None:
            result.errors.append(
                RowErrorOut(
                    row_number=row_number,
                    field="Type of Work",
                    message=f'"{code}" is not on the work-type master list',
                )
            )
        elif work_type.register is None and not work_type.is_inspection:
            result.errors.append(
                RowErrorOut(
                    row_number=row_number,
                    field="Type of Work",
                    message=f'"{code}" is not routed to a register yet',
                )
            )

    # Registration numbers are normalised before any comparison.
    reg_key = "bus" if (register is not None or is_snag) else "registration_no"
    if reg_key in result.values:
        reg = normalize_registration_no(result.values[reg_key])
        result.values[reg_key] = reg
        if reg in NOT_A_VEHICLE:
            result.errors.append(
                RowErrorOut(
                    row_number=row_number,
                    field="Registration No",
                    message=f'"{reg}" is not a registration number',
                )
            )
            return result
        # A register, service or odometer row must name a vehicle that is
        # already on this site's fleet.
        needs_fleet = (
            target is ImportTarget.odometers or register is not None or is_snag
        )
        if needs_fleet and reg not in fleet:
            result.errors.append(
                RowErrorOut(
                    row_number=row_number,
                    field="Registration No",
                    message=f"{reg} is not on the {site_code} fleet",
                )
            )

    # A dropdown value not on its master list is rejected. Imports never
    # auto-create master rows.
    for key, allowed, label in (
        ("source", sources, "Source of Defect"),
        ("defectType", types, "Type of Defect"),
    ):
        value = collapse(result.values.get(key, ""))
        if not value:
            result.values[key] = ""
            continue
        canonical = allowed.get(master_key(value))
        if canonical is None:
            result.errors.append(
                RowErrorOut(
                    row_number=row_number,
                    field=label,
                    message=f'"{value}" is not on the {label} master list',
                )
            )
            continue
        # Store the master's own spelling, not the sheet's.
        result.values[key] = canonical

    # Dates
    if register is not None or is_snag:
        raw = result.values.get("date", "")
        fmt = _date_format_for(mappings, "date")
        if parse_date(raw, fmt) is None:
            result.errors.append(
                RowErrorOut(
                    row_number=row_number,
                    field="Date",
                    message=f"Could not read \"{raw}\" as a date"
                    + (f' — expected {fmt}' if fmt else " — expected yyyy-MM-dd"),
                )
            )

    if target is ImportTarget.odometers:
        if parse_int(result.values.get("odometer_km", "")) is None:
            result.errors.append(
                RowErrorOut(
                    row_number=row_number,
                    field="Odometer",
                    message="Expected a whole number of kilometres",
                )
            )
        raw = result.values.get("recorded_at", "")
        if raw and parse_date(raw, _date_format_for(mappings, "recorded_at")) is None:
            result.errors.append(
                RowErrorOut(
                    row_number=row_number,
                    field="Reading taken on",
                    message="Expected yyyy-MM-dd",
                )
            )

    if target is ImportTarget.service_schedule and not result.values.get(
        "code", ""
    ).strip():
        result.errors.append(
            RowErrorOut(
                row_number=row_number,
                field="Service code",
                message="Required value is blank",
            )
        )

    return result


async def _fleet(session: AsyncSession, site_code: str) -> dict[str, Vehicle]:
    rows = await session.scalars(
        select(Vehicle).where(Vehicle.site_code == site_code)
    )
    return {v.registration_no: v for v in rows}


def normalize_work_type(raw: str) -> str:
    """A comparable form of a TYPE OF WORK code.

    Codes are written by hand and the same job appears as `P.M` and `PM`, so
    punctuation and spacing are dropped for matching: `B.D` and `BD` are one
    code, `10 DAYS SERVICE` and `10 Days Service` are one code. The master
    list keeps whichever spelling the depot prefers for display.
    """
    return re.sub(r"[^A-Z0-9]", "", raw.upper())


def collapse(raw: str) -> str:
    """Collapse the line breaks a sheet author wraps long values with."""
    return " ".join(raw.split())


def master_key(raw: str) -> str:
    """A comparable form of a master-list value.

    "TRANSMISSION/\nDRIVER SYSTEM" is the same entry as
    "TRANSMISSION/DRIVER SYSTEM": where the column was narrow, and whether
    anyone typed a space after the slash, is not a difference in meaning. The
    master's own spelling is what gets stored.
    """
    return re.sub(r"[^A-Z0-9]", "", raw.upper())


#: Registration placeholders that are not vehicles.
NOT_A_VEHICLE = {"N/A", "NA", "NIL", "NONE", "-"}


async def _work_types(session: AsyncSession) -> dict[str, WorkType]:
    rows = await session.scalars(select(WorkType).where(WorkType.is_active.is_(True)))
    return {normalize_work_type(w.code): w for w in rows}


async def _master_names(
    session: AsyncSession,
) -> tuple[dict[str, str], dict[str, str]]:
    """Comparable key -> the master's own spelling, per list."""
    sources = {
        master_key(n): n
        for n in (await session.scalars(select(DefectSource.name))).all()
    }
    types = {
        master_key(n): n
        for n in (await session.scalars(select(DefectType.name))).all()
    }
    return sources, types


async def build_preview(
    session: AsyncSession,
    *,
    site_code: str,
    target: ImportTarget,
    file_name: str,
    rows: list[SourceRow],
    mappings: list[ColumnMappingIO],
    actor: User,
) -> StagedPreview:
    fleet = await _fleet(session, site_code)
    sources, types = await _master_names(session)
    work_types = (
        await _work_types(session)
        if target is ImportTarget.snag_report
        else {}
    )

    accepted: list[dict[str, str]] = []
    numbers: list[int] = []
    errors: list[RowErrorOut] = []
    new_count = 0
    update_count = 0

    existing_keys = await _existing_keys(session, site_code, target, fleet)

    for row in rows:
        values = apply_mappings(row, mappings)
        result = _validate_row(
            target=target,
            site_code=site_code,
            row_number=row.number,
            values=values,
            mappings=mappings,
            fleet=fleet,
            sources=sources,
            types=types,
            work_types=work_types,
        )
        if not result.ok:
            errors.extend(result.errors)
            continue
        accepted.append(result.values)
        numbers.append(row.number)
        key = _natural_key(target, result.values)
        if key is not None and key in existing_keys:
            update_count += 1
        else:
            new_count += 1
            if key is not None:
                existing_keys.add(key)

    staged = StagedPreview(
        token=secrets.token_urlsafe(24),
        site_code=site_code,
        target=target,
        file_name=file_name,
        rows=accepted,
        row_numbers=numbers,
        errors=errors,
        total_rows=len(rows),
        new_count=new_count,
        update_count=update_count,
        created_at=datetime.now(UTC),
        created_by_id=actor.id,
    )
    previews.put(staged)
    return staged


def _natural_key(target: ImportTarget, values: dict[str, str]) -> str | None:
    """What makes a re-run an update rather than a duplicate.

    Register targets have none — a historical backfill has no stable key.
    """
    if target is ImportTarget.vehicles:
        return values.get("registration_no", "")
    if target in (ImportTarget.defect_sources, ImportTarget.defect_types):
        return values.get("name", "").strip().lower()
    if target is ImportTarget.service_schedule:
        return values.get("code", "").strip().upper()
    if target is ImportTarget.odometers:
        return values.get("registration_no", "")
    return None


async def _existing_keys(
    session: AsyncSession,
    site_code: str,
    target: ImportTarget,
    fleet: dict[str, Vehicle],
) -> set[str]:
    if target in (ImportTarget.vehicles, ImportTarget.odometers):
        return set(fleet)
    if target is ImportTarget.defect_sources:
        return {
            n.lower() for n in (await session.scalars(select(DefectSource.name))).all()
        }
    if target is ImportTarget.defect_types:
        return {
            n.lower() for n in (await session.scalars(select(DefectType.name))).all()
        }
    if target is ImportTarget.service_schedule:
        return {
            c.upper()
            for c in (
                await session.scalars(
                    select(ServicePlan.code).where(ServicePlan.site_code == site_code)
                )
            ).all()
        }
    return set()


# --- commit ----------------------------------------------------------------


async def commit(
    session: AsyncSession,
    staged: StagedPreview,
    actor: User,
    run_id: str | None = None,
) -> tuple[int, int, int]:
    """Apply exactly what was previewed. Returns (accepted, unchanged, rejected).

    `run_id` is stamped on every row written, so a month can be traced back to
    the upload it came from — and so re-running one is visibly a no-op rather
    than silently doing nothing.
    """
    target = staged.target
    site_code = staged.site_code

    unchanged = 0
    if target is ImportTarget.vehicles:
        await _commit_vehicles(session, site_code, staged.rows)
    elif target in (ImportTarget.defect_sources, ImportTarget.defect_types):
        await _commit_master(session, target, staged.rows)
    elif target is ImportTarget.service_schedule:
        await _commit_service_plans(session, site_code, staged.rows)
    elif target is ImportTarget.odometers:
        await _commit_odometers(session, site_code, staged.rows)
    elif target is ImportTarget.snag_report:
        unchanged = await _commit_snag_report(
            session, site_code, staged.rows, actor, run_id=run_id
        )
    else:
        unchanged = await _commit_register(
            session, site_code, staged, actor, run_id=run_id
        )

    rejected = len({e.row_number for e in staged.errors})
    return len(staged.rows), unchanged, rejected


async def _commit_vehicles(
    session: AsyncSession, site_code: str, rows: list[dict[str, str]]
) -> None:
    """Upsert by registration number — a re-run must not double the fleet."""
    fleet = await _fleet(session, site_code)
    for values in rows:
        reg = values["registration_no"]
        vehicle = fleet.get(reg)
        if vehicle is None:
            vehicle = Vehicle(registration_no=reg, site_code=site_code)
            session.add(vehicle)
            fleet[reg] = vehicle
        if "make" in values:
            vehicle.make = values["make"][:64]
        if "model" in values:
            vehicle.model = values["model"][:64]
        if "battery_capacity_kwh" in values:
            vehicle.battery_capacity_kwh = parse_decimal(
                values["battery_capacity_kwh"]
            )
        if "is_active" in values:
            vehicle.is_active = parse_bool(values["is_active"])
    await session.flush()


async def _commit_master(
    session: AsyncSession, target: ImportTarget, rows: list[dict[str, str]]
) -> None:
    model = (
        DefectSource if target is ImportTarget.defect_sources else DefectType
    )
    for values in rows:
        name = values["name"].strip()
        row = await session.scalar(
            select(model).where(func.lower(model.name) == name.lower())
        )
        if row is None:
            row = model(name=name)
            session.add(row)
        else:
            row.name = name
        if "sort_order" in values:
            order = parse_int(values["sort_order"])
            if order is not None:
                row.sort_order = order
        if "is_active" in values:
            row.is_active = parse_bool(values["is_active"])
        await session.flush()


async def _commit_service_plans(
    session: AsyncSession, site_code: str, rows: list[dict[str, str]]
) -> None:
    for values in rows:
        code = values["code"].strip().upper()
        plan = await session.scalar(
            select(ServicePlan).where(
                ServicePlan.site_code == site_code, ServicePlan.code == code
            )
        )
        if plan is None:
            plan = ServicePlan(site_code=site_code, code=code, name=code)
            session.add(plan)
        if values.get("name", "").strip():
            plan.name = values["name"].strip()[:120]
        for key, attr in (("interval_km", "interval_km"), ("interval_days", "interval_days")):
            if key in values:
                parsed = parse_int(values[key])
                if parsed is not None:
                    setattr(plan, attr, max(parsed, 0))
        if "notes" in values:
            plan.notes = values["notes"]
        if "is_active" in values:
            plan.is_active = parse_bool(values["is_active"])
        await session.flush()


async def _commit_odometers(
    session: AsyncSession, site_code: str, rows: list[dict[str, str]]
) -> None:
    """A lower figure is a stale sheet, not a correction — skip it silently."""
    fleet = await _fleet(session, site_code)
    for values in rows:
        vehicle = fleet.get(values["registration_no"])
        if vehicle is None:
            continue
        reading = parse_int(values.get("odometer_km", ""))
        if reading is None:
            continue
        if vehicle.odometer_updated_at is not None and reading < vehicle.odometer_km:
            continue
        recorded_on = parse_date(values.get("recorded_at", ""), None)
        recorded_at = (
            datetime.combine(recorded_on, time_t(0, 0), tzinfo=UTC)
            if recorded_on
            else datetime.now(UTC)
        )
        odometer_service.record_reading(
            session,
            vehicle,
            odometer_km=reading,
            recorded_at=recorded_at,
            source="import",
        )
    await session.flush()


async def _commit_register(
    session: AsyncSession,
    site_code: str,
    staged: StagedPreview,
    actor: User,
    run_id: str | None = None,
) -> int:
    register = staged.target.register
    assert register is not None
    field_map = REGISTER_FIELD_MAP[register]

    # A register sheet re-imports as readily as a snag report does, and used to
    # duplicate just the same.
    marks = {
        id(values): fingerprint(site_code, staged.target.value, values)
        for values in staged.rows
    }
    already = await _seen_fingerprints(session, site_code, set(marks.values()))

    unchanged = 0
    for values in staged.rows:
        mark = marks[id(values)]
        if mark in already:
            unchanged += 1
            continue
        entry_date = parse_date(values.get("date", ""), None)
        if entry_date is None:
            continue

        data: dict[str, object] = {}
        for app_key, wire_key in field_map.items():
            raw = values.get(app_key, "").strip()
            if not raw:
                continue
            if wire_key in NUMERIC_WIRE_KEYS:
                number = parse_decimal(raw)
                if number is not None:
                    data[wire_key] = number
                continue
            if wire_key in TIME_WIRE_KEYS:
                parsed = parse_time(raw)
                if parsed is not None:
                    data[wire_key] = parsed.strftime("%H:%M")
                continue
            if wire_key == "shift":
                upper = raw.upper()[:1]
                if upper in {s.value for s in Shift}:
                    data[wire_key] = upper
                continue
            data[wire_key] = raw

        entry = await entry_service.create_entry(
            session,
            register=register,
            site_code=site_code,
            entry_date=entry_date,
            entry_time=None,
            raw_data=data,
            creator=actor,
        )
        entry.source_fingerprint = mark
        entry.import_run_id = run_id
        already.add(mark)
        # A 2024 breakdown must not light up today's open-breakdown banner.
        if register is Register.breakdown:
            entry.status = EntryStatus.resolved
            if entry.breakdown is not None:
                entry.breakdown.resolved_at = datetime.now(UTC)
        await session.flush()

    return unchanged


def fingerprint(site_code: str, target: str, values: dict[str, str]) -> str:
    """A stable name for one row of one sheet.

    Re-running a month has to recognise what it already wrote, and a sheet row
    carries no id of its own — so the row's own content is the identity. Keys
    are sorted and values whitespace-collapsed, so a re-export that reorders
    columns or re-wraps a cell still hashes the same.

    Deliberately not the business key (bus + date + register): two genuinely
    different complaints against one bus on one day are two rows, and collapsing
    them would lose one.
    """
    normalised = {
        key: " ".join(str(value).split())
        for key, value in sorted(values.items())
        if str(value).strip()
    }
    payload = json.dumps(
        {"site": site_code, "target": target, "row": normalised},
        sort_keys=True,
        ensure_ascii=False,
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


async def _seen_fingerprints(
    session: AsyncSession, site_code: str, marks: set[str]
) -> set[str]:
    """Which of these rows this site already holds."""
    if not marks:
        return set()
    rows = await session.scalars(
        select(Entry.source_fingerprint).where(
            Entry.site_code == site_code,
            Entry.source_fingerprint.in_(marks),
        )
    )
    return {mark for mark in rows.all() if mark}


async def _commit_snag_report(
    session: AsyncSession,
    site_code: str,
    rows: list[dict[str, str]],
    actor: User,
    run_id: str | None = None,
) -> int:
    """One sheet, five registers. Returns how many rows were already held.

    Each row's TYPE OF WORK names a work type, and the work type says which
    register the row belongs in — so the routing is whatever the master list
    currently says, not a table baked into this file. The KMS column is a real
    odometer sighting and is recorded as one on the way past.
    """
    work_types = await _work_types(session)
    fleet = await _fleet(session, site_code)

    # Everything this sheet would write, checked against what the site already
    # has, in one query rather than one per row.
    marks = {
        id(values): fingerprint(site_code, "snagReport", values) for values in rows
    }
    already = await _seen_fingerprints(session, site_code, set(marks.values()))

    unchanged = 0
    for values in rows:
        mark = marks[id(values)]
        if mark in already:
            # A previous run wrote this exact row. Re-importing a month must
            # leave the figures where they are.
            unchanged += 1
            continue
        work_type = work_types.get(values.get("work_type", ""))
        if work_type is None:
            continue

        entry_date = parse_date(values.get("date", ""), None)
        if entry_date is None:
            continue

        vehicle_for_row = fleet.get(values.get("bus", ""))
        if work_type.is_inspection:
            # A checklist sweep, not a register entry. The sheet records that
            # it happened but never which lines were checked, so the results
            # are empty — enough for the scheduler to see the work was done.
            if vehicle_for_row is not None:
                await _commit_inspection_row(
                    session,
                    site_code=site_code,
                    vehicle=vehicle_for_row,
                    work_type=work_type,
                    values=values,
                    inspected_on=entry_date,
                    actor=actor,
                )
            continue

        if work_type.register is None:
            continue
        register = work_type.register

        translated = {
            register_key: values[snag_key]
            for snag_key, register_key in SNAG_TO_REGISTER[register].items()
            if values.get(snag_key, "").strip()
        }
        data = _to_register_data(register, translated)
        if not data:
            continue

        entry = await entry_service.create_entry(
            session,
            register=register,
            site_code=site_code,
            entry_date=entry_date,
            entry_time=parse_time(values.get("t_bd", "")),
            raw_data=data,
            creator=actor,
            work_type_id=work_type.id,
        )
        entry.source_fingerprint = mark
        entry.import_run_id = run_id
        # Two identical rows in one sheet hash alike; the first wins and the
        # second would otherwise violate the index on flush.
        already.add(mark)

        # "CLOSE" on the sheet means the job is finished. Only the breakdown
        # register has an open/resolved lifecycle to reflect it in.
        if register is Register.breakdown:
            closed = values.get("status", "").strip().upper().startswith("CLOSE")
            entry.status = EntryStatus.resolved if closed else EntryStatus.open
            if closed and entry.breakdown is not None:
                entry.breakdown.resolved_at = datetime.now(UTC)

        # The sheet's KMS column is an odometer reading taken that day.
        vehicle = vehicle_for_row
        reading = parse_int(values.get("odometer_km", ""))
        fresh = vehicle is not None and reading is not None and (
            vehicle.odometer_updated_at is None or reading >= vehicle.odometer_km
        )
        if fresh:
            odometer_service.record_reading(
                    session,
                    vehicle,
                    odometer_km=reading,
                    recorded_at=datetime.combine(entry_date, time_t(0, 0), tzinfo=UTC),
                    source="snag report",
                )
        await session.flush()

    return unchanged

async def _commit_inspection_row(
    session: AsyncSession,
    *,
    site_code: str,
    vehicle: Vehicle,
    work_type: WorkType,
    values: dict[str, str],
    inspected_on: date_t,
    actor: User,
) -> None:
    """One historical inspection from the snag report, with no checklist."""
    existing = await session.scalar(
        select(InspectionEntry.id).where(
            InspectionEntry.site_code == site_code,
            InspectionEntry.vehicle_id == vehicle.id,
            InspectionEntry.work_type_id == work_type.id,
            InspectionEntry.inspected_on == inspected_on,
        )
    )
    if existing:
        return

    reading = parse_int(values.get("odometer_km", ""))
    session.add(
        InspectionEntry(
            site_code=site_code,
            vehicle_id=vehicle.id,
            work_type_id=work_type.id,
            inspected_on=inspected_on,
            entry_time=parse_time(values.get("t_bd", "")),
            done_by=values.get("employee") or None,
            supervisor=values.get("supervisor") or None,
            odometer_km=reading,
            remarks=values.get("action") or values.get("complaint") or None,
            created_by=actor,
        )
    )
    if reading is not None and (
        vehicle.odometer_updated_at is None or reading >= vehicle.odometer_km
    ):
        odometer_service.record_reading(
            session,
            vehicle,
            odometer_km=reading,
            recorded_at=datetime.combine(inspected_on, time_t(0, 0), tzinfo=UTC),
            source="snag report",
        )
    await session.flush()


def _to_register_data(register: Register, values: dict[str, str]) -> dict[str, object]:
    """Turn register-keyed values into the API `data` payload."""
    field_map = REGISTER_FIELD_MAP[register]
    data: dict[str, object] = {}
    for app_key, wire_key in field_map.items():
        raw = values.get(app_key, "").strip()
        if not raw:
            continue
        if wire_key in NUMERIC_WIRE_KEYS:
            number = parse_decimal(raw)
            if number is not None:
                data[wire_key] = number
            continue
        if wire_key in TIME_WIRE_KEYS:
            parsed = parse_time(raw)
            if parsed is not None:
                data[wire_key] = parsed.strftime("%H:%M")
            continue
        if wire_key == "shift":
            upper = raw.upper()[:1]
            if upper in {sh.value for sh in Shift}:
                data[wire_key] = upper
            continue
        data[wire_key] = raw
    return data


def require_mappings(
    target: ImportTarget, mappings: list[ColumnMappingIO]
) -> None:
    bound = {
        m.target_key
        for m in mappings
        if m.source_column.strip() or (m.constant_value or "").strip()
    }
    missing = [f.label for f in fields_for(target) if f.required and f.key not in bound]
    if missing:
        raise ValidationError(
            f"Map every required field first: {', '.join(missing)}",
            {"mappings": "required fields unmapped"},
        )
