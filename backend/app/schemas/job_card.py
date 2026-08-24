from __future__ import annotations

from decimal import Decimal

from pydantic import BaseModel, Field

from app.models.enums import JobCardSource, JobCardStatus
from app.schemas.common import DecimalOut, ISTDateTime


class MaterialIn(BaseModel):
    """One material line on an entry/inspection save. Presence of any line
    is what opens a job card — see `app.services.sap.posting.open_job_card`."""

    sap_material_no: str = Field(min_length=1, max_length=40)
    qty_required: Decimal = Field(ge=0, le=999999)


class MaterialOut(BaseModel):
    sap_material_no: str
    qty_required: DecimalOut
    qty_issued: DecimalOut


class JobCardOut(BaseModel):
    id: str
    site_code: str
    bus_id: str
    registration_no: str = ""
    source: JobCardSource
    source_id: str
    status: JobCardStatus
    sap_notification_no: str | None
    sap_order_no: str | None
    last_sap_error: str | None
    components: list[MaterialOut] = Field(default_factory=list)
    created_at: ISTDateTime
    updated_at: ISTDateTime | None


class JobCardList(BaseModel):
    items: list[JobCardOut]
