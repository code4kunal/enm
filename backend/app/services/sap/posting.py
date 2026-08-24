"""Job cards: opening one, and the retryable posting chain.

See docs/superpowers/specs/2026-08-24-sap-pm-enm-integration-design.md,
section 3. `open_job_card` is called only when a saved entry or inspection
names at least one material — no materials, no SAP call, ever.
"""
from __future__ import annotations

import logging
from datetime import UTC, datetime
from decimal import Decimal

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import ValidationError
from app.models.enums import AuditAction, JobCardSource, JobCardStatus
from app.models.job_card import JobCard, JobCardComponent
from app.models.master import Vehicle
from app.models.user import User
from app.services import audit
from app.services.sap import client as sap_client

logger = logging.getLogger("enm.sap")


class MaterialLine:
    """What the caller (entries.py / checklists.py) already validated via
    `MaterialIn` — kept as a plain carrier so this module has no Pydantic
    dependency."""

    __slots__ = ("sap_material_no", "qty_required")

    def __init__(self, sap_material_no: str, qty_required: Decimal) -> None:
        self.sap_material_no = sap_material_no
        self.qty_required = qty_required


async def open_job_card(
    session: AsyncSession,
    *,
    source: JobCardSource,
    source_id: str,
    site_code: str,
    vehicle: Vehicle,
    materials: list[MaterialLine],
    actor: User,
    streams_breakdown_id: str | None = None,
    mechanic: str | None = None,
    hours: Decimal | None = None,
    work_done: str | None = None,
) -> JobCard:
    """Creates the draft row and its component lines, then attempts posting
    once. Never called with an empty `materials` — the caller decides that."""
    if not vehicle.sap_equipment_no:
        raise ValidationError(
            f"{vehicle.registration_no} has no SAP equipment number — "
            "sync the fleet from SAP before opening a job card for it",
            {"vehicle": "no SAP equipment number"},
        )

    job_card = JobCard(
        site_code=site_code,
        bus_id=vehicle.id,
        source=source,
        source_id=source_id,
        streams_breakdown_id=streams_breakdown_id,
        mechanic=mechanic,
        hours=hours,
        work_done=work_done,
        created_by_id=actor.id,
    )
    job_card.components = [
        JobCardComponent(
            sap_material_no=m.sap_material_no, qty_required=m.qty_required
        )
        for m in materials
    ]
    session.add(job_card)
    await session.flush()

    await audit.record(
        session,
        actor_id=actor.id,
        action=AuditAction.job_card_created,
        object_type="job_card",
        object_id=job_card.id,
        after={"source": source.value, "source_id": source_id},
    )

    await post_job_card(session, job_card)
    return job_card


async def post_job_card(session: AsyncSession, job_card: JobCard) -> None:
    """The C-chain, resumed from whichever checkpoint is still unset.

    Every step persists its result before the next runs — a crash between
    steps resumes at the right one rather than reposting from scratch. Any
    failure sets status=error and swallows the exception: the save that
    triggered this must succeed even when SAP is down.
    """
    try:
        vehicle = await session.get(Vehicle, job_card.bus_id)

        if job_card.sap_notification_no is None:
            job_card.sap_notification_no = await sap_client.create_notification(
                equipment_no=vehicle.sap_equipment_no,
                description=job_card.work_done or "ENM job card",
            )
            await session.flush()

        if job_card.sap_order_no is None:
            job_card.sap_order_no = await sap_client.create_order(
                notification_no=job_card.sap_notification_no
            )
            await session.flush()

        if job_card.components_added_at is None:
            await sap_client.add_components(
                order_no=job_card.sap_order_no,
                components=[
                    {"material_no": c.sap_material_no, "qty": c.qty_required}
                    for c in job_card.components
                ],
            )
            job_card.components_added_at = datetime.now(UTC)
            await session.flush()

        if job_card.confirmed_at is None:
            await sap_client.confirm(
                order_no=job_card.sap_order_no,
                mechanic=job_card.mechanic,
                hours=job_card.hours,
                work_done=job_card.work_done,
            )
            job_card.confirmed_at = datetime.now(UTC)
            await session.flush()

        job_card.status = JobCardStatus.posted
        job_card.posted_at = datetime.now(UTC)
        job_card.last_sap_error = None
        await audit.record(
            session,
            actor_id=job_card.created_by_id,
            action=AuditAction.job_card_posted,
            object_type="job_card",
            object_id=job_card.id,
            after={
                "sap_notification_no": job_card.sap_notification_no,
                "sap_order_no": job_card.sap_order_no,
            },
        )
    except Exception as exc:  # noqa: BLE001 — the triggering save must still succeed
        job_card.status = JobCardStatus.error
        job_card.last_sap_error = str(exc)[:2000]
        logger.warning("job card %s posting failed: %s", job_card.id, exc)
        await audit.record(
            session,
            actor_id=job_card.created_by_id,
            action=AuditAction.job_card_post_failed,
            object_type="job_card",
            object_id=job_card.id,
            after={"error": job_card.last_sap_error},
        )
    job_card.updated_at = datetime.now(UTC)
    await session.flush()


async def retry_errored_job_cards() -> int:
    """Scheduler entry point — sweeps every `status=error` card and resumes
    posting. Returns how many it attempted."""
    from app.db import SessionLocal

    async with SessionLocal() as session:
        cards = (
            await session.scalars(
                select(JobCard).where(JobCard.status == JobCardStatus.error)
            )
        ).all()
        for job_card in cards:
            await post_job_card(session, job_card)
        await session.commit()
        return len(cards)
