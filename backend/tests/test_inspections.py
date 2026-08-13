from __future__ import annotations

from datetime import date, timedelta

from httpx import AsyncClient
from sqlalchemy import select

from app.db import SessionLocal
from app.models.enums import SlotStatus
from app.models.inspection import Alert, InspectionPlan, InspectionSlot
from app.models.master import Vehicle, WorkType
from app.services import inspections
from tests.conftest import auth_headers

TODAY = date(2026, 8, 13)


async def _setup_plans(daily_cap: int = 0, ten_day_cap: int = 2) -> dict[str, int]:
    """MBMT's two cycles: a daily inspection over the whole fleet, and a
    capped 10-day service."""
    async with SessionLocal() as session:
        ids: dict[str, int] = {}
        for code, name, cycle, cap in (
            ("D.I", "Daily inspection", 1, daily_cap),
            ("10 DAYS SERVICE", "10 day inspection", 10, ten_day_cap),
        ):
            work_type = await session.scalar(
                select(WorkType).where(WorkType.code == code)
            )
            if work_type is None:
                work_type = WorkType(code=code, name=name, is_inspection=True)
                session.add(work_type)
                await session.flush()
            ids[code] = work_type.id
            session.add(
                InspectionPlan(
                    site_code="MBMT",
                    work_type_id=work_type.id,
                    cycle_days=cycle,
                    slots_per_day=cap,
                )
            )
        await session.commit()
        return ids


async def _generate(today: date = TODAY) -> inspections.GenerationResult:
    async with SessionLocal() as session:
        result = await inspections.generate_for_site(session, "MBMT", today)
        await session.commit()
        return result


async def _slots(work_type_id: int | None = None) -> list[InspectionSlot]:
    async with SessionLocal() as session:
        stmt = select(InspectionSlot).where(InspectionSlot.site_code == "MBMT")
        if work_type_id is not None:
            stmt = stmt.where(InspectionSlot.work_type_id == work_type_id)
        return list(
            (await session.scalars(stmt.order_by(InspectionSlot.scheduled_on)))
            .unique()
            .all()
        )


async def test_a_daily_inspection_books_the_whole_fleet_every_night() -> None:
    ids = await _setup_plans()
    await _generate()

    slots = await _slots(ids["D.I"])
    by_day: dict[date, int] = {}
    for slot in slots:
        by_day[slot.scheduled_on] = by_day.get(slot.scheduled_on, 0) + 1

    # MBMT's fixture fleet has two active vehicles; both are due every night.
    assert set(by_day.values()) == {2}
    assert min(by_day) == TODAY


async def test_the_ten_day_service_respects_its_nightly_cap() -> None:
    ids = await _setup_plans(ten_day_cap=1)
    await _generate()

    slots = await _slots(ids["10 DAYS SERVICE"])
    by_day: dict[date, int] = {}
    for slot in slots:
        by_day[slot.scheduled_on] = by_day.get(slot.scheduled_on, 0) + 1
    assert max(by_day.values()) == 1


async def test_a_bus_comes_round_again_a_full_cycle_later() -> None:
    ids = await _setup_plans(ten_day_cap=5)
    await _generate()

    slots = await _slots(ids["10 DAYS SERVICE"])
    per_vehicle: dict[str, list[date]] = {}
    for slot in slots:
        per_vehicle.setdefault(slot.vehicle_id, []).append(slot.scheduled_on)

    for dates in per_vehicle.values():
        dates.sort()
        for earlier, later in zip(dates, dates[1:], strict=False):
            assert (later - earlier).days == 10


async def test_generating_twice_changes_nothing() -> None:
    await _setup_plans()
    first = await _generate()
    assert first.created > 0

    second = await _generate()
    assert second.created == 0
    assert second.missed == 0


async def test_a_missed_night_is_marked_and_jumps_the_queue() -> None:
    # Capacity to spare, so the jump is visible. Where every night is already
    # full the other rule wins and the bus takes the first night with room —
    # see the test below.
    ids = await _setup_plans(ten_day_cap=5)
    await _generate(TODAY)

    # A day passes and nothing was recorded.
    tomorrow = TODAY + timedelta(days=1)
    result = await _generate(tomorrow)
    assert result.missed >= 1

    slots = await _slots(ids["10 DAYS SERVICE"])
    missed = [s for s in slots if s.status is SlotStatus.missed]
    assert missed
    assert all(s.scheduled_on < tomorrow for s in missed)

    # The bus that slipped is booked again, at the front.
    slipped = missed[0].vehicle_id
    rebooked = [
        s
        for s in slots
        if s.vehicle_id == slipped
        and s.status is SlotStatus.scheduled
        and s.scheduled_on >= tomorrow
    ]
    assert rebooked
    assert min(s.scheduled_on for s in rebooked) == tomorrow


async def test_a_full_night_makes_the_missed_bus_wait_rather_than_displace() -> None:
    """"Others hold their dates" is the stronger rule.

    A depot that bumps someone else every time a bus slips never builds a
    routine, so the bus that missed takes the first night that has room.
    """
    ids = await _setup_plans(ten_day_cap=1)
    await _generate(TODAY)
    tomorrow = TODAY + timedelta(days=1)

    held = [
        s.vehicle_id
        for s in await _slots(ids["10 DAYS SERVICE"])
        if s.scheduled_on == tomorrow
    ]
    await _generate(tomorrow)

    after = await _slots(ids["10 DAYS SERVICE"])
    still_held = [
        s.vehicle_id
        for s in after
        if s.scheduled_on == tomorrow and s.status is SlotStatus.scheduled
    ]
    assert still_held == held

    missed = [s for s in after if s.status is SlotStatus.missed]
    assert missed
    rebooked = min(
        s.scheduled_on
        for s in after
        if s.vehicle_id == missed[0].vehicle_id
        and s.status is SlotStatus.scheduled
        and s.scheduled_on >= tomorrow
    )
    # Sooner than its own next turn in the rotation, but not by evicting anyone.
    assert rebooked > tomorrow
    assert rebooked < TODAY + timedelta(days=10)


async def test_a_recorded_inspection_discharges_its_booking(
    client: AsyncClient,
) -> None:
    ids = await _setup_plans()
    await _generate()

    h = await auth_headers(client)
    async with SessionLocal() as session:
        vehicle = await session.scalar(
            select(Vehicle).where(Vehicle.registration_no == "MH40LY1894")
        )
        vehicle_id = vehicle.id

    # An inspection is its own record with its own checklist, so this is what
    # actually discharges the booking.
    created = await client.post(
        "/sites/MBMT/inspections",
        json={
            "vehicle_id": vehicle_id,
            "work_type_id": ids["D.I"],
            "inspected_on": TODAY.isoformat(),
            "done_by": "Tushar",
            "results": [],
        },
        headers=h,
    )
    assert created.status_code == 201, created.text

    result = await _generate()
    assert result.completed >= 1

    slots = await _slots(ids["D.I"])
    done = [
        s
        for s in slots
        if s.vehicle_id == vehicle_id
        and s.scheduled_on == TODAY
        and s.status is SlotStatus.done
    ]
    assert done
    assert done[0].completed_on == TODAY


async def test_a_retired_bus_leaves_the_rotation() -> None:
    ids = await _setup_plans()
    async with SessionLocal() as session:
        vehicle = await session.scalar(
            select(Vehicle).where(Vehicle.registration_no == "MH40LY1895")
        )
        vehicle.is_active = False
        retired_id = vehicle.id
        await session.commit()

    await _generate()
    slots = await _slots(ids["D.I"])
    assert all(s.vehicle_id != retired_id for s in slots)


async def test_an_open_breakdown_raises_one_alert_not_one_a_night(
    client: AsyncClient,
) -> None:
    await _setup_plans()
    h = await auth_headers(client)
    created = await client.post(
        "/entries",
        json={
            "register": "breakdown",
            "site": "MBMT",
            "date": TODAY.isoformat(),
            "data": {"bus_no": "MH40LY1894", "complaint": "No traction"},
        },
        headers=h,
    )
    assert created.status_code == 201

    first = await _generate()
    assert first.alerts_raised >= 1
    second = await _generate(TODAY + timedelta(days=1))
    # Same problem, still open — not raised again.
    async with SessionLocal() as session:
        alerts = list(
            (
                await session.scalars(
                    select(Alert).where(Alert.type == "breakdown_open")
                )
            ).all()
        )
    assert len(alerts) == 1
    assert second.alerts_raised == 0 or all(
        a.dedupe_key.startswith("breakdown:") is False
        for a in alerts[1:]
    )


async def test_resolving_a_breakdown_closes_its_alert(client: AsyncClient) -> None:
    await _setup_plans()
    h = await auth_headers(client)
    created = await client.post(
        "/entries",
        json={
            "register": "breakdown",
            "site": "MBMT",
            "date": TODAY.isoformat(),
            "data": {"bus_no": "MH40LY1894", "complaint": "No traction"},
        },
        headers=h,
    )
    await _generate()

    resolved = await client.post(
        f"/entries/{created.json()['id']}/resolve", headers=h
    )
    assert resolved.status_code == 200, resolved.text

    await _generate()
    async with SessionLocal() as session:
        alert = await session.scalar(
            select(Alert).where(Alert.type == "breakdown_open")
        )
    assert alert.status.value == "resolved"


# --- the API ----------------------------------------------------------------


async def test_calendar_returns_every_day_including_empty_ones(
    client: AsyncClient,
) -> None:
    await _setup_plans()
    await _generate()
    h = await auth_headers(client)

    r = await client.get(
        "/sites/MBMT/inspections/calendar",
        params={"from": TODAY.isoformat(), "to": (TODAY + timedelta(days=3)).isoformat()},
        headers=h,
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert len(body["days"]) == 4
    assert body["scheduled"] > 0
    assert body["days"][0]["date"] == TODAY.isoformat()


async def test_calendar_refuses_an_absurd_range(client: AsyncClient) -> None:
    h = await auth_headers(client)
    r = await client.get(
        "/sites/MBMT/inspections/calendar",
        params={"from": "2020-01-01", "to": "2030-01-01"},
        headers=h,
    )
    assert r.status_code == 400


async def test_manual_generate_is_manager_only(client: AsyncClient) -> None:
    await _setup_plans()
    sup = await auth_headers(client, "TV4102")
    assert (
        await client.post("/sites/MBMT/inspections/generate", headers=sup)
    ).status_code == 403

    h = await auth_headers(client)
    r = await client.post("/sites/MBMT/inspections/generate", headers=h)
    assert r.status_code == 200
    assert r.json()["created"] > 0


async def test_moving_a_slot_pins_it_against_the_generator(
    client: AsyncClient,
) -> None:
    ids = await _setup_plans(ten_day_cap=1)
    await _generate()
    h = await auth_headers(client)

    # A 10-day booking: the daily inspection holds every bus every night, so
    # there is no free day to move one of those to.
    slots = await _slots(ids["10 DAYS SERVICE"])
    slot = slots[0]
    moved_to = slot.scheduled_on + timedelta(days=1)

    r = await client.put(
        f"/inspection-slots/{slot.id}",
        json={"scheduled_on": moved_to.isoformat(), "notes": "bay booked"},
        headers=h,
    )
    assert r.status_code == 200, r.text
    assert r.json()["scheduled_on"] == moved_to.isoformat()
    assert r.json()["is_pinned"] is True
    assert r.json()["notes"] == "bay booked"

    # Re-running must not move it back.
    await _generate()
    async with SessionLocal() as session:
        again = await session.get(InspectionSlot, slot.id)
        assert again.scheduled_on == moved_to


async def test_a_hand_booked_slot_can_be_added_and_deleted(
    client: AsyncClient,
) -> None:
    ids = await _setup_plans()
    h = await auth_headers(client)
    async with SessionLocal() as session:
        vehicle = await session.scalar(
            select(Vehicle).where(Vehicle.registration_no == "MH40LY1894")
        )
        vehicle_id = vehicle.id

    body = {
        "vehicle_id": vehicle_id,
        "work_type_id": ids["10 DAYS SERVICE"],
        "scheduled_on": (TODAY + timedelta(days=2)).isoformat(),
        "notes": "after the route change",
    }
    created = await client.post(
        "/sites/MBMT/inspections/slots", json=body, headers=h
    )
    assert created.status_code == 201, created.text
    assert created.json()["is_pinned"] is True

    # Same bus, same day, same inspection is a conflict, not a second booking.
    assert (
        await client.post("/sites/MBMT/inspections/slots", json=body, headers=h)
    ).status_code == 409

    assert (
        await client.delete(
            f"/inspection-slots/{created.json()['id']}", headers=h
        )
    ).status_code == 204


async def test_alerts_can_be_listed_and_acknowledged(client: AsyncClient) -> None:
    await _setup_plans()
    h = await auth_headers(client)
    await client.post(
        "/entries",
        json={
            "register": "breakdown",
            "site": "MBMT",
            "date": TODAY.isoformat(),
            "data": {"bus_no": "MH40LY1894", "complaint": "No traction"},
        },
        headers=h,
    )
    await _generate()

    listed = await client.get("/sites/MBMT/alerts", headers=h)
    assert listed.status_code == 200
    assert listed.json()["open_count"] >= 1
    alert = listed.json()["items"][0]
    assert alert["registration_no"] == "MH40LY1894"

    acked = await client.post(f"/alerts/{alert['id']}/acknowledge", headers=h)
    assert acked.status_code == 200
    assert acked.json()["status"] == "acknowledged"
    assert acked.json()["acknowledged_at"] is not None


async def test_plans_can_be_edited(client: AsyncClient) -> None:
    ids = await _setup_plans()
    h = await auth_headers(client)

    r = await client.put(
        "/sites/MBMT/inspections/plans",
        json={
            "items": [
                {
                    "work_type_id": ids["10 DAYS SERVICE"],
                    "cycle_days": 14,
                    "slots_per_day": 3,
                    "is_active": True,
                }
            ]
        },
        headers=h,
    )
    assert r.status_code == 200, r.text
    items = r.json()["items"]
    assert len(items) == 1
    assert items[0]["cycle_days"] == 14
    assert items[0]["slots_per_day"] == 3
    assert items[0]["work_type_code"] == "10 DAYS SERVICE"
