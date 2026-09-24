"""one work done session per ticket per shift per day

Revision ID: 0028
Revises: 0027
Create Date: 2026-09-24

A plain table-level UniqueConstraint can't express this: `entry_date` lives
on the `entries` header, `ticket_id`/`shift` live on `work_done_entries`.
Enforced with a trigger instead of an app-level check-then-insert, which
would race under two devices submitting the same shift concurrently.
Scoped to `ticket_id IS NOT NULL` — unlinked/general work has no such limit.
"""
from __future__ import annotations

from alembic import op

revision = "0028"
down_revision = "0027"
branch_labels = None
depends_on = None

_FUNCTION = """
CREATE OR REPLACE FUNCTION check_work_done_shift_uniqueness() RETURNS trigger AS $$
DECLARE
    conflict_id varchar;
BEGIN
    IF NEW.ticket_id IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT wd.entry_id INTO conflict_id
    FROM work_done_entries wd
    JOIN entries e ON e.id = wd.entry_id
    JOIN entries new_e ON new_e.id = NEW.entry_id
    WHERE wd.ticket_id = NEW.ticket_id
      AND wd.shift IS NOT DISTINCT FROM NEW.shift
      AND e.entry_date = new_e.entry_date
      AND wd.entry_id != NEW.entry_id
    LIMIT 1;
    IF conflict_id IS NOT NULL THEN
        RAISE EXCEPTION
            'work_done_shift_uniqueness: ticket % already has a session for this date/shift (entry %)',
            NEW.ticket_id, conflict_id
            USING ERRCODE = 'unique_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
"""

_TRIGGER = """
CREATE TRIGGER trg_work_done_shift_uniqueness
BEFORE INSERT OR UPDATE ON work_done_entries
FOR EACH ROW EXECUTE FUNCTION check_work_done_shift_uniqueness();
"""


def upgrade() -> None:
    op.execute(_FUNCTION)
    op.execute(_TRIGGER)


def downgrade() -> None:
    op.execute("DROP TRIGGER IF EXISTS trg_work_done_shift_uniqueness ON work_done_entries")
    op.execute("DROP FUNCTION IF EXISTS check_work_done_shift_uniqueness()")
