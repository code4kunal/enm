from __future__ import annotations

from datetime import date as date_t
from datetime import datetime
from decimal import Decimal

from sqlalchemy import (
    Boolean,
    Date,
    Enum,
    ForeignKey,
    Index,
    Integer,
    Numeric,
    String,
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, TZDateTime, created_at_col, new_uuid
from app.models.enums import (
    DEFECT_CATEGORY_ENUM,
    REGISTER_ENUM,
    DefectCategory,
    Register,
)


class Site(Base):
    """The tenant unit — one depot, one site.

    Admin-managed, not a seeded lookup: super admins onboard sites from the UI
    and everything else (vehicles, entries, config, import profiles) hangs off
    exactly one of them.
    """

    __tablename__ = "sites"

    code: Mapped[str] = mapped_column(String(16), primary_key=True)
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    is_active: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=True, server_default="true"
    )
    timezone: Mapped[str] = mapped_column(
        String(64), nullable=False, default="Asia/Kolkata", server_default="Asia/Kolkata"
    )
    address: Mapped[str] = mapped_column(
        String(255), nullable=False, default="", server_default=""
    )
    commissioned_on: Mapped[date_t | None] = mapped_column(Date, nullable=True)
    created_at: Mapped[datetime] = created_at_col()
    updated_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)

    vehicles: Mapped[list[Vehicle]] = relationship(back_populates="site")


class Vehicle(Base):
    """A bus on a site's fleet.

    The master entity is a *vehicle*; the register *column* is still "Bus No",
    because that is what the paper register says.
    """

    __tablename__ = "vehicles"
    __table_args__ = (
        UniqueConstraint("registration_no", name="uq_vehicles_registration_no"),
        Index("ix_vehicles_site_code_is_active", "site_code", "is_active"),
    )

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_uuid)
    # normalized: uppercase, no whitespace
    registration_no: Mapped[str] = mapped_column(String(32), nullable=False)
    site_code: Mapped[str] = mapped_column(
        String(16), ForeignKey("sites.code", ondelete="RESTRICT"), nullable=False
    )
    is_active: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=True, server_default="true"
    )
    make: Mapped[str] = mapped_column(
        String(64), nullable=False, default="", server_default=""
    )
    model: Mapped[str] = mapped_column(
        String(64), nullable=False, default="", server_default=""
    )
    battery_capacity_kwh: Mapped[Decimal | None] = mapped_column(
        Numeric(8, 2), nullable=True
    )

    # The whole maintenance schedule is distance-driven, so this is the
    # load-bearing number. `odometer_updated_at` NULL means never synced —
    # report that as unknown, never as 0 km.
    odometer_km: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0, server_default="0"
    )
    odometer_updated_at: Mapped[datetime | None] = mapped_column(
        TZDateTime, nullable=True
    )
    last_service_km: Mapped[int | None] = mapped_column(Integer, nullable=True)
    last_service_on: Mapped[date_t | None] = mapped_column(Date, nullable=True)
    last_service_code: Mapped[str] = mapped_column(
        String(16), nullable=False, default="", server_default=""
    )

    site: Mapped[Site] = relationship(back_populates="vehicles")


class OdometerReading(Base):
    """Append-only reading history; the vehicle row caches the latest."""

    __tablename__ = "odometer_readings"
    __table_args__ = (
        Index("ix_odometer_readings_vehicle_id_recorded_at", "vehicle_id", "recorded_at"),
    )

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_uuid)
    vehicle_id: Mapped[str] = mapped_column(
        String(32), ForeignKey("vehicles.id", ondelete="CASCADE"), nullable=False
    )
    odometer_km: Mapped[int] = mapped_column(Integer, nullable=False)
    recorded_at: Mapped[datetime] = mapped_column(TZDateTime, nullable=False)
    source: Mapped[str] = mapped_column(
        String(64), nullable=False, default="manual", server_default="manual"
    )


class DefectSource(Base):
    """Master list backing the Defect Source dropdown."""

    __tablename__ = "defect_sources"
    __table_args__ = (UniqueConstraint("name", name="uq_defect_sources_name"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    sort_order: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    is_active: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=True, server_default="true"
    )


class DefectType(Base):
    """Master list backing the Defect Type dropdown.

    `category` is what lets the Daily Maintenance Report split breakdowns into
    Mechanical / Electrical / Body / AC / ITS / Tyre without hard-coding the
    site's own GROUP names.
    """

    __tablename__ = "defect_types"
    __table_args__ = (UniqueConstraint("name", name="uq_defect_types_name"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    category: Mapped[DefectCategory] = mapped_column(
        Enum(
            DefectCategory,
            name=DEFECT_CATEGORY_ENUM,
            values_callable=lambda e: [m.value for m in e],
        ),
        nullable=False,
        default=DefectCategory.other,
        server_default="other",
    )
    sort_order: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    is_active: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=True, server_default="true"
    )


class WorkType(Base):
    """The "TYPE OF WORK" vocabulary a site writes on its snag report.

    A site's daily sheet mixes every kind of job in one list — a breakdown, a
    daily inspection, a docking — and this column is what says which. Each code
    routes its rows to a register, so the routing is data a manager can edit
    rather than a hard-coded table:

        B.D → breakdown, D.C → driver complaint, DEPOT → daily work done,
        D.I / 10 DAYS SERVICE / P.M → PM schedule.

    A code either files into a `register`, or is an `is_inspection` code with
    its own checklist. A code that is neither is recognised but not yet routed;
    its rows are rejected by name rather than silently dropped.
    """

    __tablename__ = "work_types"
    __table_args__ = (UniqueConstraint("code", name="uq_work_types_code"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    # As written on the sheet, upper-cased: "B.D", "10 DAYS SERVICE".
    code: Mapped[str] = mapped_column(String(32), nullable=False)
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    register: Mapped[Register | None] = mapped_column(
        Enum(
            Register,
            name=REGISTER_ENUM,
            values_callable=lambda e: [m.value for m in e],
        ),
        nullable=True,
    )
    # A checklist sweep rather than a register entry. D.I and the 10-day
    # service are inspections: they have their own checklist, their own form
    # and their own record, and `register` is null for them.
    is_inspection: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default="false"
    )
    sort_order: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    is_active: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=True, server_default="true"
    )
