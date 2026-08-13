from __future__ import annotations

from datetime import date as date_t
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.master import Vehicle
from app.models.site_config import ServicePlan, SiteConfig
from app.schemas.site import ServiceDueOut
from app.services.site_config import get_or_create, load_plans

#: Nominal km/day used only to put distance and time runways on one axis for
#: sorting. It orders the queue; it does not predict a date.
KM_PER_DAY = 200

_RANK = {"ok": 0, "unknown": 1, "due_soon": 2, "overdue": 3}


def _worse(a: str, b: str) -> str:
    return a if _RANK[a] >= _RANK[b] else b


def evaluate(
    vehicle: Vehicle, plan: ServicePlan, config: SiteConfig, today: date_t
) -> ServiceDueOut:
    """Mirrors `app/lib/models/service_due.dart` exactly — change both together."""
    due_km: int | None = None
    km_remaining: int | None = None
    due_on: date_t | None = None
    days_remaining: int | None = None

    status = "ok"
    distance_usable = True
    has_odometer = vehicle.odometer_updated_at is not None

    if plan.interval_km > 0:
        if not has_odometer:
            # A missing reading is unknown, never 0 km. A stale telematics feed
            # has to be visible, not invisible.
            distance_usable = False
        else:
            anchor = vehicle.last_service_km or 0
            due_km = anchor + plan.interval_km
            km_remaining = due_km - vehicle.odometer_km
            if km_remaining <= 0:
                status = "overdue"
            elif km_remaining <= config.reminder_lead_km:
                status = "due_soon"

    if plan.interval_days > 0:
        anchor_date = vehicle.last_service_on or _date_of(
            vehicle.odometer_updated_at, today
        )
        due_on = _add_days(anchor_date, plan.interval_days)
        days_remaining = (due_on - today).days
        if days_remaining <= 0:
            time_status = "overdue"
        elif days_remaining <= config.reminder_lead_days:
            time_status = "due_soon"
        else:
            time_status = "ok"
        status = _worse(status, time_status)

    # Only report "no odometer" when nothing else already demands attention.
    if not distance_usable and status not in ("due_soon", "overdue"):
        status = "unknown"

    return ServiceDueOut(
        vehicle_id=vehicle.id,
        registration_no=vehicle.registration_no,
        plan_code=plan.code,
        plan_name=plan.name,
        status=status,
        due_km=due_km,
        km_remaining=km_remaining,
        due_on=due_on,
        days_remaining=days_remaining,
        odometer_km=vehicle.odometer_km if has_odometer else None,
        has_odometer=has_odometer,
    )


def _date_of(value: datetime | None, fallback: date_t) -> date_t:
    return value.date() if value is not None else fallback


def _add_days(anchor: date_t, days: int) -> date_t:
    from datetime import timedelta

    return anchor + timedelta(days=days)


def _urgency(row: ServiceDueOut) -> int:
    by_km = None if row.km_remaining is None else row.km_remaining // KM_PER_DAY
    by_days = row.days_remaining
    if by_km is None:
        return by_days if by_days is not None else 1 << 20
    if by_days is None:
        return by_km
    return min(by_km, by_days)


async def for_site(
    session: AsyncSession, site_code: str, today: date_t
) -> list[ServiceDueOut]:
    """Every active plan against every active vehicle, worst first."""
    config = await get_or_create(session, site_code)
    plans = [
        p
        for p in await load_plans(session, site_code)
        if p.is_active and (p.interval_km > 0 or p.interval_days > 0)
    ]
    if not plans:
        return []

    vehicles = list(
        (
            await session.scalars(
                select(Vehicle)
                .where(Vehicle.site_code == site_code, Vehicle.is_active.is_(True))
                .order_by(Vehicle.registration_no)
            )
        ).all()
    )

    rows = [
        evaluate(vehicle, plan, config, today)
        for vehicle in vehicles
        for plan in plans
    ]
    rows.sort(key=_urgency)
    return rows
