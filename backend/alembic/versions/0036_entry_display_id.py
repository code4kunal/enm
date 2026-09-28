"""entries.display_id -- backfilled per-register, then NOT NULL + unique.

Revision ID: 0036
Revises: 0035
Create Date: 2026-09-28
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa

revision = "0036"
down_revision = "0035"
branch_labels = None
depends_on = None

_PREFIX = {
    "work_done": "WD",
    "breakdown": "BD",
    "driver_complaint": "DC",
    "coolant": "CT",
    "pm_schedule": "PS",
}


def upgrade() -> None:
    op.add_column("entries", sa.Column("display_id", sa.String(length=20), nullable=True))
    conn = op.get_bind()
    for register, prefix in _PREFIX.items():
        rows = conn.execute(
            sa.text(
                "SELECT id, entry_date FROM entries WHERE register::text = :r "
                "ORDER BY entry_date, created_at"
            ),
            {"r": register},
        ).fetchall()
        counters: dict[int, int] = {}
        for entry_id, entry_date in rows:
            year = entry_date.year
            counters[year] = counters.get(year, 0) + 1
            conn.execute(
                sa.text("UPDATE entries SET display_id = :d WHERE id = :i"),
                {"d": f"{prefix}-{year}-{counters[year]:06d}", "i": entry_id},
            )
        for year, count in counters.items():
            conn.execute(
                sa.text(
                    "INSERT INTO id_counters (kind, year, next_value) "
                    "VALUES (:k, :y, :n) "
                    "ON CONFLICT (kind, year) DO UPDATE SET next_value = :n"
                ),
                {"k": f"entry:{register}", "y": year, "n": count + 1},
            )
    op.alter_column("entries", "display_id", nullable=False)
    op.create_unique_constraint("uq_entries_display_id", "entries", ["display_id"])


def downgrade() -> None:
    op.drop_constraint("uq_entries_display_id", "entries", type_="unique")
    op.drop_column("entries", "display_id")
