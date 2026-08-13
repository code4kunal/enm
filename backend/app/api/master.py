from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Query, status
from sqlalchemy import func, select

from app.deps import CurrentUser, SessionDep, SuperAdminUser, assert_site_access
from app.errors import Conflict, NotFound
from app.models.enums import AuditAction
from app.models.master import DefectSource, DefectType, WorkType
from app.models.user import User, UserSiteAccess
from app.schemas.master import (
    MasterItemCreate,
    MasterItemList,
    MasterItemOut,
    MasterItemUpdate,
    StaffList,
    StaffOut,
    WorkTypeCreate,
    WorkTypeList,
    WorkTypeOut,
    WorkTypeUpdate,
)
from app.services import audit

router = APIRouter(prefix="/master", tags=["master"])

#: The two tenant-wide dropdown lists, keyed by their route segment.
_LISTS = {
    "defect-sources": DefectSource,
    "defect-types": DefectType,
}


def _out(row: DefectSource | DefectType) -> MasterItemOut:
    return MasterItemOut(
        id=row.id, name=row.name, is_active=row.is_active, sort_order=row.sort_order
    )


def _model(kind: str) -> type[DefectSource] | type[DefectType]:
    model = _LISTS.get(kind)
    if model is None:
        raise NotFound("Unknown master list")
    return model


# --- staff ------------------------------------------------------------------


@router.get("/staff", response_model=StaffList)
async def list_staff(
    user: CurrentUser,
    session: SessionDep,
    site: Annotated[str, Query(min_length=1, max_length=16)],
) -> StaffList:
    """The people working at a site, for the "reported by" and "supervisor"
    dropdowns on the register forms.

    Readable by anyone who can reach the site — a mechanic filling in a form
    needs the list without being an administrator. Only active accounts are
    offered, so a name that has left the depot stops appearing without
    disturbing the entries that already carry it.
    """
    site_code = assert_site_access(user, site)
    rows = await session.scalars(
        select(User)
        .join(UserSiteAccess, UserSiteAccess.user_id == User.id)
        .where(UserSiteAccess.site_code == site_code, User.is_active.is_(True))
        .order_by(User.name)
    )
    return StaffList(
        items=[
            StaffOut(id=u.id, name=u.name, user_id=u.user_id, role=u.role)
            for u in rows.unique()
        ]
    )


# --- work types ------------------------------------------------------------
#
# Declared before the generic `/{kind}` routes below, which would otherwise
# match "work-types" and look for a defect list of that name.


def _work_type_out(row: WorkType) -> WorkTypeOut:
    return WorkTypeOut(
        id=row.id,
        code=row.code,
        name=row.name,
        register=row.register,
        is_active=row.is_active,
        sort_order=row.sort_order,
    )


@router.get("/work-types", response_model=WorkTypeList)
async def list_work_types(
    _: CurrentUser,
    session: SessionDep,
    include_inactive: Annotated[bool, Query()] = False,
) -> WorkTypeList:
    """The TYPE OF WORK vocabulary and where each code's rows land."""
    stmt = select(WorkType)
    if not include_inactive:
        stmt = stmt.where(WorkType.is_active.is_(True))
    rows = await session.scalars(stmt.order_by(WorkType.sort_order, WorkType.code))
    return WorkTypeList(items=[_work_type_out(r) for r in rows])


@router.post(
    "/work-types", response_model=WorkTypeOut, status_code=status.HTTP_201_CREATED
)
async def create_work_type(
    payload: WorkTypeCreate, actor: SuperAdminUser, session: SessionDep
) -> WorkTypeOut:
    clash = await session.scalar(
        select(WorkType.id).where(func.upper(WorkType.code) == payload.code)
    )
    if clash:
        raise Conflict(f'"{payload.code}" is already a work type', {"code": "duplicate"})

    sort_order = payload.sort_order
    if sort_order is None:
        highest = await session.scalar(select(func.max(WorkType.sort_order)))
        sort_order = (highest or 0) + 1

    row = WorkType(
        code=payload.code,
        name=payload.name,
        register=payload.register,
        sort_order=sort_order,
    )
    session.add(row)
    await session.flush()
    await audit.record(
        session,
        actor_id=actor.id,
        action=AuditAction.master_item_created,
        object_type="work_type",
        object_id=str(row.id),
        after={"code": row.code, "register": row.register.value if row.register else None},
    )
    await session.commit()
    return _work_type_out(row)


@router.put("/work-types/{item_id}", response_model=WorkTypeOut)
async def update_work_type(
    item_id: int,
    payload: WorkTypeUpdate,
    actor: SuperAdminUser,
    session: SessionDep,
) -> WorkTypeOut:
    row = await session.get(WorkType, item_id)
    if row is None:
        raise NotFound("Work type not found")

    before = {"code": row.code, "register": row.register.value if row.register else None}
    if payload.code is not None and payload.code != row.code:
        clash = await session.scalar(
            select(WorkType.id).where(
                func.upper(WorkType.code) == payload.code, WorkType.id != row.id
            )
        )
        if clash:
            raise Conflict(
                f'"{payload.code}" is already a work type', {"code": "duplicate"}
            )
        row.code = payload.code
    if payload.name is not None:
        row.name = payload.name.strip()
    if "register" in payload.model_fields_set:
        row.register = payload.register
    if payload.is_active is not None:
        row.is_active = payload.is_active
    if payload.sort_order is not None:
        row.sort_order = payload.sort_order

    await audit.record(
        session,
        actor_id=actor.id,
        action=AuditAction.master_item_updated,
        object_type="work_type",
        object_id=str(row.id),
        before=before,
        after={"code": row.code, "register": row.register.value if row.register else None},
    )
    await session.commit()
    return _work_type_out(row)


@router.get("/{kind}", response_model=MasterItemList)
async def list_items(
    kind: str,
    _: CurrentUser,
    session: SessionDep,
    include_inactive: Annotated[bool, Query()] = False,
) -> MasterItemList:
    """Objects, not bare strings — the master-data editor needs ids and flags.

    Inactive rows are filtered here, when serving the dropdown, and never when
    resolving a value on an existing entry.
    """
    model = _model(kind)
    stmt = select(model)
    if not include_inactive:
        stmt = stmt.where(model.is_active.is_(True))
    rows = await session.scalars(stmt.order_by(model.sort_order, model.name))
    return MasterItemList(items=[_out(r) for r in rows])


@router.post("/{kind}", response_model=MasterItemOut, status_code=status.HTTP_201_CREATED)
async def create_item(
    kind: str,
    payload: MasterItemCreate,
    actor: SuperAdminUser,
    session: SessionDep,
) -> MasterItemOut:
    model = _model(kind)
    clash = await session.scalar(
        select(model.id).where(func.lower(model.name) == payload.name.lower())
    )
    if clash:
        raise Conflict(f'"{payload.name}" is already on the list', {"name": "duplicate"})

    sort_order = payload.sort_order
    if sort_order is None:
        highest = await session.scalar(select(func.max(model.sort_order)))
        sort_order = (highest or 0) + 1

    row = model(name=payload.name, sort_order=sort_order)
    session.add(row)
    await session.flush()
    await audit.record(
        session,
        actor_id=actor.id,
        action=AuditAction.master_item_created,
        object_type=kind,
        object_id=str(row.id),
        after={"name": row.name},
    )
    await session.commit()
    return _out(row)


@router.put("/{kind}/{item_id}", response_model=MasterItemOut)
async def update_item(
    kind: str,
    item_id: int,
    payload: MasterItemUpdate,
    actor: SuperAdminUser,
    session: SessionDep,
) -> MasterItemOut:
    model = _model(kind)
    row = await session.get(model, item_id)
    if row is None:
        raise NotFound("Master list item not found")

    before = {"name": row.name, "is_active": row.is_active}
    if payload.name is not None and payload.name != row.name:
        clash = await session.scalar(
            select(model.id).where(
                func.lower(model.name) == payload.name.lower(), model.id != row.id
            )
        )
        if clash:
            raise Conflict(
                f'"{payload.name}" is already on the list', {"name": "duplicate"}
            )
        row.name = payload.name
    if payload.is_active is not None:
        row.is_active = payload.is_active
    if payload.sort_order is not None:
        row.sort_order = payload.sort_order

    await audit.record(
        session,
        actor_id=actor.id,
        action=AuditAction.master_item_updated,
        object_type=kind,
        object_id=str(row.id),
        before=before,
        after={"name": row.name, "is_active": row.is_active},
    )
    await session.commit()
    return _out(row)
