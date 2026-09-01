"""POST /auth/sso: a verified Microsoft identity provisions a shadow row from
SiteOps the same way password login does, when no local account matches the
token's email yet.
"""
from __future__ import annotations

from httpx import AsyncClient
from sqlalchemy import select

from app.api import auth as auth_module
from app.db import SessionLocal
from app.models.user import User
from app.services import siteops
from tests.conftest import PASSWORD


def _fake_ms_claims(email: str) -> dict:
    return {"_email": email, "sub": "ms-oid-does-not-matter"}


async def test_sso_provisions_a_shadow_row_from_siteops(monkeypatch) -> None:
    email = "new.hand@transvolt.in"
    monkeypatch.setattr(
        auth_module, "verify_ms_id_token", lambda _t: _fake_ms_claims(email)
    )

    async def fake_find(search_email: str) -> dict:
        assert search_email == email
        return {
            "id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            "username": "newhand",
            "full_name": "New Hand",
            "email": email,
        }

    async def fake_grants(user_id: str) -> dict:
        return {"roles": ["Manager"], "permissions": ["em_entry:read"]}

    async def fake_site_ids(user_id: str) -> list[str]:
        return []

    monkeypatch.setattr(siteops, "find_user_by_email", fake_find)
    monkeypatch.setattr(siteops, "user_grants", fake_grants)
    monkeypatch.setattr(siteops, "user_site_ids", fake_site_ids)

    from httpx import ASGITransport
    from app.main import app

    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test/api/v1"
    ) as client:
        resp = await client.post("/auth/sso", json={"ms_id_token": "irrelevant"})
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["user"]["permissions"] == ["em_entry:read"]

    async with SessionLocal() as session:
        row = await session.scalar(select(User).where(User.email == email))
        assert row is not None
        assert row.password_hash is None
        assert row.user_id == "NEWHAND"


async def test_sso_404s_when_neither_local_nor_siteops_know_the_email(
    monkeypatch,
) -> None:
    email = "nobody@transvolt.in"
    monkeypatch.setattr(
        auth_module, "verify_ms_id_token", lambda _t: _fake_ms_claims(email)
    )

    async def fake_find(search_email: str) -> None:
        return None

    monkeypatch.setattr(siteops, "find_user_by_email", fake_find)

    from httpx import ASGITransport
    from app.main import app

    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test/api/v1"
    ) as client:
        resp = await client.post("/auth/sso", json={"ms_id_token": "irrelevant"})
    assert resp.status_code == 404


async def test_sso_still_matches_an_existing_local_account_by_email(
    monkeypatch,
) -> None:
    """Regression: the pre-existing local-email path must be unaffected —
    it must not even ask SiteOps."""
    monkeypatch.setattr(
        auth_module,
        "verify_ms_id_token",
        lambda _t: _fake_ms_claims("rahul.sharma@transvolt.in"),
    )

    async def never(email: str):
        raise AssertionError("a local match must not ask SiteOps")

    monkeypatch.setattr(siteops, "find_user_by_email", never)

    from httpx import ASGITransport
    from app.main import app

    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test/api/v1"
    ) as client:
        resp = await client.post("/auth/sso", json={"ms_id_token": "irrelevant"})
    assert resp.status_code == 200, resp.text
    assert resp.json()["user"]["user_id"] == "TV4021"


async def test_find_user_by_email_narrows_search_to_an_exact_match(
    monkeypatch,
) -> None:
    async def fake_get(path: str, params: dict, *, missing_ok: bool = False):
        assert path == "/users/"
        assert params["search"] == "kunal.s@transvolt.in"
        return {
            "data": [
                {"id": "1", "email": "kunal.saxena@transvolt.in"},
                {"id": "2", "email": "Kunal.S@transvolt.in"},
            ]
        }

    monkeypatch.setattr(siteops, "_get", fake_get)
    result = await siteops.find_user_by_email("kunal.s@transvolt.in")
    assert result is not None
    assert result["id"] == "2"


async def test_find_user_by_email_returns_none_without_an_exact_match(
    monkeypatch,
) -> None:
    async def fake_get(path: str, params: dict, *, missing_ok: bool = False):
        return {"data": [{"id": "1", "email": "someone.else@transvolt.in"}]}

    monkeypatch.setattr(siteops, "_get", fake_get)
    result = await siteops.find_user_by_email("kunal.s@transvolt.in")
    assert result is None
