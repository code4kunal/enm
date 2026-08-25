"""WhatsApp + email as another client of the same ENM API

Revision ID: 0021
Revises: 0020
Create Date: 2026-08-24

docs/superpowers/specs/2026-08-24-sap-pm-enm-integration-design.md, section 5.
Adds the one column outbound WhatsApp needs that nothing already carries —
a user's phone number. `email` already exists on `users`.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0021"
down_revision = "0020"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "users", sa.Column("whatsapp_number", sa.String(20), nullable=True)
    )


def downgrade() -> None:
    op.drop_column("users", "whatsapp_number")
