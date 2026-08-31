"""siteops user sync bookkeeping on sites

Revision ID: 0018
Revises: 0017
Create Date: 2026-08-31

Mirrors the existing `last_siteops_sync_at`/`last_siteops_sync_result` pair
used for fleet sync, but for the new user-sync stream — kept as separate
columns since they track a distinct sync run, not the same one.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0018"
down_revision = "0017"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "sites",
        sa.Column("last_siteops_user_sync_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column(
        "sites", sa.Column("last_siteops_user_sync_result", sa.JSON(), nullable=True)
    )


def downgrade() -> None:
    op.drop_column("sites", "last_siteops_user_sync_result")
    op.drop_column("sites", "last_siteops_user_sync_at")
