"""user_sync.sync_users_from_siteops: the overwrite semantics that make
SiteOps the source of truth for a linked site's roster.
"""
from __future__ import annotations

from httpx import AsyncClient
from sqlalchemy import select

from app.db import SessionLocal
from app.models.enums import Role
from app.models.user import User, UserSiteAccess
from app.security import hash_password
from app.services import siteops, user_sync
from tests.conftest import PASSWORD, SUPER_ADMIN, auth_headers


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


async def test_sync_deactivates_a_user_still_on_roster_but_no_longer_active(
    monkeypatch,
) -> None:
    """SiteOps still lists the user for this site but flips them inactive.

    A user's `UserSiteAccess` must not survive from an earlier run where
    they were active — site_access means "currently active AND staffed
    here", not "was ever staffed here."
    """
    monkeypatch.setattr(siteops, "list_site_users", _fake_list_site_users(ROWS[:1]))
    monkeypatch.setattr(siteops, "user_grants", _fake_user_grants(["Manager"]))
    async with SessionLocal() as session:
        await user_sync.sync_users_from_siteops(session, "MBMT", "siteops-uuid-1")
        await session.commit()

    async with SessionLocal() as session:
        row = await session.scalar(select(User).where(User.user_id == "NEWHAND1"))
        assert "MBMT" in row.site_access

    deactivated_row = dict(ROWS[0])
    deactivated_row["is_active"] = False
    monkeypatch.setattr(
        siteops, "list_site_users", _fake_list_site_users([deactivated_row])
    )
    async with SessionLocal() as session:
        result = await user_sync.sync_users_from_siteops(
            session, "MBMT", "siteops-uuid-1"
        )
        await session.commit()
    assert result.deactivated >= 1

    async with SessionLocal() as session:
        row = await session.scalar(select(User).where(User.user_id == "NEWHAND1"))
        assert row.is_active is False
        assert "MBMT" not in row.site_access


async def test_sync_all_users_isolates_per_site_failures(monkeypatch) -> None:
    """One linked site's SiteOps outage must not abort the run over the rest.

    Mirrors `masters.sync_all_linked_sites`'s per-site error isolation: the
    failing site's result is recorded with `ok: False` and an error, the
    healthy site still syncs normally, and both sites get a timestamped
    result either way.
    """
    from app.models.master import Site
    from app.services.siteops import SiteOpsUnavailable

    async with SessionLocal() as session:
        mbmt = await session.get(Site, "MBMT")
        mbmt.siteops_site_id = "siteops-uuid-1"
        umt = await session.get(Site, "UMT")
        umt.siteops_site_id = "siteops-uuid-2"
        await session.commit()

    async def fake_list_site_users(site_id: str, is_active: bool | None = None):
        if site_id == "siteops-uuid-2":
            raise SiteOpsUnavailable("Cannot reach SiteOps: boom")
        return ROWS[:1]

    monkeypatch.setattr(siteops, "list_site_users", fake_list_site_users)
    monkeypatch.setattr(siteops, "user_grants", _fake_user_grants(["Manager"]))

    outcomes = await user_sync.sync_all_users_from_siteops()

    by_site = {o["site_code"]: o for o in outcomes}
    assert by_site["MBMT"]["ok"] is True
    assert by_site["MBMT"]["synced"] == 1
    assert by_site["UMT"]["ok"] is False
    assert "error" in by_site["UMT"]

    async with SessionLocal() as session:
        mbmt = await session.get(Site, "MBMT")
        umt = await session.get(Site, "UMT")
        assert mbmt.last_siteops_user_sync_at is not None
        assert mbmt.last_siteops_user_sync_result["ok"] is True
        assert umt.last_siteops_user_sync_at is not None
        assert umt.last_siteops_user_sync_result["ok"] is False
        assert "error" in umt.last_siteops_user_sync_result


async def test_sync_endpoint_requires_a_linked_site(
    client: AsyncClient, monkeypatch
) -> None:
    monkeypatch.setattr(siteops, "list_site_users", _fake_list_site_users([]))
    h = await auth_headers(client, SUPER_ADMIN)
    r = await client.post("/sites/TDC/users/sync-from-siteops", headers=h)
    assert r.status_code == 409


async def test_sync_endpoint_syncs_a_linked_site(
    client: AsyncClient, monkeypatch
) -> None:
    from app.db import SessionLocal
    from app.models.master import Site

    async with SessionLocal() as session:
        site = await session.get(Site, "MBMT")
        site.siteops_site_id = "siteops-uuid-1"
        await session.commit()

    monkeypatch.setattr(siteops, "list_site_users", _fake_list_site_users(ROWS))
    monkeypatch.setattr(siteops, "user_grants", _fake_user_grants(["Manager"]))
    h = await auth_headers(client, SUPER_ADMIN)
    r = await client.post("/sites/MBMT/users/sync-from-siteops", headers=h)
    assert r.status_code == 200, r.text
    assert r.json()["synced"] == 2


async def test_sync_endpoint_is_manager_only(client: AsyncClient) -> None:
    supervisor = await auth_headers(client, "TV4102")
    r = await client.post("/sites/MBMT/users/sync-from-siteops", headers=supervisor)
    assert r.status_code == 403
