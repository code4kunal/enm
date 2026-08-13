from __future__ import annotations

import pytest
from httpx import AsyncClient

from tests.conftest import PASSWORD, auth_headers


async def test_health_needs_no_token(client: AsyncClient) -> None:
    r = await client.get("/health")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"


async def test_login_returns_user_and_sites(client: AsyncClient) -> None:
    r = await client.post(
        "/auth/login", json={"user_id": "tv4021", "password": PASSWORD}
    )
    assert r.status_code == 200
    body = r.json()
    assert body["expires_in"] == 86400
    assert body["user"]["role"] == "manager"
    assert body["user"]["site_access"] == ["MBMT", "UMT"]


async def test_login_bad_password_is_401(client: AsyncClient) -> None:
    r = await client.post("/auth/login", json={"user_id": "TV4021", "password": "nope"})
    assert r.status_code == 401
    assert r.json()["error"]["code"] == "UNAUTHORIZED"


async def test_missing_token_is_401(client: AsyncClient) -> None:
    r = await client.get("/auth/me")
    assert r.status_code == 401


async def test_me_restores_session(client: AsyncClient) -> None:
    r = await client.get("/auth/me", headers=await auth_headers(client))
    assert r.status_code == 200
    assert r.json()["user_id"] == "TV4021"


async def test_refresh_rotates_and_burns_old_token(client: AsyncClient) -> None:
    login = (
        await client.post(
            "/auth/login", json={"user_id": "TV4021", "password": PASSWORD}
        )
    ).json()
    first = login["refresh_token"]

    r = await client.post("/auth/refresh", json={"refresh_token": first})
    assert r.status_code == 200
    assert r.json()["refresh_token"] != first

    replay = await client.post("/auth/refresh", json={"refresh_token": first})
    assert replay.status_code == 401


async def test_deactivated_user_is_403_and_tokens_revoked(client: AsyncClient) -> None:
    mgr = await auth_headers(client)
    target = (
        await client.get("/admin/users", params={"q": "TV4102"}, headers=mgr)
    ).json()["items"][0]

    victim_login = (
        await client.post(
            "/auth/login", json={"user_id": "TV4102", "password": PASSWORD}
        )
    ).json()

    r = await client.post(f"/admin/users/{target['id']}/deactivate", headers=mgr)
    assert r.status_code == 200 and r.json()["is_active"] is False

    # existing access token now rejected
    stale = {"Authorization": f"Bearer {victim_login['access_token']}"}
    assert (await client.get("/auth/me", headers=stale)).status_code == 403

    # refresh token revoked
    refreshed = await client.post(
        "/auth/refresh", json={"refresh_token": victim_login["refresh_token"]}
    )
    assert refreshed.status_code == 401

    # fresh login blocked with INACTIVE_USER
    relogin = await client.post(
        "/auth/login", json={"user_id": "TV4102", "password": PASSWORD}
    )
    assert relogin.status_code == 403
    assert relogin.json()["error"]["code"] == "INACTIVE_USER"


async def test_sso_without_config_is_rejected(client: AsyncClient) -> None:
    r = await client.post("/auth/sso", json={"ms_id_token": "x" * 40})
    assert r.status_code in (400, 401)


# --- refusing to start with an unsafe configuration --------------------------


def test_development_boots_with_the_shipped_defaults() -> None:
    """Otherwise nobody can run the thing locally."""
    from app.config import Settings

    assert Settings(environment="development").problems() == []


def test_production_refuses_the_placeholder_secret() -> None:
    """The one that matters: a forged token is indistinguishable from a real
    one, so a placeholder secret is a silent total compromise."""
    from app.config import ConfigurationError, Settings

    settings = Settings(
        environment="production", cors_origins=["https://em.transvolt.in"]
    )
    problems = " ".join(settings.problems())
    assert "JWT_SECRET" in problems

    with pytest.raises(ConfigurationError) as caught:
        settings.assert_production_ready()
    assert "Refusing to start" in str(caught.value)


def test_production_refuses_a_short_secret() -> None:
    from app.config import Settings

    settings = Settings(environment="production", jwt_secret="tooshort")
    assert any("shorter than" in p for p in settings.problems())


def test_production_refuses_wildcard_cors_and_debug_and_http() -> None:
    from app.config import Settings

    settings = Settings(
        environment="production",
        jwt_secret="x" * 48,
        cors_origins=["*"],
        debug=True,
        public_base_url="http://em.transvolt.in",
    )
    problems = settings.problems()
    assert any("CORS_ORIGINS" in p for p in problems)
    assert any("DEBUG" in p for p in problems)
    assert any("https" in p for p in problems)


def test_a_fully_configured_production_starts() -> None:
    from app.config import Settings

    settings = Settings(
        environment="production",
        jwt_secret="x" * 48,
        cors_origins=["https://em.transvolt.in"],
        public_base_url="https://em.transvolt.in",
    )
    assert settings.problems() == []
    settings.assert_production_ready()


def test_staging_is_held_to_the_same_bar() -> None:
    """Staging holds real data and real credentials."""
    from app.config import Settings

    assert Settings(environment="staging").problems()


# --- Microsoft sign-in -------------------------------------------------------


async def test_sso_config_says_off_when_not_configured(
    client: AsyncClient,
) -> None:
    """So the sign-in card can drop the button rather than offer one that
    fails when tapped."""
    r = await client.get("/auth/sso/config")
    assert r.status_code == 200, r.text
    assert r.json()["enabled"] is False


async def test_sso_config_needs_no_token(client: AsyncClient) -> None:
    """It is read by the sign-in screen, before anyone could have one."""
    r = await client.get("/auth/sso/config")
    assert r.status_code == 200


async def test_sso_config_reports_the_tenant_when_configured(
    client: AsyncClient, monkeypatch
) -> None:
    from app.config import settings

    monkeypatch.setattr(settings, "ms_tenant_id", "tenant-123", raising=False)
    monkeypatch.setattr(settings, "ms_client_id", "client-456", raising=False)

    body = (await client.get("/auth/sso/config")).json()
    assert body["enabled"] is True
    assert body["tenant_id"] == "tenant-123"
    assert body["client_id"] == "client-456"
    assert body["authority"] == "https://login.microsoftonline.com/tenant-123"
    assert "openid" in body["scopes"]


async def test_an_unverifiable_sso_token_is_refused(client: AsyncClient) -> None:
    r = await client.post("/auth/sso", json={"ms_id_token": "not.a.token"})
    assert r.status_code in (400, 401)
