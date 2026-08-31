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


async def test_sync_source_leaves_a_fresh_shadow_row_untouched() -> None:
    async with SessionLocal() as session:
        user = await platform_identity.ensure_user(
            session, sub=str(uuid.uuid4()), user_name="brandnew", source="sync"
        )
        assert user.password_hash is None
