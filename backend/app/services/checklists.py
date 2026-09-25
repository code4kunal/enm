"""Checklists and the inspections that fill them in.

A daily inspection and a ten-day service are different jobs, so each work type
carries its own checklist and its own data entry. The checklist is site data —
depots do not run identical sheets — and it is held as rows rather than a blob
so a result can point at the exact line it answers.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
from datetime import date as date_t
from datetime import time as time_t

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import Conflict, NotFound, ValidationError
from app.models.checklist import (
    ChecklistItem,
    ChecklistTemplate,
    InspectionEntry,
    InspectionResult,
)
from app.models.enums import CheckResult, ResponseType, SlotStatus
from app.models.inspection import InspectionSlot
from app.models.master import Vehicle, WorkType
from app.models.user import User
from app.services import odometer as odometer_service
from app.services import tickets as ticket_service


async def inspection_work_types(session: AsyncSession) -> list[WorkType]:
    """The codes that are checklist sweeps rather than register entries."""
    return list(
        (
            await session.scalars(
                select(WorkType)
                .where(
                    WorkType.is_inspection.is_(True), WorkType.is_active.is_(True)
                )
                .order_by(WorkType.sort_order, WorkType.code)
            )
        ).all()
    )


async def get_template(
    session: AsyncSession,
    site_code: str,
    work_type_id: int,
    variant: str | None = None,
    milestone_km: int | None = None,
) -> ChecklistTemplate | None:
    return await session.scalar(
        select(ChecklistTemplate).where(
            ChecklistTemplate.site_code == site_code,
            ChecklistTemplate.work_type_id == work_type_id,
            ChecklistTemplate.variant.is_(None)
            if variant is None
            else ChecklistTemplate.variant == variant,
            ChecklistTemplate.milestone_km.is_(None)
            if milestone_km is None
            else ChecklistTemplate.milestone_km == milestone_km,
        )
    )


async def template_for(
    session: AsyncSession,
    site_code: str,
    work_type_id: int,
    vehicle: Vehicle | None,
    milestone_km: int | None = None,
) -> ChecklistTemplate | None:
    """The checklist this bus takes for this inspection.

    Bus type (`checklist_variant`) first. For docking (P.M), when a KM rung is
    known, prefer the sheet for that mark, then the legacy all-rung sheet for
    the same variant, then the unscoped fallback.
    """
    variant = vehicle.checklist_variant if vehicle else None
    if variant and milestone_km is not None:
        scoped_km = await get_template(
            session, site_code, work_type_id, variant, milestone_km
        )
        if scoped_km is not None and scoped_km.items:
            return scoped_km
    if variant:
        scoped = await get_template(session, site_code, work_type_id, variant)
        if scoped is not None:
            return scoped
    return await get_template(session, site_code, work_type_id)


async def variants_of(
    session: AsyncSession, site_code: str, work_type_id: int
) -> list[ChecklistTemplate]:
    """Every variant-scoped checklist for this inspection.

    Includes docking KM sheets (variant + milestone_km). Ordered by variant,
    then KM so the admin form can group them.
    """
    rows = await session.scalars(
        select(ChecklistTemplate)
        .where(
            ChecklistTemplate.site_code == site_code,
            ChecklistTemplate.work_type_id == work_type_id,
            ChecklistTemplate.variant.is_not(None),
        )
        .order_by(
            ChecklistTemplate.variant,
            ChecklistTemplate.milestone_km.nullsfirst(),
        )
    )
    return list(rows.unique().all())


async def apply_catalogue(session: AsyncSession, site_code: str) -> int:
    """Give a newly onboarded site the standard inspection checklists.

    Migrations 0014–0016 seeded D.I / 10-day / docking supersheets. Docking KM
    sheets (`checklists_docking_km`) are applied here as well so new sites get
    Bus Type × KM forms without a one-off script.

    Never overwrites: a template that already has lines belongs to the depot.
    """
    from app.seeds.checklists_docking_km import CHECKLISTS as CHECKLISTS_DOCKING_KM
    from app.seeds.checklists_v1 import CHECKLISTS as CHECKLISTS_V1
    from app.seeds.checklists_v2 import CHECKLISTS as CHECKLISTS_V2
    from app.seeds.checklists_v3 import CHECKLISTS as CHECKLISTS_V3
    from app.services import site_config as site_config_svc

    config = await site_config_svc.get_or_create(session, site_code)
    categories = set(config.operating_categories or ["bus"])

    CHECKLISTS = [
        {**entry, "category": entry.get("category", "bus")}
        for entry in (
            CHECKLISTS_V1 + CHECKLISTS_V2 + CHECKLISTS_V3 + CHECKLISTS_DOCKING_KM
        )
    ]
    CHECKLISTS = [e for e in CHECKLISTS if e["category"] in categories]

    codes = {t["work_type_code"] for t in CHECKLISTS}
    work_types = {
        wt.code: wt
        for wt in (
            await session.scalars(select(WorkType).where(WorkType.code.in_(codes)))
        ).all()
    } if codes else {}

    added = 0
    for entry in CHECKLISTS:
        work_type = work_types.get(entry["work_type_code"])
        if work_type is None:
            continue
        template = await ensure_template(
            session,
            site_code,
            work_type,
            variant=entry["variant"],
            milestone_km=entry.get("milestone_km"),
        )
        if template.items:
            continue
        template.name = entry["name"]
        for item in entry["items"]:
            template.items.append(
                ChecklistItem(
                    section=item["section"] or "",
                    label=item["label"][:255],
                    sort_order=item["sort_order"],
                    response_type=ResponseType(item["response_type"]),
                    is_required=item["is_required"],
                    chart_key=item["chart_key"],
                )
            )
            added += 1
    await session.flush()
    return added


async def ensure_template(
    session: AsyncSession,
    site_code: str,
    work_type: WorkType,
    variant: str | None = None,
    milestone_km: int | None = None,
) -> ChecklistTemplate:
    """A site always has a template per inspection type, even an empty one.

    Empty is a legitimate state and says so on the form — better than pretending
    a checklist exists by inventing lines the depot never wrote.
    """
    template = await get_template(
        session, site_code, work_type.id, variant, milestone_km
    )
    if template is None:
        template = ChecklistTemplate(
            site_code=site_code,
            variant=variant,
            milestone_km=milestone_km,
            work_type=work_type,
            name=work_type.name,
            items=[],
        )
        session.add(template)
        await session.flush()
    return template


@dataclass(frozen=True, slots=True)
class ChecklistLine:
    """One line as it arrives from the site's checklist editor."""

    section: str
    label: str
    response_type: ResponseType = ResponseType.ok_not_ok
    is_required: bool = True
    #: `tyre_pressure` or `washing` when this line feeds a control chart.
    chart_key: str | None = None


async def replace_items(
    session: AsyncSession,
    template: ChecklistTemplate,
    items: list[ChecklistLine],
) -> None:
    """Replace a checklist wholesale.

    Items already answered by an inspection cannot be deleted — the result
    points at them — so an item that disappears from the new list is retired
    rather than removed.
    """
    incoming = {(line.section.strip(), line.label.strip()) for line in items}
    answered = {
        item_id
        for (item_id,) in (
            await session.execute(select(InspectionResult.item_id).distinct())
        ).all()
    }

    for existing in list(template.items):
        key = (existing.section, existing.label)
        if key in incoming:
            continue
        if existing.id in answered:
            existing.is_active = False
        else:
            template.items.remove(existing)

    by_key = {(i.section, i.label): i for i in template.items}
    for order, line in enumerate(items):
        key = (line.section.strip(), line.label.strip())
        item = by_key.get(key)
        if item is None:
            item = ChecklistItem(template_id=template.id, section=key[0], label=key[1])
            template.items.append(item)
        item.sort_order = order
        item.response_type = line.response_type
        item.is_required = line.is_required
        item.chart_key = line.chart_key
        item.is_active = True

    template.updated_at = datetime.now(UTC)
    await session.flush()


# --- recording an inspection -------------------------------------------------


async def record_inspection(
    session: AsyncSession,
    *,
    site_code: str,
    vehicle: Vehicle,
    work_type: WorkType,
    inspected_on: date_t,
    entry_time: time_t | None,
    done_by: str | None,
    supervisor: str | None,
    odometer_km: int | None,
    remarks: str | None,
    results: list[tuple[str, CheckResult, str | None, str | None]],
    actor: User,
    milestone_km: int | None = None,
) -> InspectionEntry:
    """Write one inspection and discharge the booking it answers.

    Refuses a second inspection of the same kind for the same bus on the same
    day: two sweeps on one night is a double entry, not two jobs.
    """
    if not work_type.is_inspection:
        raise ValidationError(
            f"{work_type.code} is not an inspection",
            {"work_type_id": "not an inspection"},
        )
    if vehicle.site_code != site_code:
        raise NotFound("Vehicle not found on this site")
    if not vehicle.is_active:
        raise ValidationError(
            f"{vehicle.registration_no} is retired",
            {"vehicle_id": "vehicle is retired"},
        )

    duplicate = await session.scalar(
        select(InspectionEntry.id).where(
            InspectionEntry.site_code == site_code,
            InspectionEntry.vehicle_id == vehicle.id,
            InspectionEntry.work_type_id == work_type.id,
            InspectionEntry.inspected_on == inspected_on,
        )
    )
    if duplicate:
        raise Conflict(
            f"{vehicle.registration_no} already has a {work_type.code} recorded "
            f"for {inspected_on.isoformat()}",
            {"inspected_on": "duplicate"},
        )

    # Prefer the docking rung's sheet when a booked slot carries one; otherwise
    # the bus variant alone (D.I / 10-day, or a manual P.M without a plan).
    # Client-supplied milestone_km wins when the mechanic picks the KM sheet
    # explicitly on the form (no booking, or override).
    open_slot = await session.scalar(
        select(InspectionSlot)
        .where(
            InspectionSlot.site_code == site_code,
            InspectionSlot.vehicle_id == vehicle.id,
            InspectionSlot.work_type_id == work_type.id,
            InspectionSlot.status.in_([SlotStatus.scheduled, SlotStatus.missed]),
        )
        .order_by(InspectionSlot.scheduled_on.desc())
        .limit(1)
    )
    slot_km = (
        open_slot.service_plan.milestone_km
        if open_slot is not None and open_slot.service_plan is not None
        else None
    )
    resolved_km = milestone_km if milestone_km is not None else slot_km
    template = await template_for(
        session, site_code, work_type.id, vehicle, milestone_km=resolved_km
    )
    if template is None:
        template = await ensure_template(
            session,
            site_code,
            work_type,
            variant=vehicle.checklist_variant,
            milestone_km=resolved_km,
        )
    by_id = {item.id: item for item in template.items if item.is_active}

    missing = [
        item.label
        for item in by_id.values()
        if item.is_required
        and not any(item_id == item.id for item_id, _, _, _ in results)
    ]
    if missing:
        raise ValidationError(
            f"Answer every required line: {', '.join(missing[:3])}"
            + ("…" if len(missing) > 3 else ""),
            {"results": "required lines unanswered"},
        )

    inspection = InspectionEntry(
        site_code=site_code,
        vehicle_id=vehicle.id,
        work_type_id=work_type.id,
        inspected_on=inspected_on,
        entry_time=entry_time,
        done_by=done_by,
        supervisor=supervisor,
        odometer_km=odometer_km,
        milestone_km=resolved_km,
        remarks=remarks,
        created_by=actor,
        # Initialised explicitly: a freshly added row would otherwise
        # lazy-load an empty `results` during serialization, outside the async
        # context that is allowed to do IO.
        results=[],
    )
    for item_id, result, value, remark in results:
        inspection.results.append(
            InspectionResult(
                item_id=item_id, result=result, value=value, remark=remark
            )
        )

    session.add(inspection)
    await session.flush()

    # Populates the relationship in memory (inspection.work_type_id alone
    # doesn't) so create_ticket_for_inspection_result below can read
    # result.inspection.work_type.code without a lazy load outside the
    # async context.
    inspection.work_type = work_type
    for result in inspection.results:
        if result.result is CheckResult.not_ok:
            await ticket_service.create_ticket_for_inspection_result(
                session, result=result, creator=actor
            )

    # An inspection reads the odometer on the way past; it never runs backwards.
    if odometer_km is not None and (
        vehicle.odometer_updated_at is None or odometer_km >= vehicle.odometer_km
    ):
        odometer_service.record_reading(
            session,
            vehicle,
            odometer_km=odometer_km,
            recorded_at=datetime.combine(inspected_on, time_t(0, 0), tzinfo=UTC),
            source=f"inspection {work_type.code}",
        )

    slot = open_slot
    if slot is not None:
        slot.status = SlotStatus.done
        slot.completed_on = inspected_on
        slot.updated_at = datetime.now(UTC)
        inspection.slot_id = slot.id
        if slot.service_plan_id is not None:
            inspection.service_plan_id = slot.service_plan_id

    await session.flush()
    return inspection


async def record_inspection_batch(
    session: AsyncSession,
    *,
    site_code: str,
    work_type: WorkType,
    inspected_on: date_t,
    entry_time: time_t | None,
    supervisor: str | None,
    items: list[
        tuple[str, int | None, int | None, str | None, str | None, list[tuple[str, CheckResult, str | None, str | None]]]
    ],
    actor: User,
) -> list[InspectionEntry]:
    """Multiple Bus Inspection: every vehicle in one transaction — a bad
    vehicle anywhere in the list fails the whole batch, since a partial
    submission would misreport as "not yet inspected" for the buses that
    should have recorded but didn't reach the request at all."""
    out: list[InspectionEntry] = []
    for vehicle_id, odometer_km, milestone_km, done_by, remarks, results in items:
        vehicle = await session.get(Vehicle, vehicle_id)
        if vehicle is None:
            raise NotFound(f"Vehicle {vehicle_id} not found")
        inspection = await record_inspection(
            session,
            site_code=site_code,
            vehicle=vehicle,
            work_type=work_type,
            inspected_on=inspected_on,
            entry_time=entry_time,
            done_by=done_by,
            supervisor=supervisor,
            odometer_km=odometer_km,
            remarks=remarks,
            results=results,
            actor=actor,
            milestone_km=milestone_km,
        )
        out.append(inspection)
    return out


async def last_done(
    session: AsyncSession, site_code: str, work_type_id: int
) -> dict[str, date_t]:
    """The most recent date each bus had this inspection."""
    from sqlalchemy import func

    rows = await session.execute(
        select(InspectionEntry.vehicle_id, func.max(InspectionEntry.inspected_on))
        .where(
            InspectionEntry.site_code == site_code,
            InspectionEntry.work_type_id == work_type_id,
        )
        .group_by(InspectionEntry.vehicle_id)
    )
    return dict(rows.all())
