"""Register E&M's permission catalogue with siteops-platform at startup.

The platform owns the permission table for every service in the estate.
`POST /access-control/permissions/sync` upserts what we declare in
`app/permissions.py` and assigns it to the platform's `admin` role; a human
administrator then attaches the permissions to whichever other roles a depot
needs (`Maintenance`, `Supervisor`, …). E&M never assigns anything itself.

The call is idempotent — every restart re-sends the same catalogue and the
platform replies with what it created versus what already existed.

A failure here is logged and swallowed. The platform being unreachable must
not stop E&M from serving requests: enforcement reads the permissions already
carried in each token, which were granted at login time and do not depend on
this call having succeeded.
"""

from __future__ import annotations

import logging

import httpx

from app.config import settings
from app.permissions import all_permission_dicts

logger = logging.getLogger("enm")

#: Identifies E&M in the platform's sync log and in the response envelope.
SERVICE_NAME = "enm-maintenance"


async def push_permissions() -> None:
    """Send every declared permission to siteops-platform. Never raises."""
    if not settings.permission_sync_enabled:
        logger.info("permission sync: disabled by configuration")
        return
    if not settings.siteops_service_key:
        logger.warning(
            "permission sync: SITEOPS_SERVICE_KEY is not set — E&M's permissions "
            "will not appear in the platform's role editor"
        )
        return

    permissions = all_permission_dicts()
    if not permissions:
        logger.warning("permission sync: nothing declared — skipping")
        return

    url = f"{settings.siteops_base_url.rstrip('/')}/access-control/permissions/sync"
    payload = {"service": SERVICE_NAME, "permissions": permissions}

    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.post(
                url,
                json=payload,
                headers={"X-Service-Key": settings.siteops_service_key},
            )
    except httpx.HTTPError as exc:
        logger.warning("permission sync: cannot reach the platform (%s)", exc)
        return

    if resp.status_code != 200:
        logger.warning(
            "permission sync: platform returned %s — %s",
            resp.status_code,
            resp.text[:300],
        )
        return

    try:
        data = resp.json().get("data") or {}
    except ValueError:
        logger.warning("permission sync: platform returned a non-JSON body")
        return

    created = data.get("created") or []
    existing = data.get("existing") or []
    logger.info(
        "permission sync: %d permission(s) registered — %d new, %d already there",
        len(permissions),
        len(created),
        len(existing),
    )
    if created:
        logger.info("permission sync: new permissions %s", ", ".join(sorted(created)))
