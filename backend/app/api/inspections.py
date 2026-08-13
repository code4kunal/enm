from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Annotated

from fastapi import APIRouter, Query, status
from sqlalchemy import func, select

from app.deps import CurrentUser, SessionDep, assert_site_access, assert_site_admin
from app.errors import Conflict, NotFound, ValidationError
from app.models.enums import AlertStatus, AuditAction, SlotStatus
from app.models.inspection import Alert, InspectionPlan, InspectionSlot
from app.models.master import Vehicle, WorkType
from app.schemas.inspection import (
    AlertList,
    AlertOut,
    CalendarDay,
    CalendarOut,
    GenerateOut,
    InspectionPlanIO,
    InspectionPlanList,
    SlotCreate,
    SlotOut,
    SlotUpdate,
)
from app.services import audit, inspections
from app.services.common import today_ist

router = APIRouter(tags=["inspections"])

#: A calendar request is bounded so one call cannot ask for a decade.
MAX_CALENDAR_DAYS = 120


def _slot_out(slot: InspectionSlot) -> SlotOut:
    return SlotOut(
        id=slot.id,
        site_code=slot.site_code,
        vehicle_id=slot.vehicle_id,
        registration_no=slot.vehicle.registration_no if slot.vehicle else "",
        work_type_id=slot.work_type_id,
        work_type_code=slot.work_type.code if slot.work_type else "",
        work_type_name=slot.work_type.name if slot.work_type else "",
        scheduled_on=slot.scheduled_on,
        status=slot.status,
        is_pinned=slot.is_pinned,
        completed_on=slot.completed_on,
        completed_entry_id=slot.completed_entry_id,
        notes=slot.notes,
    )


def _plan_out(plan: InspectionPlan) -> InspectionPlanIO:
    return InspectionPlanIO(
        id=plan.id,
        work_type_id=plan.work_type_id,
        work_type_code=plan.work_type.code if plan.work_type else "",
        work_type_name=plan.work_type.name if plan.work_type else "",
        register=plan.work_type.register if plan.work_type else None,
        cycle_days=plan.cycle_days,
        slots_per_day=plan.slots_per_day,
        is_active=plan.is_active,
    )


async def _load_slot(session: SessionDep, slot_id: str) -> InspectionSlot:
    slot = await session.get(InspectionSlot, slot_id)
    if slot is None:
        raise NotFound("Scheduled inspection not found")
    return slot


# --- the calendar -----------------------------------------------------------


@router.get("/sites/{code}/inspections/calendar", response_model=CalendarOut)
async def calendar(
    code: str,
    user: CurrentUser,
    session: SessionDep,
    from_date: Annotated[str | None, Query(alias="from")] = None,
    to_date: Annotated[str | None, Query(alias="to")] = None,
) -> CalendarOut:
    """Every booking in a date range, grouped by day.

    Empty days are returned too, so the client renders a continuous calendar
    rather than having to fill the gaps itself.
    """
    site_code = assert_site_access(user, code)
    today = today_ist()
    start = _parse_date(from_date, today - timedelta(days=7), "from")
    end = _parse_date(to_date, today + timedelta(days=30), "to")
    if end < start:
        raise ValidationError("`to` is before `from`", {"to": "before from"})
    if (end - start).days > MAX_CALENDAR_DAYS:
        raise ValidationError(
            f"Ask for at most {MAX_CALENDAR_DAYS} days at a time",
            {"to": "range too wide"},
        )

    rows = list(
        (
            await session.scalars(
                select(InspectionSlot)
                .where(
                    InspectionSlot.site_code == site_code,
                    InspectionSlot.scheduled_on >= start,
                    InspectionSlot.scheduled_on <= end,
                )
                .order_by(InspectionSlot.scheduled_on, InspectionSlot.id)
            )
        ).unique().all()
    )

    by_day: dict[object, list[SlotOut]] = {}
    for slot in rows:
        by_day.setdefault(slot.scheduled_on, []).append(_slot_out(slot))
    for slots in by_day.values():
        slots.sort(key=lambda s: (s.work_type_code, s.registration_no))

    days: list[CalendarDay] = []
    cursor = start
    while cursor <= end:
        days.append(CalendarDay(date=cursor, slots=by_day.get(cursor, [])))
        cursor += timedelta(days=1)

    return CalendarOut(
        site_code=site_code,
        from_date=start,
        to_date=end,
        days=days,
        scheduled=sum(1 for s in rows if s.status is SlotStatus.scheduled),
        done=sum(1 for s in rows if s.status is SlotStatus.done),
        missed=sum(1 for s in rows if s.status is SlotStatus.missed),
    )


def _parse_date(raw: str | None, fallback, field: str):
    if not raw:
        return fallback
    from datetime import date as date_t

    try:
        return date_t.fromisoformat(raw)
    except ValueError as exc:
        raise ValidationError(
            f"`{field}` must be yyyy-MM-dd", {field: "expected yyyy-MM-dd"}
        ) from exc


# --- running the generator --------------------------------------------------


@router.post("/sites/{code}/inspections/generate", response_model=GenerateOut)
async def generate(
    code: str, user: CurrentUser, session: SessionDep
) -> GenerateOut:
    """Run the scheduler now.

    The same routine the 22:00 job runs, exposed so a manager who has just
    imported a month of history does not have to wait until tonight to see the
    calendar catch up. Safe to run repeatedly.
    """
    site_code = assert_site_admin(user, code)
    result = await inspections.generate_for_site(session, site_code)
    await audit.record(
        session,
        actor_id=user.id,
        action=AuditAction.schedule_generated,
        object_type="site",
        object_id=site_code,
        after={
            "created": result.created,
            "missed": result.missed,
            "completed": result.completed,
        },
    )
    await session.commit()
    return GenerateOut(
        site_code=result.site_code,
        generated_on=result.generated_on,
        created=result.created,
        missed=result.missed,
        completed=result.completed,
        alerts_raised=result.alerts_raised,
    )


# --- editing the plan --------------------------------------------------------


@router.post(
    "/sites/{code}/inspections/slots",
    response_model=SlotOut,
    status_code=status.HTTP_201_CREATED,
)
async def create_slot(
    code: str, payload: SlotCreate, user: CurrentUser, session: SessionDep
) -> SlotOut:
    """Book a bus in by hand. Pinned, so the generator leaves it alone."""
    site_code = assert_site_admin(user, code)

    vehicle = await session.get(Vehicle, payload.vehicle_id)
    if vehicle is None or vehicle.site_code != site_code:
        raise NotFound("Vehicle not found on this site")
    if await session.get(WorkType, payload.work_type_id) is None:
        raise NotFound("Work type not found")

    clash = await session.scalar(
        select(InspectionSlot.id).where(
            InspectionSlot.site_code == site_code,
            InspectionSlot.vehicle_id == payload.vehicle_id,
            InspectionSlot.work_type_id == payload.work_type_id,
            InspectionSlot.scheduled_on == payload.scheduled_on,
        )
    )
    if clash:
        raise Conflict(
            f"{vehicle.registration_no} is already booked that day",
            {"scheduled_on": "duplicate"},
        )

    slot = InspectionSlot(
        site_code=site_code,
        vehicle_id=payload.vehicle_id,
        work_type_id=payload.work_type_id,
        scheduled_on=payload.scheduled_on,
        notes=payload.notes,
        is_pinned=True,
    )
    session.add(slot)
    await session.commit()
    await session.refresh(slot)
    return _slot_out(slot)


@router.put("/inspection-slots/{slot_id}", response_model=SlotOut)
async def update_slot(
    slot_id: str, payload: SlotUpdate, user: CurrentUser, session: SessionDep
) -> SlotOut:
    """Move, cancel or annotate a booking.

    Any hand edit pins it: someone who chose a date had a reason the generator
    cannot see, so it is never moved back.
    """
    slot = await _load_slot(session, slot_id)
    assert_site_admin(user, slot.site_code)
    before = {"scheduled_on": slot.scheduled_on.isoformat(), "status": slot.status.value}

    if payload.scheduled_on is not None and payload.scheduled_on != slot.scheduled_on:
        clash = await session.scalar(
            select(InspectionSlot.id).where(
                InspectionSlot.site_code == slot.site_code,
                InspectionSlot.vehicle_id == slot.vehicle_id,
                InspectionSlot.work_type_id == slot.work_type_id,
                InspectionSlot.scheduled_on == payload.scheduled_on,
                InspectionSlot.id != slot.id,
            )
        )
        if clash:
            raise Conflict(
                "That bus is already booked for this inspection that day",
                {"scheduled_on": "duplicate"},
            )
        slot.scheduled_on = payload.scheduled_on
        slot.is_pinned = True
    if payload.status is not None:
        slot.status = payload.status
        slot.is_pinned = True
    if payload.notes is not None:
        slot.notes = payload.notes
    if payload.is_pinned is not None:
        slot.is_pinned = payload.is_pinned
    slot.updated_at = datetime.now(UTC)

    await audit.record(
        session,
        actor_id=user.id,
        action=AuditAction.slot_updated,
        object_type="inspection_slot",
        object_id=slot.id,
        before=before,
        after={
            "scheduled_on": slot.scheduled_on.isoformat(),
            "status": slot.status.value,
        },
    )
    await session.commit()
    await session.refresh(slot)
    return _slot_out(slot)


@router.delete(
    "/inspection-slots/{slot_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    response_model=None,
)
async def delete_slot(
    slot_id: str, user: CurrentUser, session: SessionDep
) -> None:
    slot = await _load_slot(session, slot_id)
    assert_site_admin(user, slot.site_code)
    await session.delete(slot)
    await session.commit()


# --- plans -------------------------------------------------------------------


@router.get("/sites/{code}/inspections/plans", response_model=InspectionPlanList)
async def list_plans(
    code: str, user: CurrentUser, session: SessionDep
) -> InspectionPlanList:
    site_code = assert_site_access(user, code)
    rows = list(
        (
            await session.scalars(
                select(InspectionPlan)
                .where(InspectionPlan.site_code == site_code)
                .order_by(InspectionPlan.cycle_days)
            )
        ).unique().all()
    )
    return InspectionPlanList(items=[_plan_out(p) for p in rows])


@router.put("/sites/{code}/inspections/plans", response_model=InspectionPlanList)
async def replace_plans(
    code: str,
    payload: InspectionPlanList,
    user: CurrentUser,
    session: SessionDep,
) -> InspectionPlanList:
    """Replace the site's inspection cycles wholesale."""
    site_code = assert_site_admin(user, code)

    existing = {
        p.work_type_id: p
        for p in (
            await session.scalars(
                select(InspectionPlan).where(InspectionPlan.site_code == site_code)
            )
        ).unique().all()
    }
    seen: set[int] = set()
    for item in payload.items:
        if await session.get(WorkType, item.work_type_id) is None:
            raise NotFound(f"Work type {item.work_type_id} not found")
        seen.add(item.work_type_id)
        plan = existing.get(item.work_type_id)
        if plan is None:
            plan = InspectionPlan(
                site_code=site_code, work_type_id=item.work_type_id
            )
            session.add(plan)
        plan.cycle_days = item.cycle_days
        plan.slots_per_day = item.slots_per_day
        plan.is_active = item.is_active
    for work_type_id, plan in existing.items():
        if work_type_id not in seen:
            await session.delete(plan)

    await session.commit()
    return await list_plans(code, user, session)


# --- alerts -------------------------------------------------------------------


@router.get("/sites/{code}/alerts", response_model=AlertList)
async def list_alerts(
    code: str,
    user: CurrentUser,
    session: SessionDep,
    alert_status: Annotated[str, Query(alias="status")] = "open",
) -> AlertList:
    """The alert log: missed inspections, open breakdowns, overdue services."""
    site_code = assert_site_access(user, code)
    stmt = select(Alert).where(Alert.site_code == site_code)
    if alert_status == "open":
        stmt = stmt.where(Alert.status != AlertStatus.resolved)
    elif alert_status in {s.value for s in AlertStatus}:
        stmt = stmt.where(Alert.status == AlertStatus(alert_status))

    rows = list(
        (
            await session.scalars(
                stmt.order_by(Alert.raised_on.desc(), Alert.created_at.desc()).limit(200)
            )
        ).unique().all()
    )
    open_count = int(
        await session.scalar(
            select(func.count())
            .select_from(Alert)
            .where(Alert.site_code == site_code, Alert.status == AlertStatus.open)
        )
        or 0
    )
    return AlertList(
        items=[
            AlertOut(
                id=a.id,
                site_code=a.site_code,
                type=a.type,
                status=a.status,
                title=a.title,
                body=a.body,
                vehicle_id=a.vehicle_id,
                registration_no=a.vehicle.registration_no if a.vehicle else "",
                slot_id=a.slot_id,
                entry_id=a.entry_id,
                raised_on=a.raised_on,
                created_at=a.created_at,
                acknowledged_at=a.acknowledged_at,
            )
            for a in rows
        ],
        open_count=open_count,
    )


@router.post("/alerts/{alert_id}/acknowledge", response_model=AlertOut)
async def acknowledge(
    alert_id: str, user: CurrentUser, session: SessionDep
) -> AlertOut:
    """Seen and owned. The underlying problem still has to be fixed — the
    nightly run resolves it once it actually goes away."""
    alert = await session.get(Alert, alert_id)
    if alert is None:
        raise NotFound("Alert not found")
    assert_site_access(user, alert.site_code)

    if alert.status is AlertStatus.open:
        alert.status = AlertStatus.acknowledged
        alert.acknowledged_at = datetime.now(UTC)
        alert.acknowledged_by_id = user.id
        await audit.record(
            session,
            actor_id=user.id,
            action=AuditAction.alert_acknowledged,
            object_type="alert",
            object_id=alert.id,
        )
    await session.commit()
    await session.refresh(alert)
    return AlertOut(
        id=alert.id,
        site_code=alert.site_code,
        type=alert.type,
        status=alert.status,
        title=alert.title,
        body=alert.body,
        vehicle_id=alert.vehicle_id,
        registration_no=alert.vehicle.registration_no if alert.vehicle else "",
        slot_id=alert.slot_id,
        entry_id=alert.entry_id,
        raised_on=alert.raised_on,
        created_at=alert.created_at,
        acknowledged_at=alert.acknowledged_at,
    )
