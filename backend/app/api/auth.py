from __future__ import annotations

import logging
import uuid
from datetime import UTC, datetime

from fastapi import APIRouter, Request, status
from sqlalchemy import select, update

from app.claims import PlatformClaims
from app.config import settings
from app.deps import CurrentUser, SessionDep
from app.errors import InactiveUser, NotFound, Unauthorized, ValidationError
from app.models.user import RefreshToken, User
from app.schemas.auth import (
    LoginIn,
    RefreshIn,
    SSOConfigOut,
    SSOLoginIn,
    TokenOut,
)
from app.schemas.user import ChangePasswordIn, UserOut
from app.security import (
    create_access_token,
    hash_password,
    hash_refresh_token,
    new_refresh_token,
    verify_password,
)
from app.services import platform_identity, siteops
from app.services.siteops import SiteOpsUnavailable
from app.services.sso import verify_ms_id_token

logger = logging.getLogger("enm")

router = APIRouter(prefix="/auth", tags=["auth"])


def _user_out(user: User) -> UserOut:
    return UserOut(
        id=user.id,
        name=user.name,
        user_id=user.user_id,
        email=user.email,
        role=user.role,
        site_access=sorted(user.accessible_sites),
        governs_all_sites=user.is_super_admin,
        permissions=sorted(user.permissions),
        is_active=user.is_active,
        must_reset_password=user.must_reset_password,
        is_platform_managed=user.password_hash is None,
        created_at=user.created_at,
        last_login_at=user.last_login_at,
    )


async def issue_tokens(
    session: SessionDep,
    user: User,
    user_agent: str | None,
    grants: dict[str, object] | None = None,
) -> TokenOut:
    """Start an E&M session for an already-authenticated user.

    `grants` is what siteops-platform returned about them — roles,
    permissions, site ids. Signed into the access token so every later
    request is authorised from the platform's decision rather than from
    E&M's own `role` column.
    """
    raw, token_hash, expires_at = new_refresh_token()
    session.add(
        RefreshToken(
            user_id=user.id,
            token_hash=token_hash,
            expires_at=expires_at,
            user_agent=(user_agent or "")[:255] or None,
        )
    )
    user.last_login_at = datetime.now(UTC)
    await session.commit()
    if grants is not None:
        await _attach(session, user, grants)
    return TokenOut(
        access_token=create_access_token(
            user.id, user.role.value, platform_grants=grants
        ),
        refresh_token=raw,
        expires_in=settings.access_token_ttl_seconds,
        user=_user_out(user),
    )


async def _attach(session: SessionDep, user: User, grants: dict[str, object]) -> None:
    """Bind platform grants to the user row for the rest of this request, so
    `/auth/login` reports the same permissions the token carries."""
    claims = PlatformClaims.from_payload(
        {
            "sub": user.id,
            "user_name": grants.get("user_name") or user.user_id,
            "roles": grants.get("roles") or [],
            "permissions": grants.get("permissions") or [],
            "site_ids": grants.get("site_ids") or [],
        }
    )
    user.attach_claims(
        claims, await platform_identity.site_codes_for(session, claims.site_ids)
    )


def _grants_from_login(data: dict) -> dict[str, object]:
    return {
        "user_name": data.get("username") or "",
        "roles": data.get("roles") or [],
        "permissions": data.get("permissions") or [],
        "site_ids": data.get("site_ids") or [],
    }


async def _platform_login(handle: str, password: str) -> dict | None:
    """Ask the platform, tolerating either spelling of the handle.

    Ground staff type `TV4021`; the platform stores usernames as entered
    there, which for the accounts we have seen is lowercase. One retry is
    cheaper than a support call about capital letters.
    """
    if not settings.platform_login_enabled:
        return None
    try:
        data = await siteops.login(handle, password)
        if data is None and handle != handle.lower():
            data = await siteops.login(handle.lower(), password)
        return data
    except SiteOpsUnavailable as exc:
        # Not a rejection. Fall through to the local account so a platform
        # outage cannot lock a depot out of its own maintenance records.
        logger.warning("SiteOps login unavailable, falling back to local: %s", exc)
        return None


@router.post("/login", response_model=TokenOut)
async def login(payload: LoginIn, request: Request, session: SessionDep) -> TokenOut:
    """Sign in.

    siteops-platform is the identity authority: it owns the password and
    decides the roles, permissions and sites. E&M asks it first and, when it
    says yes, keeps a shadow row for authorship and issues its own session
    carrying the platform's grants.

    The local password path below is what remains of E&M's own accounts —
    the break-glass admin, and anyone not yet migrated to the platform.
    """
    handle = payload.user_id.strip()
    data = await _platform_login(handle, payload.password)

    if data is not None:
        sub = str(data.get("user_id") or "").strip()
        if not sub:
            raise Unauthorized("SiteOps returned no user id for this account")
        user = await platform_identity.ensure_user(
            session,
            sub=sub,
            user_name=str(data.get("username") or handle),
            name=str(data.get("full_name") or "") or None,
            email=str(data.get("email") or "") or None,
        )
        if not user.is_active:
            raise InactiveUser("Account deactivated, contact site manager")
        return await issue_tokens(
            session,
            user,
            request.headers.get("User-Agent"),
            grants=_grants_from_login(data),
        )

    user = await session.scalar(
        select(User).where(User.user_id == handle.upper())
    )
    if user is None or not verify_password(payload.password, user.password_hash):
        raise Unauthorized("Invalid User ID or password")
    if not user.is_active:
        raise InactiveUser("Account deactivated, contact site manager")
    return await issue_tokens(session, user, request.headers.get("User-Agent"))


@router.get("/sso/config", response_model=SSOConfigOut)
async def sso_config() -> SSOConfigOut:
    """Whether this deployment offers Microsoft sign-in, and against what.

    Public: it carries only the tenant and client identifiers that appear in
    every authorize URL anyway, and the sign-in screen has to know this before
    anyone could possibly have a token.

    Served rather than compiled into the client so one build works against a
    site that has SSO and one that does not, and so the button can hide itself
    instead of failing when somebody taps it.
    """
    if not settings.sso_enabled:
        return SSOConfigOut(enabled=False)
    return SSOConfigOut(
        enabled=True,
        tenant_id=settings.ms_tenant_id,
        client_id=settings.ms_client_id,
        authority=f"https://login.microsoftonline.com/{settings.ms_tenant_id}",
    )


@router.post("/sso", response_model=TokenOut)
async def sso_login(
    payload: SSOLoginIn, request: Request, session: SessionDep
) -> TokenOut:
    """Sign in with a verified Microsoft identity.

    A local row wins first — the break-glass admin, or anyone predating the
    integration. Otherwise SiteOps is asked whether this email belongs to
    one of its people and, if so, a shadow row is provisioned the same way
    a password login provisions one. A live Microsoft sign-in is at least
    as strong a proof of identity as SiteOps's own password check, so an
    adopted local account is left as is (`source="login"`, the default) —
    not converted to platform-managed.
    """
    claims = verify_ms_id_token(payload.ms_id_token)
    email = claims["_email"]
    user = await session.scalar(select(User).where(User.email == email))
    if user is not None:
        if not user.is_active:
            raise InactiveUser("Account deactivated, contact site manager")
        return await issue_tokens(session, user, request.headers.get("User-Agent"))

    person = await siteops.find_user_by_email(email)
    if person is None:
        raise NotFound(f"No E&M user record found for {email}")
    sub = str(person.get("id") or "").strip()
    if not sub:
        raise NotFound(f"No E&M user record found for {email}")

    username = str(person.get("username") or "").strip()
    provisioned = await platform_identity.ensure_user(
        session,
        sub=sub,
        user_name=username or email,
        name=str(person.get("full_name") or "") or None,
        email=email,
    )
    if not provisioned.is_active:
        raise InactiveUser("Account deactivated, contact site manager")

    grants_data = await siteops.user_grants(sub)
    grants = {
        "user_name": username,
        "roles": (grants_data or {}).get("roles") or [],
        "permissions": (grants_data or {}).get("permissions") or [],
        "site_ids": await siteops.user_site_ids(sub),
    }
    return await issue_tokens(
        session, provisioned, request.headers.get("User-Agent"), grants=grants
    )


async def _regrant(user: User) -> dict[str, object] | None:
    """Re-read a platform user's grants when their session is refreshed.

    Refreshing must not be a way to keep permissions that were revoked
    yesterday, nor to lose ones granted this morning. Only accounts with no
    local password are asked about — everything else is an E&M-local account
    the platform has never heard of.
    """
    if user.password_hash is not None:
        return None
    try:
        sub = str(uuid.UUID(hex=user.id))
    except ValueError:
        return None

    grants = await siteops.user_grants(sub)
    if grants is None:
        return None
    return {
        "user_name": user.user_id.lower(),
        "roles": grants.get("roles") or [],
        "permissions": grants.get("permissions") or [],
        "site_ids": await siteops.user_site_ids(sub),
    }


@router.post("/refresh", response_model=TokenOut)
async def refresh(
    payload: RefreshIn, request: Request, session: SessionDep
) -> TokenOut:
    token_hash = hash_refresh_token(payload.refresh_token)
    row = await session.scalar(
        select(RefreshToken).where(RefreshToken.token_hash == token_hash)
    )
    now = datetime.now(UTC)
    if row is None or row.revoked_at is not None or row.expires_at <= now:
        raise Unauthorized("Refresh token is invalid or expired")

    user = await session.get(User, row.user_id)
    if user is None:
        raise Unauthorized("Refresh token is invalid or expired")
    if not user.is_active:
        raise InactiveUser("Account deactivated, contact site manager")

    try:
        grants = await _regrant(user)
    except SiteOpsUnavailable as exc:
        # Better a re-login than a session that silently comes back with no
        # permissions and fails every screen it opens.
        raise Unauthorized(
            "Cannot reach SiteOps to renew this session, please sign in again"
        ) from exc

    # rotate: the presented token is burned, a fresh one is issued
    row.revoked_at = now
    return await issue_tokens(
        session, user, request.headers.get("User-Agent"), grants=grants
    )


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT, response_model=None)
async def logout(payload: RefreshIn, session: SessionDep) -> None:
    await session.execute(
        update(RefreshToken)
        .where(
            RefreshToken.token_hash == hash_refresh_token(payload.refresh_token),
            RefreshToken.revoked_at.is_(None),
        )
        .values(revoked_at=datetime.now(UTC))
    )
    await session.commit()


@router.get("/me", response_model=UserOut)
async def me(user: CurrentUser) -> UserOut:
    return _user_out(user)


@router.post("/change-password", status_code=status.HTTP_204_NO_CONTENT, response_model=None)
async def change_password(
    payload: ChangePasswordIn, user: CurrentUser, session: SessionDep
) -> None:
    if not verify_password(payload.current_password, user.password_hash):
        raise ValidationError(
            "Current password is incorrect", {"current_password": "incorrect"}
        )
    user.password_hash = hash_password(payload.new_password)
    user.must_reset_password = False
    user.updated_at = datetime.now(UTC)
    # force re-login on other devices
    await session.execute(
        update(RefreshToken)
        .where(RefreshToken.user_id == user.id, RefreshToken.revoked_at.is_(None))
        .values(revoked_at=datetime.now(UTC))
    )
    await session.commit()
