from __future__ import annotations

import re
from datetime import date as date_t
from decimal import Decimal

from pydantic import BaseModel, Field, field_validator

from app.schemas.common import DecimalOut, ISTDateTime

SITE_CODE_RE = re.compile(r"^[A-Z0-9][A-Z0-9_-]{1,15}$")
ALLOWED_OPERATING_CATEGORIES = frozenset({"bus", "truck"})


def _upper_code(v: str) -> str:
    code = v.strip().upper()
    if not SITE_CODE_RE.match(code):
        raise ValueError(
            "must be 2-16 characters: letters, digits, underscore or hyphen"
        )
    return code


def _norm_registration(v: str) -> str:
    return "".join(v.split()).upper()


# --- sites -----------------------------------------------------------------


class SiteOut(BaseModel):
    code: str
    name: str
    is_active: bool
    timezone: str
    address: str
    commissioned_on: date_t | None = None
    siteops_site_id: str | None = None
    last_siteops_sync_at: ISTDateTime | None = None
    #: rollups for the site list; not authoritative
    vehicle_count: int = 0
    user_count: int = 0


class SiteList(BaseModel):
    items: list[SiteOut]


class SiteCreate(BaseModel):
    code: str = Field(min_length=2, max_length=50)
    name: str = Field(min_length=1, max_length=120)
    timezone: str = Field(default="Asia/Kolkata", max_length=64)
    address: str = Field(default="", max_length=255)
    commissioned_on: date_t | None = None
    #: Link to SiteOps at create time — triggers an immediate fleet sync.
    siteops_site_id: str | None = Field(default=None, min_length=1, max_length=64)
    #: Which checklist catalogues to seed. Default bus-only.
    operating_categories: list[str] = Field(default_factory=lambda: ["bus"])

    @field_validator("code")
    @classmethod
    def _code(cls, v: str) -> str:
        return _upper_code(v)

    @field_validator("name", "address")
    @classmethod
    def _strip(cls, v: str) -> str:
        return v.strip()

    @field_validator("siteops_site_id")
    @classmethod
    def _siteops_id(cls, v: str | None) -> str | None:
        if v is None:
            return None
        cleaned = v.strip()
        return cleaned or None

    @field_validator("operating_categories")
    @classmethod
    def _categories(cls, v: list[str]) -> list[str]:
        cleaned = sorted({c.strip().lower() for c in v if c and c.strip()})
        if not cleaned:
            raise ValueError("at least one of bus, truck is required")
        bad = [c for c in cleaned if c not in ALLOWED_OPERATING_CATEGORIES]
        if bad:
            raise ValueError(f"unknown operating categories: {bad}")
        return cleaned


class SiteUpdate(BaseModel):
    """Code is immutable — entries reference it."""

    name: str | None = Field(default=None, min_length=1, max_length=120)
    timezone: str | None = Field(default=None, max_length=64)
    address: str | None = Field(default=None, max_length=255)
    commissioned_on: date_t | None = None


# --- vehicles --------------------------------------------------------------


class VehicleOut(BaseModel):
    id: str
    registration_no: str
    site_code: str
    is_active: bool
    make: str
    model: str
    #: Which inspection checklist this bus takes, when a work type has more
    #: than one. Its own field rather than `model`, which the snag import
    #: rewrites and which does not tell an AC 12M from a non-AC one.
    checklist_variant: str | None = None
    battery_capacity_kwh: DecimalOut = None
    odometer_km: int
    #: null means never synced — treat the reading as unknown, not as 0 km
    odometer_updated_at: ISTDateTime | None = None
    last_service_km: int | None = None
    last_service_on: date_t | None = None
    last_service_code: str = ""


class VehicleList(BaseModel):
    items: list[VehicleOut]


class VehicleCreate(BaseModel):
    registration_no: str = Field(min_length=1, max_length=32)
    make: str = Field(default="", max_length=64)
    model: str = Field(default="", max_length=64)
    battery_capacity_kwh: Decimal | None = Field(default=None, ge=0, le=99999)

    @field_validator("registration_no")
    @classmethod
    def _reg(cls, v: str) -> str:
        return _norm_registration(v)


class VehicleUpdate(BaseModel):
    registration_no: str | None = Field(default=None, min_length=1, max_length=32)
    make: str | None = Field(default=None, max_length=64)
    model: str | None = Field(default=None, max_length=64)
    battery_capacity_kwh: Decimal | None = Field(default=None, ge=0, le=99999)
    is_active: bool | None = None

    @field_validator("registration_no")
    @classmethod
    def _reg(cls, v: str | None) -> str | None:
        return _norm_registration(v) if v else v


# --- odometers and services ------------------------------------------------


class OdometerIn(BaseModel):
    odometer_km: int = Field(ge=0, le=10_000_000)


class OdometerReadingOut(BaseModel):
    vehicle_id: str
    registration_no: str
    odometer_km: int
    recorded_at: ISTDateTime


class OdometerSyncOut(BaseModel):
    readings: list[OdometerReadingOut]
    synced_at: ISTDateTime
    #: vehicles the provider had nothing new for
    skipped: int = 0


class FleetSyncIn(BaseModel):
    #: Optional: set/overwrite the site's SiteOps link, then sync. Prefer
    #: linking at create time; this remains for repair / first-time link.
    siteops_site_id: str | None = Field(default=None, min_length=1, max_length=64)


class FleetSyncOut(BaseModel):
    created: int
    already_present: int
    variant_backfilled: int
    owned_elsewhere: int
    skipped_no_registration: int


class ServiceRecordIn(BaseModel):
    plan_code: str = Field(min_length=1, max_length=50)
    odometer_km: int = Field(ge=0, le=10_000_000)
    serviced_on: date_t


class ServiceDueOut(BaseModel):
    vehicle_id: str
    registration_no: str
    plan_code: str
    plan_name: str
    #: overdue | due_soon | ok | unknown
    status: str
    due_km: int | None = None
    km_remaining: int | None = None
    due_on: date_t | None = None
    days_remaining: int | None = None
    odometer_km: int | None = None
    has_odometer: bool = True


class ServiceDueList(BaseModel):
    items: list[ServiceDueOut]
