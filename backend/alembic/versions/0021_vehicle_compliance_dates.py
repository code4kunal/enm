"""vehicle compliance dates + wider done_by

Revision ID: 0021
Revises: 0020
Create Date: 2026-09-09

ENM Vehicle Master keeps registration / fitness / insurance dates so depots
can edit them when SiteOps has nothing. Age is derived from registration_date
at read time. Inspection `done_by` widens so several SiteOps technicians fit.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0021"
down_revision = "0020"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "vehicles",
        sa.Column("registration_date", sa.Date(), nullable=True),
    )
    op.add_column(
        "vehicles",
        sa.Column("fitness_renewal_date", sa.Date(), nullable=True),
    )
    op.add_column(
        "vehicles",
        sa.Column("insurance_renewal_date", sa.Date(), nullable=True),
    )
    op.alter_column(
        "inspection_entries",
        "done_by",
        existing_type=sa.String(255),
        type_=sa.String(1000),
        existing_nullable=True,
    )
    op.add_column(
        "dmr_days",
        sa.Column("breakdowns_km_loss", sa.Integer(), nullable=True),
    )
    op.add_column(
        "dmr_days",
        sa.Column("breakdowns_no_km_loss", sa.Integer(), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("dmr_days", "breakdowns_no_km_loss")
    op.drop_column("dmr_days", "breakdowns_km_loss")
    op.alter_column(
        "inspection_entries",
        "done_by",
        existing_type=sa.String(1000),
        type_=sa.String(255),
        existing_nullable=True,
    )
    op.drop_column("vehicles", "insurance_renewal_date")
    op.drop_column("vehicles", "fitness_renewal_date")
    op.drop_column("vehicles", "registration_date")
