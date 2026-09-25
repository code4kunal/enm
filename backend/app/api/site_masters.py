from __future__ import annotations

from fastapi import APIRouter, status
from sqlalchemy import select

from app.deps import CurrentUser, SessionDep, assert_site_permission
from app.errors import Conflict, NotFound
from app.models.master import Driver, SparePart
from app.schemas.site_masters import (
    DriverCreate,
    DriverList,
    DriverOut,
    DriverUpdate,
    SparePartCreate,
    SparePartList,
    SparePartOut,
    SparePartUpdate,
)

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
    return await _set_spare_part_active(part_id, False, user, session)


@router.post("/spare-parts/{part_id}/activate", response_model=SparePartOut)
async def activate_spare_part(part_id: str, user: CurrentUser, session: SessionDep) -> SparePartOut:
    return await _set_spare_part_active(part_id, True, user, session)


async def _set_spare_part_active(
    part_id: str, active: bool, user: CurrentUser, session: SessionDep
) -> SparePartOut:
    row = await session.get(SparePart, part_id)
    if row is None:
        raise NotFound("Spare part not found")
    assert_site_permission(user, row.site_code, "em_master:write")
    row.is_active = active
    await session.commit()
    return _spare_part_out(row)


@router.put("/spare-parts/{part_id}", response_model=SparePartOut)
async def update_spare_part(
    part_id: str, payload: SparePartUpdate, user: CurrentUser, session: SessionDep
) -> SparePartOut:
    row = await session.get(SparePart, part_id)
    if row is None:
        raise NotFound("Spare part not found")
    site_code = assert_site_permission(user, row.site_code, "em_master:write")
    if payload.part_no is not None and payload.part_no != row.part_no:
        clash = await session.scalar(
            select(SparePart.id).where(
                SparePart.site_code == site_code,
                SparePart.part_no == payload.part_no,
                SparePart.id != row.id,
            )
        )
        if clash:
            raise Conflict(f"{payload.part_no} already exists", {"part_no": "duplicate"})
        row.part_no = payload.part_no
    if payload.name is not None:
        row.name = payload.name
    await session.commit()
    return _spare_part_out(row)


def _driver_out(row: Driver) -> DriverOut:
    return DriverOut(id=row.id, driver_code=row.driver_code, name=row.name, is_active=row.is_active)


@router.get("/sites/{code}/drivers", response_model=DriverList)
async def list_drivers(code: str, user: CurrentUser, session: SessionDep) -> DriverList:
    site_code = assert_site_permission(user, code, "em_master:read")
    rows = await session.scalars(
        select(Driver)
        .where(Driver.site_code == site_code, Driver.is_active.is_(True))
        .order_by(Driver.driver_code)
    )
    return DriverList(items=[_driver_out(r) for r in rows])


@router.post("/sites/{code}/drivers", response_model=DriverOut, status_code=status.HTTP_201_CREATED)
async def create_driver(
    code: str, payload: DriverCreate, user: CurrentUser, session: SessionDep
) -> DriverOut:
    site_code = assert_site_permission(user, code, "em_master:write")
    exists = await session.scalar(
        select(Driver.id).where(
            Driver.site_code == site_code, Driver.driver_code == payload.driver_code
        )
    )
    if exists:
        raise Conflict(f"{payload.driver_code} already exists", {"driver_code": "duplicate"})
    row = Driver(site_code=site_code, driver_code=payload.driver_code, name=payload.name)
    session.add(row)
    await session.commit()
    return _driver_out(row)


@router.post("/drivers/{driver_id}/deactivate", response_model=DriverOut)
async def deactivate_driver(driver_id: str, user: CurrentUser, session: SessionDep) -> DriverOut:
    return await _set_driver_active(driver_id, False, user, session)


@router.post("/drivers/{driver_id}/activate", response_model=DriverOut)
async def activate_driver(driver_id: str, user: CurrentUser, session: SessionDep) -> DriverOut:
    return await _set_driver_active(driver_id, True, user, session)


async def _set_driver_active(
    driver_id: str, active: bool, user: CurrentUser, session: SessionDep
) -> DriverOut:
    row = await session.get(Driver, driver_id)
    if row is None:
        raise NotFound("Driver not found")
    assert_site_permission(user, row.site_code, "em_master:write")
    row.is_active = active
    await session.commit()
    return _driver_out(row)


@router.put("/drivers/{driver_id}", response_model=DriverOut)
async def update_driver(
    driver_id: str, payload: DriverUpdate, user: CurrentUser, session: SessionDep
) -> DriverOut:
    row = await session.get(Driver, driver_id)
    if row is None:
        raise NotFound("Driver not found")
    site_code = assert_site_permission(user, row.site_code, "em_master:write")
    if payload.driver_code is not None and payload.driver_code != row.driver_code:
        clash = await session.scalar(
            select(Driver.id).where(
                Driver.site_code == site_code,
                Driver.driver_code == payload.driver_code,
                Driver.id != row.id,
            )
        )
        if clash:
            raise Conflict(
                f"{payload.driver_code} already exists", {"driver_code": "duplicate"}
            )
        row.driver_code = payload.driver_code
    if payload.name is not None:
        row.name = payload.name
    await session.commit()
    return _driver_out(row)
