"""Default inspection cycles for a newly onboarded site.

MBMT's own rhythm: every bus gets a daily inspection uncapped, and a 10-day
service at about five buses a night (enough to cover a ~57-bus fleet).
"""
from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.inspection import InspectionPlan
from app.models.master import WorkType
from app.services.site_config import get_or_create

#: (work type code, cycle days, nightly cap — 0 = whole fleet)
DEFAULT_INSPECTION_PLANS: list[tuple[str, int, int]] = [
    ("D.I", 1, 0),
    ("10 DAYS SERVICE", 10, 5),
]


async def ensure_default_plans(session: AsyncSession, site_code: str) -> int:
    """Create/refresh the site's D.I and 10-day plans. Returns how many written."""
    config = await get_or_create(session, site_code)
    written = 0
    for code, cycle_days, slots_per_day in DEFAULT_INSPECTION_PLANS:
        work_type = await session.scalar(select(WorkType).where(WorkType.code == code))
        if work_type is None:
            continue
        plan = await session.scalar(
            select(InspectionPlan).where(
                InspectionPlan.site_code == site_code,
                InspectionPlan.work_type_id == work_type.id,
            )
        )
        if plan is None:
            plan = InspectionPlan(site_code=site_code, work_type_id=work_type.id)
            session.add(plan)
        plan.cycle_days = cycle_days
        plan.slots_per_day = slots_per_day
        plan.is_active = True
        written += 1

    if config.inspection_slots_per_day <= 0:
        config.inspection_slots_per_day = 5
    await session.flush()
    return written
