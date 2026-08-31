"""platform_identity.ensure_user: shadow rows, adoption, and the sync-source fix.

A depot that signed in locally before the SiteOps integration keeps its
account when SiteOps later reports the same handle — `ensure_user` adopts it
by matching `user_id`. A live login (`source="login"`) already proved the
password belongs to that person, so it's left alone. A background sync or
staff-list fetch (`source="sync"`) has proved no such thing — SiteOps is
simply reporting a handle — so adopting there must also convert the row to
platform-managed (clear the password) or it stays silently editable through
E&M's local admin surface forever, defeating the whole migration for that
one account.
"""
from __future__ import annotations

import uuid

from app.db import SessionLocal
from app.models.enums import Role
from app.models.user import User
from app.security import hash_password
from app.services import platform_identity
from tests.conftest import PASSWORD


async def test_login_source_adopts_without_clearing_password() -> None:
    async with SessionLocal() as session:
        session.add(
            User(
                id="localacct0001",
                name="Pre-integration",
                user_id="PREINT",
                role=Role.executive,
                password_hash=hash_password(PASSWORD),
            )
        )
        await session.commit()

        user = await platform_identity.ensure_user(
            session, sub=str(uuid.uuid4()), user_name="preint", source="login"
        )
        assert user.id == "localacct0001"
        assert user.password_hash is not None


async def test_sync_source_clears_password_on_adoption() -> None:
    async with SessionLocal() as session:
        session.add(
            User(
                id="localacct0002",
                name="Pre-integration",
                user_id="PREINT2",
                role=Role.executive,
                password_hash=hash_password(PASSWORD),
                must_reset_password=True,
            )
        )
        await session.commit()

        user = await platform_identity.ensure_user(
            session, sub=str(uuid.uuid4()), user_name="preint2", source="sync"
        )
        assert user.id == "localacct0002"
        assert user.password_hash is None
        assert user.must_reset_password is False


async def test_staff_list_persists_the_adoption_it_performs(client, monkeypatch) -> None:
    """`GET /master/staff` must commit the password-clear it decides to do.

    `ensure_user`'s adoption branch only flushes, and the request-scoped
    session never commits on its own, so before the explicit commit in
    `_platform_staff` the clear survived only when some *other* row in the
    same response happened to take the create-path (which commits). One row
    here: nothing else can sweep the pending update in.
    """
    from app.config import settings
    from app.models.master import Site
    from app.models.user import UserSiteAccess
    from app.services import siteops
    from tests.conftest import auth_headers

    async with SessionLocal() as session:
        site = await session.get(Site, "MBMT")
        site.siteops_site_id = "siteops-uuid-1"
        session.add(
            User(
                id="localacct0004",
                name="Pre-integration Fitter",
                user_id="STAFF1",
                role=Role.executive,
                password_hash=hash_password(PASSWORD),
                must_reset_password=True,
                site_links=[UserSiteAccess(site_code="MBMT")],
            )
        )
        await session.commit()

    monkeypatch.setattr(settings, "siteops_service_key", "service-key")

    async def fake_list_site_users(site_id: str, is_active: bool | None = True):
        return [
            {
                "id": "cccccccc-cccc-cccc-cccc-cccccccccccc",
                "username": "staff1",
                "full_name": "Staff One",
                "email": "staff1@transvolt.in",
                "is_active": True,
            }
        ]

    monkeypatch.setattr(siteops, "list_site_users", fake_list_site_users)

    headers = await auth_headers(client)
    r = await client.get("/master/staff", params={"site": "MBMT"}, headers=headers)
    assert r.status_code == 200, r.text

    async with SessionLocal() as session:
        row = await session.get(User, "localacct0004")
        assert row.password_hash is None
        assert row.must_reset_password is False


async def test_sync_source_leaves_a_fresh_shadow_row_untouched() -> None:
    async with SessionLocal() as session:
        user = await platform_identity.ensure_user(
            session, sub=str(uuid.uuid4()), user_name="brandnew", source="sync"
        )
        assert user.password_hash is None


async def test_staff_list_never_touches_a_local_super_admin(client, monkeypatch) -> None:
    """`GET /master/staff` must not adopt a SiteOps handle that collides with
    a local `Role.super_admin` account either — the break-glass bootstrap
    admin is protected centrally in `ensure_user`, not just in the nightly
    sync loop that has its own separate call site into the same function.
    """
    from app.config import settings
    from app.models.master import Site
    from app.services import siteops
    from tests.conftest import auth_headers

    hashed = hash_password(PASSWORD)
    async with SessionLocal() as session:
        site = await session.get(Site, "MBMT")
        site.siteops_site_id = "siteops-uuid-1"
        session.add(
            User(
                id="breakglass0002",
                name="Break Glass",
                user_id="STAFF2",
                role=Role.super_admin,
                password_hash=hashed,
            )
        )
        await session.commit()

    monkeypatch.setattr(settings, "siteops_service_key", "service-key")

    async def fake_list_site_users(site_id: str, is_active: bool | None = True):
        return [
            {
                "id": "dddddddd-dddd-dddd-dddd-dddddddddddd",
                "username": "staff2",
                "full_name": "Staff Two",
                "email": "staff2@transvolt.in",
                "is_active": True,
            }
        ]

    monkeypatch.setattr(siteops, "list_site_users", fake_list_site_users)

    headers = await auth_headers(client)
    r = await client.get("/master/staff", params={"site": "MBMT"}, headers=headers)
    assert r.status_code == 200, r.text

    async with SessionLocal() as session:
        row = await session.get(User, "breakglass0002")
        assert row.password_hash == hashed
        assert row.role is Role.super_admin
        assert row.is_active is True
        assert row.must_reset_password is False
