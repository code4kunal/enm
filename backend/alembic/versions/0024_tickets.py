"""tickets table

Revision ID: 0024
Revises: 0023
Create Date: 2026-09-24

The spine between a source register entry (breakdown, coolant, driver
complaint, PM/docking) and the chain of Daily Work Done sessions logged
against it. One ticket per source, always.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0024"
down_revision = "0023"
branch_labels = None
depends_on = None

ticket_status_enum = sa.Enum("open", "completed", name="ticket_status_enum")


def upgrade() -> None:
    ticket_status_enum.create(op.get_bind(), checkfirst=True)
    op.create_table(
        "tickets",
        sa.Column("id", sa.String(32), primary_key=True),
        sa.Column(
            "source_entry_id",
            sa.String(32),
            sa.ForeignKey("entries.id", ondelete="CASCADE"),
            nullable=False,
            unique=True,
        ),
        sa.Column("status", ticket_status_enum, nullable=False, server_default="open"),
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "completed_by_id",
            sa.String(32),
            sa.ForeignKey("users.id", ondelete="SET NULL"),
            nullable=True,
        ),
        sa.Column("attended_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), nullable=False,
            server_default=sa.func.now(),
        ),
        sa.Column(
            "created_by_id",
            sa.String(32),
            sa.ForeignKey("users.id", ondelete="RESTRICT"),
            nullable=False,
        ),
    )
    op.create_index("ix_tickets_status", "tickets", ["status"])


def downgrade() -> None:
    op.drop_index("ix_tickets_status", table_name="tickets")
    op.drop_table("tickets")
    ticket_status_enum.drop(op.get_bind(), checkfirst=True)
