from __future__ import annotations

from datetime import date

from httpx import AsyncClient

from tests.conftest import auth_headers

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
            "spare_parts_used": "Air dryer cartridge x1",
            "employee": "S. Pawar",
        },
    }


def breakdown() -> dict:
    return {
        "register": "breakdown",
        "site": "MBMT",
        "date": TODAY,
        "data": {
            "bus_no": "MH40LY1895",
            "driver_id": "DRV221",
            "location": "Kashimira signal",
            "complaint": "HV contactor tripped, bus immobile",
            "breakdown_time": "14:20",
            "mechanic_reported_time": "14:45",
            "loss_km": 18.5,
        },
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
    assert entry["data"]["breakdown_time"] == "14:20"
    assert entry["data"]["loss_km"] == 18.5

    resolved = await client.post(f"/entries/{entry['id']}/resolve", headers=h)
    assert resolved.status_code == 200
    assert resolved.json()["status"] == "resolved"

    again = await client.post(f"/entries/{entry['id']}/resolve", headers=h)
    assert again.status_code == 409
    assert again.json()["error"]["code"] == "CONFLICT"


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


async def test_coolant_and_pm_registers(client: AsyncClient) -> None:
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

    pm = await client.post(
        "/entries",
        json={
            "register": "pm_schedule",
            "site": "MBMT",
            "date": TODAY,
            "data": {
                "bus_no": "MH40LY1894",
                "defect_type": "Electrical / HV",
                "defects_noticed": "HV cable lug loose",
                "action_taken": "Retorqued to spec",
                "employees": "S. Pawar, A. Kadam",
            },
        },
        headers=h,
    )
    assert pm.status_code == 201
    assert pm.json()["data"]["defect_type"] == "Electrical / HV"


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
