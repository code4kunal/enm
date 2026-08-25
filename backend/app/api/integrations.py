"""Inbound integrations — processes with no ENM session of their own.

fleet-streams' `serving` posts breakdown events and odometer batches here,
bearer-authenticated against `ENM_FEED_TOKEN` (see `app.deps.fleet_streams_auth`),
not a user session. See docs/superpowers/specs/2026-08-24-sap-pm-enm-integration-design.md.
"""
from __future__ import annotations

import hmac
import logging

from fastapi import APIRouter, Request, Response, status
from fastapi.responses import PlainTextResponse

from app.config import settings
from app.deps import FleetStreamsAuth, SessionDep
from app.errors import Unauthorized
from app.schemas.streams import (
    FleetStreamsEventIn,
    FleetStreamsEventOut,
    FleetStreamsOdometerBatchIn,
)
from app.services import streams, whatsapp_commands
from app.services.channels import whatsapp

logger = logging.getLogger("enm.integrations")

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


@router.get("/whatsapp")
async def whatsapp_verify(request: Request) -> PlainTextResponse:
    """Meta's one-time GET handshake when the webhook URL is registered."""
    mode = request.query_params.get("hub.mode")
    token = request.query_params.get("hub.verify_token") or ""
    challenge = request.query_params.get("hub.challenge", "")
    if (
        mode == "subscribe"
        and settings.whatsapp_verify_token
        and hmac.compare_digest(token, settings.whatsapp_verify_token)
    ):
        return PlainTextResponse(challenge)
    raise Unauthorized("Invalid WhatsApp verify token")


@router.post("/whatsapp", status_code=status.HTTP_200_OK)
async def whatsapp_webhook(request: Request, session: SessionDep) -> Response:
    """Public, signature-checked, not session-auth — see
    `app.services.channels.whatsapp.verify_signature`."""
    raw = await request.body()
    signature = request.headers.get("X-Hub-Signature-256")
    if not whatsapp.verify_signature(raw, signature):
        raise Unauthorized("Invalid WhatsApp signature")

    body = await request.json()
    for entry in body.get("entry", []):
        for change in entry.get("changes", []):
            for message in change.get("value", {}).get("messages", []):
                if message.get("type") != "text":
                    continue
                from_number = message.get("from", "")
                text = message.get("text", {}).get("body", "")
                if not from_number or not text:
                    continue
                reply = await whatsapp_commands.handle_command(session, from_number, text)
                await whatsapp.send_text(from_number, reply)

    return Response(status_code=status.HTTP_200_OK)
