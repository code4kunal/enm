from __future__ import annotations

from datetime import date
from decimal import Decimal

import pytest
from httpx import AsyncClient
from sqlalchemy import select
from sqlalchemy.orm import selectinload

from app.db import SessionLocal
from app.models.enums import JobCardSource, JobCardStatus
from app.models.job_card import JobCard, JobCardComponent
from app.models.master import Vehicle
from app.models.user import User
from app.services.sap import client as sap_client
from app.services.sap.posting import retry_errored_job_cards
from tests.conftest import SUPER_ADMIN, auth_headers

TODAY = date.today().isoformat()


def _refuse(*args, **kwargs):
    raise AssertionError("SAP must not be called when no materials are present")


def work_done_payload(bus: str = "MH40LY1894", materials: list[dict] | None = None) -> dict:
    body = {
        "register": "work_done",
        "site": "MBMT",
        "date": TODAY,
        "data": {
            "shift": "A",
            "bus_no": bus,
            "reported_defects": "Brake pressure dropping",
            "defect_source": "Driver report",
            "defect_type": "Brakes & air system",
            "attended_details": "Replaced air dryer cartridge",
            "spare_parts_used": "Air dryer cartridge x1",
            "employee": "S. Pawar",
        },
    }
    if materials is not None:
        body["materials"] = materials
    return body


async def _job_card_for(entry_id: str) -> JobCard | None:
    async with SessionLocal() as session:
        return await session.scalar(
            select(JobCard)
            .where(JobCard.source_id == entry_id)
            .options(selectinload(JobCard.components))
        )


async def test_no_materials_never_calls_sap(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    for fn in (
        "create_notification",
        "create_order",
        "add_components",
        "confirm",
        "teco",
        "read_order",
        "get_equipment",
    ):
        monkeypatch.setattr(sap_client, fn, _refuse)

    h = await auth_headers(client)
    r = await client.post("/entries", json=work_done_payload(), headers=h)
    assert r.status_code == 201, r.text

    async with SessionLocal() as session:
        count = await session.scalar(select(JobCard).limit(1))
        assert count is None


async def test_materials_opens_and_posts_a_job_card(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    calls: list[str] = []

    async def fake_create_notification(**kwargs):
        calls.append("notification")
        return "NOTIF-1"

    async def fake_create_order(**kwargs):
        calls.append("order")
        return "ORDER-1"

    async def fake_add_components(**kwargs):
        calls.append("components")

    async def fake_confirm(**kwargs):
        calls.append("confirm")

    monkeypatch.setattr(sap_client, "create_notification", fake_create_notification)
    monkeypatch.setattr(sap_client, "create_order", fake_create_order)
    monkeypatch.setattr(sap_client, "add_components", fake_add_components)
    monkeypatch.setattr(sap_client, "confirm", fake_confirm)

    h = await auth_headers(client)
    r = await client.post(
        "/entries",
        json=work_done_payload(
            materials=[{"sap_material_no": "MAT-1", "qty_required": "2.00"}]
        ),
        headers=h,
    )
    assert r.status_code == 201, r.text
    entry_id = r.json()["id"]

    assert calls == ["notification", "order", "components", "confirm"]

    job_card = await _job_card_for(entry_id)
    assert job_card is not None
    assert job_card.status is JobCardStatus.posted
    assert job_card.sap_notification_no == "NOTIF-1"
    assert job_card.sap_order_no == "ORDER-1"
    assert len(job_card.components) == 1
    assert job_card.components[0].sap_material_no == "MAT-1"
    assert job_card.components[0].qty_required == Decimal("2.00")
    # qty_issued only advances via the nightly reconcile step, not posting.
    assert job_card.components[0].qty_issued == Decimal("0.00")


async def test_a_failed_step_resumes_without_reposting_notification(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    notification_calls = 0
    order_should_fail = True

    async def fake_create_notification(**kwargs):
        nonlocal notification_calls
        notification_calls += 1
        return "NOTIF-2"

    async def fake_create_order(**kwargs):
        if order_should_fail:
            raise RuntimeError("SAP order service down")
        return "ORDER-2"

    async def fake_add_components(**kwargs):
        pass

    async def fake_confirm(**kwargs):
        pass

    monkeypatch.setattr(sap_client, "create_notification", fake_create_notification)
    monkeypatch.setattr(sap_client, "create_order", fake_create_order)
    monkeypatch.setattr(sap_client, "add_components", fake_add_components)
    monkeypatch.setattr(sap_client, "confirm", fake_confirm)

    h = await auth_headers(client)
    r = await client.post(
        "/entries",
        json=work_done_payload(
            materials=[{"sap_material_no": "MAT-2", "qty_required": "1.00"}]
        ),
        headers=h,
    )
    assert r.status_code == 201, r.text
    entry_id = r.json()["id"]

    job_card = await _job_card_for(entry_id)
    assert job_card.status is JobCardStatus.error
    assert job_card.sap_notification_no == "NOTIF-2"
    assert job_card.sap_order_no is None
    assert notification_calls == 1

    order_should_fail = False
    h_super = await auth_headers(client, SUPER_ADMIN)
    r2 = await client.post(
        f"/job-cards/{job_card.id}/retry", headers=h_super
    )
    assert r2.status_code == 200, r2.text
    assert r2.json()["status"] == "posted"
    assert notification_calls == 1  # never re-created


async def test_vehicle_without_sap_equipment_no_is_rejected(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(sap_client, "create_notification", _refuse)

    h = await auth_headers(client)
    r = await client.post(
        "/entries",
        json=work_done_payload(
            bus="MH40LY1895",
            materials=[{"sap_material_no": "MAT-3", "qty_required": "1.00"}],
        ),
        headers=h,
    )
    assert r.status_code == 400, r.text
    assert "vehicle" in r.json()["error"]["fields"]

    async with SessionLocal() as session:
        assert await session.scalar(select(JobCard).limit(1)) is None


async def test_retry_errored_job_cards_advances_them(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def fake_create_notification(**kwargs):
        return "NOTIF-3"

    async def fake_create_order(**kwargs):
        return "ORDER-3"

    async def fake_add_components(**kwargs):
        pass

    async def fake_confirm(**kwargs):
        pass

    monkeypatch.setattr(sap_client, "create_notification", fake_create_notification)
    monkeypatch.setattr(sap_client, "create_order", fake_create_order)
    monkeypatch.setattr(sap_client, "add_components", fake_add_components)
    monkeypatch.setattr(sap_client, "confirm", fake_confirm)

    async with SessionLocal() as session:
        vehicle = await session.scalar(
            select(Vehicle).where(Vehicle.registration_no == "MH40LY1894")
        )
        actor = await session.scalar(select(User).where(User.user_id == SUPER_ADMIN))
        job_card = JobCard(
            site_code="MBMT",
            bus_id=vehicle.id,
            source=JobCardSource.entry,
            source_id="deadbeefdeadbeefdeadbeefdeadbeef",
            status=JobCardStatus.error,
            last_sap_error="previous failure",
            created_by_id=actor.id,
        )
        job_card.components = [
            JobCardComponent(sap_material_no="MAT-4", qty_required=Decimal("3.00"))
        ]
        session.add(job_card)
        await session.commit()
        job_card_id = job_card.id

    attempted = await retry_errored_job_cards()
    assert attempted == 1

    async with SessionLocal() as session:
        refreshed = await session.get(JobCard, job_card_id)
        assert refreshed.status is JobCardStatus.posted


async def test_retry_requires_supervisor(client: AsyncClient) -> None:
    async with SessionLocal() as session:
        vehicle = await session.scalar(
            select(Vehicle).where(Vehicle.registration_no == "MH40LY1894")
        )
        actor = await session.scalar(select(User).where(User.user_id == SUPER_ADMIN))
        job_card = JobCard(
            site_code="MBMT",
            bus_id=vehicle.id,
            source=JobCardSource.entry,
            source_id="cafebabecafebabecafebabecafebabe",
            status=JobCardStatus.error,
            created_by_id=actor.id,
        )
        session.add(job_card)
        await session.commit()
        job_card_id = job_card.id

    # TV4105 is the seeded executive.
    h = await auth_headers(client, "TV4105")
    r = await client.post(f"/job-cards/{job_card_id}/retry", headers=h)
    assert r.status_code == 403

    # TV4102 is the seeded supervisor. Reaches the handler — SAP isn't
    # configured in tests, so post_job_card swallows that into status=error
    # rather than raising; the retry call itself still succeeds.
    h_sup = await auth_headers(client, "TV4102")
    r2 = await client.post(f"/job-cards/{job_card_id}/retry", headers=h_sup)
    assert r2.status_code == 200, r2.text
