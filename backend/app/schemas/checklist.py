from __future__ import annotations

from datetime import date as date_t

# pyrefly: ignore [missing-import]
from pydantic import BaseModel, Field, field_validator

from app.models.enums import CheckResult, ResponseType
from app.schemas.common import HHMM, ISTDateTime
from app.schemas.job_card import MaterialIn
from app.services.control_charts import ChartKey


class ChecklistItemIO(BaseModel):
    """One line on a checklist."""

    id: str = ""
    section: str = Field(default="", max_length=80)
    label: str = Field(min_length=1, max_length=255)
    sort_order: int = 0
    response_type: ResponseType = ResponseType.ok_not_ok
    is_required: bool = True
    is_active: bool = True
    #: Ties this line to a control chart — `tyre_pressure` or `washing`. Two of
    #: the six charts are "was this done that day", and the line that answers
    #: them is the depot's to nominate, not this code's to guess.
    chart_key: ChartKey | None = None

    @field_validator("label", "section")
    @classmethod
    def _strip(cls, v: str) -> str:
        return " ".join(v.split())


class ChecklistOut(BaseModel):
    """A site's checklist for one inspection type.

    `items` may be empty — a site that has not written its checklist yet is a
    real state, and the form says so rather than pretending otherwise.
    """

    id: str = ""
    site_code: str
    work_type_id: int
    work_type_code: str
    work_type_name: str
    name: str
    #: Which buses take this one. Null is the site's unscoped checklist, used
    #: by any bus that names no variant.
    variant: str | None = None
    is_active: bool = True
    items: list[ChecklistItemIO] = Field(default_factory=list)
    updated_at: ISTDateTime | None = None

    @property
    def is_empty(self) -> bool:
        return not self.items


class ChecklistList(BaseModel):
    items: list[ChecklistOut]


class ChecklistUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=500)
    variant: str | None = Field(default=None, max_length=40)
    is_active: bool | None = None
    items: list[ChecklistItemIO] = Field(default_factory=list)


class ResultIn(BaseModel):
    item_id: str = Field(min_length=1, max_length=64)
    result: CheckResult = CheckResult.ok
    value: str | None = Field(default=None, max_length=255)
    remark: str | None = None


class ResultOut(BaseModel):
    item_id: str
    section: str = ""
    label: str = ""
    result: CheckResult
    value: str | None = None
    remark: str | None = None


class InspectionCreate(BaseModel):
    vehicle_id: str = Field(min_length=1, max_length=64)
    work_type_id: int
    inspected_on: date_t
    entry_time: HHMM | None = None
    done_by: str | None = Field(default=None, max_length=255)
    supervisor: str | None = Field(default=None, max_length=255)
    odometer_km: int | None = Field(default=None, ge=0, le=10_000_000)
    remarks: str | None = None
    results: list[ResultIn] = Field(default_factory=list)
    #: Any line here opens a job card and posts it to SAP after the
    #: inspection saves. Empty (the default) touches SAP not at all.
    materials: list[MaterialIn] = Field(default_factory=list)


class InspectionOut(BaseModel):
    id: str
    site_code: str
    vehicle_id: str
    registration_no: str
    work_type_id: int
    work_type_code: str
    work_type_name: str
    inspected_on: date_t
    entry_time: HHMM | None = None
    done_by: str | None = None
    supervisor: str | None = None
    odometer_km: int | None = None
    remarks: str | None = None
    slot_id: str | None = None
    #: Lines that came back not OK — what a supervisor actually reads.
    failed_count: int = 0
    results: list[ResultOut] = Field(default_factory=list)
    created_by: str = ""
    created_at: ISTDateTime | None = None


class InspectionList(BaseModel):
    items: list[InspectionOut]
    total: int = 0
