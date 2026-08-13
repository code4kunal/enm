"""The Daily Maintenance Report.

Thirty-one parameters down the page, one column per day — the shape the depot
already sends on. Most lines are derived from the registers; eleven are not
observable anywhere in the system and are entered once a day.

Deriving beats typing for a reason beyond convenience: the DMR as it is kept
today reports 57 daily inspections every single day, while the snag report
records a fraction of that. A derived line shows what actually happened.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
from datetime import date as date_t
from decimal import Decimal

from sqlalchemy import func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.checklist import InspectionEntry
from app.models.entry import BreakdownEntry, CoolantEntry, Entry
from app.models.enums import DefectCategory, Register
from app.models.master import DefectType, Vehicle, WorkType
from app.models.report import DmrDay, OffRoadCase
from app.models.user import User

#: A bus off the road this long is reported separately.
HELD_DAYS = 3


@dataclass(frozen=True, slots=True)
class Parameter:
    """One line of the report."""

    number: int
    label: str
    key: str
    #: False when nothing in the system observes it, so it has to be entered.
    derived: bool = True
    #: Rendered with one decimal rather than as a count.
    decimal: bool = False


#: The report, in the order the depot's own sheet reads. `key` is the column on
#: `DmrDay` and the field in the API payload.
PARAMETERS: list[Parameter] = [
    Parameter(1, "Total fleet", "total_fleet"),
    Parameter(2, "Fleet size: Nos of buses on-road", "on_road", derived=False),
    Parameter(3, "Nos of spare buses (OK buses)", "spare", derived=False),
    Parameter(4, "Nos of defective buses in depot", "defective_in_depot"),
    Parameter(5, "Mechanical defects", "defects_mechanical"),
    Parameter(6, "Body defects (accidents)", "defects_body"),
    Parameter(7, "Electrical defects including HV battery", "defects_electrical"),
    Parameter(8, "AC defects", "defects_ac"),
    Parameter(9, "ITS defect", "defects_its"),
    Parameter(10, "Under warranty defects", "under_warranty", derived=False),
    Parameter(11, "RTO passing", "rto_passing", derived=False),
    Parameter(
        12, f"Buses held in depot for more than {HELD_DAYS} days",
        "held_over_three_days",
    ),
    Parameter(13, "Daily breakdowns", "breakdowns"),
    Parameter(14, "Daily breakdowns (Mech)", "breakdowns_mechanical"),
    Parameter(15, "Daily breakdowns (Electrical)", "breakdowns_electrical"),
    Parameter(16, "Daily breakdowns (Tyre)", "breakdowns_tyre"),
    Parameter(17, "Daily breakdowns (AC)", "breakdowns_ac"),
    Parameter(18, "Daily breakdowns (ITS)", "breakdowns_its"),
    Parameter(19, "Loss of Kms due to breakdowns", "loss_km", decimal=True),
    Parameter(20, "Daily driver complaints", "driver_complaints"),
    Parameter(21, "Daily maintenance attended buses (DI)", "daily_inspections"),
    Parameter(22, "Periodic PM schedule attended buses (10 days)", "periodic_pm"),
    Parameter(23, "Docking attended buses", "dockings"),
    Parameter(
        24, "Buses attended for high energy consumption (kWh/km)",
        "high_energy_consumption", derived=False,
    ),
    Parameter(25, "Coolant consumption (topping)", "coolant_litres", decimal=True),
    Parameter(26, "Nos of buses attended for deep cleaning", "deep_cleaning", derived=False),
    Parameter(27, "Nos of buses washed & cleaned", "washed_cleaned", derived=False),
    Parameter(
        28, "Cases of accidents / incidents within depot premises",
        "depot_accidents", derived=False,
    ),
    Parameter(29, "Nos of tyres scrapped", "tyres_scrapped", derived=False),
    Parameter(30, "Nos of HV batteries replaced", "hv_batteries_replaced", derived=False),
    Parameter(31, "Nos of buses reported for body damages", "body_damages", derived=False),
]

DERIVED_KEYS = tuple(p.key for p in PARAMETERS if p.derived)
ENTERED_KEYS = tuple(p.key for p in PARAMETERS if not p.derived)


# --- deriving ---------------------------------------------------------------


async def _breakdowns_by_category(
    session: AsyncSession, site_code: str, day: date_t
) -> dict[DefectCategory, int]:
    """Breakdowns that day, split by the defect type's category.

    A breakdown with no defect type recorded counts to the total but to no
    category — better an unsplit total than a wrong split.
    """
    rows = await session.execute(
        select(DefectType.category, func.count())
        .select_from(Entry)
        .join(BreakdownEntry, BreakdownEntry.entry_id == Entry.id)
        .join(
            DefectType, DefectType.id == BreakdownEntry.defect_type_id, isouter=True
        )
        .where(
            Entry.site_code == site_code,
            Entry.entry_date == day,
            Entry.register == Register.breakdown,
        )
        .group_by(DefectType.category)
    )
    return {c: n for c, n in rows.all() if c is not None}


async def off_road_on(
    session: AsyncSession, site_code: str, day: date_t
) -> list[OffRoadCase]:
    """The buses that were off the road on that date.

    A case, not a daily row: one problem being worked on, open from the day the
    bus went down until the day it ran again. That is exactly what the depot's
    own off-road sheet restates each morning.
    """
    rows = await session.scalars(
        select(OffRoadCase).where(
            OffRoadCase.site_code == site_code,
            OffRoadCase.off_road_since <= day,
            or_(
                OffRoadCase.returned_on.is_(None),
                OffRoadCase.returned_on > day,
            ),
        )
    )
    return list(rows.unique().all())


async def _count_inspections(
    session: AsyncSession, site_code: str, day: date_t, codes: tuple[str, ...]
) -> int:
    return int(
        await session.scalar(
            select(func.count())
            .select_from(InspectionEntry)
            .join(WorkType, WorkType.id == InspectionEntry.work_type_id)
            .where(
                InspectionEntry.site_code == site_code,
                InspectionEntry.inspected_on == day,
                func.upper(WorkType.code).in_(codes),
            )
        )
        or 0
    )


async def derive(
    session: AsyncSession, site_code: str, day: date_t
) -> dict[str, object]:
    """Every line the registers can answer for one day."""
    total_fleet = int(
        await session.scalar(
            select(func.count())
            .select_from(Vehicle)
            .where(Vehicle.site_code == site_code, Vehicle.is_active.is_(True))
        )
        or 0
    )

    by_register = dict(
        (
            await session.execute(
                select(Entry.register, func.count())
                .where(Entry.site_code == site_code, Entry.entry_date == day)
                .group_by(Entry.register)
            )
        ).all()
    )

    breakdown_split = await _breakdowns_by_category(session, site_code, day)
    off_road = await off_road_on(session, site_code, day)
    defect_split: dict[DefectCategory, int] = {}
    for case in off_road:
        defect_split[case.category] = defect_split.get(case.category, 0) + 1

    loss_km = await session.scalar(
        select(func.coalesce(func.sum(BreakdownEntry.loss_km), 0))
        .select_from(Entry)
        .join(BreakdownEntry, BreakdownEntry.entry_id == Entry.id)
        .where(Entry.site_code == site_code, Entry.entry_date == day)
    )
    coolant = await session.scalar(
        select(
            func.coalesce(
                func.sum(
                    func.coalesce(CoolantEntry.bcs_litres, 0)
                    + func.coalesce(CoolantEntry.tcs_litres, 0)
                ),
                0,
            )
        )
        .select_from(Entry)
        .join(CoolantEntry, CoolantEntry.entry_id == Entry.id)
        .where(Entry.site_code == site_code, Entry.entry_date == day)
    )

    return {
        "total_fleet": total_fleet,
        "defective_in_depot": len(off_road),
        "defects_mechanical": defect_split.get(DefectCategory.mechanical, 0),
        "defects_body": defect_split.get(DefectCategory.body, 0),
        "defects_electrical": defect_split.get(DefectCategory.electrical, 0),
        "defects_ac": defect_split.get(DefectCategory.ac, 0),
        "defects_its": defect_split.get(DefectCategory.its, 0),
        "held_over_three_days": sum(
            1 for case in off_road if case.days_down_on(day) >= HELD_DAYS
        ),
        "breakdowns": by_register.get(Register.breakdown, 0),
        "breakdowns_mechanical": breakdown_split.get(DefectCategory.mechanical, 0),
        "breakdowns_electrical": breakdown_split.get(DefectCategory.electrical, 0),
        "breakdowns_tyre": breakdown_split.get(DefectCategory.tyre, 0),
        "breakdowns_ac": breakdown_split.get(DefectCategory.ac, 0),
        "breakdowns_its": breakdown_split.get(DefectCategory.its, 0),
        "loss_km": Decimal(loss_km or 0),
        "driver_complaints": by_register.get(Register.driver_complaint, 0),
        "daily_inspections": await _count_inspections(
            session, site_code, day, ("D.I", "DI")
        ),
        "periodic_pm": await _count_inspections(
            session, site_code, day, ("10 DAYS SERVICE",)
        ),
        "dockings": await _count_inspections(session, site_code, day, ("P.M", "PM")),
        "coolant_litres": Decimal(coolant or 0),
    }


# --- reading and writing ----------------------------------------------------


async def get_day(
    session: AsyncSession, site_code: str, day: date_t
) -> DmrDay | None:
    return await session.scalar(
        select(DmrDay).where(
            DmrDay.site_code == site_code, DmrDay.report_date == day
        )
    )


async def ensure_day(session: AsyncSession, site_code: str, day: date_t) -> DmrDay:
    row = await get_day(session, site_code, day)
    if row is None:
        row = DmrDay(site_code=site_code, report_date=day)
        session.add(row)
        await session.flush()
    return row


async def compose(
    session: AsyncSession, site_code: str, day: date_t
) -> tuple[dict[str, object], bool]:
    """The full day: derived plus entered. Returns (values, is_snapshot).

    A snapshotted day returns what was reported. An open day recomputes, so a
    correction to yesterday's register shows up until the day is frozen.
    """
    row = await get_day(session, site_code, day)
    snapshot = row is not None and row.generated_at is not None

    values: dict[str, object] = {}
    if snapshot:
        for key in DERIVED_KEYS:
            values[key] = getattr(row, key)
    else:
        values.update(await derive(session, site_code, day))

    for key in ENTERED_KEYS:
        values[key] = getattr(row, key) if row is not None else None
    values["notes"] = row.notes if row is not None else ""
    return values, snapshot


async def snapshot(
    session: AsyncSession, site_code: str, day: date_t
) -> DmrDay:
    """Freeze the derived lines as reported for that day."""
    row = await ensure_day(session, site_code, day)
    for key, value in (await derive(session, site_code, day)).items():
        setattr(row, key, value)
    row.generated_at = datetime.now(UTC)
    await session.flush()
    return row


async def save_entered(
    session: AsyncSession,
    site_code: str,
    day: date_t,
    values: dict[str, object],
    actor: User,
) -> DmrDay:
    """Store the eleven lines nothing else observes."""
    row = await ensure_day(session, site_code, day)
    for key in ENTERED_KEYS:
        if key in values:
            setattr(row, key, values[key])
    if "notes" in values:
        row.notes = str(values["notes"] or "")
    row.updated_at = datetime.now(UTC)
    row.updated_by_id = actor.id
    await session.flush()
    return row


async def snapshot_all_sites() -> int:
    """The nightly freeze, run after the schedule generator."""
    import logging

    from app.models.master import Site
    from app.services.common import today_ist

    logger = logging.getLogger("enm.dmr")
    from app.db import SessionLocal

    day = today_ist()
    frozen = 0
    async with SessionLocal() as session:
        codes = list(
            (
                await session.scalars(select(Site.code).where(Site.is_active.is_(True)))
            ).all()
        )

    for code in codes:
        async with SessionLocal() as session:
            try:
                await snapshot(session, code, day)
                await session.commit()
                frozen += 1
            except Exception:  # noqa: BLE001 - one site must not stop the rest
                await session.rollback()
                logger.exception("DMR snapshot failed for %s", code)
    return frozen
