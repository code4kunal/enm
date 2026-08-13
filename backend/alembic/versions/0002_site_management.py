"""site management: depot->site rename, super_admin, vehicles, config, imports

Revision ID: 0002
Revises: 0001
Create Date: 2026-08-13

Renames rather than drops and recreates, so an existing database keeps every
entry, user and access grant. Constraint and index names are renamed too, so
`alembic revision --autogenerate` produces an empty diff afterwards.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import ENUM

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None

import_target_enum = ENUM(
    "vehicles",
    "defectSources",
    "defectTypes",
    "serviceSchedule",
    "odometers",
    "workDone",
    "coolant",
    "driverComplaint",
    "breakdown",
    "pmSchedule",
    name="import_target_enum",
    create_type=False,
)

#: (old, new) for every constraint and index the rename touches.
_RENAMES: list[tuple[str, str, str]] = [
    # table, old name, new name
    ("sites", "pk_depots", "pk_sites"),
    ("vehicles", "pk_buses", "pk_vehicles"),
    ("vehicles", "uq_buses_bus_no", "uq_vehicles_registration_no"),
    ("vehicles", "fk_buses_depot_code_depots", "fk_vehicles_site_code_sites"),
    ("user_site_access", "pk_user_depot_access", "pk_user_site_access"),
    (
        "user_site_access",
        "fk_user_depot_access_user_id_users",
        "fk_user_site_access_user_id_users",
    ),
    (
        "user_site_access",
        "fk_user_depot_access_depot_code_depots",
        "fk_user_site_access_site_code_sites",
    ),
    ("entries", "fk_entries_depot_code_depots", "fk_entries_site_code_sites"),
    ("entries", "fk_entries_bus_id_buses", "fk_entries_bus_id_vehicles"),
]

_INDEX_RENAMES = [
    ("ix_buses_depot_code_is_active", "ix_vehicles_site_code_is_active"),
    ("ix_entries_depot_code_entry_date", "ix_entries_site_code_entry_date"),
]


def upgrade() -> None:
    bind = op.get_bind()

    # --- 1. depot -> site --------------------------------------------------
    op.rename_table("depots", "sites")
    op.rename_table("buses", "vehicles")
    op.rename_table("user_depot_access", "user_site_access")

    op.alter_column("vehicles", "bus_no", new_column_name="registration_no")
    op.alter_column("vehicles", "depot_code", new_column_name="site_code")
    op.alter_column("user_site_access", "depot_code", new_column_name="site_code")
    op.alter_column("entries", "depot_code", new_column_name="site_code")
    op.alter_column("notifications", "depot_code", new_column_name="site_code")

    for table, old, new in _RENAMES:
        op.execute(f'ALTER TABLE {table} RENAME CONSTRAINT "{old}" TO "{new}"')
    for old, new in _INDEX_RENAMES:
        op.execute(f'ALTER INDEX "{old}" RENAME TO "{new}"')

    # --- 2. sites become first-class --------------------------------------
    op.add_column(
        "sites",
        sa.Column(
            "timezone",
            sa.String(64),
            nullable=False,
            server_default="Asia/Kolkata",
        ),
    )
    op.add_column(
        "sites",
        sa.Column("address", sa.String(255), nullable=False, server_default=""),
    )
    op.add_column("sites", sa.Column("commissioned_on", sa.Date(), nullable=True))
    op.add_column(
        "sites",
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("now()"),
        ),
    )
    op.add_column(
        "sites", sa.Column("updated_at", sa.DateTime(timezone=True), nullable=True)
    )
    op.alter_column("sites", "created_at", server_default=None)

    # --- 3. super_admin ----------------------------------------------------
    # ALTER TYPE ... ADD VALUE cannot run inside a transaction block on older
    # servers; IF NOT EXISTS keeps it idempotent on re-runs.
    op.execute("ALTER TYPE role_enum ADD VALUE IF NOT EXISTS 'super_admin' BEFORE 'manager'")

    # --- 4. vehicles gain specs and odometers ------------------------------
    op.add_column(
        "vehicles", sa.Column("make", sa.String(64), nullable=False, server_default="")
    )
    op.add_column(
        "vehicles", sa.Column("model", sa.String(64), nullable=False, server_default="")
    )
    op.add_column(
        "vehicles",
        sa.Column("battery_capacity_kwh", sa.Numeric(8, 2), nullable=True),
    )
    op.add_column(
        "vehicles",
        sa.Column("odometer_km", sa.Integer(), nullable=False, server_default="0"),
    )
    op.add_column(
        "vehicles",
        sa.Column("odometer_updated_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column("vehicles", sa.Column("last_service_km", sa.Integer(), nullable=True))
    op.add_column("vehicles", sa.Column("last_service_on", sa.Date(), nullable=True))
    op.add_column(
        "vehicles",
        sa.Column(
            "last_service_code", sa.String(16), nullable=False, server_default=""
        ),
    )

    op.create_table(
        "odometer_readings",
        sa.Column("id", sa.String(32), nullable=False),
        sa.Column("vehicle_id", sa.String(32), nullable=False),
        sa.Column("odometer_km", sa.Integer(), nullable=False),
        sa.Column("recorded_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("source", sa.String(64), nullable=False, server_default="manual"),
        sa.ForeignKeyConstraint(
            ["vehicle_id"],
            ["vehicles.id"],
            name="fk_odometer_readings_vehicle_id_vehicles",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_odometer_readings"),
    )
    op.create_index(
        "ix_odometer_readings_vehicle_id_recorded_at",
        "odometer_readings",
        ["vehicle_id", "recorded_at"],
    )

    # --- 5. site configuration (the docking schedule) ----------------------
    op.create_table(
        "site_configs",
        sa.Column("site_code", sa.String(16), nullable=False),
        sa.Column(
            "reminder_lead_km", sa.Integer(), nullable=False, server_default="500"
        ),
        sa.Column(
            "reminder_lead_days", sa.Integer(), nullable=False, server_default="7"
        ),
        sa.Column(
            "docking_slot_minutes", sa.Integer(), nullable=False, server_default="120"
        ),
        sa.Column(
            "max_vehicles_in_service",
            sa.Integer(),
            nullable=False,
            server_default="0",
        ),
        sa.Column(
            "odometer_sync_enabled",
            sa.Boolean(),
            nullable=False,
            server_default=sa.text("true"),
        ),
        sa.Column(
            "odometer_sync_minutes", sa.Integer(), nullable=False, server_default="60"
        ),
        sa.Column(
            "odometer_sync_source",
            sa.String(64),
            nullable=False,
            server_default="telematics",
        ),
        sa.Column(
            "odometer_last_synced_at", sa.DateTime(timezone=True), nullable=True
        ),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("updated_by_id", sa.String(32), nullable=True),
        sa.ForeignKeyConstraint(
            ["site_code"],
            ["sites.code"],
            name="fk_site_configs_site_code_sites",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["updated_by_id"],
            ["users.id"],
            name="fk_site_configs_updated_by_id_users",
            ondelete="SET NULL",
        ),
        sa.PrimaryKeyConstraint("site_code", name="pk_site_configs"),
    )

    op.create_table(
        "service_plans",
        sa.Column("id", sa.String(32), nullable=False),
        sa.Column("site_code", sa.String(16), nullable=False),
        sa.Column("code", sa.String(16), nullable=False),
        sa.Column("name", sa.String(120), nullable=False),
        sa.Column("interval_km", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("interval_days", sa.Integer(), nullable=False, server_default="0"),
        sa.Column(
            "is_active", sa.Boolean(), nullable=False, server_default=sa.text("true")
        ),
        sa.Column("notes", sa.Text(), nullable=False, server_default=""),
        sa.ForeignKeyConstraint(
            ["site_code"],
            ["sites.code"],
            name="fk_service_plans_site_code_sites",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_service_plans"),
        sa.UniqueConstraint("site_code", "code", name="uq_service_plans_site_code_code"),
    )

    op.create_table(
        "shift_windows",
        sa.Column("id", sa.String(32), nullable=False),
        sa.Column("site_code", sa.String(16), nullable=False),
        sa.Column(
            "shift",
            ENUM("A", "B", "C", name="shift_enum", create_type=False),
            nullable=False,
        ),
        sa.Column("start_time", sa.Time(), nullable=False),
        sa.Column("end_time", sa.Time(), nullable=False),
        sa.ForeignKeyConstraint(
            ["site_code"],
            ["sites.code"],
            name="fk_shift_windows_site_code_sites",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_shift_windows"),
        sa.UniqueConstraint(
            "site_code", "shift", name="uq_shift_windows_site_code_shift"
        ),
    )

    # --- 6. imports --------------------------------------------------------
    import_target_enum.create(bind, checkfirst=True)

    op.create_table(
        "site_import_profiles",
        sa.Column("id", sa.String(32), nullable=False),
        sa.Column("site_code", sa.String(16), nullable=False),
        sa.Column("name", sa.String(160), nullable=False),
        sa.Column("target", import_target_enum, nullable=False),
        sa.Column("sheet_name", sa.String(120), nullable=True),
        sa.Column("header_row", sa.Integer(), nullable=False, server_default="1"),
        sa.Column("skip_rows", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("last_run_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_by_id", sa.String(32), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(
            ["site_code"],
            ["sites.code"],
            name="fk_site_import_profiles_site_code_sites",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["created_by_id"],
            ["users.id"],
            name="fk_site_import_profiles_created_by_id_users",
            ondelete="SET NULL",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_site_import_profiles"),
    )
    op.create_index(
        "ix_site_import_profiles_site_code", "site_import_profiles", ["site_code"]
    )

    op.create_table(
        "site_import_mappings",
        sa.Column("id", sa.String(32), nullable=False),
        sa.Column("profile_id", sa.String(32), nullable=False),
        sa.Column("target_key", sa.String(64), nullable=False),
        sa.Column("source_column", sa.String(255), nullable=False, server_default=""),
        sa.Column("constant_value", sa.String(255), nullable=True),
        sa.Column("date_format", sa.String(32), nullable=True),
        sa.ForeignKeyConstraint(
            ["profile_id"],
            ["site_import_profiles.id"],
            name="fk_site_import_mappings_profile_id_site_import_profiles",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_site_import_mappings"),
    )

    op.create_table(
        "site_import_runs",
        sa.Column("id", sa.String(32), nullable=False),
        sa.Column("site_code", sa.String(16), nullable=False),
        sa.Column("profile_id", sa.String(32), nullable=True),
        sa.Column("profile_name", sa.String(160), nullable=False),
        sa.Column("target", import_target_enum, nullable=False),
        sa.Column("file_name", sa.String(255), nullable=False),
        sa.Column("rows_accepted", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("rows_rejected", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("notes", sa.Text(), nullable=False, server_default=""),
        sa.Column("run_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("run_by_id", sa.String(32), nullable=True),
        sa.ForeignKeyConstraint(
            ["site_code"],
            ["sites.code"],
            name="fk_site_import_runs_site_code_sites",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["profile_id"],
            ["site_import_profiles.id"],
            name="fk_site_import_runs_profile_id_site_import_profiles",
            ondelete="SET NULL",
        ),
        sa.ForeignKeyConstraint(
            ["run_by_id"],
            ["users.id"],
            name="fk_site_import_runs_run_by_id_users",
            ondelete="SET NULL",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_site_import_runs"),
    )
    op.create_index(
        "ix_site_import_runs_site_code_run_at",
        "site_import_runs",
        ["site_code", "run_at"],
    )


def downgrade() -> None:
    bind = op.get_bind()

    op.drop_table("site_import_runs")
    op.drop_table("site_import_mappings")
    op.drop_table("site_import_profiles")
    import_target_enum.drop(bind, checkfirst=True)

    op.drop_table("shift_windows")
    op.drop_table("service_plans")
    op.drop_table("site_configs")
    op.drop_table("odometer_readings")

    for column in (
        "last_service_code",
        "last_service_on",
        "last_service_km",
        "odometer_updated_at",
        "odometer_km",
        "battery_capacity_kwh",
        "model",
        "make",
    ):
        op.drop_column("vehicles", column)

    for column in (
        "updated_at",
        "created_at",
        "commissioned_on",
        "address",
        "timezone",
    ):
        op.drop_column("sites", column)

    for old, new in _INDEX_RENAMES:
        op.execute(f'ALTER INDEX "{new}" RENAME TO "{old}"')
    for table, old, new in _RENAMES:
        op.execute(f'ALTER TABLE {table} RENAME CONSTRAINT "{new}" TO "{old}"')

    op.alter_column("notifications", "site_code", new_column_name="depot_code")
    op.alter_column("entries", "site_code", new_column_name="depot_code")
    op.alter_column("user_site_access", "site_code", new_column_name="depot_code")
    op.alter_column("vehicles", "site_code", new_column_name="depot_code")
    op.alter_column("vehicles", "registration_no", new_column_name="bus_no")

    op.rename_table("user_site_access", "user_depot_access")
    op.rename_table("vehicles", "buses")
    op.rename_table("sites", "depots")
    # role_enum keeps `super_admin`: Postgres cannot drop an enum value.
