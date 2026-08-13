from __future__ import annotations

from datetime import UTC, datetime

from fastapi import APIRouter, Request, status
from sqlalchemy import select, update

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
from app.services.sso import verify_ms_id_token

router = APIRouter(prefix="/auth", tags=["auth"])


def _user_out(user: User) -> UserOut:
    return UserOut(
        id=user.id,
        name=user.name,
        user_id=user.user_id,
        email=user.email,
        role=user.role,
        site_access=user.site_access,
        is_active=user.is_active,
        must_reset_password=user.must_reset_password,
        created_at=user.created_at,
        last_login_at=user.last_login_at,
    )


async def issue_tokens(
    session: SessionDep, user: User, user_agent: str | None
) -> TokenOut:
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
    return TokenOut(
        access_token=create_access_token(user.id, user.role.value),
        refresh_token=raw,
        expires_in=settings.access_token_ttl_seconds,
        user=_user_out(user),
    )


@router.post("/login", response_model=TokenOut)
async def login(payload: LoginIn, request: Request, session: SessionDep) -> TokenOut:
    handle = payload.user_id.strip().upper()
    user = await session.scalar(select(User).where(User.user_id == handle))
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
    claims = verify_ms_id_token(payload.ms_id_token)
    email = claims["_email"]
    user = await session.scalar(select(User).where(User.email == email))
    if user is None:
        raise NotFound(f"No E&M user record found for {email}")
    if not user.is_active:
        raise InactiveUser("Account deactivated, contact site manager")
    return await issue_tokens(session, user, request.headers.get("User-Agent"))


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

    # rotate: the presented token is burned, a fresh one is issued
    row.revoked_at = now
    return await issue_tokens(session, user, request.headers.get("User-Agent"))


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
