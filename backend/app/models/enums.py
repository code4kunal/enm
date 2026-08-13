from __future__ import annotations

import enum


class StrEnum(str, enum.Enum):
    def __str__(self) -> str:  # pragma: no cover - trivial
        return self.value


class Role(StrEnum):
    manager = "manager"
    supervisor = "supervisor"
    executive = "executive"


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
    breakdown_resolved = "breakdown_resolved"
    breakdown_sla_breach = "breakdown_sla_breach"
    account = "account"


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


# Postgres enum type names (shared between models and migrations)
ROLE_ENUM = "role_enum"
REGISTER_ENUM = "register_enum"
ENTRY_STATUS_ENUM = "entry_status_enum"
SHIFT_ENUM = "shift_enum"
PLATFORM_ENUM = "platform_enum"
NOTIFICATION_TYPE_ENUM = "notification_type_enum"
