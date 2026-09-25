"""driver_id becomes a real FK into the new drivers master.

`breakdown_entries.driver_id` already existed as free text and is backfilled
before its type changes. `driver_complaint_entries` never had a `driver_id`
column at all (the client's own feedback bullet — "linked to driver
details" — was never actually wired end to end), so that one is a plain new
column, no backfill needed.

Revision ID: 0034
Revises: 0033
Create Date: 2026-09-25
"""
from __future__ import annotations

import uuid

from alembic import op
import sqlalchemy as sa

revision = "0034"
down_revision = "0033"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # driver_complaint_entries: brand new column, nothing to backfill.
    op.add_column(
        "driver_complaint_entries",
        sa.Column(
            "driver_id",
            sa.String(length=32),
            sa.ForeignKey("drivers.id", ondelete="SET NULL"),
            nullable=True,
        ),
    )

    # breakdown_entries: existing free-text values become drivers rows first
    # (site-scoped from the entry they came from), then the column is
    # retyped and pointed at the new table. Same uuid4().hex-in-Python
    # pattern as 0032's spare_parts_used backfill (no Postgres extension for
    # server-side id generation is enabled in this repo).
    connection = op.get_bind()
    rows = connection.execute(
        sa.text(
            "SELECT be.entry_id, e.site_code, be.driver_id AS text_value "
            "FROM breakdown_entries be "
            "JOIN entries e ON e.id = be.entry_id "
            "WHERE be.driver_id IS NOT NULL AND trim(be.driver_id) <> ''"
        )
    ).fetchall()

    driver_ids: dict[tuple[str, str], str] = {}
    for row in rows:
        key = (row.site_code, row.text_value.strip())
        if key not in driver_ids:
            new_id = uuid.uuid4().hex
            driver_ids[key] = new_id
            connection.execute(
                sa.text(
                    "INSERT INTO drivers (id, site_code, driver_code, name, is_active) "
                    "VALUES (:id, :site_code, :driver_code, :name, true)"
                ),
                {
                    "id": new_id,
                    "site_code": row.site_code,
                    "driver_code": f"LEGACY-{new_id[:8]}",
                    "name": row.text_value.strip(),
                },
            )

    op.alter_column(
        "breakdown_entries",
        "driver_id",
        new_column_name="driver_id_text",
        type_=sa.String(length=64),
    )
    op.add_column(
        "breakdown_entries",
        sa.Column(
            "driver_id",
            sa.String(length=32),
            sa.ForeignKey("drivers.id", ondelete="SET NULL"),
            nullable=True,
        ),
    )
    for row in rows:
        key = (row.site_code, row.text_value.strip())
        connection.execute(
            sa.text(
                "UPDATE breakdown_entries SET driver_id = :driver_id WHERE entry_id = :entry_id"
            ),
            {"driver_id": driver_ids[key], "entry_id": row.entry_id},
        )
    op.drop_column("breakdown_entries", "driver_id_text")


def downgrade() -> None:
    op.drop_column("driver_complaint_entries", "driver_id")

    op.alter_column(
        "breakdown_entries",
        "driver_id",
        new_column_name="driver_id_fk",
        type_=sa.String(length=32),
    )
    op.add_column("breakdown_entries", sa.Column("driver_id", sa.String(length=64), nullable=True))
    op.drop_column("breakdown_entries", "driver_id_fk")
