from __future__ import annotations

from datetime import UTC, datetime
from typing import Annotated, Literal

from fastapi import APIRouter, Query, status
from sqlalchemy import func, or_, select, update

from app.deps import ManagerUser, PageDep, SessionDep
from app.errors import Conflict, Forbidden, NotFound, ValidationError
from app.models.enums import AuditAction, Role
from app.models.master import Site
from app.models.user import RefreshToken, User, UserSiteAccess
from app.schemas.common import Page
from app.schemas.user import (
    ResetPasswordIn,
    TempPasswordOut,
    UserCreate,
    UserCreatedOut,
    UserOut,
    UserUpdate,
)
from app.security import generate_temp_password, hash_password
from app.services import audit, notifications

router = APIRouter(prefix="/admin/users", tags=["admin"])

StatusQ = Literal["all", "active", "inactive"]


def _out(user: User) -> UserOut:
    return UserOut(
        id=user.id,
        name=user.name,
        user_id=user.user_id,
        email=user.email,
        role=user.role,
        site_access=user.site_access,
        governs_all_sites=user.is_super_admin,
        permissions=sorted(user.permissions),
        is_active=user.is_active,
        must_reset_password=user.must_reset_password,
        created_at=user.created_at,
        last_login_at=user.last_login_at,
    )


def _created_out(user: User, temp_password: str | None) -> UserCreatedOut:
    return UserCreatedOut(**_out(user).model_dump(), temp_password=temp_password)


async def _assert_sites_exist(session: SessionDep, codes: list[str]) -> None:
    if not codes:
        return
    found = set(
        (await session.scalars(select(Site.code).where(Site.code.in_(codes)))).all()
    )
    missing = [c for c in codes if c not in found]
    if missing:
        raise ValidationError(
            f"Unknown site(s): {', '.join(missing)}",
            {"site_access": "unknown site code"},
        )


def _assert_can_grant(actor: User, role: Role) -> None:
    if not actor.can_grant(role):
        raise Forbidden(
            f"A {actor.role.value} cannot create a {role.value}",
            {"role": "not grantable by your role"},
        )


def _assert_sites_within_reach(actor: User, codes: list[str]) -> None:
    """A manager staffs its own sites only; a super admin reaches every site."""
    if actor.is_super_admin:
        return
    outside = [c for c in codes if c not in actor.accessible_sites]
    if outside:
        raise Forbidden(
            f"You have no access to {', '.join(outside)}",
            {"site_access": "outside your sites"},
        )


async def _assert_not_last_super_admin(session: SessionDep, user: User) -> None:
    """The last active super admin may not be deactivated or demoted."""
    if user.role is not Role.super_admin or not user.is_active:
        return
    remaining = await session.scalar(
        select(func.count())
        .select_from(User)
        .where(
            User.role == Role.super_admin,
            User.is_active.is_(True),
            User.id != user.id,
        )
    )
    if not remaining:
        raise Conflict(
            "This is the last active super admin — promote another one first",
            {"role": "last super admin"},
        )


async def _assert_unique(
    session: SessionDep,
    *,
    user_id: str | None,
    email: str | None,
    exclude_id: str | None = None,
) -> None:
    if user_id:
        stmt = select(User.id).where(User.user_id == user_id)
        if exclude_id:
            stmt = stmt.where(User.id != exclude_id)
        if await session.scalar(stmt):
            raise Conflict("User ID already exists", {"user_id": "duplicate"})
    if email:
        stmt = select(User.id).where(User.email == email)
        if exclude_id:
            stmt = stmt.where(User.id != exclude_id)
        if await session.scalar(stmt):
            raise Conflict("Email already exists", {"email": "duplicate"})


async def _load(session: SessionDep, user_id: str) -> User:
    user = await session.get(User, user_id)
    if user is None:
        raise NotFound("User not found")
    return user


async def _revoke_sessions(session: SessionDep, user_id: str) -> None:
    await session.execute(
        update(RefreshToken)
        .where(RefreshToken.user_id == user_id, RefreshToken.revoked_at.is_(None))
        .values(revoked_at=datetime.now(UTC))
    )


@router.get("", response_model=Page[UserOut])
async def list_users(
    actor: ManagerUser,
    session: SessionDep,
    page: PageDep,
    status_filter: Annotated[StatusQ, Query(alias="status")] = "all",
    q: Annotated[str | None, Query(max_length=120)] = None,
) -> Page[UserOut]:
    """Every user for a super admin; users on the caller's sites otherwise."""
    stmt = select(User)
    if not actor.is_super_admin:
        reachable = select(UserSiteAccess.user_id).where(
            UserSiteAccess.site_code.in_(sorted(actor.accessible_sites) or [""])
        )
        stmt = stmt.where(or_(User.id.in_(reachable), User.id == actor.id))
    if status_filter == "active":
        stmt = stmt.where(User.is_active.is_(True))
    elif status_filter == "inactive":
        stmt = stmt.where(User.is_active.is_(False))
    if q:
        needle = f"%{q.strip().lower()}%"
        stmt = stmt.where(
            or_(
                func.lower(User.name).like(needle),
                func.lower(User.user_id).like(needle),
                func.lower(User.email).like(needle),
            )
        )

    total = int(
        await session.scalar(
            select(func.count()).select_from(stmt.with_only_columns(User.id).subquery())
        )
        or 0
    )
    rows = (
        await session.scalars(
            stmt.order_by(User.is_active.desc(), User.name)
            .offset(page.offset)
            .limit(page.page_size)
        )
    ).unique().all()
    return Page[UserOut](
        items=[_out(u) for u in rows],
        page=page.page,
        page_size=page.page_size,
        total=total,
    )


@router.post("", response_model=UserCreatedOut, status_code=status.HTTP_201_CREATED)
async def create_user(
    payload: UserCreate, actor: ManagerUser, session: SessionDep
) -> UserCreatedOut:
    _assert_can_grant(actor, payload.role)

    # A super admin's site_access is empty and ignored — it reaches every site.
    site_access = [] if payload.role is Role.super_admin else payload.site_access
    if payload.role is not Role.super_admin and not site_access:
        raise ValidationError(
            "Give the user at least one site", {"site_access": "required"}
        )
    _assert_sites_within_reach(actor, site_access)
    await _assert_sites_exist(session, site_access)

    email = payload.email.lower() if payload.email else None
    await _assert_unique(session, user_id=payload.user_id, email=email)

    # The password is echoed exactly once; the admin reads it aloud and it is
    # never retrievable again.
    temp_password = payload.temp_password or generate_temp_password()

    user = User(
        name=payload.name,
        user_id=payload.user_id,
        email=email,
        role=payload.role,
        password_hash=hash_password(temp_password),
        must_reset_password=True,
        site_links=[UserSiteAccess(site_code=c) for c in site_access],
    )
    session.add(user)
    await session.flush()
    await audit.record(
        session,
        actor_id=actor.id,
        action=AuditAction.user_created,
        object_type="user",
        object_id=user.id,
        after={"user_id": user.user_id, "role": user.role.value},
    )
    await session.commit()
    await session.refresh(user)
    return _created_out(user, temp_password)


@router.put("/{user_id}", response_model=UserOut)
async def update_user(
    user_id: str, payload: UserUpdate, actor: ManagerUser, session: SessionDep
) -> UserOut:
    user = await _load(session, user_id)
    before = {
        "name": user.name,
        "user_id": user.user_id,
        "email": user.email,
        "role": user.role.value,
        "site_access": user.site_access,
    }
    _assert_sites_within_reach(actor, user.site_access)

    email = payload.email.lower() if payload.email else None
    await _assert_unique(
        session, user_id=payload.user_id, email=email, exclude_id=user.id
    )

    if payload.role is not None and payload.role is not user.role:
        _assert_can_grant(actor, payload.role)
        await _assert_not_last_super_admin(session, user)
        user.role = payload.role

    if payload.name is not None:
        user.name = payload.name
    if payload.user_id is not None:
        user.user_id = payload.user_id
    if "email" in payload.model_fields_set:
        user.email = email

    if user.role is Role.super_admin:
        # Its list is meaningless; keeping stale codes around would only mislead.
        user.site_links.clear()
    elif payload.site_access is not None:
        _assert_sites_within_reach(actor, payload.site_access)
        await _assert_sites_exist(session, payload.site_access)
        user.site_links.clear()
        await session.flush()
        user.site_links = [
            UserSiteAccess(site_code=c) for c in payload.site_access
        ]
    user.updated_at = datetime.now(UTC)

    await audit.record(
        session,
        actor_id=actor.id,
        action=AuditAction.user_updated,
        object_type="user",
        object_id=user.id,
        before=before,
        after={
            "name": user.name,
            "user_id": user.user_id,
            "email": user.email,
            "role": user.role.value,
            "site_access": user.site_access,
        },
    )
    await session.commit()
    await session.refresh(user)
    return _out(user)


@router.post("/{user_id}/deactivate", response_model=UserOut)
async def deactivate_user(
    user_id: str, actor: ManagerUser, session: SessionDep
) -> UserOut:
    user = await _load(session, user_id)
    if user.id == actor.id:
        raise Conflict("You cannot deactivate your own account")
    _assert_sites_within_reach(actor, user.site_access)
    if not user.is_active:
        return _out(user)
    await _assert_not_last_super_admin(session, user)

    user.is_active = False
    user.updated_at = datetime.now(UTC)
    await _revoke_sessions(session, user.id)
    await audit.record(
        session,
        actor_id=actor.id,
        action=AuditAction.user_deactivated,
        object_type="user",
        object_id=user.id,
    )
    await session.commit()
    await session.refresh(user)
    return _out(user)


@router.post("/{user_id}/activate", response_model=UserOut)
async def activate_user(
    user_id: str, actor: ManagerUser, session: SessionDep
) -> UserOut:
    user = await _load(session, user_id)
    _assert_sites_within_reach(actor, user.site_access)
    user.is_active = True
    user.updated_at = datetime.now(UTC)
    await audit.record(
        session,
        actor_id=actor.id,
        action=AuditAction.user_activated,
        object_type="user",
        object_id=user.id,
    )
    await notifications.notify_account_event(
        session,
        user,
        "Account reactivated",
        "Your Transvolt E&M account has been reactivated.",
    )
    await session.commit()
    await session.refresh(user)
    return _out(user)


@router.post("/{user_id}/reset-password", response_model=TempPasswordOut)
async def reset_password(
    user_id: str,
    actor: ManagerUser,
    session: SessionDep,
    payload: ResetPasswordIn | None = None,
) -> TempPasswordOut:
    """Returns the new password once — it is never retrievable again."""
    user = await _load(session, user_id)
    _assert_sites_within_reach(actor, user.site_access)

    temp_password = (payload.temp_password if payload else None) or (
        generate_temp_password()
    )
    user.password_hash = hash_password(temp_password)
    user.must_reset_password = True
    user.updated_at = datetime.now(UTC)
    await _revoke_sessions(session, user.id)
    await audit.record(
        session,
        actor_id=actor.id,
        action=AuditAction.user_password_reset,
        object_type="user",
        object_id=user.id,
    )
    await session.commit()
    return TempPasswordOut(temp_password=temp_password)
