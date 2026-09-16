"""Super-admin estate endpoints: summary dashboard and audit trail."""

from __future__ import annotations

import csv
import io
import json
from datetime import UTC, datetime, time
from datetime import date as date_t
from typing import Annotated, Literal
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Query
from fastapi.responses import Response
from sqlalchemy import select

from app.config import settings
from app.deps import SessionDep, SuperAdminUser
from app.errors import Forbidden
from app.models.audit import AuditLog
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


def _audit_out(row: AuditLog, actors: dict[str, User]) -> AuditLogOut:
    actor = actors.get(row.actor_id) if row.actor_id else None
    before = json.loads(row.before) if row.before else None
    after = json.loads(row.after) if row.after else None
    return AuditLogOut(
        id=row.id,
        actor_id=row.actor_id,
        actor_user_id=actor.user_id if actor else None,
        actor_name=actor.name if actor else None,
        action=row.action,
        object_type=row.object_type,
        object_id=row.object_id,
        before=before if isinstance(before, dict) else None,
        after=after if isinstance(after, dict) else None,
        created_at=row.created_at,
    )


async def _load_actors(session: SessionDep, rows: list[AuditLog]) -> dict[str, User]:
    ids = {r.actor_id for r in rows if r.actor_id}
    if not ids:
        return {}
    users = (await session.scalars(select(User).where(User.id.in_(ids)))).all()
    return {u.id: u for u in users}


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
    await session.commit()
    return AuditLogList(
        items=[_audit_out(r, actors) for r in rows],
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
    await session.commit()

    buf = io.StringIO()
    writer = csv.writer(buf)
    writer.writerow(
        [
            "created_at",
            "actor_user_id",
            "actor_name",
            "action",
            "object_type",
            "object_id",
            "after",
        ]
    )
    for r in rows:
        out = _audit_out(r, actors)
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
