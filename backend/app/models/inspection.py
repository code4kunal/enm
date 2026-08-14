from __future__ import annotations

from datetime import date as date_t
from datetime import datetime

from sqlalchemy import (
    Boolean,
    Date,
    Enum,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, TZDateTime, created_at_col, new_uuid
from app.models.enums import (
    ALERT_STATUS_ENUM,
    ALERT_TYPE_ENUM,
    SLOT_STATUS_ENUM,
    AlertStatus,
    AlertType,
    SlotStatus,
)
from app.models.master import Vehicle, WorkType
from app.models.site_config import ServicePlan


class InspectionPlan(Base):
    """How often one kind of inspection comes round, at one site.

    A rotation, not a calendar rule: every bus is due `cycle_days` after its own
    last inspection of that kind, so the fleet spreads itself evenly instead of
    everything falling due on the first of the month. MBMT runs its 10 DAYS
    SERVICE on a 10-day cycle at roughly five buses a night, which is exactly
    enough to cover 57 buses.
    """

    __tablename__ = "inspection_plans"
    __table_args__ = (
        UniqueConstraint(
            "site_code", "work_type_id", name="uq_inspection_plans_site_code_work_type_id"
        ),
    )

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_uuid)
    site_code: Mapped[str] = mapped_column(
        String(16), ForeignKey("sites.code", ondelete="CASCADE"), nullable=False
    )
    work_type_id: Mapped[int] = mapped_column(
        Integer, ForeignKey("work_types.id", ondelete="CASCADE"), nullable=False
    )
    cycle_days: Mapped[int] = mapped_column(Integer, nullable=False, default=10)
    #: Nightly cap. **0 means uncapped** — the daily inspection covers every
    #: bus every night, whereas the 10-day service is limited by bay time to
    #: about five.
    slots_per_day: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0, server_default="0"
    )
    is_active: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=True, server_default="true"
    )

    work_type: Mapped[WorkType] = relationship(lazy="joined")


class InspectionSlot(Base):
    """One bus booked in for one inspection on one night.

    The generator owns `scheduled` slots and will move them; a slot a manager
    has edited by hand is pinned (`is_pinned`) and left alone, because a person
    who chose a date had a reason the generator cannot see.
    """

    __tablename__ = "inspection_slots"
    __table_args__ = (
        UniqueConstraint(
            "site_code",
            "vehicle_id",
            "work_type_id",
            "scheduled_on",
            name="uq_inspection_slots_site_vehicle_work_type_scheduled_on",
        ),
        Index("ix_inspection_slots_site_code_scheduled_on", "site_code", "scheduled_on"),
        Index("ix_inspection_slots_status", "status"),
    )

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_uuid)
    site_code: Mapped[str] = mapped_column(
        String(16), ForeignKey("sites.code", ondelete="CASCADE"), nullable=False
    )
    vehicle_id: Mapped[str] = mapped_column(
        String(32), ForeignKey("vehicles.id", ondelete="CASCADE"), nullable=False
    )
    work_type_id: Mapped[int] = mapped_column(
        Integer, ForeignKey("work_types.id", ondelete="CASCADE"), nullable=False
    )
    #: Which rung of the docking ladder this books, when it books one.
    service_plan_id: Mapped[str | None] = mapped_column(
        String(32), ForeignKey("service_plans.id", ondelete="SET NULL"), nullable=True
    )
    scheduled_on: Mapped[date_t] = mapped_column(Date, nullable=False)
    status: Mapped[SlotStatus] = mapped_column(
        Enum(
            SlotStatus,
            name=SLOT_STATUS_ENUM,
            values_callable=lambda e: [m.value for m in e],
        ),
        nullable=False,
        default=SlotStatus.scheduled,
    )
    #: Set when a manager moved or created this slot by hand.
    is_pinned: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default="false"
    )
    #: The register entry that discharged it, and when.
    completed_entry_id: Mapped[str | None] = mapped_column(
        String(32), ForeignKey("entries.id", ondelete="SET NULL"), nullable=True
    )
    completed_on: Mapped[date_t | None] = mapped_column(Date, nullable=True)
    notes: Mapped[str] = mapped_column(
        Text, nullable=False, default="", server_default=""
    )
    created_at: Mapped[datetime] = created_at_col()
    updated_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)

    vehicle: Mapped[Vehicle] = relationship(lazy="joined")
    service_plan: Mapped[ServicePlan | None] = relationship(lazy="joined")
    work_type: Mapped[WorkType] = relationship(lazy="joined")


class Alert(Base):
    """Something a site has to look at: a missed inspection, an open breakdown,
    a service past due.

    `dedupe_key` is what stops the nightly run from raising the same alert every
    night — one open alert per real-world problem, re-raised only once it has
    been resolved and recurs.
    """

    __tablename__ = "alerts"
    __table_args__ = (
        UniqueConstraint(
            "site_code", "dedupe_key", name="uq_alerts_site_code_dedupe_key"
        ),
        Index("ix_alerts_site_code_status", "site_code", "status"),
        Index("ix_alerts_raised_on", "raised_on"),
    )

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_uuid)
    site_code: Mapped[str] = mapped_column(
        String(16), ForeignKey("sites.code", ondelete="CASCADE"), nullable=False
    )
    type: Mapped[AlertType] = mapped_column(
        Enum(
            AlertType,
            name=ALERT_TYPE_ENUM,
            values_callable=lambda e: [m.value for m in e],
        ),
        nullable=False,
    )
    status: Mapped[AlertStatus] = mapped_column(
        Enum(
            AlertStatus,
            name=ALERT_STATUS_ENUM,
            values_callable=lambda e: [m.value for m in e],
        ),
        nullable=False,
        default=AlertStatus.open,
    )
    #: Stable identity of the underlying problem, e.g. "missed:<slot_id>".
    dedupe_key: Mapped[str] = mapped_column(String(120), nullable=False)
    title: Mapped[str] = mapped_column(String(255), nullable=False)
    body: Mapped[str] = mapped_column(Text, nullable=False, default="")
    vehicle_id: Mapped[str | None] = mapped_column(
        String(32), ForeignKey("vehicles.id", ondelete="CASCADE"), nullable=True
    )
    slot_id: Mapped[str | None] = mapped_column(
        String(32), ForeignKey("inspection_slots.id", ondelete="CASCADE"), nullable=True
    )
    entry_id: Mapped[str | None] = mapped_column(
        String(32), ForeignKey("entries.id", ondelete="CASCADE"), nullable=True
    )
    raised_on: Mapped[date_t] = mapped_column(Date, nullable=False)
    created_at: Mapped[datetime] = created_at_col()
    acknowledged_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
    acknowledged_by_id: Mapped[str | None] = mapped_column(
        String(32), ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )

    vehicle: Mapped[Vehicle | None] = relationship(lazy="joined")
