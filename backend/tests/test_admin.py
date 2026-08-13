from __future__ import annotations

from httpx import AsyncClient

from tests.conftest import PASSWORD, auth_headers


async def test_non_manager_gets_403(client: AsyncClient) -> None:
    sup = await auth_headers(client, "TV4102")
    r = await client.get("/admin/users", headers=sup)
    assert r.status_code == 403
    assert r.json()["error"]["code"] == "FORBIDDEN"


async def test_create_user_requires_temp_password_without_email(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    r = await client.post(
        "/admin/users",
        json={
            "name": "Sunil Patil",
            "user_id": "TV9001",
            "email": None,
            "role": "executive",
            "depot_access": ["MBMT"],
        },
        headers=h,
    )
    assert r.status_code == 400
    assert r.json()["error"]["fields"]["temp_password"] == "required"


async def test_create_user_and_first_login_must_reset(client: AsyncClient) -> None:
    h = await auth_headers(client)
    r = await client.post(
        "/admin/users",
        json={
            "name": "Sunil Patil",
            "user_id": "tv9001",
            "role": "executive",
            "depot_access": ["MBMT", "mbmt", "UMT"],
            "temp_password": "Temp@1234",
        },
        headers=h,
    )
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["user_id"] == "TV9001"
    assert body["depot_access"] == ["MBMT", "UMT"]
    assert body["must_reset_password"] is True

    login = await client.post(
        "/auth/login", json={"user_id": "TV9001", "password": "Temp@1234"}
    )
    assert login.status_code == 200
    assert login.json()["user"]["must_reset_password"] is True


async def test_duplicate_user_id_is_409(client: AsyncClient) -> None:
    h = await auth_headers(client)
    r = await client.post(
        "/admin/users",
        json={
            "name": "Clone",
            "user_id": "TV4102",
            "role": "executive",
            "depot_access": ["MBMT"],
            "temp_password": "Temp@1234",
        },
        headers=h,
    )
    assert r.status_code == 409
    assert r.json()["error"]["message"] == "User ID already exists"


async def test_unknown_depot_rejected(client: AsyncClient) -> None:
    h = await auth_headers(client)
    r = await client.post(
        "/admin/users",
        json={
            "name": "Ghost",
            "user_id": "TV9002",
            "role": "executive",
            "depot_access": ["NOPE"],
            "temp_password": "Temp@1234",
        },
        headers=h,
    )
    assert r.status_code == 400
    assert "depot_access" in r.json()["error"]["fields"]


async def test_status_filter_chips(client: AsyncClient) -> None:
    h = await auth_headers(client)
    target = (
        await client.get("/admin/users", params={"q": "TV4105"}, headers=h)
    ).json()["items"][0]
    await client.post(f"/admin/users/{target['id']}/deactivate", headers=h)

    active = await client.get("/admin/users", params={"status": "active"}, headers=h)
    inactive = await client.get(
        "/admin/users", params={"status": "inactive"}, headers=h
    )
    everyone = await client.get("/admin/users", params={"status": "all"}, headers=h)
    assert inactive.json()["total"] == 1
    assert active.json()["total"] + inactive.json()["total"] == everyone.json()["total"]


async def test_update_user_depot_access(client: AsyncClient) -> None:
    h = await auth_headers(client)
    target = (
        await client.get("/admin/users", params={"q": "TV4102"}, headers=h)
    ).json()["items"][0]

    r = await client.put(
        f"/admin/users/{target['id']}",
        json={"role": "manager", "depot_access": ["MBMT", "UMT"]},
        headers=h,
    )
    assert r.status_code == 200
    assert r.json()["role"] == "manager"
    assert r.json()["depot_access"] == ["MBMT", "UMT"]


async def test_reset_password_forces_new_credentials(client: AsyncClient) -> None:
    h = await auth_headers(client)
    target = (
        await client.get("/admin/users", params={"q": "TV4105"}, headers=h)
    ).json()["items"][0]

    r = await client.post(
        f"/admin/users/{target['id']}/reset-password",
        json={"temp_password": "Fresh@123"},
        headers=h,
    )
    assert r.status_code == 204

    old = await client.post(
        "/auth/login", json={"user_id": "TV4105", "password": PASSWORD}
    )
    assert old.status_code == 401

    new = await client.post(
        "/auth/login", json={"user_id": "TV4105", "password": "Fresh@123"}
    )
    assert new.status_code == 200
    assert new.json()["user"]["must_reset_password"] is True


async def test_cannot_deactivate_self(client: AsyncClient) -> None:
    h = await auth_headers(client)
    me = (await client.get("/auth/me", headers=h)).json()
    r = await client.post(f"/admin/users/{me['id']}/deactivate", headers=h)
    assert r.status_code == 409


async def test_reactivate_user(client: AsyncClient) -> None:
    h = await auth_headers(client)
    target = (
        await client.get("/admin/users", params={"q": "TV4105"}, headers=h)
    ).json()["items"][0]
    await client.post(f"/admin/users/{target['id']}/deactivate", headers=h)
    r = await client.post(f"/admin/users/{target['id']}/activate", headers=h)
    assert r.status_code == 200
    assert r.json()["is_active"] is True

    login = await client.post(
        "/auth/login", json={"user_id": "TV4105", "password": PASSWORD}
    )
    assert login.status_code == 200
