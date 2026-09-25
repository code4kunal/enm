from __future__ import annotations

from datetime import date

import pytest
from httpx import AsyncClient
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from app.db import SessionLocal
from app.models.checklist import ChecklistItem, ChecklistTemplate, InspectionEntry, InspectionResult
from app.models.enums import CheckResult, TicketSourceKind
from app.models.master import Vehicle, WorkType
from app.models.ticket import Ticket
from app.models.user import User
from tests.conftest import SUPER_ADMIN, auth_headers

TODAY = date.today().isoformat()


def coolant() -> dict:
    return {
        "register": "coolant",
        "site": "MBMT",
        "date": TODAY,
        "data": {"bus_no": "MH40LY1894"},
    }


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


async def _ticket_for(client: AsyncClient, h: dict, entry_id: str, site: str = "MBMT") -> str:
    r = await client.get(
        "/tickets/search", params={"site": site, "q": entry_id}, headers=h
    )
    assert r.status_code == 200, r.text
    results = r.json()
    assert len(results) == 1, results
    return results[0]["ticket_id"]


async def test_an_attended_breakdown_still_round_trips_through_the_edit_form(
    client: AsyncClient,
) -> None:
    """C1: the round trip only broke once the ticket had been attended.

    Before a Work Done session exists, `attended_time` serialises as null and
    the edit form's GET-then-PUT-the-whole-form-back is harmless. Once one
    does, the server echoes a real `HH:mm` and the form writes it straight
    back — so `BreakdownData` has to accept the key, and go on ignoring it.
    """
    h = await auth_headers(client)
    bd = await client.post("/entries", json=breakdown(), headers=h)
    bd_id = bd.json()["id"]
    assert bd.json()["data"]["attended_time"] is None

    wd = work_done()
    wd["data"]["ticket_id"] = await _ticket_for(client, h, bd_id)
    assert (await client.post("/entries", json=wd, headers=h)).status_code == 201

    fetched = (await client.get(f"/entries/{bd_id}", headers=h)).json()
    stamped = fetched["data"]["attended_time"]
    assert stamped is not None

    # Verbatim: exactly what the form holds, nothing stripped.
    data = dict(fetched["data"])
    data["remarks"] = "Towed in at 18:00"
    echoed = await client.put(
        f"/entries/{bd_id}",
        json={
            "register": "breakdown",
            "site": "MBMT",
            "date": fetched["date"],
            "data": data,
        },
        headers=h,
    )
    assert echoed.status_code == 200, echoed.text
    assert echoed.json()["data"]["remarks"] == "Towed in at 18:00"
    # Inert on write: the ticket owns it, so a PUT can neither clear nor move
    # it — not even by sending a different value.
    assert echoed.json()["data"]["attended_time"] == stamped

    data["attended_time"] = "03:00"
    forged = await client.put(
        f"/entries/{bd_id}",
        json={
            "register": "breakdown",
            "site": "MBMT",
            "date": fetched["date"],
            "data": data,
        },
        headers=h,
    )
    assert forged.status_code == 200, forged.text
    assert forged.json()["data"]["attended_time"] == stamped


async def test_a_work_done_entry_cannot_link_another_sites_ticket(
    client: AsyncClient,
) -> None:
    """I3: site is the tenant boundary, and a ticket belongs to a site.

    TV4021 reaches both MBMT and UMT, which is exactly what makes this
    reachable without a permission error: the UMT breakdown is legitimately
    theirs to create, and the MBMT Work Done entry is legitimately theirs to
    write. Linking one to the other is not.
    """
    h = await auth_headers(client)
    umt = {
        "register": "breakdown",
        "site": "UMT",
        "date": TODAY,
        "data": {
            "bus_no": "MH05GX4410",
            "complaint": "Air leak, bus immobile",
            "reported_time": "08:00",
        },
    }
    created = await client.post("/entries", json=umt, headers=h)
    assert created.status_code == 201, created.text
    umt_ticket = await _ticket_for(client, h, created.json()["id"], site="UMT")

    wd = work_done()  # MBMT bus, MBMT site
    wd["data"]["ticket_id"] = umt_ticket
    r = await client.post("/entries", json=wd, headers=h)
    assert r.status_code == 400, r.text
    assert r.json()["error"]["fields"]["ticket_id"] == "not found"

    # The UMT breakdown is untouched — not attended, still open.
    after = (await client.get(f"/entries/{created.json()['id']}", headers=h)).json()
    assert after["status"] == "open"
    assert after["data"]["attended_time"] is None


async def test_attend_and_completion_times_come_from_the_session_not_the_clock(
    client: AsyncClient,
) -> None:
    """I6: `entry_date` is user-supplied and routinely backdated.

    A month of paper caught up in one sitting must not stamp every breakdown
    it attends with today. Both the attend moment and the completion moment
    are derived from the session's own date and times.
    """
    h = await auth_headers(client)
    bd = await client.post("/entries", json=breakdown(), headers=h)
    bd_id = bd.json()["id"]
    ticket_id = await _ticket_for(client, h, bd_id)

    wd = work_done()
    wd["date"] = "2026-03-04"
    wd["entry_time"] = "11:20"
    wd["data"]["ticket_id"] = ticket_id
    wd["data"]["completes_ticket"] = True
    wd["data"]["completion_time"] = "13:45"
    assert (await client.post("/entries", json=wd, headers=h)).status_code == 201

    after = (await client.get(f"/entries/{bd_id}", headers=h)).json()
    assert after["data"]["attended_time"] == "11:20"
    assert after["data"]["resolved_at"].startswith("2026-03-04T13:45")


async def test_a_completed_ticket_cannot_be_uncompleted_by_editing_its_session(
    client: AsyncClient,
) -> None:
    """I7: completion is one-directional from this path.

    Unchecking the box would leave the ticket completed and the breakdown
    `resolved` with nothing claiming the completion. There is no un-resolve,
    so the edit is refused rather than silently half-applied.
    """
    h = await auth_headers(client)
    bd = await client.post("/entries", json=breakdown(), headers=h)
    bd_id = bd.json()["id"]

    payload = work_done()
    payload["data"]["ticket_id"] = await _ticket_for(client, h, bd_id)
    payload["data"]["completes_ticket"] = True
    payload["data"]["completion_time"] = "16:00"
    entry = (await client.post("/entries", json=payload, headers=h)).json()

    fetched = (await client.get(f"/entries/{entry['id']}", headers=h)).json()
    unchecked = dict(fetched["data"])
    unchecked["completes_ticket"] = False
    unchecked.pop("completion_time", None)
    r = await client.put(
        f"/entries/{entry['id']}",
        json={"date": fetched["date"], "data": unchecked},
        headers=h,
    )
    assert r.status_code == 409, r.text
    assert r.json()["error"]["code"] == "CONFLICT"

    # Unlinking the ticket altogether is the same move by another route.
    unlinked = dict(fetched["data"])
    unlinked["completes_ticket"] = False
    unlinked["ticket_id"] = None
    unlinked.pop("completion_time", None)
    r2 = await client.put(
        f"/entries/{entry['id']}",
        json={"date": fetched["date"], "data": unlinked},
        headers=h,
    )
    assert r2.status_code == 409, r2.text

    # The breakdown stayed resolved throughout.
    assert (await client.get(f"/entries/{bd_id}", headers=h)).json()[
        "status"
    ] == "resolved"


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


async def _admin_id(session) -> str:
    """`SUPER_ADMIN` ("TV1001") is `User.user_id`, the login code — not the
    primary key a `created_by_id` FK needs."""
    return await session.scalar(select(User.id).where(User.user_id == SUPER_ADMIN))


async def _daily_inspection_result(session, *, not_ok: bool = True) -> InspectionResult:
    """Direct DB construction — recording an inspection through the API needs
    a checklist template with items already set up, and `ResultOut` doesn't
    expose `InspectionResult.id`, so there is no way to get a real result id
    through the HTTP surface alone. Mirrors test_inspections.py's own
    `SessionLocal`-direct setup pattern."""
    work_type = await session.scalar(select(WorkType).where(WorkType.code == "D.I"))
    if work_type is None:
        work_type = WorkType(code="D.I", name="Daily inspection", is_inspection=True)
        session.add(work_type)
        await session.flush()
    template = ChecklistTemplate(site_code="MBMT", work_type_id=work_type.id, name="D.I")
    session.add(template)
    await session.flush()
    item = ChecklistItem(template_id=template.id, label="Brakes")
    session.add(item)
    await session.flush()
    vehicle = await session.scalar(
        select(Vehicle).where(Vehicle.registration_no == "MH40LY1894")
    )
    inspection = InspectionEntry(
        site_code="MBMT",
        vehicle_id=vehicle.id,
        work_type_id=work_type.id,
        inspected_on=date.today(),
        created_by_id=await _admin_id(session),
        results=[],
    )
    session.add(inspection)
    await session.flush()
    result = InspectionResult(
        inspection_id=inspection.id,
        item_id=item.id,
        result=CheckResult.not_ok if not_ok else CheckResult.ok,
    )
    session.add(result)
    await session.flush()
    return result


async def test_ticket_requires_exactly_one_source(client: AsyncClient) -> None:
    async with SessionLocal() as session:
        session.add(
            Ticket(
                source_entry_id=None,
                source_inspection_result_id=None,
                source_kind=TicketSourceKind.breakdown,
                created_by_id=await _admin_id(session),
            )
        )
        with pytest.raises(IntegrityError):
            await session.flush()


async def test_ticket_rejects_both_sources_set(client: AsyncClient) -> None:
    h = await auth_headers(client)
    coolant_entry = (await client.post("/entries", json=coolant(), headers=h)).json()

    async with SessionLocal() as session:
        result = await _daily_inspection_result(session)
        session.add(
            Ticket(
                source_entry_id=coolant_entry["id"],
                source_inspection_result_id=result.id,
                source_kind=TicketSourceKind.daily_inspection,
                created_by_id=await _admin_id(session),
            )
        )
        with pytest.raises(IntegrityError):
            await session.flush()
