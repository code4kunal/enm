from __future__ import annotations

from datetime import UTC, datetime

from fastapi import APIRouter
from sqlalchemy import select

from app.deps import CurrentUser, SessionDep, assert_site_access, assert_site_admin
from app.models.master import SapMaterial
from app.schemas.sap import SapMaterialList, SapMaterialOut, SapSyncOut
from app.services.sap.masters import sync_site

router = APIRouter(prefix="/sites/{code}/sap", tags=["sap"])


@router.post("/sync", response_model=SapSyncOut)
async def sync_now(code: str, user: CurrentUser, session: SessionDep) -> SapSyncOut:
    site_code = assert_site_admin(user, code)
    result = await sync_site(session, site_code)
    await session.commit()
    return SapSyncOut(
        equipment_matched=result.equipment_matched,
        materials_synced=result.materials_synced,
        flocs_matched=result.flocs_matched,
        synced_at=datetime.now(UTC).isoformat(),
    )


@router.get("/materials", response_model=SapMaterialList)
async def list_materials(
    code: str, user: CurrentUser, session: SessionDep
) -> SapMaterialList:
    """Feeds the Flutter materials picker — search-and-tap, no free text."""
    assert_site_access(user, code)
    rows = (
        await session.scalars(
            select(SapMaterial)
            .where(SapMaterial.is_active.is_(True))
            .order_by(SapMaterial.description)
        )
    ).all()
    return SapMaterialList(
        items=[
            SapMaterialOut(
                sap_material_no=r.sap_material_no,
                description=r.description,
                uom=r.uom,
            )
            for r in rows
        ]
    )
