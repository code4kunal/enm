"""link a fitted unit back to the entry that fit it

Revision ID: 0019
Revises: 0018
Create Date: 2026-09-01

`fitted_units` has never carried an FK to `entries` — Bus History and the
Unit Failure Statement read a stay by (vehicle, unit_type, date), not by
entry, and that stays true. But the Daily Work Done form can now fit more
than one unit on the same save, and a bus can have more than one Work Done
entry on the same day (different shifts) — matching a fit back to "the entry
that recorded it" by vehicle+date alone would sometimes pick the wrong one.
`entry_id` is nullable and only ever set by that one write path; every other
way of fitting a unit (imports, a future admin tool) leaves it null, and
nothing downstream requires it.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0019"
down_revision = "0018"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "fitted_units", sa.Column("entry_id", sa.String(32), nullable=True)
    )
    op.create_foreign_key(
        "fk_fitted_units_entry_id_entries",
        "fitted_units",
        "entries",
        ["entry_id"],
        ["id"],
        ondelete="SET NULL",
    )
    op.create_index(
        "ix_fitted_units_entry_id", "fitted_units", ["entry_id"]
    )


def downgrade() -> None:
    op.drop_index("ix_fitted_units_entry_id", table_name="fitted_units")
    op.drop_constraint(
        "fk_fitted_units_entry_id_entries", "fitted_units", type_="foreignkey"
    )
    op.drop_column("fitted_units", "entry_id")
