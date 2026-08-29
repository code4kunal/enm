from __future__ import annotations

from dataclasses import dataclass
from typing import Annotated

from fastapi import Depends, Query, Request
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.claims import PlatformClaims
from app.config import settings
from app.db import get_session
from app.errors import Forbidden, InactiveUser, Unauthorized
from app.models.user import User
from app.security import PLATFORM_ISSUER, decode_access_token
from app.services import platform_identity

SessionDep = Annotated[AsyncSession, Depends(get_session)]


def _bearer(request: Request) -> str:
    header = request.headers.get("Authorization", "")
    scheme, _, token = header.partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        raise Unauthorized("Missing or malformed Authorization header")
    return token.strip()


async def current_user(request: Request, session: SessionDep) -> User:
    """The caller behind a verified bearer token.

    Two shapes reach here, and both are authorised from claims we trust:

    * a token siteops-platform signed, presented directly;
    * a token E&M signed at `/auth/login`, carrying the grants the platform
      returned when it checked the password.

    Anything else is an E&M-local account — the break-glass admin, or one
    predating the integration — authorised from its `role` column.
    """
    token = decode_access_token(_bearer(request))
    claims = (
        PlatformClaims.from_payload(token.payload)
        if token.is_platform or token.payload.get("src") == PLATFORM_ISSUER
        else None
    )

    if claims is not None:
        user = await platform_identity.ensure_user(
            session, sub=claims.sub, user_name=claims.user_name
        )
        user.attach_claims(
            claims, await platform_identity.site_codes_for(session, claims.site_ids)
        )
    else:
        sub = str(token.payload.get("sub", "")).replace("-", "")
        user = await session.get(User, sub)

    if user is None:
        raise Unauthorized("Invalid authentication token")
    if not user.is_active:
        raise InactiveUser("Account deactivated, contact site manager")
    return user


CurrentUser = Annotated[User, Depends(current_user)]


def require_permission(*names: str):
    """Dependency factory: the caller must hold every listed permission.

    The names are E&M's own, declared in `app/permissions.py` and registered
    with siteops-platform at startup, so a platform administrator grants them
    on the role screen alongside every other service's.
    """

    async def _dep(user: CurrentUser) -> User:
        missing = [name for name in names if not user.has_permission(name)]
        if missing:
            raise Forbidden(f"Missing permission: {', '.join(sorted(missing))}")
        return user

    return _dep


async def require_manager(user: CurrentUser) -> User:
    """Site administration: maintaining a site's own configuration."""
    if not user.has_permission("em_user:write"):
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


def assert_site_permission(user: User, site_code: str, permission: str) -> str:
    """Both halves of every write: reach the site, and hold the permission."""
    code = assert_site_access(user, site_code)
    if not user.has_permission(permission):
        raise Forbidden(f"Missing permission: {permission}")
    return code


def assert_site_admin(user: User, site_code: str) -> str:
    """Maintaining a site's fleet, config and import profiles.

    Kept as the coarse gate for surfaces that have not yet been split into
    their own permission; new call sites should name the permission they
    actually need with `assert_site_permission`.
    """
    return assert_site_permission(user, site_code, "em_site_config:write")


async def site_param(
    user: CurrentUser,
    site: Annotated[str, Query(min_length=1, max_length=50)],
) -> str:
    """Every scoped endpoint takes `?site=` and validates it against site_access."""
    return assert_site_access(user, site)


SiteDep = Annotated[str, Depends(site_param)]


def site_reader(permission: str):
    """`?site=` validated against both halves: reach, and the read grant.

    One of these per resource, so a role can be granted the registers without
    the reports. A read grant is cheap to hand out and a depot role will
    usually hold every `em_*:read` — but they are separable, which is the
    point of registering them individually.
    """

    async def _dep(
        user: CurrentUser,
        site: Annotated[str, Query(min_length=1, max_length=50)],
    ) -> str:
        return assert_site_permission(user, site, permission)

    return _dep


EntrySite = Annotated[str, Depends(site_reader("em_entry:read"))]
InspectionSite = Annotated[str, Depends(site_reader("em_inspection:read"))]
ScheduleSite = Annotated[str, Depends(site_reader("em_schedule:read"))]
ReportSite = Annotated[str, Depends(site_reader("em_report:read"))]
ImportSite = Annotated[str, Depends(site_reader("em_import:read"))]
MasterSite = Annotated[str, Depends(site_reader("em_master:read"))]
VehicleSite = Annotated[str, Depends(site_reader("em_vehicle:read"))]
ConfigSite = Annotated[str, Depends(site_reader("em_site_config:read"))]


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
