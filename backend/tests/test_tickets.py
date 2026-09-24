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
