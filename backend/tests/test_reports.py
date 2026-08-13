from __future__ import annotations

from datetime import date, timedelta

from httpx import AsyncClient
from sqlalchemy import select

from app.db import SessionLocal
from app.models.enums import DefectCategory
from app.models.master import DefectType, Vehicle
from app.services import dmr
from tests.conftest import auth_headers

TODAY = date(2026, 8, 13)


def line(body: dict, number: int) -> dict:
    return next(x for x in body["lines"] if x["number"] == number)


def value(body: dict, number: int):
    """A line's figure, asserting it arrived as a JSON number.

    Pydantic renders Decimal as a *string* by default and the client casts
    these to `num`, so a quoted "57" is a crash rather than a cosmetic
    difference. `float(raw)` would hide it.
    """
    raw = line(body, number)["value"]
    assert raw is None or isinstance(raw, int | float), (
        f"line {number} came back as {type(raw).__name__}: {raw!r}"
    )
    return None if raw is None else float(raw)


async def _vehicle_id(reg: str = "MH40LY1894") -> str:
    async with SessionLocal() as session:
        vehicle = await session.scalar(
            select(Vehicle).where(Vehicle.registration_no == reg)
        )
        return vehicle.id


async def _categorise(name: str, category: DefectCategory) -> None:
    async with SessionLocal() as session:
        row = await session.scalar(
            select(DefectType).where(DefectType.name == name)
        )
        row.category = category
        await session.commit()


async def _breakdown(
    client: AsyncClient, headers: dict, *, defect_type: str | None = None, loss: float = 0
):
    data = {"bus_no": "MH40LY1894", "complaint": "No traction"}
    if defect_type:
        data["defect_type"] = defect_type
    if loss:
        data["loss_km"] = loss
    return await client.post(
        "/entries",
        json={
            "register": "breakdown",
            "site": "MBMT",
            "date": TODAY.isoformat(),
            "data": data,
        },
        headers=headers,
    )


# --- the Daily Maintenance Report -------------------------------------------


async def test_the_report_has_every_line_in_order(client: AsyncClient) -> None:
    h = await auth_headers(client)
    r = await client.get(
        "/sites/MBMT/reports/dmr", params={"date": TODAY.isoformat()}, headers=h
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert [x["number"] for x in body["lines"]] == list(range(1, 32))
    assert line(body, 1)["label"] == "Total fleet"
    assert line(body, 1)["derived"] is True
    # Nothing observes these, so they are asked for rather than invented.
    assert line(body, 2)["derived"] is False
    assert value(body, 2) is None


async def test_total_fleet_counts_active_vehicles(client: AsyncClient) -> None:
    h = await auth_headers(client)
    body = (
        await client.get(
            "/sites/MBMT/reports/dmr", params={"date": TODAY.isoformat()}, headers=h
        )
    ).json()
    # The fixture site has three vehicles, one of them retired.
    assert value(body, 1) == 2


async def test_breakdowns_split_by_their_defect_category(
    client: AsyncClient,
) -> None:
    """Lines 14-18 are the whole reason defect types carry a category."""
    h = await auth_headers(client)
    await _categorise("Brakes & air system", DefectCategory.mechanical)
    await _categorise("Electrical / HV", DefectCategory.electrical)

    assert (
        await _breakdown(client, h, defect_type="Brakes & air system", loss=12.5)
    ).status_code == 201
    assert (
        await _breakdown(client, h, defect_type="Electrical / HV", loss=8)
    ).status_code == 201
    assert (await _breakdown(client, h, defect_type="Electrical / HV")).status_code == 201

    body = (
        await client.get(
            "/sites/MBMT/reports/dmr", params={"date": TODAY.isoformat()}, headers=h
        )
    ).json()
    assert value(body, 13) == 3
    assert value(body, 14) == 1
    assert value(body, 15) == 2
    assert value(body, 16) == 0
    assert value(body, 19) == 20.5


async def test_an_uncategorised_breakdown_still_counts_to_the_total(
    client: AsyncClient,
) -> None:
    """Better an unsplit total than a wrong split."""
    h = await auth_headers(client)
    assert (await _breakdown(client, h)).status_code == 201

    body = (
        await client.get(
            "/sites/MBMT/reports/dmr", params={"date": TODAY.isoformat()}, headers=h
        )
    ).json()
    assert value(body, 13) == 1
    assert sum(value(body, n) or 0 for n in (14, 15, 16, 17, 18)) == 0


async def test_the_entered_lines_are_stored_and_read_back(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    r = await client.put(
        "/sites/MBMT/reports/dmr",
        params={"date": TODAY.isoformat()},
        json={"on_road": 48, "spare": 6, "tyres_scrapped": 2, "notes": "Two spare"},
        headers=h,
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert value(body, 2) == 48
    assert value(body, 3) == 6
    assert value(body, 29) == 2
    assert body["notes"] == "Two spare"

    again = (
        await client.get(
            "/sites/MBMT/reports/dmr", params={"date": TODAY.isoformat()}, headers=h
        )
    ).json()
    assert value(again, 2) == 48


async def test_a_snapshot_freezes_the_derived_lines(client: AsyncClient) -> None:
    """What was reported stays what was reported."""
    h = await auth_headers(client)
    await _breakdown(client, h)

    frozen = await client.post(
        "/sites/MBMT/reports/dmr/snapshot",
        params={"date": TODAY.isoformat()},
        headers=h,
    )
    assert frozen.status_code == 200, frozen.text
    assert frozen.json()["is_snapshot"] is True
    assert value(frozen.json(), 13) == 1

    # A breakdown recorded afterwards does not rewrite the reported day.
    await _breakdown(client, h)
    after = (
        await client.get(
            "/sites/MBMT/reports/dmr", params={"date": TODAY.isoformat()}, headers=h
        )
    ).json()
    assert after["is_snapshot"] is True
    assert value(after, 13) == 1


async def test_an_open_day_still_recomputes(client: AsyncClient) -> None:
    h = await auth_headers(client)
    first = (
        await client.get(
            "/sites/MBMT/reports/dmr", params={"date": TODAY.isoformat()}, headers=h
        )
    ).json()
    assert value(first, 13) == 0

    await _breakdown(client, h)
    second = (
        await client.get(
            "/sites/MBMT/reports/dmr", params={"date": TODAY.isoformat()}, headers=h
        )
    ).json()
    assert second["is_snapshot"] is False
    assert value(second, 13) == 1


async def test_the_month_grid_exports_in_the_depots_layout(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    await _breakdown(client, h)

    grid = await client.get(
        "/sites/MBMT/reports/dmr/month", params={"month": "2026-08"}, headers=h
    )
    assert grid.status_code == 200, grid.text
    body = grid.json()
    assert len(body["dates"]) == len(body["values"]["breakdowns"])
    # Numbers, not quoted decimals.
    assert all(
        v is None or isinstance(v, int | float)
        for v in body["values"]["loss_km"]
    )

    export = await client.get(
        "/sites/MBMT/reports/dmr/export", params={"month": "2026-08"}, headers=h
    )
    assert export.status_code == 200
    text = export.text
    assert "Daily Maintenance Report (DMR)" in text
    assert "Location :- MBMT" in text
    assert "Total fleet" in text
    assert "Nos of tyres scrapped" in text


# --- off-road cases ---------------------------------------------------------


async def test_a_bus_off_the_road_shows_on_the_list_and_in_the_report(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    vehicle_id = await _vehicle_id()

    r = await client.post(
        "/sites/MBMT/reports/off-road",
        json={
            "vehicle_id": vehicle_id,
            "issue": "Steering hard in running",
            "category": "mechanical",
            "off_road_since": (TODAY - timedelta(days=5)).isoformat(),
            "expected_days": 3,
            "spare_parts_required": "Steering gear box",
            "awaiting_vendor": True,
        },
        headers=h,
    )
    assert r.status_code == 201, r.text
    case = r.json()
    assert case["registration_no"] == "MH40LY1894"
    # A commitment in days implies a date; they are the same promise.
    assert case["expected_ready_on"] == (TODAY - timedelta(days=2)).isoformat()

    listed = await client.get(
        "/sites/MBMT/reports/off-road",
        params={"date": TODAY.isoformat()},
        headers=h,
    )
    assert listed.status_code == 200
    item = listed.json()["items"][0]
    assert item["days_down"] == 5
    assert item["is_held"] is True

    body = (
        await client.get(
            "/sites/MBMT/reports/dmr", params={"date": TODAY.isoformat()}, headers=h
        )
    ).json()
    assert value(body, 4) == 1
    assert value(body, 5) == 1
    assert value(body, 12) == 1


async def test_one_open_case_per_bus(client: AsyncClient) -> None:
    """A bus with two faults is still one bus off the road."""
    h = await auth_headers(client)
    vehicle_id = await _vehicle_id()
    body = {
        "vehicle_id": vehicle_id,
        "issue": "Steering hard",
        "off_road_since": TODAY.isoformat(),
    }
    assert (
        await client.post("/sites/MBMT/reports/off-road", json=body, headers=h)
    ).status_code == 201
    second = await client.post(
        "/sites/MBMT/reports/off-road",
        json={**body, "issue": "Brake issue as well"},
        headers=h,
    )
    assert second.status_code == 201

    listed = await client.get(
        "/sites/MBMT/reports/off-road",
        params={"date": TODAY.isoformat()},
        headers=h,
    )
    assert len(listed.json()["items"]) == 1
    assert listed.json()["items"][0]["issue"] == "Brake issue as well"


async def test_a_returned_bus_leaves_the_list(client: AsyncClient) -> None:
    h = await auth_headers(client)
    vehicle_id = await _vehicle_id()
    created = await client.post(
        "/sites/MBMT/reports/off-road",
        json={
            "vehicle_id": vehicle_id,
            "issue": "Brake issue",
            "off_road_since": (TODAY - timedelta(days=2)).isoformat(),
        },
        headers=h,
    )
    case_id = created.json()["id"]

    closed = await client.post(
        f"/off-road/{case_id}/close",
        json={"returned_on": TODAY.isoformat()},
        headers=h,
    )
    assert closed.status_code == 200, closed.text

    listed = await client.get(
        "/sites/MBMT/reports/off-road",
        params={"date": TODAY.isoformat()},
        headers=h,
    )
    assert listed.json()["items"] == []

    # It was still off the road the day before, and the report says so.
    yesterday = (TODAY - timedelta(days=1)).isoformat()
    earlier = await client.get(
        "/sites/MBMT/reports/off-road", params={"date": yesterday}, headers=h
    )
    assert len(earlier.json()["items"]) == 1


async def test_a_bus_cannot_return_before_it_went_off_the_road(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    created = await client.post(
        "/sites/MBMT/reports/off-road",
        json={
            "vehicle_id": await _vehicle_id(),
            "issue": "Brake issue",
            "off_road_since": TODAY.isoformat(),
        },
        headers=h,
    )
    r = await client.post(
        f"/off-road/{created.json()['id']}/close",
        json={"returned_on": (TODAY - timedelta(days=1)).isoformat()},
        headers=h,
    )
    assert r.status_code == 400


# --- breakdown investigation ------------------------------------------------


async def test_an_investigation_is_prefilled_from_what_is_already_known(
    client: AsyncClient,
) -> None:
    """The three columns an investigator would otherwise look up by hand."""
    h = await auth_headers(client)

    complaint = await client.post(
        "/entries",
        json={
            "register": "driver_complaint",
            "site": "MBMT",
            "date": (TODAY - timedelta(days=2)).isoformat(),
            "data": {"bus_no": "MH40LY1894", "complaint": "Steering pulling left"},
        },
        headers=h,
    )
    assert complaint.status_code == 201, complaint.text

    breakdown = await _breakdown(client, h)
    entry_id = breakdown.json()["id"]

    r = await client.get(f"/breakdowns/{entry_id}/investigation", headers=h)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["registration_no"] == "MH40LY1894"
    assert body["breakdown_reason"] == "No traction"
    assert "Steering pulling left" in (body["related_complaints"] or "")
    # Nothing found yet, so it is not a complete investigation.
    assert body["is_complete"] is False


async def test_an_investigation_is_saved_and_counted(client: AsyncClient) -> None:
    h = await auth_headers(client)
    entry_id = (await _breakdown(client, h)).json()["id"]

    outstanding = await client.get(
        "/sites/MBMT/reports/investigations",
        params={"date": TODAY.isoformat()},
        headers=h,
    )
    assert outstanding.json()["outstanding"] == 1

    saved = await client.put(
        f"/breakdowns/{entry_id}/investigation",
        json={
            "findings": "Contactor welded shut",
            "investigation_action": "Contactor replaced; batch checked",
        },
        headers=h,
    )
    assert saved.status_code == 200, saved.text
    assert saved.json()["is_complete"] is True

    after = await client.get(
        "/sites/MBMT/reports/investigations",
        params={"date": TODAY.isoformat()},
        headers=h,
    )
    assert after.json()["outstanding"] == 0
    assert after.json()["items"][0]["findings"] == "Contactor welded shut"


async def test_only_a_breakdown_can_be_investigated(client: AsyncClient) -> None:
    h = await auth_headers(client)
    entry = await client.post(
        "/entries",
        json={
            "register": "work_done",
            "site": "MBMT",
            "date": TODAY.isoformat(),
            "data": {"bus_no": "MH40LY1894", "reported_defects": "AC fault"},
        },
        headers=h,
    )
    r = await client.get(
        f"/breakdowns/{entry.json()['id']}/investigation", headers=h
    )
    assert r.status_code == 400
    assert "Only a breakdown" in r.json()["error"]["message"]


async def test_reports_are_site_scoped(client: AsyncClient) -> None:
    h = await auth_headers(client)  # TV4021 holds MBMT and UMT, not TDC
    for path in (
        "/sites/TDC/reports/dmr",
        "/sites/TDC/reports/off-road",
        "/sites/TDC/reports/investigations",
    ):
        assert (await client.get(path, headers=h)).status_code == 403


async def test_the_parameter_list_is_the_one_spec(client: AsyncClient) -> None:
    """The API, the export and the UI all read the same list."""
    assert len(dmr.PARAMETERS) == 31
    assert len(dmr.DERIVED_KEYS) + len(dmr.ENTERED_KEYS) == 31
    assert len({p.key for p in dmr.PARAMETERS}) == 31
