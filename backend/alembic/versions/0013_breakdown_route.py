"""keep the route a bus broke down on

Revision ID: 0013
Revises: 0012
Create Date: 2026-08-17

The snag report has a ROUTE column and the import profile has always mapped it,
but no register carried it and no table had a column for it, so every value was
read, validated and thrown away. A breakdown is the one register where the bus
was out on the road, so that is where the route belongs.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0013"
down_revision = "0012"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "breakdown_entries", sa.Column("route", sa.String(64), nullable=True)
    )


def downgrade() -> None:
    op.drop_column("breakdown_entries", "route")
