"""docking is due by distance, not by date

Revision ID: 0012
Revises: 0011
Create Date: 2026-08-14

The daily inspection and the ten-day service come round on the calendar. A
docking does not: MBMT's sheets are a ladder of odometer marks — 3,000 km, then
every 10,000 to 1.20 lakh — and each rung is a different job. A bus reaches
40,000 km when it reaches it.

`milestone_km` is that rung, and it is distinct from `interval_km`, which means
"every N km" and is what a genuinely recurring plan would use. The two are not
the same thing and conflating them would make the ladder unreadable.

The rung is carried onto the booking and onto the record, so "which docking was
this?" is answerable from the row rather than from a remark someone typed.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0012"
down_revision = "0011"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "service_plans", sa.Column("milestone_km", sa.Integer(), nullable=True)
    )
    op.add_column(
        "service_plans",
        sa.Column("sort_order", sa.Integer(), nullable=False, server_default="0"),
    )
    op.add_column(
        "service_plans",
        sa.Column("work_type_id", sa.Integer(), nullable=True),
    )
    op.create_foreign_key(
        "fk_service_plans_work_type_id",
        "service_plans",
        "work_types",
        ["work_type_id"],
        ["id"],
        ondelete="SET NULL",
    )

    for table in ("inspection_slots", "inspection_entries"):
        op.add_column(
            table, sa.Column("service_plan_id", sa.String(32), nullable=True)
        )
        op.create_foreign_key(
            f"fk_{table}_service_plan_id",
            table,
            "service_plans",
            ["service_plan_id"],
            ["id"],
            ondelete="SET NULL",
        )

    op.create_index(
        "ix_service_plans_site_code_milestone_km",
        "service_plans",
        ["site_code", "milestone_km"],
    )


def downgrade() -> None:
    op.drop_index(
        "ix_service_plans_site_code_milestone_km", table_name="service_plans"
    )
    for table in ("inspection_slots", "inspection_entries"):
        op.drop_constraint(
            f"fk_{table}_service_plan_id", table, type_="foreignkey"
        )
        op.drop_column(table, "service_plan_id")
    op.drop_constraint(
        "fk_service_plans_work_type_id", "service_plans", type_="foreignkey"
    )
    op.drop_column("service_plans", "work_type_id")
    op.drop_column("service_plans", "sort_order")
    op.drop_column("service_plans", "milestone_km")
