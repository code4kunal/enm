"""Authorisation from siteops-platform tokens.

The platform is the estate's identity authority: it signs the token and the
token carries the decision — roles, permissions, site ids. These tests hold
the line at the two places that decision can be faked or lost: the signature,
and the mapping from platform site ids onto E&M site codes.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

import jwt
import pytest
from httpx import AsyncClient
from sqlalchemy import select

from app.config import settings
from app.db import SessionLocal
from app.models.master import Site
from app.models.user import User
from tests.conftest import auth_headers

PLATFORM_SECRET = "platform-test-secret"
#: The platform site id the fixtures below link MBMT to.
MBMT_SITEOPS_ID = "18e9fd58-a005-4765-ad75-02f75b0a9c09"


def platform_token(
    *,
    sub: str | None = None,
    user_name: str = "rahul.sharma",
    roles: list[str] | None = None,
    permissions: list[str] | None = None,
    site_ids: list[str] | None = None,
    secret: str = PLATFORM_SECRET,
    token_type: str = "access",
    expires_in: int = 3600,
) -> str:
    """A token shaped exactly like the ones siteops-platform issues."""
    now = datetime.now(UTC)
    payload = {
        "sub": sub or str(uuid.uuid4()),
        "user_name": user_name,
        "employee_code": "EMP-001",
        "roles": roles if roles is not None else ["Maintenance"],
        "permissions": permissions if permissions is not None else [],
        "site_ids": site_ids if site_ids is not None else [],
        "project_ids": [],
        "security_stamp": "stamp",
        "type": token_type,
        "exp": now + timedelta(seconds=expires_in),
        "jti": str(uuid.uuid4()),
    }
    return jwt.encode(payload, secret, algorithm="HS256")


def headers(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


async def link_mbmt() -> None:
    """Give MBMT the SiteOps id the tokens below claim access to."""
    async with SessionLocal() as session:
        site = await session.get(Site, "MBMT")
        site.siteops_site_id = MBMT_SITEOPS_ID
        await session.commit()


# --- the signature is the whole boundary -----------------------------------


async def test_unsigned_token_is_rejected(client: AsyncClient) -> None:
    """A token nobody signed carries claims an attacker chose.

    This is the shape that used to be accepted: decode without verification,
    trust `roles`, and a self-minted `admin` walks in.
    """
    forged = jwt.encode(
        {"sub": str(uuid.uuid4()), "roles": ["admin"], "type": "access"},
        "",
        algorithm="HS256",
    )
    resp = await client.get("/auth/me", headers=headers(forged))
    assert resp.status_code == 401


async def test_token_signed_with_the_wrong_secret_is_rejected(
    client: AsyncClient,
) -> None:
    resp = await client.get(
        "/auth/me",
        headers=headers(platform_token(secret="not-the-platform-secret")),
    )
    assert resp.status_code == 401


async def test_refresh_token_is_not_a_bearer_token(client: AsyncClient) -> None:
    """A refresh token has a different job and must not open a session."""
    resp = await client.get(
        "/auth/me", headers=headers(platform_token(token_type="refresh"))
    )
    assert resp.status_code == 401


async def test_expired_platform_token_is_rejected(client: AsyncClient) -> None:
    resp = await client.get(
        "/auth/me", headers=headers(platform_token(expires_in=-60))
    )
    assert resp.status_code == 401


# --- what a valid token gets you -------------------------------------------


async def test_first_sign_in_creates_a_shadow_row_with_no_grants(
    client: AsyncClient,
) -> None:
    """A platform user E&M has never seen gets a row for authorship only.

    No site links: access comes from the token on every request, so revoking
    a site in the platform needs no cleanup here.
    """
    sub = str(uuid.uuid4())
    resp = await client.get(
        "/auth/me",
        headers=headers(
            platform_token(sub=sub, user_name="new.mechanic", permissions=[])
        ),
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["user_id"] == "NEW.MECHANIC"
    assert body["site_access"] == []
    assert body["permissions"] == []

    async with SessionLocal() as session:
        row = await session.get(User, sub.replace("-", ""))
        assert row is not None
        assert row.password_hash is None
        assert row.site_links == []


async def test_permissions_come_from_the_token(client: AsyncClient) -> None:
    await link_mbmt()
    token = platform_token(
        permissions=["em_entry:read", "em_report:read"],
        site_ids=[MBMT_SITEOPS_ID],
    )
    body = (await client.get("/auth/me", headers=headers(token))).json()
    assert body["permissions"] == ["em_entry:read", "em_report:read"]
    assert body["site_access"] == ["MBMT"]


async def test_site_ids_map_onto_e_and_m_site_codes(client: AsyncClient) -> None:
    """`sites.siteops_site_id` is the join; an unlinked site is unreachable."""
    await link_mbmt()
    token = platform_token(
        permissions=["em_entry:read"], site_ids=[MBMT_SITEOPS_ID]
    )
    assert (
        await client.get("/entries?site=MBMT", headers=headers(token))
    ).status_code == 200
    # UMT exists in E&M but is linked to nothing, so no token can reach it.
    assert (
        await client.get("/entries?site=UMT", headers=headers(token))
    ).status_code == 403


async def test_a_site_granted_in_the_platform_is_unreachable_until_linked(
    client: AsyncClient,
) -> None:
    token = platform_token(
        permissions=["em_entry:read"], site_ids=[MBMT_SITEOPS_ID]
    )
    resp = await client.get("/entries?site=MBMT", headers=headers(token))
    assert resp.status_code == 403


async def test_the_site_list_shows_the_token_s_sites(client: AsyncClient) -> None:
    """What the client's site switcher reads.

    A platform user has no `user_site_access` rows, so a site list built from
    that table comes back empty and the app asks them to select a site from
    nothing at all. It has to be built from the token instead.
    """
    await link_mbmt()
    token = platform_token(
        permissions=["em_entry:read"], site_ids=[MBMT_SITEOPS_ID]
    )
    resp = await client.get("/sites", headers=headers(token))
    assert resp.status_code == 200
    assert [s["code"] for s in resp.json()["items"]] == ["MBMT"]


async def test_missing_permission_is_a_403_not_a_404(client: AsyncClient) -> None:
    """Reaching the site is not the same as being allowed to change it."""
    await link_mbmt()
    token = platform_token(
        permissions=["em_entry:read"], site_ids=[MBMT_SITEOPS_ID]
    )
    resp = await client.put(
        "/sites/MBMT/config",
        headers=headers(token),
        json={"shift_windows": [], "service_plans": []},
    )
    assert resp.status_code == 403
    assert "em_site_config:write" in resp.json()["error"]["message"]


async def test_platform_admin_reaches_every_site(client: AsyncClient) -> None:
    """The platform's own convention: `admin` bypasses permission checks.

    Its sync endpoint assigns every service's permissions to that role, so
    honouring it here matches what an administrator already sees granted.
    """
    token = platform_token(roles=["admin"], permissions=[], site_ids=[])
    assert (
        await client.get("/entries?site=UMT", headers=headers(token))
    ).status_code == 200


async def test_a_platform_user_is_not_promoted_by_its_role_claim(
    client: AsyncClient,
) -> None:
    """Only `admin` bypasses. A role named `manager` grants nothing by itself —
    permissions do, and they are granted in the platform."""
    await link_mbmt()
    token = platform_token(
        roles=["manager", "Maintenance"],
        permissions=[],
        site_ids=[MBMT_SITEOPS_ID],
    )
    resp = await client.get("/entries?site=MBMT", headers=headers(token))
    assert resp.status_code == 403


async def test_deactivating_the_shadow_row_locks_the_platform_user_out(
    client: AsyncClient,
) -> None:
    """E&M keeps a local off switch that does not need the platform."""
    sub = str(uuid.uuid4())
    token = platform_token(sub=sub, user_name="temp.hand", roles=["admin"])
    assert (await client.get("/auth/me", headers=headers(token))).status_code == 200

    async with SessionLocal() as session:
        row = await session.get(User, sub.replace("-", ""))
        row.is_active = False
        await session.commit()

    assert (await client.get("/auth/me", headers=headers(token))).status_code == 403


async def test_an_existing_local_account_is_adopted_not_duplicated(
    client: AsyncClient,
) -> None:
    """TV4021 signed in with a password yesterday and through the platform
    today. Same person, same entries, same audit trail."""
    async with SessionLocal() as session:
        before = await session.scalar(select(User).where(User.user_id == "TV4021"))
        before_id = before.id

    token = platform_token(user_name="tv4021", roles=["admin"])
    body = (await client.get("/auth/me", headers=headers(token))).json()
    assert body["id"] == before_id

    async with SessionLocal() as session:
        rows = (
            await session.scalars(select(User).where(User.user_id == "TV4021"))
        ).all()
        assert len(rows) == 1


# --- E&M-local accounts still work -----------------------------------------


@pytest.mark.parametrize(
    ("user_id", "permission", "expected"),
    [
        ("TV1001", "em_site:write", True),  # super admin
        ("TV4021", "em_site_config:write", True),  # manager
        ("TV4102", "em_entry:write", True),  # supervisor
        ("TV4102", "em_site_config:write", False),
        ("TV4105", "em_entry:read", True),  # executive
        ("TV4105", "em_entry:write", False),
    ],
)
async def test_local_roles_map_to_permissions(
    client: AsyncClient, user_id: str, permission: str, expected: bool
) -> None:
    """Accounts predating the integration are authorised from `role` against
    the default table in `app/permissions.py`."""
    body = (
        await client.get("/auth/me", headers=await auth_headers(client, user_id))
    ).json()
    assert (permission in body["permissions"]) is expected


async def test_the_platform_secret_and_the_local_secret_stay_distinct() -> None:
    """Sharing one key would let an E&M-signed token pass as a platform one,
    claims and all — `Settings.problems()` refuses to start on it."""
    assert settings.jwt_secret != settings.siteops_jwt_secret
