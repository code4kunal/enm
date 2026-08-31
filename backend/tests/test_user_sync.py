"""user_sync.sync_users_from_siteops: the overwrite semantics that make
SiteOps the source of truth for a linked site's roster.
"""
from __future__ import annotations

from sqlalchemy import select

from app.db import SessionLocal
from app.models.enums import Role
from app.models.user import User, UserSiteAccess
from app.security import hash_password
from app.services import siteops, user_sync
from tests.conftest import PASSWORD


def _fake_list_site_users(rows: list[dict]):
    async def fake(site_id: str, is_active: bool | None = None) -> list[dict]:
        return rows

    return fake


def _fake_user_grants(roles: list[str]):
    async def fake(user_id: str) -> dict:
        return {"roles": roles, "permissions": []}

    return fake


ROWS = [
    {
        "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        "username": "newhand1",
        "full_name": "New Hand One",
        "email": "newhand1@transvolt.in",
        "is_active": True,
    },
    {
        "id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
        "username": "newhand2",
        "full_name": "New Hand Two",
        "email": "newhand2@transvolt.in",
        "is_active": False,
    },
]


async def test_sync_creates_shadow_rows_and_site_access(monkeypatch) -> None:
    monkeypatch.setattr(siteops, "list_site_users", _fake_list_site_users(ROWS))
    monkeypatch.setattr(siteops, "user_grants", _fake_user_grants(["Manager"]))

    async with SessionLocal() as session:
        result = await user_sync.sync_users_from_siteops(
            session, "MBMT", "siteops-uuid-1"
        )
        await session.commit()

    assert result.synced == 2
    assert result.adopted == 0

    async with SessionLocal() as session:
        active = await session.scalar(
            select(User).where(User.user_id == "NEWHAND1")
        )
        inactive = await session.scalar(
            select(User).where(User.user_id == "NEWHAND2")
        )
        assert active.is_active is True
        assert active.role is Role.manager
        assert "MBMT" in active.site_access
        assert inactive.is_active is False
        # A deactivated SiteOps user is not staffed on the site.
        assert "MBMT" not in inactive.site_access


async def test_sync_adopts_a_pre_existing_local_account_and_clears_its_password(
    monkeypatch,
) -> None:
    async with SessionLocal() as session:
        session.add(
            User(
                id="localacct0003",
                name="Pre-integration Person",
                user_id="NEWHAND1",
                role=Role.executive,
                password_hash=hash_password(PASSWORD),
            )
        )
        await session.commit()

    monkeypatch.setattr(siteops, "list_site_users", _fake_list_site_users(ROWS[:1]))
    monkeypatch.setattr(siteops, "user_grants", _fake_user_grants(["Manager"]))

    async with SessionLocal() as session:
        result = await user_sync.sync_users_from_siteops(
            session, "MBMT", "siteops-uuid-1"
        )
        await session.commit()

    assert result.adopted == 1

    async with SessionLocal() as session:
        row = await session.get(User, "localacct0003")
        assert row.password_hash is None


async def test_sync_removes_site_access_for_a_user_no_longer_on_the_roster(
    monkeypatch,
) -> None:
    monkeypatch.setattr(siteops, "list_site_users", _fake_list_site_users(ROWS))
    monkeypatch.setattr(siteops, "user_grants", _fake_user_grants(["Manager"]))
    async with SessionLocal() as session:
        await user_sync.sync_users_from_siteops(session, "MBMT", "siteops-uuid-1")
        await session.commit()

    # Next sync: SiteOps no longer lists NEWHAND1 for this site at all.
    monkeypatch.setattr(siteops, "list_site_users", _fake_list_site_users(ROWS[1:]))
    async with SessionLocal() as session:
        result = await user_sync.sync_users_from_siteops(
            session, "MBMT", "siteops-uuid-1"
        )
        await session.commit()
    assert result.deactivated >= 1

    async with SessionLocal() as session:
        row = await session.scalar(select(User).where(User.user_id == "NEWHAND1"))
        assert "MBMT" not in row.site_access


async def test_sync_reactivates_a_user_siteops_marks_active_again(
    monkeypatch,
) -> None:
    monkeypatch.setattr(siteops, "list_site_users", _fake_list_site_users(ROWS))
    monkeypatch.setattr(siteops, "user_grants", _fake_user_grants(["Manager"]))
    async with SessionLocal() as session:
        await user_sync.sync_users_from_siteops(session, "MBMT", "siteops-uuid-1")
        await session.commit()

    reactivated_row = dict(ROWS[1])
    reactivated_row["is_active"] = True
    monkeypatch.setattr(
        siteops, "list_site_users", _fake_list_site_users([reactivated_row])
    )
    async with SessionLocal() as session:
        result = await user_sync.sync_users_from_siteops(
            session, "MBMT", "siteops-uuid-1"
        )
        await session.commit()
    assert result.reactivated == 1
