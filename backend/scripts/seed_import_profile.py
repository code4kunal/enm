"""Provision a site's snag-report import profile from its own spreadsheet.

The format is per site — MBMT's monthly "SNAG REPORT" is one shape, another
site's sheet will be another — so the mapping is *data*, stored against the
site, not code. This writes MBMT's mapping into `site_import_profiles` so the
import wizard offers it as a saved profile instead of asking a manager to bind
32 columns by hand every month.

    python -m scripts.seed_import_profile [SITE_CODE]

The site must already exist; sites are onboarded from the UI.
"""
from __future__ import annotations

import asyncio
import sys

from sqlalchemy import select

from app.db import SessionLocal
from app.models.enums import ImportTarget
from app.models.inspection import InspectionPlan
from app.models.master import Site, WorkType
from app.models.site_import import SiteImportMapping, SiteImportProfile
from app.services.site_config import get_or_create

PROFILE_NAME = "MBMT monthly snag report"

#: target key -> the column header as the reader reports it.
#:
#: The sheet wraps long headings across lines ("TYPE OF WORK"); the reader
#: collapses that whitespace, so a mapping never depends on where the author
#: pressed Alt+Enter.
SNAG_MAPPING: dict[str, str] = {
    "date": "DATE",
    "bus": "VEHICLE NO",
    "work_type": "TYPE OF WORK",
    "complaint": "DRIVER COMPLAINT",
    "defectType": "GROUP",
    "odometer_km": "KMS.",
    "action": "ACTION TAKEN",
    "spares": "PART USED",
    "employee": "ATTEND BY",
    "supervisor": "SUPERVISOR (FLOOR)",
    "driver": "DRIVER NO",
    "route": "ROUTE",
    "loc": "LOCATION",
    "t_bd": "REPORTING TIME",
    "t_mech": "Mech. Attend Time",
    "t_att": "COMPLAINT RESOLVING TIME",
    "loss": "LOSS KMS",
    "status": "COMPLAINT STATUS OPEN /CLOSE",
    "remarks": "REMARKS",
}

#: The same sheet also carries the fleet, so one upload can build the vehicle
#: master before the register rows that reference it.
FLEET_MAPPING: dict[str, str] = {
    "registration_no": "VEHICLE NO",
    "model": "MODEL",
}


async def _upsert(
    session,
    *,
    site_code: str,
    name: str,
    target: ImportTarget,
    mapping: dict[str, str],
    sheet_name: str | None,
) -> str:
    profile = await session.scalar(
        select(SiteImportProfile).where(
            SiteImportProfile.site_code == site_code,
            SiteImportProfile.name == name,
        )
    )
    verb = "updated"
    if profile is None:
        profile = SiteImportProfile(site_code=site_code, name=name)
        session.add(profile)
        verb = "created"

    profile.target = target
    profile.sheet_name = sheet_name
    profile.header_row = 1
    profile.skip_rows = 0
    profile.mappings = [
        SiteImportMapping(target_key=key, source_column=column)
        for key, column in mapping.items()
    ]
    return verb


#: The site's inspection cycles. The daily inspection covers the whole fleet
#: every night (uncapped); the 10-day service is limited by bay time to about
#: five buses, which is exactly what MBMT's own sheet shows.
INSPECTION_PLANS: list[tuple[str, int, int]] = [
    # (work type code, cycle days, nightly cap — 0 means uncapped)
    ("D.I", 1, 0),
    ("10 DAYS SERVICE", 10, 5),
]


async def _seed_plans(session, site_code: str) -> None:
    config = await get_or_create(session, site_code)
    for code, cycle_days, slots_per_day in INSPECTION_PLANS:
        work_type = await session.scalar(
            select(WorkType).where(WorkType.code == code)
        )
        if work_type is None:
            print(f"  skipped {code}: not on the work-type master list")
            continue
        plan = await session.scalar(
            select(InspectionPlan).where(
                InspectionPlan.site_code == site_code,
                InspectionPlan.work_type_id == work_type.id,
            )
        )
        verb = "updated"
        if plan is None:
            plan = InspectionPlan(site_code=site_code, work_type_id=work_type.id)
            session.add(plan)
            verb = "created"
        plan.cycle_days = cycle_days
        plan.slots_per_day = slots_per_day
        plan.is_active = True
        cap = "uncapped" if slots_per_day == 0 else f"{slots_per_day}/night"
        print(f"  {verb}: {code} every {cycle_days}d, {cap}")

    if config.inspection_slots_per_day <= 0:
        config.inspection_slots_per_day = 5


async def main(site_code: str) -> None:
    async with SessionLocal() as session:
        site = await session.get(Site, site_code)
        if site is None:
            sys.exit(
                f"Site {site_code} does not exist — onboard it from Admin → "
                "Sites first."
            )

        for name, target, mapping in (
            (PROFILE_NAME, ImportTarget.snag_report, SNAG_MAPPING),
            (f"{site_code} fleet from snag report", ImportTarget.vehicles, FLEET_MAPPING),
        ):
            # The sheet is named for its month ("Aug-2026"), so the profile
            # leaves it unset and reads the first sheet in the workbook.
            verb = await _upsert(
                session,
                site_code=site_code,
                name=name,
                target=target,
                mapping=mapping,
                sheet_name=None,
            )
            print(f"  {verb}: {name} -> {target.value}")

        await _seed_plans(session, site_code)
        await session.commit()
    print("Import profile and inspection plans ready.")


if __name__ == "__main__":
    asyncio.run(main((sys.argv[1] if len(sys.argv) > 1 else "MBMT").upper()))
