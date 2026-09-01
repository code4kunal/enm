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
    #: The closest date that does have breakdowns, when this one has none. An
    #: empty pane on a quiet day is indistinguishable from a broken one without
    #: it. Null when the site has no breakdowns at all.
    nearest_date: date_t | None = None


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


# --- fitted units: the statement and the history card ------------------------


class UnitTypeOut(BaseModel):
    id: int
    name: str
    sort_order: int = 0
    #: Marks the unit the DMR counts under "HV batteries replaced".
    is_hv_battery: bool = False


class FittedUnitOut(BaseModel):
    """One component's stay on one bus."""

    id: str
    site_code: str
    vehicle_id: str
    registration_no: str
    unit_type_id: int
    unit_name: str
    #: The Work Done entry this was fit alongside, when it was fit that way.
    entry_id: str | None = None
    unit_no: str | None = None
    fitted_on: date_t
    fitted_odometer_km: int | None = None
    removed_on: date_t | None = None
    removed_odometer_km: int | None = None
    #: Removal odometer less fitting odometer. Null when either is missing — an
    #: unknown life is not a life of zero.
    kms_covered: int | None = None
    removal_reason: str | None = None
    remarks: str | None = None
    #: False once it has come off.
    is_fitted: bool = True


class FittedUnitList(BaseModel):
    site_code: str
    month: str = ""
    items: list[FittedUnitOut]


class FitUnitIn(BaseModel):
    vehicle_id: str = Field(min_length=1, max_length=32)
    unit_type_id: int
    fitted_on: date_t
    #: Set when this fit is recorded alongside a Work Done entry's own save —
    #: lets the register list find it without guessing from vehicle + date.
    entry_id: str | None = Field(default=None, max_length=32)
    unit_no: str | None = Field(default=None, max_length=120)
    #: Defaults to the bus's last odometer reading when left out.
    fitted_odometer_km: int | None = Field(default=None, ge=0, le=10_000_000)
    remarks: str | None = None


class RemoveUnitIn(BaseModel):
    removed_on: date_t
    removed_odometer_km: int | None = Field(default=None, ge=0, le=10_000_000)
    removal_reason: str | None = None
    remarks: str | None = None


class HistoryEventOut(BaseModel):
    """What happened to one unit in one month."""

    #: "fitted", "removed", or "replaced" when both happened that month.
    kind: str
    #: What the block shows — the day, or both days.
    label: str
    unit_no: str = ""
    reason: str = ""
    kms_covered: int | None = None


class HistoryRowOut(BaseModel):
    unit_type_id: int
    unit_name: str
    #: One per month in `months` order; null where nothing happened.
    cells: list[HistoryEventOut | None]
    #: True when the unit is on the bus as at the end of the window.
    fitted_now: bool = False


class BusHistoryOut(BaseModel):
    site_code: str
    vehicle_id: str
    registration_no: str
    #: `yyyy-MM`, oldest first.
    months: list[str]
    rows: list[HistoryRowOut]
    #: How many blocks carry anything — whether the card is being kept at all.
    events: int = 0
