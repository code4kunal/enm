"""checklist templates keyed by docking KM rung

Revision ID: 0020
Revises: 0019
Create Date: 2026-09-09

Docking (P.M) has a different maintenance sheet per odometer mark (3k, 10k,
…, 1.20 lakh). Templates were unique on (site, work_type, variant) only —
one sheet for every docking. `milestone_km` adds the rung so Bus Type × KM
can each carry their own lines. D.I and 10-day keep `milestone_km` null.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0020"
down_revision = "0019"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "checklist_templates",
        sa.Column("milestone_km", sa.Integer(), nullable=True),
    )
    op.drop_constraint(
        "uq_checklist_templates_site_work_type_variant",
        "checklist_templates",
        type_="unique",
    )
    op.create_unique_constraint(
        "uq_checklist_templates_site_work_type_variant_km",
        "checklist_templates",
        ["site_code", "work_type_id", "variant", "milestone_km"],
        postgresql_nulls_not_distinct=True,
    )


def downgrade() -> None:
    op.drop_constraint(
        "uq_checklist_templates_site_work_type_variant_km",
        "checklist_templates",
        type_="unique",
    )
    op.drop_column("checklist_templates", "milestone_km")
    op.create_unique_constraint(
        "uq_checklist_templates_site_work_type_variant",
        "checklist_templates",
        ["site_code", "work_type_id", "variant"],
        postgresql_nulls_not_distinct=True,
    )
