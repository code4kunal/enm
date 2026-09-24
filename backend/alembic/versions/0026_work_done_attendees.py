"""work_done_attendees

Revision ID: 0026
Revises: 0025
Create Date: 2026-09-24
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0026"
down_revision = "0025"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "work_done_attendees",
        sa.Column("work_done_entry_id", sa.String(32), nullable=False),
        sa.Column("user_id", sa.String(32), nullable=False),
        sa.ForeignKeyConstraint(
            ["work_done_entry_id"],
            ["work_done_entries.entry_id"],
            name="fk_work_done_attendees_work_done_entry_id_work_done_entries",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name="fk_work_done_attendees_user_id_users",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint(
            "work_done_entry_id", "user_id", name="pk_work_done_attendees"
        ),
    )


def downgrade() -> None:
    op.drop_table("work_done_attendees")
