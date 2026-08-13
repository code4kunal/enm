"""supervisor on every register, and the staff who sign the work off

Revision ID: 0004
Revises: 0003
Create Date: 2026-08-13

The snag report names a floor supervisor on every job, and the register forms
offer that as a dropdown of the site's own staff. Held as a name rather than a
foreign key: the supervisor on a 2024 entry has to keep reading correctly after
they leave the depot.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0004"
down_revision = "0003"
branch_labels = None
depends_on = None

TABLES = (
    "work_done_entries",
    "coolant_entries",
    "driver_complaint_entries",
    "breakdown_entries",
    "pm_schedule_entries",
)


def upgrade() -> None:
    for table in TABLES:
        op.add_column(
            table, sa.Column("supervisor", sa.String(255), nullable=True)
        )


def downgrade() -> None:
    for table in TABLES:
        op.drop_column(table, "supervisor")
