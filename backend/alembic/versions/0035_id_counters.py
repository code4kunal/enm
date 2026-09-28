"""id_counters -- backs every Entry/Ticket display_id.

Revision ID: 0035
Revises: 0034
Create Date: 2026-09-28
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa

revision = "0035"
down_revision = "0034"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "id_counters",
        sa.Column("kind", sa.String(length=32), nullable=False),
        sa.Column("year", sa.Integer(), nullable=False),
        sa.Column("next_value", sa.Integer(), nullable=False, server_default="1"),
        sa.PrimaryKeyConstraint("kind", "year", name="pk_id_counters"),
    )


def downgrade() -> None:
    op.drop_table("id_counters")
