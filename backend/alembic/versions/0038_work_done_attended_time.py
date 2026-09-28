"""work_done_entries.attended_time -- explicit, mirrors completion_time.

Revision ID: 0038
Revises: 0037
Create Date: 2026-09-28
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa

revision = "0038"
down_revision = "0037"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "work_done_entries", sa.Column("attended_time", sa.Time(), nullable=True)
    )


def downgrade() -> None:
    op.drop_column("work_done_entries", "attended_time")
