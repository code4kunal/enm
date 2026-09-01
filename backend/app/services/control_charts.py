"""Annexure-IV control charts.

Six grids, all the same shape: the fleet down the side, the days across the top,
one mark per bus per day. That shape is the point — a month of one thing for
every bus at once is how a gap becomes visible, which no per-entry list does.

The depot's own instructions carry the colour rules, and they are what the marks
below encode: PM days shaded on the coolant and energy charts, docking days red
on the PM chart, breakdowns red on the complaints chart.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import date as date_t
from datetime import timedelta
from decimal import Decimal

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import ValidationError
from app.models.checklist import (
    ChecklistItem,
    ChecklistTemplate,
    InspectionEntry,
    InspectionResult,
)
from app.models.entry import BreakdownEntry, CoolantEntry, DriverComplaintEntry, Entry
from app.models.enums import CheckResult, Register, StrEnum
from app.models.master import Vehicle, WorkType

#: A grid wider than this stops being readable and starts being a download.
MAX_CHART_DAYS = 31

#: The two `WorkType.code`s that route to the `pm_schedule` register and that
#: `di_inspection`/`ten_day_service` each isolate — must match
#: `inspection_plans.DEFAULT_INSPECTION_PLANS` exactly, it's the same string
#: the nightly rotation uses to name the plan.
DI_CODE = "D.I"
TEN_DAY_CODE = "10 DAYS SERVICE"


class ChartKind(StrEnum):
    coolant_topping = "coolantTopping"
    energy = "energy"
    pm_schedule = "pmSchedule"
    complaints_breakdowns = "complaintsBreakdowns"
    tyre_pressure = "tyrePressure"
    bus_washing = "busWashing"
    #: D.I and the 10-day service, split out of `pm_schedule` — a tick per
    #: bus per day rather than the merged chart's abbreviated work-type code.
    di_inspection = "diInspection"
    ten_day_service = "tenDayService"
    #: Driver complaints and breakdowns, split out of `complaints_breakdowns`
    #: — the merged chart let a breakdown silently overwrite that day's
    #: complaint count, so splitting them is also what fixes that.
    driver_complaints = "driverComplaints"
    breakdowns = "breakdowns"


class CellMark(StrEnum):
    """What the depot colours a block. Plain is the common case."""

    plain = "plain"
    #: A PM was attended that day — shaded on the coolant and energy charts.
    pm = "pm"
    #: A docking, which the PM chart marks red.
    docking = "docking"
    #: A breakdown, which the complaints chart marks red.
    breakdown = "breakdown"


@dataclass(frozen=True, slots=True)
class ChartSpec:
    kind: ChartKind
    title: str
    #: What a filled block means, shown under the grid.
    legend: str
    unit: str = ""
    #: False when nothing in the system can answer it yet.
    available: bool = True
    unavailable_reason: str = ""


CHARTS: list[ChartSpec] = [
    ChartSpec(
        ChartKind.coolant_topping,
        "Coolant topping",
        "Litres topped up. Shaded where a PM was attended that day.",
        unit="litres",
    ),
    ChartSpec(
        ChartKind.energy,
        "kWh / km",
        "Energy per kilometre. Shaded where a PM was attended that day.",
        unit="kWh/km",
        available=False,
        unavailable_reason=(
            "No energy feed. Nothing in the system records kWh or distance per "
            "bus per day, so this chart would be blank rather than empty."
        ),
    ),
    ChartSpec(
        ChartKind.pm_schedule,
        "P.M schedule",
        "The inspection attended. Dockings marked red.",
    ),
    ChartSpec(
        ChartKind.complaints_breakdowns,
        "Driver complaints and breakdowns",
        "Complaints raised that day. Days with a breakdown marked red.",
    ),
    ChartSpec(
        ChartKind.tyre_pressure,
        "Tyre pressure checked",
        "Ticked where the tyre-pressure line was answered on an inspection.",
    ),
    ChartSpec(
        ChartKind.bus_washing,
        "Bus washing and deep cleaning",
        "Ticked where the washing line was answered on an inspection.",
    ),
    ChartSpec(
        ChartKind.di_inspection,
        "D.I inspection",
        "Ticked where the daily inspection was attended.",
    ),
    ChartSpec(
        ChartKind.ten_day_service,
        "10-day service",
        "Ticked where the ten-day service was attended.",
    ),
    ChartSpec(
        ChartKind.driver_complaints,
        "Driver complaints",
        "Complaint raised that day. Hover a block for the full complaint.",
    ),
    ChartSpec(
        ChartKind.breakdowns,
        "Breakdowns",
        "Breakdown that day. Hover a block for the full description.",
    ),
]

CHART_BY_KIND = {c.kind: c for c in CHARTS}


class ChartKey(StrEnum):
    """What a checklist line can be nominated to answer.

    A closed set rather than free text: a typo here is a chart that silently
    stays empty, which reads exactly like a check nobody performed.
    """

    tyre_pressure = "tyre_pressure"
    washing = "washing"


#: Chart kinds answered by a marked checklist line, and the key that marks it.
CHECKLIST_CHARTS: dict[ChartKind, ChartKey] = {
    ChartKind.tyre_pressure: ChartKey.tyre_pressure,
    ChartKind.bus_washing: ChartKey.washing,
}


#: A block is about 34px wide on screen. Anything longer than this has to be
#: shortened or it renders as illegible grey mush.
BLOCK_CHARS = 4


@dataclass(slots=True)
class Cell:
    #: What the block shows — already short enough to read.
    value: str = ""
    mark: CellMark = CellMark.plain
    #: The full text, when `value` had to be shortened to fit. Empty when the
    #: two would be the same.
    title: str = ""

    @property
    def is_empty(self) -> bool:
        return not self.value and self.mark is CellMark.plain


@dataclass(slots=True)
class Row:
    vehicle_id: str
    registration_no: str
    cells: list[Cell] = field(default_factory=list)

    @property
    def filled(self) -> int:
        return sum(1 for c in self.cells if not c.is_empty)


@dataclass(slots=True)
class Chart:
    spec: ChartSpec
    site_code: str
    from_date: date_t
    to_date: date_t
    dates: list[date_t]
    rows: list[Row]

    @property
    def filled(self) -> int:
        return sum(r.filled for r in self.rows)


def date_range(from_date: date_t, to_date: date_t) -> list[date_t]:
    if to_date < from_date:
        raise ValidationError("`to` is before `from`", {"to": "before from"})
    span = (to_date - from_date).days + 1
    if span > MAX_CHART_DAYS:
        raise ValidationError(
            f"A control chart covers at most {MAX_CHART_DAYS} days",
            {"to": "range too wide"},
        )
    return [from_date + timedelta(days=i) for i in range(span)]


async def _fleet(session: AsyncSession, site_code: str) -> list[Vehicle]:
    rows = await session.scalars(
        select(Vehicle)
        .where(Vehicle.site_code == site_code, Vehicle.is_active.is_(True))
        .order_by(Vehicle.registration_no)
    )
    return list(rows.unique().all())


async def _inspection_days(
    session: AsyncSession, site_code: str, dates: list[date_t]
) -> tuple[dict[tuple[str, date_t], str], set[tuple[str, date_t]]]:
    """(bus, day) -> the inspection code attended, and which of those are
    dockings."""
    rows = await session.execute(
        select(
            InspectionEntry.vehicle_id,
            InspectionEntry.inspected_on,
            WorkType.code,
        )
        .join(WorkType, WorkType.id == InspectionEntry.work_type_id)
        .where(
            InspectionEntry.site_code == site_code,
            InspectionEntry.inspected_on >= dates[0],
            InspectionEntry.inspected_on <= dates[-1],
        )
    )
    attended: dict[tuple[str, date_t], str] = {}
    dockings: set[tuple[str, date_t]] = set()
    for vehicle_id, day, code in rows.all():
        key = (vehicle_id, day)
        # A bus can have two inspections in a day; the longer one is the one
        # worth showing.
        if key not in attended or len(code) > len(attended[key]):
            attended[key] = code
        if code.upper().replace(".", "") == "PM":
            dockings.add(key)
    return attended, dockings


async def _inspection_days_for_code(
    session: AsyncSession, site_code: str, dates: list[date_t], code: str
) -> set[tuple[str, date_t]]:
    """(bus, day) where this exact work-type code was attended.

    A separate query from `_inspection_days` rather than filtering its
    result: that one keeps only the longer of two same-day codes, which
    would silently drop a D.I entry on a day that also had a 10-day service.
    """
    rows = await session.execute(
        select(InspectionEntry.vehicle_id, InspectionEntry.inspected_on)
        .join(WorkType, WorkType.id == InspectionEntry.work_type_id)
        .where(
            InspectionEntry.site_code == site_code,
            InspectionEntry.inspected_on >= dates[0],
            InspectionEntry.inspected_on <= dates[-1],
            WorkType.code == code,
        )
    )
    return {(vehicle_id, day) for vehicle_id, day in rows.all()}


async def _complaint_texts(
    session: AsyncSession, site_code: str, dates: list[date_t]
) -> dict[tuple[str, date_t], list[str]]:
    """(bus, day) -> every complaint text raised that day, in entry order."""
    rows = await session.execute(
        select(Entry.bus_id, Entry.entry_date, DriverComplaintEntry.complaint)
        .join(DriverComplaintEntry, DriverComplaintEntry.entry_id == Entry.id)
        .where(
            Entry.site_code == site_code,
            Entry.entry_date >= dates[0],
            Entry.entry_date <= dates[-1],
        )
        .order_by(Entry.entry_time)
    )
    texts: dict[tuple[str, date_t], list[str]] = {}
    for bus, day, complaint in rows.all():
        texts.setdefault((bus, day), []).append(complaint)
    return texts


async def _breakdown_texts(
    session: AsyncSession, site_code: str, dates: list[date_t]
) -> dict[tuple[str, date_t], list[str]]:
    """(bus, day) -> every breakdown description that day, in entry order."""
    rows = await session.execute(
        select(Entry.bus_id, Entry.entry_date, BreakdownEntry.complaint)
        .join(BreakdownEntry, BreakdownEntry.entry_id == Entry.id)
        .where(
            Entry.site_code == site_code,
            Entry.entry_date >= dates[0],
            Entry.entry_date <= dates[-1],
        )
        .order_by(Entry.entry_time)
    )
    texts: dict[tuple[str, date_t], list[str]] = {}
    for bus, day, complaint in rows.all():
        texts.setdefault((bus, day), []).append(complaint)
    return texts


async def site_availability(
    session: AsyncSession, site_code: str, spec: ChartSpec
) -> tuple[bool, str]:
    """Whether this site can answer this chart, as opposed to whether the
    system can in principle.

    Tyre pressure and bus washing are answered by a checklist line the depot
    nominates with `chart_key`. Until a line carries it there is no source at
    all, and a grid that reports itself available and renders blank cannot be
    told apart from a month where nobody checked. `energy` already shows the
    honest shape; these two now match it.

    Coolant topping is deliberately not included. It is wired to the coolant
    register, so an empty month there is real data — no toppings happened —
    and saying otherwise would hide a fact the depot should see.
    """
    if not spec.available:
        return False, spec.unavailable_reason
    key = CHECKLIST_CHARTS.get(spec.kind)
    if key is None:
        return True, ""

    nominated = await session.scalar(
        select(ChecklistItem.id)
        .join(ChecklistTemplate)
        .where(
            ChecklistTemplate.site_code == site_code,
            ChecklistItem.chart_key == key.value,
        )
        .limit(1)
    )
    if nominated:
        return True, ""
    return False, (
        f"No inspection line is nominated for this chart. A depot marks the "
        f"line that records it with chart key \"{key.value}\"; until one "
        f"does, there is nothing to read and the grid would be blank rather "
        f"than empty."
    )


async def _checklist_days(
    session: AsyncSession, site_code: str, dates: list[date_t], chart_key: ChartKey
) -> set[tuple[str, date_t]]:
    """(bus, day) where the marked checklist line was actually answered.

    "Not applicable" does not count as done — it is the honest way to record a
    check that was skipped, and a tick would say the opposite.
    """
    rows = await session.execute(
        select(InspectionEntry.vehicle_id, InspectionEntry.inspected_on)
        .join(InspectionResult, InspectionResult.inspection_id == InspectionEntry.id)
        .join(ChecklistItem, ChecklistItem.id == InspectionResult.item_id)
        .join(
            ChecklistTemplate, ChecklistTemplate.id == ChecklistItem.template_id
        )
        .where(
            InspectionEntry.site_code == site_code,
            InspectionEntry.inspected_on >= dates[0],
            InspectionEntry.inspected_on <= dates[-1],
            ChecklistItem.chart_key == chart_key.value,
            ChecklistTemplate.site_code == site_code,
            InspectionResult.result != CheckResult.na,
        )
    )
    return {(vehicle_id, day) for vehicle_id, day in rows.all()}


async def _coolant(
    session: AsyncSession, site_code: str, dates: list[date_t]
) -> dict[tuple[str, date_t], Decimal]:
    rows = await session.execute(
        select(
            Entry.bus_id,
            Entry.entry_date,
            func.sum(
                func.coalesce(CoolantEntry.bcs_litres, 0)
                + func.coalesce(CoolantEntry.tcs_litres, 0)
            ),
        )
        .join(CoolantEntry, CoolantEntry.entry_id == Entry.id)
        .where(
            Entry.site_code == site_code,
            Entry.entry_date >= dates[0],
            Entry.entry_date <= dates[-1],
        )
        .group_by(Entry.bus_id, Entry.entry_date)
    )
    return {(bus, day): total or Decimal(0) for bus, day, total in rows.all()}


async def _by_register(
    session: AsyncSession, site_code: str, dates: list[date_t], register: Register
) -> dict[tuple[str, date_t], int]:
    rows = await session.execute(
        select(Entry.bus_id, Entry.entry_date, func.count())
        .where(
            Entry.site_code == site_code,
            Entry.register == register,
            Entry.entry_date >= dates[0],
            Entry.entry_date <= dates[-1],
        )
        .group_by(Entry.bus_id, Entry.entry_date)
    )
    return {(bus, day): count for bus, day, count in rows.all()}


def abbreviate(text: str) -> str:
    """A work-type code short enough for one block.

    "10 DAYS SERVICE" is fifteen characters in a column four wide, so it
    becomes "10D" — leading digits and the initial that follows them, which is
    how the depot writes it on the paper chart anyway. The full code stays on
    the cell so nothing is actually lost.
    """
    if len(text) <= BLOCK_CHARS:
        return text
    squashed = re.sub(r"[^A-Za-z0-9]", "", text).upper()
    digits = re.match(r"\d+", squashed)
    if digits:
        rest = squashed[digits.end() :]
        return f"{digits.group()}{rest[:1]}"
    return squashed[:3]


def _trim(value: Decimal) -> str:
    """1.50 reads as 1.5, and 2.00 as 2 — a grid of trailing zeros is noise."""
    text = format(value.normalize(), "f")
    return text.rstrip("0").rstrip(".") if "." in text else text


async def build(
    session: AsyncSession,
    *,
    site_code: str,
    kind: ChartKind,
    from_date: date_t,
    to_date: date_t,
) -> Chart:
    """One chart: the fleet down, the days across, a mark per bus per day."""
    spec = CHART_BY_KIND[kind]
    dates = date_range(from_date, to_date)
    fleet = await _fleet(session, site_code)

    def blank() -> Chart:
        return Chart(
            spec=spec,
            site_code=site_code,
            from_date=from_date,
            to_date=to_date,
            dates=dates,
            rows=[
                Row(
                    vehicle_id=v.id,
                    registration_no=v.registration_no,
                    cells=[Cell() for _ in dates],
                )
                for v in fleet
            ],
        )

    chart = blank()
    if not spec.available or not fleet:
        return chart

    attended, dockings = await _inspection_days(session, site_code, dates)

    values: dict[tuple[str, date_t], str] = {}
    titles: dict[tuple[str, date_t], str] = {}
    marks: dict[tuple[str, date_t], CellMark] = {}

    if kind is ChartKind.coolant_topping:
        for key, litres in (await _coolant(session, site_code, dates)).items():
            if litres:
                values[key] = _trim(litres)
        # The depot shades PM days on this chart so a topping right after a
        # service is read differently from one in the middle of a cycle.
        for key in attended:
            marks[key] = CellMark.pm

    elif kind is ChartKind.pm_schedule:
        for key, code in attended.items():
            values[key] = abbreviate(code)
            titles[key] = code
            marks[key] = (
                CellMark.docking if key in dockings else CellMark.pm
            )

    elif kind is ChartKind.complaints_breakdowns:
        complaints = await _by_register(
            session, site_code, dates, Register.driver_complaint
        )
        breakdowns = await _by_register(
            session, site_code, dates, Register.breakdown
        )
        for key, count in complaints.items():
            values[key] = str(count)
        for key, count in breakdowns.items():
            marks[key] = CellMark.breakdown
            # A breakdown day with no complaint still has to show something,
            # otherwise the red block reads as an empty one.
            values.setdefault(key, f"BD{count}" if count > 1 else "BD")

    elif kind in CHECKLIST_CHARTS:
        done = await _checklist_days(
            session, site_code, dates, CHECKLIST_CHARTS[kind]
        )
        for key in done:
            values[key] = "✓"

    elif kind is ChartKind.di_inspection:
        for key in await _inspection_days_for_code(session, site_code, dates, DI_CODE):
            values[key] = "✓"

    elif kind is ChartKind.ten_day_service:
        for key in await _inspection_days_for_code(
            session, site_code, dates, TEN_DAY_CODE
        ):
            values[key] = "✓"

    elif kind is ChartKind.driver_complaints:
        for key, texts in (await _complaint_texts(session, site_code, dates)).items():
            values[key] = str(len(texts)) if len(texts) > 1 else "C"
            titles[key] = "; ".join(texts)

    elif kind is ChartKind.breakdowns:
        for key, texts in (await _breakdown_texts(session, site_code, dates)).items():
            values[key] = f"BD{len(texts)}" if len(texts) > 1 else "BD"
            titles[key] = "; ".join(texts)
            marks[key] = CellMark.breakdown

    index = {day: i for i, day in enumerate(dates)}
    for row in chart.rows:
        for day, position in index.items():
            key = (row.vehicle_id, day)
            row.cells[position] = Cell(
                value=values.get(key, ""),
                mark=marks.get(key, CellMark.plain),
                title=titles.get(key, ""),
            )
    return chart
