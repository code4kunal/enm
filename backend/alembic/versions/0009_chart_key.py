"""tie a checklist line to a control chart

Revision ID: 0009
Revises: 0008
Create Date: 2026-08-13

Two of the six control charts — tyre pressure checked, bus washed — are simply
"was this done that day". The answer already exists as a checklist line; what
was missing is which line. Guessing from the wording would break the first time
a depot rephrased it, so the depot marks the line instead.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0009"
down_revision = "0008"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "checklist_items", sa.Column("chart_key", sa.String(40), nullable=True)
    )
    op.create_index(
        "ix_checklist_items_chart_key", "checklist_items", ["chart_key"]
    )


def downgrade() -> None:
    op.drop_index("ix_checklist_items_chart_key", table_name="checklist_items")
    op.drop_column("checklist_items", "chart_key")
