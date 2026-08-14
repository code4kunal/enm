from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Query, status
from sqlalchemy import func, select

from app.deps import CurrentUser, SessionDep, assert_site_access, assert_site_admin
from app.errors import NotFound
from app.models.checklist import ChecklistTemplate, InspectionEntry
from app.models.enums import AuditAction
from app.models.master import Vehicle, WorkType
from app.schemas.checklist import (
    ChecklistItemIO,
    ChecklistList,
    ChecklistOut,
    ChecklistUpdate,
    InspectionCreate,
    InspectionList,
    InspectionOut,
    ResultOut,
)
from app.services import audit, checklists
from app.services.common import today_ist

router = APIRouter(tags=["checklists"])


def _checklist_out(template: ChecklistTemplate) -> ChecklistOut:
    work_type = template.work_type
    return ChecklistOut(
        id=template.id,
        site_code=template.site_code,
        work_type_id=template.work_type_id,
        work_type_code=work_type.code if work_type else "",
        work_type_name=work_type.name if work_type else "",
        name=template.name,
        variant=template.variant,
        is_active=template.is_active,
        items=[
            ChecklistItemIO(
                id=item.id,
                section=item.section,
                label=item.label,
                sort_order=item.sort_order,
                response_type=item.response_type,
                is_required=item.is_required,
                is_active=item.is_active,
                chart_key=item.chart_key,
            )
            for item in template.items
            if item.is_active
        ],
        updated_at=template.updated_at,
    )


def _inspection_out(inspection: InspectionEntry) -> InspectionOut:
    return InspectionOut(
        id=inspection.id,
        site_code=inspection.site_code,
        vehicle_id=inspection.vehicle_id,
        registration_no=(
            inspection.vehicle.registration_no if inspection.vehicle else ""
        ),
        work_type_id=inspection.work_type_id,
        work_type_code=inspection.work_type.code if inspection.work_type else "",
        work_type_name=inspection.work_type.name if inspection.work_type else "",
        inspected_on=inspection.inspected_on,
        entry_time=inspection.entry_time,
        done_by=inspection.done_by,
        supervisor=inspection.supervisor,
        odometer_km=inspection.odometer_km,
        remarks=inspection.remarks,
        slot_id=inspection.slot_id,
        failed_count=len(inspection.failed),
        results=[
            ResultOut(
                item_id=r.item_id,
                section=r.item.section if r.item else "",
                label=r.item.label if r.item else "",
                result=r.result,
                value=r.value,
                remark=r.remark,
            )
            for r in inspection.results
        ],
        created_by=inspection.created_by.name if inspection.created_by else "",
        created_at=inspection.created_at,
    )


# --- checklists ---------------------------------------------------------------


@router.get("/sites/{code}/checklists", response_model=ChecklistList)
async def list_checklists(
    code: str, user: CurrentUser, session: SessionDep
) -> ChecklistList:
    """One checklist per inspection type, created empty on first read.

    Readable by anyone who can reach the site — a mechanic filling one in is
    not an administrator.
    """
    site_code = assert_site_access(user, code)
    out: list[ChecklistOut] = []
    for work_type in await checklists.inspection_work_types(session):
        # The unscoped one always exists, so a site that has written nothing
        # still sees the empty form rather than nothing at all.
        out.append(
            _checklist_out(
                await checklists.ensure_template(session, site_code, work_type)
            )
        )
        # Plus any per-variant lists the site keeps. The client picks between
        # them by the bus in front of the mechanic.
        for template in await checklists.variants_of(
            session, site_code, work_type.id
        ):
            out.append(_checklist_out(template))
    await session.commit()
    return ChecklistList(items=out)


@router.put("/sites/{code}/checklists/{work_type_id}", response_model=ChecklistOut)
async def replace_checklist(
    code: str,
    work_type_id: int,
    payload: ChecklistUpdate,
    user: CurrentUser,
    session: SessionDep,
) -> ChecklistOut:
    """Replace a checklist wholesale.

    A line that has already been answered is retired rather than deleted, so
    past inspections keep reading correctly.
    """
    site_code = assert_site_admin(user, code)
    work_type = await session.get(WorkType, work_type_id)
    if work_type is None or not work_type.is_inspection:
        raise NotFound("Inspection type not found")

    template = await checklists.ensure_template(
        session, site_code, work_type, variant=payload.variant
    )
    if payload.name is not None:
        template.name = payload.name
    if payload.is_active is not None:
        template.is_active = payload.is_active

    await checklists.replace_items(
        session,
        template,
        [
            checklists.ChecklistLine(
                section=i.section,
                label=i.label,
                response_type=i.response_type,
                is_required=i.is_required,
                chart_key=i.chart_key.value if i.chart_key else None,
            )
            for i in payload.items
        ],
    )
    await audit.record(
        session,
        actor_id=user.id,
        action=AuditAction.checklist_updated,
        object_type="checklist",
        object_id=template.id,
        after={"items": len(payload.items)},
    )
    await session.commit()
    await session.refresh(template)
    return _checklist_out(template)


# --- inspections --------------------------------------------------------------


@router.post(
    "/sites/{code}/inspections",
    response_model=InspectionOut,
    status_code=status.HTTP_201_CREATED,
)
async def record_inspection(
    code: str, payload: InspectionCreate, user: CurrentUser, session: SessionDep
) -> InspectionOut:
    """Record one completed inspection, and discharge its booking."""
    site_code = assert_site_access(user, code)

    vehicle = await session.get(Vehicle, payload.vehicle_id)
    if vehicle is None:
        raise NotFound("Vehicle not found")
    work_type = await session.get(WorkType, payload.work_type_id)
    if work_type is None:
        raise NotFound("Inspection type not found")

    inspection = await checklists.record_inspection(
        session,
        site_code=site_code,
        vehicle=vehicle,
        work_type=work_type,
        inspected_on=payload.inspected_on,
        entry_time=payload.entry_time,
        done_by=payload.done_by,
        supervisor=payload.supervisor,
        odometer_km=payload.odometer_km,
        remarks=payload.remarks,
        results=[
            (r.item_id, r.result, r.value, r.remark) for r in payload.results
        ],
        actor=user,
    )
    await audit.record(
        session,
        actor_id=user.id,
        action=AuditAction.inspection_recorded,
        object_type="inspection",
        object_id=inspection.id,
        after={
            "vehicle": vehicle.registration_no,
            "work_type": work_type.code,
            "failed": len(inspection.failed),
        },
    )
    await session.commit()
    await session.refresh(inspection)
    return _inspection_out(inspection)


@router.get("/sites/{code}/inspections", response_model=InspectionList)
async def list_inspections(
    code: str,
    user: CurrentUser,
    session: SessionDep,
    work_type_id: Annotated[int | None, Query()] = None,
    date_from: Annotated[str | None, Query(alias="from")] = None,
    date_to: Annotated[str | None, Query(alias="to")] = None,
    page_size: Annotated[int, Query(ge=1, le=200)] = 50,
) -> InspectionList:
    site_code = assert_site_access(user, code)
    stmt = select(InspectionEntry).where(InspectionEntry.site_code == site_code)
    if work_type_id is not None:
        stmt = stmt.where(InspectionEntry.work_type_id == work_type_id)
    if date_from:
        stmt = stmt.where(InspectionEntry.inspected_on >= date_from)
    if date_to:
        stmt = stmt.where(InspectionEntry.inspected_on <= date_to)

    total = int(
        await session.scalar(
            select(func.count()).select_from(
                stmt.with_only_columns(InspectionEntry.id).subquery()
            )
        )
        or 0
    )
    rows = (
        await session.scalars(
            stmt.order_by(
                InspectionEntry.inspected_on.desc(), InspectionEntry.created_at.desc()
            ).limit(page_size)
        )
    ).unique().all()
    return InspectionList(
        items=[_inspection_out(r) for r in rows], total=total
    )


@router.get("/sites/{code}/inspections/today", response_model=InspectionList)
async def todays_inspections(
    code: str, user: CurrentUser, session: SessionDep
) -> InspectionList:
    """What has already been done today — the Home feed for inspections."""
    site_code = assert_site_access(user, code)
    today = today_ist()
    rows = (
        await session.scalars(
            select(InspectionEntry)
            .where(
                InspectionEntry.site_code == site_code,
                InspectionEntry.inspected_on == today,
            )
            .order_by(InspectionEntry.created_at.desc())
        )
    ).unique().all()
    return InspectionList(
        items=[_inspection_out(r) for r in rows], total=len(rows)
    )
