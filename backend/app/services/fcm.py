from __future__ import annotations

import asyncio
import logging
from typing import Any

from app.config import settings

logger = logging.getLogger("enm.fcm")

_app: Any = None
_init_attempted = False


def _init() -> Any:
    """Lazily initialize firebase-admin. Absent credentials => push disabled,
    in-app notifications still persist."""
    global _app, _init_attempted
    if _init_attempted:
        return _app
    _init_attempted = True

    if not settings.fcm_credentials_file:
        logger.info("FCM credentials not configured; push delivery disabled")
        return None
    try:
        import firebase_admin
        from firebase_admin import credentials

        cred = credentials.Certificate(settings.fcm_credentials_file)
        _app = firebase_admin.initialize_app(
            cred,
            {"projectId": settings.fcm_project_id} if settings.fcm_project_id else None,
        )
        logger.info("FCM initialized")
    except Exception:
        logger.exception("FCM initialization failed; push delivery disabled")
        _app = None
    return _app


def _send_blocking(
    tokens: list[str], title: str, body: str, data: dict[str, str]
) -> list[str]:
    """Return the list of tokens FCM rejected as permanently invalid."""
    if not _init():
        return []
    from firebase_admin import messaging

    message = messaging.MulticastMessage(
        tokens=tokens,
        notification=messaging.Notification(title=title, body=body),
        data={k: str(v) for k, v in data.items()},
        android=messaging.AndroidConfig(
            priority="high",
            notification=messaging.AndroidNotification(
                channel_id="enm_alerts", sound="default"
            ),
        ),
        apns=messaging.APNSConfig(
            payload=messaging.APNSPayload(
                aps=messaging.Aps(sound="default", badge=1)
            )
        ),
    )
    dead: list[str] = []
    try:
        response = messaging.send_each_for_multicast(message)
    except Exception:
        logger.exception("FCM multicast failed")
        return []

    for token, result in zip(tokens, response.responses, strict=False):
        if result.success:
            continue
        err = getattr(result.exception, "code", "") or str(result.exception)
        if "registration-token-not-registered" in str(err) or "invalid-argument" in str(
            err
        ):
            dead.append(token)
        else:
            logger.warning("FCM send failed for one token: %s", err)
    return dead


async def send_push(
    tokens: list[str], *, title: str, body: str, data: dict[str, str]
) -> list[str]:
    """Send to up to 500 tokens per call. Returns permanently-dead tokens."""
    if not tokens or not settings.notifications_enabled:
        return []
    dead: list[str] = []
    for i in range(0, len(tokens), 500):
        batch = tokens[i : i + 500]
        dead += await asyncio.to_thread(_send_blocking, batch, title, body, data)
    return dead
