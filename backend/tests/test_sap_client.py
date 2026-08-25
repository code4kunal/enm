from __future__ import annotations

import json
from decimal import Decimal

import httpx
import pytest

from app.config import settings
from app.services.sap import client as sap_client


async def test_add_components_serializes_decimal_quantities(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Regression: every other SAP-posting test monkeypatches `sap_client`'s
    functions directly (this codebase's house pattern), so none of them ever
    exercise real httpx JSON encoding — which rejects `Decimal` outright.
    This intercepts at the transport instead, so the real serializer runs."""
    monkeypatch.setattr(settings, "sap_base_url", "http://sap.test")
    captured: dict[str, object] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        captured["body"] = json.loads(request.read())
        return httpx.Response(200, json={"status": "ok"})

    transport = httpx.MockTransport(handler)
    real_async_client = httpx.AsyncClient
    monkeypatch.setattr(
        sap_client.httpx,
        "AsyncClient",
        lambda **kw: real_async_client(transport=transport, **kw),
    )

    await sap_client.add_components(
        order_no="ORDER-1",
        components=[{"material_no": "MAT-1", "qty": Decimal("2.50")}],
    )

    assert captured["body"] == {
        "components": [{"material_no": "MAT-1", "qty": "2.50"}]
    }
