"""a checklist per bus model, because the depot's is

Revision ID: 0011
Revises: 0010
Create Date: 2026-08-14

MBMT's daily-inspection sheet is three sheets: 9M, 12M AC and 12M non-AC. They
share eleven checks and differ in the rest — a driver fan on the 9M, AC blower
and cooling on the 12M AC, neither on the 12M non-AC.

One template per work type could only be their union, and a mechanic would then
be asked about AC cooling on a bus that has none. Defaulted to "ok", as a daily
inspection sensibly does, that writes a check nobody could have performed into
the maintenance record. So a template is scoped to a variant, and a vehicle
names the one it takes.

`vehicles.checklist_variant` rather than reusing `model`: the snag-report
import overwrites `model` on every run, and would take the AC distinction with
it.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0011"
down_revision = "0010"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "checklist_templates", sa.Column("variant", sa.String(40), nullable=True)
    )
    op.add_column(
        "vehicles", sa.Column("checklist_variant", sa.String(40), nullable=True)
    )
    op.drop_constraint(
        "uq_checklist_templates_site_code_work_type_id",
        "checklist_templates",
        type_="unique",
    )
    # Postgres treats nulls as distinct in a unique constraint, so the
    # variant-less template — the fallback for a bus with no variant named —
    # needs `NULLS NOT DISTINCT` to stay unique.
    op.create_unique_constraint(
        "uq_checklist_templates_site_work_type_variant",
        "checklist_templates",
        ["site_code", "work_type_id", "variant"],
        postgresql_nulls_not_distinct=True,
    )


def downgrade() -> None:
    op.drop_constraint(
        "uq_checklist_templates_site_work_type_variant",
        "checklist_templates",
        type_="unique",
    )
    op.create_unique_constraint(
        "uq_checklist_templates_site_code_work_type_id",
        "checklist_templates",
        ["site_code", "work_type_id"],
    )
    op.drop_column("vehicles", "checklist_variant")
    op.drop_column("checklist_templates", "variant")
