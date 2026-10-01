"""ticket_source_kind on work_types -- a stable identity a ticket routes on,
independent of the editable `code` string.

create_ticket_for_inspection_result used to match `work_type.code` against
three hardcoded literals ("D.I", "10 DAYS SERVICE", "P.M") to decide which
TicketSourceKind a failed check mints. A manager renaming the code (the
field is explicitly editable -- "a manager can re-route later") silently
drops the work type out of that match with no error anywhere: `is_inspection`
stays true, the inspection records fine, the failure is real, it just never
becomes a ticket. This column backs that decision with an explicit,
non-code identity instead.

Revision ID: 0043
Revises: 0042
Create Date: 2026-10-01
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa

revision = "0043"
down_revision = "0042"
branch_labels = None
depends_on = None

_ticket_source_kind = sa.Enum(
    "breakdown",
    "coolant",
    "driver_complaint",
    "daily_inspection",
    "ten_day_inspection",
    "pm_docking",
    "pm_schedule",
    name="ticket_source_kind_enum",
)

#: The only three codes create_ticket_for_inspection_result has ever
#: matched (services/tickets.py's own _INSPECTION_WORK_TYPE_SOURCE_KIND) --
#: backfilled once, by whatever a row's code happens to be *right now*, not
#: re-matched again after this.
_BACKFILL = {
    "D.I": "daily_inspection",
    "10 DAYS SERVICE": "ten_day_inspection",
    "P.M": "pm_docking",
}


def backfill_from_ticket_history(conn: sa.engine.Connection) -> None:
    """Recover a work type whose code was already renamed *before* this
    migration runs -- by then the code match in `upgrade()` can't see it,
    but it already minted a ticket of the kind in question, and every
    ticket's own `source_kind` was stamped at creation time off the code
    match that existed back then. A historical ticket is still real
    evidence, independent of what the code says now.

    `WHERE ticket_source_kind IS NULL` so this never overwrites a row the
    code match already handled (or an already-correct existing value).
    This still can't recover a work type renamed before it ever minted a
    single ticket -- no record anywhere says what it used to be -- but that
    gap is unrecoverable by any backfill, not specific to this one.

    Pulled out of `upgrade()` so a test can exercise this exact SQL against
    a crafted pre-rename fixture without needing a full alembic upgrade
    cycle -- this repo's test schema is built from the current models, not
    replayed migration-by-migration.
    """
    for kind in _BACKFILL.values():
        conn.execute(
            sa.text(
                """
                UPDATE work_types
                SET ticket_source_kind = :kind
                WHERE ticket_source_kind IS NULL
                  AND id IN (
                      SELECT ie.work_type_id
                      FROM tickets t
                      JOIN inspection_results ir
                          ON ir.id = t.source_inspection_result_id
                      JOIN inspection_entries ie
                          ON ie.id = ir.inspection_id
                      WHERE t.source_kind = :kind
                  )
                """
            ),
            {"kind": kind},
        )


def upgrade() -> None:
    op.add_column(
        "work_types",
        sa.Column("ticket_source_kind", _ticket_source_kind, nullable=True),
    )
    conn = op.get_bind()
    for code, kind in _BACKFILL.items():
        conn.execute(
            sa.text(
                "UPDATE work_types SET ticket_source_kind = :kind "
                "WHERE code = :code AND is_inspection = true"
            ),
            {"kind": kind, "code": code},
        )
    backfill_from_ticket_history(conn)


def downgrade() -> None:
    op.drop_column("work_types", "ticket_source_kind")
