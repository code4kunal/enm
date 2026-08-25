from __future__ import annotations

from pydantic import BaseModel

from app.models.enums import JobCardReconKind
from app.schemas.common import ISTDateTime


class JobCardReconOut(BaseModel):
    id: str
    site_code: str
    job_card_id: str | None
    sap_order_no: str | None
    kind: JobCardReconKind
    detail: str
    detected_at: ISTDateTime
    resolved_at: ISTDateTime | None


class JobCardReconList(BaseModel):
    items: list[JobCardReconOut]
