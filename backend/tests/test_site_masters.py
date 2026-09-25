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
