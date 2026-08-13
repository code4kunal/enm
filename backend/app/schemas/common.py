from __future__ import annotations

from datetime import UTC, datetime, time
from decimal import Decimal
from typing import Annotated, Generic, TypeVar
from zoneinfo import ZoneInfo

from pydantic import BaseModel, BeforeValidator, Field, PlainSerializer

from app.config import settings

IST = ZoneInfo(settings.timezone)

T = TypeVar("T")


def _to_ist(value: datetime | None) -> str | None:
    if value is None:
        return None
    if value.tzinfo is None:
        value = value.replace(tzinfo=UTC)
    return value.astimezone(IST).isoformat(timespec="seconds")


def _hhmm(value: time | None) -> str | None:
    return None if value is None else value.strftime("%H:%M")


def _blank_to_none(value: object) -> object:
    if isinstance(value, str) and not value.strip():
        return None
    return value


#: ISO 8601 timestamp rendered in IST, e.g. "2026-08-13T07:40:12+05:30"
ISTDateTime = Annotated[datetime, PlainSerializer(_to_ist, return_type=str)]
#: 24h wall-clock time rendered as "HH:MM"
HHMM = Annotated[
    time, BeforeValidator(_blank_to_none), PlainSerializer(_hhmm, return_type=str)
]
#: Optional free-text field where "" from a mobile form means "not provided"
OptText = Annotated[str | None, BeforeValidator(_blank_to_none)]


def _decimal_out(value: Decimal | None) -> float | None:
    return None if value is None else float(value)


#: A decimal stored exactly and sent as a JSON number.
#:
#: Pydantic renders Decimal as a *string* by default, and the Dart client casts
#: these to `num` — so "250.00" would blow up at the seam. Storage keeps the
#: Decimal; only the wire form is a number.
DecimalOut = Annotated[
    Decimal | None, PlainSerializer(_decimal_out, return_type=float | None)
]


class Page(BaseModel, Generic[T]):
    items: list[T]
    page: int
    page_size: int
    total: int


class PageParams(BaseModel):
    page: int = Field(default=1, ge=1)
    page_size: int = Field(
        default=settings.default_page_size, ge=1, le=settings.max_page_size
    )

    @property
    def offset(self) -> int:
        return (self.page - 1) * self.page_size


class Ok(BaseModel):
    ok: bool = True
