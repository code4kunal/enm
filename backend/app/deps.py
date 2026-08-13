from __future__ import annotations

from dataclasses import dataclass
from typing import Annotated

from fastapi import Depends, Query, Request
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.db import get_session
from app.errors import Forbidden, InactiveUser, Unauthorized
from app.models.enums import Role
from app.models.user import User
from app.security import decode_access_token

SessionDep = Annotated[AsyncSession, Depends(get_session)]


def _bearer(request: Request) -> str:
    header = request.headers.get("Authorization", "")
    scheme, _, token = header.partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        raise Unauthorized("Missing or malformed Authorization header")
    return token.strip()


async def current_user(request: Request, session: SessionDep) -> User:
    payload = decode_access_token(_bearer(request))
    user = await session.get(User, payload.get("sub", ""))
    if user is None:
        raise Unauthorized("Invalid authentication token")
    if not user.is_active:
        raise InactiveUser("Account deactivated, contact depot manager")
    return user


CurrentUser = Annotated[User, Depends(current_user)]


async def require_manager(user: CurrentUser) -> User:
    if user.role is not Role.manager:
        raise Forbidden("Manager role required")
    return user


ManagerUser = Annotated[User, Depends(require_manager)]


def assert_depot_access(user: User, depot_code: str) -> str:
    code = depot_code.strip().upper()
    if not user.can_access(code):
        raise Forbidden(f"No access to depot {code}")
    return code


async def depot_param(
    user: CurrentUser,
    depot: Annotated[str, Query(min_length=1, max_length=16)],
) -> str:
    """Every scoped endpoint takes `?depot=` and validates it against depot_access."""
    return assert_depot_access(user, depot)


DepotDep = Annotated[str, Depends(depot_param)]


@dataclass(slots=True)
class Pagination:
    page: int
    page_size: int

    @property
    def offset(self) -> int:
        return (self.page - 1) * self.page_size


def pagination(
    page: int = Query(default=1, ge=1),
    page_size: int = Query(
        default=settings.default_page_size, ge=1, le=settings.max_page_size
    ),
) -> Pagination:
    return Pagination(page=page, page_size=page_size)


PageDep = Annotated[Pagination, Depends(pagination)]


async def user_by_id(session: AsyncSession, user_id: str) -> User | None:
    return await session.scalar(select(User).where(User.id == user_id))
