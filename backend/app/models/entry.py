from __future__ import annotations

from datetime import date as date_t
from datetime import datetime
from datetime import time as time_t
from decimal import Decimal

from sqlalchemy import (
    Date,
    Enum,
    ForeignKey,
    Index,
    Integer,
    Numeric,
    String,
    Text,
    Time,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, TZDateTime, created_at_col, new_uuid
from app.models.enums import (
    ENTRY_STATUS_ENUM,
    REGISTER_ENUM,
    SHIFT_ENUM,
    EntryStatus,
    Register,
    Shift,
)
from app.models.master import DefectSource, DefectType, Vehicle, WorkType
from app.models.user import User


def _entry_fk() -> Mapped[str]:
    return mapped_column(
        String(32),
        ForeignKey("entries.id", ondelete="CASCADE"),
        primary_key=True,
    )


def _vehicle_fk(nullable: bool = False) -> Mapped[str]:
    """Column stays `bus_id` — the paper register says "Bus No"."""
    return mapped_column(
        String(32),
        ForeignKey("vehicles.id", ondelete="RESTRICT"),
        nullable=nullable,
    )


class Entry(Base):
    """Common header for every register entry.

    Register-specific columns live in the five child tables below (strict
    relational modelling, no JSON blobs). `bus_id` and `search_text` are
    deliberately denormalized onto the header: every register requires a vehicle,
    and free-text search must not fan out across five LEFT JOINs.
    """

    __tablename__ = "entries"
    __table_args__ = (
        Index("ix_entries_site_code_entry_date", "site_code", "entry_date"),
        Index("ix_entries_register_status", "register", "status"),
        Index("ix_entries_bus_id", "bus_id"),
        Index("ix_entries_work_type_id_entry_date", "work_type_id", "entry_date"),
        Index("ix_entries_created_by_id", "created_by_id"),
        Index("ix_entries_entry_date_created_at", "entry_date", "created_at"),
        # backs the `q` free-text filter without fanning out over five joins
        Index(
            "ix_entries_search_text_trgm",
            "search_text",
            postgresql_using="gin",
            postgresql_ops={"search_text": "gin_trgm_ops"},
        ),
    )

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_uuid)
    register: Mapped[Register] = mapped_column(
        Enum(
            Register,
            name=REGISTER_ENUM,
            values_callable=lambda e: [m.value for m in e],
        ),
        nullable=False,
    )
    site_code: Mapped[str] = mapped_column(
        String(16), ForeignKey("sites.code", ondelete="RESTRICT"), nullable=False
    )
    bus_id: Mapped[str] = _vehicle_fk()
    # Which TYPE OF WORK this was. Null for entries typed straight into a
    # register; set by the snag import and by completing a scheduled slot, and
    # it is what lets the scheduler see an inspection actually happened.
    work_type_id: Mapped[int | None] = mapped_column(
        Integer, ForeignKey("work_types.id", ondelete="SET NULL"), nullable=True
    )
    entry_date: Mapped[date_t] = mapped_column(Date, nullable=False)
    entry_time: Mapped[time_t | None] = mapped_column(Time, nullable=True)
    status: Mapped[EntryStatus] = mapped_column(
        Enum(
            EntryStatus,
            name=ENTRY_STATUS_ENUM,
            values_callable=lambda e: [m.value for m in e],
        ),
        nullable=False,
        default=EntryStatus.done,
    )
    photo_url: Mapped[str | None] = mapped_column(String(1024), nullable=True)
    photo_key: Mapped[str | None] = mapped_column(String(512), nullable=True)
    # denormalized haystack for `q` search; GIN trgm indexed in migration
    search_text: Mapped[str] = mapped_column(Text, nullable=False, default="")

    created_by_id: Mapped[str] = mapped_column(
        String(32), ForeignKey("users.id", ondelete="RESTRICT"), nullable=False
    )
    created_at: Mapped[datetime] = created_at_col()
    updated_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)

    vehicle: Mapped[Vehicle] = relationship(lazy="joined")
    work_type: Mapped[WorkType | None] = relationship(lazy="joined")
    created_by: Mapped[User] = relationship(lazy="joined", foreign_keys=[created_by_id])

    work_done: Mapped[WorkDoneEntry | None] = relationship(
        back_populates="entry", cascade="all, delete-orphan", lazy="selectin",
        uselist=False,
    )
    coolant: Mapped[CoolantEntry | None] = relationship(
        back_populates="entry", cascade="all, delete-orphan", lazy="selectin",
        uselist=False,
    )
    driver_complaint: Mapped[DriverComplaintEntry | None] = relationship(
        back_populates="entry", cascade="all, delete-orphan", lazy="selectin",
        uselist=False,
    )
    breakdown: Mapped[BreakdownEntry | None] = relationship(
        back_populates="entry", cascade="all, delete-orphan", lazy="selectin",
        uselist=False,
    )
    pm_schedule: Mapped[PMScheduleEntry | None] = relationship(
        back_populates="entry", cascade="all, delete-orphan", lazy="selectin",
        uselist=False,
    )

    @property
    def detail(
        self,
    ) -> WorkDoneEntry | CoolantEntry | DriverComplaintEntry | BreakdownEntry | PMScheduleEntry | None:
        return getattr(self, self.register.value, None)


class WorkDoneEntry(Base):
    __tablename__ = "work_done_entries"

    entry_id: Mapped[str] = _entry_fk()
    shift: Mapped[Shift | None] = mapped_column(
        Enum(Shift, name=SHIFT_ENUM, values_callable=lambda e: [m.value for m in e]),
        nullable=True,
    )
    reported_defects: Mapped[str] = mapped_column(Text, nullable=False)
    defect_source_id: Mapped[int | None] = mapped_column(
        Integer, ForeignKey("defect_sources.id", ondelete="RESTRICT"), nullable=True
    )
    defect_type_id: Mapped[int | None] = mapped_column(
        Integer, ForeignKey("defect_types.id", ondelete="RESTRICT"), nullable=True
    )
    attended_details: Mapped[str | None] = mapped_column(Text, nullable=True)
    spare_parts_used: Mapped[str | None] = mapped_column(Text, nullable=True)
    employee: Mapped[str | None] = mapped_column(String(255), nullable=True)
    # Floor supervisor who signed the job off. A name, not an FK: the
    # supervisor of a 2024 entry must still read correctly after they leave.
    supervisor: Mapped[str | None] = mapped_column(String(255), nullable=True)

    entry: Mapped[Entry] = relationship(back_populates="work_done")
    defect_source: Mapped[DefectSource | None] = relationship(lazy="joined")
    defect_type: Mapped[DefectType | None] = relationship(lazy="joined")


class CoolantEntry(Base):
    __tablename__ = "coolant_entries"

    entry_id: Mapped[str] = _entry_fk()
    bcs_litres: Mapped[Decimal | None] = mapped_column(Numeric(8, 2), nullable=True)
    tcs_litres: Mapped[Decimal | None] = mapped_column(Numeric(8, 2), nullable=True)
    topped_by: Mapped[str | None] = mapped_column(String(255), nullable=True)
    # Floor supervisor who signed the job off. A name, not an FK: the
    # supervisor of a 2024 entry must still read correctly after they leave.
    supervisor: Mapped[str | None] = mapped_column(String(255), nullable=True)

    entry: Mapped[Entry] = relationship(back_populates="coolant")


class DriverComplaintEntry(Base):
    __tablename__ = "driver_complaint_entries"

    entry_id: Mapped[str] = _entry_fk()
    defect_type_id: Mapped[int | None] = mapped_column(
        Integer, ForeignKey("defect_types.id", ondelete="RESTRICT"), nullable=True
    )
    complaint: Mapped[str] = mapped_column(Text, nullable=False)
    rectification_action: Mapped[str | None] = mapped_column(Text, nullable=True)
    mechanic: Mapped[str | None] = mapped_column(String(255), nullable=True)
    # Floor supervisor who signed the job off. A name, not an FK: the
    # supervisor of a 2024 entry must still read correctly after they leave.
    supervisor: Mapped[str | None] = mapped_column(String(255), nullable=True)

    entry: Mapped[Entry] = relationship(back_populates="driver_complaint")
    defect_type: Mapped[DefectType | None] = relationship(lazy="joined")


class BreakdownEntry(Base):
    __tablename__ = "breakdown_entries"

    entry_id: Mapped[str] = _entry_fk()
    driver_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    location: Mapped[str | None] = mapped_column(String(255), nullable=True)
    complaint: Mapped[str] = mapped_column(Text, nullable=False)
    breakdown_time: Mapped[time_t | None] = mapped_column(Time, nullable=True)
    mechanic_reported_time: Mapped[time_t | None] = mapped_column(Time, nullable=True)
    attended_time: Mapped[time_t | None] = mapped_column(Time, nullable=True)
    loss_km: Mapped[Decimal | None] = mapped_column(Numeric(8, 2), nullable=True)
    attended_details: Mapped[str | None] = mapped_column(Text, nullable=True)
    remarks: Mapped[str | None] = mapped_column(Text, nullable=True)
    # Floor supervisor who signed the job off. A name, not an FK: the
    # supervisor of a 2024 entry must still read correctly after they leave.
    supervisor: Mapped[str | None] = mapped_column(String(255), nullable=True)
    resolved_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
    resolved_by_id: Mapped[str | None] = mapped_column(
        String(32), ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
    # set when the SLA nudge has fired, so it fires at most once per breakdown
    sla_notified_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)

    entry: Mapped[Entry] = relationship(back_populates="breakdown")
    resolved_by: Mapped[User | None] = relationship(
        lazy="joined", foreign_keys=[resolved_by_id]
    )


class PMScheduleEntry(Base):
    __tablename__ = "pm_schedule_entries"

    entry_id: Mapped[str] = _entry_fk()
    defect_type_id: Mapped[int | None] = mapped_column(
        Integer, ForeignKey("defect_types.id", ondelete="RESTRICT"), nullable=True
    )
    defects_noticed: Mapped[str] = mapped_column(Text, nullable=False)
    action_taken: Mapped[str | None] = mapped_column(Text, nullable=True)
    balance_job_reason: Mapped[str | None] = mapped_column(Text, nullable=True)
    spare_parts_used: Mapped[str | None] = mapped_column(Text, nullable=True)
    employees: Mapped[str | None] = mapped_column(Text, nullable=True)
    # Floor supervisor who signed the job off. A name, not an FK: the
    # supervisor of a 2024 entry must still read correctly after they leave.
    supervisor: Mapped[str | None] = mapped_column(String(255), nullable=True)

    entry: Mapped[Entry] = relationship(back_populates="pm_schedule")
    defect_type: Mapped[DefectType | None] = relationship(lazy="joined")


REGISTER_MODELS: dict[Register, type[Base]] = {
    Register.work_done: WorkDoneEntry,
    Register.coolant: CoolantEntry,
    Register.driver_complaint: DriverComplaintEntry,
    Register.breakdown: BreakdownEntry,
    Register.pm_schedule: PMScheduleEntry,
}
