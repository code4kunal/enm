from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Query
from sqlalchemy import select

from app.deps import CurrentUser, SessionDep, assert_depot_access
from app.models.master import Bus, DefectSource, DefectType, Depot
from app.schemas.master import BusList, BusOut, DepotList, DepotOut, StringList

router = APIRouter(prefix="/master", tags=["master"])


@router.get("/depots", response_model=DepotList)
async def list_depots(user: CurrentUser, session: SessionDep) -> DepotList:
    """Only the depots this user can act on — drives the depot picker."""
    rows = await session.scalars(
        select(Depot)
        .where(Depot.code.in_(user.depot_access), Depot.is_active.is_(True))
        .order_by(Depot.name)
    )
    return DepotList(items=[DepotOut(code=d.code, name=d.name) for d in rows])


@router.get("/buses", response_model=BusList)
async def list_buses(
    user: CurrentUser,
    session: SessionDep,
    depot: Annotated[str, Query(min_length=1, max_length=16)],
    include_inactive: Annotated[bool, Query()] = False,
) -> BusList:
    code = assert_depot_access(user, depot)
    stmt = select(Bus).where(Bus.depot_code == code)
    if not include_inactive:
        stmt = stmt.where(Bus.is_active.is_(True))
    rows = await session.scalars(stmt.order_by(Bus.bus_no))
    return BusList(
        items=[
            BusOut(bus_no=b.bus_no, depot=b.depot_code, is_active=b.is_active)
            for b in rows
        ]
    )


@router.get("/defect-sources", response_model=StringList)
async def list_defect_sources(_: CurrentUser, session: SessionDep) -> StringList:
    rows = await session.scalars(
        select(DefectSource.name)
        .where(DefectSource.is_active.is_(True))
        .order_by(DefectSource.sort_order, DefectSource.name)
    )
    return StringList(items=list(rows.all()))


@router.get("/defect-types", response_model=StringList)
async def list_defect_types(_: CurrentUser, session: SessionDep) -> StringList:
    rows = await session.scalars(
        select(DefectType.name)
        .where(DefectType.is_active.is_(True))
        .order_by(DefectType.sort_order, DefectType.name)
    )
    return StringList(items=list(rows.all()))
