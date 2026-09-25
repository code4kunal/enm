from __future__ import annotations

from datetime import date as date_t
from decimal import Decimal
from typing import Annotated, Any, Literal

from pydantic import BaseModel, BeforeValidator, ConfigDict, Field, field_validator, model_validator

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
    spare_part_ids: list[str] = Field(default_factory=list)
    supervisor: OptText = None
    ticket_id: OptText = None
    completes_ticket: bool = False
    completion_time: HHMM | None = None
    attendee_user_ids: list[str] = Field(default_factory=list)
    # Read-only: the server always echoes attendees back as `{user_id, name}`
    # objects (see services/entries.serialize_data), but the form writes them
    # back as `attendee_user_ids`. Accepted here (and ignored) purely so a
    # GET-then-PUT-the-whole-form-back round trip doesn't 400 on a key the
    # client never set itself — same contract as `BreakdownData.resolved_at`.
    attendees: list[Any] | None = None
    # Read-only, same contract as `attendees` above: the server echoes spare
    # parts back as `{part_id, part_no, name}` objects, the form writes them
    # back as `spare_part_ids`.
    spare_parts: list[Any] | None = None

    @model_validator(mode="after")
    def _completion_requires_ticket_and_time(self) -> "WorkDoneData":
        if self.completes_ticket and not self.ticket_id:
            raise ValueError("completes_ticket requires ticket_id")
        if self.completes_ticket and not self.completion_time:
            raise ValueError("completes_ticket requires completion_time")
        return self


class CoolantData(_DataBase):
    bus_no: BusNo
    bcs_litres: Decimal | None = Field(default=None, ge=0, le=999999)
    tcs_litres: Decimal | None = Field(default=None, ge=0, le=999999)
    topped_by: OptText = None
    supervisor: OptText = None


class DriverComplaintData(_DataBase):
    bus_no: BusNo
    defect_type: OptText = None
    complaint: Req = Field(min_length=1)
    rectification_action: OptText = None
    mechanic: OptText = None
    supervisor: OptText = None
    driver_id: OptText = None


class BreakdownData(_DataBase):
    bus_no: BusNo
    defect_type: OptText = None
    driver_id: OptText = None
    route: OptText = None
    location: OptText = None
    complaint: Req = Field(min_length=1)
    reported_time: HHMM
    loss_km: Decimal | None = Field(default=None, ge=0, le=999999)
    attended_details: OptText = None
    remarks: OptText = None
    supervisor: OptText = None
    # Read-only: stamped by the first Work Done session logged against this
    # breakdown's ticket (services/tickets.mark_attended), never by the form.
    # Accepted here (and ignored — see services/entries._build_detail) purely
    # so an edit-form round trip (GET the entry, PUT it back) doesn't 400 on a
    # key the client never set but the server always echoes.
    attended_time: OptText = None
    # Read-only: set by resolving the ticket, never by the form. Accepted here
    # (and ignored — see services/entries._build_detail) purely so an
    # edit-form round trip (GET the entry, PUT it back) doesn't 400 on a key
    # the client never set but the server always echoes.
    resolved_at: OptText = None


class PMScheduleData(_DataBase):
    bus_no: BusNo
    defect_type: OptText = None
    defects_noticed: Req = Field(min_length=1)
    action_taken: OptText = None
    balance_job_reason: OptText = None
    spare_parts_used: OptText = None
    employees: OptText = None
    supervisor: OptText = None


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
    site: str = Field(min_length=1, max_length=50)
    date: date_t
    entry_time: HHMM | None = None
    data: dict[str, Any]

    @field_validator("site")
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
    site: str
    date: date_t
    entry_time: HHMM | None
    #: Who did the work, per the register. Falls back to `created_by.name`.
    entered_by: str = ""
    created_by: UserBrief
    created_at: ISTDateTime
    updated_at: ISTDateTime | None
    status: EntryStatus
    photo_url: str | None
    data: dict[str, Any]
    #: Work Done sessions logged against this entry's ticket. Populated only
    #: for entries that can have a ticket (breakdown, coolant, driver
    #: complaint, PM/docking); null everywhere else, including work_done
    #: entries themselves.
    linked_sessions: list[dict[str, Any]] | None = None


class PhotoOut(BaseModel):
    photo_url: str


class SummaryOut(BaseModel):
    date: date_t
    site: str
    total_today: int
    by_register: dict[str, int]
    open_breakdowns: int


Period = Literal["today", "last7", "month", "all"]
