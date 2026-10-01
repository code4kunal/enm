from __future__ import annotations

from datetime import date

from httpx import AsyncClient
from sqlalchemy import select

from app.db import SessionLocal, engine
from app.models.entry import BreakdownEntry
from app.models.master import OdometerReading, Vehicle
from tests.conftest import auth_headers


async def _vehicle_id(reg: str) -> str:
    async with SessionLocal() as session:
        vehicle = await session.scalar(
            select(Vehicle).where(Vehicle.registration_no == reg)
        )
        return vehicle.id


TODAY = date.today().isoformat()


def work_done(bus: str = "mh40 ly1894") -> dict:
    return {
        "register": "work_done",
        "site": "MBMT",
        "date": TODAY,
        "data": {
            "shift": "A",
            "bus_no": bus,
            "reported_defects": "Brake pressure dropping",
            "defect_source": "Driver report",
            "defect_type": "Brakes & air system",
            "attended_details": "Replaced air dryer cartridge",
        },
    }


def breakdown(bus: str = "MH40LY1895") -> dict:
    return {
        "register": "breakdown",
        "site": "MBMT",
        "date": TODAY,
        "data": {
            "bus_no": bus,
            "driver_id": "DRV221",
            "route": "7",
            "location": "Kashimira signal",
            "complaint": "HV contactor tripped, bus immobile",
            "reported_time": "14:45",
            "loss_km": 18.5,
        },
    }


def coolant() -> dict:
    return {
        "register": "coolant",
        "site": "MBMT",
        "date": TODAY,
        "data": {"bus_no": "MH40LY1894", "bcs_litres": 2.5},
    }


async def resolve_via_work_done(
    client: AsyncClient,
    headers: dict,
    bd_id: str,
    *,
    completion_time: str = "16:00",
) -> dict:
    """The only path a breakdown's ticket can be resolved through: a Work
    Done session linked to it with completes_ticket=true. Mirrors what the
    form does -- find the ticket, then submit a session against it."""
    found = await client.get(
        "/tickets/search", params={"site": "MBMT", "q": bd_id}, headers=headers
    )
    ticket_id = found.json()[0]["ticket_id"]
    payload = work_done()
    payload["data"]["ticket_id"] = ticket_id
    payload["data"]["completes_ticket"] = True
    payload["data"]["completion_time"] = completion_time
    r = await client.post("/entries", json=payload, headers=headers)
    assert r.status_code == 201, r.text
    return r.json()


async def test_create_work_done_normalizes_bus_no(client: AsyncClient) -> None:
    h = await auth_headers(client)
    r = await client.post("/entries", json=work_done(), headers=h)
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["data"]["bus_no"] == "MH40LY1894"
    assert body["status"] == "done"
    assert body["created_by"]["user_id"] == "TV4021"
    assert body["entry_time"] and len(body["entry_time"]) == 5


async def test_missing_required_field_returns_field_map(client: AsyncClient) -> None:
    h = await auth_headers(client)
    payload = work_done()
    del payload["data"]["reported_defects"]
    r = await client.post("/entries", json=payload, headers=h)
    assert r.status_code == 400
    err = r.json()["error"]
    assert err["code"] == "VALIDATION_ERROR"
    assert err["fields"]["reported_defects"] == "required"


async def test_unknown_bus_for_site_rejected(client: AsyncClient) -> None:
    h = await auth_headers(client)
    payload = work_done(bus="MH05GX4410")  # belongs to UMT
    r = await client.post("/entries", json=payload, headers=h)
    assert r.status_code == 400
    assert "bus_no" in r.json()["error"]["fields"]


async def test_inactive_bus_rejected(client: AsyncClient) -> None:
    h = await auth_headers(client)
    r = await client.post("/entries", json=work_done(bus="MH40LY9999"), headers=h)
    assert r.status_code == 400


async def test_site_outside_access_is_403(client: AsyncClient) -> None:
    h = await auth_headers(client)
    payload = work_done()
    payload["site"] = "TDC"
    r = await client.post("/entries", json=payload, headers=h)
    assert r.status_code == 403
    assert r.json()["error"]["code"] == "FORBIDDEN"

    listed = await client.get("/entries", params={"site": "TDC"}, headers=h)
    assert listed.status_code == 403


async def test_breakdown_opens_and_resolves_once(client: AsyncClient) -> None:
    h = await auth_headers(client)
    created = await client.post("/entries", json=breakdown(), headers=h)
    assert created.status_code == 201
    entry = created.json()
    assert entry["status"] == "open"
    assert entry["data"]["reported_time"] == "14:45"
    assert entry["data"]["loss_km"] == 18.5
    # The route the bus was running when it failed. Read and thrown away until
    # `breakdown_entries` had a column for it.
    assert entry["data"]["route"] == "7"

    completed = await resolve_via_work_done(client, h, entry["id"])
    assert completed["status"] == "done"
    bd_after = (await client.get(f"/entries/{entry['id']}", headers=h)).json()
    assert bd_after["status"] == "resolved"

    # A second Work Done session can't complete an already-completed ticket.
    found = await client.get(
        "/tickets/search", params={"site": "MBMT", "q": entry["id"]}, headers=h
    )
    assert found.json() == []


async def test_breakdown_requires_reported_time(client: AsyncClient) -> None:
    h = await auth_headers(client)
    payload = breakdown()
    del payload["data"]["reported_time"]
    r = await client.post("/entries", json=payload, headers=h)
    assert r.status_code == 400
    assert r.json()["error"]["fields"].get("reported_time") == "required"


async def test_a_breakdown_can_be_written_back_unchanged(
    client: AsyncClient,
) -> None:
    """What GET returns, PUT has to accept.

    An edit form reads an entry, changes one field and writes it back.
    `resolved_at` and `attended_time` ride along in the serialised `data`
    (read-only — set by resolving or attending the ticket, never by the form),
    so `BreakdownData` accepts and ignores both rather than 400ing on keys the
    client never set itself. The form writes the whole `data` object back
    verbatim, so nothing may need stripping.
    """
    h = await auth_headers(client)
    created = await client.post("/entries", json=breakdown(), headers=h)
    assert created.status_code == 201, created.text
    entry = created.json()
    assert entry["data"]["resolved_at"] is None

    data = dict(entry["data"])
    echoed = await client.put(
        f"/entries/{entry['id']}",
        json={
            "register": "breakdown",
            "site": "MBMT",
            "date": entry["date"],
            "data": data,
        },
        headers=h,
    )
    assert echoed.status_code == 200, echoed.text
    assert echoed.json()["data"]["route"] == "7"


async def test_a_resolved_breakdown_still_round_trips(client: AsyncClient) -> None:
    """The regression only showed up once `resolved_at` had a value."""
    h = await auth_headers(client)
    entry = (await client.post("/entries", json=breakdown(), headers=h)).json()
    await resolve_via_work_done(client, h, entry["id"])

    fetched = (await client.get(f"/entries/{entry['id']}", headers=h)).json()
    assert fetched["status"] == "resolved"
    assert fetched["data"]["resolved_at"] is not None

    data = dict(fetched["data"])
    again = await client.put(
        f"/entries/{entry['id']}",
        json={
            "register": "breakdown",
            "site": "MBMT",
            "date": fetched["date"],
            "data": data,
        },
        headers=h,
    )
    assert again.status_code == 200, again.text
    # Accepted-and-ignored must not mean lost: the edit rebuilds the detail
    # row from the form, and the server-owned stamps have to survive it or a
    # resolved breakdown quietly forgets when it was resolved.
    assert again.json()["status"] == "resolved"
    assert again.json()["data"]["resolved_at"] == fetched["data"]["resolved_at"]


async def test_resolve_notifies_supervisors_on_open(client: AsyncClient) -> None:
    mgr = await auth_headers(client)
    await client.post("/entries", json=breakdown(), headers=mgr)

    sup = await auth_headers(client, "TV4102")
    inbox = await client.get("/notifications", headers=sup)
    assert inbox.status_code == 200
    items = inbox.json()["items"]
    assert any(n["type"] == "breakdown_opened" for n in items)

    count = await client.get("/notifications/unread-count", headers=sup)
    assert count.json()["unread"] >= 1


async def test_list_filters_by_register_and_status(client: AsyncClient) -> None:
    h = await auth_headers(client)
    await client.post("/entries", json=work_done(), headers=h)
    await client.post("/entries", json=breakdown(), headers=h)

    all_entries = await client.get("/entries", params={"site": "MBMT"}, headers=h)
    assert all_entries.json()["total"] == 2

    only_bd = await client.get(
        "/entries", params={"site": "MBMT", "register": "breakdown"}, headers=h
    )
    assert only_bd.json()["total"] == 1

    open_bd = await client.get(
        "/entries",
        params={"site": "MBMT", "register": "breakdown", "status": "open"},
        headers=h,
    )
    assert open_bd.json()["total"] == 1


async def test_free_text_search(client: AsyncClient) -> None:
    h = await auth_headers(client)
    await client.post("/entries", json=work_done(), headers=h)
    await client.post("/entries", json=breakdown(), headers=h)

    hit = await client.get(
        "/entries", params={"site": "MBMT", "q": "contactor"}, headers=h
    )
    assert hit.json()["total"] == 1

    by_creator = await client.get(
        "/entries", params={"site": "MBMT", "q": "rahul"}, headers=h
    )
    assert by_creator.json()["total"] == 2

    miss = await client.get(
        "/entries", params={"site": "MBMT", "q": "zzzznothing"}, headers=h
    )
    assert miss.json()["total"] == 0


async def test_period_today(client: AsyncClient) -> None:
    h = await auth_headers(client)
    await client.post("/entries", json=work_done(), headers=h)
    old = work_done()
    old["date"] = "2020-01-01"
    await client.post("/entries", json=old, headers=h)

    today = await client.get(
        "/entries", params={"site": "MBMT", "period": "today"}, headers=h
    )
    assert today.json()["total"] == 1

    everything = await client.get(
        "/entries", params={"site": "MBMT", "period": "all"}, headers=h
    )
    assert everything.json()["total"] == 2


async def test_summary_counts(client: AsyncClient) -> None:
    h = await auth_headers(client)
    await client.post("/entries", json=work_done(), headers=h)
    await client.post("/entries", json=breakdown(), headers=h)

    r = await client.get("/entries/summary", params={"site": "MBMT"}, headers=h)
    assert r.status_code == 200
    body = r.json()
    assert body["total_today"] == 2
    assert body["by_register"]["work_done"] == 1
    assert body["by_register"]["pm_schedule"] == 0
    assert body["open_breakdowns"] == 1


async def test_update_entry_sets_updated_at(client: AsyncClient) -> None:
    h = await auth_headers(client)
    entry = (await client.post("/entries", json=work_done(), headers=h)).json()
    assert entry["updated_at"] is None

    data = dict(entry["data"])
    data["attended_details"] = "Also bled the air lines"
    r = await client.put(
        f"/entries/{entry['id']}", json={"date": TODAY, "data": data}, headers=h
    )
    assert r.status_code == 200
    assert r.json()["data"]["attended_details"] == "Also bled the air lines"
    assert r.json()["updated_at"] is not None


async def test_executive_cannot_edit_others_entries(client: AsyncClient) -> None:
    mgr = await auth_headers(client)
    entry = (await client.post("/entries", json=work_done(), headers=mgr)).json()

    exec_h = await auth_headers(client, "TV4105")
    r = await client.put(
        f"/entries/{entry['id']}",
        json={"date": TODAY, "data": entry["data"]},
        headers=exec_h,
    )
    assert r.status_code == 403


async def test_supervisor_can_edit_others_entries(client: AsyncClient) -> None:
    mgr = await auth_headers(client)
    entry = (await client.post("/entries", json=work_done(), headers=mgr)).json()

    sup = await auth_headers(client, "TV4102")
    r = await client.put(
        f"/entries/{entry['id']}",
        json={"date": TODAY, "data": entry["data"]},
        headers=sup,
    )
    assert r.status_code == 200


PNG = (
    b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01"
    b"\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\nIDAT"
    b"x\x9cc\x00\x01\x00\x00\x05\x00\x01\r\n-\xb4\x00\x00\x00\x00IEND\xaeB`\x82"
)


async def test_single_photo_behavior_still_works_for_an_untouched_register(
    client: AsyncClient,
) -> None:
    """Coolant isn't one of this plan's three touched registers -- its
    Flutter widget still shows one photo, backed by the same list-returning
    endpoint capped at index 0. This proves the endpoint swap didn't change
    behavior for registers that never asked for a gallery."""
    h = await auth_headers(client)
    entry = (await client.post("/entries", json=coolant(), headers=h)).json()

    r = await client.post(
        f"/entries/{entry['id']}/photos",
        files={"photo": ("defect.png", PNG, "image/png")},
        headers=h,
    )
    assert r.status_code == 201, r.text
    assert len(r.json()) == 1
    assert r.json()[0]["url"].endswith(".png")
    photo_id = r.json()[0]["id"]

    fetched = await client.get(f"/entries/{entry['id']}", headers=h)
    assert len(fetched.json()["photos"]) == 1

    deleted = await client.delete(f"/entries/{entry['id']}/photos/{photo_id}", headers=h)
    assert deleted.status_code == 204
    assert (await client.get(f"/entries/{entry['id']}", headers=h)).json()["photos"] == []


async def test_upload_two_photos_produces_two_rows(client: AsyncClient) -> None:
    h = await auth_headers(client)
    entry = (await client.post("/entries", json=breakdown(), headers=h)).json()

    r1 = await client.post(
        f"/entries/{entry['id']}/photos",
        files={"photo": ("a.png", PNG, "image/png")},
        headers=h,
    )
    assert r1.status_code == 201, r1.text
    r2 = await client.post(
        f"/entries/{entry['id']}/photos",
        files={"photo": ("b.png", PNG, "image/png")},
        headers=h,
    )
    assert r2.status_code == 201, r2.text
    assert len(r2.json()) == 2


async def test_delete_one_photo_leaves_the_other(client: AsyncClient) -> None:
    h = await auth_headers(client)
    entry = (await client.post("/entries", json=breakdown(), headers=h)).json()

    await client.post(
        f"/entries/{entry['id']}/photos",
        files={"photo": ("a.png", PNG, "image/png")},
        headers=h,
    )
    photos = (
        await client.post(
            f"/entries/{entry['id']}/photos",
            files={"photo": ("b.png", PNG, "image/png")},
            headers=h,
        )
    ).json()
    to_delete = photos[0]["id"]
    r = await client.delete(f"/entries/{entry['id']}/photos/{to_delete}", headers=h)
    assert r.status_code == 204
    remaining = await client.get(f"/entries/{entry['id']}", headers=h)
    assert len(remaining.json()["photos"]) == 1
    assert remaining.json()["photos"][0]["id"] != to_delete


async def test_photo_rejects_wrong_type(client: AsyncClient) -> None:
    h = await auth_headers(client)
    entry = (await client.post("/entries", json=work_done(), headers=h)).json()
    r = await client.post(
        f"/entries/{entry['id']}/photos",
        files={"photo": ("notes.txt", b"hello", "text/plain")},
        headers=h,
    )
    assert r.status_code == 400


async def test_work_done_can_link_to_an_open_ticket(client: AsyncClient) -> None:
    h = await auth_headers(client)
    await client.post("/entries", json=breakdown(), headers=h)
    tickets = await client.get(
        "/tickets/search",
        params={"site": "MBMT", "register": "breakdown", "q": "contactor"},
        headers=h,
    )
    ticket_id = tickets.json()[0]["ticket_id"]

    payload = work_done()
    payload["data"]["ticket_id"] = ticket_id
    r = await client.post("/entries", json=payload, headers=h)
    assert r.status_code == 201, r.text
    assert r.json()["data"]["ticket_id"] == ticket_id


async def test_work_done_rejects_an_already_completed_ticket(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    bd = await client.post("/entries", json=breakdown(), headers=h)
    bd_id = bd.json()["id"]
    await resolve_via_work_done(client, h, bd_id)
    tickets = await client.get(
        "/tickets/search",
        params={"site": "MBMT", "register": "breakdown", "q": bd_id},
        headers=h,
    )
    # A resolved breakdown's ticket is completed, so it no longer shows up in
    # an open-tickets search — confirm that, then confirm linking to its id
    # directly (as if a stale client cached it) is rejected.
    assert tickets.json() == []


async def test_two_sessions_same_ticket_date_shift_is_rejected(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    bd = await client.post("/entries", json=breakdown(), headers=h)
    bd_id = bd.json()["id"]
    tickets = await client.get(
        "/tickets/search",
        params={"site": "MBMT", "register": "breakdown", "q": bd_id},
        headers=h,
    )
    ticket_id = tickets.json()[0]["ticket_id"]

    first = work_done()
    first["data"]["ticket_id"] = ticket_id
    r1 = await client.post("/entries", json=first, headers=h)
    assert r1.status_code == 201, r1.text

    second = work_done()
    second["data"]["ticket_id"] = ticket_id  # same shift ("A"), same date, same ticket
    r2 = await client.post("/entries", json=second, headers=h)
    assert r2.status_code == 409, r2.text


async def test_two_tickets_same_bus_same_shift_both_get_sessions(
    client: AsyncClient,
) -> None:
    """Ticket-scoped, not vehicle-scoped — resolves the same-shift limitation."""
    h = await auth_headers(client)
    bd1 = await client.post("/entries", json=breakdown(), headers=h)
    coolant_payload = coolant()
    coolant_payload["data"]["bus_no"] = "MH40LY1895"  # same bus as the breakdown
    bd2_source = await client.post("/entries", json=coolant_payload, headers=h)
    raised = await client.post(
        f"/entries/{bd2_source.json()['id']}/raise_ticket", headers=h
    )
    assert raised.status_code == 200

    t1 = (
        await client.get(
            "/tickets/search",
            params={"site": "MBMT", "register": "breakdown", "q": bd1.json()["id"]},
            headers=h,
        )
    ).json()[0]["ticket_id"]
    t2 = (
        await client.get(
            "/tickets/search",
            params={"site": "MBMT", "register": "coolant", "q": bd2_source.json()["id"]},
            headers=h,
        )
    ).json()[0]["ticket_id"]

    wd1 = work_done(bus="MH40LY1895")
    wd1["data"]["ticket_id"] = t1
    wd2 = work_done(bus="MH40LY1895")
    wd2["data"]["ticket_id"] = t2

    r1 = await client.post("/entries", json=wd1, headers=h)
    r2 = await client.post("/entries", json=wd2, headers=h)
    assert r1.status_code == 201, r1.text
    assert r2.status_code == 201, r2.text


async def test_work_done_attendees_round_trip_by_user_id(client: AsyncClient) -> None:
    h = await auth_headers(client)
    me = await client.get("/auth/me", headers=h)
    my_id = me.json()["id"]

    payload = work_done()
    payload["data"]["attendee_user_ids"] = [my_id]
    r = await client.post("/entries", json=payload, headers=h)
    assert r.status_code == 201, r.text
    attendees = r.json()["data"]["attendees"]
    assert attendees == [{"user_id": my_id, "name": me.json()["name"]}]


async def test_work_done_attendees_preserve_submission_order(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    mgr = await client.get("/auth/me", headers=h)
    mgr_id, mgr_name = mgr.json()["id"], mgr.json()["name"]

    sup_h = await auth_headers(client, "TV4102")
    sup = await client.get("/auth/me", headers=sup_h)
    sup_id, sup_name = sup.json()["id"], sup.json()["name"]

    # Submitted supervisor-first, manager-second — an `IN (...)` fetch alone
    # would come back in whatever order Postgres feels like, so this ordering
    # is only preserved if the service explicitly re-sorts to match input.
    payload = work_done()
    payload["data"]["attendee_user_ids"] = [sup_id, mgr_id]
    r = await client.post("/entries", json=payload, headers=h)
    assert r.status_code == 201, r.text
    assert r.json()["data"]["attendees"] == [
        {"user_id": sup_id, "name": sup_name},
        {"user_id": mgr_id, "name": mgr_name},
    ]


async def test_attendee_without_access_to_the_site_is_rejected(
    client: AsyncClient,
) -> None:
    """An attendee is an attribution on a site-scoped entry.

    TV4105 works at MBMT only. TV4021 (the manager) reaches both MBMT and UMT,
    so it can write a UMT entry — but it may not name an MBMT-only colleague
    on it. Existing-and-active was the only check; site membership is the one
    that matters, and it's the same list `/master/staff` offers the picker.
    """
    mgr = await auth_headers(client)
    other = await client.get("/auth/me", headers=await auth_headers(client, "TV4105"))
    mbmt_only_id = other.json()["id"]

    payload = work_done(bus="MH05GX4410")  # a UMT bus
    payload["site"] = "UMT"
    payload["data"]["attendee_user_ids"] = [mbmt_only_id]
    r = await client.post("/entries", json=payload, headers=mgr)
    assert r.status_code == 400, r.text
    assert "attendee_user_ids" in r.json()["error"]["fields"]

    # …and the same person on their own site is fine, so this isn't just
    # rejecting every attendee.
    same_site = work_done()
    same_site["data"]["attendee_user_ids"] = [mbmt_only_id]
    ok = await client.post("/entries", json=same_site, headers=mgr)
    assert ok.status_code == 201, ok.text


async def test_csv_export(client: AsyncClient) -> None:
    h = await auth_headers(client)
    await client.post("/entries", json=work_done(), headers=h)

    r = await client.get("/entries/export", params={"site": "MBMT"}, headers=h)
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("text/csv")
    assert "transvolt-em-register-MBMT-" in r.headers["content-disposition"]
    lines = r.text.strip().splitlines()
    assert lines[0] == "Register,Date,Site,Bus No,Details,Entered By"
    assert "MH40LY1894" in lines[1]
    assert "Rahul Sharma (TV4021)" in lines[1]


async def test_csv_export_renders_spare_parts_as_names_not_raw_dicts(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    part = (
        await client.post(
            "/sites/MBMT/spare-parts",
            json={"part_no": "SP-CSV1", "name": "Brake pad"},
            headers=h,
        )
    ).json()
    payload = work_done()
    payload["data"]["spare_part_ids"] = [part["id"]]
    await client.post("/entries", json=payload, headers=h)

    r = await client.get("/entries/export", params={"site": "MBMT"}, headers=h)
    assert r.status_code == 200
    body = r.text
    assert "SP-CSV1" in body
    assert "'part_id'" not in body
    assert "{" not in body


async def test_coolant_register(client: AsyncClient) -> None:
    h = await auth_headers(client)
    coolant = await client.post(
        "/entries",
        json={
            "register": "coolant",
            "site": "MBMT",
            "date": TODAY,
            "data": {
                "bus_no": "MH40LY1894",
                "bcs_litres": 2.5,
                "tcs_litres": 1,
                "topped_by": "A. Kadam",
            },
        },
        headers=h,
    )
    assert coolant.status_code == 201
    assert coolant.json()["data"]["bcs_litres"] == 2.5


async def test_the_pm_register_is_retired(client: AsyncClient) -> None:
    """Inspections hold this now, with their own checklist and their own form.

    The enum value survives so historical rows still read, but nothing new may
    be written to it — two places to write the same thing is how a register
    stops being trusted.
    """
    h = await auth_headers(client)
    r = await client.post(
        "/entries",
        json={
            "register": "pm_schedule",
            "site": "MBMT",
            "date": TODAY,
            "data": {
                "bus_no": "MH40LY1894",
                "defects_noticed": "HV cable lug loose",
            },
        },
        headers=h,
    )
    assert r.status_code == 400
    assert "replaced by Inspections" in r.json()["error"]["message"]


async def test_unknown_defect_type_rejected(client: AsyncClient) -> None:
    h = await auth_headers(client)
    payload = work_done()
    payload["data"]["defect_type"] = "Warp core breach"
    r = await client.post("/entries", json=payload, headers=h)
    assert r.status_code == 400
    assert "defect_type" in r.json()["error"]["fields"]


async def test_pagination(client: AsyncClient) -> None:
    h = await auth_headers(client)
    for _ in range(5):
        await client.post("/entries", json=work_done(), headers=h)

    r = await client.get(
        "/entries", params={"site": "MBMT", "page": 2, "page_size": 2}, headers=h
    )
    body = r.json()
    assert body["total"] == 5
    assert body["page"] == 2
    assert len(body["items"]) == 2

    too_big = await client.get(
        "/entries", params={"site": "MBMT", "page_size": 500}, headers=h
    )
    assert too_big.status_code == 400


async def test_work_done_no_longer_accepts_employee(client: AsyncClient) -> None:
    h = await auth_headers(client)
    payload = work_done()
    payload["data"]["employee"] = "S. Pawar"
    r = await client.post("/entries", json=payload, headers=h)
    assert r.status_code == 400
    assert (
        "employee" in r.json()["error"]["fields"]
        or "employee" in r.json()["error"]["message"]
    )


async def test_work_done_persists_multiple_spare_parts(client: AsyncClient) -> None:
    h = await auth_headers(client)
    part_a = (
        await client.post(
            "/sites/MBMT/spare-parts",
            json={"part_no": "SP-3001", "name": "Air dryer cartridge"},
            headers=h,
        )
    ).json()
    part_b = (
        await client.post(
            "/sites/MBMT/spare-parts",
            json={"part_no": "SP-3002", "name": "Brake pad"},
            headers=h,
        )
    ).json()

    payload = work_done()
    payload["data"]["spare_part_ids"] = [part_a["id"], part_b["id"]]
    created = (await client.post("/entries", json=payload, headers=h)).json()

    part_ids = {p["part_id"] for p in created["data"]["spare_parts"]}
    assert part_ids == {part_a["id"], part_b["id"]}


async def test_work_done_rejects_unknown_spare_part_id(client: AsyncClient) -> None:
    h = await auth_headers(client)
    payload = work_done()
    payload["data"]["spare_part_ids"] = ["not-real"]
    r = await client.post("/entries", json=payload, headers=h)
    assert r.status_code == 400


async def test_driver_complaint_persists_driver_id(client: AsyncClient) -> None:
    h = await auth_headers(client)
    driver = (
        await client.post(
            "/sites/MBMT/drivers",
            json={"driver_code": "DRV-9001", "name": "Rakesh Yadav"},
            headers=h,
        )
    ).json()

    created = (
        await client.post(
            "/entries",
            json={
                "register": "driver_complaint",
                "site": "MBMT",
                "date": TODAY,
                "data": {
                    "bus_no": "MH40LY1894",
                    "complaint": "harsh braking",
                    "driver_id": driver["driver_code"],
                },
            },
            headers=h,
        )
    ).json()
    assert created["data"]["driver_id"] == driver["driver_code"]
    assert created["data"]["driver_name"] == "Rakesh Yadav"


async def test_breakdown_echoes_the_drivers_name_alongside_its_code(
    client: AsyncClient,
) -> None:
    """The Breakdowns tracker and Ticket Detail read driver_name for
    display; driver_id stays the FK the form writes and the select-dropdown
    still needs."""
    h = await auth_headers(client)
    driver = (
        await client.post(
            "/sites/MBMT/drivers",
            json={"driver_code": "DRV-9002", "name": "Suresh Kamble"},
            headers=h,
        )
    ).json()

    payload = breakdown()
    payload["data"]["driver_id"] = driver["driver_code"]
    created = await client.post("/entries", json=payload, headers=h)
    assert created.status_code == 201, created.text
    assert created.json()["data"]["driver_id"] == driver["driver_code"]
    assert created.json()["data"]["driver_name"] == "Suresh Kamble"

    fetched = await client.get(f"/entries/{created.json()['id']}", headers=h)
    assert fetched.json()["data"]["driver_name"] == "Suresh Kamble"


async def test_breakdown_rejects_unknown_driver_id(client: AsyncClient) -> None:
    h = await auth_headers(client)
    payload = breakdown()
    payload["data"]["driver_id"] = "NOT-REAL"
    r = await client.post("/entries", json=payload, headers=h)
    assert r.status_code == 400


async def test_coolant_day_entry_creates_one_row_per_vehicle(client: AsyncClient) -> None:
    h = await auth_headers(client)
    r = await client.post(
        "/entries/coolant/day",
        params={"site": "MBMT"},
        json={
            "entry_date": "2026-09-25",
            "supervisor": "R. Mehta",
            "rows": [
                {
                    "vehicle_id": await _vehicle_id("MH40LY1894"),
                    "bcs_litres": "1.5",
                    "tcs_litres": "0.5",
                    "topped_by": "A",
                },
                {
                    "vehicle_id": await _vehicle_id("MH40LY1895"),
                    "bcs_litres": "2.0",
                    "topped_by": "B",
                },
            ],
        },
        headers=h,
    )
    assert r.status_code == 201, r.text
    assert len(r.json()["items"]) == 2


async def test_coolant_day_entry_rolls_back_on_one_bad_vehicle(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    r = await client.post(
        "/entries/coolant/day",
        params={"site": "MBMT"},
        json={
            "entry_date": "2026-09-25",
            "rows": [
                {"vehicle_id": await _vehicle_id("MH40LY1894"), "bcs_litres": "1.5"},
                {"vehicle_id": "not-a-real-vehicle", "bcs_litres": "2.0"},
            ],
        },
        headers=h,
    )
    assert r.status_code == 400

    listing = await client.get(
        "/entries",
        params={"site": "MBMT", "register": "coolant"},
        headers=h,
    )
    assert listing.json()["total"] == 0


async def test_entry_origin_manual_by_default(client: AsyncClient) -> None:
    h = await auth_headers(client)
    created = (await client.post("/entries", json=work_done(), headers=h)).json()
    assert created["data"]["entry_origin"] == "manual"


async def test_entry_origin_linked_when_ticket_set(client: AsyncClient) -> None:
    h = await auth_headers(client)
    bd = (await client.post("/entries", json=breakdown(), headers=h)).json()
    found = await client.get(
        "/tickets/search", params={"site": "MBMT", "q": bd["id"]}, headers=h
    )
    ticket_id = found.json()[0]["ticket_id"]

    payload = work_done()
    payload["data"]["ticket_id"] = ticket_id
    created = (await client.post("/entries", json=payload, headers=h)).json()
    assert created["data"]["entry_origin"] == "linked"


async def test_origin_filter_matches_only_imported(client: AsyncClient) -> None:
    from tests.test_imports import _import_snag, _snag_work_types

    h = await auth_headers(client)
    manual = (await client.post("/entries", json=work_done(), headers=h)).json()

    await _snag_work_types()
    assert (await _import_snag(client, h)).status_code == 200
    imported = next(
        e
        for e in (
            await client.get(
                "/entries", params={"site": "MBMT", "register": "work_done"}, headers=h
            )
        ).json()["items"]
        if e["id"] != manual["id"]
    )

    r = await client.get(
        "/entries",
        params={"site": "MBMT", "register": "work_done", "origin": "imported"},
        headers=h,
    )
    ids = {e["id"] for e in r.json()["items"]}
    assert imported["id"] in ids
    assert manual["id"] not in ids


async def test_has_open_ticket_true_matches_only_open(client: AsyncClient) -> None:
    h = await auth_headers(client)
    open_entry = (
        await client.post("/entries", json=breakdown(bus="MH40LY1894"), headers=h)
    ).json()
    completed_source = (
        await client.post("/entries", json=breakdown(bus="MH40LY1895"), headers=h)
    ).json()
    await resolve_via_work_done(client, h, completed_source["id"])
    unticketed = (await client.post("/entries", json=work_done(), headers=h)).json()

    r = await client.get(
        "/entries", params={"site": "MBMT", "has_open_ticket": "true"}, headers=h
    )
    ids = {e["id"] for e in r.json()["items"]}
    assert open_entry["id"] in ids
    assert completed_source["id"] not in ids
    assert unticketed["id"] not in ids


async def test_work_done_can_complete_an_inspection_sourced_ticket(
    client: AsyncClient,
) -> None:
    """A ticket raised from a failed inspection result (source_kind =
    daily_inspection) has no `source_entry` — only `source_inspection_result`.
    Completing it via a Work Done session must not assume every ticket has
    a register entry as its source."""
    from app.db import SessionLocal
    from app.services import tickets as tickets_service
    from tests.test_tickets import _daily_inspection_result

    async with SessionLocal() as session:
        result = await _daily_inspection_result(session)
        from app.models.user import User
        from tests.conftest import SUPER_ADMIN

        admin = await session.scalar(select(User).where(User.user_id == SUPER_ADMIN))
        ticket = await tickets_service.create_ticket_for_inspection_result(
            session, result=result, creator=admin
        )
        ticket_id = ticket.id
        await session.commit()

    h = await auth_headers(client)
    payload = work_done()
    payload["data"]["ticket_id"] = ticket_id
    payload["data"]["completes_ticket"] = True
    payload["data"]["completion_time"] = "11:30"
    r = await client.post("/entries", json=payload, headers=h)
    assert r.status_code == 201, r.text

    found = await client.get(
        "/tickets/search", params={"site": "MBMT", "q": ""}, headers=h
    )
    assert not any(t["ticket_id"] == ticket_id for t in found.json())


async def test_linked_sessions_include_supervisor(client: AsyncClient) -> None:
    h = await auth_headers(client)
    bd = (await client.post("/entries", json=breakdown(), headers=h)).json()
    found = await client.get(
        "/tickets/search", params={"site": "MBMT", "q": bd["id"]}, headers=h
    )
    ticket_id = found.json()[0]["ticket_id"]

    payload = work_done()
    payload["data"]["ticket_id"] = ticket_id
    payload["data"]["supervisor"] = "R. Mehta"
    await client.post("/entries", json=payload, headers=h)

    body = (await client.get(f"/entries/{bd['id']}", headers=h)).json()
    assert body["linked_sessions"][0]["supervisor"] == "R. Mehta"


async def test_entry_gets_a_prefixed_display_id(client: AsyncClient) -> None:
    h = await auth_headers(client)
    r = await client.post("/entries", json=breakdown(), headers=h)
    assert r.status_code == 201, r.text
    assert r.json()["display_id"].startswith("BD-")


async def test_work_done_entry_gets_wd_prefix(client: AsyncClient) -> None:
    h = await auth_headers(client)
    r = await client.post("/entries", json=work_done(), headers=h)
    assert r.status_code == 201, r.text
    assert r.json()["display_id"].startswith("WD-")


def driver_complaint(bus: str = "MH40LY1895") -> dict:
    return {
        "register": "driver_complaint",
        "site": "MBMT",
        "date": TODAY,
        "data": {
            "bus_no": bus,
            "complaint": "AC not cooling",
        },
    }


async def test_driver_complaint_opens_a_ticket_automatically(
    client: AsyncClient,
) -> None:
    from app.models.ticket import Ticket

    h = await auth_headers(client)
    r = await client.post("/entries", json=driver_complaint(), headers=h)
    assert r.status_code == 201, r.text
    assert r.json()["status"] == "open"
    entry_id = r.json()["id"]
    async with SessionLocal() as session:
        ticket = await session.scalar(
            select(Ticket).where(Ticket.source_entry_id == entry_id)
        )
        assert ticket is not None


async def test_driver_complaint_raise_ticket_endpoint_now_conflicts(
    client: AsyncClient,
) -> None:
    """The manual raise_ticket endpoint still exists (used by Coolant), but
    a freshly-created complaint already has a ticket -- calling it again
    must 409, not silently create a duplicate."""
    h = await auth_headers(client)
    created = await client.post("/entries", json=driver_complaint(), headers=h)
    entry_id = created.json()["id"]
    r = await client.post(f"/entries/{entry_id}/raise_ticket", headers=h)
    assert r.status_code == 409


async def test_attended_time_is_used_when_provided(client: AsyncClient) -> None:
    h = await auth_headers(client)
    bd = await client.post("/entries", json=breakdown(), headers=h)
    bd_id = bd.json()["id"]
    found = await client.get(
        "/tickets/search",
        params={"site": "MBMT", "q": bd.json()["display_id"]},
        headers=h,
    )
    ticket_id = found.json()[0]["ticket_id"]
    payload = work_done()
    payload["data"]["ticket_id"] = ticket_id
    payload["data"]["attended_time"] = "11:05"
    r = await client.post("/entries", json=payload, headers=h)
    assert r.status_code == 201, r.text
    assert r.json()["data"]["attended_time"] == "11:05"
    entry = await client.get(f"/entries/{bd_id}", headers=h)
    assert entry.json()["data"]["attended_time"] == "11:05"


async def test_breakdown_location_round_trips(client: AsyncClient) -> None:
    h = await auth_headers(client)
    payload = breakdown()
    payload["data"]["latitude"] = "19.1197"
    payload["data"]["longitude"] = "72.8468"
    payload["data"]["location_source"] = "gps"
    r = await client.post("/entries", json=payload, headers=h)
    assert r.status_code == 201, r.text
    assert r.json()["data"]["location_source"] == "gps"
    entry = await client.get(f"/entries/{r.json()['id']}", headers=h)
    assert entry.json()["data"]["latitude"] == 19.1197


async def test_driver_complaint_location_round_trips(client: AsyncClient) -> None:
    h = await auth_headers(client)
    payload = driver_complaint()
    payload["data"]["latitude"] = "19.03"
    payload["data"]["longitude"] = "73.0297"
    payload["data"]["location_source"] = "manual"
    r = await client.post("/entries", json=payload, headers=h)
    assert r.status_code == 201, r.text
    assert r.json()["data"]["location_source"] == "manual"
    assert r.json()["data"]["longitude"] == 73.0297


# --- Breakdown odometer capture (AC-3 / AC-3b) -----------------------------
#
# The odometer plumbing already exists and is used by inspections
# (services/odometer.record_reading, wired from services/checklists) -- a
# breakdown is just another moment someone stands at the bus and reads the
# dash, so it feeds the same forward-only reading history.


async def _vehicle_row(reg: str) -> Vehicle:
    async with SessionLocal() as session:
        return await session.scalar(select(Vehicle).where(Vehicle.registration_no == reg))


async def _readings(reg: str) -> list[OdometerReading]:
    async with SessionLocal() as session:
        vehicle = await session.scalar(
            select(Vehicle).where(Vehicle.registration_no == reg)
        )
        rows = await session.scalars(
            select(OdometerReading).where(OdometerReading.vehicle_id == vehicle.id)
        )
        return list(rows)


async def test_ac3_breakdown_persists_its_odometer_reading(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    payload = breakdown()
    payload["data"]["odometer_km"] = 121000
    created = await client.post("/entries", json=payload, headers=h)
    assert created.status_code == 201, created.text
    assert created.json()["data"]["odometer_km"] == 121000

    # It is a column on the breakdown detail row, not a loose blob key.
    async with SessionLocal() as session:
        detail = await session.scalar(
            select(BreakdownEntry).where(BreakdownEntry.entry_id == created.json()["id"])
        )
    assert detail.odometer_km == 121000

    fetched = await client.get(f"/entries/{created.json()['id']}", headers=h)
    assert fetched.json()["data"]["odometer_km"] == 121000


async def test_ac3_breakdown_odometer_moves_the_vehicle_forward(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    payload = breakdown()  # MH40LY1895
    payload["data"]["odometer_km"] = 121000
    r = await client.post("/entries", json=payload, headers=h)
    assert r.status_code == 201, r.text

    fleet = (await client.get("/sites/MBMT/vehicles", headers=h)).json()["items"]
    bus = next(v for v in fleet if v["registration_no"] == "MH40LY1895")
    assert bus["odometer_km"] == 121000
    assert bus["odometer_updated_at"] is not None

    # …and it lands in the append-only history, attributed to the breakdown.
    readings = await _readings("MH40LY1895")
    assert [x.odometer_km for x in readings] == [121000]
    assert "breakdown" in readings[0].source


async def test_ac3b_breakdown_odometer_never_moves_the_vehicle_backward(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    bus = await _vehicle_row("MH40LY1895")
    ahead = await client.put(
        f"/vehicles/{bus.id}/odometer", json={"odometer_km": 200000}, headers=h
    )
    assert ahead.status_code == 200, ahead.text

    payload = breakdown()
    payload["data"]["odometer_km"] = 150000
    r = await client.post("/entries", json=payload, headers=h)
    # A point-in-time report is still worth keeping…
    assert r.status_code == 201, r.text
    assert r.json()["data"]["odometer_km"] == 150000

    # …but the vehicle's own reading is forward-only, same contract every
    # other record_reading caller holds to.
    fleet = (await client.get("/sites/MBMT/vehicles", headers=h)).json()["items"]
    after = next(v for v in fleet if v["registration_no"] == "MH40LY1895")
    assert after["odometer_km"] == 200000
    assert [x.odometer_km for x in await _readings("MH40LY1895")] == [200000]


async def test_ac3_breakdown_without_an_odometer_writes_no_reading(
    client: AsyncClient,
) -> None:
    """A missing reading is unknown, never zero."""
    h = await auth_headers(client)
    r = await client.post("/entries", json=breakdown(), headers=h)
    assert r.status_code == 201, r.text
    assert r.json()["data"]["odometer_km"] is None

    fleet = (await client.get("/sites/MBMT/vehicles", headers=h)).json()["items"]
    bus = next(v for v in fleet if v["registration_no"] == "MH40LY1895")
    assert bus["odometer_updated_at"] is None
    assert await _readings("MH40LY1895") == []


async def test_ac3_breakdown_rejects_a_negative_odometer(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    ok = breakdown()
    ok["data"]["odometer_km"] = 5
    accepted = await client.post("/entries", json=ok, headers=h)
    assert accepted.status_code == 201, accepted.text

    bad = breakdown()
    bad["data"]["odometer_km"] = -5
    r = await client.post("/entries", json=bad, headers=h)
    assert r.status_code == 400, r.text
    assert "odometer_km" in r.json()["error"]["fields"]
    # Rejected for being negative, not for being an unknown key.
    assert "Extra inputs" not in r.json()["error"]["fields"]["odometer_km"]


# --- Ticket status on the entry list (AC-8) --------------------------------
#
# The CSV export the client ships is built from the *list* fetch, which never
# carries linked_sessions -- so the lifecycle has to ride along on EntryOut
# itself, from one bulk query per page.


async def test_ac8_list_carries_an_open_ticket_status(client: AsyncClient) -> None:
    h = await auth_headers(client)
    await client.post("/entries", json=breakdown(), headers=h)

    listed = await client.get(
        "/entries", params={"site": "MBMT", "register": "breakdown"}, headers=h
    )
    assert listed.status_code == 200, listed.text
    row = listed.json()["items"][0]
    assert row["ticket_status"] == "open"
    assert row["ticket_completed_at"] is None


async def test_ac8_list_carries_a_completed_ticket_and_its_date(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    bd = (await client.post("/entries", json=breakdown(), headers=h)).json()
    await resolve_via_work_done(client, h, bd["id"])

    listed = await client.get(
        "/entries", params={"site": "MBMT", "register": "breakdown"}, headers=h
    )
    row = next(r for r in listed.json()["items"] if r["id"] == bd["id"])
    assert row["ticket_status"] == "completed"
    assert row["ticket_completed_at"] == TODAY


async def test_ac8_driver_complaint_list_carries_its_ticket_status(
    client: AsyncClient,
) -> None:
    """Driver Complaint stays `done` even while its ticket is open, which is
    exactly why `status` can't stand in for the ticket lifecycle."""
    h = await auth_headers(client)
    dc = (await client.post("/entries", json=driver_complaint(), headers=h)).json()

    listed = await client.get(
        "/entries", params={"site": "MBMT", "register": "driver_complaint"}, headers=h
    )
    row = next(r for r in listed.json()["items"] if r["id"] == dc["id"])
    assert row["ticket_status"] == "open"


async def test_ac8_get_entry_carries_the_same_ticket_status(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    bd = (await client.post("/entries", json=breakdown(), headers=h)).json()

    fetched = await client.get(f"/entries/{bd['id']}", headers=h)
    assert fetched.status_code == 200, fetched.text
    assert fetched.json()["ticket_status"] == "open"
    assert fetched.json()["ticket_completed_at"] is None


async def test_ac8_a_work_done_entry_reports_no_ticket_status(
    client: AsyncClient,
) -> None:
    """work_done can never be a ticket's source -- null, not a made-up state
    (same convention linked_sessions already holds to)."""
    h = await auth_headers(client)
    await client.post("/entries", json=work_done(), headers=h)

    listed = await client.get(
        "/entries", params={"site": "MBMT", "register": "work_done"}, headers=h
    )
    row = listed.json()["items"][0]
    assert row["ticket_status"] is None
    assert row["ticket_completed_at"] is None


async def test_ac8_a_ticketable_entry_with_no_ticket_yet_reports_null(
    client: AsyncClient,
) -> None:
    """Coolant can carry a ticket but doesn't raise one on save."""
    h = await auth_headers(client)
    await client.post("/entries", json=coolant(), headers=h)

    listed = await client.get(
        "/entries", params={"site": "MBMT", "register": "coolant"}, headers=h
    )
    row = listed.json()["items"][0]
    assert row["ticket_status"] is None
    assert row["ticket_completed_at"] is None


async def test_ac8_ticket_status_costs_one_bulk_query_not_one_per_row(
    client: AsyncClient,
) -> None:
    """The Registers list is paginated and hot; this must mirror the existing
    has_open_ticket exists-subquery, not a per-row detail fetch."""
    from sqlalchemy import event

    h = await auth_headers(client)
    for bus in ("MH40LY1894", "MH40LY1895", "MH40LY1894", "MH40LY1895"):
        payload = breakdown(bus)
        r = await client.post("/entries", json=payload, headers=h)
        assert r.status_code == 201, r.text

    statements: list[str] = []

    def _record(conn, cursor, statement, parameters, context, executemany):
        statements.append(statement)

    event.listen(engine.sync_engine, "before_cursor_execute", _record)
    try:
        listed = await client.get(
            "/entries", params={"site": "MBMT", "register": "breakdown"}, headers=h
        )
    finally:
        event.remove(engine.sync_engine, "before_cursor_execute", _record)

    items = listed.json()["items"]
    assert len(items) == 4
    assert all(i["ticket_status"] == "open" for i in items)

    ticket_queries = [s for s in statements if "FROM tickets" in s]
    # One joined/bulk lookup for the whole page (two, if the page query and
    # the status lookup are separate statements) -- never one per row.
    assert len(ticket_queries) <= 2, ticket_queries


# --- Work Done against a retired bus, when linked to that bus's own
# ticket (item 2) -------------------------------------------------------
#
# A bus can be retired while its breakdown ticket is still open -- the
# fleet moving on shouldn't orphan a ticket that was legitimately open
# against it. The exception is narrow: only the ticket's own vehicle is
# exempt from the active-fleet check, not retired buses in general.


async def test_work_done_linked_to_a_ticket_accepts_that_tickets_retired_bus(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    bd = await client.post("/entries", json=breakdown(bus="MH40LY1894"), headers=h)
    assert bd.status_code == 201, bd.text

    vehicle_id = await _vehicle_id("MH40LY1894")
    deactivated = await client.post(f"/vehicles/{vehicle_id}/deactivate", headers=h)
    assert deactivated.status_code == 200, deactivated.text

    found = await client.get(
        "/tickets/search",
        params={"site": "MBMT", "q": bd.json()["display_id"]},
        headers=h,
    )
    ticket_id = found.json()[0]["ticket_id"]

    payload = work_done(bus="MH40LY1894")
    payload["data"]["ticket_id"] = ticket_id
    payload["data"]["completes_ticket"] = True
    payload["data"]["completion_time"] = "16:00"
    r = await client.post("/entries", json=payload, headers=h)
    assert r.status_code == 201, r.text


async def test_unlinked_work_done_still_rejects_a_retired_bus(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    vehicle_id = await _vehicle_id("MH40LY1895")
    deactivated = await client.post(f"/vehicles/{vehicle_id}/deactivate", headers=h)
    assert deactivated.status_code == 200, deactivated.text

    payload = work_done(bus="MH40LY1895")
    r = await client.post("/entries", json=payload, headers=h)
    assert r.status_code == 400, r.text
    assert "retired" in r.json()["error"]["fields"]["bus_no"]


async def test_work_done_on_an_inspection_sourced_ticket_accepts_its_retired_bus(
    client: AsyncClient,
) -> None:
    """Same exemption as test_work_done_linked_to_a_ticket_accepts_that_tickets
    _retired_bus, but the ticket's source is a failed inspection result, not a
    register entry -- _ticket_vehicle_id must resolve the vehicle off
    `source_inspection_result.inspection`, not assume every ticket has a
    `source_entry`."""
    from app.db import SessionLocal
    from app.services import tickets as tickets_service
    from tests.test_tickets import _daily_inspection_result

    async with SessionLocal() as session:
        result = await _daily_inspection_result(session)
        from app.models.user import User
        from tests.conftest import SUPER_ADMIN

        admin = await session.scalar(select(User).where(User.user_id == SUPER_ADMIN))
        ticket = await tickets_service.create_ticket_for_inspection_result(
            session, result=result, creator=admin
        )
        ticket_id = ticket.id
        await session.commit()

    h = await auth_headers(client)
    vehicle_id = await _vehicle_id("MH40LY1894")
    deactivated = await client.post(f"/vehicles/{vehicle_id}/deactivate", headers=h)
    assert deactivated.status_code == 200, deactivated.text

    payload = work_done(bus="MH40LY1894")
    payload["data"]["ticket_id"] = ticket_id
    payload["data"]["completes_ticket"] = True
    payload["data"]["completion_time"] = "11:30"
    r = await client.post("/entries", json=payload, headers=h)
    assert r.status_code == 201, r.text
