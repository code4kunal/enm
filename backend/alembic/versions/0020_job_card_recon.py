"""daily two-way recon between ENM job cards and SAP orders

Revision ID: 0020
Revises: 0019
Create Date: 2026-08-24

docs/superpowers/specs/2026-08-24-sap-pm-enm-integration-design.md, section 4.
An exception list, not a third editor — this table only ever gets written
by the recon job and read/acknowledged by a person; nothing here edits
`job_cards` or SAP.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import ENUM

revision = "0020"
down_revision = "0019"
branch_labels = None
depends_on = None

job_card_recon_kind_enum = ENUM(
    "sap_only", "enm_only", "qty_mismatch", "status_mismatch",
    name="job_card_recon_kind_enum", create_type=False,
)


def upgrade() -> None:
    bind = op.get_bind()
    job_card_recon_kind_enum.create(bind, checkfirst=True)
    op.execute(
        "ALTER TYPE notification_type_enum ADD VALUE IF NOT EXISTS 'job_card_recon'"
    )

    op.create_table(
        "job_card_recon_exceptions",
        sa.Column("id", sa.String(32), nullable=False),
        sa.Column("site_code", sa.String(50), nullable=False),
        sa.Column("job_card_id", sa.String(32), nullable=True),
        sa.Column("sap_order_no", sa.String(40), nullable=True),
        sa.Column("kind", job_card_recon_kind_enum, nullable=False),
        sa.Column("detail", sa.Text(), nullable=False),
        sa.Column(
            "detected_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("now()"),
        ),
        sa.Column("resolved_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("resolved_by_id", sa.String(32), nullable=True),
        sa.PrimaryKeyConstraint("id", name="pk_job_card_recon_exceptions"),
        sa.ForeignKeyConstraint(
            ["site_code"], ["sites.code"],
            name="fk_job_card_recon_exceptions_site_code_sites",
            ondelete="RESTRICT",
        ),
        sa.ForeignKeyConstraint(
            ["job_card_id"], ["job_cards.id"],
            name="fk_job_card_recon_exceptions_job_card_id_job_cards",
            ondelete="SET NULL",
        ),
        sa.ForeignKeyConstraint(
            ["resolved_by_id"], ["users.id"],
            name="fk_job_card_recon_exceptions_resolved_by_id_users",
            ondelete="SET NULL",
        ),
    )
    op.create_index(
        "ix_job_card_recon_exceptions_site_code_resolved_at",
        "job_card_recon_exceptions",
        ["site_code", "resolved_at"],
    )


def downgrade() -> None:
    op.drop_index(
        "ix_job_card_recon_exceptions_site_code_resolved_at",
        table_name="job_card_recon_exceptions",
    )
    op.drop_table("job_card_recon_exceptions")
    bind = op.get_bind()
    job_card_recon_kind_enum.drop(bind, checkfirst=True)
    # notification_type_enum keeps 'job_card_recon': Postgres cannot drop an enum value.
