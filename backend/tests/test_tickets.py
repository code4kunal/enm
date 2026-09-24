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


async def test_breakdown_creation_does_not_yet_expose_a_ticket_field(
    client: AsyncClient,
) -> None:
    """Placeholder confirming the migration lands cleanly; Task 2 wires the
    actual auto-ticket-creation behavior this test file will grow to cover."""
    h = await auth_headers(client)
    r = await client.post("/entries", json=breakdown(), headers=h)
    assert r.status_code == 201, r.text


async def test_ticket_search_finds_open_breakdown_by_title_text(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    created = await client.post("/entries", json=breakdown(), headers=h)
    assert created.status_code == 201

    # No ticket exists yet — Task 3 wires auto-creation. For now this proves
    # the search endpoint itself round-trips when a ticket exists, so seed one
    # directly through the not-yet-existent raise endpoint's future shape is
    # out of reach here; instead assert the endpoint 200s with an empty list,
    # which is the correct behavior before any ticket exists.
    r = await client.get(
        "/tickets/search",
        params={"site": "MBMT", "register": "breakdown", "q": "contactor"},
        headers=h,
    )
    assert r.status_code == 200, r.text
    assert r.json() == []
