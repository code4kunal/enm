"""Persist docking KM rung on each inspection entry.

Revision ID: 0023
Revises: 0022
Create Date: 2026-09-11
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0023"
down_revision = "0022"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "inspection_entries",
        sa.Column("milestone_km", sa.Integer(), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("inspection_entries", "milestone_km")
