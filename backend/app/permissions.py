"""E&M's permission catalogue — the names siteops-platform stores and grants.

siteops-platform is the auth authority for the whole estate: it issues every
token and owns the one `permissions` table that every service registers into
(`POST /api/v1/access-control/permissions/sync`, see
`app/services/permission_sync.py`). This module is the source of truth for
what E&M puts in that table.

Naming — why every resource starts with `em_`
---------------------------------------------
The platform's permission table is shared, not namespaced. It already holds
`inspection`, `schedule`, `reports`, `maintenance`, `vehicle`, `master`,
`breakdown_category`, `defect_type` and seventy more resources belonging to
other services. Registering a bare `inspection:read` would not create a new
permission — it would silently match the existing row, and everyone holding
another product's `inspection:read` would gain E&M access. The `em_` prefix
is what keeps E&M's grants E&M's.

The names are permanent. Renaming a resource after it has been assigned to
roles leaves the old permission attached to every one of them.

Actions — the consumer vocabulary
---------------------------------
Consumer services use three actions; siteops-platform itself uses four
(it splits `write` into create and `update`). The sync endpoint accepts both.

    <resource>:read    GET / list
    <resource>:write   POST / PUT / PATCH
    <resource>:delete  DELETE

Roles
-----
E&M does not define roles. A platform administrator attaches these
permissions to whichever platform roles they choose (`Maintenance`,
`Supervisor`, …). `DEFAULT_ROLE_PERMISSIONS` below is only for accounts that
predate the integration and for the break-glass local admin; a
platform-issued token is authorised strictly by the permissions it carries.
"""

from __future__ import annotations

from dataclasses import dataclass

from app.models.enums import Role

#: What a consumer service may declare. The platform's own registry adds
#: "update"; ours folds updates into `write`.
STANDARD_ACTIONS: tuple[str, ...] = ("read", "write", "delete")


@dataclass(frozen=True, slots=True)
class PermissionSpec:
    """Every permission belonging to one resource."""

    resource: str
    actions: tuple[str, ...]
    description: str

    @property
    def names(self) -> list[str]:
        return [f"{self.resource}:{action}" for action in self.actions]

    def permission_dicts(self) -> list[dict[str, str]]:
        """The wire shape `/access-control/permissions/sync` expects."""
        return [
            {
                "name": f"{self.resource}:{action}",
                "description": f"{self.description} — {action}",
                "resource": self.resource,
                "action": action,
            }
            for action in self.actions
        ]


REGISTRY: list[PermissionSpec] = []


def register_resource(
    resource: str,
    *,
    description: str,
    actions: tuple[str, ...] = STANDARD_ACTIONS,
) -> PermissionSpec:
    """Declare a resource and its permissions. Idempotent by resource name."""
    for existing in REGISTRY:
        if existing.resource == resource:
            return existing
    spec = PermissionSpec(resource=resource, actions=actions, description=description)
    REGISTRY.append(spec)
    return spec


# --- the catalogue ---------------------------------------------------------
#
# One resource per thing a depot user does. Declared here rather than at the
# top of each router so the whole grant surface reads on one screen — it is
# what a platform admin sees when they build a role.

SITE = register_resource(
    "em_site",
    description="E&M site onboarding and activation",
)
SITE_CONFIG = register_resource(
    "em_site_config",
    description="E&M docking configuration and checklist setup",
    actions=("read", "write"),
)
VEHICLE = register_resource(
    "em_vehicle",
    description="E&M fleet master, odometers and service records",
)
MASTER = register_resource(
    "em_master",
    description="E&M master lists (defect sources, defect types, units)",
)
ENTRY = register_resource(
    "em_entry",
    description="E&M register entries (work done, coolant, complaints, breakdowns, PM)",
)
INSPECTION = register_resource(
    "em_inspection",
    description="E&M daily and ten-day inspections",
    actions=("read", "write"),
)
SCHEDULE = register_resource(
    "em_schedule",
    description="E&M docking schedule",
    actions=("read", "write"),
)
IMPORT = register_resource(
    "em_import",
    description="E&M spreadsheet import profiles and runs",
)
REPORT = register_resource(
    "em_report",
    description="E&M reports, exports and the Daily Maintenance Report",
    actions=("read", "write"),
)
USER = register_resource(
    "em_user",
    description="E&M user administration",
)


def all_permission_dicts() -> list[dict[str, str]]:
    """Every declared permission, in the sync endpoint's wire shape."""
    return [d for spec in REGISTRY for d in spec.permission_dicts()]


def all_permission_names() -> frozenset[str]:
    return frozenset(name for spec in REGISTRY for name in spec.names)


# --- legacy role fallback --------------------------------------------------
#
# Accounts that predate the platform integration have a `role` column and no
# claims. They are authorised from this table so a depot is not locked out
# mid-migration, and so the break-glass admin still works when the platform
# is unreachable. Platform tokens never consult it.


def _names(*specs: PermissionSpec) -> frozenset[str]:
    return frozenset(name for spec in specs for name in spec.names)


def _reads(*specs: PermissionSpec) -> frozenset[str]:
    return frozenset(f"{spec.resource}:read" for spec in specs)


def _writes(*specs: PermissionSpec) -> frozenset[str]:
    return frozenset(
        f"{spec.resource}:{action}"
        for spec in specs
        for action in ("read", "write")
        if action in spec.actions
    )


_ALL = _names(
    SITE, SITE_CONFIG, VEHICLE, MASTER, ENTRY, INSPECTION, SCHEDULE, IMPORT, REPORT, USER
)

#: Everything a supervisor does: files work, records inspections, corrects the
#: shift's paperwork, reads the rest.
#:
#: `em_entry:delete` is what lets them edit an entry somebody else filed — the
#: rule the depot has always run on, and the reason it is a separate grant
#: from `em_entry:write`, which only files your own.
_SUPERVISOR = (
    _writes(ENTRY, INSPECTION)
    | {"em_entry:delete"}
    | _reads(SITE, SITE_CONFIG, VEHICLE, MASTER, SCHEDULE, REPORT)
)

#: An executive reads. Nothing an executive does changes a record.
_EXECUTIVE = _reads(SITE, VEHICLE, MASTER, ENTRY, INSPECTION, SCHEDULE, REPORT)

DEFAULT_ROLE_PERMISSIONS: dict[Role, frozenset[str]] = {
    # Platform-level: onboards sites, mints users, reaches every site.
    Role.super_admin: _ALL,
    # Site-level admin: everything on its own sites except onboarding new ones.
    Role.manager: _ALL - frozenset({"em_site:write", "em_site:delete"}),
    Role.supervisor: _SUPERVISOR,
    Role.executive: _EXECUTIVE,
}


def permissions_for_role(role: Role) -> frozenset[str]:
    return DEFAULT_ROLE_PERMISSIONS.get(role, frozenset())
