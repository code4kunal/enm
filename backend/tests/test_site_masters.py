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


async def test_deactivated_spare_part_still_resolves_on_an_existing_entry(
    client: AsyncClient,
) -> None:
    """Plan Review Focus #5: hiding a spare part from the picker must not
    corrupt an entry that already references it -- the FK stays valid and
    the entry keeps reading/displaying it after is_active flips false."""
    from tests.test_entries import work_done

    h = await auth_headers(client)
    part = (
        await client.post(
            "/sites/MBMT/spare-parts",
            json={"part_no": "SP-3001", "name": "Wiper blade"},
            headers=h,
        )
    ).json()

    payload = work_done()
    payload["data"]["spare_part_ids"] = [part["id"]]
    entry = (await client.post("/entries", json=payload, headers=h)).json()
    assert entry["data"]["spare_parts"][0]["part_id"] == part["id"]

    deactivated = await client.post(
        f"/spare-parts/{part['id']}/deactivate", headers=h
    )
    assert deactivated.status_code == 200, deactivated.text

    listed = (await client.get("/sites/MBMT/spare-parts", headers=h)).json()
    assert not any(p["id"] == part["id"] for p in listed["items"])

    refetched = (await client.get(f"/entries/{entry['id']}", headers=h)).json()
    assert refetched["data"]["spare_parts"][0]["part_id"] == part["id"]
    assert refetched["data"]["spare_parts"][0]["part_no"] == "SP-3001"


async def test_deactivated_driver_still_resolves_on_an_existing_entry(
    client: AsyncClient,
) -> None:
    """Same rule as spare parts, for the driver on a breakdown entry."""
    from tests.test_entries import breakdown

    h = await auth_headers(client)
    driver = (
        await client.post(
            "/sites/MBMT/drivers",
            json={"driver_code": "DRV-3001", "name": "S. Rao"},
            headers=h,
        )
    ).json()

    payload = breakdown()
    payload["data"]["driver_id"] = driver["driver_code"]
    entry = (await client.post("/entries", json=payload, headers=h)).json()
    assert entry["data"]["driver_id"] == driver["driver_code"]

    deactivated = await client.post(
        f"/drivers/{driver['id']}/deactivate", headers=h
    )
    assert deactivated.status_code == 200, deactivated.text

    listed = (await client.get("/sites/MBMT/drivers", headers=h)).json()
    assert not any(d["id"] == driver["id"] for d in listed["items"])

    refetched = (await client.get(f"/entries/{entry['id']}", headers=h)).json()
    assert refetched["data"]["driver_id"] == driver["driver_code"]


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
