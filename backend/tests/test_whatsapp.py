from __future__ import annotations

import hashlib
import hmac
import json

import pytest
from httpx import AsyncClient
from sqlalchemy import select

from app.config import settings
from app.db import SessionLocal
from app.models.entry import Entry
from app.models.enums import Register
from app.models.master import Vehicle
from app.services import whatsapp_commands
from app.services.channels import whatsapp
from app.services.channels.whatsapp import verify_signature


def test_verify_signature_rejects_missing_or_wrong(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(settings, "whatsapp_app_secret", "s3cr3t")
    body = b'{"hello": "world"}'

    assert verify_signature(body, None) is False
    assert verify_signature(body, "sha256=deadbeef") is False

    correct = "sha256=" + hmac.new(b"s3cr3t", body, hashlib.sha256).hexdigest()
    assert verify_signature(body, correct) is True


def test_verify_signature_refuses_when_unconfigured(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(settings, "whatsapp_app_secret", None)
    assert verify_signature(b"{}", "sha256=anything") is False


async def test_down_files_a_breakdown_for_a_known_bus() -> None:
    async with SessionLocal() as session:
        reply = await whatsapp_commands.handle_command(
            session, "+91900000", "DOWN MH40LY1894 steering pulling left"
        )
        assert "Breakdown filed for MH40LY1894" in reply

        entry = await session.scalar(
            select(Entry).where(Entry.register == Register.breakdown)
        )
        assert entry is not None


async def test_down_with_unknown_registration_creates_nothing() -> None:
    async with SessionLocal() as session:
        reply = await whatsapp_commands.handle_command(
            session, "+91900000", "DOWN MH99ZZ0000 flat tyre"
        )
        assert "not on the fleet" in reply

        vehicle = await session.scalar(
            select(Vehicle).where(Vehicle.registration_no == "MH99ZZ0000")
        )
        assert vehicle is None


async def test_status_reports_nothing_open() -> None:
    async with SessionLocal() as session:
        reply = await whatsapp_commands.handle_command(
            session, "+91900000", "STATUS MH40LY1894"
        )
        assert reply == "MH40LY1894: nothing open."


async def test_status_after_down_shows_the_open_breakdown() -> None:
    async with SessionLocal() as session:
        await whatsapp_commands.handle_command(
            session, "+91900000", "DOWN MH40LY1894 brake noise"
        )
        reply = await whatsapp_commands.handle_command(
            session, "+91900000", "STATUS MH40LY1894"
        )
        assert "open breakdown" in reply
        assert "brake noise" in reply


async def test_unrecognized_command_gets_help() -> None:
    async with SessionLocal() as session:
        reply = await whatsapp_commands.handle_command(session, "+91900000", "hello there")
        assert reply == whatsapp_commands.HELP_TEXT


async def test_webhook_rejects_bad_signature(client: AsyncClient) -> None:
    r = await client.post(
        "/integrations/whatsapp",
        content=b'{"entry": []}',
        headers={"X-Hub-Signature-256": "sha256=wrong"},
    )
    assert r.status_code == 401


async def test_webhook_accepts_valid_signature_and_files_a_breakdown(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(settings, "whatsapp_app_secret", "s3cr3t")
    sent: list[tuple[str, str]] = []

    async def fake_send_text(to: str, body: str) -> bool:
        sent.append((to, body))
        return True

    monkeypatch.setattr(whatsapp, "send_text", fake_send_text)

    payload = {
        "entry": [
            {
                "changes": [
                    {
                        "value": {
                            "messages": [
                                {
                                    "type": "text",
                                    "from": "+91900000",
                                    "text": {"body": "DOWN MH40LY1895 oil leak"},
                                }
                            ]
                        }
                    }
                ]
            }
        ]
    }
    raw = json.dumps(payload).encode()
    signature = "sha256=" + hmac.new(b"s3cr3t", raw, hashlib.sha256).hexdigest()

    r = await client.post(
        "/integrations/whatsapp",
        content=raw,
        headers={
            "X-Hub-Signature-256": signature,
            "Content-Type": "application/json",
        },
    )
    assert r.status_code == 200, r.text
    assert len(sent) == 1
    assert "Breakdown filed for MH40LY1895" in sent[0][1]
