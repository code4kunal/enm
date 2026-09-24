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
            "reported_time": "14:45",
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


async def test_editing_a_work_done_entry_after_it_completed_its_ticket_is_not_a_conflict(
    client: AsyncClient,
) -> None:
    """The edit form is GET-then-PUT-the-whole-form-back.

    `serialize_data` echoes `completes_ticket: true` once it's set, so an
    unrelated edit resubmits it too. That must not re-trigger completion —
    the ticket is already completed, and re-submitting the same completed
    state is not the same thing as trying to complete it a second time.
    """
    h = await auth_headers(client)
    bd = await client.post("/entries", json=breakdown(), headers=h)
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
    created = await client.post("/entries", json=payload, headers=h)
    assert created.status_code == 201, created.text
    entry = created.json()

    # Simulate the real round trip: GET the entry back, tweak one unrelated
    # field, PUT the whole form — completes_ticket/ticket_id ride along
    # unchanged, exactly as the edit form would send them.
    fetched = (await client.get(f"/entries/{entry['id']}", headers=h)).json()
    data = dict(fetched["data"])
    assert data["completes_ticket"] is True
    data["attended_details"] = "Confirmed fix held on next inspection"
    r = await client.put(
        f"/entries/{entry['id']}",
        json={"date": fetched["date"], "data": data},
        headers=h,
    )
    assert r.status_code == 200, r.text
    assert r.json()["data"]["attended_details"] == "Confirmed fix held on next inspection"


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


async def test_breakdown_get_lists_its_linked_work_done_sessions(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    me = await client.get("/auth/me", headers=h)
    my_id = me.json()["id"]
    bd = await client.post("/entries", json=breakdown(), headers=h)
    bd_id = bd.json()["id"]
    ticket_id = (
        await client.get(
            "/tickets/search",
            params={"site": "MBMT", "register": "breakdown", "q": bd_id},
            headers=h,
        )
    ).json()[0]["ticket_id"]

    wd = work_done()
    wd["data"]["ticket_id"] = ticket_id
    wd["data"]["attendee_user_ids"] = [my_id]
    await client.post("/entries", json=wd, headers=h)

    bd_after = await client.get(f"/entries/{bd_id}", headers=h)
    sessions = bd_after.json()["linked_sessions"]
    assert len(sessions) == 1
    assert sessions[0]["shift"] == "A"
    assert sessions[0]["attendees"] == [{"user_id": my_id, "name": me.json()["name"]}]
    assert sessions[0]["completes_ticket"] is False


async def test_non_ticketable_register_get_has_no_linked_sessions(
    client: AsyncClient,
) -> None:
    # work_done is the one register that can never itself carry a ticket
    # (breakdown/coolant/driver_complaint/pm_schedule all can, per
    # TICKETABLE_REGISTERS) — it's the true "null" case, unlike coolant,
    # which is ticketable and would report `[]` once created without a
    # ticket having been raised against it yet.
    h = await auth_headers(client)
    created = await client.post("/entries", json=work_done(), headers=h)
    got = await client.get(f"/entries/{created.json()['id']}", headers=h)
    assert got.json()["linked_sessions"] is None
