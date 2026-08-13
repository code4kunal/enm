from __future__ import annotations

from datetime import datetime
from datetime import time as time_t

from sqlalchemy import (
    Boolean,
    Enum,
    ForeignKey,
    Integer,
    String,
    Text,
    Time,
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base, TZDateTime, new_uuid
from app.models.enums import SHIFT_ENUM, Shift


class SiteConfig(Base):
    """A site's preventive-maintenance configuration — the docking schedule.

    This is *maintenance*, not charging: a service falls due on whichever comes
    first, distance or elapsed time, the way paid car servicing works.
    """

    __tablename__ = "site_configs"

    site_code: Mapped[str] = mapped_column(
        String(16),
        ForeignKey("sites.code", ondelete="CASCADE"),
        primary_key=True,
    )
    # how far ahead a vehicle is flagged "due soon"
    reminder_lead_km: Mapped[int] = mapped_column(
        Integer, nullable=False, default=500, server_default="500"
    )
    reminder_lead_days: Mapped[int] = mapped_column(
        Integer, nullable=False, default=7, server_default="7"
    )
    # nominal bay time for one service
    docking_slot_minutes: Mapped[int] = mapped_column(
        Integer, nullable=False, default=120, server_default="120"
    )
    # 0 = no cap on vehicles off the road at once
    max_vehicles_in_service: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0, server_default="0"
    )
    # How many buses the site can put through an inspection in one night.
    # MBMT's sheet shows about five.
    inspection_slots_per_day: Mapped[int] = mapped_column(
        Integer, nullable=False, default=5, server_default="5"
    )
    odometer_sync_enabled: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=True, server_default="true"
    )
    odometer_sync_minutes: Mapped[int] = mapped_column(
        Integer, nullable=False, default=60, server_default="60"
    )
    odometer_sync_source: Mapped[str] = mapped_column(
        String(64), nullable=False, default="telematics", server_default="telematics"
    )
    odometer_last_synced_at: Mapped[datetime | None] = mapped_column(
        TZDateTime, nullable=True
    )
    updated_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
    updated_by_id: Mapped[str | None] = mapped_column(
        String(32), ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )

    # Plans and shift windows are keyed by site_code rather than by this row,
    # so they are loaded explicitly in `services/site_config.py`. A PUT
    # replaces the whole aggregate, which is simpler to reason about than an
    # ORM cascade across three tables.


class ServicePlan(Base):
    """One rung of a site's service ladder: minor 10,000 km, major 40,000 km.

    `interval_km = 0` means time-driven only, and vice versa.
    """

    __tablename__ = "service_plans"
    __table_args__ = (
        UniqueConstraint("site_code", "code", name="uq_service_plans_site_code_code"),
    )

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_uuid)
    site_code: Mapped[str] = mapped_column(
        String(16), ForeignKey("sites.code", ondelete="CASCADE"), nullable=False
    )
    code: Mapped[str] = mapped_column(String(16), nullable=False)
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    interval_km: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0, server_default="0"
    )
    interval_days: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0, server_default="0"
    )
    is_active: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=True, server_default="true"
    )
    notes: Mapped[str] = mapped_column(
        Text, nullable=False, default="", server_default=""
    )


class ShiftWindow(Base):
    """Site-local start/end for one operating shift.

    `end <= start` means the window wraps midnight, which the C shift usually
    does.
    """

    __tablename__ = "shift_windows"
    __table_args__ = (
        UniqueConstraint("site_code", "shift", name="uq_shift_windows_site_code_shift"),
    )

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_uuid)
    site_code: Mapped[str] = mapped_column(
        String(16), ForeignKey("sites.code", ondelete="CASCADE"), nullable=False
    )
    shift: Mapped[Shift] = mapped_column(
        Enum(Shift, name=SHIFT_ENUM, values_callable=lambda e: [m.value for m in e]),
        nullable=False,
    )
    start_time: Mapped[time_t] = mapped_column(Time, nullable=False)
    end_time: Mapped[time_t] = mapped_column(Time, nullable=False)
