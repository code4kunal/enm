"""SAP master data sync: equipment, materials, functional locations.

Nightly job plus a manager "Sync now" button (app/api/sap.py). Pull only —
nothing here ever writes back to SAP. Upsert by SAP's own key; a row SAP
stops mentioning is left alone rather than deleted, the same stance
`app.services.masters.resolve_defect_source` already takes for local master
data ("hiding must not break references").
"""
from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import UTC, datetime

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.master import SapMaterial, Site, Vehicle
from app.models.sync import SyncCursor
from app.services.masters import normalize_registration_no
from app.services.sap import client as sap_client

logger = logging.getLogger("enm.sap")

_CURSOR = "sap_master_sync"


@dataclass(slots=True)
class SyncResult:
    equipment_matched: int = 0
    materials_synced: int = 0
    flocs_matched: int = 0


async def sync_site(session: AsyncSession, site_code: str) -> SyncResult:
    result = SyncResult()

    equipment = await sap_client.list_equipment()
    by_registration = {
        normalize_registration_no(e["registration_no"]): e["equipment_no"]
        for e in equipment
        if e.get("registration_no")
    }
    vehicles = (
        await session.scalars(select(Vehicle).where(Vehicle.site_code == site_code))
    ).all()
    for vehicle in vehicles:
        equipment_no = by_registration.get(vehicle.registration_no)
        if not equipment_no:
            continue
        # Counted as matched whether or not it changed anything — "Sync now"
        # reporting 0 after a clean sync would read as failure, not success.
        result.equipment_matched += 1
        if vehicle.sap_equipment_no != equipment_no:
            vehicle.sap_equipment_no = equipment_no

    materials = await sap_client.list_materials()
    for m in materials:
        material_no = m.get("material_no")
        if not material_no:
            continue
        row = await session.scalar(
            select(SapMaterial).where(SapMaterial.sap_material_no == material_no)
        )
        if row is None:
            row = SapMaterial(sap_material_no=material_no)
            session.add(row)
        row.description = m.get("description", "")
        row.uom = m.get("uom", "")
        result.materials_synced += 1

    flocs = await sap_client.list_functional_locations()
    for f in flocs:
        code = f.get("site_code")
        floc = f.get("floc")
        if not code or not floc:
            continue
        site = await session.get(Site, code)
        if site is None:
            continue
        result.flocs_matched += 1
        if site.sap_floc != floc:
            site.sap_floc = floc

    cursor = await session.scalar(select(SyncCursor).where(SyncCursor.name == _CURSOR))
    if cursor is None:
        cursor = SyncCursor(name=_CURSOR)
        session.add(cursor)
    cursor.value = datetime.now(UTC).isoformat()
    cursor.updated_at = datetime.now(UTC)

    await session.flush()
    return result


async def sync_all_sites() -> None:
    """Scheduler entry point."""
    from app.db import SessionLocal

    async with SessionLocal() as session:
        site_codes = (await session.scalars(select(Site.code))).all()
        for code in site_codes:
            try:
                result = await sync_site(session, code)
                logger.info(
                    "SAP master sync %s: %d equipment, %d materials, %d flocs",
                    code,
                    result.equipment_matched,
                    result.materials_synced,
                    result.flocs_matched,
                )
            except Exception:  # noqa: BLE001 — one site's failure must not skip the rest
                logger.exception("SAP master sync failed for site %s", code)
        await session.commit()
