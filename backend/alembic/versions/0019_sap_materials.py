"""SAP master sync: materials catalog and a site's functional location

Revision ID: 0019
Revises: 0018
Create Date: 2026-08-24

docs/superpowers/specs/2026-08-24-sap-pm-enm-integration-design.md, section 2 —
scoped to what the rest of this integration actually reads: the materials
picker needs `sap_materials` populated, and `vehicles.sap_equipment_no`
(already a column since 0018) needs something to write it. The lookup-table
and task-list sync targets the spec also lists are left out — nothing built
so far reads them, and syncing data nothing consumes is its own bug.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0019"
down_revision = "0018"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("sites", sa.Column("sap_floc", sa.String(60), nullable=True))

    op.create_table(
        "sap_materials",
        sa.Column("id", sa.String(32), nullable=False),
        sa.Column("sap_material_no", sa.String(40), nullable=False),
        sa.Column("description", sa.String(255), nullable=False),
        sa.Column("uom", sa.String(20), nullable=False, server_default=""),
        sa.Column(
            "is_active", sa.Boolean(), nullable=False, server_default=sa.text("true")
        ),
        sa.PrimaryKeyConstraint("id", name="pk_sap_materials"),
        sa.UniqueConstraint(
            "sap_material_no", name="uq_sap_materials_sap_material_no"
        ),
    )


def downgrade() -> None:
    op.drop_table("sap_materials")
    op.drop_column("sites", "sap_floc")
