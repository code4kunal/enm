from __future__ import annotations

from datetime import date as date_t
from datetime import datetime
from datetime import time as time_t

from sqlalchemy import (
    Boolean,
    Date,
    Enum,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    Time,
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, TZDateTime, created_at_col, new_uuid
from app.models.enums import (
    CHECK_RESULT_ENUM,
    RESPONSE_TYPE_ENUM,
    CheckResult,
    ResponseType,
)
from app.models.master import Vehicle, WorkType
from app.models.user import User


class ChecklistTemplate(Base):
    """The list of things to check for one kind of inspection, at one site.

    A daily inspection and a ten-day service are different jobs with different
    sheets, so each work type gets its own template and its own data entry.
    Per site, because depots do not run identical checklists.
    """

    __tablename__ = "checklist_templates"
    __table_args__ = (
        UniqueConstraint(
            "site_code",
            "work_type_id",
            name="uq_checklist_templates_site_code_work_type_id",
        ),
    )

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_uuid)
    site_code: Mapped[str] = mapped_column(
        String(16), ForeignKey("sites.code", ondelete="CASCADE"), nullable=False
    )
    work_type_id: Mapped[int] = mapped_column(
        Integer, ForeignKey("work_types.id", ondelete="CASCADE"), nullable=False
    )
    name: Mapped[str] = mapped_column(String(160), nullable=False)
    is_active: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=True, server_default="true"
    )
    updated_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)

    work_type: Mapped[WorkType] = relationship(lazy="joined")
    items: Mapped[list[ChecklistItem]] = relationship(
        back_populates="template",
        cascade="all, delete-orphan",
        lazy="selectin",
        order_by="ChecklistItem.sort_order",
    )


class ChecklistItem(Base):
    """One line on a checklist.

    Kept as rows rather than a JSON blob so a result can point at the exact item
    it answers, and so an item can be retired without rewriting history.
    """

    __tablename__ = "checklist_items"
    __table_args__ = (
        Index("ix_checklist_items_template_id_sort_order", "template_id", "sort_order"),
    )

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_uuid)
    template_id: Mapped[str] = mapped_column(
        String(32),
        ForeignKey("checklist_templates.id", ondelete="CASCADE"),
        nullable=False,
    )
    #: Groups items on the form: "Brakes", "Body", "HV system".
    section: Mapped[str] = mapped_column(
        String(80), nullable=False, default="", server_default=""
    )
    label: Mapped[str] = mapped_column(String(255), nullable=False)
    sort_order: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    response_type: Mapped[ResponseType] = mapped_column(
        Enum(
            ResponseType,
            name=RESPONSE_TYPE_ENUM,
            values_callable=lambda e: [m.value for m in e],
        ),
        nullable=False,
        default=ResponseType.ok_not_ok,
    )
    is_required: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=True, server_default="true"
    )
    is_active: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=True, server_default="true"
    )

    template: Mapped[ChecklistTemplate] = relationship(back_populates="items")


class InspectionEntry(Base):
    """One inspection, carried out on one bus.

    Its own record rather than a register entry: the five paper registers stay
    what they are, and an inspection is a checklist sweep, which is a different
    shape from "defects noticed". A defect found during one is still written up
    in the register it belongs to.
    """

    __tablename__ = "inspection_entries"
    __table_args__ = (
        Index(
            "ix_inspection_entries_site_code_inspected_on",
            "site_code",
            "inspected_on",
        ),
        Index(
            "ix_inspection_entries_vehicle_id_work_type_id",
            "vehicle_id",
            "work_type_id",
        ),
    )

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_uuid)
    site_code: Mapped[str] = mapped_column(
        String(16), ForeignKey("sites.code", ondelete="RESTRICT"), nullable=False
    )
    vehicle_id: Mapped[str] = mapped_column(
        String(32), ForeignKey("vehicles.id", ondelete="RESTRICT"), nullable=False
    )
    work_type_id: Mapped[int] = mapped_column(
        Integer, ForeignKey("work_types.id", ondelete="RESTRICT"), nullable=False
    )
    inspected_on: Mapped[date_t] = mapped_column(Date, nullable=False)
    entry_time: Mapped[time_t | None] = mapped_column(Time, nullable=True)
    #: Names, not FKs: the mechanic on a 2024 inspection must still read
    #: correctly after they leave the depot.
    done_by: Mapped[str | None] = mapped_column(String(255), nullable=True)
    supervisor: Mapped[str | None] = mapped_column(String(255), nullable=True)
    odometer_km: Mapped[int | None] = mapped_column(Integer, nullable=True)
    remarks: Mapped[str | None] = mapped_column(Text, nullable=True)
    #: The booking this discharged, when it came off the calendar.
    slot_id: Mapped[str | None] = mapped_column(
        String(32), ForeignKey("inspection_slots.id", ondelete="SET NULL"), nullable=True
    )
    created_by_id: Mapped[str] = mapped_column(
        String(32), ForeignKey("users.id", ondelete="RESTRICT"), nullable=False
    )
    created_at: Mapped[datetime] = created_at_col()
    updated_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)

    vehicle: Mapped[Vehicle] = relationship(lazy="joined")
    work_type: Mapped[WorkType] = relationship(lazy="joined")
    created_by: Mapped[User] = relationship(lazy="joined")
    results: Mapped[list[InspectionResult]] = relationship(
        back_populates="inspection",
        cascade="all, delete-orphan",
        lazy="selectin",
    )

    @property
    def failed(self) -> list[InspectionResult]:
        return [r for r in self.results if r.result is CheckResult.not_ok]


class InspectionResult(Base):
    """What one checklist item came back as."""

    __tablename__ = "inspection_results"
    __table_args__ = (
        UniqueConstraint(
            "inspection_id", "item_id", name="uq_inspection_results_inspection_id_item_id"
        ),
    )

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_uuid)
    inspection_id: Mapped[str] = mapped_column(
        String(32),
        ForeignKey("inspection_entries.id", ondelete="CASCADE"),
        nullable=False,
    )
    item_id: Mapped[str] = mapped_column(
        String(32), ForeignKey("checklist_items.id", ondelete="RESTRICT"), nullable=False
    )
    result: Mapped[CheckResult] = mapped_column(
        Enum(
            CheckResult,
            name=CHECK_RESULT_ENUM,
            values_callable=lambda e: [m.value for m in e],
        ),
        nullable=False,
        default=CheckResult.ok,
    )
    #: For a reading or a note item, and for why something failed.
    value: Mapped[str | None] = mapped_column(String(255), nullable=True)
    remark: Mapped[str | None] = mapped_column(Text, nullable=True)

    inspection: Mapped[InspectionEntry] = relationship(back_populates="results")
    item: Mapped[ChecklistItem] = relationship(lazy="joined")
