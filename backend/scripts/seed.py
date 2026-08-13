"""Idempotent seed: the tenant-wide master lists and one super admin.

Deliberately **no sites, vehicles, users or entries** beyond the bootstrap
super admin. Sites and their staff are onboarded from the UI and live only in
the database; anything seeded here would be dummy data pretending to be real.

    python -m scripts.seed
"""
from __future__ import annotations

import asyncio
import os

from sqlalchemy import func, select

from app.db import SessionLocal
from app.models.enums import Register, Role
from app.models.master import DefectSource, DefectType, WorkType
from app.models.user import User
from app.security import hash_password

#: Backs the "Source of Defect" dropdown on the Daily Work Done register.
DEFECT_SOURCES = [
    "Driver report",
    "Daily inspection",
    "PM schedule",
    "Breakdown",
    "Site supervisor",
    "Telematics alert",
    "Other",
]

#: Backs "Type of Defect" on work-done, driver-complaint and PM registers.
#:
#: These are the GROUP values as written on MBMT's own snag report, not an
#: invented taxonomy — an imported row has to match a master entry exactly, and
#: the sheet is the authority on what the fitters actually write.
DEFECT_TYPES = [
    "BODY REFURBISHMENT",
    "BODY ELECTRICALS",
    "ELECTRICAL",
    "SUSPENSION",
    "HV SYSTEM",
    "LV SYSTEM",
    "DOOR SYSTEM",
    "STEERING SYSTEM",
    "BRAKE SYSTEM",
    "COOLING SYSTEM",
    "TRANSMISSION/DRIVER SYSTEM",
    "CHARGING SYSTEM",
    "ITS SYSTEM",
    "AIR CONDITION",
    "TYRE",
    "OTHERS",
]

#: The "TYPE OF WORK" column on the snag report, and the register each code
#: routes its rows to. Codes are exactly as written on the sheet.
#:
#: `C/F` is a carried-forward continuation of an earlier job and `P.M` / `PM`
#: are dockings; both are recorded, the first as day-to-day work done and the
#: second against the PM schedule.
WORK_TYPES = [
    ("B.D", "Breakdown", Register.breakdown),
    ("D.C", "Driver complaint", Register.driver_complaint),
    ("DEPOT", "Daily work", Register.work_done),
    ("C/F", "Carried forward", Register.work_done),
    ("D.I", "Daily inspection", Register.pm_schedule),
    ("10 DAYS SERVICE", "10 day inspection", Register.pm_schedule),
    ("P.M", "Preventive maintenance docking", Register.pm_schedule),
    ("PM", "Preventive maintenance docking", Register.pm_schedule),
]


async def _seed_list(session, model, names: list[str]) -> int:
    """Insert by name, case-insensitively. Never renames or reorders what a
    site has already edited."""
    added = 0
    for order, name in enumerate(names):
        exists = await session.scalar(
            select(model.id).where(func.lower(model.name) == name.lower())
        )
        if not exists:
            session.add(model(name=name, sort_order=order))
            added += 1
    return added


async def _seed_work_types(session) -> int:
    """Insert by code. Never re-routes a code an operator has already changed."""
    added = 0
    for order, (code, name, register) in enumerate(WORK_TYPES):
        exists = await session.scalar(
            select(WorkType.id).where(func.upper(WorkType.code) == code)
        )
        if not exists:
            session.add(
                WorkType(code=code, name=name, register=register, sort_order=order)
            )
            added += 1
    return added


async def seed() -> None:
    async with SessionLocal() as session:
        sources = await _seed_list(session, DefectSource, DEFECT_SOURCES)
        types = await _seed_list(session, DefectType, DEFECT_TYPES)
        work = await _seed_work_types(session)
        print(
            f"  defect sources: +{sources}, defect types: +{types}, "
            f"work types: +{work}"
        )

        handle = os.environ.get("BOOTSTRAP_SUPERADMIN_USER_ID", "KUNAL").upper()
        password = os.environ.get("BOOTSTRAP_SUPERADMIN_PASSWORD", "admin")
        name = os.environ.get("BOOTSTRAP_SUPERADMIN_NAME", "Kunal Saxena")

        exists = await session.scalar(select(User.id).where(User.user_id == handle))
        if exists:
            print(f"  super admin {handle}: already present")
        else:
            session.add(
                User(
                    name=name,
                    user_id=handle,
                    email=os.environ.get("BOOTSTRAP_SUPERADMIN_EMAIL") or None,
                    role=Role.super_admin,
                    password_hash=hash_password(password),
                    # A super admin's site_access is empty and ignored — it
                    # reaches every site, including ones onboarded later.
                    must_reset_password=False,
                    site_links=[],
                )
            )
            print(f"  super admin: {handle} / {password}")

        await session.commit()
    print("Seed complete.")


if __name__ == "__main__":
    asyncio.run(seed())
