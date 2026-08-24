"""Ingest from fleet-streams' `serving` process.

Two live routes POST here (`app/api/integrations.py`): breakdown events and
odometer batches. `replay_on_startup` is the catch-up path — a one-shot GET
against fleet-streams' own replay endpoints if ENM was down when an event
fired — not the live path.

See docs/superpowers/specs/2026-08-24-sap-pm-enm-integration-design.md,
section 1.
"""
from __future__ import annotations

import logging
from datetime import UTC, datetime

import httpx
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.models.entry import BreakdownEntry, Entry
from app.models.enums import AuditAction, EntryStatus, Register
from app.models.master import Vehicle
from app.models.sync import SyncCursor
from app.models.user import User
from app.schemas.streams import (
    FleetStreamsEventIn,
    FleetStreamsEventOut,
    FleetStreamsOdometerBatchIn,
)
from app.services import audit, notifications, odometer
from app.services import entries as entries_svc
from app.services.common import IST
from app.services.masters import normalize_registration_no, resolve_defect_type
from app.services.sites import assert_date_is_plausible, assert_site_accepts_entries

logger = logging.getLogger("enm.streams")

#: Attributed as creator/resolver for entries this integration writes — there
#: is no human on the other end of these POSTs. Seeded by migration 0017.
SYSTEM_USER_ID = "FLEETSTREAMS"

_EVENTS_CURSOR = "fleet_streams_events"


async def _system_user(session: AsyncSession) -> User:
    user = await session.scalar(select(User).where(User.user_id == SYSTEM_USER_ID))
    if user is None:
        # Migration 0017 seeds this; missing means the migration hasn't run,
        # which is a deploy ordering bug worth failing loudly on rather than
        # inventing a throwaway user that would own real entries.
        raise RuntimeError(
            f"System user {SYSTEM_USER_ID!r} is missing — run migrations"
        )
    return user


async def _find_vehicle(session: AsyncSession, raw_registration: str) -> Vehicle | None:
    """Registration numbers are unique across the whole fleet (not per site),
    so unlike `resolve_vehicle` this needs no site to search within — the
    POST body doesn't carry one."""
    normalized = normalize_registration_no(raw_registration)
    return await session.scalar(
        select(Vehicle).where(Vehicle.registration_no == normalized)
    )


async def _find_breakdown(
    session: AsyncSession, streams_breakdown_id: str
) -> Entry | None:
    detail = await session.scalar(
        select(BreakdownEntry).where(
            BreakdownEntry.streams_breakdown_id == streams_breakdown_id
        )
    )
    if detail is None:
        return None
    # `detail.entry` is a lazy relationship — awaiting the FK lookup instead
    # avoids an implicit lazy-load outside greenlet context.
    return await session.get(Entry, detail.entry_id)


async def ingest_event(
    session: AsyncSession, payload: FleetStreamsEventIn
) -> FleetStreamsEventOut:
    vehicle = await _find_vehicle(session, payload.vehicle_id)
    if vehicle is None:
        logger.warning(
            "fleet-streams event for unknown registration %s (breakdown_id=%s)",
            payload.vehicle_id,
            payload.breakdown_id,
        )
        return FleetStreamsEventOut(applied=False, reason="unknown_vehicle")

    streams_id = str(payload.breakdown_id)

    if payload.action == "clear":
        entry = await _find_breakdown(session, streams_id)
        if entry is None:
            return FleetStreamsEventOut(applied=False, reason="unknown_breakdown")
        if entry.status is not EntryStatus.open:
            # Already resolved (by a person, or a prior clear) — a no-op,
            # not an error: resolving twice is exactly what idempotency means.
            return FleetStreamsEventOut(applied=True)
        await _resolve(session, entry)
        return FleetStreamsEventOut(applied=True)

    # open / update: find-or-create by streams_breakdown_id, then apply the
    # latest fields. Both actions patch identically — the spec doesn't give
    # `update` a different field set than `open` carries, so there is
    # nothing to gain from treating them as separate code paths.
    entry = await _find_breakdown(session, streams_id)
    if entry is None:
        entry = await _create_from_event(session, vehicle, payload, streams_id)
    else:
        await _patch_from_event(session, entry, payload)

    if payload.odo_km is not None:
        await _apply_odometer(
            session, vehicle, odometer_km=payload.odo_km, recorded_at=payload.ts
        )

    return FleetStreamsEventOut(applied=True)


async def _create_from_event(
    session: AsyncSession,
    vehicle: Vehicle,
    payload: FleetStreamsEventIn,
    streams_id: str,
) -> Entry:
    ts_ist = payload.ts.astimezone(IST)
    site = await assert_site_accepts_entries(session, vehicle.site_code)
    assert_date_is_plausible(site, ts_ist.date(), datetime.now(IST).date())

    system_user = await _system_user(session)
    defect_type = None
    if payload.category:
        try:
            defect_type = await resolve_defect_type(session, payload.category)
        except Exception:  # noqa: BLE001 — an unmatched category must not sink the event
            logger.info("fleet-streams category %r not in defect_types", payload.category)

    entry = await entries_svc.create_entry(
        session,
        register=Register.breakdown,
        site_code=vehicle.site_code,
        entry_date=ts_ist.date(),
        entry_time=ts_ist.time(),
        raw_data={
            "bus_no": vehicle.registration_no,
            "complaint": payload.note or "Reported by fleet-streams",
            "remarks": _remarks(payload),
        },
        creator=system_user,
    )
    detail: BreakdownEntry = entry.breakdown
    detail.streams_breakdown_id = streams_id
    detail.severity = payload.severity
    detail.eta_min = payload.eta_min
    detail.lat = payload.lat
    detail.lon = payload.lon
    if defect_type is not None:
        detail.defect_type_id = defect_type.id
    await session.flush()

    await audit.record(
        session,
        actor_id=system_user.id,
        action=AuditAction.entry_created,
        object_type="entry",
        object_id=entry.id,
        after={"source": "fleet-streams", "streams_breakdown_id": streams_id},
    )
    await notifications.notify_breakdown_opened(session, entry)
    return entry


async def _patch_from_event(
    session: AsyncSession, entry: Entry, payload: FleetStreamsEventIn
) -> None:
    detail: BreakdownEntry = entry.breakdown
    if payload.note:
        detail.complaint = payload.note
    if payload.severity is not None:
        detail.severity = payload.severity
    if payload.eta_min is not None:
        detail.eta_min = payload.eta_min
    if payload.lat is not None:
        detail.lat = payload.lat
    if payload.lon is not None:
        detail.lon = payload.lon
    remarks = _remarks(payload)
    if remarks:
        detail.remarks = remarks
    if payload.category:
        try:
            defect_type = await resolve_defect_type(session, payload.category)
        except Exception:  # noqa: BLE001 — see _create_from_event
            defect_type = None
        if defect_type is not None:
            detail.defect_type_id = defect_type.id
    entry.updated_at = datetime.now(UTC)
    await session.flush()


async def _resolve(session: AsyncSession, entry: Entry) -> None:
    system_user = await _system_user(session)
    now = datetime.now(UTC)
    entry.status = EntryStatus.resolved
    entry.updated_at = now
    detail: BreakdownEntry = entry.breakdown
    detail.resolved_at = now
    detail.resolved_by_id = system_user.id
    await audit.record(
        session,
        actor_id=system_user.id,
        action=AuditAction.entry_resolved,
        object_type="entry",
        object_id=entry.id,
        after={"status": "resolved", "source": "fleet-streams"},
    )
    await notifications.notify_breakdown_resolved(session, entry, system_user)


def _remarks(payload: FleetStreamsEventIn) -> str | None:
    parts = [p for p in (payload.by_whom, payload.contact) if p]
    return " · ".join(parts) if parts else None


async def _apply_odometer(
    session: AsyncSession, vehicle: Vehicle, *, odometer_km: int, recorded_at: datetime
) -> None:
    if vehicle.odometer_updated_at is not None and odometer_km < vehicle.odometer_km:
        return  # never backwards — same guard every other caller applies
    odometer.record_reading(
        session,
        vehicle,
        odometer_km=odometer_km,
        recorded_at=recorded_at,
        source="fleet-streams",
    )


async def ingest_odometers(
    session: AsyncSession, payload: FleetStreamsOdometerBatchIn
) -> int:
    """Returns how many of the batch were actually applied."""
    applied = 0
    for reading in payload.readings:
        vehicle = await _find_vehicle(session, reading.vehicle_id)
        if vehicle is None:
            logger.warning(
                "fleet-streams odometer for unknown registration %s", reading.vehicle_id
            )
            continue
        if vehicle.odometer_updated_at is not None and reading.odo_km < vehicle.odometer_km:
            continue
        odometer.record_reading(
            session,
            vehicle,
            odometer_km=reading.odo_km,
            recorded_at=reading.odo_ts,
            source="fleet-streams",
        )
        applied += 1
    if applied:
        await session.flush()
    return applied


async def replay_on_startup() -> None:
    """One-shot catch-up if ENM was down when an event fired. Never blocks
    startup — a fleet-streams outage must not be a reason ENM itself fails
    to come up."""
    if not (settings.fleet_streams_base_url and settings.enm_feed_token):
        return
    try:
        await _replay()
    except Exception:  # noqa: BLE001 — startup must proceed regardless
        logger.exception("fleet-streams replay failed; live ingest still works")


async def _replay() -> None:
    from app.db import SessionLocal

    async with SessionLocal() as session:
        cursor = await session.scalar(
            select(SyncCursor).where(SyncCursor.name == _EVENTS_CURSOR)
        )
        after = cursor.value if cursor else None

        base = settings.fleet_streams_base_url.rstrip("/")
        headers = {"Authorization": f"Bearer {settings.enm_feed_token}"}
        async with httpx.AsyncClient(timeout=10.0) as client:
            params = {"after": after} if after else {}
            events_resp = await client.get(
                f"{base}/api/enm/v1/events", params=params, headers=headers
            )
            events_resp.raise_for_status()
            events = events_resp.json()

            # Informational only for now — nothing on the ENM side consumes
            # the vehicle list yet; the fleet master is authoritative here.
            vehicles_resp = await client.get(
                f"{base}/api/enm/v1/vehicles", headers=headers
            )
            vehicles_resp.raise_for_status()
            logger.info(
                "fleet-streams replay: %d event(s), %d vehicle(s) on file",
                len(events),
                len(vehicles_resp.json()),
            )

        last_id = after
        for raw in events:
            try:
                await ingest_event(session, FleetStreamsEventIn(**raw))
            except Exception:  # noqa: BLE001 — one bad replayed event must not drop the rest
                logger.exception("failed to replay fleet-streams event %r", raw)
            last_id = raw.get("event_id", last_id)

        if last_id is not None:
            if cursor is None:
                cursor = SyncCursor(name=_EVENTS_CURSOR)
                session.add(cursor)
            cursor.value = str(last_id)
            cursor.updated_at = datetime.now(UTC)
        await session.commit()
