from __future__ import annotations

import hashlib
import secrets
from dataclasses import dataclass
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


def create_access_token(
    user_id: str,
    role: str,
    *,
    platform_grants: dict[str, Any] | None = None,
) -> str:
    """An E&M session token.

    `platform_grants` carries what siteops-platform said when it checked the
    password: the roles, permissions and site ids it granted. E&M signs them
    into its own token so the session survives a refresh — the platform's
    `/auth/refresh` re-issues with `roles=["user"]` and no permissions at all,
    which would silently strip a mechanic of everything mid-shift.

    The grants are trustworthy because this signature is ours: the claims
    were read from an authenticated platform reply, never from a client.
    """
    now = datetime.now(UTC)
    payload: dict[str, Any] = {
        "sub": user_id,
        "role": role,
        "typ": "access",
        "iat": int(now.timestamp()),
        "exp": int(
            (now + timedelta(seconds=settings.access_token_ttl_seconds)).timestamp()
        ),
        "jti": secrets.token_hex(8),
    }
    if platform_grants is not None:
        payload.update(
            {
                "src": PLATFORM_ISSUER,
                "user_name": platform_grants.get("user_name") or "",
                "roles": list(platform_grants.get("roles") or []),
                "permissions": list(platform_grants.get("permissions") or []),
                "site_ids": list(platform_grants.get("site_ids") or []),
            }
        )
    return jwt.encode(payload, settings.jwt_secret, algorithm=settings.jwt_algorithm)


#: An E&M-issued token: the break-glass local admin and any account that
#: predates the platform integration. Authorised from its `role` column.
LOCAL_ISSUER = "enm"
#: A siteops-platform token. Authorised strictly from its claims — the roles,
#: permissions and site_ids the platform granted at login.
PLATFORM_ISSUER = "siteops"


@dataclass(frozen=True, slots=True)
class DecodedToken:
    payload: dict[str, Any]
    issuer: str

    @property
    def is_platform(self) -> bool:
        return self.issuer == PLATFORM_ISSUER


def _decode_with(token: str, secret: str, *, type_keys: tuple[str, ...]) -> dict[str, Any]:
    """Decode and verify, or raise `jwt.InvalidTokenError`.

    Both issuers stamp the token type; they simply spell the claim
    differently (`typ` here, `type` on the platform). A refresh token
    presented as a bearer must not authenticate anybody.
    """
    payload = jwt.decode(token, secret, algorithms=[settings.jwt_algorithm])
    kind = next((payload[k] for k in type_keys if k in payload), None)
    if kind != "access":
        raise jwt.InvalidTokenError("not an access token")
    if not payload.get("sub"):
        raise jwt.InvalidTokenError("no subject")
    return payload


def decode_access_token(token: str) -> DecodedToken:
    """Verify a bearer token against both issuers we accept.

    The signature is always checked. There is no unverified path: a token we
    cannot verify is a token somebody minted themselves, and the claims it
    carries — role, permissions, site_ids — are exactly what an attacker
    would choose.

    Local first because it is the cheaper, commoner case in tests and for the
    break-glass admin; the platform secret is tried only when the local one
    does not match, so the two never have to agree on a claim vocabulary.
    """
    try:
        return DecodedToken(
            _decode_with(token, settings.jwt_secret, type_keys=("typ", "type")),
            LOCAL_ISSUER,
        )
    except jwt.ExpiredSignatureError as exc:
        raise Unauthorized("Session expired, please sign in again") from exc
    except jwt.InvalidTokenError:
        pass

    if not settings.siteops_jwt_secret:
        raise Unauthorized("Invalid authentication token")

    try:
        return DecodedToken(
            _decode_with(
                token, settings.siteops_jwt_secret, type_keys=("type", "typ")
            ),
            PLATFORM_ISSUER,
        )
    except jwt.ExpiredSignatureError as exc:
        raise Unauthorized("Session expired, please sign in again") from exc
    except jwt.InvalidTokenError as exc:
        raise Unauthorized("Invalid authentication token") from exc


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
