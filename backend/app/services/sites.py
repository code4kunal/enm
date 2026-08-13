from __future__ import annotations

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import NotFound, ValidationError
from app.models.master import Site, Vehicle
from app.models.user import User, UserSiteAccess
from app.schemas.site import SiteOut, VehicleOut


async def load_site(session: AsyncSession, code: str) -> Site:
    site = await session.get(Site, code.strip().upper())
    if site is None:
        raise NotFound(f"Site {code.strip().upper()} not found")
    return site


async def assert_site_accepts_entries(session: AsyncSession, code: str) -> Site:
    """A deactivated site keeps its history but accepts no new entries."""
    site = await load_site(session, code)
    if not site.is_active:
        raise ValidationError(
            f"Site {site.code} is deactivated and accepts no new entries",
            {"site": "site is deactivated"},
        )
    return site


async def rollups(
    session: AsyncSession, codes: list[str]
) -> tuple[dict[str, int], dict[str, int]]:
    """(vehicle_count, user_count) per site code, in two grouped queries."""
    if not codes:
        return {}, {}
    vehicles = dict(
        (
            await session.execute(
                select(Vehicle.site_code, func.count())
                .where(Vehicle.site_code.in_(codes))
                .group_by(Vehicle.site_code)
            )
        ).all()
    )
    users = dict(
        (
            await session.execute(
                select(UserSiteAccess.site_code, func.count())
                .where(UserSiteAccess.site_code.in_(codes))
                .group_by(UserSiteAccess.site_code)
            )
        ).all()
    )
    return vehicles, users


def site_out(
    site: Site, vehicle_count: int = 0, user_count: int = 0
) -> SiteOut:
    return SiteOut(
        code=site.code,
        name=site.name,
        is_active=site.is_active,
        timezone=site.timezone,
        address=site.address,
        commissioned_on=site.commissioned_on,
        vehicle_count=vehicle_count,
        user_count=user_count,
    )


def vehicle_out(vehicle: Vehicle) -> VehicleOut:
    return VehicleOut(
        id=vehicle.id,
        registration_no=vehicle.registration_no,
        site_code=vehicle.site_code,
        is_active=vehicle.is_active,
        make=vehicle.make,
        model=vehicle.model,
        battery_capacity_kwh=vehicle.battery_capacity_kwh,
        odometer_km=vehicle.odometer_km,
        odometer_updated_at=vehicle.odometer_updated_at,
        last_service_km=vehicle.last_service_km,
        last_service_on=vehicle.last_service_on,
        last_service_code=vehicle.last_service_code,
    )


async def visible_sites(session: AsyncSession, user: User) -> list[Site]:
    """Every site for a super admin; the caller's grants otherwise."""
    stmt = select(Site).order_by(Site.name)
    if not user.is_super_admin:
        stmt = stmt.where(Site.code.in_(user.site_access or [""]))
    return list((await session.scalars(stmt)).all())
