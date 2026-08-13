"""work types: the site's TYPE OF WORK vocabulary and its register routing

Revision ID: 0003
Revises: 0002
Create Date: 2026-08-13

A site's daily snag report mixes every kind of job in one list; the TYPE OF
WORK column says which register each row belongs in. Holding that as data
rather than a hard-coded table means a site can add its own codes.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import ENUM

revision = "0003"
down_revision = "0002"
branch_labels = None
depends_on = None

register_enum = ENUM(
    "work_done",
    "coolant",
    "driver_complaint",
    "breakdown",
    "pm_schedule",
    name="register_enum",
    create_type=False,
)


def upgrade() -> None:
    op.create_table(
        "work_types",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("code", sa.String(32), nullable=False),
        sa.Column("name", sa.String(120), nullable=False),
        # Null means recognised but not routed yet; those rows are rejected by
        # name rather than silently dropped.
        sa.Column("register", register_enum, nullable=True),
        sa.Column("sort_order", sa.Integer(), nullable=False, server_default="0"),
        sa.Column(
            "is_active", sa.Boolean(), nullable=False, server_default=sa.text("true")
        ),
        sa.PrimaryKeyConstraint("id", name="pk_work_types"),
        sa.UniqueConstraint("code", name="uq_work_types_code"),
    )

    op.execute(
        "ALTER TYPE import_target_enum ADD VALUE IF NOT EXISTS 'snagReport' "
        "BEFORE 'workDone'"
    )


def downgrade() -> None:
    op.drop_table("work_types")
    # import_target_enum keeps 'snagReport': Postgres cannot drop an enum value.
