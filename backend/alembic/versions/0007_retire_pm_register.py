"""retire the PM Schedule Attention register, and merge the duplicate PM code

Revision ID: 0007
Revises: 0006
Create Date: 2026-08-13

Inspections became their own record with their own checklist in 0006, which is
exactly what the PM Schedule Attention register held: defects noticed during
preventive maintenance. Keeping both means two places to write the same thing,
so the register is retired and its rows are gone.

`P.M` and `PM` were the same code typed two ways on the sheet. One survives,
and the import now matches on punctuation-insensitive form so either spelling
still lands.
"""
from __future__ import annotations

from alembic import op

revision = "0007"
down_revision = "0006"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # Those rows were inspection sweeps routed to a register before
    # inspections existed. Re-importing the source sheet lands them as
    # inspections; leaving them here would double-count the work.
    op.execute(
        "DELETE FROM entries WHERE register = 'pm_schedule'"
    )

    # One docking code, not two. Safe as a delete because nothing references
    # the duplicate — anything that did would have been re-pointed first.
    op.execute(
        """
        UPDATE inspection_entries SET work_type_id = keep.id
        FROM work_types keep, work_types dup
        WHERE keep.code = 'P.M' AND dup.code = 'PM'
          AND inspection_entries.work_type_id = dup.id
        """
    )
    op.execute(
        """
        UPDATE inspection_slots SET work_type_id = keep.id
        FROM work_types keep, work_types dup
        WHERE keep.code = 'P.M' AND dup.code = 'PM'
          AND inspection_slots.work_type_id = dup.id
        """
    )
    op.execute("DELETE FROM work_types WHERE code = 'PM'")


def downgrade() -> None:
    # The deleted entries are not recoverable; re-import the source sheet.
    op.execute(
        """
        INSERT INTO work_types (code, name, register, is_inspection, sort_order,
                                is_active)
        VALUES ('PM', 'Preventive maintenance docking', NULL, true, 7, true)
        ON CONFLICT (code) DO NOTHING
        """
    )
