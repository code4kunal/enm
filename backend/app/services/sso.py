from __future__ import annotations

import time
from typing import Any

import httpx
import jwt
from jwt import PyJWKClient

from app.config import settings
from app.errors import Unauthorized, ValidationError

_jwks_client: PyJWKClient | None = None
_jwks_fetched_at: float = 0.0


def _client() -> PyJWKClient:
    """Cache the JWKS client; PyJWKClient itself caches signing keys."""
    global _jwks_client, _jwks_fetched_at
    if not settings.ms_jwks_url:
        raise ValidationError(
            "Microsoft SSO is not configured on this server",
            {"ms_id_token": "sso_not_configured"},
        )
    now = time.time()
    if _jwks_client is None or now - _jwks_fetched_at > settings.ms_jwks_cache_seconds:
        _jwks_client = PyJWKClient(
            settings.ms_jwks_url, cache_keys=True, lifespan=settings.ms_jwks_cache_seconds
        )
        _jwks_fetched_at = now
    return _jwks_client


def verify_ms_id_token(id_token: str) -> dict[str, Any]:
    """Validate an Entra ID id_token: signature (JWKS), issuer, audience, exp."""
    if not settings.ms_client_id:
        raise ValidationError(
            "Microsoft SSO is not configured on this server",
            {"ms_id_token": "sso_not_configured"},
        )
    try:
        signing_key = _client().get_signing_key_from_jwt(id_token)
        claims = jwt.decode(
            id_token,
            signing_key.key,
            algorithms=["RS256"],
            audience=settings.ms_client_id,
            issuer=settings.ms_issuer,
            options={"require": ["exp", "iss", "aud"]},
        )
    except (jwt.InvalidTokenError, httpx.HTTPError) as exc:
        raise Unauthorized("Microsoft sign-in could not be verified") from exc
    except Exception as exc:  # JWKS fetch/parse failures
        raise Unauthorized("Microsoft sign-in could not be verified") from exc

    email = (
        claims.get("email")
        or claims.get("preferred_username")
        or claims.get("upn")
        or ""
    ).strip().lower()
    if not email:
        raise Unauthorized("Microsoft token carries no email claim")
    claims["_email"] = email
    return claims
