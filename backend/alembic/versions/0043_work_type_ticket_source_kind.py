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


def downgrade() -> None:
    op.drop_column("work_types", "ticket_source_kind")
