"""latitude/longitude/location_source on breakdown_entries and
driver_complaint_entries -- additive to the existing text location/route.

Revision ID: 0039
Revises: 0038
Create Date: 2026-09-28
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa

revision = "0039"
down_revision = "0038"
branch_labels = None
depends_on = None

_location_source = sa.Enum("gps", "map", "manual", name="location_source_enum")


def upgrade() -> None:
    _location_source.create(op.get_bind(), checkfirst=True)
    for table in ("breakdown_entries", "driver_complaint_entries"):
        op.add_column(table, sa.Column("latitude", sa.Numeric(9, 6), nullable=True))
        op.add_column(table, sa.Column("longitude", sa.Numeric(9, 6), nullable=True))
        op.add_column(
            table,
            sa.Column("location_source", _location_source, nullable=True),
        )


def downgrade() -> None:
    for table in ("breakdown_entries", "driver_complaint_entries"):
        op.drop_column(table, "location_source")
        op.drop_column(table, "longitude")
        op.drop_column(table, "latitude")
    _location_source.drop(op.get_bind(), checkfirst=True)
