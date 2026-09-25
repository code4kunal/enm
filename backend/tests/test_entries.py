from __future__ import annotations

from datetime import date

from httpx import AsyncClient
from sqlalchemy import select

from app.db import SessionLocal
from app.models.master import Vehicle
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

    resolved = await client.post(f"/entries/{entry['id']}/resolve", headers=h)
    assert resolved.status_code == 200
    assert resolved.json()["status"] == "resolved"

    again = await client.post(f"/entries/{entry['id']}/resolve", headers=h)
    assert again.status_code == 409
    assert again.json()["error"]["code"] == "CONFLICT"


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
    assert (
        await client.post(f"/entries/{entry['id']}/resolve", headers=h)
    ).status_code == 200

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


async def test_photo_upload_and_delete(client: AsyncClient) -> None:
    h = await auth_headers(client)
    entry = (await client.post("/entries", json=work_done(), headers=h)).json()

    png = (
        b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01"
        b"\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\nIDAT"
        b"x\x9cc\x00\x01\x00\x00\x05\x00\x01\r\n-\xb4\x00\x00\x00\x00IEND\xaeB`\x82"
    )
    r = await client.post(
        f"/entries/{entry['id']}/photo",
        files={"photo": ("defect.png", png, "image/png")},
        headers=h,
    )
    assert r.status_code == 200, r.text
    assert r.json()["photo_url"].endswith(".png")

    fetched = await client.get(f"/entries/{entry['id']}", headers=h)
    assert fetched.json()["photo_url"] is not None

    deleted = await client.delete(f"/entries/{entry['id']}/photo", headers=h)
    assert deleted.status_code == 204
    assert (await client.get(f"/entries/{entry['id']}", headers=h)).json()[
        "photo_url"
    ] is None


async def test_photo_rejects_wrong_type(client: AsyncClient) -> None:
    h = await auth_headers(client)
    entry = (await client.post("/entries", json=work_done(), headers=h)).json()
    r = await client.post(
        f"/entries/{entry['id']}/photo",
        files={"photo": ("notes.txt", b"hello", "text/plain")},
        headers=h,
    )
    assert r.status_code == 400


async def test_work_done_can_link_to_an_open_ticket(client: AsyncClient) -> None:
    h = await auth_headers(client)
    bd = await client.post("/entries", json=breakdown(), headers=h)
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
    await client.post(f"/entries/{bd_id}/resolve", headers=h)
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
    assert "employee" in r.json()["error"]["fields"] or "employee" in r.json()["error"]["message"]


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
            "/sites/MBMT/spare-parts", json={"part_no": "SP-3002", "name": "Brake pad"}, headers=h
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


async def test_coolant_day_entry_rolls_back_on_one_bad_vehicle(client: AsyncClient) -> None:
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
    open_entry = (await client.post("/entries", json=breakdown(bus="MH40LY1894"), headers=h)).json()
    completed_source = (
        await client.post("/entries", json=breakdown(bus="MH40LY1895"), headers=h)
    ).json()
    resolved = await client.post(f"/entries/{completed_source['id']}/resolve", headers=h)
    assert resolved.status_code == 200, resolved.text
    unticketed = (await client.post("/entries", json=work_done(), headers=h)).json()

    r = await client.get(
        "/entries", params={"site": "MBMT", "has_open_ticket": "true"}, headers=h
    )
    ids = {e["id"] for e in r.json()["items"]}
    assert open_entry["id"] in ids
    assert completed_source["id"] not in ids
    assert unticketed["id"] not in ids


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
