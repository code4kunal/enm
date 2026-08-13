from __future__ import annotations

from httpx import AsyncClient

from tests.conftest import PASSWORD, SUPER_ADMIN, auth_headers


async def test_non_manager_gets_403(client: AsyncClient) -> None:
    sup = await auth_headers(client, "TV4102")
    r = await client.get("/admin/users", headers=sup)
    assert r.status_code == 403
    assert r.json()["error"]["code"] == "FORBIDDEN"


async def test_omitted_password_is_generated_and_echoed_once(
    client: AsyncClient,
) -> None:
    """The admin reads it aloud to a mechanic; it is never retrievable again."""
    h = await auth_headers(client)
    r = await client.post(
        "/admin/users",
        json={
            "name": "Sunil Patil",
            "user_id": "TV9001",
            "email": None,
            "role": "executive",
            "site_access": ["MBMT"],
        },
        headers=h,
    )
    assert r.status_code == 201, r.text
    generated = r.json()["temp_password"]
    assert generated

    login = await client.post(
        "/auth/login", json={"user_id": "TV9001", "password": generated}
    )
    assert login.status_code == 200
    assert login.json()["user"]["must_reset_password"] is True

    # It is not on any later read of the user.
    again = await client.get("/admin/users", params={"q": "TV9001"}, headers=h)
    assert "temp_password" not in again.json()["items"][0]


async def test_create_user_and_first_login_must_reset(client: AsyncClient) -> None:
    h = await auth_headers(client)
    r = await client.post(
        "/admin/users",
        json={
            "name": "Sunil Patil",
            "user_id": "tv9001",
            "role": "executive",
            "site_access": ["MBMT", "mbmt", "UMT"],
            "temp_password": "Temp@1234",
        },
        headers=h,
    )
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["user_id"] == "TV9001"
    assert body["site_access"] == ["MBMT", "UMT"]
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
            "site_access": ["MBMT"],
            "temp_password": "Temp@1234",
        },
        headers=h,
    )
    assert r.status_code == 409
    assert r.json()["error"]["message"] == "User ID already exists"


async def test_unknown_site_rejected(client: AsyncClient) -> None:
    """A super admin reaches every site, so an unknown code is a 400 — for a
    manager the same code is simply outside its reach, and answering 403 keeps
    it from probing which sites exist."""
    admin = await auth_headers(client, SUPER_ADMIN)
    r = await client.post(
        "/admin/users",
        json={
            "name": "Ghost",
            "user_id": "TV9002",
            "role": "executive",
            "site_access": ["NOPE"],
            "temp_password": "Temp@1234",
        },
        headers=admin,
    )
    assert r.status_code == 400
    assert "site_access" in r.json()["error"]["fields"]

    manager = await auth_headers(client)
    r = await client.post(
        "/admin/users",
        json={
            "name": "Ghost",
            "user_id": "TV9003",
            "role": "executive",
            "site_access": ["TDC"],
            "temp_password": "Temp@1234",
        },
        headers=manager,
    )
    assert r.status_code == 403


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


async def test_update_user_site_access(client: AsyncClient) -> None:
    h = await auth_headers(client)
    target = (
        await client.get("/admin/users", params={"q": "TV4102"}, headers=h)
    ).json()["items"][0]

    r = await client.put(
        f"/admin/users/{target['id']}",
        json={"role": "executive", "site_access": ["MBMT", "UMT"]},
        headers=h,
    )
    assert r.status_code == 200
    assert r.json()["role"] == "executive"
    assert r.json()["site_access"] == ["MBMT", "UMT"]


async def test_manager_cannot_mint_a_peer_or_a_super_admin(
    client: AsyncClient,
) -> None:
    """Promotion is a super-admin act."""
    h = await auth_headers(client)
    target = (
        await client.get("/admin/users", params={"q": "TV4102"}, headers=h)
    ).json()["items"][0]

    for role in ("manager", "super_admin"):
        r = await client.put(
            f"/admin/users/{target['id']}", json={"role": role}, headers=h
        )
        assert r.status_code == 403, role

    admin = await auth_headers(client, SUPER_ADMIN)
    r = await client.put(
        f"/admin/users/{target['id']}", json={"role": "manager"}, headers=admin
    )
    assert r.status_code == 200


async def test_super_admin_site_access_stays_empty(client: AsyncClient) -> None:
    """Storing every code would go stale the moment a site is onboarded."""
    admin = await auth_headers(client, SUPER_ADMIN)
    r = await client.post(
        "/admin/users",
        json={
            "name": "Second Admin",
            "user_id": "TV1002",
            "role": "super_admin",
            "site_access": ["MBMT"],
            "temp_password": "Temp@1234",
        },
        headers=admin,
    )
    assert r.status_code == 201, r.text
    assert r.json()["site_access"] == []

    # And it still reaches a site it was never granted.
    h = {"Authorization": f"Bearer {(await client.post('/auth/login', json={'user_id': 'TV1002', 'password': 'Temp@1234'})).json()['access_token']}"}
    assert (await client.get("/sites/TDC/vehicles", headers=h)).status_code == 200


async def test_last_super_admin_cannot_be_removed(client: AsyncClient) -> None:
    admin = await auth_headers(client, SUPER_ADMIN)
    me = (await client.get("/auth/me", headers=admin)).json()

    demote = await client.put(
        f"/admin/users/{me['id']}", json={"role": "manager"}, headers=admin
    )
    assert demote.status_code == 409
    assert "last super admin" in demote.json()["error"]["fields"]["role"]

    # With a second one in place the guard lifts.
    await client.post(
        "/admin/users",
        json={
            "name": "Second Admin",
            "user_id": "TV1002",
            "role": "super_admin",
            "temp_password": "Temp@1234",
        },
        headers=admin,
    )
    second = (
        await client.get("/admin/users", params={"q": "TV1002"}, headers=admin)
    ).json()["items"][0]
    assert (
        await client.post(
            f"/admin/users/{second['id']}/deactivate", headers=admin
        )
    ).status_code == 200


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
    assert r.status_code == 200
    assert r.json()["temp_password"] == "Fresh@123"

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
