"""ticket_source_kind_enum was missing the 'pm_schedule' label live.

Migration 0030's own file has always listed `pm_schedule` in its
`sa.Enum(...)` definition, but the type it actually created in any database
that ran 0030 before that label was added to the file never got it --
Alembic tracks "0030 applied", so the original `CREATE TYPE` never re-runs
just because the file changed later. The model (`TicketSourceKind`) and
every test built on `Base.metadata.create_all()` (the test suite's ephemeral
schema, not Alembic) have had it the whole time, masking the drift -- only
a real migrated Postgres database is missing it, discovered constructing a
legacy pm_schedule-sourced ticket against one.

Revision ID: 0041
Revises: 0040
Create Date: 2026-09-29
"""

from __future__ import annotations

from alembic import op

revision = "0041"
down_revision = "0040"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # ADD VALUE cannot run inside the same transaction that then uses the
    # new label, but Postgres 12+ allows it inside a normal transaction
    # otherwise -- no autocommit block needed here, unlike a type rename.
    op.execute("ALTER TYPE ticket_source_kind_enum ADD VALUE IF NOT EXISTS 'pm_schedule'")


def downgrade() -> None:
    # Postgres has no DROP VALUE -- removing a label requires rebuilding the
    # type (new type, cast every column, drop the old one, rename). Not
    # worth it for a downgrade path: pm_schedule is retired-but-legacy-safe
    # to leave in place, the same way the model has always kept it.
    pass
