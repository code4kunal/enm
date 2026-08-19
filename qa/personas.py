"""Identities the QA floor tests as.

Deliberately not the seeded staff. The live database has no manager at all —
the site-level role that owns vehicles, master lists and import profiles — and
every account but the bootstrap super admin carries `must_reset_password`, so
none of them can simply be logged in as.

`QA_OTHER` is a manager on a *second* site and exists only to prove that
`site_access` is re-checked server-side on every request.
"""
from __future__ import annotations

from dataclasses import dataclass

import httpx

#: The bootstrap super admin, used ONLY to create the personas below. No test
#: asserts anything while holding this token: super_admin reaches every site
#: without a stored list, so every tenant bug is invisible from this seat.
ADMIN_HANDLE = "KUNAL"
ADMIN_PASSWORD = "admin"

#: What every QA identity ends up with, after the forced first-login change.
QA_PASSWORD = "QaFloor@2026"
#: What `POST /admin/users` is given. The API always sets
#: `must_reset_password` on a user it creates, so this is never the password a
#: persona logs in with — see `_settle_password`.
QA_TEMP_PASSWORD = "QaTemp@2026"

PRIMARY_SITE = "QASITE"
OTHER_SITE = "QASITE2"

TIMEOUT = 30.0


@dataclass(frozen=True)
class Persona:
    handle: str
    password: str
    role: str
    site: str


_WANTED: tuple[tuple[str, str, str, str], ...] = (
    ("manager", "QA_MGR", "manager", PRIMARY_SITE),
    ("supervisor", "QA_SUP", "supervisor", PRIMARY_SITE),
    ("executive", "QA_EXEC", "executive", PRIMARY_SITE),
    ("other_manager", "QA_OTHER", "manager", OTHER_SITE),
)


def _login(base_url: str, handle: str, password: str) -> httpx.Response:
    return httpx.post(
        f"{base_url}/auth/login",
        json={"user_id": handle, "password": password},
        timeout=TIMEOUT,
    )


def _admin_client(base_url: str) -> httpx.Client:
    r = _login(base_url, ADMIN_HANDLE, ADMIN_PASSWORD)
    r.raise_for_status()
    return httpx.Client(
        base_url=base_url,
        headers={"Authorization": f"Bearer {r.json()['access_token']}"},
        timeout=TIMEOUT,
    )


def _ensure_site(client: httpx.Client, code: str, name: str) -> None:
    r = client.post("/sites", json={"code": code, "name": name})
    # 409 is the site already existing, which is the normal case on re-run.
    if r.status_code not in (200, 201, 409):
        r.raise_for_status()


def _ensure_user(client: httpx.Client, p: Persona) -> None:
    r = client.post(
        "/admin/users",
        json={
            "name": p.handle.replace("_", " ").title(),
            "user_id": p.handle,
            "role": p.role,
            "site_access": [p.site],
            "temp_password": QA_TEMP_PASSWORD,
        },
    )
    if r.status_code not in (200, 201, 409):
        r.raise_for_status()


def _settle_password(base_url: str, p: Persona) -> None:
    """Get the persona to its permanent password.

    `POST /admin/users` only accepts a `temp_password` and always sets
    `must_reset_password`, so a freshly created persona cannot be used until it
    has changed its own password. Running this on every provision means the
    change-password flow is exercised by the floor rather than worked around.
    """
    if _login(base_url, p.handle, p.password).status_code == 200:
        return  # already settled by an earlier run

    first = _login(base_url, p.handle, QA_TEMP_PASSWORD)
    first.raise_for_status()
    token = first.json()["access_token"]

    changed = httpx.post(
        f"{base_url}/auth/change-password",
        json={
            "current_password": QA_TEMP_PASSWORD,
            "new_password": p.password,
        },
        headers={"Authorization": f"Bearer {token}"},
        timeout=TIMEOUT,
    )
    changed.raise_for_status()


def provision(base_url: str) -> dict[str, Persona]:
    """Create the QA sites and identities. Idempotent."""
    with _admin_client(base_url) as client:
        _ensure_site(client, PRIMARY_SITE, "QA Floor Site")
        _ensure_site(client, OTHER_SITE, "QA Tenant Probe Site")
        for _, handle, role, site in _WANTED:
            _ensure_user(
                client,
                Persona(handle=handle, password=QA_PASSWORD, role=role, site=site),
            )

    people: dict[str, Persona] = {}
    for key, handle, role, site in _WANTED:
        p = Persona(handle=handle, password=QA_PASSWORD, role=role, site=site)
        _settle_password(base_url, p)
        people[key] = p
    return people


def token_for(base_url: str, p: Persona) -> str:
    r = _login(base_url, p.handle, p.password)
    r.raise_for_status()
    return r.json()["access_token"]
