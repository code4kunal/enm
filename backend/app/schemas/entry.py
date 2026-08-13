from __future__ import annotations

from datetime import date as date_t
from decimal import Decimal
from typing import Annotated, Any, Literal

from pydantic import BaseModel, BeforeValidator, ConfigDict, Field, field_validator

from app.models.enums import EntryStatus, Register, Shift
from app.schemas.common import HHMM, ISTDateTime, OptText
from app.schemas.user import UserBrief


def _norm_bus(value: object) -> object:
    if isinstance(value, str):
        return "".join(value.split()).upper()
    return value


BusNo = Annotated[str, BeforeValidator(_norm_bus), Field(min_length=1, max_length=32)]
Req = Annotated[str, BeforeValidator(lambda v: v.strip() if isinstance(v, str) else v)]


class _DataBase(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


# --- per-register data schemas (single source of validation truth) ---------


class WorkDoneData(_DataBase):
    shift: Shift | None = None
    bus_no: BusNo
    reported_defects: Req = Field(min_length=1)
    defect_source: OptText = None
    defect_type: OptText = None
    attended_details: OptText = None
    spare_parts_used: OptText = None
    employee: OptText = None


class CoolantData(_DataBase):
    bus_no: BusNo
    bcs_litres: Decimal | None = Field(default=None, ge=0, le=999999)
    tcs_litres: Decimal | None = Field(default=None, ge=0, le=999999)
    topped_by: OptText = None


class DriverComplaintData(_DataBase):
    bus_no: BusNo
    defect_type: OptText = None
    complaint: Req = Field(min_length=1)
    rectification_action: OptText = None
    mechanic: OptText = None


class BreakdownData(_DataBase):
    bus_no: BusNo
    driver_id: OptText = None
    location: OptText = None
    complaint: Req = Field(min_length=1)
    breakdown_time: HHMM | None = None
    mechanic_reported_time: HHMM | None = None
    attended_time: HHMM | None = None
    loss_km: Decimal | None = Field(default=None, ge=0, le=999999)
    attended_details: OptText = None
    remarks: OptText = None


class PMScheduleData(_DataBase):
    bus_no: BusNo
    defect_type: OptText = None
    defects_noticed: Req = Field(min_length=1)
    action_taken: OptText = None
    balance_job_reason: OptText = None
    spare_parts_used: OptText = None
    employees: OptText = None


REGISTER_DATA_SCHEMAS: dict[Register, type[_DataBase]] = {
    Register.work_done: WorkDoneData,
    Register.coolant: CoolantData,
    Register.driver_complaint: DriverComplaintData,
    Register.breakdown: BreakdownData,
    Register.pm_schedule: PMScheduleData,
}


# --- envelopes -------------------------------------------------------------


class EntryCreate(BaseModel):
    register: Register
    depot: str = Field(min_length=1, max_length=16)
    date: date_t
    entry_time: HHMM | None = None
    data: dict[str, Any]

    @field_validator("depot")
    @classmethod
    def _upper(cls, v: str) -> str:
        return v.strip().upper()


class EntryUpdate(BaseModel):
    date: date_t | None = None
    entry_time: HHMM | None = None
    data: dict[str, Any]


class EntryOut(BaseModel):
    id: str
    register: Register
    depot: str
    date: date_t
    entry_time: HHMM | None
    created_by: UserBrief
    created_at: ISTDateTime
    updated_at: ISTDateTime | None
    status: EntryStatus
    photo_url: str | None
    data: dict[str, Any]


class PhotoOut(BaseModel):
    photo_url: str


class SummaryOut(BaseModel):
    date: date_t
    depot: str
    total_today: int
    by_register: dict[str, int]
    open_breakdowns: int


Period = Literal["today", "last7", "month", "all"]
