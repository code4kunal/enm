"""Ticket gains a second source shape: inspection results.

Revision ID: 0030
Revises: 0029
Create Date: 2026-09-25
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa

revision = "0030"
down_revision = "0029"
branch_labels = None
depends_on = None

TICKET_SOURCE_KIND = sa.Enum(
    "breakdown", "coolant", "driver_complaint",
    "daily_inspection", "ten_day_inspection", "pm_docking",
    name="ticket_source_kind_enum",
)


def upgrade() -> None:
    TICKET_SOURCE_KIND.create(op.get_bind())
    op.add_column(
        "tickets",
        sa.Column("source_kind", TICKET_SOURCE_KIND, nullable=True),
    )
    # Backfill: every existing ticket is entry-sourced; source_kind mirrors
    # the entry's own register (breakdown/coolant/driver_complaint are the
    # only registers that could have raised one before this migration).
    op.execute(
        """
        UPDATE tickets
        SET source_kind = entries.register::text::ticket_source_kind_enum
        FROM entries
        WHERE tickets.source_entry_id = entries.id
        """
    )
    op.alter_column("tickets", "source_kind", nullable=False)

    op.alter_column("tickets", "source_entry_id", nullable=True)
    op.add_column(
        "tickets",
        sa.Column(
            "source_inspection_result_id",
            sa.String(length=32),
            sa.ForeignKey("inspection_results.id", ondelete="CASCADE"),
            nullable=True,
        ),
    )
    op.create_unique_constraint(
        "uq_tickets_source_inspection_result_id", "tickets", ["source_inspection_result_id"]
    )
    op.create_check_constraint(
        "ck_tickets_exactly_one_source",
        "tickets",
        "(source_entry_id IS NULL) != (source_inspection_result_id IS NULL)",
    )


def downgrade() -> None:
    op.drop_constraint("ck_tickets_exactly_one_source", "tickets", type_="check")
    op.drop_constraint("uq_tickets_source_inspection_result_id", "tickets", type_="unique")
    op.drop_column("tickets", "source_inspection_result_id")
    op.alter_column("tickets", "source_entry_id", nullable=False)
    op.drop_column("tickets", "source_kind")
    TICKET_SOURCE_KIND.drop(op.get_bind())
