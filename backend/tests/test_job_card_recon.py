from __future__ import annotations

from decimal import Decimal

import pytest
from httpx import AsyncClient
from sqlalchemy import select

from app.db import SessionLocal
from app.models.enums import JobCardReconKind, JobCardSource, JobCardStatus
from app.models.job_card import JobCard, JobCardComponent, JobCardReconException
from app.models.master import Vehicle
from app.models.user import User
from app.services.sap import client as sap_client
from app.services.sap.recon import run_daily_recon
from tests.conftest import SUPER_ADMIN, auth_headers


async def _make_posted_job_card(
    *,
    order_no: str,
    qty_issued: Decimal = Decimal("0"),
    status: JobCardStatus = JobCardStatus.posted,
) -> str:
    async with SessionLocal() as session:
        vehicle = await session.scalar(
            select(Vehicle).where(Vehicle.registration_no == "MH40LY1894")
        )
        actor = await session.scalar(select(User).where(User.user_id == SUPER_ADMIN))
        job_card = JobCard(
            site_code="MBMT",
            bus_id=vehicle.id,
            source=JobCardSource.entry,
            source_id="feedfacefeedfacefeedfacefeedface",
            status=status,
            sap_notification_no="NOTIF-R",
            sap_order_no=order_no,
            created_by_id=actor.id,
        )
        job_card.components = [
            JobCardComponent(
                sap_material_no="MAT-R", qty_required=Decimal("1.00"), qty_issued=qty_issued
            )
        ]
        session.add(job_card)
        await session.commit()
        return job_card.id


async def test_recon_flags_status_mismatch_on_teco(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    await _make_posted_job_card(order_no="ORDER-R1")

    async def fake_read_order(order_no):
        return {"status": "TECO", "qty_issued": {}}

    async def fake_list_orders(since):
        return []

    monkeypatch.setattr(sap_client, "read_order", fake_read_order)
    monkeypatch.setattr(sap_client, "list_orders_created_since", fake_list_orders)

    async with SessionLocal() as session:
        raised = await run_daily_recon(session, "MBMT")
        await session.commit()
        assert raised == 1

        exc = await session.scalar(select(JobCardReconException))
        assert exc.kind is JobCardReconKind.status_mismatch


async def test_recon_flags_qty_mismatch(monkeypatch: pytest.MonkeyPatch) -> None:
    # Status already agrees (issued) so only the qty check is exercised —
    # a real 5-vs-0 mismatch would legitimately also flip the status, which
    # is exactly what the status_mismatch test above already covers.
    await _make_posted_job_card(
        order_no="ORDER-R2", qty_issued=Decimal("0"), status=JobCardStatus.issued
    )

    async def fake_read_order(order_no):
        return {"status": "REL", "qty_issued": {"MAT-R": 5}}

    async def fake_list_orders(since):
        return []

    monkeypatch.setattr(sap_client, "read_order", fake_read_order)
    monkeypatch.setattr(sap_client, "list_orders_created_since", fake_list_orders)

    async with SessionLocal() as session:
        raised = await run_daily_recon(session, "MBMT")
        await session.commit()
        assert raised == 1

        exc = await session.scalar(select(JobCardReconException))
        assert exc.kind is JobCardReconKind.qty_mismatch


async def test_recon_flags_sap_only(monkeypatch: pytest.MonkeyPatch) -> None:
    async def fake_list_orders(since):
        return [{"order_no": "ORDER-ORPHAN"}]

    monkeypatch.setattr(sap_client, "list_orders_created_since", fake_list_orders)

    async with SessionLocal() as session:
        raised = await run_daily_recon(session, "MBMT")
        await session.commit()
        assert raised == 1

        exc = await session.scalar(select(JobCardReconException))
        assert exc.kind is JobCardReconKind.sap_only
        assert exc.job_card_id is None


async def test_recon_finds_nothing_when_in_sync(monkeypatch: pytest.MonkeyPatch) -> None:
    await _make_posted_job_card(order_no="ORDER-R3", qty_issued=Decimal("0"))

    async def fake_read_order(order_no):
        return {"status": "REL", "qty_issued": {"MAT-R": 0}}

    async def fake_list_orders(since):
        return [{"order_no": "ORDER-R3"}]

    monkeypatch.setattr(sap_client, "read_order", fake_read_order)
    monkeypatch.setattr(sap_client, "list_orders_created_since", fake_list_orders)

    async with SessionLocal() as session:
        raised = await run_daily_recon(session, "MBMT")
        await session.commit()
        assert raised == 0


async def test_acknowledge_requires_supervisor(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    async def fake_list_orders(since):
        return [{"order_no": "ORDER-ACK"}]

    monkeypatch.setattr(sap_client, "list_orders_created_since", fake_list_orders)

    async with SessionLocal() as session:
        await run_daily_recon(session, "MBMT")
        await session.commit()
        exc_id = (await session.scalar(select(JobCardReconException))).id

    h = await auth_headers(client, "TV4105")  # seeded executive
    r = await client.post(f"/job-card-recon/{exc_id}/acknowledge", headers=h)
    assert r.status_code == 403

    h_sup = await auth_headers(client, "TV4102")  # seeded supervisor
    r2 = await client.post(f"/job-card-recon/{exc_id}/acknowledge", headers=h_sup)
    assert r2.status_code == 200, r2.text
    assert r2.json()["resolved_at"] is not None

    # Resolved exceptions drop off the open list.
    r3 = await client.get("/sites/MBMT/job-card-recon", headers=h_sup)
    assert r3.json()["items"] == []
