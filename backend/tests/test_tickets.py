from __future__ import annotations

from datetime import date

import pytest
from httpx import AsyncClient
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from app.db import SessionLocal
from app.errors import Conflict
from app.models.checklist import (
    ChecklistItem,
    ChecklistTemplate,
    InspectionEntry,
    InspectionResult,
)
from app.models.entry import Entry, PMScheduleEntry
from app.models.enums import CheckResult, EntryStatus, Register, TicketSourceKind
from app.models.master import Vehicle, WorkType
from app.models.ticket import Ticket
from app.models.user import User
from app.services import tickets
from tests.conftest import SUPER_ADMIN, auth_headers

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
    await client.post("/entries", json=breakdown(), headers=h)
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


async def test_direct_resolve_endpoint_is_gone(client: AsyncClient) -> None:
    """A breakdown can no longer be resolved except through a linked Work
    Done session -- there is no standalone shortcut that skips it."""
    h = await auth_headers(client)
    bd = await client.post("/entries", json=breakdown(), headers=h)
    bd_id = bd.json()["id"]
    r = await client.post(f"/entries/{bd_id}/resolve", headers=h)
    assert r.status_code == 404


async def test_completing_a_ticket_twice_is_rejected(client: AsyncClient) -> None:
    from tests.test_entries import resolve_via_work_done

    h = await auth_headers(client)
    bd = await client.post("/entries", json=breakdown(), headers=h)
    bd_id = bd.json()["id"]
    completed = await resolve_via_work_done(client, h, bd_id)
    assert completed["data"]["completes_ticket"] is True

    found = await client.get(
        "/tickets/search", params={"site": "MBMT", "q": bd_id}, headers=h
    )
    assert found.json() == []  # already completed, no longer open


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


async def _daily_inspection_result(
    session,
    *,
    not_ok: bool = True,
    site_code: str = "MBMT",
    vehicle_registration: str = "MH40LY1894",
    work_type_code: str = "D.I",
) -> InspectionResult:
    """Direct DB construction — recording an inspection through the API needs
    a checklist template with items already set up, and `ResultOut` doesn't
    expose `InspectionResult.id`, so there is no way to get a real result id
    through the HTTP surface alone. Mirrors test_inspections.py's own
    `SessionLocal`-direct setup pattern."""
    work_type = await session.scalar(select(WorkType).where(WorkType.code == work_type_code))
    if work_type is None:
        work_type = WorkType(code=work_type_code, name=work_type_code, is_inspection=True)
        session.add(work_type)
        await session.flush()
    template = await session.scalar(
        select(ChecklistTemplate).where(
            ChecklistTemplate.site_code == site_code, ChecklistTemplate.work_type_id == work_type.id
        )
    )
    if template is None:
        template = ChecklistTemplate(site_code=site_code, work_type_id=work_type.id, name=work_type_code)
        session.add(template)
        await session.flush()
        session.add(ChecklistItem(template_id=template.id, label="Brakes"))
        await session.flush()
    item = await session.scalar(select(ChecklistItem).where(ChecklistItem.template_id == template.id))
    vehicle = await session.scalar(
        select(Vehicle).where(Vehicle.registration_no == vehicle_registration)
    )
    inspection = InspectionEntry(
        site_code=site_code,
        vehicle=vehicle,
        work_type=work_type,
        inspected_on=date.today(),
        created_by_id=await _admin_id(session),
        results=[],
    )
    session.add(inspection)
    await session.flush()
    # Assigning the relationship (not just item_id), and appending rather
    # than a bare session.add, matches how record_inspection (Task 4) builds
    # results and populates InspectionResult.inspection in memory for free —
    # avoids a lazy load of .inspection/.work_type outside the async
    # greenlet context when a caller reads them synchronously right after.
    result = InspectionResult(
        item=item,
        result=CheckResult.not_ok if not_ok else CheckResult.ok,
    )
    inspection.results.append(result)
    await session.flush()
    return result


async def _seeded_pm_entry(session) -> Entry:
    """A pre-existing PM Schedule row — the register is retired for new
    writes via the API (`RETIRED_REGISTERS`), but old rows exist in real
    depot data and must still resolve/read correctly, which is exactly what
    `create_ticket_for_entry` rejecting it (rather than 500ing) proves."""
    vehicle = await session.scalar(
        select(Vehicle).where(Vehicle.registration_no == "MH40LY1894")
    )
    entry = Entry(
        register=Register.pm_schedule,
        site_code="MBMT",
        bus_id=vehicle.id,
        entry_date=date.today(),
        status=EntryStatus.done,
        created_by_id=await _admin_id(session),
    )
    session.add(entry)
    await session.flush()
    session.add(PMScheduleEntry(entry_id=entry.id, defects_noticed="legacy row"))
    await session.flush()
    return entry


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


async def test_inspection_result_cannot_get_two_tickets(client: AsyncClient) -> None:
    async with SessionLocal() as session:
        result = await _daily_inspection_result(session)
        admin = await session.get(User, await _admin_id(session))
        await tickets.create_ticket_for_inspection_result(session, result=result, creator=admin)
        with pytest.raises(Conflict):
            await tickets.create_ticket_for_inspection_result(session, result=result, creator=admin)


async def test_pm_schedule_is_no_longer_ticketable(client: AsyncClient) -> None:
    async with SessionLocal() as session:
        entry = await _seeded_pm_entry(session)
        admin = await session.get(User, await _admin_id(session))
        with pytest.raises(Conflict):
            await tickets.create_ticket_for_entry(session, entry=entry, creator=admin)


async def test_legacy_pm_schedule_ticket_still_reads(client: AsyncClient) -> None:
    """Migration 0030 backfills `source_kind` from every pre-existing
    ticket's entry register, including tickets raised before this branch
    against a pm_schedule entry (retired for new writes, but real depot
    data still has old rows). ticket_title/search_tickets must not KeyError
    on one -- they only run backward, never create a new one."""
    async with SessionLocal() as session:
        entry = await _seeded_pm_entry(session)
        admin = await session.get(User, await _admin_id(session))
        ticket = Ticket(
            source_entry=entry,
            source_kind=TicketSourceKind.pm_schedule,
            created_by_id=admin.id,
        )
        session.add(ticket)
        await session.commit()
        await session.refresh(ticket)

        title = tickets.ticket_title(ticket)
        assert "legacy row" in title  # title comes from defects_noticed
        assert entry.vehicle.registration_no in title

    h = await auth_headers(client)
    found = await client.get("/tickets/search", params={"site": "MBMT", "q": ""}, headers=h)
    assert found.status_code == 200, found.text


async def test_ticket_title_for_inspection_source(client: AsyncClient) -> None:
    async with SessionLocal() as session:
        result = await _daily_inspection_result(session)
        admin = await session.get(User, await _admin_id(session))
        ticket = await tickets.create_ticket_for_inspection_result(session, result=result, creator=admin)
        title = tickets.ticket_title(ticket)
        assert result.item.label[:20] in title
        assert result.inspection.vehicle.registration_no in title


async def test_search_tickets_scopes_inspection_source_by_site(client: AsyncClient) -> None:
    async with SessionLocal() as session:
        mbmt_result = await _daily_inspection_result(session)
        umt_result = await _daily_inspection_result(
            session, site_code="UMT", vehicle_registration="MH05GX4410"
        )
        admin = await session.get(User, await _admin_id(session))
        await tickets.create_ticket_for_inspection_result(session, result=mbmt_result, creator=admin)
        await tickets.create_ticket_for_inspection_result(session, result=umt_result, creator=admin)

        results = await tickets.search_tickets(session, site_code="MBMT", source_kind=None, q=None)
        found_ids = {r.source_inspection_result_id for r in results}
        assert mbmt_result.id in found_ids
        assert umt_result.id not in found_ids


async def test_search_tickets_matches_inspection_by_label_or_bus(client: AsyncClient) -> None:
    """An inspection-sourced ticket's title comes from the checklist item's
    label and the bus registration (ticket_title above) -- q must be able to
    match either, not just the optional remark, which the batch UI never
    sets and is None on most real failures."""
    async with SessionLocal() as session:
        result = await _daily_inspection_result(session)
        admin = await session.get(User, await _admin_id(session))
        ticket = await tickets.create_ticket_for_inspection_result(
            session, result=result, creator=admin
        )
        ticket_id = ticket.id

        by_label = await tickets.search_tickets(
            session, site_code="MBMT", source_kind=None, q="brakes"
        )
        assert ticket_id in {t.id for t in by_label}

        by_bus = await tickets.search_tickets(
            session, site_code="MBMT", source_kind=None, q="MH40LY1894"
        )
        assert ticket_id in {t.id for t in by_bus}


async def test_search_endpoint_accepts_source_kind(client: AsyncClient) -> None:
    async with SessionLocal() as session:
        result = await _daily_inspection_result(session)
        site_code = result.inspection.site_code
        admin = await session.get(User, await _admin_id(session))
        await tickets.create_ticket_for_inspection_result(session, result=result, creator=admin)
        await session.commit()

    h = await auth_headers(client)
    r = await client.get(
        "/tickets/search",
        params={"site": site_code, "source_kind": "daily_inspection"},
        headers=h,
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert len(body) == 1
    assert body[0]["source_kind"] == "daily_inspection"
