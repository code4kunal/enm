from __future__ import annotations

from httpx import AsyncClient

from tests.conftest import auth_headers

#: A coherent baseline each test bends in exactly one way.
VALID = {
    "site_code": "MBMT",
    "service_plans": [
        {"code": "S1", "name": "Minor", "interval_km": 10000, "interval_days": 90},
        {"code": "S2", "name": "Major", "interval_km": 40000, "interval_days": 365},
    ],
    "shifts": [
        {"shift": "A", "start": "06:00", "end": "14:00"},
        {"shift": "C", "start": "22:00", "end": "06:00"},
    ],
    "reminder_lead_km": 500,
    "reminder_lead_days": 7,
    "odometer_sync": {"enabled": True, "interval_minutes": 60, "source": "telematics"},
}


def _with(**overrides) -> dict:
    return {**VALID, **overrides}


async def _put(client: AsyncClient, body: dict, user: str = "TV4021"):
    return await client.put(
        "/sites/MBMT/config", json=body, headers=await auth_headers(client, user)
    )


async def test_a_site_starts_with_usable_defaults(client: AsyncClient) -> None:
    h = await auth_headers(client)
    r = await client.get("/sites/MBMT/config", headers=h)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["service_plans"] == []
    assert body["reminder_lead_km"] == 500
    assert body["odometer_sync"]["interval_minutes"] == 60


async def test_saving_replaces_the_whole_aggregate(client: AsyncClient) -> None:
    assert (await _put(client, VALID)).status_code == 200

    trimmed = _with(
        service_plans=[
            {"code": "S1", "name": "Minor", "interval_km": 10000, "interval_days": 90}
        ],
        shifts=[],
    )
    r = await _put(client, trimmed)
    assert r.status_code == 200
    assert [p["code"] for p in r.json()["service_plans"]] == ["S1"]
    assert r.json()["shifts"] == []


async def test_the_c_shift_may_wrap_midnight(client: AsyncClient) -> None:
    r = await _put(client, VALID)
    c = next(s for s in r.json()["shifts"] if s["shift"] == "C")
    assert c["start"] == "22:00"
    assert c["end"] == "06:00"


async def test_no_active_plan_with_an_interval_is_rejected(
    client: AsyncClient,
) -> None:
    r = await _put(
        client,
        _with(
            service_plans=[
                {"code": "S1", "name": "Idle", "interval_km": 0, "interval_days": 0}
            ]
        ),
    )
    assert r.status_code == 400
    assert "nothing will ever fall due" in r.json()["error"]["message"]


async def test_duplicate_plan_codes_are_rejected(client: AsyncClient) -> None:
    r = await _put(
        client,
        _with(
            service_plans=[
                {"code": "S1", "name": "A", "interval_km": 10000, "interval_days": 0},
                {"code": "s1", "name": "B", "interval_km": 20000, "interval_days": 0},
            ]
        ),
    )
    assert r.status_code == 400
    assert "share the same code" in r.json()["error"]["message"]


async def test_a_blank_plan_code_is_rejected(client: AsyncClient) -> None:
    r = await _put(
        client,
        _with(
            service_plans=[
                {"code": "  ", "name": "A", "interval_km": 10000, "interval_days": 0}
            ]
        ),
    )
    assert r.status_code == 400
    assert "needs a code" in r.json()["error"]["message"]


async def test_a_lead_longer_than_its_km_interval_is_rejected(
    client: AsyncClient,
) -> None:
    r = await _put(client, _with(reminder_lead_km=10000))
    assert r.status_code == 400
    assert "always read as due" in r.json()["error"]["message"]


async def test_a_lead_longer_than_its_day_interval_is_rejected(
    client: AsyncClient,
) -> None:
    r = await _put(client, _with(reminder_lead_days=90))
    assert r.status_code == 400
    assert "always read as due" in r.json()["error"]["message"]


async def test_a_sub_five_minute_sync_is_rejected(client: AsyncClient) -> None:
    r = await _put(
        client,
        _with(
            odometer_sync={
                "enabled": True,
                "interval_minutes": 1,
                "source": "telematics",
            }
        ),
    )
    assert r.status_code == 400
    assert "every 5 minutes" in r.json()["error"]["message"]


async def test_config_writes_are_manager_only(client: AsyncClient) -> None:
    assert (await _put(client, VALID, user="TV4102")).status_code == 403
    # A supervisor still reads it — the due list depends on it.
    sup = await auth_headers(client, "TV4102")
    assert (await client.get("/sites/MBMT/config", headers=sup)).status_code == 200
