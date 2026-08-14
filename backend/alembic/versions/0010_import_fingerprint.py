"""remember which sheet row an entry came from

Revision ID: 0010
Revises: 0009
Create Date: 2026-08-14

Re-importing a month doubled every register entry: inspections and vehicles
upsert on a natural key, but an entry had none, so each run inserted afresh.
Backfilling — re-running a corrected sheet, or loading last month — was
therefore destructive to every figure derived from the registers.

`source_fingerprint` is that missing key: a hash of the sheet row an entry was
built from, unique per site. Hand-entered rows leave it null and are never
matched, so an import can never touch what a supervisor typed.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0010"
down_revision = "0009"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # What a re-run actually did. `rows_accepted` counts rows read from the
    # sheet, which on a repeat import is every one of them — reporting that as
    # the outcome makes a no-op look like a full reload.
    op.add_column(
        "site_import_runs",
        sa.Column(
            "rows_unchanged",
            sa.Integer(),
            nullable=False,
            server_default="0",
        ),
    )
    op.add_column(
        "entries", sa.Column("source_fingerprint", sa.String(64), nullable=True)
    )
    op.add_column(
        "entries", sa.Column("import_run_id", sa.String(32), nullable=True)
    )
    op.create_foreign_key(
        "fk_entries_import_run_id",
        "entries",
        "site_import_runs",
        ["import_run_id"],
        ["id"],
        ondelete="SET NULL",
    )
    # Unique per site rather than globally: two depots can file the same sheet
    # row and they are different events. Null fingerprints are hand-entered and
    # Postgres does not compare nulls, so any number of them coexist.
    op.create_index(
        "uq_entries_site_code_source_fingerprint",
        "entries",
        ["site_code", "source_fingerprint"],
        unique=True,
        postgresql_where=sa.text("source_fingerprint IS NOT NULL"),
    )


def downgrade() -> None:
    op.drop_column("site_import_runs", "rows_unchanged")
    op.drop_index("uq_entries_site_code_source_fingerprint", table_name="entries")
    op.drop_constraint("fk_entries_import_run_id", "entries", type_="foreignkey")
    op.drop_column("entries", "import_run_id")
    op.drop_column("entries", "source_fingerprint")
