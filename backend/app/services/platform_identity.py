"""The E&M row behind a siteops-platform identity, and its site reach.

A platform user's privileges live in their token, not in E&M's tables. What
E&M still needs locally is a stable id: `audit_logs.actor_id`, entry
authorship and photo ownership are foreign keys, and they have to point
somewhere that survives the session.

So E&M keeps a shadow row — name, handle, and nothing else that grants
anything. It has no `user_site_access` rows and its `role` column is a label.
Revoking a site or a permission in the platform therefore takes effect on the
next token, with no cleanup to forget here.
"""

from __future__ import annotations

from typing import Literal

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.models.enums import Role
from app.models.master import Site
from app.models.user import User


def local_id(sub: str) -> str:
    """The platform's UUID as E&M stores ids: 32 hex characters, no dashes."""
    return sub.replace("-", "")


class SyncProtectedSuperAdmin(RuntimeError):
    """Raised by `ensure_user(source="sync")` instead of adopting a row.

    A `Role.super_admin` row is the break-glass bootstrap admin. If a SiteOps
    id or handle happens to collide with it, a background sync must not
    adopt it — that would clear its password, and every subsequent field the
    caller writes (role, `is_active`, site access) would then overwrite the
    one account that has to survive SiteOps being wrong or unreachable.

    Every `source="sync"` call site — the nightly roster sync and the
    staff-list dropdown fetch alike — must catch this and treat it as "skip
    this person", not let it propagate.
    """


async def ensure_user(
    session: AsyncSession,
    *,
    sub: str,
    user_name: str,
    name: str | None = None,
    email: str | None = None,
    source: Literal["login", "sync"] = "login",
) -> User:
    """Find or create the shadow row for a platform identity.

    `source="sync"` marks a background reconciliation (the user sync, or the
    staff-list dropdown fetch) rather than a live sign-in. If it adopts a
    pre-existing local-password account by handle, that account is converted
    to platform-managed (password cleared) — a live login already proved the
    password belongs to this person, so `source="login"` leaves it alone.
    """
    handle = (user_name or sub).strip().upper()
    user = await session.get(User, local_id(sub))

    if user is None and user_name:
        # Adopt the local account of the same handle. A depot that signed in
        # as TV4021 before the integration keeps its entries, its audit trail
        # and its authorship instead of starting a second identity.
        user = await session.scalar(select(User).where(User.user_id == handle))

    if user is not None:
        if source == "sync" and user.role is Role.super_admin:
            raise SyncProtectedSuperAdmin(user.id)
        if source == "sync" and user.password_hash is not None:
            user.password_hash = None
            user.must_reset_password = False
            await session.flush()
        return user

    # `users.email` is unique. A platform account whose address already
    # belongs to some other E&M row is still a real person who needs to sign
    # in, so the shadow row goes without the address rather than 500ing on
    # the constraint.
    address = (email or "").strip().lower() or None
    if address and await session.scalar(select(User.id).where(User.email == address)):
        address = None

    user = User(
        id=local_id(sub),
        name=(name or user_name or sub).strip(),
        user_id=handle,
        email=address,
        role=Role.executive,
        password_hash=None,
        must_reset_password=False,
    )
    session.add(user)
    await session.commit()
    return await session.scalar(
        select(User).where(User.id == user.id).options(selectinload(User.site_links))
    )


async def site_codes_for(
    session: AsyncSession, site_ids: tuple[str, ...] | list[str]
) -> frozenset[str]:
    """Platform site ids → E&M site codes, through `sites.siteops_site_id`.

    A site nobody has linked resolves to nothing and stays reachable only by
    an administrator, which is the right way for an unlinked site to fail.
    """
    ids = [str(i) for i in site_ids if i]
    if not ids:
        return frozenset()
    codes = await session.scalars(
        select(Site.code).where(Site.siteops_site_id.in_(ids))
    )
    return frozenset(codes.all())
