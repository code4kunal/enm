from __future__ import annotations

from httpx import AsyncClient

from tests.conftest import auth_headers


async def test_create_and_list_spare_parts(client: AsyncClient) -> None:
    h = await auth_headers(client)
    created = (
        await client.post(
            "/sites/MBMT/spare-parts",
            json={"part_no": "SP-1001", "name": "Brake pad set"},
            headers=h,
        )
    ).json()
    assert created["part_no"] == "SP-1001"

    listed = (await client.get("/sites/MBMT/spare-parts", headers=h)).json()
    assert any(p["part_no"] == "SP-1001" for p in listed["items"])


async def test_spare_part_no_is_unique_per_site(client: AsyncClient) -> None:
    h = await auth_headers(client)
    await client.post(
        "/sites/MBMT/spare-parts", json={"part_no": "SP-2001", "name": "Filter"}, headers=h
    )
    dup = await client.post(
        "/sites/MBMT/spare-parts",
        json={"part_no": "SP-2001", "name": "Filter (dup)"},
        headers=h,
    )
    assert dup.status_code == 409


async def test_create_and_list_drivers(client: AsyncClient) -> None:
    h = await auth_headers(client)
    created = (
        await client.post(
            "/sites/MBMT/drivers",
            json={"driver_code": "DRV-1001", "name": "Rakesh Yadav"},
            headers=h,
        )
    ).json()
    assert created["driver_code"] == "DRV-1001"

    listed = (await client.get("/sites/MBMT/drivers", headers=h)).json()
    assert any(d["driver_code"] == "DRV-1001" for d in listed["items"])


async def test_driver_code_is_unique_per_site(client: AsyncClient) -> None:
    h = await auth_headers(client)
    await client.post(
        "/sites/MBMT/drivers", json={"driver_code": "DRV-2001", "name": "A. Khan"}, headers=h
    )
    dup = await client.post(
        "/sites/MBMT/drivers",
        json={"driver_code": "DRV-2001", "name": "A. Khan (dup)"},
        headers=h,
    )
    assert dup.status_code == 409
