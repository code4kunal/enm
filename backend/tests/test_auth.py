from __future__ import annotations

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
