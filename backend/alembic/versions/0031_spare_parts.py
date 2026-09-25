"""Add the site-scoped spare_parts catalogue.

Revision ID: 0031
Revises: 0030
Create Date: 2026-09-25
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa

revision = "0031"
down_revision = "0030"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "spare_parts",
        sa.Column("id", sa.String(length=32), primary_key=True),
        sa.Column(
            "site_code",
            sa.String(length=50),
            sa.ForeignKey("sites.code", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("part_no", sa.String(length=64), nullable=False),
        sa.Column("name", sa.String(length=160), nullable=False),
        sa.Column("is_active", sa.Boolean, nullable=False, server_default="true"),
        sa.UniqueConstraint("site_code", "part_no", name="uq_spare_parts_site_code_part_no"),
    )


def downgrade() -> None:
    op.drop_table("spare_parts")
