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


async def test_sso_exchange_redeems_the_code_then_completes_sign_in(
    monkeypatch,
) -> None:
    """POST /auth/sso/exchange: server-side code redemption (the "Web"
    platform-type path), then the same completion logic as /auth/sso."""
    seen_exchange: dict = {}

    async def fake_exchange(*, code, redirect_uri, code_verifier):
        seen_exchange.update(
            {"code": code, "redirect_uri": redirect_uri, "code_verifier": code_verifier}
        )
        return "fake-id-token"

    monkeypatch.setattr(auth_module, "exchange_code_for_id_token", fake_exchange)
    monkeypatch.setattr(
        auth_module,
        "verify_ms_id_token",
        lambda token: _fake_ms_claims("rahul.sharma@transvolt.in")
        if token == "fake-id-token"
        else (_ for _ in ()).throw(AssertionError("wrong token verified")),
    )

    from httpx import ASGITransport
    from app.main import app

    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test/api/v1"
    ) as client:
        resp = await client.post(
            "/auth/sso/exchange",
            json={
                "code": "auth-code-123",
                "redirect_uri": "https://enm.transvolt.org/",
                "code_verifier": "verifier-abc",
            },
        )
    assert resp.status_code == 200, resp.text
    assert resp.json()["user"]["user_id"] == "TV4021"
    assert seen_exchange == {
        "code": "auth-code-123",
        "redirect_uri": "https://enm.transvolt.org/",
        "code_verifier": "verifier-abc",
    }


async def test_exchange_code_for_id_token_sends_a_confidential_client_request(
    monkeypatch,
) -> None:
    from app.config import settings
    from app.services.sso import exchange_code_for_id_token

    monkeypatch.setattr(settings, "ms_tenant_id", "tenant-123")
    monkeypatch.setattr(settings, "ms_client_id", "client-abc")
    monkeypatch.setattr(settings, "ms_client_secret", "shh-secret")

    seen: dict = {}

    class FakeResponse:
        status_code = 200
        headers = {"content-type": "application/json"}

        def json(self):
            return {"id_token": "real-id-token"}

    class FakeClient:
        async def __aenter__(self):
            return self

        async def __aexit__(self, *exc):
            return False

        async def post(self, url, data):
            seen["url"] = url
            seen["data"] = data
            return FakeResponse()

    import httpx as httpx_module

    monkeypatch.setattr(httpx_module, "AsyncClient", lambda timeout=10.0: FakeClient())

    token = await exchange_code_for_id_token(
        code="c1", redirect_uri="https://enm.transvolt.org/", code_verifier="v1"
    )
    assert token == "real-id-token"
    assert seen["url"] == "https://login.microsoftonline.com/tenant-123/oauth2/v2.0/token"
    assert seen["data"]["client_id"] == "client-abc"
    assert seen["data"]["client_secret"] == "shh-secret"
    assert seen["data"]["grant_type"] == "authorization_code"
    assert seen["data"]["code"] == "c1"
    assert seen["data"]["code_verifier"] == "v1"


async def test_exchange_code_for_id_token_requires_a_configured_secret(
    monkeypatch,
) -> None:
    from app.config import settings
    from app.errors import ValidationError
    from app.services.sso import exchange_code_for_id_token

    monkeypatch.setattr(settings, "ms_tenant_id", "tenant-123")
    monkeypatch.setattr(settings, "ms_client_id", "client-abc")
    monkeypatch.setattr(settings, "ms_client_secret", None)

    try:
        await exchange_code_for_id_token(
            code="c1", redirect_uri="https://x/", code_verifier="v1"
        )
        raise AssertionError("expected ValidationError")
    except ValidationError:
        pass


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
