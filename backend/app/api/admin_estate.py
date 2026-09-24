"""Super-admin estate endpoints: summary dashboard and audit trail."""

from __future__ import annotations

import csv
import io
import json
from datetime import UTC, datetime, time
from datetime import date as date_t
from typing import Annotated, Any, Literal
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Query
from fastapi.responses import Response
from sqlalchemy import select
from sqlalchemy.orm import selectinload

from app.config import settings
from app.deps import SessionDep, SuperAdminUser
from app.errors import Forbidden
from app.models.audit import AuditLog
from app.models.checklist import InspectionEntry
from app.models.entry import Entry
from app.models.user import User
from app.schemas.admin_estate import (
    AdminSummaryOut,
    AuditLogList,
    AuditLogOut,
    EstateTotals,
    SegmentOut,
    SegmentTotals,
    SiteSummaryOut,
)
from app.services import admin_summary, audit

router = APIRouter(prefix="/admin", tags=["admin"])

PeriodMode = Literal["today", "week", "month", "custom"]
IST = ZoneInfo(settings.timezone)

REGISTER_LABELS = {
    "work_done": "Work Done",
    "coolant": "Coolant",
    "driver_complaint": "Driver Complaint",
    "breakdown": "Breakdown",
    "pm_schedule": "PM Schedule",
}


def _parse_day(raw: str | None) -> date_t | None:
    if not raw:
        return None
    return date_t.fromisoformat(raw)


def _day_bounds_ist(day: date_t, *, end: bool) -> datetime:
    """UTC-aware instant at start (or end) of an IST calendar day."""
    wall = time(23, 59, 59, 999999) if end else time(0, 0, 0)
    local = datetime.combine(day, wall, tzinfo=IST)
    return local.astimezone(UTC)


@router.get("/summary", response_model=AdminSummaryOut)
async def estate_summary(
    _user: SuperAdminUser,
    session: SessionDep,
    period: Annotated[PeriodMode, Query()] = "month",
    date_from: Annotated[str | None, Query()] = None,
    date_to: Annotated[str | None, Query()] = None,
    month: Annotated[str | None, Query()] = None,
) -> AdminSummaryOut:
    """Site-wise incident counts for the Admin Summary and project reports."""
    start, end = admin_summary.resolve_period(
        period,
        date_from=_parse_day(date_from),
        date_to=_parse_day(date_to),
        month=month,
    )
    raw = await admin_summary.build_summary(session, date_from=start, date_to=end)
    await session.commit()

    def _site(s: dict) -> SiteSummaryOut:
        return SiteSummaryOut(**s)

    segments = {
        key: SegmentOut(
            label=seg["label"],
            totals=SegmentTotals(**seg["totals"]),
            sites=[_site(s) for s in seg["sites"]],
        )
        for key, seg in raw["segments"].items()
    }
    return AdminSummaryOut(
        date_from=raw["date_from"],
        date_to=raw["date_to"],
        estate=EstateTotals(**raw["estate"]),
        sites=[_site(s) for s in raw["sites"]],
        segments=segments,
    )


def _subject_from_after(object_type: str, after: dict[str, Any] | None) -> str | None:
    if not after:
        return None
    if object_type == "entry":
        register = after.get("register")
        label = REGISTER_LABELS.get(str(register), str(register) if register else "Entry")
        bus = after.get("bus_no") or ""
        site = after.get("site") or ""
        day = after.get("date") or ""
        parts = [p for p in (label, bus, site, day) if p]
        return " · ".join(parts) if parts else None
    if object_type == "inspection":
        code = after.get("work_type") or after.get("work_type_name") or "Inspection"
        bus = after.get("bus_no") or after.get("vehicle") or ""
        site = after.get("site") or ""
        day = after.get("inspected_on") or ""
        km = after.get("milestone_km")
        km_s = f"{km // 1000}k" if isinstance(km, int) and km >= 1000 else (
            str(km) if km is not None else ""
        )
        parts = [p for p in (str(code), bus, site, day, km_s) if p]
        return " · ".join(parts) if parts else None
    if object_type == "fitted_unit":
        unit = after.get("unit") or "Unit"
        bus = after.get("vehicle") or ""
        return " · ".join(p for p in (f"Fitted {unit}", bus) if p)
    return None


def _audit_out(
    row: AuditLog,
    actors: dict[str, User],
    *,
    entry_by_id: dict[str, Entry] | None = None,
    inspection_by_id: dict[str, InspectionEntry] | None = None,
) -> AuditLogOut:
    actor = actors.get(row.actor_id) if row.actor_id else None
    before = json.loads(row.before) if row.before else None
    after = json.loads(row.after) if row.after else None
    if not isinstance(before, dict):
        before = None
    if not isinstance(after, dict):
        after = None

    register: str | None = None
    site_code: str | None = None
    bus_no: str | None = None
    subject: str | None = None

    if after:
        register = after.get("register") if isinstance(after.get("register"), str) else None
        site_code = after.get("site") if isinstance(after.get("site"), str) else None
        bus_no = after.get("bus_no") or after.get("vehicle")
        if isinstance(bus_no, str) and not bus_no:
            bus_no = None
        subject = _subject_from_after(row.object_type, after)

    # Hydrate older rows that only stored form fields (no register/site).
    if row.object_type == "entry" and entry_by_id:
        entry = entry_by_id.get(row.object_id)
        if entry is not None:
            register = register or entry.register.value
            site_code = site_code or entry.site_code
            bus_no = bus_no or (
                entry.vehicle.registration_no if entry.vehicle else None
            )
            if not subject:
                label = REGISTER_LABELS.get(entry.register.value, entry.register.value)
                subject = " · ".join(
                    p
                    for p in (
                        label,
                        bus_no or "",
                        entry.site_code,
                        entry.entry_date.isoformat(),
                    )
                    if p
                )
            # Merge into after so CSV/export also carries register.
            after = {
                **(after or {}),
                "register": register,
                "site": site_code,
                "date": entry.entry_date.isoformat(),
                "bus_no": bus_no,
                "status": entry.status.value,
            }

    if row.object_type == "inspection" and inspection_by_id:
        insp = inspection_by_id.get(row.object_id)
        if insp is not None:
            site_code = site_code or insp.site_code
            bus_no = bus_no or (
                insp.vehicle.registration_no if insp.vehicle else None
            )
            code = insp.work_type.code if insp.work_type else "Inspection"
            if not subject:
                subject = " · ".join(
                    p
                    for p in (
                        code,
                        bus_no or "",
                        insp.site_code,
                        insp.inspected_on.isoformat(),
                    )
                    if p
                )
            after = {
                **(after or {}),
                "site": site_code,
                "bus_no": bus_no,
                "vehicle": bus_no,
                "work_type": code,
                "inspected_on": insp.inspected_on.isoformat(),
                "milestone_km": insp.milestone_km,
            }

    return AuditLogOut(
        id=row.id,
        actor_id=row.actor_id,
        actor_user_id=actor.user_id if actor else None,
        actor_name=actor.name if actor else None,
        action=row.action,
        object_type=row.object_type,
        object_id=row.object_id,
        before=before,
        after=after,
        created_at=row.created_at,
        subject=subject,
        register=register,
        site_code=site_code,
        bus_no=bus_no,
    )


async def _load_actors(session: SessionDep, rows: list[AuditLog]) -> dict[str, User]:
    ids = {r.actor_id for r in rows if r.actor_id}
    if not ids:
        return {}
    users = (await session.scalars(select(User).where(User.id.in_(ids)))).all()
    return {u.id: u for u in users}


async def _load_entries(
    session: SessionDep, rows: list[AuditLog]
) -> dict[str, Entry]:
    ids = {r.object_id for r in rows if r.object_type == "entry"}
    if not ids:
        return {}
    found = (
        await session.scalars(
            select(Entry)
            .where(Entry.id.in_(ids))
            .options(selectinload(Entry.vehicle))
        )
    ).all()
    return {e.id: e for e in found}


async def _load_inspections(
    session: SessionDep, rows: list[AuditLog]
) -> dict[str, InspectionEntry]:
    ids = {r.object_id for r in rows if r.object_type == "inspection"}
    if not ids:
        return {}
    found = (
        await session.scalars(
            select(InspectionEntry)
            .where(InspectionEntry.id.in_(ids))
            .options(
                selectinload(InspectionEntry.vehicle),
                selectinload(InspectionEntry.work_type),
            )
        )
    ).all()
    return {i.id: i for i in found}


@router.get("/audit", response_model=AuditLogList)
async def list_audit(
    user: SuperAdminUser,
    session: SessionDep,
    page: Annotated[int, Query(ge=1)] = 1,
    page_size: Annotated[int, Query(ge=1, le=200)] = 50,
    actor_id: Annotated[str | None, Query()] = None,
    action: Annotated[str | None, Query()] = None,
    object_type: Annotated[str | None, Query()] = None,
    date_from: Annotated[str | None, Query()] = None,
    date_to: Annotated[str | None, Query()] = None,
) -> AuditLogList:
    """User-wise audit trail — every recorded action, newest first."""
    if not user.has_permission("em_audit:read"):
        raise Forbidden("Missing permission: em_audit:read")

    start = _parse_day(date_from)
    end = _parse_day(date_to)
    rows, total = await audit.list_logs(
        session,
        actor_id=actor_id,
        action=action,
        object_type=object_type,
        date_from=_day_bounds_ist(start, end=False) if start else None,
        date_to=_day_bounds_ist(end, end=True) if end else None,
        offset=(page - 1) * page_size,
        limit=page_size,
    )
    actors = await _load_actors(session, rows)
    entries = await _load_entries(session, rows)
    inspections = await _load_inspections(session, rows)
    await session.commit()
    return AuditLogList(
        items=[
            _audit_out(r, actors, entry_by_id=entries, inspection_by_id=inspections)
            for r in rows
        ],
        page=page,
        page_size=page_size,
        total=total,
    )


@router.get("/audit/export")
async def export_audit(
    user: SuperAdminUser,
    session: SessionDep,
    actor_id: Annotated[str | None, Query()] = None,
    action: Annotated[str | None, Query()] = None,
    object_type: Annotated[str | None, Query()] = None,
    date_from: Annotated[str | None, Query()] = None,
    date_to: Annotated[str | None, Query()] = None,
) -> Response:
    """CSV of the filtered audit trail (capped)."""
    if not user.has_permission("em_audit:read"):
        raise Forbidden("Missing permission: em_audit:read")

    start = _parse_day(date_from)
    end = _parse_day(date_to)
    rows, _ = await audit.list_logs(
        session,
        actor_id=actor_id,
        action=action,
        object_type=object_type,
        date_from=_day_bounds_ist(start, end=False) if start else None,
        date_to=_day_bounds_ist(end, end=True) if end else None,
        offset=0,
        limit=5_000,
    )
    actors = await _load_actors(session, rows)
    entries = await _load_entries(session, rows)
    inspections = await _load_inspections(session, rows)
    await session.commit()

    buf = io.StringIO()
    writer = csv.writer(buf)
    writer.writerow(
        [
            "created_at",
            "actor_user_id",
            "actor_name",
            "action",
            "subject",
            "register",
            "site_code",
            "bus_no",
            "object_type",
            "object_id",
            "after",
        ]
    )
    for r in rows:
        out = _audit_out(
            r, actors, entry_by_id=entries, inspection_by_id=inspections
        )
        created = out.created_at
        created_s = (
            created.isoformat() if isinstance(created, datetime) else str(created)
        )
        writer.writerow(
            [
                created_s,
                out.actor_user_id or "",
                out.actor_name or "",
                out.action,
                out.subject or "",
                out.register or "",
                out.site_code or "",
                out.bus_no or "",
                out.object_type,
                out.object_id,
                json.dumps(out.after or {}, default=str),
            ]
        )

    return Response(
        content=buf.getvalue(),
        media_type="text/csv",
        headers={
            "Content-Disposition": 'attachment; filename="enm-audit.csv"',
        },
    )
