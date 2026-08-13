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
from app.models.enums import DefectCategory, Register, Role
from app.models.master import DefectSource, DefectType, WorkType
from app.models.report import UnitType
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
#: `category` is what the Daily Maintenance Report splits breakdowns and
#: defects on. A manager can re-map any of them; these are the defaults.
DEFECT_TYPES = [
    ("BODY REFURBISHMENT", DefectCategory.body),
    ("BODY ELECTRICALS", DefectCategory.electrical),
    ("ELECTRICAL", DefectCategory.electrical),
    ("SUSPENSION", DefectCategory.mechanical),
    ("HV SYSTEM", DefectCategory.electrical),
    ("LV SYSTEM", DefectCategory.electrical),
    ("DOOR SYSTEM", DefectCategory.mechanical),
    ("STEERING SYSTEM", DefectCategory.mechanical),
    ("BRAKE SYSTEM", DefectCategory.mechanical),
    ("COOLING SYSTEM", DefectCategory.mechanical),
    ("TRANSMISSION/DRIVER SYSTEM", DefectCategory.mechanical),
    ("CHARGING SYSTEM", DefectCategory.electrical),
    ("ITS SYSTEM", DefectCategory.its),
    ("AIR CONDITION", DefectCategory.ac),
    ("TYRE", DefectCategory.tyre),
    ("OTHERS", DefectCategory.other),
]

#: The "TYPE OF WORK" column on the snag report. A code either files into a
#: register or is an inspection with its own checklist and its own form.
#: Codes are exactly as written on the sheet.
#:
#: `C/F` is a carried-forward continuation of an earlier job, so it files as
#: day-to-day work done. `P.M` is a docking ("80K DOCKING"), a checklist job
#: like the other inspections — the sheet also writes it `PM`, which the import
#: matches to the same code because it compares without punctuation.
WORK_TYPES = [
    # (code, name, register, is_inspection)
    ("B.D", "Breakdown", Register.breakdown, False),
    ("D.C", "Driver complaint", Register.driver_complaint, False),
    ("DEPOT", "Daily work", Register.work_done, False),
    ("C/F", "Carried forward", Register.work_done, False),
    ("D.I", "Daily inspection", None, True),
    ("10 DAYS SERVICE", "10 day inspection", None, True),
    ("P.M", "Preventive maintenance docking", None, True),
]


#: The components the Unit Failure Statement tracks by name. Their life is
#: worth following individually; everything else is a consumable.
UNIT_TYPES = [
    ("Battery Pack", True),
    ("Traction Motor", False),
    ("Motor Controller", False),
    ("Air Compressor", False),
    ("Steering Motor", False),
    ("Air Compressor Motor", False),
    ("Steering Pump", False),
    ("Steering Box", False),
    ("Radiator", False),
]


async def _seed_defect_types(session) -> int:
    """Defect types carry the report category they roll up into."""
    added = 0
    for order, (name, category) in enumerate(DEFECT_TYPES):
        exists = await session.scalar(
            select(DefectType.id).where(func.lower(DefectType.name) == name.lower())
        )
        if not exists:
            session.add(
                DefectType(name=name, category=category, sort_order=order)
            )
            added += 1
    return added


async def _seed_unit_types(session) -> int:
    added = 0
    for order, (name, is_hv_battery) in enumerate(UNIT_TYPES):
        exists = await session.scalar(
            select(UnitType.id).where(func.lower(UnitType.name) == name.lower())
        )
        if not exists:
            session.add(
                UnitType(
                    name=name, is_hv_battery=is_hv_battery, sort_order=order
                )
            )
            added += 1
    return added


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
    for order, (code, name, register, is_inspection) in enumerate(WORK_TYPES):
        exists = await session.scalar(
            select(WorkType.id).where(func.upper(WorkType.code) == code)
        )
        if not exists:
            session.add(
                WorkType(
                    code=code,
                    name=name,
                    register=register,
                    is_inspection=is_inspection,
                    sort_order=order,
                )
            )
            added += 1
    return added


async def seed() -> None:
    async with SessionLocal() as session:
        sources = await _seed_list(session, DefectSource, DEFECT_SOURCES)
        types = await _seed_defect_types(session)
        work = await _seed_work_types(session)
        units = await _seed_unit_types(session)
        print(
            f"  defect sources: +{sources}, defect types: +{types}, "
            f"work types: +{work}, unit types: +{units}"
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
