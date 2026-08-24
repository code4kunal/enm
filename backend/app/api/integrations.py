"""Inbound integrations — processes with no ENM session of their own.

fleet-streams' `serving` posts breakdown events and odometer batches here,
bearer-authenticated against `ENM_FEED_TOKEN` (see `app.deps.fleet_streams_auth`),
not a user session. See docs/superpowers/specs/2026-08-24-sap-pm-enm-integration-design.md.
"""
from __future__ import annotations

from fastapi import APIRouter, status

from app.deps import FleetStreamsAuth, SessionDep
from app.schemas.streams import (
    FleetStreamsEventIn,
    FleetStreamsEventOut,
    FleetStreamsOdometerBatchIn,
)
from app.services import streams

router = APIRouter(prefix="/integrations", tags=["integrations"])


@router.post(
    "/fleet-streams/events",
    response_model=FleetStreamsEventOut,
    status_code=status.HTTP_200_OK,
)
async def fleet_streams_event(
    payload: FleetStreamsEventIn,
    _auth: FleetStreamsAuth,
    session: SessionDep,
) -> FleetStreamsEventOut:
    result = await streams.ingest_event(session, payload)
    await session.commit()
    return result


@router.post("/fleet-streams/odometers", status_code=status.HTTP_200_OK)
async def fleet_streams_odometers(
    payload: FleetStreamsOdometerBatchIn,
    _auth: FleetStreamsAuth,
    session: SessionDep,
) -> dict[str, int]:
    applied = await streams.ingest_odometers(session, payload)
    await session.commit()
    return {"received": len(payload.readings), "applied": applied}
