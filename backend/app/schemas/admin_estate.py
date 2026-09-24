"""Admin estate schemas — summary dashboard and audit trail."""

from __future__ import annotations

from datetime import date as date_t

from pydantic import BaseModel, Field

from app.schemas.common import ISTDateTime


class EstateTotals(BaseModel):
    sites: int = 0
    active_sites: int = 0
    vehicles: int = 0
    users: int = 0
    work_done: int = 0
    driver_complaints: int = 0
    breakdowns: int = 0
    coolant: int = 0
    inspections: int = 0
    open_off_road: int = 0


class SiteSummaryOut(BaseModel):
    site_code: str
    name: str
    is_active: bool
    operating_categories: list[str] = Field(default_factory=lambda: ["bus"])
    vehicle_count: int = 0
    user_count: int = 0
    work_done: int = 0
    driver_complaints: int = 0
    breakdowns: int = 0
    coolant: int = 0
    inspections: int = 0
    open_off_road: int = 0


class SegmentTotals(BaseModel):
    site_count: int = 0
    work_done: int = 0
    driver_complaints: int = 0
    breakdowns: int = 0
    coolant: int = 0
    inspections: int = 0
    open_off_road: int = 0


class SegmentOut(BaseModel):
    label: str
    totals: SegmentTotals
    sites: list[SiteSummaryOut]


class AdminSummaryOut(BaseModel):
    date_from: date_t
    date_to: date_t
    estate: EstateTotals
    sites: list[SiteSummaryOut]
    segments: dict[str, SegmentOut]


class AuditLogOut(BaseModel):
    id: str
    actor_id: str | None = None
    actor_user_id: str | None = None
    actor_name: str | None = None
    action: str
    object_type: str
    object_id: str
    before: dict | None = None
    after: dict | None = None
    created_at: ISTDateTime
    #: Human label — e.g. "Breakdown · MH04LY… · MBMT · 2026-09-13".
    subject: str | None = None
    register: str | None = None
    site_code: str | None = None
    bus_no: str | None = None


class AuditLogList(BaseModel):
    items: list[AuditLogOut]
    page: int
    page_size: int
    total: int
