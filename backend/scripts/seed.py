"""Idempotent seed: depots, buses, defect masters, and a bootstrap manager.

    python -m scripts.seed
"""
from __future__ import annotations

import asyncio
import os

from sqlalchemy import select

from app.db import SessionLocal
from app.models.enums import Role
from app.models.master import Bus, DefectSource, DefectType, Depot
from app.models.user import User, UserDepotAccess
from app.security import hash_password

DEPOTS = [
    ("MBMT", "Mira Bhayandar"),
    ("UMT", "Ulhasnagar"),
]

BUSES = {
    "MBMT": [
        "MH40LY1894", "MH40LY1895", "MH40LY1896", "MH40LY1897", "MH40LY1898",
        "MH40LY1899", "MH40LY1900", "MH40LY1901",
    ],
    "UMT": ["MH05GX4410", "MH05GX4411", "MH05GX4412", "MH05GX4413"],
}

DEFECT_SOURCES = [
    "Driver report",
    "Daily inspection",
    "PM schedule",
    "Breakdown",
    "Depot supervisor",
    "Other",
]

DEFECT_TYPES = [
    "Electrical / HV",
    "Electrical / LV",
    "AC & HVAC",
    "Brakes & air system",
    "Doors",
    "Suspension & axle",
    "Body & interior",
    "Tyres",
    "Cooling system",
    "Software / telematics",
    "Other",
]


async def seed() -> None:
    async with SessionLocal() as session:
        for code, name in DEPOTS:
            if not await session.get(Depot, code):
                session.add(Depot(code=code, name=name))
        await session.flush()

        for depot_code, bus_numbers in BUSES.items():
            for bus_no in bus_numbers:
                exists = await session.scalar(
                    select(Bus.id).where(Bus.bus_no == bus_no)
                )
                if not exists:
                    session.add(Bus(bus_no=bus_no, depot_code=depot_code))

        for order, name in enumerate(DEFECT_SOURCES):
            exists = await session.scalar(
                select(DefectSource.id).where(DefectSource.name == name)
            )
            if not exists:
                session.add(DefectSource(name=name, sort_order=order))

        for order, name in enumerate(DEFECT_TYPES):
            exists = await session.scalar(
                select(DefectType.id).where(DefectType.name == name)
            )
            if not exists:
                session.add(DefectType(name=name, sort_order=order))

        admin_handle = os.environ.get("BOOTSTRAP_USER_ID", "TV4021")
        admin_pw = os.environ.get("BOOTSTRAP_PASSWORD", "Transvolt@123")
        exists = await session.scalar(
            select(User.id).where(User.user_id == admin_handle)
        )
        if not exists:
            session.add(
                User(
                    name=os.environ.get("BOOTSTRAP_NAME", "Rahul Sharma"),
                    user_id=admin_handle,
                    email=os.environ.get("BOOTSTRAP_EMAIL") or None,
                    role=Role.manager,
                    password_hash=hash_password(admin_pw),
                    must_reset_password=False,
                    depot_links=[
                        UserDepotAccess(depot_code=code) for code, _ in DEPOTS
                    ],
                )
            )
            print(f"  bootstrap manager: {admin_handle} / {admin_pw}")

        await session.commit()
    print("Seed complete.")


if __name__ == "__main__":
    asyncio.run(seed())
