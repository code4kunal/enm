"""Email outbound send — plain stdlib smtplib, no new dependency.

Lazy/optional exactly like `app.services.fcm`: unset SMTP settings disable
the channel, never raise. Blocking `smtplib` calls run off the event loop
via `asyncio.to_thread`, the same shape `fcm.py` uses for its own blocking
SDK call.
"""
from __future__ import annotations

import asyncio
import logging
import smtplib
from email.mime.text import MIMEText

from app.config import settings

logger = logging.getLogger("enm.email")


def configured() -> bool:
    return bool(settings.smtp_host and settings.smtp_from_address)


def _send_blocking(to: str, subject: str, html_body: str) -> bool:
    msg = MIMEText(html_body, "html")
    msg["Subject"] = subject
    msg["From"] = settings.smtp_from_address
    msg["To"] = to
    try:
        with smtplib.SMTP(settings.smtp_host, settings.smtp_port, timeout=10) as smtp:
            smtp.starttls()
            if settings.smtp_user and settings.smtp_password:
                smtp.login(settings.smtp_user, settings.smtp_password)
            smtp.send_message(msg)
        return True
    except Exception:
        logger.exception("Email send to %s failed", to)
        return False


async def send_html(to: str, subject: str, html_body: str) -> bool:
    """Best-effort — never raises. Returns whether it actually sent."""
    if not configured():
        return False
    return await asyncio.to_thread(_send_blocking, to, subject, html_body)
