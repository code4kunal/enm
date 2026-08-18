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
    sub_val = payload.get("sub", "")
    user = await session.get(User, sub_val)
    if user is None:
        user_name = payload.get("user_name") or payload.get("username")
        if user_name:
            username_clean = user_name.strip().upper()
            existing_user = await session.scalar(
                select(User).where(User.user_id == username_clean)
            )
            if existing_user:
                user = existing_user
            else:
                roles = payload.get("roles", [])
                mapped_role = Role.executive
                if "admin" in roles:
                    mapped_role = Role.super_admin
                elif "manager" in roles:
                    mapped_role = Role.manager
                elif "supervisor" in roles:
                    mapped_role = Role.supervisor
                    
                user = User(
                    id=sub_val,
                    name=payload.get("full_name") or payload.get("name") or user_name,
                    user_id=username_clean,
                    email=payload.get("email"),
                    role=mapped_role,
                    password_hash=None,
                    must_reset_password=False,
                )
                session.add(user)
                await session.flush()
                
                if not user.is_super_admin:
                    from app.models.master import Site
                    from app.models.user import UserSiteAccess
                    sites = (await session.scalars(select(Site))).all()
                    for site in sites:
                        session.add(UserSiteAccess(user_id=user.id, site_code=site.code))
                    await session.flush()
                
                await session.commit()
                from sqlalchemy.orm import selectinload
                user = await session.scalar(
                    select(User)
                    .where(User.id == user.id)
                    .options(selectinload(User.site_links))
                )
                
    if user is None:
        raise Unauthorized("Invalid authentication token")
    if not user.is_active:
        raise InactiveUser("Account deactivated, contact site manager")
    return user


CurrentUser = Annotated[User, Depends(current_user)]


async def require_manager(user: CurrentUser) -> User:
    """Site administration: a manager over its own sites, or a super admin."""
    if user.role not in (Role.super_admin, Role.manager):
        raise Forbidden("Manager role required")
    return user


ManagerUser = Annotated[User, Depends(require_manager)]


async def require_super_admin(user: CurrentUser) -> User:
    if not user.is_super_admin:
        raise Forbidden("Super admin role required")
    return user


SuperAdminUser = Annotated[User, Depends(require_super_admin)]


def assert_site_access(user: User, site_code: str) -> str:
    """The only correct way to ask. Never read `site_access` directly — a super
    admin has none and still reaches every site."""
    code = site_code.strip().upper()
    if not user.can_access(code):
        raise Forbidden(f"No access to site {code}")
    return code


def assert_site_admin(user: User, site_code: str) -> str:
    """Maintaining a site's fleet, config and import profiles: super admin
    anywhere, manager on its own sites."""
    code = assert_site_access(user, site_code)
    if user.role not in (Role.super_admin, Role.manager):
        raise Forbidden("Manager role required")
    return code


async def site_param(
    user: CurrentUser,
    site: Annotated[str, Query(min_length=1, max_length=16)],
) -> str:
    """Every scoped endpoint takes `?site=` and validates it against site_access."""
    return assert_site_access(user, site)


SiteDep = Annotated[str, Depends(site_param)]


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
