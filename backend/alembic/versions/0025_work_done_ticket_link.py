"""work_done_entries ticket link

Revision ID: 0025
Revises: 0024
Create Date: 2026-09-24
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0025"
down_revision = "0024"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "work_done_entries", sa.Column("ticket_id", sa.String(32), nullable=True)
    )
    op.create_foreign_key(
        "fk_work_done_entries_ticket_id_tickets",
        "work_done_entries",
        "tickets",
        ["ticket_id"],
        ["id"],
        ondelete="SET NULL",
    )
    op.create_index(
        "ix_work_done_entries_ticket_id", "work_done_entries", ["ticket_id"]
    )
    op.add_column(
        "work_done_entries",
        sa.Column(
            "completes_ticket", sa.Boolean(), nullable=False, server_default=sa.text("false")
        ),
    )
    op.add_column(
        "work_done_entries", sa.Column("completion_time", sa.Time(), nullable=True)
    )


def downgrade() -> None:
    op.drop_column("work_done_entries", "completion_time")
    op.drop_column("work_done_entries", "completes_ticket")
    op.drop_index("ix_work_done_entries_ticket_id", table_name="work_done_entries")
    op.drop_constraint(
        "fk_work_done_entries_ticket_id_tickets", "work_done_entries", type_="foreignkey"
    )
    op.drop_column("work_done_entries", "ticket_id")
