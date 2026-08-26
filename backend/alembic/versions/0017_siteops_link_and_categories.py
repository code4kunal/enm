"""siteops link fields on sites, operating_categories on site_configs

Revision ID: 0017
Revises: 0016
Create Date: 2026-08-26

A site's link to its SiteOps counterpart was passed by the client on every
sync-from-siteops call and never stored. `siteops_site_id` persists the link
once so create-time provisioning and the nightly job can find linked sites.

`operating_categories` lets checklist provisioning key off bus vs truck
instead of unioning every checklist onto every site.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0017"
down_revision = "0016"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "sites", sa.Column("siteops_site_id", sa.String(64), nullable=True)
    )
    op.create_unique_constraint(
        "uq_sites_siteops_site_id", "sites", ["siteops_site_id"]
    )
    op.add_column(
        "sites",
        sa.Column("last_siteops_sync_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column(
        "sites", sa.Column("last_siteops_sync_result", sa.JSON(), nullable=True)
    )
    op.add_column(
        "site_configs",
        sa.Column(
            "operating_categories",
            postgresql.ARRAY(sa.String(20)),
            nullable=False,
            server_default="{bus}",
        ),
    )


def downgrade() -> None:
    op.drop_column("site_configs", "operating_categories")
    op.drop_column("sites", "last_siteops_sync_result")
    op.drop_column("sites", "last_siteops_sync_at")
    op.drop_constraint("uq_sites_siteops_site_id", "sites", type_="unique")
    op.drop_column("sites", "siteops_site_id")
