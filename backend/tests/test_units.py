from __future__ import annotations

from datetime import UTC, datetime

from httpx import AsyncClient
from sqlalchemy import select

from app.db import SessionLocal
from app.models.master import Vehicle
from app.models.report import UnitType
from tests.conftest import auth_headers

BUS = "MH40LY1894"
OTHER = "MH40LY1895"


async def _unit_types() -> dict[str, int]:
    """Two tracked components, one of them an HV pack."""
    async with SessionLocal() as session:
        ids: dict[str, int] = {}
        for order, (name, hv) in enumerate(
            [("Battery pack 1", True), ("Traction Motor", False)]
        ):
            row = UnitType(name=name, sort_order=order, is_hv_battery=hv)
            session.add(row)
            await session.flush()
            ids[name] = row.id
        await session.commit()
        return ids


async def _vehicle_id(reg: str = BUS) -> str:
    async with SessionLocal() as session:
        return (
            await session.scalar(
                select(Vehicle).where(Vehicle.registration_no == reg)
            )
        ).id


async def _set_odometer(reg: str, km: int | None) -> None:
    """`None` puts the bus back to never-synced, which is not the same as 0."""
    async with SessionLocal() as session:
        vehicle = await session.scalar(
            select(Vehicle).where(Vehicle.registration_no == reg)
        )
        vehicle.odometer_km = km or 0
        vehicle.odometer_updated_at = (
            datetime.now(UTC) if km is not None else None
        )
        await session.commit()


async def _fit(
    client: AsyncClient,
    headers: dict,
    unit_type_id: int,
    fitted_on: str,
    *,
    reg: str = BUS,
    **extra,
):
    return await client.post(
        "/sites/MBMT/units",
        json={
            "vehicle_id": await _vehicle_id(reg),
            "unit_type_id": unit_type_id,
            "fitted_on": fitted_on,
            **extra,
        },
        headers=headers,
    )


async def _remove(client: AsyncClient, headers: dict, unit_id: str, on: str, **extra):
    return await client.post(
        f"/units/{unit_id}/remove",
        json={"removed_on": on, **extra},
        headers=headers,
    )


# --- recording a unit --------------------------------------------------------


async def test_a_unit_takes_the_bus_odometer_when_none_is_given(
    client: AsyncClient,
) -> None:
    """A unit fitted today started its life at today's reading. Asking a
    mechanic to retype a number the system holds is how the two drift."""
    h = await auth_headers(client)
    types = await _unit_types()
    await _set_odometer(BUS, 121_500)

    r = await _fit(client, h, types["Traction Motor"], "2026-08-01")
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["fitted_odometer_km"] == 121_500
    assert body["is_fitted"] is True
    assert body["kms_covered"] is None
    assert body["registration_no"] == BUS
    assert body["unit_name"] == "Traction Motor"


async def test_an_explicit_odometer_wins(client: AsyncClient) -> None:
    h = await auth_headers(client)
    types = await _unit_types()
    await _set_odometer(BUS, 121_500)

    r = await _fit(
        client, h, types["Traction Motor"], "2026-08-01", fitted_odometer_km=90_000
    )
    assert r.json()["fitted_odometer_km"] == 90_000


async def test_the_same_unit_cannot_be_fitted_twice_over(
    client: AsyncClient,
) -> None:
    """Two open stays for one component on one bus would make the history card
    ambiguous about which one came off."""
    h = await auth_headers(client)
    types = await _unit_types()

    assert (await _fit(client, h, types["Traction Motor"], "2026-08-01")).status_code == 201
    second = await _fit(client, h, types["Traction Motor"], "2026-08-05")
    assert second.status_code == 400
    assert "already fitted" in second.json()["error"]["message"]


async def test_the_same_unit_can_be_refitted_once_it_has_come_off(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    types = await _unit_types()

    first = (await _fit(client, h, types["Traction Motor"], "2026-08-01")).json()
    assert (await _remove(client, h, first["id"], "2026-08-05")).status_code == 200
    assert (
        await _fit(client, h, types["Traction Motor"], "2026-08-06")
    ).status_code == 201


async def test_kms_covered_is_the_difference_between_the_two_readings(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    types = await _unit_types()

    stay = (
        await _fit(
            client,
            h,
            types["Traction Motor"],
            "2026-08-01",
            fitted_odometer_km=100_000,
        )
    ).json()
    body = (
        await _remove(
            client, h, stay["id"], "2026-08-10", removed_odometer_km=142_500
        )
    ).json()
    assert body["kms_covered"] == 42_500
    assert body["is_fitted"] is False


async def test_a_missing_reading_leaves_the_life_unknown(
    client: AsyncClient,
) -> None:
    """An unknown life is not a life of zero — a nil in that column would be
    read as a unit that failed immediately."""
    h = await auth_headers(client)
    types = await _unit_types()
    # Never synced: the column sits at 0, which is not a reading.
    await _set_odometer(BUS, None)

    stay = (
        await _fit(client, h, types["Traction Motor"], "2026-08-01")
    ).json()
    assert stay["fitted_odometer_km"] is None

    body = (await _remove(client, h, stay["id"], "2026-08-10")).json()
    assert body["removed_odometer_km"] is None
    assert body["kms_covered"] is None


async def test_a_unit_cannot_come_off_before_it_went_on(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    types = await _unit_types()
    stay = (await _fit(client, h, types["Traction Motor"], "2026-08-10")).json()

    r = await _remove(client, h, stay["id"], "2026-08-01")
    assert r.status_code == 400
    assert "before it went on" in r.json()["error"]["message"]


async def test_removing_twice_is_refused(client: AsyncClient) -> None:
    h = await auth_headers(client)
    types = await _unit_types()
    stay = (await _fit(client, h, types["Traction Motor"], "2026-08-01")).json()

    assert (await _remove(client, h, stay["id"], "2026-08-05")).status_code == 200
    again = await _remove(client, h, stay["id"], "2026-08-06")
    assert again.status_code == 400


async def test_an_executive_cannot_record_units(client: AsyncClient) -> None:
    h = await auth_headers(client, "TV4105")
    types = await _unit_types()
    assert (await _fit(client, h, types["Traction Motor"], "2026-08-01")).status_code == 403


async def test_a_supervisor_can_fit_and_remove_a_unit(client: AsyncClient) -> None:
    """Gated on em_entry:write, the same bar Daily Work Done uses — fitting a
    unit from that form must not need a permission its own save does not."""
    h = await auth_headers(client, "TV4102")
    types = await _unit_types()
    fit = await _fit(client, h, types["Traction Motor"], "2026-08-01")
    assert fit.status_code == 201, fit.text
    remove = await _remove(client, h, fit.json()["id"], "2026-08-05")
    assert remove.status_code == 200, remove.text


async def test_what_is_on_a_bus_right_now(client: AsyncClient) -> None:
    h = await auth_headers(client)
    types = await _unit_types()
    kept = (await _fit(client, h, types["Battery pack 1"], "2026-08-01")).json()
    gone = (await _fit(client, h, types["Traction Motor"], "2026-08-01")).json()
    await _remove(client, h, gone["id"], "2026-08-05")

    r = await client.get(
        "/sites/MBMT/units",
        params={"vehicle_id": await _vehicle_id()},
        headers=h,
    )
    assert r.status_code == 200, r.text
    assert [i["id"] for i in r.json()["items"]] == [kept["id"]]


async def _work_entry(
    client: AsyncClient, headers: dict, *, site: str = "MBMT", reg: str = BUS
) -> str:
    resp = await client.post(
        "/entries",
        json={
            "register": "work_done",
            "site": site,
            "date": "2026-08-01",
            "data": {"bus_no": reg, "reported_defects": "AC not cooling"},
        },
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()["id"]


async def test_a_fit_can_be_linked_to_the_entry_that_recorded_it(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    types = await _unit_types()
    entry_id = await _work_entry(client, h)

    fit = await _fit(
        client, h, types["Traction Motor"], "2026-08-01", entry_id=entry_id
    )
    assert fit.status_code == 201, fit.text
    assert fit.json()["entry_id"] == entry_id


async def test_by_entries_finds_every_unit_two_entries_fit(
    client: AsyncClient,
) -> None:
    """Two shifts, two Work Done entries, one battery each — the lookup must
    not conflate them just because both are the same bus on the same day."""
    h = await auth_headers(client)
    types = await _unit_types()
    entry_a = await _work_entry(client, h)
    entry_b = await _work_entry(client, h)

    fit_a = await _fit(
        client, h, types["Battery pack 1"], "2026-08-01", entry_id=entry_a
    )
    fit_b = await _fit(
        client, h, types["Traction Motor"], "2026-08-01", entry_id=entry_b
    )
    assert fit_a.status_code == 201 and fit_b.status_code == 201

    r = await client.get(
        "/sites/MBMT/units/by-entries",
        params={"entry_ids": f"{entry_a},{entry_b}"},
        headers=h,
    )
    assert r.status_code == 200, r.text
    ids = {i["id"] for i in r.json()["items"]}
    assert ids == {fit_a.json()["id"], fit_b.json()["id"]}

    # Asking for only one entry must not leak the other's unit.
    only_a = await client.get(
        "/sites/MBMT/units/by-entries",
        params={"entry_ids": entry_a},
        headers=h,
    )
    assert [i["id"] for i in only_a.json()["items"]] == [fit_a.json()["id"]]


async def test_an_entry_from_another_site_is_refused(client: AsyncClient) -> None:
    """TV4021 can reach both sites, so this is the site check on `entry_id`
    itself, not a permission gate that would 403 regardless."""
    h = await auth_headers(client)
    types = await _unit_types()
    umt_entry = await _work_entry(client, h, site="UMT", reg="MH05GX4410")

    fit = await _fit(
        client, h, types["Traction Motor"], "2026-08-01", entry_id=umt_entry
    )
    assert fit.status_code == 404, fit.text


# --- the Unit Failure Statement ----------------------------------------------


async def test_the_statement_is_the_removals_in_that_month(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    types = await _unit_types()

    in_month = (await _fit(client, h, types["Traction Motor"], "2026-07-01")).json()
    await _remove(
        client, h, in_month["id"], "2026-08-04", removal_reason="Bearing noise"
    )
    # Still on the bus, so not a failure.
    await _fit(client, h, types["Battery pack 1"], "2026-08-01")
    # Came off in September, not August.
    other = (
        await _fit(client, h, types["Traction Motor"], "2026-08-06", reg=OTHER)
    ).json()
    await _remove(client, h, other["id"], "2026-09-02")

    body = (
        await client.get(
            "/sites/MBMT/reports/unit-failures",
            params={"month": "2026-08"},
            headers=h,
        )
    ).json()
    assert body["month"] == "2026-08"
    assert len(body["items"]) == 1
    row = body["items"][0]
    assert row["registration_no"] == BUS
    assert row["unit_name"] == "Traction Motor"
    assert row["removal_reason"] == "Bearing noise"
    assert row["fitted_on"] == "2026-07-01"


async def test_a_month_with_no_removals_is_an_empty_statement(
    client: AsyncClient,
) -> None:
    """Which is a real answer, not a missing one."""
    h = await auth_headers(client)
    types = await _unit_types()
    await _fit(client, h, types["Traction Motor"], "2026-08-01")

    body = (
        await client.get(
            "/sites/MBMT/reports/unit-failures",
            params={"month": "2026-08"},
            headers=h,
        )
    ).json()
    assert body["items"] == []


async def test_the_statement_exports_in_the_sheets_own_columns(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    types = await _unit_types()
    stay = (
        await _fit(
            client,
            h,
            types["Traction Motor"],
            "2026-07-01",
            fitted_odometer_km=100_000,
            unit_no="TM-99812",
        )
    ).json()
    await _remove(
        client,
        h,
        stay["id"],
        "2026-08-04",
        removed_odometer_km=142_500,
        removal_reason="Bearing noise",
    )

    r = await client.get(
        "/sites/MBMT/reports/unit-failures/export",
        params={"month": "2026-08"},
        headers=h,
    )
    assert r.status_code == 200, r.text
    assert "text/csv" in r.headers["content-type"]
    body = r.text
    assert "Unit Failure Statement" in body
    assert "Sl.No,Bus No,Name of unit,Unit No" in body
    assert "TM-99812" in body
    assert "42500" in body
    assert "Bearing noise" in body


async def test_a_bad_month_is_refused(client: AsyncClient) -> None:
    h = await auth_headers(client)
    r = await client.get(
        "/sites/MBMT/reports/unit-failures", params={"month": "August"}, headers=h
    )
    assert r.status_code == 400


# --- the DMR line the unit master exists for ---------------------------------


async def test_hv_batteries_replaced_is_now_derived(client: AsyncClient) -> None:
    """Line 30 used to be typed in because nothing observed it. A pack coming
    off the bus is that event, and it is now written down."""
    h = await auth_headers(client)
    types = await _unit_types()

    pack = (await _fit(client, h, types["Battery pack 1"], "2026-07-01")).json()
    motor = (await _fit(client, h, types["Traction Motor"], "2026-07-01")).json()
    await _remove(client, h, pack["id"], "2026-08-04")
    # Not an HV pack, so it must not count towards this line.
    await _remove(client, h, motor["id"], "2026-08-04")

    body = (
        await client.get(
            "/sites/MBMT/reports/dmr", params={"date": "2026-08-04"}, headers=h
        )
    ).json()
    line = next(x for x in body["lines"] if x["number"] == 30)
    assert line["derived"] is True
    assert line["value"] == 1

    quiet = (
        await client.get(
            "/sites/MBMT/reports/dmr", params={"date": "2026-08-05"}, headers=h
        )
    ).json()
    assert next(x for x in quiet["lines"] if x["number"] == 30)["value"] == 0


# --- the bus history card ----------------------------------------------------


async def _card(client: AsyncClient, headers: dict, **params) -> dict:
    r = await client.get(
        f"/sites/MBMT/reports/bus-history/{await _vehicle_id()}",
        params=params,
        headers=headers,
    )
    assert r.status_code == 200, r.text
    return r.json()


def _cell(card: dict, unit: str, month: str):
    row = next(r for r in card["rows"] if r["unit_name"] == unit)
    return row["cells"][card["months"].index(month)]


async def test_the_card_is_every_unit_by_thirteen_months(
    client: AsyncClient,
) -> None:
    """Every unit is a row whether or not it was ever touched — the empty rows
    are the record of what has not been changed."""
    h = await auth_headers(client)
    await _unit_types()

    card = await _card(client, h, to="2026-08")
    assert card["months"] == [
        "2025-08", "2025-09", "2025-10", "2025-11", "2025-12",
        "2026-01", "2026-02", "2026-03", "2026-04", "2026-05",
        "2026-06", "2026-07", "2026-08",
    ]
    assert [r["unit_name"] for r in card["rows"]] == [
        "Battery pack 1",
        "Traction Motor",
    ]
    assert all(c is None for r in card["rows"] for c in r["cells"])
    assert card["events"] == 0
    assert card["registration_no"] == BUS


async def test_the_card_marks_the_month_a_unit_went_on_and_came_off(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    types = await _unit_types()
    stay = (
        await _fit(
            client,
            h,
            types["Traction Motor"],
            "2026-06-14",
            fitted_odometer_km=100_000,
        )
    ).json()
    await _remove(
        client,
        h,
        stay["id"],
        "2026-08-04",
        removed_odometer_km=142_500,
        removal_reason="Bearing noise",
    )

    card = await _card(client, h, to="2026-08")
    fitted = _cell(card, "Traction Motor", "2026-06")
    assert fitted["kind"] == "fitted"
    assert fitted["label"] == "14"

    removed = _cell(card, "Traction Motor", "2026-08")
    assert removed["kind"] == "removed"
    assert removed["label"] == "04"
    assert removed["reason"] == "Bearing noise"
    assert removed["kms_covered"] == 42_500

    # Nothing happened in July, and the card says so.
    assert _cell(card, "Traction Motor", "2026-07") is None
    assert card["events"] == 2


async def test_off_and_back_on_in_one_month_is_one_block(
    client: AsyncClient,
) -> None:
    """One block on the paper card, and "replaced" is what the depot writes in
    it."""
    h = await auth_headers(client)
    types = await _unit_types()
    first = (
        await _fit(client, h, types["Traction Motor"], "2026-07-01")
    ).json()
    await _remove(client, h, first["id"], "2026-08-04")
    await _fit(client, h, types["Traction Motor"], "2026-08-06")

    card = await _card(client, h, to="2026-08")
    cell = _cell(card, "Traction Motor", "2026-08")
    assert cell["kind"] == "replaced"
    assert cell["label"] == "04/06"


async def test_a_unit_still_on_the_bus_is_flagged(client: AsyncClient) -> None:
    h = await auth_headers(client)
    types = await _unit_types()
    await _fit(client, h, types["Battery pack 1"], "2026-06-01")
    gone = (await _fit(client, h, types["Traction Motor"], "2026-06-01")).json()
    await _remove(client, h, gone["id"], "2026-07-01")

    card = await _card(client, h, to="2026-08")
    flags = {r["unit_name"]: r["fitted_now"] for r in card["rows"]}
    assert flags == {"Battery pack 1": True, "Traction Motor": False}


async def test_events_outside_the_window_stay_off_the_card(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    types = await _unit_types()
    stay = (
        await _fit(client, h, types["Traction Motor"], "2024-01-05")
    ).json()
    await _remove(client, h, stay["id"], "2024-02-05")

    card = await _card(client, h, to="2026-08")
    assert card["events"] == 0
    # But it is not claimed to be fitted either — it came off long ago.
    assert all(not r["fitted_now"] for r in card["rows"])


async def test_the_window_can_be_narrowed(client: AsyncClient) -> None:
    h = await auth_headers(client)
    await _unit_types()
    card = await _card(client, h, to="2026-08", months=3)
    assert card["months"] == ["2026-06", "2026-07", "2026-08"]


async def test_a_bus_at_another_site_is_not_reachable(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    async with SessionLocal() as session:
        other = await session.scalar(
            select(Vehicle).where(Vehicle.registration_no == "MH05GX4410")
        )
        other_id = other.id

    r = await client.get(
        f"/sites/MBMT/reports/bus-history/{other_id}", headers=h
    )
    assert r.status_code == 404
