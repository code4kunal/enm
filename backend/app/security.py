from __future__ import annotations

import hashlib
import secrets
from datetime import UTC, datetime, timedelta
from typing import Any, Literal

import bcrypt
import jwt

from app.config import settings
from app.errors import Unauthorized

TokenType = Literal["access", "refresh"]


# --- passwords -------------------------------------------------------------


def hash_password(raw: str) -> str:
    return bcrypt.hashpw(
        raw.encode("utf-8"), bcrypt.gensalt(rounds=settings.bcrypt_rounds)
    ).decode("utf-8")


def verify_password(raw: str, hashed: str | None) -> bool:
    if not hashed:
        return False
    try:
        return bcrypt.checkpw(raw.encode("utf-8"), hashed.encode("utf-8"))
    except ValueError:
        return False


# --- access tokens ---------------------------------------------------------


def create_access_token(user_id: str, role: str) -> str:
    now = datetime.now(UTC)
    payload = {
        "sub": user_id,
        "role": role,
        "typ": "access",
        "iat": int(now.timestamp()),
        "exp": int(
            (now + timedelta(seconds=settings.access_token_ttl_seconds)).timestamp()
        ),
        "jti": secrets.token_hex(8),
    }
    return jwt.encode(payload, settings.jwt_secret, algorithm=settings.jwt_algorithm)


def decode_access_token(token: str) -> dict[str, Any]:
    try:
        payload = jwt.decode(
            token, settings.jwt_secret, algorithms=[settings.jwt_algorithm]
        )
    except jwt.ExpiredSignatureError as exc:
        raise Unauthorized("Session expired, please sign in again") from exc
    except jwt.InvalidTokenError as exc:
        raise Unauthorized("Invalid authentication token") from exc
    if payload.get("typ") != "access":
        raise Unauthorized("Invalid authentication token")
    return payload


# --- refresh tokens (opaque, stored hashed) --------------------------------


def new_refresh_token() -> tuple[str, str, datetime]:
    """Return (raw_token, sha256_hash, expires_at)."""
    raw = secrets.token_urlsafe(48)
    expires_at = datetime.now(UTC) + timedelta(
        seconds=settings.refresh_token_ttl_seconds
    )
    return raw, hash_refresh_token(raw), expires_at


def hash_refresh_token(raw: str) -> str:
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def generate_temp_password(length: int = 10) -> str:
    alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789"
    return "".join(secrets.choice(alphabet) for _ in range(length))
