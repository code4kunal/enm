"""reactive inspection schedule: plans, slots and the alert log

Revision ID: 0005
Revises: 0004
Create Date: 2026-08-13

The daily inspection covers the whole fleet every night; the 10-day service is
capped by bay time at about five buses. `entries.work_type_id` is what lets the
generator see that an inspection actually happened, including one imported from
the site's own snag report.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import ENUM

revision = "0005"
down_revision = "0004"
branch_labels = None
depends_on = None

slot_status_enum = ENUM(
    "scheduled", "done", "missed", "cancelled",
    name="slot_status_enum", create_type=False,
)
alert_type_enum = ENUM(
    "missed_inspection", "breakdown_open", "service_overdue",
    name="alert_type_enum", create_type=False,
)
alert_status_enum = ENUM(
    "open", "acknowledged", "resolved",
    name="alert_status_enum", create_type=False,
)


def upgrade() -> None:
    bind = op.get_bind()
    for enum in (slot_status_enum, alert_type_enum, alert_status_enum):
        enum.create(bind, checkfirst=True)

    op.execute(
        "ALTER TYPE notification_type_enum ADD VALUE IF NOT EXISTS 'schedule_alert'"
    )

    # What an entry actually was, so a booking can be discharged by it.
    op.add_column("entries", sa.Column("work_type_id", sa.Integer(), nullable=True))
    op.create_foreign_key(
        "fk_entries_work_type_id_work_types",
        "entries",
        "work_types",
        ["work_type_id"],
        ["id"],
        ondelete="SET NULL",
    )
    op.create_index(
        "ix_entries_work_type_id_entry_date",
        "entries",
        ["work_type_id", "entry_date"],
    )

    op.add_column(
        "site_configs",
        sa.Column(
            "inspection_slots_per_day",
            sa.Integer(),
            nullable=False,
            server_default="5",
        ),
    )

    op.create_table(
        "inspection_plans",
        sa.Column("id", sa.String(32), nullable=False),
        sa.Column("site_code", sa.String(16), nullable=False),
        sa.Column("work_type_id", sa.Integer(), nullable=False),
        sa.Column("cycle_days", sa.Integer(), nullable=False),
        # 0 = uncapped, which is what a whole-fleet daily inspection means.
        sa.Column("slots_per_day", sa.Integer(), nullable=False, server_default="0"),
        sa.Column(
            "is_active", sa.Boolean(), nullable=False, server_default=sa.text("true")
        ),
        sa.ForeignKeyConstraint(
            ["site_code"],
            ["sites.code"],
            name="fk_inspection_plans_site_code_sites",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["work_type_id"],
            ["work_types.id"],
            name="fk_inspection_plans_work_type_id_work_types",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_inspection_plans"),
        sa.UniqueConstraint(
            "site_code",
            "work_type_id",
            name="uq_inspection_plans_site_code_work_type_id",
        ),
    )

    op.create_table(
        "inspection_slots",
        sa.Column("id", sa.String(32), nullable=False),
        sa.Column("site_code", sa.String(16), nullable=False),
        sa.Column("vehicle_id", sa.String(32), nullable=False),
        sa.Column("work_type_id", sa.Integer(), nullable=False),
        sa.Column("scheduled_on", sa.Date(), nullable=False),
        sa.Column("status", slot_status_enum, nullable=False),
        sa.Column(
            "is_pinned", sa.Boolean(), nullable=False, server_default=sa.text("false")
        ),
        sa.Column("completed_entry_id", sa.String(32), nullable=True),
        sa.Column("completed_on", sa.Date(), nullable=True),
        sa.Column("notes", sa.Text(), nullable=False, server_default=""),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(
            ["site_code"],
            ["sites.code"],
            name="fk_inspection_slots_site_code_sites",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["vehicle_id"],
            ["vehicles.id"],
            name="fk_inspection_slots_vehicle_id_vehicles",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["work_type_id"],
            ["work_types.id"],
            name="fk_inspection_slots_work_type_id_work_types",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["completed_entry_id"],
            ["entries.id"],
            name="fk_inspection_slots_completed_entry_id_entries",
            ondelete="SET NULL",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_inspection_slots"),
        sa.UniqueConstraint(
            "site_code",
            "vehicle_id",
            "work_type_id",
            "scheduled_on",
            name="uq_inspection_slots_site_vehicle_work_type_scheduled_on",
        ),
    )
    op.create_index(
        "ix_inspection_slots_site_code_scheduled_on",
        "inspection_slots",
        ["site_code", "scheduled_on"],
    )
    op.create_index("ix_inspection_slots_status", "inspection_slots", ["status"])

    op.create_table(
        "alerts",
        sa.Column("id", sa.String(32), nullable=False),
        sa.Column("site_code", sa.String(16), nullable=False),
        sa.Column("type", alert_type_enum, nullable=False),
        sa.Column("status", alert_status_enum, nullable=False),
        sa.Column("dedupe_key", sa.String(120), nullable=False),
        sa.Column("title", sa.String(255), nullable=False),
        sa.Column("body", sa.Text(), nullable=False),
        sa.Column("vehicle_id", sa.String(32), nullable=True),
        sa.Column("slot_id", sa.String(32), nullable=True),
        sa.Column("entry_id", sa.String(32), nullable=True),
        sa.Column("raised_on", sa.Date(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("acknowledged_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("acknowledged_by_id", sa.String(32), nullable=True),
        sa.ForeignKeyConstraint(
            ["site_code"],
            ["sites.code"],
            name="fk_alerts_site_code_sites",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["vehicle_id"],
            ["vehicles.id"],
            name="fk_alerts_vehicle_id_vehicles",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["slot_id"],
            ["inspection_slots.id"],
            name="fk_alerts_slot_id_inspection_slots",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["entry_id"],
            ["entries.id"],
            name="fk_alerts_entry_id_entries",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["acknowledged_by_id"],
            ["users.id"],
            name="fk_alerts_acknowledged_by_id_users",
            ondelete="SET NULL",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_alerts"),
        sa.UniqueConstraint(
            "site_code", "dedupe_key", name="uq_alerts_site_code_dedupe_key"
        ),
    )
    op.create_index("ix_alerts_site_code_status", "alerts", ["site_code", "status"])
    op.create_index("ix_alerts_raised_on", "alerts", ["raised_on"])


def downgrade() -> None:
    bind = op.get_bind()
    op.drop_table("alerts")
    op.drop_table("inspection_slots")
    op.drop_table("inspection_plans")
    op.drop_column("site_configs", "inspection_slots_per_day")
    op.drop_index("ix_entries_work_type_id_entry_date", table_name="entries")
    op.drop_constraint(
        "fk_entries_work_type_id_work_types", "entries", type_="foreignkey"
    )
    op.drop_column("entries", "work_type_id")
    for enum in (alert_status_enum, alert_type_enum, slot_status_enum):
        enum.drop(bind, checkfirst=True)
    # notification_type_enum keeps 'schedule_alert': values cannot be dropped.
