"""Signing in through siteops-platform, and what a refresh does to the grants.

`/auth/login` asks the platform, which owns the password and the grants, then
issues an E&M session carrying what it said. The platform is stubbed here:
these tests are about what E&M does with the answer, not about the platform
being up.
"""

from __future__ import annotations

import uuid

import pytest
from httpx import AsyncClient
from sqlalchemy import select

from app.config import settings
from app.db import SessionLocal
from app.models.enums import Role
from app.models.master import Site
from app.models.user import User
from app.services import siteops
from app.services.siteops import SiteOpsUnavailable
from tests.conftest import PASSWORD

SITEOPS_SITE_ID = "18e9fd58-a005-4765-ad75-02f75b0a9c09"


@pytest.fixture(autouse=True)
def _platform_login_on(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(settings, "platform_login_enabled", True)


def login_reply(
    *,
    sub: str,
    username: str = "new.mechanic",
    permissions: list[str] | None = None,
    site_ids: list[str] | None = None,
    roles: list[str] | None = None,
) -> dict:
    """The shape siteops-platform's `/auth/login` returns under `data`."""
    return {
        "user_id": sub,
        "username": username,
        "full_name": "New Mechanic",
        "email": "new.mechanic@transvolt.in",
        "employee_code": "EMP-77",
        "roles": roles or ["Maintenance"],
        "permissions": permissions or [],
        "site_ids": site_ids or [],
        "project_ids": [],
    }


async def link_mbmt() -> None:
    async with SessionLocal() as session:
        site = await session.get(Site, "MBMT")
        site.siteops_site_id = SITEOPS_SITE_ID
        await session.commit()


async def test_platform_login_issues_a_session_carrying_its_grants(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    await link_mbmt()
    sub = str(uuid.uuid4())

    async def fake_login(username: str, password: str) -> dict:
        assert username == "NEWHAND" or username == "newhand"
        return login_reply(
            sub=sub,
            username="newhand",
            permissions=["em_entry:read", "em_entry:write"],
            site_ids=[SITEOPS_SITE_ID],
        )

    monkeypatch.setattr(siteops, "login", fake_login)

    resp = await client.post(
        "/auth/login", json={"user_id": "NEWHAND", "password": "whatever"}
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["user"]["permissions"] == ["em_entry:read", "em_entry:write"]
    assert body["user"]["site_access"] == ["MBMT"]

    # And the token works: the grants ride in it, not in a database row.
    headers = {"Authorization": f"Bearer {body['access_token']}"}
    assert (
        await client.get("/entries?site=MBMT", headers=headers)
    ).status_code == 200

    async with SessionLocal() as session:
        row = await session.get(User, sub.replace("-", ""))
        assert row.site_links == []  # the shadow row grants nothing


async def test_a_platform_rejection_falls_through_to_the_local_account(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The break-glass admin still signs in when the platform says no."""

    async def fake_login(username: str, password: str) -> None:
        return None

    monkeypatch.setattr(siteops, "login", fake_login)

    resp = await client.post(
        "/auth/login", json={"user_id": "TV1001", "password": PASSWORD}
    )
    assert resp.status_code == 200
    assert resp.json()["user"]["user_id"] == "TV1001"


async def test_a_platform_outage_does_not_lock_a_depot_out(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    async def fake_login(username: str, password: str) -> dict:
        raise SiteOpsUnavailable("connection refused")

    monkeypatch.setattr(siteops, "login", fake_login)

    resp = await client.post(
        "/auth/login", json={"user_id": "TV4021", "password": PASSWORD}
    )
    assert resp.status_code == 200


async def test_a_wrong_password_is_still_wrong(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    async def fake_login(username: str, password: str) -> None:
        return None

    monkeypatch.setattr(siteops, "login", fake_login)

    resp = await client.post(
        "/auth/login", json={"user_id": "TV4021", "password": "not-it"}
    )
    assert resp.status_code == 401


async def test_refresh_re_reads_the_grants_rather_than_copying_them(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A permission revoked after sign-in must not survive a refresh.

    The platform's own `/auth/refresh` would hand back `roles=["user"]` and no
    permissions at all, so E&M asks the platform again instead.
    """
    await link_mbmt()
    sub = str(uuid.uuid4())

    async def fake_login(username: str, password: str) -> dict:
        return login_reply(
            sub=sub,
            username="newhand",
            permissions=["em_entry:read", "em_entry:write"],
            site_ids=[SITEOPS_SITE_ID],
        )

    monkeypatch.setattr(siteops, "login", fake_login)
    first = (
        await client.post(
            "/auth/login", json={"user_id": "newhand", "password": "whatever"}
        )
    ).json()

    # Overnight, the platform administrator takes the write grant away.
    async def fake_grants(user_id: str) -> dict:
        assert user_id == str(uuid.UUID(hex=sub.replace("-", "")))
        return {"roles": ["Maintenance"], "permissions": ["em_entry:read"]}

    async def fake_site_ids(user_id: str) -> list[str]:
        return [SITEOPS_SITE_ID]

    monkeypatch.setattr(siteops, "user_grants", fake_grants)
    monkeypatch.setattr(siteops, "user_site_ids", fake_site_ids)

    resp = await client.post(
        "/auth/refresh", json={"refresh_token": first["refresh_token"]}
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["user"]["permissions"] == ["em_entry:read"]

    headers = {"Authorization": f"Bearer {body['access_token']}"}
    denied = await client.post(
        "/entries",
        headers=headers,
        json={
            "site": "MBMT",
            "register": "work_done",
            "date": "2026-08-28",
            "data": {},
        },
    )
    assert denied.status_code == 403


async def test_refresh_fails_loudly_when_the_platform_is_unreachable(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Better a re-login than a session that comes back with no permissions."""
    sub = str(uuid.uuid4())

    async def fake_login(username: str, password: str) -> dict:
        return login_reply(sub=sub, username="newhand", permissions=["em_entry:read"])

    monkeypatch.setattr(siteops, "login", fake_login)
    first = (
        await client.post(
            "/auth/login", json={"user_id": "newhand", "password": "whatever"}
        )
    ).json()

    async def boom(user_id: str) -> dict:
        raise SiteOpsUnavailable("connection refused")

    monkeypatch.setattr(siteops, "user_grants", boom)

    resp = await client.post(
        "/auth/refresh", json={"refresh_token": first["refresh_token"]}
    )
    assert resp.status_code == 401


async def test_a_local_account_refreshes_without_asking_the_platform(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    async def fake_login(username: str, password: str) -> None:
        return None

    async def never(user_id: str) -> dict:
        raise AssertionError("a local account has no platform identity to ask about")

    monkeypatch.setattr(siteops, "login", fake_login)
    monkeypatch.setattr(siteops, "user_grants", never)

    first = (
        await client.post(
            "/auth/login", json={"user_id": "TV4021", "password": PASSWORD}
        )
    ).json()
    resp = await client.post(
        "/auth/refresh", json={"refresh_token": first["refresh_token"]}
    )
    assert resp.status_code == 200


async def test_the_handle_is_retried_in_lower_case(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Ground staff type TV4021; the platform stores usernames as entered."""
    seen: list[str] = []
    sub = str(uuid.uuid4())

    async def fake_login(username: str, password: str) -> dict | None:
        seen.append(username)
        if username.islower():
            return login_reply(sub=sub, username=username)
        return None

    monkeypatch.setattr(siteops, "login", fake_login)

    resp = await client.post(
        "/auth/login", json={"user_id": "TV9999", "password": "whatever"}
    )
    assert resp.status_code == 200
    assert seen == ["TV9999", "tv9999"]

    async with SessionLocal() as session:
        row = await session.scalar(select(User).where(User.user_id == "TV9999"))
        assert row is not None


async def test_list_site_users_default_filters_active_only(monkeypatch) -> None:
    """Unchanged default — the staff dropdown must keep seeing only actives."""
    seen_params: list[dict] = []

    async def fake_get(path: str, params: dict, *, missing_ok: bool = False):
        seen_params.append(params)
        return {"data": []}

    monkeypatch.setattr(siteops, "_get", fake_get)
    await siteops.list_site_users("some-site-id")
    assert seen_params[0]["is_active"] == "true"


async def test_list_site_users_none_omits_the_filter(monkeypatch) -> None:
    """The sync job needs deactivated SiteOps users too, to mirror the flip."""
    seen_params: list[dict] = []

    async def fake_get(path: str, params: dict, *, missing_ok: bool = False):
        seen_params.append(params)
        return {"data": []}

    monkeypatch.setattr(siteops, "_get", fake_get)
    await siteops.list_site_users("some-site-id", is_active=None)
    assert "is_active" not in seen_params[0]


async def test_login_resolves_a_known_identitys_exact_case_from_siteops(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A mixed-case SiteOps username (`KunalS`) survives neither an
    as-typed-in-caps attempt nor the lowercase retry — but once this
    person is already synced locally, E&M knows their platform id and can
    ask SiteOps for the exact spelling instead of guessing."""
    sub = str(uuid.uuid4())
    async with SessionLocal() as session:
        session.add(
            User(
                id=sub.replace("-", ""),
                name="Kunal Saxena",
                user_id="KUNALS",
                role=Role.executive,
                password_hash=None,
            )
        )
        await session.commit()

    seen: list[str] = []

    async def fake_login(username: str, password: str) -> dict | None:
        seen.append(username)
        if username == "KunalS":
            return login_reply(sub=sub, username="KunalS")
        return None

    async def fake_profile(user_id: str) -> dict:
        assert user_id == sub
        return {"username": "KunalS"}

    monkeypatch.setattr(siteops, "login", fake_login)
    monkeypatch.setattr(siteops, "get_user_profile", fake_profile)

    resp = await client.post(
        "/auth/login", json={"user_id": "KUNALS", "password": "whatever"}
    )
    assert resp.status_code == 200, resp.text
    # Resolved and tried the canonical spelling first — no guessing needed.
    assert seen == ["KunalS"]


async def test_login_falls_back_to_guessing_for_an_unknown_identity(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """No local row yet (first-ever login) — canonical-handle resolution has
    nothing to look up, so the existing as-typed/lowercase retry still runs."""
    seen: list[str] = []

    async def fake_login(username: str, password: str) -> dict | None:
        seen.append(username)
        return None

    async def never(user_id: str) -> dict:
        raise AssertionError("no local row to resolve — must not call SiteOps")

    monkeypatch.setattr(siteops, "login", fake_login)
    monkeypatch.setattr(siteops, "get_user_profile", never)

    resp = await client.post(
        "/auth/login", json={"user_id": "BRANDNEW", "password": "whatever"}
    )
    assert resp.status_code == 401
    assert seen == ["BRANDNEW", "brandnew"]


def test_redact_tokens_masks_access_and_refresh_tokens_only() -> None:
    body = (
        '{"result":true,"data":{"access_token":"eyJabc.def.ghi",'
        '"refresh_token":"eyJxyz.uvw.rst","username":"kunals",'
        '"roles":["Manager"],"permissions":["em_entry:read"]}}'
    )
    redacted = siteops._redact_tokens(body)
    assert "eyJabc.def.ghi" not in redacted
    assert "eyJxyz.uvw.rst" not in redacted
    assert '"access_token": "***redacted***"' in redacted
    assert '"refresh_token": "***redacted***"' in redacted
    # Everything else — the useful debugging signal — survives untouched.
    assert '"username":"kunals"' in redacted
    assert '"roles":["Manager"]' in redacted


def test_redact_tokens_is_a_no_op_on_an_error_body() -> None:
    body = '{"result":false,"message":"Invalid username or password.","error":"unauthorized"}'
    assert siteops._redact_tokens(body) == body
