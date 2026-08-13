"""initial schema

Revision ID: 0001
Revises:
Create Date: 2026-08-13

"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import ENUM

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None

# create_type=False: the types are created once, explicitly, in upgrade().
# Without it every table referencing an enum re-emits CREATE TYPE.
role_enum = ENUM(
    "manager", "supervisor", "executive", name="role_enum", create_type=False
)
register_enum = ENUM(
    "work_done",
    "coolant",
    "driver_complaint",
    "breakdown",
    "pm_schedule",
    name="register_enum",
    create_type=False,
)
entry_status_enum = ENUM(
    "done", "open", "resolved", name="entry_status_enum", create_type=False
)
shift_enum = ENUM("A", "B", "C", name="shift_enum", create_type=False)
platform_enum = ENUM("android", "ios", "web", name="platform_enum", create_type=False)
notification_type_enum = ENUM(
    "breakdown_opened",
    "breakdown_resolved",
    "breakdown_sla_breach",
    "account",
    name="notification_type_enum",
    create_type=False,
)


def upgrade() -> None:
    bind = op.get_bind()
    op.execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")

    for enum in (
        role_enum,
        register_enum,
        entry_status_enum,
        shift_enum,
        platform_enum,
        notification_type_enum,
    ):
        enum.create(bind, checkfirst=True)

    # --- master data -------------------------------------------------------
    op.create_table(
        "depots",
        sa.Column("code", sa.String(16), nullable=False),
        sa.Column("name", sa.String(120), nullable=False),
        sa.Column(
            "is_active", sa.Boolean(), nullable=False, server_default=sa.text("true")
        ),
        sa.PrimaryKeyConstraint("code", name="pk_depots"),
    )

    op.create_table(
        "buses",
        sa.Column("id", sa.String(32), nullable=False),
        sa.Column("bus_no", sa.String(32), nullable=False),
        sa.Column("depot_code", sa.String(16), nullable=False),
        sa.Column(
            "is_active", sa.Boolean(), nullable=False, server_default=sa.text("true")
        ),
        sa.ForeignKeyConstraint(
            ["depot_code"],
            ["depots.code"],
            name="fk_buses_depot_code_depots",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_buses"),
        sa.UniqueConstraint("bus_no", name="uq_buses_bus_no"),
    )
    op.create_index(
        "ix_buses_depot_code_is_active", "buses", ["depot_code", "is_active"]
    )

    for table in ("defect_sources", "defect_types"):
        op.create_table(
            table,
            sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
            sa.Column("name", sa.String(120), nullable=False),
            sa.Column("sort_order", sa.Integer(), nullable=False, server_default="0"),
            sa.Column(
                "is_active",
                sa.Boolean(),
                nullable=False,
                server_default=sa.text("true"),
            ),
            sa.PrimaryKeyConstraint("id", name=f"pk_{table}"),
            sa.UniqueConstraint("name", name=f"uq_{table}_name"),
        )

    # --- users -------------------------------------------------------------
    op.create_table(
        "users",
        sa.Column("id", sa.String(32), nullable=False),
        sa.Column("name", sa.String(160), nullable=False),
        sa.Column("user_id", sa.String(64), nullable=False),
        sa.Column("email", sa.String(255), nullable=True),
        sa.Column("password_hash", sa.String(255), nullable=True),
        sa.Column("role", role_enum, nullable=False),
        sa.Column(
            "is_active", sa.Boolean(), nullable=False, server_default=sa.text("true")
        ),
        sa.Column(
            "must_reset_password",
            sa.Boolean(),
            nullable=False,
            server_default=sa.text("false"),
        ),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_login_at", sa.DateTime(timezone=True), nullable=True),
        sa.PrimaryKeyConstraint("id", name="pk_users"),
        sa.UniqueConstraint("user_id", name="uq_users_user_id"),
        sa.UniqueConstraint("email", name="uq_users_email"),
    )
    op.create_index("ix_users_is_active", "users", ["is_active"])

    op.create_table(
        "user_depot_access",
        sa.Column("user_id", sa.String(32), nullable=False),
        sa.Column("depot_code", sa.String(16), nullable=False),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name="fk_user_depot_access_user_id_users",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["depot_code"],
            ["depots.code"],
            name="fk_user_depot_access_depot_code_depots",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("user_id", "depot_code", name="pk_user_depot_access"),
    )

    op.create_table(
        "refresh_tokens",
        sa.Column("id", sa.String(32), nullable=False),
        sa.Column("user_id", sa.String(32), nullable=False),
        sa.Column("token_hash", sa.String(64), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("user_agent", sa.String(255), nullable=True),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name="fk_refresh_tokens_user_id_users",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_refresh_tokens"),
        sa.UniqueConstraint("token_hash", name="uq_refresh_tokens_token_hash"),
    )
    op.create_index(
        "ix_refresh_tokens_user_id_revoked_at",
        "refresh_tokens",
        ["user_id", "revoked_at"],
    )

    op.create_table(
        "device_tokens",
        sa.Column("id", sa.String(32), nullable=False),
        sa.Column("user_id", sa.String(32), nullable=False),
        sa.Column("fcm_token", sa.String(512), nullable=False),
        sa.Column("platform", platform_enum, nullable=False),
        sa.Column(
            "is_active", sa.Boolean(), nullable=False, server_default=sa.text("true")
        ),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_seen_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name="fk_device_tokens_user_id_users",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_device_tokens"),
        sa.UniqueConstraint("fcm_token", name="uq_device_tokens_fcm_token"),
    )
    op.create_index(
        "ix_device_tokens_user_id_is_active", "device_tokens", ["user_id", "is_active"]
    )

    # --- entries -----------------------------------------------------------
    op.create_table(
        "entries",
        sa.Column("id", sa.String(32), nullable=False),
        sa.Column("register", register_enum, nullable=False),
        sa.Column("depot_code", sa.String(16), nullable=False),
        sa.Column("bus_id", sa.String(32), nullable=False),
        sa.Column("entry_date", sa.Date(), nullable=False),
        sa.Column("entry_time", sa.Time(), nullable=True),
        sa.Column("status", entry_status_enum, nullable=False),
        sa.Column("photo_url", sa.String(1024), nullable=True),
        sa.Column("photo_key", sa.String(512), nullable=True),
        sa.Column("search_text", sa.Text(), nullable=False, server_default=""),
        sa.Column("created_by_id", sa.String(32), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(
            ["depot_code"],
            ["depots.code"],
            name="fk_entries_depot_code_depots",
            ondelete="RESTRICT",
        ),
        sa.ForeignKeyConstraint(
            ["bus_id"], ["buses.id"], name="fk_entries_bus_id_buses", ondelete="RESTRICT"
        ),
        sa.ForeignKeyConstraint(
            ["created_by_id"],
            ["users.id"],
            name="fk_entries_created_by_id_users",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_entries"),
    )
    op.create_index(
        "ix_entries_depot_code_entry_date", "entries", ["depot_code", "entry_date"]
    )
    op.create_index("ix_entries_register_status", "entries", ["register", "status"])
    op.create_index("ix_entries_bus_id", "entries", ["bus_id"])
    op.create_index("ix_entries_created_by_id", "entries", ["created_by_id"])
    op.create_index(
        "ix_entries_entry_date_created_at", "entries", ["entry_date", "created_at"]
    )
    # free-text `q` search across the denormalized haystack
    op.execute(
        "CREATE INDEX ix_entries_search_text_trgm "
        "ON entries USING gin (search_text gin_trgm_ops)"
    )

    op.create_table(
        "work_done_entries",
        sa.Column("entry_id", sa.String(32), nullable=False),
        sa.Column("shift", shift_enum, nullable=True),
        sa.Column("reported_defects", sa.Text(), nullable=False),
        sa.Column("defect_source_id", sa.Integer(), nullable=True),
        sa.Column("defect_type_id", sa.Integer(), nullable=True),
        sa.Column("attended_details", sa.Text(), nullable=True),
        sa.Column("spare_parts_used", sa.Text(), nullable=True),
        sa.Column("employee", sa.String(255), nullable=True),
        sa.ForeignKeyConstraint(
            ["entry_id"],
            ["entries.id"],
            name="fk_work_done_entries_entry_id_entries",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["defect_source_id"],
            ["defect_sources.id"],
            name="fk_work_done_entries_defect_source_id_defect_sources",
            ondelete="RESTRICT",
        ),
        sa.ForeignKeyConstraint(
            ["defect_type_id"],
            ["defect_types.id"],
            name="fk_work_done_entries_defect_type_id_defect_types",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("entry_id", name="pk_work_done_entries"),
    )

    op.create_table(
        "coolant_entries",
        sa.Column("entry_id", sa.String(32), nullable=False),
        sa.Column("bcs_litres", sa.Numeric(8, 2), nullable=True),
        sa.Column("tcs_litres", sa.Numeric(8, 2), nullable=True),
        sa.Column("topped_by", sa.String(255), nullable=True),
        sa.ForeignKeyConstraint(
            ["entry_id"],
            ["entries.id"],
            name="fk_coolant_entries_entry_id_entries",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("entry_id", name="pk_coolant_entries"),
    )

    op.create_table(
        "driver_complaint_entries",
        sa.Column("entry_id", sa.String(32), nullable=False),
        sa.Column("defect_type_id", sa.Integer(), nullable=True),
        sa.Column("complaint", sa.Text(), nullable=False),
        sa.Column("rectification_action", sa.Text(), nullable=True),
        sa.Column("mechanic", sa.String(255), nullable=True),
        sa.ForeignKeyConstraint(
            ["entry_id"],
            ["entries.id"],
            name="fk_driver_complaint_entries_entry_id_entries",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["defect_type_id"],
            ["defect_types.id"],
            name="fk_driver_complaint_entries_defect_type_id_defect_types",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("entry_id", name="pk_driver_complaint_entries"),
    )

    op.create_table(
        "breakdown_entries",
        sa.Column("entry_id", sa.String(32), nullable=False),
        sa.Column("driver_id", sa.String(64), nullable=True),
        sa.Column("location", sa.String(255), nullable=True),
        sa.Column("complaint", sa.Text(), nullable=False),
        sa.Column("breakdown_time", sa.Time(), nullable=True),
        sa.Column("mechanic_reported_time", sa.Time(), nullable=True),
        sa.Column("attended_time", sa.Time(), nullable=True),
        sa.Column("loss_km", sa.Numeric(8, 2), nullable=True),
        sa.Column("attended_details", sa.Text(), nullable=True),
        sa.Column("remarks", sa.Text(), nullable=True),
        sa.Column("resolved_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("resolved_by_id", sa.String(32), nullable=True),
        sa.Column("sla_notified_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(
            ["entry_id"],
            ["entries.id"],
            name="fk_breakdown_entries_entry_id_entries",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["resolved_by_id"],
            ["users.id"],
            name="fk_breakdown_entries_resolved_by_id_users",
            ondelete="SET NULL",
        ),
        sa.PrimaryKeyConstraint("entry_id", name="pk_breakdown_entries"),
    )

    op.create_table(
        "pm_schedule_entries",
        sa.Column("entry_id", sa.String(32), nullable=False),
        sa.Column("defect_type_id", sa.Integer(), nullable=True),
        sa.Column("defects_noticed", sa.Text(), nullable=False),
        sa.Column("action_taken", sa.Text(), nullable=True),
        sa.Column("balance_job_reason", sa.Text(), nullable=True),
        sa.Column("spare_parts_used", sa.Text(), nullable=True),
        sa.Column("employees", sa.Text(), nullable=True),
        sa.ForeignKeyConstraint(
            ["entry_id"],
            ["entries.id"],
            name="fk_pm_schedule_entries_entry_id_entries",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["defect_type_id"],
            ["defect_types.id"],
            name="fk_pm_schedule_entries_defect_type_id_defect_types",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("entry_id", name="pk_pm_schedule_entries"),
    )

    # --- notifications & audit --------------------------------------------
    op.create_table(
        "notifications",
        sa.Column("id", sa.String(32), nullable=False),
        sa.Column("user_id", sa.String(32), nullable=False),
        sa.Column("type", notification_type_enum, nullable=False),
        sa.Column("title", sa.String(255), nullable=False),
        sa.Column("body", sa.Text(), nullable=False),
        sa.Column("entry_id", sa.String(32), nullable=True),
        sa.Column("depot_code", sa.String(16), nullable=True),
        sa.Column(
            "is_read", sa.Boolean(), nullable=False, server_default=sa.text("false")
        ),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name="fk_notifications_user_id_users",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["entry_id"],
            ["entries.id"],
            name="fk_notifications_entry_id_entries",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_notifications"),
    )
    op.create_index(
        "ix_notifications_user_id_is_read", "notifications", ["user_id", "is_read"]
    )
    op.create_index(
        "ix_notifications_user_id_created_at",
        "notifications",
        ["user_id", "created_at"],
    )

    op.create_table(
        "audit_logs",
        sa.Column("id", sa.String(32), nullable=False),
        sa.Column("actor_id", sa.String(32), nullable=True),
        sa.Column("action", sa.String(64), nullable=False),
        sa.Column("object_type", sa.String(32), nullable=False),
        sa.Column("object_id", sa.String(64), nullable=False),
        sa.Column("before", sa.Text(), nullable=True),
        sa.Column("after", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(
            ["actor_id"],
            ["users.id"],
            name="fk_audit_logs_actor_id_users",
            ondelete="SET NULL",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_audit_logs"),
    )
    op.create_index(
        "ix_audit_logs_object_type_object_id",
        "audit_logs",
        ["object_type", "object_id"],
    )
    op.create_index("ix_audit_logs_created_at", "audit_logs", ["created_at"])


def downgrade() -> None:
    for table in (
        "audit_logs",
        "notifications",
        "pm_schedule_entries",
        "breakdown_entries",
        "driver_complaint_entries",
        "coolant_entries",
        "work_done_entries",
        "entries",
        "device_tokens",
        "refresh_tokens",
        "user_depot_access",
        "users",
        "defect_types",
        "defect_sources",
        "buses",
        "depots",
    ):
        op.drop_table(table)

    bind = op.get_bind()
    for enum in (
        notification_type_enum,
        platform_enum,
        shift_enum,
        entry_status_enum,
        register_enum,
        role_enum,
    ):
        enum.drop(bind, checkfirst=True)
