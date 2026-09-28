"""tickets.display_id -- backfilled per source_kind, then NOT NULL + unique.

Revision ID: 0037
Revises: 0036
Create Date: 2026-09-28
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa

revision = "0037"
down_revision = "0036"
branch_labels = None
depends_on = None

_PREFIX = {
    "breakdown": "BD",
    "driver_complaint": "DC",
    "coolant": "CT",
    "daily_inspection": "DI",
    "ten_day_inspection": "TD",
    "pm_docking": "PM",
    "pm_schedule": "PS",
}


def upgrade() -> None:
    op.add_column("tickets", sa.Column("display_id", sa.String(length=20), nullable=True))
    conn = op.get_bind()
    for source_kind, prefix in _PREFIX.items():
        rows = conn.execute(
            sa.text(
                """
                SELECT t.id,
                       COALESCE(e.entry_date, ir_ins.inspected_on) AS entry_date
                FROM tickets t
                LEFT JOIN entries e ON e.id = t.source_entry_id
                LEFT JOIN inspection_results ir ON ir.id = t.source_inspection_result_id
                LEFT JOIN inspection_entries ir_ins ON ir_ins.id = ir.inspection_id
                WHERE t.source_kind::text = :k
                ORDER BY entry_date, t.created_at
                """
            ),
            {"k": source_kind},
        ).fetchall()
        counters: dict[int, int] = {}
        for ticket_id, entry_date in rows:
            year = entry_date.year
            counters[year] = counters.get(year, 0) + 1
            conn.execute(
                sa.text("UPDATE tickets SET display_id = :d WHERE id = :i"),
                {"d": f"{prefix}-{year}-{counters[year]:06d}", "i": ticket_id},
            )
        for year, count in counters.items():
            conn.execute(
                sa.text(
                    "INSERT INTO id_counters (kind, year, next_value) "
                    "VALUES (:k, :y, :n) "
                    "ON CONFLICT (kind, year) DO UPDATE SET next_value = :n"
                ),
                {"k": f"ticket:{source_kind}", "y": year, "n": count + 1},
            )
    op.alter_column("tickets", "display_id", nullable=False)
    op.create_unique_constraint("uq_tickets_display_id", "tickets", ["display_id"])


def downgrade() -> None:
    op.drop_constraint("uq_tickets_display_id", "tickets", type_="unique")
    op.drop_column("tickets", "display_id")
