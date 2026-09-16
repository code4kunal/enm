"""audit_logs actor index for user-wise audit trail

Revision ID: 0022
Revises: 0021
Create Date: 2026-09-10

Admin Audit filters by actor; without this index a user-wise page scan
walks the whole append-only log.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0022"
down_revision = "0021"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_index(
        "ix_audit_logs_actor_id_created_at",
        "audit_logs",
        ["actor_id", "created_at"],
    )


def downgrade() -> None:
    op.drop_index("ix_audit_logs_actor_id_created_at", table_name="audit_logs")
