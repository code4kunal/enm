"""Replace work_done_entries.spare_parts_used with a real catalogue join.

Revision ID: 0032
Revises: 0031
Create Date: 2026-09-25
"""
from __future__ import annotations

import re
import uuid

from alembic import op
import sqlalchemy as sa

revision = "0032"
down_revision = "0031"
branch_labels = None
depends_on = None

_SPLIT = re.compile(r"[,;\n]")


def upgrade() -> None:
    op.create_table(
        "work_done_spare_parts",
        sa.Column(
            "work_done_entry_id",
            sa.String(length=32),
            sa.ForeignKey("work_done_entries.entry_id", ondelete="CASCADE"),
            primary_key=True,
        ),
        sa.Column(
            "spare_part_id",
            sa.String(length=32),
            sa.ForeignKey("spare_parts.id", ondelete="RESTRICT"),
            primary_key=True,
        ),
    )

    # Backfill: every distinct non-null spare_parts_used string becomes one
    # spare_parts row (site-scoped from the entry it came from), split on
    # common delimiters; a value that doesn't split cleanly becomes one row
    # with the whole text as its name. Nothing is dropped. Ids are generated
    # in Python (uuid4().hex, matching app.models.base.new_uuid) rather than
    # gen_random_uuid() — this repo generates ids application-side only, no
    # Postgres extension is enabled for it.
    connection = op.get_bind()
    rows = connection.execute(
        sa.text(
            "SELECT wd.entry_id, e.site_code, wd.spare_parts_used "
            "FROM work_done_entries wd "
            "JOIN entries e ON e.id = wd.entry_id "
            "WHERE wd.spare_parts_used IS NOT NULL AND trim(wd.spare_parts_used) <> ''"
        )
    ).fetchall()

    # (site_code, part_text) -> spare_part_id, so the same text on the same
    # site becomes one catalogue row shared across entries, not one per entry.
    part_ids: dict[tuple[str, str], str] = {}
    for row in rows:
        parts = [p.strip() for p in _SPLIT.split(row.spare_parts_used) if p.strip()]
        for part_text in parts:
            key = (row.site_code, part_text)
            if key not in part_ids:
                new_id = uuid.uuid4().hex
                part_ids[key] = new_id
                connection.execute(
                    sa.text(
                        "INSERT INTO spare_parts (id, site_code, part_no, name, is_active) "
                        "VALUES (:id, :site_code, :part_no, :name, true)"
                    ),
                    {
                        "id": new_id,
                        "site_code": row.site_code,
                        "part_no": f"LEGACY-{new_id[:8]}",
                        "name": part_text,
                    },
                )
            connection.execute(
                sa.text(
                    "INSERT INTO work_done_spare_parts (work_done_entry_id, spare_part_id) "
                    "VALUES (:entry_id, :spare_part_id) "
                    "ON CONFLICT DO NOTHING"
                ),
                {"entry_id": row.entry_id, "spare_part_id": part_ids[key]},
            )

    op.drop_column("work_done_entries", "spare_parts_used")


def downgrade() -> None:
    op.add_column("work_done_entries", sa.Column("spare_parts_used", sa.Text(), nullable=True))
    op.drop_table("work_done_spare_parts")
