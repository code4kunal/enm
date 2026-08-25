from __future__ import annotations

import pytest
from httpx import AsyncClient
from sqlalchemy import func, select

from app.db import SessionLocal
from app.models.master import SapMaterial, Site, Vehicle
from app.services.sap import client as sap_client
from app.services.sap.masters import sync_site
from tests.conftest import auth_headers


async def _fake_equipment(**kwargs):
    return [
        {"equipment_no": "EQ-1894", "registration_no": "MH40LY1894"},
        {"equipment_no": "EQ-UNKNOWN", "registration_no": "MH00ZZ0000"},
    ]


async def _fake_materials(**kwargs):
    return [
        {"material_no": "MAT-1", "description": "Air dryer cartridge", "uom": "PC"},
        {"material_no": "MAT-2", "description": "Brake pad set", "uom": "SET"},
    ]


async def _fake_flocs(**kwargs):
    return [{"floc": "FLOC-MBMT", "site_code": "MBMT"}]


async def test_sync_site_matches_equipment_materials_and_floc(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(sap_client, "list_equipment", _fake_equipment)
    monkeypatch.setattr(sap_client, "list_materials", _fake_materials)
    monkeypatch.setattr(sap_client, "list_functional_locations", _fake_flocs)

    async with SessionLocal() as session:
        result = await sync_site(session, "MBMT")
        await session.commit()

        assert result.equipment_matched == 1
        assert result.materials_synced == 2
        assert result.flocs_matched == 1

        vehicle = await session.scalar(
            select(Vehicle).where(Vehicle.registration_no == "MH40LY1894")
        )
        assert vehicle.sap_equipment_no == "EQ-1894"

        site = await session.get(Site, "MBMT")
        assert site.sap_floc == "FLOC-MBMT"

        count = await session.scalar(select(func.count()).select_from(SapMaterial))
        assert count == 2


async def test_sync_site_twice_does_not_duplicate_materials(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(sap_client, "list_equipment", _fake_equipment)
    monkeypatch.setattr(sap_client, "list_materials", _fake_materials)
    monkeypatch.setattr(sap_client, "list_functional_locations", _fake_flocs)

    async with SessionLocal() as session:
        await sync_site(session, "MBMT")
        await session.commit()
    async with SessionLocal() as session:
        await sync_site(session, "MBMT")
        await session.commit()

    async with SessionLocal() as session:
        count = await session.scalar(select(func.count()).select_from(SapMaterial))
        assert count == 2

        row = await session.scalar(
            select(SapMaterial).where(SapMaterial.sap_material_no == "MAT-1")
        )
        assert row.description == "Air dryer cartridge"


async def test_sync_now_requires_manager(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(sap_client, "list_equipment", _fake_equipment)
    monkeypatch.setattr(sap_client, "list_materials", _fake_materials)
    monkeypatch.setattr(sap_client, "list_functional_locations", _fake_flocs)

    # TV4105 is the seeded executive.
    h = await auth_headers(client, "TV4105")
    r = await client.post("/sites/MBMT/sap/sync", headers=h)
    assert r.status_code == 403

    # TV4021 is the seeded manager.
    h_mgr = await auth_headers(client, "TV4021")
    r2 = await client.post("/sites/MBMT/sap/sync", headers=h_mgr)
    assert r2.status_code == 200, r2.text
    assert r2.json()["materials_synced"] == 2


async def test_materials_list_is_readable_by_any_site_user(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(sap_client, "list_equipment", _fake_equipment)
    monkeypatch.setattr(sap_client, "list_materials", _fake_materials)
    monkeypatch.setattr(sap_client, "list_functional_locations", _fake_flocs)

    h_mgr = await auth_headers(client, "TV4021")
    await client.post("/sites/MBMT/sap/sync", headers=h_mgr)

    h = await auth_headers(client, "TV4105")
    r = await client.get("/sites/MBMT/sap/materials", headers=h)
    assert r.status_code == 200, r.text
    names = {m["sap_material_no"] for m in r.json()["items"]}
    assert names == {"MAT-1", "MAT-2"}
