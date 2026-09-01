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


async def exchange_code_for_id_token(
    *, code: str, redirect_uri: str, code_verifier: str
) -> str:
    """Redeem an authorization code server-side, as a confidential client.

    Only needed while the app registration's redirect URI is typed "Web" —
    Azure returns AADSTS9002326 if a browser tries this directly against a
    Web-typed URI, since that platform type assumes a server holds the
    secret. `code_verifier` still travels with the request (PKCE remains a
    real defence even alongside a secret); `ms_client_secret` is what makes
    this call itself trusted.
    """
    if not settings.ms_tenant_id or not settings.ms_client_id:
        raise ValidationError(
            "Microsoft SSO is not configured on this server",
            {"code": "sso_not_configured"},
        )
    if not settings.ms_client_secret:
        raise ValidationError(
            "Server-side Microsoft token exchange is not configured",
            {"code": "sso_exchange_not_configured"},
        )
    url = f"https://login.microsoftonline.com/{settings.ms_tenant_id}/oauth2/v2.0/token"
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.post(
                url,
                data={
                    "grant_type": "authorization_code",
                    "client_id": settings.ms_client_id,
                    "client_secret": settings.ms_client_secret,
                    "code": code,
                    "redirect_uri": redirect_uri,
                    "code_verifier": code_verifier,
                },
            )
    except httpx.HTTPError as exc:
        raise Unauthorized("Could not reach Microsoft to complete sign-in") from exc

    body = resp.json() if resp.headers.get("content-type", "").startswith(
        "application/json"
    ) else {}
    if resp.status_code >= 400:
        detail = body.get("error_description") or body.get("error") or resp.text
        raise Unauthorized(f"Microsoft rejected the sign-in: {detail}")

    id_token = body.get("id_token")
    if not isinstance(id_token, str) or not id_token:
        raise Unauthorized("Microsoft returned no id_token for this sign-in")
    return id_token
