from __future__ import annotations

from datetime import UTC, datetime
from typing import Annotated, Literal

from fastapi import APIRouter, Query, status
from sqlalchemy import func, or_, select, update

from app.deps import ManagerUser, PageDep, SessionDep
from app.errors import Conflict, NotFound, ValidationError
from app.models.enums import AuditAction
from app.models.master import Depot
from app.models.user import RefreshToken, User, UserDepotAccess
from app.schemas.common import Page
from app.schemas.user import ResetPasswordIn, UserCreate, UserOut, UserUpdate
from app.security import hash_password
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
        depot_access=user.depot_access,
        is_active=user.is_active,
        must_reset_password=user.must_reset_password,
        created_at=user.created_at,
        last_login_at=user.last_login_at,
    )


async def _assert_depots_exist(session: SessionDep, codes: list[str]) -> None:
    found = set(
        (await session.scalars(select(Depot.code).where(Depot.code.in_(codes)))).all()
    )
    missing = [c for c in codes if c not in found]
    if missing:
        raise ValidationError(
            f"Unknown depot(s): {', '.join(missing)}",
            {"depot_access": "unknown depot code"},
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
    _: ManagerUser,
    session: SessionDep,
    page: PageDep,
    status_filter: Annotated[StatusQ, Query(alias="status")] = "all",
    q: Annotated[str | None, Query(max_length=120)] = None,
) -> Page[UserOut]:
    stmt = select(User)
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


@router.post("", response_model=UserOut, status_code=status.HTTP_201_CREATED)
async def create_user(
    payload: UserCreate, actor: ManagerUser, session: SessionDep
) -> UserOut:
    email = payload.email.lower() if payload.email else None
    if email is None and not payload.temp_password:
        raise ValidationError(
            "A temporary password is required for User-ID accounts",
            {"temp_password": "required"},
        )
    await _assert_unique(session, user_id=payload.user_id, email=email)
    await _assert_depots_exist(session, payload.depot_access)

    user = User(
        name=payload.name,
        user_id=payload.user_id,
        email=email,
        role=payload.role,
        password_hash=(
            hash_password(payload.temp_password) if payload.temp_password else None
        ),
        must_reset_password=bool(payload.temp_password),
        depot_links=[UserDepotAccess(depot_code=c) for c in payload.depot_access],
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
    return _out(user)


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
        "depot_access": user.depot_access,
    }
    email = payload.email.lower() if payload.email else None
    await _assert_unique(
        session, user_id=payload.user_id, email=email, exclude_id=user.id
    )

    if payload.name is not None:
        user.name = payload.name
    if payload.user_id is not None:
        user.user_id = payload.user_id
    if "email" in payload.model_fields_set:
        user.email = email
    if payload.role is not None:
        user.role = payload.role
    if payload.depot_access is not None:
        await _assert_depots_exist(session, payload.depot_access)
        user.depot_links.clear()
        await session.flush()
        user.depot_links = [
            UserDepotAccess(depot_code=c) for c in payload.depot_access
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
            "depot_access": payload.depot_access or before["depot_access"],
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
    if not user.is_active:
        return _out(user)

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


@router.post("/{user_id}/reset-password", status_code=status.HTTP_204_NO_CONTENT, response_model=None)
async def reset_password(
    user_id: str, payload: ResetPasswordIn, actor: ManagerUser, session: SessionDep
) -> None:
    user = await _load(session, user_id)
    user.password_hash = hash_password(payload.temp_password)
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
