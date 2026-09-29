"""odometer_km on breakdown_entries -- the dash reading at the moment of
breakdown, feeding the same forward-only history inspections already write
to (services/odometer.record_reading).

Revision ID: 0042
Revises: 0041
Create Date: 2026-09-29
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa

revision = "0042"
down_revision = "0041"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "breakdown_entries", sa.Column("odometer_km", sa.Integer(), nullable=True)
    )


def downgrade() -> None:
    op.drop_column("breakdown_entries", "odometer_km")
