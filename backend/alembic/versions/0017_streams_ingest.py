"""fleet-streams ingest: breakdown columns, a sync cursor, a system user

Revision ID: 0017
Revises: 0016
Create Date: 2026-08-24

fleet-streams' `serving` process POSTs breakdown events and odometer batches
into ENM (docs/superpowers/specs/2026-08-24-sap-pm-enm-integration-design.md,
section 1). Three additions, all additive and reversible:

* `breakdown_entries` gets the fields a streams event carries that no
  register column already holds (severity, eta, coordinates), plus
  `streams_breakdown_id` — the idempotency key `app/services/streams.py`
  upserts on, so a retried POST re-applies the same fields rather than
  minting a second breakdown.
* `sync_cursors` is a generic one-row-per-name bookmark table, seeded empty
  here. Its first user is `replay_on_startup`'s "resume after `event_id`"
  position; nothing about its shape is streams-specific.
* A `FLEETSTREAMS` system user, so ingested entries have a real
  `created_by_id`/`resolved_by_id` to point at (both NOT NULL columns) —
  there is no human on the other end of these POSTs to attribute them to.
"""
from __future__ import annotations

import uuid

import sqlalchemy as sa
from alembic import op

revision = "0017"
down_revision = "0016"
branch_labels = None
depends_on = None

#: Matches app.services.streams.SYSTEM_USER_ID — kept as a literal here
#: rather than imported, the same reason every prior migration inlines its
#: own values: a migration must still run correctly after the model it
#: touched has moved on.
SYSTEM_USER_ID = "FLEETSTREAMS"


def upgrade() -> None:
    op.add_column(
        "breakdown_entries",
        sa.Column("streams_breakdown_id", sa.String(64), nullable=True),
    )
    op.create_unique_constraint(
        "uq_breakdown_entries_streams_breakdown_id",
        "breakdown_entries",
        ["streams_breakdown_id"],
    )
    op.add_column(
        "breakdown_entries", sa.Column("severity", sa.String(32), nullable=True)
    )
    op.add_column(
        "breakdown_entries", sa.Column("eta_min", sa.Integer(), nullable=True)
    )
    op.add_column(
        "breakdown_entries", sa.Column("lat", sa.Numeric(9, 6), nullable=True)
    )
    op.add_column(
        "breakdown_entries", sa.Column("lon", sa.Numeric(9, 6), nullable=True)
    )

    op.create_table(
        "sync_cursors",
        sa.Column("name", sa.String(64), primary_key=True),
        sa.Column("value", sa.String(255), nullable=True),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=True),
    )

    bind = op.get_bind()
    exists = bind.execute(
        sa.text("SELECT 1 FROM users WHERE user_id = :uid"),
        {"uid": SYSTEM_USER_ID},
    ).scalar()
    if not exists:
        bind.execute(
            sa.text(
                "INSERT INTO users (id, name, user_id, role, is_active, "
                "must_reset_password, created_at) "
                "VALUES (:id, :name, :user_id, "
                "CAST(:role AS role_enum), false, false, now())"
            ),
            {
                "id": uuid.uuid4().hex,
                "name": "fleet-streams",
                "user_id": SYSTEM_USER_ID,
                "role": "executive",
            },
        )


def downgrade() -> None:
    op.drop_table("sync_cursors")
    op.drop_column("breakdown_entries", "lon")
    op.drop_column("breakdown_entries", "lat")
    op.drop_column("breakdown_entries", "eta_min")
    op.drop_column("breakdown_entries", "severity")
    op.drop_constraint(
        "uq_breakdown_entries_streams_breakdown_id",
        "breakdown_entries",
        type_="unique",
    )
    op.drop_column("breakdown_entries", "streams_breakdown_id")
    # The system user is left in place — entries created while it existed
    # still reference it, and `is_active=false` accounts are otherwise
    # already meaningless anywhere but the audit trail.
