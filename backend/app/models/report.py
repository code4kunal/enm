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
    Text,
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, TZDateTime, created_at_col, new_uuid
from app.models.entry import Entry
from app.models.enums import DEFECT_CATEGORY_ENUM, DefectCategory
from app.models.master import Vehicle
from app.models.user import User


class DmrDay(Base):
    """One day of the Daily Maintenance Report.

    Two kinds of number live here. Most of the report is *derived* — breakdowns,
    driver complaints, inspections attended, coolant, loss of km — and is
    recomputed from the registers until the day is snapshotted, after which the
    stored figure is what was reported and stays that way.

    The rest is *entered*: how many buses went on road, tyres scrapped,
    accidents in the depot. Nothing in the system observes those, and inventing
    them would be worse than asking.
    """

    __tablename__ = "dmr_days"
    __table_args__ = (
        UniqueConstraint("site_code", "report_date", name="uq_dmr_days_site_code_report_date"),
        Index("ix_dmr_days_site_code_report_date", "site_code", "report_date"),
    )

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_uuid)
    site_code: Mapped[str] = mapped_column(
        String(50), ForeignKey("sites.code", ondelete="CASCADE"), nullable=False
    )
    report_date: Mapped[date_t] = mapped_column(Date, nullable=False)

    # --- entered: nothing else in the system knows these -------------------
    on_road: Mapped[int | None] = mapped_column(Integer, nullable=True)
    spare: Mapped[int | None] = mapped_column(Integer, nullable=True)
    under_warranty: Mapped[int | None] = mapped_column(Integer, nullable=True)
    rto_passing: Mapped[int | None] = mapped_column(Integer, nullable=True)
    high_energy_consumption: Mapped[int | None] = mapped_column(Integer, nullable=True)
    deep_cleaning: Mapped[int | None] = mapped_column(Integer, nullable=True)
    washed_cleaned: Mapped[int | None] = mapped_column(Integer, nullable=True)
    depot_accidents: Mapped[int | None] = mapped_column(Integer, nullable=True)
    tyres_scrapped: Mapped[int | None] = mapped_column(Integer, nullable=True)
    hv_batteries_replaced: Mapped[int | None] = mapped_column(Integer, nullable=True)
    body_damages: Mapped[int | None] = mapped_column(Integer, nullable=True)
    notes: Mapped[str] = mapped_column(
        Text, nullable=False, default="", server_default=""
    )

    # --- snapshot: what was reported, frozen ------------------------------
    #: Null until the day is snapshotted; the derived lines are live until then.
    generated_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
    total_fleet: Mapped[int | None] = mapped_column(Integer, nullable=True)
    defective_in_depot: Mapped[int | None] = mapped_column(Integer, nullable=True)
    defects_mechanical: Mapped[int | None] = mapped_column(Integer, nullable=True)
    defects_body: Mapped[int | None] = mapped_column(Integer, nullable=True)
    defects_electrical: Mapped[int | None] = mapped_column(Integer, nullable=True)
    defects_ac: Mapped[int | None] = mapped_column(Integer, nullable=True)
    defects_its: Mapped[int | None] = mapped_column(Integer, nullable=True)
    held_over_three_days: Mapped[int | None] = mapped_column(Integer, nullable=True)
    breakdowns: Mapped[int | None] = mapped_column(Integer, nullable=True)
    breakdowns_mechanical: Mapped[int | None] = mapped_column(Integer, nullable=True)
    breakdowns_electrical: Mapped[int | None] = mapped_column(Integer, nullable=True)
    breakdowns_tyre: Mapped[int | None] = mapped_column(Integer, nullable=True)
    breakdowns_ac: Mapped[int | None] = mapped_column(Integer, nullable=True)
    breakdowns_its: Mapped[int | None] = mapped_column(Integer, nullable=True)
    loss_km: Mapped[Decimal | None] = mapped_column(Numeric(10, 2), nullable=True)
    driver_complaints: Mapped[int | None] = mapped_column(Integer, nullable=True)
    daily_inspections: Mapped[int | None] = mapped_column(Integer, nullable=True)
    periodic_pm: Mapped[int | None] = mapped_column(Integer, nullable=True)
    dockings: Mapped[int | None] = mapped_column(Integer, nullable=True)
    coolant_litres: Mapped[Decimal | None] = mapped_column(
        Numeric(10, 2), nullable=True
    )

    updated_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
    updated_by_id: Mapped[str | None] = mapped_column(
        String(32), ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )


class BreakdownInvestigation(Base):
    """Annexure-V: the root-cause follow-up to one breakdown.

    A breakdown and its investigation are the same event seen twice — the
    register records what happened, this records why and what was done to stop
    it happening again. One per breakdown, which is why `entry_id` is unique
    rather than a loose date-and-bus match.

    Three of its columns are answerable from data already held: when the bus
    last had a PM, what that PM turned up, and what the driver had already
    complained about. Those are filled in for the investigator rather than
    looked up by hand.
    """

    __tablename__ = "breakdown_investigations"
    __table_args__ = (
        UniqueConstraint("entry_id", name="uq_breakdown_investigations_entry_id"),
    )

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_uuid)
    entry_id: Mapped[str] = mapped_column(
        String(32), ForeignKey("entries.id", ondelete="CASCADE"), nullable=False
    )

    #: What was actually found — the diagnosis behind the reported symptom.
    findings: Mapped[str | None] = mapped_column(Text, nullable=True)
    #: When the bus last had a PM, and what that PM reported. Pre-filled from
    #: the inspection history; an investigator may correct either.
    last_pm_on: Mapped[date_t | None] = mapped_column(Date, nullable=True)
    last_pm_findings: Mapped[str | None] = mapped_column(Text, nullable=True)
    #: What the driver had already reported on this bus beforehand.
    related_complaints: Mapped[str | None] = mapped_column(Text, nullable=True)
    #: The corrective action taken to prevent a recurrence.
    investigation_action: Mapped[str | None] = mapped_column(Text, nullable=True)

    created_at: Mapped[datetime] = created_at_col()
    updated_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
    updated_by_id: Mapped[str | None] = mapped_column(
        String(32), ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )

    entry: Mapped[Entry] = relationship(lazy="joined")
    updated_by: Mapped[User | None] = relationship(lazy="joined")

    @property
    def is_complete(self) -> bool:
        """An investigation with no finding and no action is not an
        investigation, it is a placeholder."""
        return bool(
            (self.findings or "").strip()
            and (self.investigation_action or "").strip()
        )


class OffRoadCase(Base):
    """A bus that is off the road, from the day it went down to the day it ran.

    The depot restates this list every morning — issue, what has been done,
    what part is awaited, when it is expected back. Held as a *case* with a
    lifecycle rather than a row per day, because it is one problem being worked
    on, not thirty separate facts. The daily sheet is a view of the cases open
    that morning.

    This is also what the Daily Maintenance Report counts as "defective buses in
    depot", its split by category, and "held more than three days".
    """

    __tablename__ = "off_road_cases"
    __table_args__ = (
        Index("ix_off_road_cases_site_code_off_road_since", "site_code", "off_road_since"),
        Index("ix_off_road_cases_vehicle_id_returned_on", "vehicle_id", "returned_on"),
    )

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_uuid)
    site_code: Mapped[str] = mapped_column(
        String(50), ForeignKey("sites.code", ondelete="CASCADE"), nullable=False
    )
    vehicle_id: Mapped[str] = mapped_column(
        String(32), ForeignKey("vehicles.id", ondelete="RESTRICT"), nullable=False
    )
    #: The breakdown that put it here, when there was one.
    entry_id: Mapped[str | None] = mapped_column(
        String(32), ForeignKey("entries.id", ondelete="SET NULL"), nullable=True
    )

    issue: Mapped[str] = mapped_column(Text, nullable=False, default="")
    action_taken: Mapped[str | None] = mapped_column(Text, nullable=True)
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

    off_road_since: Mapped[date_t] = mapped_column(Date, nullable=False)
    #: What the depot committed to: how many days, and the date that implies.
    expected_days: Mapped[int | None] = mapped_column(Integer, nullable=True)
    expected_ready_on: Mapped[date_t | None] = mapped_column(Date, nullable=True)
    #: Null while the bus is still down — the open/closed flag and the date in
    #: one field, so "was it off the road on the 3rd" is one comparison.
    returned_on: Mapped[date_t | None] = mapped_column(Date, nullable=True)

    odometer_km: Mapped[int | None] = mapped_column(Integer, nullable=True)
    spare_parts_required: Mapped[str | None] = mapped_column(Text, nullable=True)
    remarks: Mapped[str | None] = mapped_column(Text, nullable=True)
    #: Waiting on someone else — EKA, Octillion, JTAC. Why a day slipped.
    awaiting_vendor: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default="false"
    )

    created_at: Mapped[datetime] = created_at_col()
    updated_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
    updated_by_id: Mapped[str | None] = mapped_column(
        String(32), ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )

    vehicle: Mapped[Vehicle] = relationship(lazy="joined")

    def is_open_on(self, day: date_t) -> bool:
        """Was this bus off the road on that date?"""
        if self.off_road_since > day:
            return False
        return self.returned_on is None or self.returned_on > day

    def days_down_on(self, day: date_t) -> int:
        end = self.returned_on if self.returned_on and self.returned_on <= day else day
        return (end - self.off_road_since).days

    @property
    def is_open(self) -> bool:
        return self.returned_on is None


class UnitType(Base):
    """A major component whose life is worth tracking on its own.

    Battery pack, traction motor, motor controller, steering box — the units a
    depot replaces and reports on rather than consumes. Site-editable, because
    which components are worth tracking differs by fleet.
    """

    __tablename__ = "unit_types"
    __table_args__ = (UniqueConstraint("name", name="uq_unit_types_name"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    sort_order: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    is_active: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=True, server_default="true"
    )
    #: Marks the unit the DMR counts under "HV batteries replaced".
    is_hv_battery: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default="false"
    )


class FittedUnit(Base):
    """One component, on one bus, for the period it was fitted.

    The Unit Failure Statement is this list for a month. Kilometres covered is
    not stored: it is the odometer at removal less the odometer at fitting, and
    deriving it means it can never disagree with the readings the fleet already
    keeps.
    """

    __tablename__ = "fitted_units"
    __table_args__ = (
        Index("ix_fitted_units_site_code_removed_on", "site_code", "removed_on"),
        Index("ix_fitted_units_vehicle_id_unit_type_id", "vehicle_id", "unit_type_id"),
        Index("ix_fitted_units_entry_id", "entry_id"),
    )

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_uuid)
    site_code: Mapped[str] = mapped_column(
        String(50), ForeignKey("sites.code", ondelete="CASCADE"), nullable=False
    )
    vehicle_id: Mapped[str] = mapped_column(
        String(32), ForeignKey("vehicles.id", ondelete="RESTRICT"), nullable=False
    )
    unit_type_id: Mapped[int] = mapped_column(
        Integer, ForeignKey("unit_types.id", ondelete="RESTRICT"), nullable=False
    )
    #: The Work Done entry this fit was recorded alongside, when it was fit
    #: that way. Not how a stay is read back (that's still vehicle + unit_type
    #: + date, so Bus History and the statement never change shape) — only how
    #: the register list finds "which units did this entry touch" without
    #: guessing from a shared vehicle+date that a second shift's entry could
    #: also match.
    entry_id: Mapped[str | None] = mapped_column(
        String(32), ForeignKey("entries.id", ondelete="SET NULL"), nullable=True
    )
    #: The manufacturer's serial. Null when the depot did not record one.
    unit_no: Mapped[str | None] = mapped_column(String(120), nullable=True)

    fitted_on: Mapped[date_t] = mapped_column(Date, nullable=False)
    fitted_odometer_km: Mapped[int | None] = mapped_column(Integer, nullable=True)
    #: Null while it is still on the bus.
    removed_on: Mapped[date_t | None] = mapped_column(Date, nullable=True)
    removed_odometer_km: Mapped[int | None] = mapped_column(Integer, nullable=True)
    removal_reason: Mapped[str | None] = mapped_column(Text, nullable=True)
    remarks: Mapped[str | None] = mapped_column(Text, nullable=True)

    created_at: Mapped[datetime] = created_at_col()
    updated_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
    updated_by_id: Mapped[str | None] = mapped_column(
        String(32), ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )

    vehicle: Mapped[Vehicle] = relationship(lazy="joined")
    unit_type: Mapped[UnitType] = relationship(lazy="joined")

    @property
    def kms_covered(self) -> int | None:
        """What the unit did while it was on. Null when either reading is
        missing — an unknown life is not a life of zero."""
        if self.fitted_odometer_km is None or self.removed_odometer_km is None:
            return None
        return max(self.removed_odometer_km - self.fitted_odometer_km, 0)

    @property
    def is_fitted(self) -> bool:
        return self.removed_on is None
