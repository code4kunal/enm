from __future__ import annotations

from datetime import date

from httpx import AsyncClient
from sqlalchemy import select

from app.db import SessionLocal
from app.models.enums import Register, SlotStatus
from app.models.inspection import InspectionSlot
from app.models.master import Vehicle, WorkType
from tests.conftest import auth_headers

TODAY = date(2026, 8, 13)

CHECKLIST = {
    "name": "Daily inspection",
    "items": [
        {"section": "Safety", "label": "Horn working", "response_type": "ok_not_ok"},
        {"section": "Safety", "label": "Wipers working", "response_type": "ok_not_ok"},
        {
            "section": "Readings",
            "label": "Brake air pressure",
            "response_type": "reading",
            "is_required": False,
        },
    ],
}


async def _work_types() -> dict[str, int]:
    """D.I and the 10-day service, as inspection codes rather than registers."""
    async with SessionLocal() as session:
        ids: dict[str, int] = {}
        for code, name in (
            ("D.I", "Daily inspection"),
            ("10 DAYS SERVICE", "10 day inspection"),
        ):
            work_type = WorkType(code=code, name=name, is_inspection=True)
            session.add(work_type)
            await session.flush()
            ids[code] = work_type.id
        # A register code, to prove the two do not mix.
        session.add(WorkType(code="B.D", name="Breakdown", register=Register.breakdown))
        await session.commit()
        return ids


async def _vehicle(reg: str = "MH40LY1894") -> str:
    async with SessionLocal() as session:
        vehicle = await session.scalar(
            select(Vehicle).where(Vehicle.registration_no == reg)
        )
        return vehicle.id


async def _save_checklist(
    client: AsyncClient, headers: dict, work_type_id: int, body: dict = CHECKLIST
):
    return await client.put(
        f"/sites/MBMT/checklists/{work_type_id}", json=body, headers=headers
    )


async def test_each_inspection_type_gets_its_own_checklist(
    client: AsyncClient,
) -> None:
    """The whole point: a daily inspection and a ten-day service are different
    jobs, so they cannot share one form."""
    await _work_types()
    h = await auth_headers(client)

    r = await client.get("/sites/MBMT/checklists", headers=h)
    assert r.status_code == 200, r.text
    codes = [c["work_type_code"] for c in r.json()["items"]]
    assert set(codes) == {"D.I", "10 DAYS SERVICE"}
    # A register code is not an inspection and has no checklist.
    assert "B.D" not in codes


async def test_a_checklist_starts_empty_and_says_so(client: AsyncClient) -> None:
    """Nothing is invented — a site that has not written its checklist has an
    empty one, and the form can say so."""
    await _work_types()
    h = await auth_headers(client)
    r = await client.get("/sites/MBMT/checklists", headers=h)
    assert all(c["items"] == [] for c in r.json()["items"])


async def test_a_checklist_can_be_written_and_rewritten(
    client: AsyncClient,
) -> None:
    ids = await _work_types()
    h = await auth_headers(client)

    r = await _save_checklist(client, h, ids["D.I"])
    assert r.status_code == 200, r.text
    labels = [i["label"] for i in r.json()["items"]]
    assert labels == ["Horn working", "Wipers working", "Brake air pressure"]

    trimmed = await _save_checklist(
        client,
        h,
        ids["D.I"],
        {"name": "Daily inspection", "items": [CHECKLIST["items"][0]]},
    )
    assert [i["label"] for i in trimmed.json()["items"]] == ["Horn working"]


async def test_writing_a_checklist_is_manager_only(client: AsyncClient) -> None:
    ids = await _work_types()
    sup = await auth_headers(client, "TV4102")
    assert (await _save_checklist(client, sup, ids["D.I"])).status_code == 403
    # A supervisor still reads it — they are the one filling it in.
    assert (
        await client.get("/sites/MBMT/checklists", headers=sup)
    ).status_code == 200


async def test_an_inspection_records_a_result_per_line(
    client: AsyncClient,
) -> None:
    ids = await _work_types()
    h = await auth_headers(client)
    saved = await _save_checklist(client, h, ids["D.I"])
    items = saved.json()["items"]

    r = await client.post(
        "/sites/MBMT/inspections",
        json={
            "vehicle_id": await _vehicle(),
            "work_type_id": ids["D.I"],
            "inspected_on": TODAY.isoformat(),
            "entry_time": "21:40",
            "done_by": "Tushar",
            "supervisor": "Nitin",
            "odometer_km": 121000,
            "results": [
                {"item_id": items[0]["id"], "result": "ok"},
                {
                    "item_id": items[1]["id"],
                    "result": "not_ok",
                    "remark": "RHS blade worn",
                },
                {"item_id": items[2]["id"], "result": "ok", "value": "8.2 bar"},
            ],
        },
        headers=h,
    )
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["work_type_code"] == "D.I"
    assert body["done_by"] == "Tushar"
    assert body["supervisor"] == "Nitin"
    assert body["failed_count"] == 1
    assert len(body["results"]) == 3
    failed = next(x for x in body["results"] if x["result"] == "not_ok")
    assert failed["label"] == "Wipers working"
    assert failed["remark"] == "RHS blade worn"


async def test_every_required_line_must_be_answered(client: AsyncClient) -> None:
    ids = await _work_types()
    h = await auth_headers(client)
    items = (await _save_checklist(client, h, ids["D.I"])).json()["items"]

    r = await client.post(
        "/sites/MBMT/inspections",
        json={
            "vehicle_id": await _vehicle(),
            "work_type_id": ids["D.I"],
            "inspected_on": TODAY.isoformat(),
            "results": [{"item_id": items[0]["id"], "result": "ok"}],
        },
        headers=h,
    )
    assert r.status_code == 400
    assert "Wipers working" in r.json()["error"]["message"]
    # The reading line is optional, so its absence is not what failed.
    assert "Brake air pressure" not in r.json()["error"]["message"]


async def test_the_same_inspection_twice_in_a_day_is_a_conflict(
    client: AsyncClient,
) -> None:
    ids = await _work_types()
    h = await auth_headers(client)
    items = (await _save_checklist(client, h, ids["D.I"])).json()["items"]
    body = {
        "vehicle_id": await _vehicle(),
        "work_type_id": ids["D.I"],
        "inspected_on": TODAY.isoformat(),
        "results": [
            {"item_id": items[0]["id"], "result": "ok"},
            {"item_id": items[1]["id"], "result": "ok"},
        ],
    }
    assert (
        await client.post("/sites/MBMT/inspections", json=body, headers=h)
    ).status_code == 201
    again = await client.post("/sites/MBMT/inspections", json=body, headers=h)
    assert again.status_code == 409
    assert "already has a D.I" in again.json()["error"]["message"]


async def test_recording_an_inspection_discharges_its_booking(
    client: AsyncClient,
) -> None:
    ids = await _work_types()
    h = await auth_headers(client)
    items = (await _save_checklist(client, h, ids["D.I"])).json()["items"]
    vehicle_id = await _vehicle()

    async with SessionLocal() as session:
        session.add(
            InspectionSlot(
                site_code="MBMT",
                vehicle_id=vehicle_id,
                work_type_id=ids["D.I"],
                scheduled_on=TODAY,
                status=SlotStatus.scheduled,
            )
        )
        await session.commit()

    r = await client.post(
        "/sites/MBMT/inspections",
        json={
            "vehicle_id": vehicle_id,
            "work_type_id": ids["D.I"],
            "inspected_on": TODAY.isoformat(),
            "results": [
                {"item_id": items[0]["id"], "result": "ok"},
                {"item_id": items[1]["id"], "result": "ok"},
            ],
        },
        headers=h,
    )
    assert r.status_code == 201, r.text
    assert r.json()["slot_id"] is not None

    async with SessionLocal() as session:
        slot = await session.scalar(
            select(InspectionSlot).where(InspectionSlot.vehicle_id == vehicle_id)
        )
    assert slot.status is SlotStatus.done
    assert slot.completed_on == TODAY


async def test_an_inspection_reads_the_odometer_on_the_way_past(
    client: AsyncClient,
) -> None:
    ids = await _work_types()
    h = await auth_headers(client)
    items = (await _save_checklist(client, h, ids["D.I"])).json()["items"]
    vehicle_id = await _vehicle()

    await client.post(
        "/sites/MBMT/inspections",
        json={
            "vehicle_id": vehicle_id,
            "work_type_id": ids["D.I"],
            "inspected_on": TODAY.isoformat(),
            "odometer_km": 121000,
            "results": [
                {"item_id": items[0]["id"], "result": "ok"},
                {"item_id": items[1]["id"], "result": "ok"},
            ],
        },
        headers=h,
    )
    fleet = (await client.get("/sites/MBMT/vehicles", headers=h)).json()["items"]
    vehicle = next(v for v in fleet if v["id"] == vehicle_id)
    assert vehicle["odometer_km"] == 121000
    assert vehicle["odometer_updated_at"] is not None


async def test_a_register_code_cannot_be_recorded_as_an_inspection(
    client: AsyncClient,
) -> None:
    await _work_types()
    h = await auth_headers(client)
    async with SessionLocal() as session:
        breakdown = await session.scalar(
            select(WorkType).where(WorkType.code == "B.D")
        )
        breakdown_id = breakdown.id

    r = await client.post(
        "/sites/MBMT/inspections",
        json={
            "vehicle_id": await _vehicle(),
            "work_type_id": breakdown_id,
            "inspected_on": TODAY.isoformat(),
            "results": [],
        },
        headers=h,
    )
    assert r.status_code == 400
    assert "not an inspection" in r.json()["error"]["message"]


async def test_todays_inspections_feed(client: AsyncClient) -> None:
    ids = await _work_types()
    h = await auth_headers(client)
    items = (await _save_checklist(client, h, ids["D.I"])).json()["items"]

    empty = await client.get("/sites/MBMT/inspections/today", headers=h)
    assert empty.status_code == 200
    assert empty.json()["items"] == []

    # `inspections/today` filters on the server's own date, so record for it.
    from app.services.common import today_ist

    await client.post(
        "/sites/MBMT/inspections",
        json={
            "vehicle_id": await _vehicle(),
            "work_type_id": ids["D.I"],
            "inspected_on": today_ist().isoformat(),
            "results": [
                {"item_id": items[0]["id"], "result": "ok"},
                {"item_id": items[1]["id"], "result": "ok"},
            ],
        },
        headers=h,
    )
    feed = await client.get("/sites/MBMT/inspections/today", headers=h)
    assert feed.json()["total"] == 1
    assert feed.json()["items"][0]["work_type_code"] == "D.I"
