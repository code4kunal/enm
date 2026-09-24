"""drop work_done_entries.employee

Revision ID: 0027
Revises: 0026
Create Date: 2026-09-24

Replaced by work_done_attendees (Task 7) — same tradeoff already accepted
for breakdown_time: old rows keep this text only in audit-log snapshots
taken at write time, not in the live schema going forward.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0027"
down_revision = "0026"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.drop_column("work_done_entries", "employee")


def downgrade() -> None:
    op.add_column(
        "work_done_entries", sa.Column("employee", sa.String(255), nullable=True)
    )
