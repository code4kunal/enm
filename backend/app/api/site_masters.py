from __future__ import annotations

from fastapi import APIRouter, status
from sqlalchemy import select

from app.deps import CurrentUser, SessionDep, assert_site_permission
from app.errors import Conflict, NotFound
from app.models.master import SparePart
from app.schemas.site_masters import SparePartCreate, SparePartList, SparePartOut

router = APIRouter(tags=["site-masters"])


def _spare_part_out(row: SparePart) -> SparePartOut:
    return SparePartOut(id=row.id, part_no=row.part_no, name=row.name, is_active=row.is_active)


@router.get("/sites/{code}/spare-parts", response_model=SparePartList)
async def list_spare_parts(code: str, user: CurrentUser, session: SessionDep) -> SparePartList:
    site_code = assert_site_permission(user, code, "em_master:read")
    rows = await session.scalars(
        select(SparePart)
        .where(SparePart.site_code == site_code, SparePart.is_active.is_(True))
        .order_by(SparePart.part_no)
    )
    return SparePartList(items=[_spare_part_out(r) for r in rows])


@router.post(
    "/sites/{code}/spare-parts", response_model=SparePartOut, status_code=status.HTTP_201_CREATED
)
async def create_spare_part(
    code: str, payload: SparePartCreate, user: CurrentUser, session: SessionDep
) -> SparePartOut:
    site_code = assert_site_permission(user, code, "em_master:write")
    exists = await session.scalar(
        select(SparePart.id).where(
            SparePart.site_code == site_code, SparePart.part_no == payload.part_no
        )
    )
    if exists:
        raise Conflict(f"{payload.part_no} already exists", {"part_no": "duplicate"})
    row = SparePart(site_code=site_code, part_no=payload.part_no, name=payload.name)
    session.add(row)
    await session.commit()
    return _spare_part_out(row)


@router.post("/spare-parts/{part_id}/deactivate", response_model=SparePartOut)
async def deactivate_spare_part(part_id: str, user: CurrentUser, session: SessionDep) -> SparePartOut:
    row = await session.get(SparePart, part_id)
    if row is None:
        raise NotFound("Spare part not found")
    assert_site_permission(user, row.site_code, "em_master:write")
    row.is_active = False
    await session.commit()
    return _spare_part_out(row)
