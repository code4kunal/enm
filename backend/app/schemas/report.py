from __future__ import annotations

from datetime import date as date_t

from pydantic import BaseModel, Field

from app.models.enums import DefectCategory
from app.schemas.common import HHMM, DecimalOut, ISTDateTime
from app.services.control_charts import CellMark, ChartKind


class DmrLine(BaseModel):
    """One numbered line of the report."""

    number: int
    label: str
    key: str
    #: False when nothing observes it, so a person enters it.
    derived: bool
    #: A JSON number, never a string — the client casts these to num.
    value: DecimalOut = None
    #: Rendered with a decimal rather than as a count.
    is_decimal: bool = False


class DmrDayOut(BaseModel):
    site_code: str
    report_date: date_t
    lines: list[DmrLine]
    notes: str = ""
    #: True once the day is frozen; until then the derived lines recompute.
    is_snapshot: bool = False
    generated_at: ISTDateTime | None = None


class DmrEnteredIn(BaseModel):
    """Only the lines nothing else in the system observes."""

    on_road: int | None = Field(default=None, ge=0, le=10_000)
    spare: int | None = Field(default=None, ge=0, le=10_000)
    under_warranty: int | None = Field(default=None, ge=0, le=10_000)
    rto_passing: int | None = Field(default=None, ge=0, le=10_000)
    high_energy_consumption: int | None = Field(default=None, ge=0, le=10_000)
    deep_cleaning: int | None = Field(default=None, ge=0, le=10_000)
    washed_cleaned: int | None = Field(default=None, ge=0, le=10_000)
    depot_accidents: int | None = Field(default=None, ge=0, le=10_000)
    tyres_scrapped: int | None = Field(default=None, ge=0, le=10_000)
    hv_batteries_replaced: int | None = Field(default=None, ge=0, le=10_000)
    body_damages: int | None = Field(default=None, ge=0, le=10_000)
    notes: str | None = None


class DmrMonthOut(BaseModel):
    """The month grid: parameters down, one column per day."""

    site_code: str
    month: str
    dates: list[date_t]
    lines: list[DmrLine]
    #: line key -> value per date, in `dates` order. Plain numbers: a grid of
    #: quoted decimals is a parsing trap for every consumer.
    values: dict[str, list[float | None]]


# --- breakdown investigation (Annexure-V) ----------------------------------


class InvestigationOut(BaseModel):
    entry_id: str
    registration_no: str
    model: str = ""
    odometer_km: int | None = None
    driver_id: str | None = None
    defect_type: str = ""
    breakdown_reason: str = ""
    location: str | None = None
    breakdown_time: HHMM | None = None
    mechanic_reported_time: HHMM | None = None
    attended_time: HHMM | None = None
    loss_km: DecimalOut = None
    attended_details: str | None = None
    entry_date: date_t

    #: The investigation itself.
    findings: str | None = None
    last_pm_on: date_t | None = None
    last_pm_findings: str | None = None
    related_complaints: str | None = None
    investigation_action: str | None = None
    is_complete: bool = False
    updated_by: str = ""


class InvestigationList(BaseModel):
    site_code: str
    report_date: date_t
    items: list[InvestigationOut]
    outstanding: int = 0


class InvestigationIn(BaseModel):
    findings: str | None = None
    last_pm_on: date_t | None = None
    last_pm_findings: str | None = None
    related_complaints: str | None = None
    investigation_action: str | None = None


# --- off-road cases ---------------------------------------------------------


class OffRoadOut(BaseModel):
    id: str
    site_code: str
    vehicle_id: str
    registration_no: str
    model: str = ""
    odometer_km: int | None = None
    issue: str = ""
    action_taken: str | None = None
    category: DefectCategory
    off_road_since: date_t
    expected_days: int | None = None
    expected_ready_on: date_t | None = None
    returned_on: date_t | None = None
    spare_parts_required: str | None = None
    remarks: str | None = None
    awaiting_vendor: bool = False
    #: How long it has been down as at the date asked for.
    days_down: int = 0
    #: True once it has been down longer than the report's threshold.
    is_held: bool = False


class OffRoadList(BaseModel):
    site_code: str
    report_date: date_t
    items: list[OffRoadOut]


class OffRoadIn(BaseModel):
    vehicle_id: str = Field(min_length=1, max_length=32)
    entry_id: str | None = None
    issue: str = ""
    action_taken: str | None = None
    category: DefectCategory = DefectCategory.other
    off_road_since: date_t | None = None
    expected_days: int | None = Field(default=None, ge=0, le=365)
    expected_ready_on: date_t | None = None
    odometer_km: int | None = Field(default=None, ge=0, le=10_000_000)
    spare_parts_required: str | None = None
    remarks: str | None = None
    awaiting_vendor: bool = False


class OffRoadClose(BaseModel):
    returned_on: date_t


class ChartCellOut(BaseModel):
    """One block on a control chart."""

    #: Empty means the block is blank — no topping, no inspection, no complaint.
    value: str = ""
    #: What the depot colours it: plain, pm, docking, breakdown.
    mark: CellMark = CellMark.plain
    #: The full text when `value` was shortened to fit the block. Empty when
    #: the two are the same.
    title: str = ""


class ChartRowOut(BaseModel):
    vehicle_id: str
    registration_no: str
    #: One per date, in `dates` order, always the same length as `dates`.
    cells: list[ChartCellOut]


class ChartKindOut(BaseModel):
    """A chart offered by the site, whether or not it has data behind it."""

    kind: ChartKind
    title: str
    legend: str
    unit: str = ""
    #: False when nothing in the system can answer it; the client says why
    #: rather than drawing an empty grid.
    available: bool = True
    unavailable_reason: str = ""


class ControlChartOut(ChartKindOut):
    site_code: str
    from_date: date_t
    to_date: date_t
    dates: list[date_t]
    rows: list[ChartRowOut]
    #: How many blocks carry anything — a whole-chart "is this being kept up".
    filled: int = 0
