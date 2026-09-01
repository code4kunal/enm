from __future__ import annotations

import logging
import re
from typing import Any

import httpx

from app.config import settings
from app.errors import AppError, ValidationError

logger = logging.getLogger("enm")

#: SiteOps rejects any page_size above this.
_MAX_PAGE_SIZE = 100
#: Backstop against an API that never sets has_next=false.
_MAX_PAGES = 50


class SiteOpsUnavailable(AppError):
    code = "SITEOPS_UNAVAILABLE"
    http_status = 502


def _redact_tokens(raw_body: str) -> str:
    """Mask token values in a raw JSON response before it hits the logs.

    A successful login's body carries a live SiteOps access/refresh token —
    logging it verbatim would put a 24h-valid credential into log storage.
    Everything else (result, message, roles, permissions, site_ids) is fine
    to log in full and is exactly what's useful for diagnosing a rejection.
    """
    return re.sub(
        r'"((?:access|refresh)_token)"\s*:\s*"[^"]*"',
        r'"\1": "***redacted***"',
        raw_body,
    )


async def _get(path: str, params: dict[str, Any], *, missing_ok: bool = False) -> Any:
    """A service-key GET. `missing_ok` turns a 404 into `None`.

    Worth the extra flag: "the platform does not know this user" and "the
    platform is down" must not look alike to a caller deciding whether to
    fall back to a local account.
    """
    if not settings.siteops_service_key:
        raise ValidationError("SiteOps service key is not configured on this server")
    url = f"{settings.siteops_base_url.rstrip('/')}{path}"
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.get(
                url,
                params=params,
                headers={"X-Service-Key": settings.siteops_service_key},
            )
    except httpx.HTTPError as e:
        raise SiteOpsUnavailable(f"Cannot reach SiteOps: {e}") from e
    if resp.status_code == 404 and missing_ok:
        return None
    if resp.status_code >= 400:
        raise SiteOpsUnavailable(f"SiteOps returned {resp.status_code}")
    return resp.json()


async def _get_all_pages(
    path: str, extra_params: dict[str, Any] | None = None
) -> list[dict[str, Any]]:
    """SiteOps caps page_size at 100 — walk `has_next` to collect every row.

    Also accepts a bare JSON list (dropdown endpoints) so the header switcher
    does not go empty when SiteOps skips the `{data, pagination}` envelope.
    """
    rows: list[dict[str, Any]] = []
    page = 1
    while page <= _MAX_PAGES:
        params = {"page_size": _MAX_PAGE_SIZE, "page": page, **(extra_params or {})}
        body = await _get(path, params)
        if isinstance(body, list):
            return [r for r in body if isinstance(r, dict)]
        if not isinstance(body, dict):
            return rows
        chunk = body.get("data")
        if isinstance(chunk, list):
            rows.extend(r for r in chunk if isinstance(r, dict))
        elif isinstance(chunk, dict) and isinstance(chunk.get("items"), list):
            rows.extend(r for r in chunk["items"] if isinstance(r, dict))
        pagination = body.get("pagination")
        if not pagination or not pagination.get("has_next"):
            break
        page += 1
    return rows


async def login(username: str, password: str) -> dict[str, Any] | None:
    """Authenticate against the platform. `None` means it said no.

    The platform is the estate's identity authority: it owns the password,
    the roles and the grants. Its reply carries the whole authorisation
    picture — `permissions`, `site_ids`, `roles` — which is what E&M puts in
    the session it hands back.

    A network failure is not a rejection. It raises, so the caller can fall
    back to a local account rather than telling a mechanic with correct
    credentials that they are wrong.
    """
    url = f"{settings.siteops_base_url.rstrip('/')}/auth/login"
    logger.info(
        "SiteOps login request: POST %s grant_type=password username=%r",
        url, username,
    )
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.post(
                url,
                data={
                    "grant_type": "password",
                    "username": username,
                    "password": password,
                },
            )
    except httpx.HTTPError as e:
        logger.info("SiteOps login request failed: %s", e)
        raise SiteOpsUnavailable(f"Cannot reach SiteOps: {e}") from e

    logger.info(
        "SiteOps login response: status=%d body=%s",
        resp.status_code,
        _redact_tokens(resp.text),
    )

    if resp.status_code == 401:
        return None
    if resp.status_code >= 400:
        raise SiteOpsUnavailable(f"SiteOps returned {resp.status_code}")

    try:
        body = resp.json()
    except ValueError as e:
        raise SiteOpsUnavailable("SiteOps returned a non-JSON login response") from e
    if body.get("result") is not True:
        return None
    data = body.get("data")
    return data if isinstance(data, dict) else None


async def find_user_by_email(email: str) -> dict[str, Any] | None:
    """Look up a platform identity by email, for SSO provisioning.

    `search` is SiteOps's free-text filter — case-insensitive but not
    exact, so the match is narrowed here to a real email equality rather
    than trusting the search ranking to return only one row.
    """
    rows = await _get_all_pages("/users/", {"search": email})
    needle = email.strip().lower()
    for row in rows:
        if str(row.get("email") or "").strip().lower() == needle:
            return row
    return None


async def get_user_profile(user_id: str) -> dict[str, Any] | None:
    """Full profile for a known platform id — used to recover the exact,
    case-preserved `username` SiteOps has on file, since login is
    case-sensitive but a mechanic types whatever case is habitual.

    `None` when the platform does not know this id.
    """
    try:
        body = await _get(f"/users/{user_id}", {}, missing_ok=True)
    except SiteOpsUnavailable:
        raise
    except (ValidationError, TypeError, AttributeError):
        return None
    data = body.get("data") if isinstance(body, dict) else None
    return data if isinstance(data, dict) else None


async def user_grants(user_id: str) -> dict[str, Any] | None:
    """A user's current roles and permissions, server-to-server.

    Used when a session is refreshed: the platform's own `/auth/refresh`
    issues a token with `roles=["user"]` and no permissions at all, so a
    refreshed session would otherwise come back with nothing it could do.
    Asking here means a refresh picks up grants changed since sign-in.

    `None` when the platform does not know this id — a local-only account.
    """
    try:
        body = await _get(f"/access-control/users/{user_id}/roles", {}, missing_ok=True)
    except SiteOpsUnavailable:
        raise
    except (ValidationError, TypeError, AttributeError):
        return None

    data = body.get("data") if isinstance(body, dict) else None
    roles = (data or {}).get("roles")
    if not isinstance(roles, list) or not roles:
        return None

    role_names = [str(r.get("name")) for r in roles if isinstance(r, dict) and r.get("name")]
    permissions = sorted(
        {
            str(p.get("name"))
            for r in roles
            if isinstance(r, dict)
            for p in (r.get("permissions") or [])
            if isinstance(p, dict) and p.get("name")
        }
    )
    return {"roles": role_names, "permissions": permissions}


async def user_site_ids(user_id: str) -> list[str]:
    """The platform site ids a user is assigned to. Empty if unknown."""
    try:
        body = await _get(f"/users/{user_id}", {}, missing_ok=True)
    except SiteOpsUnavailable:
        raise
    except (ValidationError, TypeError, AttributeError):
        return []
    data = body.get("data") if isinstance(body, dict) else None
    if not isinstance(data, dict):
        return []
    ids = data.get("site_ids")
    if isinstance(ids, list):
        return [str(i) for i in ids if i]
    return [
        str(s.get("id"))
        for s in (data.get("sites") or [])
        if isinstance(s, dict) and s.get("id")
    ]


async def list_site_users(
    site_id: str, is_active: bool | None = True
) -> list[dict[str, Any]]:
    """Every platform user assigned to one site.

    What the "reported by" and "supervisor" dropdowns are built from now that
    people are staffed in the platform rather than in E&M: a mechanic who has
    never opened E&M still has to be nameable on somebody else's entry.

    `is_active=None` drops the filter — the user sync needs deactivated
    SiteOps accounts too, to mirror a deactivation into E&M; the dropdown
    caller keeps the default (`True`) so a departed mechanic stops appearing
    there unchanged.
    """
    params = {"site_id": site_id, "pagination": "false"}
    if is_active is not None:
        params["is_active"] = "true" if is_active else "false"
    body = await _get("/users/", params)
    if isinstance(body, list):
        return [r for r in body if isinstance(r, dict)]
    if not isinstance(body, dict):
        return []
    data = body.get("data")
    if isinstance(data, list):
        return [r for r in data if isinstance(r, dict)]
    if isinstance(data, dict) and isinstance(data.get("items"), list):
        return [r for r in data["items"] if isinstance(r, dict)]
    return []


async def list_sites() -> list[dict[str, Any]]:
    """Every onboarded site, for mapping onto E&M site codes.

    Prefer the compact dropdown feed (what the Flutter client used before the
    proxy). Fall back to the paginated onboarding list when dropdown is empty
    or unavailable — an empty list previously hid the header site switcher.
    """
    try:
        rows = await _get_all_pages("/onboarding/sites/dropdown")
        if rows:
            return rows
    except (SiteOpsUnavailable, ValidationError, TypeError, AttributeError):
        pass

    return await _get_all_pages("/onboarding/sites")


async def list_all_vehicles(site_id: str) -> list[dict[str, Any]]:
    """Every vehicle SiteOps lists under this site id, walking every page.

    For the fleet sync — `list_vehicles()` stays single-page for the Vehicle
    Master screen's own pagination, which this would otherwise fight.
    """
    return await _get_all_pages("/master/vehicles", {"site_id": site_id})


async def list_vehicles(params: dict[str, Any]) -> dict[str, Any]:
    """One page of the platform's vehicle master.

    Passed straight through to SiteOps (page, page_size, site_id, search) so
    the Vehicle Master screen's existing pagination keeps working unchanged.
    """
    return await _get("/master/vehicles", params)


async def list_vehicle_types() -> dict[str, Any]:
    return await _get("/master/vehicle-types", {"pagination": "false"})
