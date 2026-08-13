from __future__ import annotations

from datetime import UTC, date, datetime, timedelta

from httpx import AsyncClient
from sqlalchemy import select, update

from app.db import SessionLocal
from app.models.entry import BreakdownEntry, Entry
from app.services.notifications import scan_breakdown_sla
from tests.conftest import auth_headers

TODAY = date.today().isoformat()

BREAKDOWN = {
    "register": "breakdown",
    "depot": "MBMT",
    "date": TODAY,
    "data": {"bus_no": "MH40LY1895", "complaint": "HV contactor tripped"},
}


async def test_device_token_registration_is_idempotent(client: AsyncClient) -> None:
    h = await auth_headers(client)
    payload = {"fcm_token": "d" * 64, "platform": "android"}
    first = await client.post("/devices/token", json=payload, headers=h)
    assert first.status_code == 201
    second = await client.post("/devices/token", json=payload, headers=h)
    assert second.status_code == 201
    assert second.json()["id"] == first.json()["id"]


async def test_creator_is_not_notified_of_own_breakdown(client: AsyncClient) -> None:
    mgr = await auth_headers(client)
    await client.post("/entries", json=BREAKDOWN, headers=mgr)

    mine = await client.get("/notifications", headers=mgr)
    assert mine.json()["total"] == 0

    sup = await auth_headers(client, "TV4102")
    assert (await client.get("/notifications", headers=sup)).json()["total"] == 1


async def test_resolution_notifies_original_reporter(client: AsyncClient) -> None:
    sup = await auth_headers(client, "TV4102")
    entry = (await client.post("/entries", json=BREAKDOWN, headers=sup)).json()

    mgr = await auth_headers(client)
    await client.post(f"/entries/{entry['id']}/resolve", headers=mgr)

    inbox = (await client.get("/notifications", headers=sup)).json()["items"]
    assert any(n["type"] == "breakdown_resolved" for n in inbox)


async def test_mark_read_and_read_all(client: AsyncClient) -> None:
    mgr = await auth_headers(client)
    await client.post("/entries", json=BREAKDOWN, headers=mgr)
    sup = await auth_headers(client, "TV4102")

    items = (await client.get("/notifications", headers=sup)).json()["items"]
    r = await client.post(f"/notifications/{items[0]['id']}/read", headers=sup)
    assert r.status_code == 200 and r.json()["is_read"] is True
    assert (await client.get("/notifications/unread-count", headers=sup)).json()[
        "unread"
    ] == 0

    await client.post("/entries", json=BREAKDOWN, headers=mgr)
    await client.post("/notifications/read-all", headers=sup)
    assert (await client.get("/notifications/unread-count", headers=sup)).json()[
        "unread"
    ] == 0


async def test_cannot_read_another_users_notification(client: AsyncClient) -> None:
    mgr = await auth_headers(client)
    await client.post("/entries", json=BREAKDOWN, headers=mgr)
    sup = await auth_headers(client, "TV4102")
    nid = (await client.get("/notifications", headers=sup)).json()["items"][0]["id"]

    other = await auth_headers(client, "TV4105")
    r = await client.post(f"/notifications/{nid}/read", headers=other)
    assert r.status_code == 404


async def test_sla_scan_fires_once_for_stale_breakdowns(
    client: AsyncClient, monkeypatch
) -> None:
    from app.config import settings

    monkeypatch.setattr(settings, "breakdown_sla_enabled", True)

    sup = await auth_headers(client, "TV4102")
    entry = (await client.post("/entries", json=BREAKDOWN, headers=sup)).json()

    # backdate so it is past the SLA window
    async with SessionLocal() as session:
        await session.execute(
            update(Entry)
            .where(Entry.id == entry["id"])
            .values(created_at=datetime.now(UTC) - timedelta(hours=9))
        )
        await session.commit()

    assert await scan_breakdown_sla() == 1
    assert await scan_breakdown_sla() == 0  # guarded by sla_notified_at

    mgr = await auth_headers(client)
    inbox = (await client.get("/notifications", headers=mgr)).json()["items"]
    assert any(n["type"] == "breakdown_sla_breach" for n in inbox)

    async with SessionLocal() as session:
        stamped = await session.scalar(
            select(BreakdownEntry.sla_notified_at).where(
                BreakdownEntry.entry_id == entry["id"]
            )
        )
    assert stamped is not None
