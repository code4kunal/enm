"""Daily two-way recon between ENM job cards and SAP orders.

An exception list, not a third editor — see
docs/superpowers/specs/2026-08-24-sap-pm-enm-integration-design.md, section 4.
Nothing here writes to `job_cards` or SAP; a person resolves what's found.
"""
from __future__ import annotations

import logging
from datetime import UTC, datetime, timedelta

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.enums import JobCardReconKind, JobCardStatus
from app.models.job_card import JobCard, JobCardReconException
from app.services import notifications
from app.services.sap import client as sap_client

logger = logging.getLogger("enm.sap")


async def run_daily_recon(session: AsyncSession, site_code: str) -> int:
    """Returns how many new exceptions it raised."""
    cards = (
        await session.scalars(
            select(JobCard).where(
                JobCard.site_code == site_code,
                JobCard.sap_order_no.is_not(None),
            )
        )
    ).all()
    by_order_no = {c.sap_order_no: c for c in cards}
    raised = 0

    for card in cards:
        try:
            order = await sap_client.read_order(card.sap_order_no)
        except Exception as exc:  # noqa: BLE001 — one order's failure must not skip the rest
            logger.warning("recon: could not read SAP order %s: %s", card.sap_order_no, exc)
            continue

        sap_status = order.get("status")
        qty_issued = order.get("qty_issued") or {}
        # TECO -> teco takes priority; otherwise any material actually
        # issued means the order has moved past a bare "posted" draft.
        if sap_status == "TECO":
            expected = JobCardStatus.teco
        elif any(float(q) > 0 for q in qty_issued.values()):
            expected = JobCardStatus.issued
        else:
            expected = None  # nothing SAP-side implies a status change

        if expected is not None and card.status is not expected:
            session.add(
                JobCardReconException(
                    site_code=site_code,
                    job_card_id=card.id,
                    sap_order_no=card.sap_order_no,
                    kind=JobCardReconKind.status_mismatch,
                    detail=(
                        f"SAP order {card.sap_order_no} implies {expected.value}, "
                        f"ENM card is {card.status.value}"
                    ),
                )
            )
            raised += 1

        for component in card.components:
            sap_qty = qty_issued.get(component.sap_material_no)
            if sap_qty is not None and float(sap_qty) != float(component.qty_issued):
                session.add(
                    JobCardReconException(
                        site_code=site_code,
                        job_card_id=card.id,
                        sap_order_no=card.sap_order_no,
                        kind=JobCardReconKind.qty_mismatch,
                        detail=(
                            f"{component.sap_material_no}: SAP shows {sap_qty} "
                            f"issued, ENM shows {component.qty_issued}"
                        ),
                    )
                )
                raised += 1

    try:
        since = datetime.now(UTC) - timedelta(days=1)
        sap_orders = await sap_client.list_orders_created_since(since)
        for row in sap_orders:
            order_no = row.get("order_no")
            if order_no and order_no not in by_order_no:
                session.add(
                    JobCardReconException(
                        site_code=site_code,
                        job_card_id=None,
                        sap_order_no=order_no,
                        kind=JobCardReconKind.sap_only,
                        detail=f"SAP order {order_no} has no matching ENM job card",
                    )
                )
                raised += 1
    except Exception as exc:  # noqa: BLE001 — partial recon beats no recon
        logger.warning("recon: could not list SAP orders for %s: %s", site_code, exc)

    if raised:
        await session.flush()
    return raised


async def run_daily_recon_all_sites() -> None:
    """Scheduler entry point, after the DMR freeze."""
    from app.db import SessionLocal
    from app.models.master import Site

    async with SessionLocal() as session:
        site_codes = (await session.scalars(select(Site.code))).all()
        for code in site_codes:
            try:
                raised = await run_daily_recon(session, code)
                if raised:
                    await notifications.notify_recon_exceptions(session, code, raised)
            except Exception:  # noqa: BLE001 — one site's failure must not skip the rest
                logger.exception("daily recon failed for site %s", code)
        await session.commit()
