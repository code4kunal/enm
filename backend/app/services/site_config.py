from __future__ import annotations

from datetime import UTC, datetime, time

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import ValidationError
from app.models.enums import Shift
from app.models.site_config import ServicePlan, ShiftWindow, SiteConfig
from app.models.user import User
from app.schemas.site_config import (
    OdometerSyncIO,
    ServicePlanIO,
    ShiftWindowIO,
    SiteConfigIO,
)

#: A pull more often than this is telematics abuse, not fresher data.
MIN_SYNC_MINUTES = 5

#: The three-shift day every depot we onboard actually runs. Seeded once, when
#: a site's config row is first created, so a new site can file a Daily Work
#: Done entry against a real shift instead of an empty dropdown. A manager who
#: clears or edits them is not overruled — `replace` writes exactly what it is
#: given and this never runs again for that site.
DEFAULT_SHIFTS: tuple[tuple[Shift, time, time], ...] = (
    (Shift.A, time(6, 0), time(14, 0)),
    (Shift.B, time(14, 0), time(22, 0)),
    # C wraps midnight, which `end <= start` is how ShiftWindow says.
    (Shift.C, time(22, 0), time(6, 0)),
)


async def get_or_create(session: AsyncSession, site_code: str) -> SiteConfig:
    config = await session.get(SiteConfig, site_code)
    if config is None:
        config = SiteConfig(site_code=site_code)
        session.add(config)
        for shift, start, end in DEFAULT_SHIFTS:
            session.add(
                ShiftWindow(
                    site_code=site_code,
                    shift=shift,
                    start_time=start,
                    end_time=end,
                )
            )
        # Flushed here rather than left pending: `replace` deletes the shift
        # rows straight after calling this, and the delete has to see them.
        await session.flush()
    return config


async def load_plans(session: AsyncSession, site_code: str) -> list[ServicePlan]:
    return list(
        (
            await session.scalars(
                select(ServicePlan)
                .where(ServicePlan.site_code == site_code)
                .order_by(ServicePlan.interval_km, ServicePlan.code)
            )
        ).all()
    )


async def load_shifts(session: AsyncSession, site_code: str) -> list[ShiftWindow]:
    return list(
        (
            await session.scalars(
                select(ShiftWindow)
                .where(ShiftWindow.site_code == site_code)
                .order_by(ShiftWindow.shift)
            )
        ).all()
    )


async def to_io(session: AsyncSession, config: SiteConfig) -> SiteConfigIO:
    plans = await load_plans(session, config.site_code)
    shifts = await load_shifts(session, config.site_code)
    updated_by = ""
    if config.updated_by_id:
        actor = await session.get(User, config.updated_by_id)
        updated_by = actor.name if actor else ""

    return SiteConfigIO(
        site_code=config.site_code,
        service_plans=[
            ServicePlanIO(
                code=p.code,
                name=p.name,
                interval_km=p.interval_km,
                interval_days=p.interval_days,
                is_active=p.is_active,
                notes=p.notes,
            )
            for p in plans
        ],
        shifts=[
            ShiftWindowIO(
                shift=s.shift.value, start=s.start_time, end=s.end_time
            )
            for s in shifts
        ],
        reminder_lead_km=config.reminder_lead_km,
        reminder_lead_days=config.reminder_lead_days,
        docking_slot_minutes=config.docking_slot_minutes,
        max_vehicles_in_service=config.max_vehicles_in_service,
        operating_categories=list(config.operating_categories or ["bus"]),
        odometer_sync=OdometerSyncIO(
            enabled=config.odometer_sync_enabled,
            interval_minutes=config.odometer_sync_minutes,
            source=config.odometer_sync_source,
            last_synced_at=config.odometer_last_synced_at,
        ),
        updated_at=config.updated_at,
        updated_by=updated_by,
    )


def validation_issues(payload: SiteConfigIO) -> list[str]:
    """The six coherence rules, mirroring `app/lib/models/site_config.dart`.

    The client checks the same list first so the user sees a problem before a
    round trip, but this is the authority.
    """
    issues: list[str] = []

    active = [
        p
        for p in payload.service_plans
        if p.is_active and (p.interval_km > 0 or p.interval_days > 0)
    ]
    if not active:
        issues.append(
            "No active service plan has an interval — nothing will ever fall due."
        )

    codes = [p.code.strip().upper() for p in payload.service_plans]
    if len(set(codes)) != len(codes):
        issues.append("Two service plans share the same code.")
    if any(not c for c in codes):
        issues.append("Every service plan needs a code.")

    for plan in active:
        if plan.interval_km > 0 and payload.reminder_lead_km >= plan.interval_km:
            issues.append(
                f'"{plan.name or plan.code}" is warned about '
                f"{payload.reminder_lead_km:,} km ahead of a "
                f"{plan.interval_km:,} km interval — it would always read as due."
            )
        if plan.interval_days > 0 and payload.reminder_lead_days >= plan.interval_days:
            issues.append(
                f'"{plan.name or plan.code}" is warned about '
                f"{payload.reminder_lead_days} days ahead of a "
                f"{plan.interval_days} day interval — it would always read as due."
            )

    if (
        payload.odometer_sync.enabled
        and payload.odometer_sync.interval_minutes < MIN_SYNC_MINUTES
    ):
        issues.append(
            f"Odometer sync cannot run more often than every "
            f"{MIN_SYNC_MINUTES} minutes."
        )

    return issues


async def replace(
    session: AsyncSession,
    *,
    site_code: str,
    payload: SiteConfigIO,
    actor: User,
) -> SiteConfig:
    """PUT replaces the whole aggregate — plans and shifts included."""
    issues = validation_issues(payload)
    if issues:
        raise ValidationError(issues[0], {"config": "; ".join(issues)})

    config = await get_or_create(session, site_code)
    categories_changed = sorted(config.operating_categories or []) != sorted(
        payload.operating_categories
    )
    config.reminder_lead_km = payload.reminder_lead_km
    config.reminder_lead_days = payload.reminder_lead_days
    config.docking_slot_minutes = payload.docking_slot_minutes
    config.max_vehicles_in_service = payload.max_vehicles_in_service
    config.operating_categories = list(payload.operating_categories)
    config.odometer_sync_enabled = payload.odometer_sync.enabled
    config.odometer_sync_minutes = max(
        payload.odometer_sync.interval_minutes, MIN_SYNC_MINUTES
    )
    config.odometer_sync_source = payload.odometer_sync.source
    config.updated_at = datetime.now(UTC)
    config.updated_by_id = actor.id

    await session.execute(
        delete(ServicePlan).where(ServicePlan.site_code == site_code)
    )
    await session.execute(
        delete(ShiftWindow).where(ShiftWindow.site_code == site_code)
    )
    await session.flush()

    for plan in payload.service_plans:
        session.add(
            ServicePlan(
                site_code=site_code,
                code=plan.code.strip().upper(),
                name=plan.name.strip() or plan.code.strip().upper(),
                interval_km=plan.interval_km,
                interval_days=plan.interval_days,
                is_active=plan.is_active,
                notes=plan.notes,
            )
        )
    for window in payload.shifts:
        session.add(
            ShiftWindow(
                site_code=site_code,
                shift=Shift(window.shift),
                start_time=window.start,
                end_time=window.end,
            )
        )
    await session.flush()
    if categories_changed:
        from app.services import checklists

        await checklists.apply_catalogue(session, site_code)
    return config
