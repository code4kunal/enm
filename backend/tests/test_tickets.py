from __future__ import annotations

from datetime import date

from httpx import AsyncClient

from tests.conftest import auth_headers

TODAY = date.today().isoformat()


def breakdown() -> dict:
    return {
        "register": "breakdown",
        "site": "MBMT",
        "date": TODAY,
        "data": {
            "bus_no": "MH40LY1895",
            "complaint": "HV contactor tripped, bus immobile",
            "mechanic_reported_time": "14:45",
        },
    }


async def test_breakdown_creation_auto_creates_its_ticket(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    created = await client.post("/entries", json=breakdown(), headers=h)
    assert created.status_code == 201

    r = await client.get(
        "/tickets/search",
        params={"site": "MBMT", "register": "breakdown", "q": "contactor"},
        headers=h,
    )
    assert r.status_code == 200, r.text
    results = r.json()
    assert len(results) == 1
    assert results[0]["status"] == "open"
    assert "MH40LY1895" in results[0]["title"]


async def test_ticket_search_finds_open_breakdown_by_title_text(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    created = await client.post("/entries", json=breakdown(), headers=h)
    assert created.status_code == 201

    # Task 3 auto-creates a ticket when a breakdown is reported.
    r = await client.get(
        "/tickets/search",
        params={"site": "MBMT", "register": "breakdown", "q": "contactor"},
        headers=h,
    )
    assert r.status_code == 200, r.text
    results = r.json()
    assert len(results) == 1
    assert results[0]["status"] == "open"
    assert "HV contactor" in results[0]["title"]


def coolant() -> dict:
    return {
        "register": "coolant",
        "site": "MBMT",
        "date": TODAY,
        "data": {"bus_no": "MH40LY1894", "bcs_litres": 2.5},
    }


def work_done() -> dict:
    return {
        "register": "work_done",
        "site": "MBMT",
        "date": TODAY,
        "data": {
            "shift": "A",
            "bus_no": "MH40LY1894",
            "reported_defects": "Brake pressure dropping",
            "defect_source": "Driver report",
            "defect_type": "Brakes & air system",
            "attended_details": "Replaced air dryer cartridge",
            "spare_parts_used": "Air dryer cartridge x1",
            "employee": "S. Pawar",
        },
    }


async def test_raise_ticket_on_coolant_opens_it_and_is_idempotent_guarded(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    created = await client.post("/entries", json=coolant(), headers=h)
    entry_id = created.json()["id"]
    assert created.json()["status"] == "done"

    raised = await client.post(f"/entries/{entry_id}/raise_ticket", headers=h)
    assert raised.status_code == 200, raised.text
    assert raised.json()["status"] == "open"

    again = await client.post(f"/entries/{entry_id}/raise_ticket", headers=h)
    assert again.status_code == 409


async def test_raise_ticket_rejects_breakdown(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    created = await client.post("/entries", json=breakdown(), headers=h)
    entry_id = created.json()["id"]

    r = await client.post(f"/entries/{entry_id}/raise_ticket", headers=h)
    assert r.status_code == 409


async def test_raise_ticket_rejects_work_done(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    created = await client.post("/entries", json=work_done(), headers=h)
    entry_id = created.json()["id"]

    r = await client.post(f"/entries/{entry_id}/raise_ticket", headers=h)
    assert r.status_code == 409


async def test_work_done_completing_a_breakdown_ticket_mirrors_resolved_fields(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    bd = await client.post("/entries", json=breakdown(), headers=h)
    bd_id = bd.json()["id"]
    tickets = await client.get(
        "/tickets/search",
        params={"site": "MBMT", "register": "breakdown"},
        headers=h,
    )
    ticket_id = tickets.json()[0]["ticket_id"]

    payload = work_done()
    payload["data"]["ticket_id"] = ticket_id
    payload["data"]["completes_ticket"] = True
    payload["data"]["completion_time"] = "16:00"
    r = await client.post("/entries", json=payload, headers=h)
    assert r.status_code == 201, r.text

    bd_after = await client.get(f"/entries/{bd_id}", headers=h)
    assert bd_after.json()["status"] == "resolved"
    assert bd_after.json()["data"]["resolved_at"] is not None

    still_open = await client.get(
        "/tickets/search",
        params={"site": "MBMT", "register": "breakdown"},
        headers=h,
    )
    assert still_open.json() == []


async def test_resolve_endpoint_still_works_and_completes_the_ticket(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    bd = await client.post("/entries", json=breakdown(), headers=h)
    bd_id = bd.json()["id"]
    resolved = await client.post(f"/entries/{bd_id}/resolve", headers=h)
    assert resolved.status_code == 200
    again = await client.post(f"/entries/{bd_id}/resolve", headers=h)
    assert again.status_code == 409
