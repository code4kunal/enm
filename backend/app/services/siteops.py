from __future__ import annotations

from typing import Any

import httpx

from app.config import settings
from app.errors import AppError, ValidationError

#: SiteOps rejects any page_size above this.
_MAX_PAGE_SIZE = 100
#: Backstop against an API that never sets has_next=false.
_MAX_PAGES = 50


class SiteOpsUnavailable(AppError):
    code = "SITEOPS_UNAVAILABLE"
    http_status = 502


async def _get(path: str, params: dict[str, Any]) -> Any:
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
