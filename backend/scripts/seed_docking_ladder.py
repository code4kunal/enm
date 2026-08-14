"""Provision a site's docking ladder from its own maintenance schedules.

A docking is not on the calendar. MBMT keeps one schedule document per odometer
mark — 3k, then every 10k to 1.20 lakh — and each is a different job, so each
becomes a rung the scheduler books a bus onto when it has run the distance.

The rungs are read from the file names in the depot's docking folder rather
than typed here, so adding a 1.30 lakh schedule to the folder adds the rung.

    python -m scripts.seed_docking_ladder [SITE_CODE] [DOCKING_DIR]

Idempotent: a rung that already exists is left alone apart from its name and
order, so a site that renamed one keeps the rename.
"""
from __future__ import annotations

import asyncio
import re
import sys
from pathlib import Path

from sqlalchemy import func, select

from app.db import SessionLocal
from app.models.master import WorkType
from app.models.site_config import ServicePlan

DEFAULT_SITE = "MBMT"
DEFAULT_DIR = "/srv/data/MBMT/August/9M DOCKING SHEET"

#: The work type a docking books.
WORK_TYPE_CODE = "P.M"

#: "3k", "90k", "1Lakh", "1.10Lakh", "100K", "1.20K" — the depot writes the
#: same number several ways, and a lakh is 100,000.
KM = re.compile(
    r"^(?P<value>\d+(?:\.\d+)?)\s*(?P<unit>lakh|lac|k)\b", re.IGNORECASE
)


def rung_km(file_name: str) -> int | None:
    """The odometer mark a schedule document is for."""
    match = KM.match(file_name.strip())
    if match is None:
        return None
    value = float(match.group("value"))
    unit = match.group("unit").lower()

    if unit.startswith("la"):
        return int(value * 100_000)
    # "1.10K" in the 12M folder means 1.10 lakh, not 1,100 km — a fractional
    # "k" is the depot writing lakh with the wrong letter.
    if value < 10:
        return int(value * 100_000) if "." in match.group("value") else int(value * 1000)
    return int(value * 1000)


def read_ladder(folder: Path) -> list[int]:
    """Every rung the folder describes, lowest first and deduplicated."""
    rungs: set[int] = set()
    for path in folder.iterdir():
        if path.suffix.lower() not in {".pdf", ".xlsx"}:
            continue
        km = rung_km(path.name)
        if km:
            rungs.add(km)
    return sorted(rungs)


def rung_name(km: int) -> str:
    if km >= 100_000:
        return f"{km / 100_000:.2f}".rstrip("0").rstrip(".") + " lakh docking"
    return f"{km // 1000}k docking"


def rung_code(km: int) -> str:
    return f"D{km // 1000}K"


async def seed(site_code: str, folder: Path) -> None:
    rungs = read_ladder(folder)
    if not rungs:
        raise SystemExit(f"No maintenance schedules recognised in {folder}")

    async with SessionLocal() as session:
        work_type = await session.scalar(
            select(WorkType).where(
                func.upper(WorkType.code) == WORK_TYPE_CODE.upper()
            )
        )
        if work_type is None:
            raise SystemExit(
                f"No {WORK_TYPE_CODE} work type — run scripts.seed first"
            )

        added = 0
        for order, km in enumerate(rungs):
            code = rung_code(km)
            plan = await session.scalar(
                select(ServicePlan).where(
                    ServicePlan.site_code == site_code,
                    ServicePlan.code == code,
                )
            )
            if plan is None:
                plan = ServicePlan(
                    site_code=site_code, code=code, name=rung_name(km)
                )
                session.add(plan)
                added += 1
            plan.milestone_km = km
            plan.sort_order = order
            plan.work_type_id = work_type.id
            plan.is_active = True

        await session.commit()

    print(f"  {len(rungs)} rungs ({added} new): " + ", ".join(
        f"{km // 1000}k" for km in rungs
    ))
    print("Docking ladder ready.")


if __name__ == "__main__":
    site = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SITE
    folder = Path(sys.argv[2] if len(sys.argv) > 2 else DEFAULT_DIR)
    asyncio.run(seed(site, folder))
