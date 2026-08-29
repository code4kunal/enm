"""What a siteops-platform token says about the person holding it.

The platform is the estate's only token issuer. Its access tokens carry the
whole authorisation decision — roles, permissions and the site ids the user
was granted — so E&M reads rather than re-derives it. See
`app/services/permission_sync.py` for how E&M's permission names get into
that grant list in the first place.

Sample claim set, from a real platform token:

    sub             "1ccb9e29-df9c-45e8-a1a2-a69f160851f9"
    user_name       "admin"
    employee_code   "ADMIN-001"
    roles           ["admin"]
    permissions     ["em_entry:read", "trips:read", …]
    site_ids        ["18e9fd58-…", "cc5c2b0f-…", …]
    security_stamp  "cee468c6a9e04dfd90ae426f1084f081"
    type            "access"
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

#: The platform's own convention: the `admin` role bypasses every permission
#: check (`modules/auth/deps.py`), and the sync endpoint auto-assigns each
#: service's permissions to it. E&M honours the same rule rather than
#: inventing a second, quieter answer to "who is the administrator".
PLATFORM_ADMIN_ROLE = "admin"


def _str_list(value: Any) -> tuple[str, ...]:
    if not isinstance(value, (list, tuple, set)):
        return ()
    return tuple(str(v).strip() for v in value if str(v).strip())


@dataclass(frozen=True, slots=True)
class PlatformClaims:
    sub: str
    user_name: str
    employee_code: str | None
    roles: frozenset[str]
    permissions: frozenset[str]
    site_ids: tuple[str, ...]
    security_stamp: str | None

    @classmethod
    def from_payload(cls, payload: dict[str, Any]) -> PlatformClaims:
        user_name = str(
            payload.get("user_name") or payload.get("username") or ""
        ).strip()
        return cls(
            sub=str(payload.get("sub") or "").strip(),
            user_name=user_name,
            employee_code=(str(payload.get("employee_code")).strip() or None)
            if payload.get("employee_code")
            else None,
            roles=frozenset(_str_list(payload.get("roles"))),
            permissions=frozenset(_str_list(payload.get("permissions"))),
            site_ids=_str_list(payload.get("site_ids")),
            security_stamp=(
                str(payload.get("security_stamp")) or None
                if payload.get("security_stamp")
                else None
            ),
        )

    @property
    def is_platform_admin(self) -> bool:
        return PLATFORM_ADMIN_ROLE in self.roles

    @property
    def local_id(self) -> str:
        """The platform UUID as E&M stores it — 32 hex characters, no dashes."""
        return self.sub.replace("-", "")
