from __future__ import annotations

from datetime import UTC, datetime

from httpx import AsyncClient
from sqlalchemy import func, select
from sqlalchemy.orm import selectinload

from app.db import SessionLocal
from app.models.entry import BreakdownEntry, Entry
from app.models.enums import EntryStatus
from app.models.master import Vehicle

FEED_HEADERS = {"Authorization": "Bearer test-feed-token"}
BUS = "MH40LY1894"


def event(
    *,
    action: str = "open",
    breakdown_id: int = 1842,
    vehicle_id: str = BUS,
    **overrides,
) -> dict:
    body = {
        "vehicle_id": vehicle_id,
        "action": action,
        "breakdown_id": breakdown_id,
        "category": None,
        "severity": "major",
        "note": "LHS rear",
        "contact": None,
        "by_whom": "ops",
        "eta_min": 40,
        "lat": 19.18,
        "lon": 72.85,
        "ts": datetime.now(UTC).isoformat(),
        "odo_km": None,
    }
    body.update(overrides)
    return body


async def _breakdown_count(streams_breakdown_id: str) -> int:
    async with SessionLocal() as session:
        return await session.scalar(
            select(func.count())
            .select_from(BreakdownEntry)
            .where(BreakdownEntry.streams_breakdown_id == streams_breakdown_id)
        )


async def _entry_for(streams_breakdown_id: str) -> Entry:
    async with SessionLocal() as session:
        detail = await session.scalar(
            select(BreakdownEntry).where(
                BreakdownEntry.streams_breakdown_id == streams_breakdown_id
            )
        )
        entry = await session.scalar(
            select(Entry)
            .where(Entry.id == detail.entry_id)
            .options(selectinload(Entry.breakdown))
        )
        # Force-load before the session closes — the caller reads
        # entry.breakdown.* on a detached instance.
        _ = entry.breakdown
        return entry


async def test_open_twice_does_not_duplicate(client: AsyncClient) -> None:
    r1 = await client.post(
        "/integrations/fleet-streams/events", json=event(), headers=FEED_HEADERS
    )
    assert r1.status_code == 200, r1.text
    assert r1.json() == {"applied": True, "reason": None}

    r2 = await client.post(
        "/integrations/fleet-streams/events", json=event(), headers=FEED_HEADERS
    )
    assert r2.status_code == 200, r2.text

    assert await _breakdown_count("1842") == 1


async def test_update_patches_the_existing_breakdown(client: AsyncClient) -> None:
    await client.post(
        "/integrations/fleet-streams/events", json=event(), headers=FEED_HEADERS
    )
    r = await client.post(
        "/integrations/fleet-streams/events",
        json=event(action="update", severity="critical", note="now on fire"),
        headers=FEED_HEADERS,
    )
    assert r.status_code == 200, r.text
    assert await _breakdown_count("1842") == 1

    entry = await _entry_for("1842")
    assert entry.breakdown.severity == "critical"
    assert entry.breakdown.complaint == "now on fire"
    assert entry.status is EntryStatus.open


async def test_clear_resolves_and_is_idempotent(client: AsyncClient) -> None:
    await client.post(
        "/integrations/fleet-streams/events", json=event(), headers=FEED_HEADERS
    )
    r1 = await client.post(
        "/integrations/fleet-streams/events",
        json=event(action="clear"),
        headers=FEED_HEADERS,
    )
    assert r1.status_code == 200, r1.text
    entry = await _entry_for("1842")
    assert entry.status is EntryStatus.resolved

    # A second clear on an already-resolved entry is a no-op, not an error.
    r2 = await client.post(
        "/integrations/fleet-streams/events",
        json=event(action="clear"),
        headers=FEED_HEADERS,
    )
    assert r2.status_code == 200, r2.text
    assert r2.json()["applied"] is True


async def test_clear_with_no_open_returns_unknown(client: AsyncClient) -> None:
    r = await client.post(
        "/integrations/fleet-streams/events",
        json=event(action="clear", breakdown_id=999999),
        headers=FEED_HEADERS,
    )
    assert r.status_code == 200, r.text
    assert r.json() == {"applied": False, "reason": "unknown_breakdown"}


async def test_unknown_registration_is_skipped_not_errored(client: AsyncClient) -> None:
    r = await client.post(
        "/integrations/fleet-streams/events",
        json=event(vehicle_id="MH99ZZ0000"),
        headers=FEED_HEADERS,
    )
    assert r.status_code == 200, r.text
    assert r.json() == {"applied": False, "reason": "unknown_vehicle"}
    assert await _breakdown_count("1842") == 0


async def test_missing_or_wrong_token_is_401(client: AsyncClient) -> None:
    r = await client.post("/integrations/fleet-streams/events", json=event())
    assert r.status_code == 401

    r = await client.post(
        "/integrations/fleet-streams/events",
        json=event(),
        headers={"Authorization": "Bearer wrong-token"},
    )
    assert r.status_code == 401


async def test_odometer_batch_applies_and_skips(client: AsyncClient) -> None:
    async with SessionLocal() as session:
        vehicle = await session.scalar(
            select(Vehicle).where(Vehicle.registration_no == BUS)
        )
        vehicle.odometer_km = 41000
        from datetime import datetime as dt

        vehicle.odometer_updated_at = dt.now(UTC)
        await session.commit()

    r = await client.post(
        "/integrations/fleet-streams/odometers",
        json={
            "readings": [
                # applied: a real advance
                {
                    "vehicle_id": BUS,
                    "odo_km": 41500,
                    "odo_ts": datetime.now(UTC).isoformat(),
                },
                # skipped: moves backwards
                {
                    "vehicle_id": BUS,
                    "odo_km": 100,
                    "odo_ts": datetime.now(UTC).isoformat(),
                },
                # skipped: no such vehicle, and must not create one
                {
                    "vehicle_id": "MH99ZZ0000",
                    "odo_km": 5000,
                    "odo_ts": datetime.now(UTC).isoformat(),
                },
            ]
        },
        headers=FEED_HEADERS,
    )
    assert r.status_code == 200, r.text
    assert r.json() == {"received": 3, "applied": 1}

    async with SessionLocal() as session:
        vehicle = await session.scalar(
            select(Vehicle).where(Vehicle.registration_no == BUS)
        )
        assert vehicle.odometer_km == 41500
        unknown = await session.scalar(
            select(Vehicle).where(Vehicle.registration_no == "MH99ZZ0000")
        )
        assert unknown is None
