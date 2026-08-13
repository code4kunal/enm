from __future__ import annotations

from datetime import date, timedelta

from httpx import AsyncClient

from tests.conftest import auth_headers

PLANS = {
    "site_code": "MBMT",
    "service_plans": [
        {"code": "S1", "name": "Minor", "interval_km": 10000, "interval_days": 90}
    ],
    "shifts": [],
    "reminder_lead_km": 500,
    "reminder_lead_days": 7,
    "odometer_sync": {"enabled": True, "interval_minutes": 60, "source": "telematics"},
}


async def _vehicle(client: AsyncClient, headers: dict, reg: str = "MH40LY1894") -> dict:
    fleet = (await client.get("/sites/MBMT/vehicles", headers=headers)).json()["items"]
    return next(v for v in fleet if v["registration_no"] == reg)


async def test_a_new_vehicle_has_never_been_synced(client: AsyncClient) -> None:
    """Null, not zero — a stale telematics feed has to be visible."""
    h = await auth_headers(client)
    vehicle = await _vehicle(client, h)
    assert vehicle["odometer_km"] == 0
    assert vehicle["odometer_updated_at"] is None


async def test_a_manual_reading_is_recorded(client: AsyncClient) -> None:
    h = await auth_headers(client)
    vehicle = await _vehicle(client, h)
    r = await client.put(
        f"/vehicles/{vehicle['id']}/odometer", json={"odometer_km": 42000}, headers=h
    )
    assert r.status_code == 200, r.text
    assert r.json()["odometer_km"] == 42000
    assert r.json()["odometer_updated_at"] is not None


async def test_odometers_do_not_run_backwards(client: AsyncClient) -> None:
    h = await auth_headers(client)
    vehicle = await _vehicle(client, h)
    await client.put(
        f"/vehicles/{vehicle['id']}/odometer", json={"odometer_km": 42000}, headers=h
    )
    r = await client.put(
        f"/vehicles/{vehicle['id']}/odometer", json={"odometer_km": 41999}, headers=h
    )
    assert r.status_code == 400
    assert "backwards" in r.json()["error"]["message"]


async def test_sync_without_a_provider_succeeds_and_is_idempotent(
    client: AsyncClient,
) -> None:
    """Sites with no feed rely on manual readings; the rest still works."""
    h = await auth_headers(client)
    first = await client.post("/sites/MBMT/vehicles/odometer/sync", headers=h)
    assert first.status_code == 200, first.text
    assert first.json()["readings"] == []
    # Two of MBMT's three vehicles are active; a retired one is not polled.
    assert first.json()["skipped"] == 2

    second = await client.post("/sites/MBMT/vehicles/odometer/sync", headers=h)
    assert second.status_code == 200
    assert second.json()["skipped"] == 2


async def test_due_is_unknown_without_a_reading_never_zero_km(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    assert (
        await client.put("/sites/MBMT/config", json=PLANS, headers=h)
    ).status_code == 200

    rows = (await client.get("/sites/MBMT/services/due", headers=h)).json()["items"]
    row = next(r for r in rows if r["registration_no"] == "MH40LY1894")
    assert row["status"] == "unknown"
    assert row["odometer_km"] is None
    assert row["km_remaining"] is None
    # The time-driven half still has an answer.
    assert row["days_remaining"] == 90


async def test_due_becomes_overdue_and_due_soon_by_distance(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    await client.put("/sites/MBMT/config", json=PLANS, headers=h)

    overdue = await _vehicle(client, h, "MH40LY1894")
    soon = await _vehicle(client, h, "MH40LY1895")
    await client.put(
        f"/vehicles/{overdue['id']}/odometer", json={"odometer_km": 12000}, headers=h
    )
    await client.put(
        f"/vehicles/{soon['id']}/odometer", json={"odometer_km": 9800}, headers=h
    )

    rows = (await client.get("/sites/MBMT/services/due", headers=h)).json()["items"]
    by_reg = {r["registration_no"]: r for r in rows}
    assert by_reg["MH40LY1894"]["status"] == "overdue"
    assert by_reg["MH40LY1894"]["km_remaining"] == -2000
    assert by_reg["MH40LY1895"]["status"] == "due_soon"
    assert by_reg["MH40LY1895"]["km_remaining"] == 200
    # Worst first.
    assert rows[0]["registration_no"] == "MH40LY1894"


async def test_recording_a_service_re_anchors_the_next_one(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    await client.put("/sites/MBMT/config", json=PLANS, headers=h)
    vehicle = await _vehicle(client, h)
    await client.put(
        f"/vehicles/{vehicle['id']}/odometer", json={"odometer_km": 12000}, headers=h
    )

    today = date.today()
    r = await client.post(
        f"/vehicles/{vehicle['id']}/services",
        json={
            "plan_code": "s1",
            "odometer_km": 12000,
            "serviced_on": today.isoformat(),
        },
        headers=h,
    )
    assert r.status_code == 200, r.text
    assert r.json()["last_service_km"] == 12000
    assert r.json()["last_service_code"] == "S1"

    rows = (await client.get("/sites/MBMT/services/due", headers=h)).json()["items"]
    row = next(r for r in rows if r["registration_no"] == "MH40LY1894")
    assert row["status"] == "ok"
    assert row["due_km"] == 22000
    assert row["km_remaining"] == 10000
    assert row["due_on"] == (today + timedelta(days=90)).isoformat()


async def test_retired_vehicles_are_left_out_of_the_due_list(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    await client.put("/sites/MBMT/config", json=PLANS, headers=h)
    vehicle = await _vehicle(client, h)
    await client.post(f"/vehicles/{vehicle['id']}/deactivate", headers=h)

    rows = (await client.get("/sites/MBMT/services/due", headers=h)).json()["items"]
    assert "MH40LY1894" not in [r["registration_no"] for r in rows]


async def test_no_plans_means_nothing_falls_due(client: AsyncClient) -> None:
    h = await auth_headers(client)
    rows = (await client.get("/sites/MBMT/services/due", headers=h)).json()["items"]
    assert rows == []
