"""Fitted units: the Unit Failure Statement and the bus history card.

One dataset seen two ways. A `FittedUnit` row is a component's stay on a bus —
fitted on a date at an odometer, removed on another. The statement is every
stay that ended in a month, across the fleet. The history card is the same
events for one bus, pivoted onto a unit × month grid.

Neither is stored: both are read off the stays, so a correction to a removal
date shows up in both without a rebuild, and the two can never disagree.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date as date_t

from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import NotFound, ValidationError
from app.models.master import Vehicle
from app.models.report import FittedUnit, UnitType
from app.models.user import User

#: A history card runs a year plus the month it opens on, which is how the
#: depot's own card is laid out: Dec, then Jan…Dec.
HISTORY_MONTHS = 13


def month_bounds(month: str) -> tuple[date_t, date_t]:
    """`yyyy-MM` to the first and last day it covers."""
    try:
        year, mon = (int(part) for part in month.split("-", 1))
        first = date_t(year, mon, 1)
    except (ValueError, TypeError) as exc:
        raise ValidationError(
            "`month` must be yyyy-MM", {"month": "expected yyyy-MM"}
        ) from exc
    last = date_t(year + (mon == 12), (mon % 12) + 1, 1)
    return first, date_t.fromordinal(last.toordinal() - 1)


def shift_month(month: str, by: int) -> str:
    year, mon = (int(part) for part in month.split("-", 1))
    index = year * 12 + (mon - 1) + by
    return f"{index // 12:04d}-{index % 12 + 1:02d}"


def month_of(day: date_t) -> str:
    return f"{day.year:04d}-{day.month:02d}"


# --- recording a unit --------------------------------------------------------


def _reading(vehicle: Vehicle) -> int | None:
    """The bus's odometer, or None when it has never actually been read.

    The column is not nullable and sits at 0 until a sync lands, so 0 has to be
    read as "unknown" rather than as a bus that has not moved — a unit fitted
    at 0 and removed at 140,000 would otherwise claim a life it never had.
    """
    return vehicle.odometer_km if vehicle.odometer_updated_at else None


async def fit_unit(
    session: AsyncSession,
    *,
    site_code: str,
    vehicle: Vehicle,
    unit_type_id: int,
    fitted_on: date_t,
    entry_id: str | None = None,
    unit_no: str | None = None,
    fitted_odometer_km: int | None = None,
    remarks: str | None = None,
    actor: User,
) -> FittedUnit:
    """Put a component on a bus.

    The odometer defaults to whatever the fleet last read for that bus, because
    a unit fitted today started its life at today's reading — asking a mechanic
    to retype a number the system already holds is how the two drift apart.
    """
    unit_type = await session.get(UnitType, unit_type_id)
    if unit_type is None:
        raise NotFound("Unit type not found")

    open_stay = await session.scalar(
        select(FittedUnit).where(
            FittedUnit.vehicle_id == vehicle.id,
            FittedUnit.unit_type_id == unit_type_id,
            FittedUnit.removed_on.is_(None),
        )
    )
    if open_stay is not None:
        raise ValidationError(
            f"{unit_type.name} is already fitted to {vehicle.registration_no}. "
            "Record its removal first.",
            {"unit_type_id": "already fitted"},
        )

    stay = FittedUnit(
        site_code=site_code,
        vehicle_id=vehicle.id,
        unit_type_id=unit_type_id,
        entry_id=entry_id,
        unit_no=unit_no or None,
        fitted_on=fitted_on,
        fitted_odometer_km=(
            fitted_odometer_km
            if fitted_odometer_km is not None
            else _reading(vehicle)
        ),
        remarks=remarks or None,
        updated_by_id=actor.id,
        vehicle=vehicle,
        unit_type=unit_type,
    )
    session.add(stay)
    await session.flush()
    return stay


async def remove_unit(
    session: AsyncSession,
    stay: FittedUnit,
    *,
    removed_on: date_t,
    removed_odometer_km: int | None = None,
    removal_reason: str | None = None,
    remarks: str | None = None,
    actor: User,
) -> FittedUnit:
    """Take it off, which is what puts it on the failure statement."""
    if removed_on < stay.fitted_on:
        raise ValidationError(
            "A unit cannot come off before it went on",
            {"removed_on": "before fitted_on"},
        )

    stay.removed_on = removed_on
    stay.removed_odometer_km = (
        removed_odometer_km
        if removed_odometer_km is not None
        else _reading(stay.vehicle)
    )
    if removal_reason is not None:
        stay.removal_reason = removal_reason or None
    if remarks is not None:
        stay.remarks = remarks or None
    stay.updated_by_id = actor.id
    await session.flush()
    return stay


async def fitted_to(
    session: AsyncSession, site_code: str, vehicle_id: str
) -> list[FittedUnit]:
    """What is on a bus right now, in the card's order."""
    rows = await session.scalars(
        select(FittedUnit)
        .join(UnitType, UnitType.id == FittedUnit.unit_type_id)
        .where(
            FittedUnit.site_code == site_code,
            FittedUnit.vehicle_id == vehicle_id,
            FittedUnit.removed_on.is_(None),
        )
        .order_by(UnitType.sort_order, UnitType.name)
    )
    return list(rows.unique().all())


async def by_entries(
    session: AsyncSession, site_code: str, entry_ids: list[str]
) -> list[FittedUnit]:
    """Every unit fit alongside any of these entries, for the register list
    to show inline without a call per row."""
    if not entry_ids:
        return []
    rows = await session.scalars(
        select(FittedUnit)
        .join(UnitType, UnitType.id == FittedUnit.unit_type_id)
        .where(
            FittedUnit.site_code == site_code,
            FittedUnit.entry_id.in_(entry_ids),
        )
        .order_by(UnitType.sort_order, UnitType.name)
    )
    return list(rows.unique().all())


# --- the Unit Failure Statement ----------------------------------------------


async def statement(
    session: AsyncSession, site_code: str, month: str
) -> list[FittedUnit]:
    """Every unit that came off in a month, in the sheet's own order.

    Grouped by unit type because the paper statement is: the units down the
    page, and under each the buses it came off. A month with no removals is an
    empty statement, which is a real answer.
    """
    first, last = month_bounds(month)
    rows = await session.scalars(
        select(FittedUnit)
        .join(UnitType, UnitType.id == FittedUnit.unit_type_id)
        .join(Vehicle, Vehicle.id == FittedUnit.vehicle_id)
        .where(
            FittedUnit.site_code == site_code,
            FittedUnit.removed_on >= first,
            FittedUnit.removed_on <= last,
        )
        .order_by(
            UnitType.sort_order,
            UnitType.name,
            Vehicle.registration_no,
            FittedUnit.removed_on,
        )
    )
    return list(rows.unique().all())


async def hv_batteries_replaced(
    session: AsyncSession, site_code: str, day: date_t
) -> int:
    """DMR line 30, now that removals are recorded.

    Counts HV packs that came off that day. This is why `is_hv_battery` exists
    on the unit master — the line used to be typed in because nothing observed
    it.
    """
    rows = await session.scalars(
        select(FittedUnit.id)
        .join(UnitType, UnitType.id == FittedUnit.unit_type_id)
        .where(
            FittedUnit.site_code == site_code,
            FittedUnit.removed_on == day,
            UnitType.is_hv_battery.is_(True),
        )
    )
    return len(list(rows.all()))


# --- the bus history card ----------------------------------------------------


@dataclass(slots=True)
class HistoryEvent:
    """What happened to one unit in one month."""

    #: "fitted", "removed", or "replaced" when both happened in the month.
    kind: str
    #: What the block shows: the day, or the days, it happened on.
    label: str
    unit_no: str = ""
    reason: str = ""
    kms_covered: int | None = None


@dataclass(slots=True)
class HistoryRow:
    unit_type_id: int
    unit_name: str
    #: One per month, in `months` order. None where nothing happened.
    cells: list[HistoryEvent | None]
    #: True when the unit is on the bus as at the end of the window.
    fitted_now: bool = False


@dataclass(slots=True)
class History:
    site_code: str
    vehicle_id: str
    registration_no: str
    months: list[str]
    rows: list[HistoryRow]

    @property
    def events(self) -> int:
        return sum(1 for row in self.rows for cell in row.cells if cell)


async def history(
    session: AsyncSession,
    *,
    site_code: str,
    vehicle: Vehicle,
    to_month: str,
    months: int = HISTORY_MONTHS,
) -> History:
    """One bus's card: every unit down the side, the months across.

    Every unit type is a row whether or not it was ever touched. A card with
    forty empty rows is the point — it is the record of what has *not* been
    changed as much as what has.
    """
    if months < 1:
        raise ValidationError("`months` must be at least 1", {"months": "too few"})
    window = [shift_month(to_month, offset) for offset in range(1 - months, 1)]
    first, _ = month_bounds(window[0])
    _, last = month_bounds(window[-1])

    types = list(
        (
            await session.scalars(
                select(UnitType)
                .where(UnitType.is_active.is_(True))
                .order_by(UnitType.sort_order, UnitType.name)
            )
        ).all()
    )

    stays = list(
        (
            await session.scalars(
                select(FittedUnit).where(
                    FittedUnit.site_code == site_code,
                    FittedUnit.vehicle_id == vehicle.id,
                    # A stay is relevant if either end lands in the window, or
                    # if it spans the whole of it.
                    or_(
                        FittedUnit.fitted_on <= last,
                        FittedUnit.removed_on.is_(None),
                    ),
                )
            )
        )
        .unique()
        .all()
    )

    index = {month: position for position, month in enumerate(window)}
    cells: dict[tuple[int, int], HistoryEvent] = {}
    fitted_now: set[int] = set()

    for stay in stays:
        if stay.removed_on is None and stay.fitted_on <= last:
            fitted_now.add(stay.unit_type_id)

        for day, kind in (
            (stay.fitted_on, "fitted"),
            (stay.removed_on, "removed"),
        ):
            if day is None or not (first <= day <= last):
                continue
            position = index[month_of(day)]
            key = (stay.unit_type_id, position)
            existing = cells.get(key)
            if existing is None:
                cells[key] = HistoryEvent(
                    kind=kind,
                    label=f"{day.day:02d}",
                    unit_no=stay.unit_no or "",
                    reason=stay.removal_reason or "",
                    kms_covered=stay.kms_covered,
                )
                continue
            # A unit off and back on inside one month is one block on paper, and
            # "replaced" is what the depot writes in it.
            labels = sorted({existing.label, f"{day.day:02d}"})
            cells[key] = HistoryEvent(
                kind="replaced",
                label="/".join(labels),
                unit_no=stay.unit_no or existing.unit_no,
                reason=stay.removal_reason or existing.reason,
                kms_covered=(
                    stay.kms_covered
                    if kind == "removed"
                    else existing.kms_covered
                ),
            )

    return History(
        site_code=site_code,
        vehicle_id=vehicle.id,
        registration_no=vehicle.registration_no,
        months=window,
        rows=[
            HistoryRow(
                unit_type_id=unit_type.id,
                unit_name=unit_type.name,
                cells=[
                    cells.get((unit_type.id, position))
                    for position in range(len(window))
                ],
                fitted_now=unit_type.id in fitted_now,
            )
            for unit_type in types
        ],
    )
