"""WhatsApp outbound send + inbound signature verification.

Meta Cloud API — a real, stable, publicly documented contract (unlike the
SAP adapter, this one isn't guessing at a shape). Lazy/optional exactly
like `app.services.fcm`: unset credentials disable the channel, they never
raise.
"""
from __future__ import annotations

import hashlib
import hmac
import logging

import httpx

from app.config import settings

logger = logging.getLogger("enm.whatsapp")

_GRAPH_BASE = "https://graph.facebook.com/v20.0"


def configured() -> bool:
    return bool(settings.whatsapp_token and settings.whatsapp_phone_id)


async def send_text(to: str, body: str) -> bool:
    """Best-effort — never raises. Returns whether it actually sent."""
    if not configured():
        return False
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.post(
                f"{_GRAPH_BASE}/{settings.whatsapp_phone_id}/messages",
                headers={"Authorization": f"Bearer {settings.whatsapp_token}"},
                json={
                    "messaging_product": "whatsapp",
                    "to": to,
                    "type": "text",
                    "text": {"body": body},
                },
            )
        if resp.status_code >= 400:
            logger.warning("WhatsApp send to %s failed: %s", to, resp.text[:300])
            return False
        return True
    except httpx.HTTPError:
        logger.exception("WhatsApp send to %s failed", to)
        return False


def verify_signature(raw_body: bytes, signature_header: str | None) -> bool:
    """`X-Hub-Signature-256: sha256=<hex>` over the raw body, keyed on the
    app secret — not `whatsapp_verify_token`, which only answers the
    one-time GET handshake. Missing config or header refuses, never opens."""
    if not settings.whatsapp_app_secret or not signature_header:
        return False
    if not signature_header.startswith("sha256="):
        return False
    expected = hmac.new(
        settings.whatsapp_app_secret.encode(), raw_body, hashlib.sha256
    ).hexdigest()
    return hmac.compare_digest(expected, signature_header.removeprefix("sha256="))
