from __future__ import annotations

import logging
from datetime import UTC, datetime
from datetime import date as date_t

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import ValidationError
from app.models.master import OdometerReading, Vehicle
from app.models.site_config import SiteConfig
from app.schemas.site import OdometerReadingOut, OdometerSyncOut
from app.services.site_config import get_or_create

logger = logging.getLogger("enm.odometer")


class TelematicsProvider:
    """Where odometer readings come from.

    No provider is configured out of the box, and that is a supported state:
    sites without a feed rely on manual readings and the odometer import, and
    the rest of the schedule still works. A pull that finds nothing new must
    succeed with an empty list, never 500.
    """

    def __init__(self, source: str) -> None:
        self.source = source

    @property
    def is_configured(self) -> bool:
        return False

    async def fetch(
        self, _registration_nos: list[str]
    ) -> dict[str, tuple[int, datetime]]:
        return {}


def provider_for(config: SiteConfig) -> TelematicsProvider:
    return TelematicsProvider(config.odometer_sync_source)


def record_reading(
    session: AsyncSession,
    vehicle: Vehicle,
    *,
    odometer_km: int,
    recorded_at: datetime,
    source: str,
) -> None:
    """Cache the latest on the vehicle and append to the history."""
    vehicle.odometer_km = odometer_km
    vehicle.odometer_updated_at = recorded_at
    session.add(
        OdometerReading(
            vehicle_id=vehicle.id,
            odometer_km=odometer_km,
            recorded_at=recorded_at,
            source=source,
        )
    )


async def set_manual(
    session: AsyncSession, vehicle: Vehicle, odometer_km: int
) -> Vehicle:
    """An odometer never moves backwards — a lower manual reading is rejected."""
    if vehicle.odometer_updated_at is not None and odometer_km < vehicle.odometer_km:
        raise ValidationError(
            f"Odometers do not run backwards — {vehicle.registration_no} is "
            f"already at {vehicle.odometer_km:,} km",
            {"odometer_km": "lower than the reading on record"},
        )
    record_reading(
        session,
        vehicle,
        odometer_km=odometer_km,
        recorded_at=datetime.now(UTC),
        source="manual",
    )
    await session.flush()
    return vehicle


async def record_service(
    session: AsyncSession,
    vehicle: Vehicle,
    *,
    plan_code: str,
    odometer_km: int,
    serviced_on: date_t,
) -> Vehicle:
    """Close out a service and re-anchor the next one."""
    if vehicle.odometer_updated_at is not None and odometer_km < vehicle.odometer_km:
        raise ValidationError(
            f"Odometers do not run backwards — {vehicle.registration_no} is "
            f"already at {vehicle.odometer_km:,} km",
            {"odometer_km": "lower than the reading on record"},
        )
    record_reading(
        session,
        vehicle,
        odometer_km=odometer_km,
        recorded_at=datetime.now(UTC),
        source="service",
    )
    vehicle.last_service_km = odometer_km
    vehicle.last_service_on = serviced_on
    vehicle.last_service_code = plan_code.strip().upper()
    await session.flush()
    return vehicle


async def sync_site(session: AsyncSession, site_code: str) -> OdometerSyncOut:
    """Pull the latest readings for one site's fleet.

    Idempotent: the client polls on the same interval as the server job, so a
    pull that finds nothing new reports `skipped`, not an error.
    """
    config = await get_or_create(session, site_code)
    now = datetime.now(UTC)

    vehicles = list(
        (
            await session.scalars(
                select(Vehicle).where(
                    Vehicle.site_code == site_code, Vehicle.is_active.is_(True)
                )
            )
        ).all()
    )

    provider = provider_for(config)
    fetched = (
        await provider.fetch([v.registration_no for v in vehicles])
        if provider.is_configured
        else {}
    )

    updated: list[OdometerReadingOut] = []
    skipped = 0
    for vehicle in vehicles:
        reading = fetched.get(vehicle.registration_no)
        # Nothing reported, or not newer than what we hold: not an error.
        if reading is None or reading[0] <= vehicle.odometer_km:
            skipped += 1
            continue
        odometer_km, recorded_at = reading
        record_reading(
            session,
            vehicle,
            odometer_km=odometer_km,
            recorded_at=recorded_at,
            source=config.odometer_sync_source,
        )
        updated.append(
            OdometerReadingOut(
                vehicle_id=vehicle.id,
                registration_no=vehicle.registration_no,
                odometer_km=odometer_km,
                recorded_at=recorded_at,
            )
        )

    config.odometer_last_synced_at = now
    await session.flush()
    return OdometerSyncOut(readings=updated, synced_at=now, skipped=skipped)


async def scan_sites_due_for_sync() -> None:
    """Scheduled job: pull for every site whose interval has elapsed.

    Runs alongside the breakdown-SLA scan. The client polls too, which is why
    the pull has to be idempotent.
    """
    from app.db import SessionLocal

    async with SessionLocal() as session:
        configs = list(
            (
                await session.scalars(
                    select(SiteConfig).where(SiteConfig.odometer_sync_enabled.is_(True))
                )
            ).all()
        )
        now = datetime.now(UTC)
        for config in configs:
            last = config.odometer_last_synced_at
            if last is not None:
                elapsed_minutes = (now - last).total_seconds() / 60
                if elapsed_minutes < config.odometer_sync_minutes:
                    continue
            try:
                result = await sync_site(session, config.site_code)
                await session.commit()
            except Exception:  # noqa: BLE001 - one bad site must not stop the rest
                await session.rollback()
                logger.exception("Odometer sync failed for %s", config.site_code)
                continue
            if result.readings:
                logger.info(
                    "Odometer sync %s: %d updated, %d skipped",
                    config.site_code,
                    len(result.readings),
                    result.skipped,
                )
