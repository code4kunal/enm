from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import ValidationError
from app.models.master import Bus, DefectSource, DefectType


def normalize_bus_no(raw: str) -> str:
    return "".join(raw.split()).upper()


async def resolve_bus(
    session: AsyncSession, *, bus_no: str, depot_code: str
) -> Bus:
    """Bus must exist in the master for this depot. Server normalizes case/spaces."""
    normalized = normalize_bus_no(bus_no)
    bus = await session.scalar(
        select(Bus).where(Bus.bus_no == normalized, Bus.depot_code == depot_code)
    )
    if bus is None:
        raise ValidationError(
            f"Bus {normalized} is not registered at depot {depot_code}",
            {"bus_no": "unknown bus for this depot"},
        )
    if not bus.is_active:
        raise ValidationError(
            f"Bus {normalized} is inactive", {"bus_no": "bus is inactive"}
        )
    return bus


async def resolve_defect_source(
    session: AsyncSession, name: str | None
) -> DefectSource | None:
    if not name:
        return None
    row = await session.scalar(select(DefectSource).where(DefectSource.name == name))
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
    row = await session.scalar(select(DefectType).where(DefectType.name == name))
    if row is None:
        raise ValidationError(
            f"Unknown defect type: {name}", {"defect_type": "not in master list"}
        )
    return row
