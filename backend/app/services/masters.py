from __future__ import annotations

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import ValidationError
from app.models.master import DefectSource, DefectType, Vehicle


def normalize_registration_no(raw: str) -> str:
    """Registration numbers are stored uppercase with no whitespace."""
    return "".join(raw.split()).upper()


async def find_vehicle_by_registration(
    session: AsyncSession, raw_registration: str
) -> Vehicle | None:
    """Registration numbers are unique across the whole fleet (not per
    site), so unlike `resolve_vehicle` this needs no site to search within.
    Returns `None` rather than raising — every caller (fleet-streams
    ingest, the WhatsApp `DOWN`/`STATUS` commands) treats an unrecognized
    plate as a soft miss, never an auto-created vehicle."""
    normalized = normalize_registration_no(raw_registration)
    return await session.scalar(
        select(Vehicle).where(Vehicle.registration_no == normalized)
    )


async def resolve_vehicle(
    session: AsyncSession, *, registration_no: str, site_code: str
) -> Vehicle:
    """The vehicle must be on this site's fleet. Server normalizes case/spaces.

    Never conjures a vehicle from entry text — a typo or another site's bus
    would silently join this site's master (registration numbers are unique
    across the whole fleet, so a bus already owned elsewhere would 500 rather
    than fail cleanly). A bus joins the fleet through Vehicle Master or an
    import, not by being typed into a register.
    """
    normalized = normalize_registration_no(registration_no)
    vehicle = await session.scalar(
        select(Vehicle).where(
            Vehicle.registration_no == normalized, Vehicle.site_code == site_code
        )
    )
    if vehicle is None:
        raise ValidationError(
            f"{normalized} is not on the {site_code} fleet",
            {"bus_no": "unknown vehicle"},
        )
    if not vehicle.is_active:
        raise ValidationError(
            f"{normalized} is retired", {"bus_no": "vehicle is retired"}
        )
    return vehicle


async def resolve_defect_source(
    session: AsyncSession, name: str | None
) -> DefectSource | None:
    """Resolve by name, ignoring `is_active`.

    Hiding a master row must not break entries that already reference it —
    filter on `is_active` when serving the dropdown, never when resolving.
    """
    if not name:
        return None
    row = await session.scalar(
        select(DefectSource).where(
            func.lower(DefectSource.name) == name.strip().lower()
        )
    )
    if row is None:
        raise ValidationError(
            f"Unknown defect source: {name}", {"defect_source": "not in master list"}
        )
    return row


async def resolve_defect_type(
    session: AsyncSession, name: str | None
) -> DefectType | None:
    if not name:
        return None
    row = await session.scalar(
        select(DefectType).where(func.lower(DefectType.name) == name.strip().lower())
    )
    if row is None:
        raise ValidationError(
            f"Unknown defect type: {name}", {"defect_type": "not in master list"}
        )
    return row
