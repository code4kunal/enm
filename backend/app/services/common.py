from __future__ import annotations

from datetime import date as date_t
from datetime import datetime
from zoneinfo import ZoneInfo

from app.config import settings

IST = ZoneInfo(settings.timezone)


def now_ist() -> datetime:
    """Site wall-clock, not UTC — entry times and due dates are local."""
    return datetime.now(IST)


def today_ist() -> date_t:
    return now_ist().date()
