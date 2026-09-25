"""Add the site-scoped driver master.

Revision ID: 0033
Revises: 0032
Create Date: 2026-09-25
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa

revision = "0033"
down_revision = "0032"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "drivers",
        sa.Column("id", sa.String(length=32), primary_key=True),
        sa.Column(
            "site_code",
            sa.String(length=50),
            sa.ForeignKey("sites.code", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("driver_code", sa.String(length=64), nullable=False),
        sa.Column("name", sa.String(length=160), nullable=False),
        sa.Column("is_active", sa.Boolean, nullable=False, server_default="true"),
        sa.UniqueConstraint("site_code", "driver_code", name="uq_drivers_site_code_driver_code"),
    )


def downgrade() -> None:
    op.drop_table("drivers")
