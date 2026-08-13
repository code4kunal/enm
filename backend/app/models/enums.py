from __future__ import annotations

import enum


class StrEnum(str, enum.Enum):
    def __str__(self) -> str:  # pragma: no cover - trivial
        return self.value


class Role(StrEnum):
    """Privilege ladder, most to least.

    `super_admin` is platform-level: it onboards sites and its `site_access`
    list is empty and ignored. `manager` is the admin of its own sites only.
    """

    super_admin = "super_admin"
    manager = "manager"
    supervisor = "supervisor"
    executive = "executive"

    @property
    def rank(self) -> int:
        return _ROLE_RANK[self]

    @property
    def grantable_roles(self) -> tuple[Role, ...]:
        """Roles this role may hand out.

        A manager staffs its own sites but cannot mint peers or super admins —
        promotion is a super-admin act.
        """
        if self is Role.super_admin:
            return tuple(Role)
        if self is Role.manager:
            return (Role.supervisor, Role.executive)
        return ()


class Register(StrEnum):
    work_done = "work_done"
    coolant = "coolant"
    driver_complaint = "driver_complaint"
    breakdown = "breakdown"
    pm_schedule = "pm_schedule"


class EntryStatus(StrEnum):
    done = "done"
    open = "open"
    resolved = "resolved"


class Shift(StrEnum):
    A = "A"
    B = "B"
    C = "C"


class Platform(StrEnum):
    android = "android"
    ios = "ios"
    web = "web"


class NotificationType(StrEnum):
    breakdown_opened = "breakdown_opened"
    schedule_alert = "schedule_alert"
    breakdown_resolved = "breakdown_resolved"
    breakdown_sla_breach = "breakdown_sla_breach"
    account = "account"


class ImportTarget(StrEnum):
    """What a spreadsheet lands in. Mirrors `app/lib/models/site_import.dart`."""

    vehicles = "vehicles"
    defect_sources = "defectSources"
    defect_types = "defectTypes"
    service_schedule = "serviceSchedule"
    odometers = "odometers"
    snag_report = "snagReport"
    work_done = "workDone"
    coolant = "coolant"
    driver_complaint = "driverComplaint"
    breakdown = "breakdown"
    pm_schedule = "pmSchedule"

    @property
    def register(self) -> Register | None:
        return _IMPORT_TARGET_REGISTER.get(self)


class ResponseType(StrEnum):
    """What a checklist line asks for."""

    ok_not_ok = "ok_not_ok"
    reading = "reading"
    note = "note"


class CheckResult(StrEnum):
    ok = "ok"
    not_ok = "not_ok"
    na = "na"


class SlotStatus(StrEnum):
    scheduled = "scheduled"
    done = "done"
    missed = "missed"
    cancelled = "cancelled"


class AlertType(StrEnum):
    missed_inspection = "missed_inspection"
    breakdown_open = "breakdown_open"
    service_overdue = "service_overdue"


class AlertStatus(StrEnum):
    open = "open"
    acknowledged = "acknowledged"
    resolved = "resolved"


class AuditAction(StrEnum):
    entry_created = "entry_created"
    entry_updated = "entry_updated"
    entry_resolved = "entry_resolved"
    entry_photo_set = "entry_photo_set"
    entry_photo_deleted = "entry_photo_deleted"
    user_created = "user_created"
    user_updated = "user_updated"
    user_activated = "user_activated"
    user_deactivated = "user_deactivated"
    user_password_reset = "user_password_reset"
    site_created = "site_created"
    site_updated = "site_updated"
    site_activated = "site_activated"
    site_deactivated = "site_deactivated"
    vehicle_created = "vehicle_created"
    vehicle_updated = "vehicle_updated"
    vehicle_activated = "vehicle_activated"
    vehicle_deactivated = "vehicle_deactivated"
    vehicle_serviced = "vehicle_serviced"
    odometer_set = "odometer_set"
    master_item_created = "master_item_created"
    master_item_updated = "master_item_updated"
    site_config_updated = "site_config_updated"
    import_committed = "import_committed"
    schedule_generated = "schedule_generated"
    slot_updated = "slot_updated"
    slot_completed = "slot_completed"
    alert_acknowledged = "alert_acknowledged"
    inspection_recorded = "inspection_recorded"
    checklist_updated = "checklist_updated"


_ROLE_RANK: dict[Role, int] = {
    Role.super_admin: 3,
    Role.manager: 2,
    Role.supervisor: 1,
    Role.executive: 0,
}

_IMPORT_TARGET_REGISTER: dict[ImportTarget, Register] = {
    ImportTarget.work_done: Register.work_done,
    ImportTarget.coolant: Register.coolant,
    ImportTarget.driver_complaint: Register.driver_complaint,
    ImportTarget.breakdown: Register.breakdown,
    ImportTarget.pm_schedule: Register.pm_schedule,
}


# Postgres enum type names (shared between models and migrations)
ROLE_ENUM = "role_enum"
IMPORT_TARGET_ENUM = "import_target_enum"
SLOT_STATUS_ENUM = "slot_status_enum"
RESPONSE_TYPE_ENUM = "response_type_enum"
CHECK_RESULT_ENUM = "check_result_enum"
ALERT_TYPE_ENUM = "alert_type_enum"
ALERT_STATUS_ENUM = "alert_status_enum"
REGISTER_ENUM = "register_enum"
ENTRY_STATUS_ENUM = "entry_status_enum"
SHIFT_ENUM = "shift_enum"
PLATFORM_ENUM = "platform_enum"
NOTIFICATION_TYPE_ENUM = "notification_type_enum"
