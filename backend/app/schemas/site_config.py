from __future__ import annotations

from pydantic import BaseModel, Field, field_validator

from app.schemas.common import HHMM, ISTDateTime


class ServicePlanIO(BaseModel):
    code: str = Field(max_length=50)
    name: str = Field(default="", max_length=120)
    #: 0 means this plan is time-driven only, and vice versa
    interval_km: int = Field(default=0, ge=0, le=10_000_000)
    interval_days: int = Field(default=0, ge=0, le=36_500)
    is_active: bool = True
    notes: str = ""

    @field_validator("code")
    @classmethod
    def _upper(cls, v: str) -> str:
        return v.strip().upper()


class ShiftWindowIO(BaseModel):
    shift: str = Field(pattern="^[ABC]$")
    #: HH:mm, site-local. end <= start means the window wraps midnight.
    start: HHMM
    end: HHMM


class OdometerSyncIO(BaseModel):
    enabled: bool = True
    interval_minutes: int = Field(default=60, ge=1, le=10_080)
    source: str = Field(default="telematics", max_length=64)
    last_synced_at: ISTDateTime | None = None


class SiteConfigIO(BaseModel):
    """The docking schedule — one aggregate, replaced wholesale on PUT.

    Held together rather than as loose key/values so validation can reason
    across fields: a reminder lead longer than the interval it warns about is
    incoherent.
    """

    site_code: str = ""
    service_plans: list[ServicePlanIO] = Field(default_factory=list)
    shifts: list[ShiftWindowIO] = Field(default_factory=list)
    reminder_lead_km: int = Field(default=500, ge=0, le=1_000_000)
    reminder_lead_days: int = Field(default=7, ge=0, le=3_650)
    docking_slot_minutes: int = Field(default=120, ge=1, le=10_080)
    max_vehicles_in_service: int = Field(default=0, ge=0, le=10_000)
    operating_categories: list[str] = Field(default_factory=lambda: ["bus"])
    odometer_sync: OdometerSyncIO = Field(default_factory=OdometerSyncIO)
    updated_at: ISTDateTime | None = None
    updated_by: str = ""

    @field_validator("operating_categories")
    @classmethod
    def _categories(cls, v: list[str]) -> list[str]:
        cleaned = sorted({c.strip().lower() for c in v if c and c.strip()})
        if not cleaned:
            raise ValueError("at least one of bus, truck is required")
        allowed = {"bus", "truck"}
        bad = [c for c in cleaned if c not in allowed]
        if bad:
            raise ValueError(f"unknown operating categories: {bad}")
        return cleaned
