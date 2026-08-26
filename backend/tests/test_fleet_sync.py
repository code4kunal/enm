from __future__ import annotations

from httpx import AsyncClient
from sqlalchemy import select

from app.db import SessionLocal
from app.models.master import Vehicle
from app.services import siteops
from tests.conftest import SUPER_ADMIN, auth_headers

SITEOPS_ROWS = [
    {"vehicle_no": "mh04ly1001", "make": "EKA", "model": "EV9M", "ac_nac": "9M NAC"},
    {"vehicle_no": "MH04LY1002", "make": "EKA", "model": "EV12M", "ac_nac": "12M AC"},
    {"vehicle_no": "MH04LY1003", "make": "EKA", "model": "EV12M", "ac_nac": "12M NAC"},
    {"vehicle_no": "MH04LY1004", "make": "EKA", "model": "EVX", "ac_nac": "Unknown"},
    {"vehicle_no": "", "make": "EKA", "model": "Ghost", "ac_nac": "9M"},
]


def _fake_list_all_vehicles(rows: list[dict]):
    async def fake(site_id: str) -> list[dict]:
        return rows

    return fake


async def test_sync_creates_vehicles_and_maps_checklist_variant(
    client: AsyncClient, monkeypatch
) -> None:
    monkeypatch.setattr(
        siteops, "list_all_vehicles", _fake_list_all_vehicles(SITEOPS_ROWS)
    )
    h = await auth_headers(client, SUPER_ADMIN)

    r = await client.post(
        "/sites/MBMT/vehicles/sync-from-siteops",
        json={"siteops_site_id": "siteops-uuid-1"},
        headers=h,
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["created"] == 4
    assert body["skipped_no_registration"] == 1

    async with SessionLocal() as session:
        rows = (
            await session.scalars(
                select(Vehicle).where(Vehicle.site_code == "MBMT")
            )
        ).all()
    by_reg = {v.registration_no: v for v in rows}
    assert by_reg["MH04LY1001"].checklist_variant == "9M"
    assert by_reg["MH04LY1002"].checklist_variant == "12M AC"
    assert by_reg["MH04LY1003"].checklist_variant == "12M Non-AC"
    assert by_reg["MH04LY1004"].checklist_variant is None


async def test_sync_is_idempotent_and_never_overwrites_a_set_variant(
    client: AsyncClient, monkeypatch
) -> None:
    monkeypatch.setattr(
        siteops, "list_all_vehicles", _fake_list_all_vehicles(SITEOPS_ROWS)
    )
    h = await auth_headers(client, SUPER_ADMIN)

    await client.post(
        "/sites/MBMT/vehicles/sync-from-siteops",
        json={"siteops_site_id": "siteops-uuid-1"},
        headers=h,
    )

    # A depot corrects the variant SiteOps' free text mapped wrong.
    async with SessionLocal() as session:
        v = await session.scalar(
            select(Vehicle).where(Vehicle.registration_no == "MH04LY1001")
        )
        v.checklist_variant = "12M AC"
        await session.commit()

    again = await client.post(
        "/sites/MBMT/vehicles/sync-from-siteops",
        json={"siteops_site_id": "siteops-uuid-1"},
        headers=h,
    )
    body = again.json()
    assert body["created"] == 0
    assert body["already_present"] == 4

    async with SessionLocal() as session:
        v = await session.scalar(
            select(Vehicle).where(Vehicle.registration_no == "MH04LY1001")
        )
        assert v.checklist_variant == "12M AC"


async def test_sync_never_moves_a_vehicle_owned_by_another_site(
    client: AsyncClient, monkeypatch
) -> None:
    h = await auth_headers(client, SUPER_ADMIN)
    # MH40LY1894 already exists on MBMT in the seeded fixture — reuse it as
    # "owned by a different site" from UMT's point of view.
    monkeypatch.setattr(
        siteops,
        "list_all_vehicles",
        _fake_list_all_vehicles(
            [{"vehicle_no": "MH40LY1894", "make": "", "model": "", "ac_nac": None}]
        ),
    )

    r = await client.post(
        "/sites/UMT/vehicles/sync-from-siteops",
        json={"siteops_site_id": "siteops-uuid-2"},
        headers=h,
    )
    assert r.status_code == 200, r.text
    assert r.json()["owned_elsewhere"] == 1

    async with SessionLocal() as session:
        v = await session.scalar(
            select(Vehicle).where(Vehicle.registration_no == "MH40LY1894")
        )
        assert v.site_code == "MBMT"


async def test_sync_is_manager_only(client: AsyncClient, monkeypatch) -> None:
    monkeypatch.setattr(siteops, "list_all_vehicles", _fake_list_all_vehicles([]))
    supervisor = await auth_headers(client, "TV4102")
    r = await client.post(
        "/sites/MBMT/vehicles/sync-from-siteops",
        json={"siteops_site_id": "siteops-uuid-1"},
        headers=supervisor,
    )
    assert r.status_code == 403
