"""reports: the Daily Maintenance Report and breakdown investigations

Revision ID: 0008
Revises: 0007
Create Date: 2026-08-13

Two additions make most of the DMR derivable rather than typed: a category on
each defect type, which is what splits breakdowns into Mechanical / Electrical
/ Tyre / AC / ITS, and the unit status the snag report already records, which
is what "defective in depot" and "held more than three days" actually mean.

The eleven lines nothing observes — buses on road, tyres scrapped, accidents in
the depot — are entered once a day and stored alongside.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import ENUM

revision = "0008"
down_revision = "0007"
branch_labels = None
depends_on = None

defect_category_enum = ENUM(
    "mechanical", "electrical", "body", "ac", "its", "tyre", "other",
    name="defect_category_enum", create_type=False,
)
unit_status_enum = ENUM(
    "serviceable", "pending", "held_up", name="unit_status_enum", create_type=False
)

#: The site's own GROUP values, mapped onto the report's categories. Defaults a
#: manager can change; the mapping is data, not code.
CATEGORY_BY_NAME = {
    "mechanical": (
        "SUSPENSION", "DOOR SYSTEM", "STEERING SYSTEM", "BRAKE SYSTEM",
        "COOLING SYSTEM", "TRANSMISSION/DRIVER SYSTEM",
    ),
    "electrical": (
        "ELECTRICAL", "BODY ELECTRICALS", "HV SYSTEM", "LV SYSTEM",
        "CHARGING SYSTEM",
    ),
    "body": ("BODY REFURBISHMENT",),
    "ac": ("AIR CONDITION",),
    "its": ("ITS SYSTEM",),
    "tyre": ("TYRE",),
}


def upgrade() -> None:
    bind = op.get_bind()
    for enum in (defect_category_enum, unit_status_enum):
        enum.create(bind, checkfirst=True)

    op.add_column(
        "defect_types",
        sa.Column(
            "category", defect_category_enum, nullable=False, server_default="other"
        ),
    )
    for category, names in CATEGORY_BY_NAME.items():
        op.execute(
            sa.text(
                "UPDATE defect_types SET category = :category "
                "WHERE upper(name) = ANY(:names)"
            ).bindparams(
                sa.bindparam("category", category, type_=defect_category_enum),
                sa.bindparam("names", list(names), type_=sa.ARRAY(sa.String)),
            )
        )

    op.add_column("entries", sa.Column("unit_status", unit_status_enum, nullable=True))
    op.create_index(
        "ix_entries_site_code_unit_status", "entries", ["site_code", "unit_status"]
    )

    op.create_table(
        "dmr_days",
        sa.Column("id", sa.String(32), nullable=False),
        sa.Column("site_code", sa.String(16), nullable=False),
        sa.Column("report_date", sa.Date(), nullable=False),
        # entered
        *[
            sa.Column(name, sa.Integer(), nullable=True)
            for name in (
                "on_road",
                "spare",
                "under_warranty",
                "rto_passing",
                "high_energy_consumption",
                "deep_cleaning",
                "washed_cleaned",
                "depot_accidents",
                "tyres_scrapped",
                "hv_batteries_replaced",
                "body_damages",
            )
        ],
        sa.Column("notes", sa.Text(), nullable=False, server_default=""),
        # snapshot
        sa.Column("generated_at", sa.DateTime(timezone=True), nullable=True),
        *[
            sa.Column(name, sa.Integer(), nullable=True)
            for name in (
                "total_fleet",
                "defective_in_depot",
                "defects_mechanical",
                "defects_body",
                "defects_electrical",
                "defects_ac",
                "defects_its",
                "held_over_three_days",
                "breakdowns",
                "breakdowns_mechanical",
                "breakdowns_electrical",
                "breakdowns_tyre",
                "breakdowns_ac",
                "breakdowns_its",
                "driver_complaints",
                "daily_inspections",
                "periodic_pm",
                "dockings",
            )
        ],
        sa.Column("loss_km", sa.Numeric(10, 2), nullable=True),
        sa.Column("coolant_litres", sa.Numeric(10, 2), nullable=True),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("updated_by_id", sa.String(32), nullable=True),
        sa.ForeignKeyConstraint(
            ["site_code"], ["sites.code"],
            name="fk_dmr_days_site_code_sites", ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["updated_by_id"], ["users.id"],
            name="fk_dmr_days_updated_by_id_users", ondelete="SET NULL",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_dmr_days"),
        sa.UniqueConstraint(
            "site_code", "report_date", name="uq_dmr_days_site_code_report_date"
        ),
    )
    op.create_index(
        "ix_dmr_days_site_code_report_date", "dmr_days", ["site_code", "report_date"]
    )

    op.create_table(
        "breakdown_investigations",
        sa.Column("id", sa.String(32), nullable=False),
        sa.Column("entry_id", sa.String(32), nullable=False),
        sa.Column("findings", sa.Text(), nullable=True),
        sa.Column("last_pm_on", sa.Date(), nullable=True),
        sa.Column("last_pm_findings", sa.Text(), nullable=True),
        sa.Column("related_complaints", sa.Text(), nullable=True),
        sa.Column("investigation_action", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("updated_by_id", sa.String(32), nullable=True),
        sa.ForeignKeyConstraint(
            ["entry_id"], ["entries.id"],
            name="fk_breakdown_investigations_entry_id_entries", ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["updated_by_id"], ["users.id"],
            name="fk_breakdown_investigations_updated_by_id_users",
            ondelete="SET NULL",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_breakdown_investigations"),
        sa.UniqueConstraint(
            "entry_id", name="uq_breakdown_investigations_entry_id"
        ),
    )

    op.create_table(
        "off_road_cases",
        sa.Column("id", sa.String(32), nullable=False),
        sa.Column("site_code", sa.String(16), nullable=False),
        sa.Column("vehicle_id", sa.String(32), nullable=False),
        sa.Column("entry_id", sa.String(32), nullable=True),
        sa.Column("issue", sa.Text(), nullable=False, server_default=""),
        sa.Column("action_taken", sa.Text(), nullable=True),
        sa.Column(
            "category", defect_category_enum, nullable=False, server_default="other"
        ),
        sa.Column("off_road_since", sa.Date(), nullable=False),
        sa.Column("expected_days", sa.Integer(), nullable=True),
        sa.Column("expected_ready_on", sa.Date(), nullable=True),
        sa.Column("returned_on", sa.Date(), nullable=True),
        sa.Column("odometer_km", sa.Integer(), nullable=True),
        sa.Column("spare_parts_required", sa.Text(), nullable=True),
        sa.Column("remarks", sa.Text(), nullable=True),
        sa.Column(
            "awaiting_vendor",
            sa.Boolean(),
            nullable=False,
            server_default=sa.text("false"),
        ),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("updated_by_id", sa.String(32), nullable=True),
        sa.ForeignKeyConstraint(
            ["site_code"], ["sites.code"],
            name="fk_off_road_cases_site_code_sites", ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["vehicle_id"], ["vehicles.id"],
            name="fk_off_road_cases_vehicle_id_vehicles", ondelete="RESTRICT",
        ),
        sa.ForeignKeyConstraint(
            ["entry_id"], ["entries.id"],
            name="fk_off_road_cases_entry_id_entries", ondelete="SET NULL",
        ),
        sa.ForeignKeyConstraint(
            ["updated_by_id"], ["users.id"],
            name="fk_off_road_cases_updated_by_id_users", ondelete="SET NULL",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_off_road_cases"),
    )
    op.create_index(
        "ix_off_road_cases_site_code_off_road_since",
        "off_road_cases",
        ["site_code", "off_road_since"],
    )
    op.create_index(
        "ix_off_road_cases_vehicle_id_returned_on",
        "off_road_cases",
        ["vehicle_id", "returned_on"],
    )

    op.add_column(
        "breakdown_entries",
        sa.Column("defect_type_id", sa.Integer(), nullable=True),
    )
    op.create_foreign_key(
        "fk_breakdown_entries_defect_type_id_defect_types",
        "breakdown_entries",
        "defect_types",
        ["defect_type_id"],
        ["id"],
        ondelete="RESTRICT",
    )

    op.create_table(
        "unit_types",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("name", sa.String(120), nullable=False),
        sa.Column("sort_order", sa.Integer(), nullable=False, server_default="0"),
        sa.Column(
            "is_active", sa.Boolean(), nullable=False, server_default=sa.text("true")
        ),
        sa.Column(
            "is_hv_battery",
            sa.Boolean(),
            nullable=False,
            server_default=sa.text("false"),
        ),
        sa.PrimaryKeyConstraint("id", name="pk_unit_types"),
        sa.UniqueConstraint("name", name="uq_unit_types_name"),
    )

    op.create_table(
        "fitted_units",
        sa.Column("id", sa.String(32), nullable=False),
        sa.Column("site_code", sa.String(16), nullable=False),
        sa.Column("vehicle_id", sa.String(32), nullable=False),
        sa.Column("unit_type_id", sa.Integer(), nullable=False),
        sa.Column("unit_no", sa.String(120), nullable=True),
        sa.Column("fitted_on", sa.Date(), nullable=False),
        sa.Column("fitted_odometer_km", sa.Integer(), nullable=True),
        sa.Column("removed_on", sa.Date(), nullable=True),
        sa.Column("removed_odometer_km", sa.Integer(), nullable=True),
        sa.Column("removal_reason", sa.Text(), nullable=True),
        sa.Column("remarks", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("updated_by_id", sa.String(32), nullable=True),
        sa.ForeignKeyConstraint(
            ["site_code"], ["sites.code"],
            name="fk_fitted_units_site_code_sites", ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["vehicle_id"], ["vehicles.id"],
            name="fk_fitted_units_vehicle_id_vehicles", ondelete="RESTRICT",
        ),
        sa.ForeignKeyConstraint(
            ["unit_type_id"], ["unit_types.id"],
            name="fk_fitted_units_unit_type_id_unit_types", ondelete="RESTRICT",
        ),
        sa.ForeignKeyConstraint(
            ["updated_by_id"], ["users.id"],
            name="fk_fitted_units_updated_by_id_users", ondelete="SET NULL",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_fitted_units"),
    )
    op.create_index(
        "ix_fitted_units_site_code_removed_on",
        "fitted_units",
        ["site_code", "removed_on"],
    )
    op.create_index(
        "ix_fitted_units_vehicle_id_unit_type_id",
        "fitted_units",
        ["vehicle_id", "unit_type_id"],
    )

    for value in ("breakdownInvestigation", "offRoad", "unitFailure"):
        op.execute(
            f"ALTER TYPE import_target_enum ADD VALUE IF NOT EXISTS '{value}'"
        )


def downgrade() -> None:
    bind = op.get_bind()
    op.drop_constraint(
        "fk_breakdown_entries_defect_type_id_defect_types",
        "breakdown_entries",
        type_="foreignkey",
    )
    op.drop_column("breakdown_entries", "defect_type_id")
    op.drop_table("fitted_units")
    op.drop_table("unit_types")
    op.drop_table("off_road_cases")
    op.drop_table("breakdown_investigations")
    op.drop_table("dmr_days")
    op.drop_index("ix_entries_site_code_unit_status", table_name="entries")
    op.drop_column("entries", "unit_status")
    op.drop_column("defect_types", "category")
    for enum in (unit_status_enum, defect_category_enum):
        enum.drop(bind, checkfirst=True)
