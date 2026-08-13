from __future__ import annotations

from datetime import date as date_t

from pydantic import BaseModel, Field

from app.models.enums import AlertStatus, AlertType, Register, SlotStatus
from app.schemas.common import ISTDateTime


class InspectionPlanIO(BaseModel):
    """How often one inspection comes round, and how many fit in a night."""

    id: str = ""
    work_type_id: int
    work_type_code: str = ""
    work_type_name: str = ""
    register: Register | None = None
    cycle_days: int = Field(default=10, ge=1, le=365)
    #: 0 means uncapped — a daily inspection covers the whole fleet.
    slots_per_day: int = Field(default=0, ge=0, le=500)
    is_active: bool = True


class InspectionPlanList(BaseModel):
    items: list[InspectionPlanIO]


class SlotOut(BaseModel):
    id: str
    site_code: str
    vehicle_id: str
    registration_no: str
    work_type_id: int
    work_type_code: str
    work_type_name: str
    scheduled_on: date_t
    status: SlotStatus
    is_pinned: bool
    completed_on: date_t | None = None
    completed_entry_id: str | None = None
    notes: str = ""


class SlotList(BaseModel):
    items: list[SlotOut]


class CalendarDay(BaseModel):
    """One column of the calendar."""

    date: date_t
    slots: list[SlotOut]

    @property
    def count(self) -> int:
        return len(self.slots)


class CalendarOut(BaseModel):
    site_code: str
    from_date: date_t
    to_date: date_t
    days: list[CalendarDay]
    #: Rolled up for the header strip, so the client does not recount.
    scheduled: int = 0
    done: int = 0
    missed: int = 0


class SlotCreate(BaseModel):
    vehicle_id: str = Field(min_length=1, max_length=32)
    work_type_id: int
    scheduled_on: date_t
    notes: str = ""


class SlotUpdate(BaseModel):
    """Any hand edit pins the slot so the generator stops moving it."""

    scheduled_on: date_t | None = None
    status: SlotStatus | None = None
    notes: str | None = None
    is_pinned: bool | None = None


class GenerateOut(BaseModel):
    site_code: str
    generated_on: date_t
    created: int
    missed: int
    completed: int
    alerts_raised: int


class AlertOut(BaseModel):
    id: str
    site_code: str
    type: AlertType
    status: AlertStatus
    title: str
    body: str
    vehicle_id: str | None = None
    registration_no: str = ""
    slot_id: str | None = None
    entry_id: str | None = None
    raised_on: date_t
    created_at: ISTDateTime
    acknowledged_at: ISTDateTime | None = None


class AlertList(BaseModel):
    items: list[AlertOut]
    open_count: int = 0
