"""SAP PM adapter — the narrow interface job-card posting drives.

Seven functions, matching docs/superpowers/specs/2026-08-24-sap-pm-enm-integration-design.md
section 2 exactly. BASIS has not yet said whether the real connector is
RFC/BAPI or S/4 OData, so this assumes a REST/OData-shaped `sap_base_url`
for now — the same generic-HTTP shape `app/services/siteops.py` uses for a
platform whose contract *is* known. Only endpoint paths and payload shapes
should need to change once BASIS confirms the transport; the plumbing
(config guard, timeout, error mapping) is written to still be correct.

Every function raises `SapUnavailable` if `sap_base_url` isn't configured —
tests exercise the posting chain by monkeypatching these functions directly
(this codebase's house pattern for external services; see `app/services/fcm.py`
and `app/services/siteops.py` — no ABC, no injected fake).
"""
from __future__ import annotations

from decimal import Decimal
from typing import Any

import httpx

from app.config import settings
from app.errors import AppError


class SapUnavailable(AppError):
    code = "SAP_UNAVAILABLE"
    http_status = 502


def _configured() -> tuple[str, dict[str, str]]:
    if not settings.sap_base_url:
        raise SapUnavailable("SAP is not configured on this server")
    headers = {}
    if settings.sap_service_key:
        headers["Authorization"] = f"Bearer {settings.sap_service_key}"
    return settings.sap_base_url.rstrip("/"), headers


async def _request(method: str, path: str, **kwargs: Any) -> dict[str, Any]:
    base, headers = _configured()
    try:
        async with httpx.AsyncClient(timeout=15.0) as client:
            resp = await client.request(
                method, f"{base}{path}", headers=headers, **kwargs
            )
    except httpx.HTTPError as e:
        raise SapUnavailable(f"Cannot reach SAP: {e}") from e
    if resp.status_code >= 400:
        raise SapUnavailable(f"SAP returned {resp.status_code}: {resp.text[:500]}")
    return resp.json()


async def get_equipment(equipment_no: str) -> dict[str, Any]:
    return await _request("GET", f"/equipment/{equipment_no}")


async def create_notification(
    *, equipment_no: str, description: str
) -> str:
    """Returns the SAP notification number."""
    body = await _request(
        "POST",
        "/notifications",
        json={"equipment_no": equipment_no, "description": description},
    )
    return body["notification_no"]


async def create_order(*, notification_no: str) -> str:
    """Returns the SAP maintenance order number — the job card's SAP twin."""
    body = await _request(
        "POST", "/orders", json={"notification_no": notification_no}
    )
    return body["order_no"]


async def add_components(
    *, order_no: str, components: list[dict[str, str | Decimal]]
) -> None:
    await _request(
        "POST", f"/orders/{order_no}/components", json={"components": components}
    )


async def confirm(
    *, order_no: str, mechanic: str | None, hours: Decimal | None, work_done: str | None
) -> None:
    await _request(
        "POST",
        f"/orders/{order_no}/confirm",
        json={"mechanic": mechanic, "hours": str(hours) if hours else None, "work_done": work_done},
    )


async def teco(*, order_no: str) -> None:
    await _request("POST", f"/orders/{order_no}/teco")


async def read_order(order_no: str) -> dict[str, Any]:
    """`{"status": "REL"|"CNF"|"TECO", "qty_issued": {material_no: qty}}` —
    exact shape TBD once BASIS confirms the connector; this is the contract
    `app.services.sap.posting` currently reads against."""
    return await _request("GET", f"/orders/{order_no}")
