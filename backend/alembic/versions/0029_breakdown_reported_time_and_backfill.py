"""breakdown reported_time + backfill tickets for existing breakdowns

Revision ID: 0029
Revises: 0028
Create Date: 2026-09-24

Collapses breakdown timing to reported_time/attended_time/resolved_at.
breakdown_time (the moment of breakdown itself, distinct from when it was
reported) is dropped — confirmed acceptable data loss on existing rows.
Every pre-existing breakdown gets a backfilled ticket so it shows up in the
new linked-sessions UI immediately; historical Work Done rows are not
retroactively linked (no reliable way to infer which session belongs to
which breakdown — this feature closes that gap only going forward).
"""
from __future__ import annotations

import uuid

import sqlalchemy as sa
from alembic import op

revision = "0029"
down_revision = "0028"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # 1. Backfill nulls before the column becomes NOT NULL — closest available
    #    signal for pre-existing rows is the header's own entry_time.
    op.execute(
        """
        UPDATE breakdown_entries be
        SET mechanic_reported_time = e.entry_time
        FROM entries e
        WHERE be.entry_id = e.id
          AND be.mechanic_reported_time IS NULL
          AND e.entry_time IS NOT NULL
        """
    )
    # A handful of rows may still be null if entry_time itself was never set —
    # fall back to midnight rather than leaving the migration stuck.
    op.execute(
        "UPDATE breakdown_entries SET mechanic_reported_time = '00:00' "
        "WHERE mechanic_reported_time IS NULL"
    )

    op.alter_column(
        "breakdown_entries",
        "mechanic_reported_time",
        new_column_name="reported_time",
        existing_type=sa.Time(),
        nullable=False,
    )
    op.drop_column("breakdown_entries", "breakdown_time")

    # 2. Backfill a ticket for every existing breakdown that doesn't already
    #    have one. `tickets.source_entry_id` is unique, and breakdowns created
    #    after Task 1 shipped (including dev/seed data on any environment this
    #    migration runs against) already got an auto-created ticket at write
    #    time — only genuinely pre-ticket rows need one here.
    connection = op.get_bind()
    rows = connection.execute(
        sa.text(
            "SELECT e.id, e.created_by_id, e.status, be.resolved_at, be.resolved_by_id "
            "FROM entries e "
            "JOIN breakdown_entries be ON be.entry_id = e.id "
            "LEFT JOIN tickets t ON t.source_entry_id = e.id "
            "WHERE e.register = 'breakdown' AND t.id IS NULL"
        )
    ).fetchall()
    for row in rows:
        ticket_id = uuid.uuid4().hex
        status = "completed" if row.status == "resolved" else "open"
        connection.execute(
            sa.text(
                "INSERT INTO tickets "
                "(id, source_entry_id, status, completed_at, completed_by_id, "
                " attended_at, created_at, created_by_id) "
                "VALUES (:id, :source_entry_id, :status, :completed_at, "
                " :completed_by_id, NULL, now(), :created_by_id)"
            ),
            {
                "id": ticket_id,
                "source_entry_id": row.id,
                "status": status,
                "completed_at": row.resolved_at,
                "completed_by_id": row.resolved_by_id,
                "created_by_id": row.created_by_id,
            },
        )


def downgrade() -> None:
    # Tickets backfilled by this migration are not distinguishable from ones
    # created normally after upgrade — downgrade leaves them in place
    # (harmless: `tickets` is dropped in Task 1's downgrade if you roll back
    # that far) and only reverses the column change.
    op.add_column(
        "breakdown_entries", sa.Column("breakdown_time", sa.Time(), nullable=True)
    )
    op.alter_column(
        "breakdown_entries",
        "reported_time",
        new_column_name="mechanic_reported_time",
        existing_type=sa.Time(),
        nullable=True,
    )
