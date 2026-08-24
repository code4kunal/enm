"""job cards: born in ENM, posted to SAP as a retryable step chain

Revision ID: 0018
Revises: 0017
Create Date: 2026-08-24

docs/superpowers/specs/2026-08-24-sap-pm-enm-integration-design.md, section 3.
A job card is opened only when a saved entry or inspection names at least
one SAP material; posting a notification -> order -> components -> confirm
is one retryable unit of work, checkpointed on the row so a failure resumes
at the right step instead of reposting from scratch. `sap_equipment_no` on
`vehicles` gates whether a card can be opened at all — a bus SAP doesn't
know about has nothing to post an order against.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import ENUM

revision = "0018"
down_revision = "0017"
branch_labels = None
depends_on = None

job_card_source_enum = ENUM(
    "inspection", "entry", "breakdown",
    name="job_card_source_enum", create_type=False,
)
job_card_status_enum = ENUM(
    "draft", "posted", "issued", "teco", "error",
    name="job_card_status_enum", create_type=False,
)


def upgrade() -> None:
    bind = op.get_bind()
    for enum in (job_card_source_enum, job_card_status_enum):
        enum.create(bind, checkfirst=True)

    op.add_column(
        "vehicles", sa.Column("sap_equipment_no", sa.String(40), nullable=True)
    )

    op.create_table(
        "job_cards",
        sa.Column("id", sa.String(32), nullable=False),
        sa.Column("site_code", sa.String(50), nullable=False),
        sa.Column("bus_id", sa.String(32), nullable=False),
        sa.Column("source", job_card_source_enum, nullable=False),
        sa.Column("source_id", sa.String(32), nullable=False),
        sa.Column("streams_breakdown_id", sa.String(64), nullable=True),
        sa.Column(
            "status", job_card_status_enum, nullable=False, server_default="draft"
        ),
        sa.Column("sap_notification_no", sa.String(40), nullable=True),
        sa.Column("sap_order_no", sa.String(40), nullable=True),
        sa.Column("components_added_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("confirmed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("posted_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_sap_error", sa.Text(), nullable=True),
        sa.Column("mechanic", sa.String(255), nullable=True),
        sa.Column("hours", sa.Numeric(6, 2), nullable=True),
        sa.Column("work_done", sa.Text(), nullable=True),
        sa.Column("created_by_id", sa.String(32), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("now()"),
        ),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=True),
        sa.PrimaryKeyConstraint("id", name="pk_job_cards"),
        sa.UniqueConstraint(
            "source", "source_id", name="uq_job_cards_source_source_id"
        ),
        sa.ForeignKeyConstraint(
            ["site_code"], ["sites.code"],
            name="fk_job_cards_site_code_sites", ondelete="RESTRICT",
        ),
        sa.ForeignKeyConstraint(
            ["bus_id"], ["vehicles.id"],
            name="fk_job_cards_bus_id_vehicles", ondelete="RESTRICT",
        ),
        sa.ForeignKeyConstraint(
            ["created_by_id"], ["users.id"],
            name="fk_job_cards_created_by_id_users", ondelete="RESTRICT",
        ),
    )
    op.create_index(
        "ix_job_cards_site_code_status", "job_cards", ["site_code", "status"]
    )

    op.create_table(
        "job_card_components",
        sa.Column("id", sa.String(32), nullable=False),
        sa.Column("job_card_id", sa.String(32), nullable=False),
        sa.Column("sap_material_no", sa.String(40), nullable=False),
        sa.Column("qty_required", sa.Numeric(10, 2), nullable=False),
        sa.Column(
            "qty_issued", sa.Numeric(10, 2), nullable=False, server_default="0"
        ),
        sa.PrimaryKeyConstraint("id", name="pk_job_card_components"),
        sa.ForeignKeyConstraint(
            ["job_card_id"], ["job_cards.id"],
            name="fk_job_card_components_job_card_id_job_cards",
            ondelete="CASCADE",
        ),
    )


def downgrade() -> None:
    op.drop_table("job_card_components")
    op.drop_index("ix_job_cards_site_code_status", table_name="job_cards")
    op.drop_table("job_cards")
    op.drop_column("vehicles", "sap_equipment_no")

    bind = op.get_bind()
    for enum in (job_card_status_enum, job_card_source_enum):
        enum.drop(bind, checkfirst=True)
