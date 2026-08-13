"""checklists and inspection entries

Revision ID: 0006
Revises: 0005
Create Date: 2026-08-13

A daily inspection and a ten-day service are different jobs with different
sheets, so they get different data entry. An inspection becomes its own record
with a result per checklist line, rather than another PM Schedule Attention
entry — the five paper registers stay what they are.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import ENUM

revision = "0006"
down_revision = "0005"
branch_labels = None
depends_on = None

response_type_enum = ENUM(
    "ok_not_ok", "reading", "note", name="response_type_enum", create_type=False
)
check_result_enum = ENUM(
    "ok", "not_ok", "na", name="check_result_enum", create_type=False
)


def upgrade() -> None:
    bind = op.get_bind()
    for enum in (response_type_enum, check_result_enum):
        enum.create(bind, checkfirst=True)

    op.add_column(
        "work_types",
        sa.Column(
            "is_inspection",
            sa.Boolean(),
            nullable=False,
            server_default=sa.text("false"),
        ),
    )
    # The inspection codes stop filing into the PM register and become
    # checklist sweeps in their own right.
    op.execute(
        "UPDATE work_types SET is_inspection = true, register = NULL "
        "WHERE upper(code) IN ('D.I', '10 DAYS SERVICE', 'P.M', 'PM')"
    )

    op.create_table(
        "checklist_templates",
        sa.Column("id", sa.String(32), nullable=False),
        sa.Column("site_code", sa.String(16), nullable=False),
        sa.Column("work_type_id", sa.Integer(), nullable=False),
        sa.Column("name", sa.String(160), nullable=False),
        sa.Column(
            "is_active", sa.Boolean(), nullable=False, server_default=sa.text("true")
        ),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(
            ["site_code"],
            ["sites.code"],
            name="fk_checklist_templates_site_code_sites",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["work_type_id"],
            ["work_types.id"],
            name="fk_checklist_templates_work_type_id_work_types",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_checklist_templates"),
        sa.UniqueConstraint(
            "site_code",
            "work_type_id",
            name="uq_checklist_templates_site_code_work_type_id",
        ),
    )

    op.create_table(
        "checklist_items",
        sa.Column("id", sa.String(32), nullable=False),
        sa.Column("template_id", sa.String(32), nullable=False),
        sa.Column("section", sa.String(80), nullable=False, server_default=""),
        sa.Column("label", sa.String(255), nullable=False),
        sa.Column("sort_order", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("response_type", response_type_enum, nullable=False),
        sa.Column(
            "is_required", sa.Boolean(), nullable=False, server_default=sa.text("true")
        ),
        sa.Column(
            "is_active", sa.Boolean(), nullable=False, server_default=sa.text("true")
        ),
        sa.ForeignKeyConstraint(
            ["template_id"],
            ["checklist_templates.id"],
            name="fk_checklist_items_template_id_checklist_templates",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_checklist_items"),
    )
    op.create_index(
        "ix_checklist_items_template_id_sort_order",
        "checklist_items",
        ["template_id", "sort_order"],
    )

    op.create_table(
        "inspection_entries",
        sa.Column("id", sa.String(32), nullable=False),
        sa.Column("site_code", sa.String(16), nullable=False),
        sa.Column("vehicle_id", sa.String(32), nullable=False),
        sa.Column("work_type_id", sa.Integer(), nullable=False),
        sa.Column("inspected_on", sa.Date(), nullable=False),
        sa.Column("entry_time", sa.Time(), nullable=True),
        sa.Column("done_by", sa.String(255), nullable=True),
        sa.Column("supervisor", sa.String(255), nullable=True),
        sa.Column("odometer_km", sa.Integer(), nullable=True),
        sa.Column("remarks", sa.Text(), nullable=True),
        sa.Column("slot_id", sa.String(32), nullable=True),
        sa.Column("created_by_id", sa.String(32), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(
            ["site_code"],
            ["sites.code"],
            name="fk_inspection_entries_site_code_sites",
            ondelete="RESTRICT",
        ),
        sa.ForeignKeyConstraint(
            ["vehicle_id"],
            ["vehicles.id"],
            name="fk_inspection_entries_vehicle_id_vehicles",
            ondelete="RESTRICT",
        ),
        sa.ForeignKeyConstraint(
            ["work_type_id"],
            ["work_types.id"],
            name="fk_inspection_entries_work_type_id_work_types",
            ondelete="RESTRICT",
        ),
        sa.ForeignKeyConstraint(
            ["slot_id"],
            ["inspection_slots.id"],
            name="fk_inspection_entries_slot_id_inspection_slots",
            ondelete="SET NULL",
        ),
        sa.ForeignKeyConstraint(
            ["created_by_id"],
            ["users.id"],
            name="fk_inspection_entries_created_by_id_users",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_inspection_entries"),
    )
    op.create_index(
        "ix_inspection_entries_site_code_inspected_on",
        "inspection_entries",
        ["site_code", "inspected_on"],
    )
    op.create_index(
        "ix_inspection_entries_vehicle_id_work_type_id",
        "inspection_entries",
        ["vehicle_id", "work_type_id"],
    )

    op.create_table(
        "inspection_results",
        sa.Column("id", sa.String(32), nullable=False),
        sa.Column("inspection_id", sa.String(32), nullable=False),
        sa.Column("item_id", sa.String(32), nullable=False),
        sa.Column("result", check_result_enum, nullable=False),
        sa.Column("value", sa.String(255), nullable=True),
        sa.Column("remark", sa.Text(), nullable=True),
        sa.ForeignKeyConstraint(
            ["inspection_id"],
            ["inspection_entries.id"],
            name="fk_inspection_results_inspection_id_inspection_entries",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["item_id"],
            ["checklist_items.id"],
            name="fk_inspection_results_item_id_checklist_items",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_inspection_results"),
        sa.UniqueConstraint(
            "inspection_id",
            "item_id",
            name="uq_inspection_results_inspection_id_item_id",
        ),
    )


def downgrade() -> None:
    bind = op.get_bind()
    op.drop_table("inspection_results")
    op.drop_table("inspection_entries")
    op.drop_table("checklist_items")
    op.drop_table("checklist_templates")
    op.execute(
        "UPDATE work_types SET register = 'pm_schedule' WHERE is_inspection = true"
    )
    op.drop_column("work_types", "is_inspection")
    for enum in (check_result_enum, response_type_enum):
        enum.drop(bind, checkfirst=True)
