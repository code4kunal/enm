from __future__ import annotations

from fastapi import APIRouter
from sqlalchemy import select

from app.deps import CurrentUser, SessionDep, SupervisorUser, assert_site_access
from app.errors import NotFound
from app.models.job_card import JobCard
from app.models.master import Vehicle
from app.schemas.job_card import JobCardList, JobCardOut, MaterialOut
from app.services.sap.posting import post_job_card

router = APIRouter(tags=["job-cards"])


def _out(job_card: JobCard, registration_no: str = "") -> JobCardOut:
    return JobCardOut(
        id=job_card.id,
        site_code=job_card.site_code,
        bus_id=job_card.bus_id,
        registration_no=registration_no,
        source=job_card.source,
        source_id=job_card.source_id,
        status=job_card.status,
        sap_notification_no=job_card.sap_notification_no,
        sap_order_no=job_card.sap_order_no,
        last_sap_error=job_card.last_sap_error,
        components=[
            MaterialOut(
                sap_material_no=c.sap_material_no,
                qty_required=c.qty_required,
                qty_issued=c.qty_issued,
            )
            for c in job_card.components
        ],
        created_at=job_card.created_at,
        updated_at=job_card.updated_at,
    )


@router.get("/sites/{code}/job-cards", response_model=JobCardList)
async def list_job_cards(
    code: str, user: CurrentUser, session: SessionDep
) -> JobCardList:
    site_code = assert_site_access(user, code)
    rows = (
        await session.scalars(
            select(JobCard)
            .where(JobCard.site_code == site_code)
            .order_by(JobCard.created_at.desc())
        )
    ).all()
    vehicles = {
        v.id: v.registration_no
        for v in (
            await session.scalars(
                select(Vehicle).where(Vehicle.id.in_([r.bus_id for r in rows]))
            )
        ).all()
    }
    return JobCardList(
        items=[_out(r, vehicles.get(r.bus_id, "")) for r in rows]
    )


@router.post("/job-cards/{job_card_id}/retry", response_model=JobCardOut)
async def retry_job_card(
    job_card_id: str, user: SupervisorUser, session: SessionDep
) -> JobCardOut:
    job_card = await session.get(JobCard, job_card_id)
    if job_card is None:
        raise NotFound("Job card not found")
    assert_site_access(user, job_card.site_code)
    await post_job_card(session, job_card)
    await session.commit()
    await session.refresh(job_card)
    vehicle = await session.get(Vehicle, job_card.bus_id)
    return _out(job_card, vehicle.registration_no if vehicle else "")
