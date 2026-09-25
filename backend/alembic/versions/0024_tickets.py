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
from sqlalchemy.dialects.postgresql import ENUM

revision = "0024"
down_revision = "0023"
branch_labels = None
depends_on = None

ticket_status_enum = ENUM(
    "open", "completed", name="ticket_status_enum", create_type=False
)


def upgrade() -> None:
    bind = op.get_bind()
    ticket_status_enum.create(bind, checkfirst=True)
    op.create_table(
        "tickets",
        sa.Column("id", sa.String(32), nullable=False),
        sa.Column("source_entry_id", sa.String(32), nullable=False),
        sa.Column("status", ticket_status_enum, nullable=False, server_default="open"),
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("completed_by_id", sa.String(32), nullable=True),
        sa.Column("attended_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.func.now(),
        ),
        sa.Column("created_by_id", sa.String(32), nullable=False),
        sa.ForeignKeyConstraint(
            ["source_entry_id"],
            ["entries.id"],
            name="fk_tickets_source_entry_id_entries",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["completed_by_id"],
            ["users.id"],
            name="fk_tickets_completed_by_id_users",
            ondelete="SET NULL",
        ),
        sa.ForeignKeyConstraint(
            ["created_by_id"],
            ["users.id"],
            name="fk_tickets_created_by_id_users",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_tickets"),
        sa.UniqueConstraint("source_entry_id", name="uq_tickets_source_entry_id"),
    )
    op.create_index("ix_tickets_status", "tickets", ["status"])


def downgrade() -> None:
    op.drop_index("ix_tickets_status", table_name="tickets")
    op.drop_table("tickets")
    ticket_status_enum.drop(op.get_bind(), checkfirst=True)
