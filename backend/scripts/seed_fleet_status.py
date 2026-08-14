"""Load the fleet's models and current odometers from a VehicleStatus export.

The export is the depot's daily telematics report: one row per bus, its type,
its status, and where the odometer stood. It is the same file the odometer sync
reads, so this is a first load of what will afterwards arrive on its own.

Two things come off it that nothing else in the system knows as well:

* the bus's type — "9M NAC", "12M AC", "12M NAC" — which is both its model and
  which inspection checklist it takes. The snag report says only "12M", and it
  rewrites `model` on every import, which is why the variant lives in its own
  column.
* the current reading, which is what the docking ladder is scheduled against.

    python -m scripts.seed_fleet_status [SITE_CODE] [PATH_TO_EXPORT]

Idempotent: readings never move backwards, and a bus the export has nothing for
is left as it was.
"""
from __future__ import annotations

import asyncio
import sys
from datetime import UTC, datetime
from pathlib import Path

from sqlalchemy import select

from app.db import SessionLocal
from app.models.master import Vehicle
from app.services.odometer import read_vehicle_status, record_reading

DEFAULT_SITE = "MBMT"
DEFAULT_FILE = "/srv/data/MBMT/August/VehicleStatus (1).xlsx"

SOURCE = "vehicle-status"

#: Vehicle type -> (model, checklist variant). The export writes NAC where the
#: daily sheet writes Non-AC; the variant name follows the sheet the mechanic
#: reads, not the feed.
TYPES: dict[str, tuple[str, str]] = {
    "9M NAC": ("9M", "9M"),
    "9M AC": ("9M", "9M"),
    "12M AC": ("12M", "12M AC"),
    "12M NAC": ("12M", "12M Non-AC"),
}


async def seed(site_code: str, path: Path) -> None:
    rows = read_vehicle_status(path)
    if not rows:
        raise SystemExit(f"No vehicle rows in {path}")

    now = datetime.now(UTC)
    typed = 0
    read = 0
    behind: list[str] = []
    unknown_type: set[str] = set()
    missing: list[str] = []

    async with SessionLocal() as session:
        fleet = {
            v.registration_no.upper(): v
            for v in (
                await session.scalars(
                    select(Vehicle).where(Vehicle.site_code == site_code)
                )
            )
            .unique()
            .all()
        }

        for row in rows:
            vehicle = fleet.get(row.registration_no)
            if vehicle is None:
                missing.append(row.registration_no)
                continue

            mapped = TYPES.get(row.vehicle_type.upper()) or TYPES.get(
                row.vehicle_type
            )
            if mapped is None:
                if row.vehicle_type:
                    unknown_type.add(row.vehicle_type)
            else:
                model, variant = mapped
                vehicle.model = model
                vehicle.checklist_variant = variant
                typed += 1

            if row.odometer_km is None:
                continue
            # An odometer never runs backwards. A lower figure means the feed
            # is stale or the bus was swapped, and either way the reading on
            # record is the better one.
            if (
                vehicle.odometer_updated_at is not None
                and row.odometer_km < vehicle.odometer_km
            ):
                behind.append(vehicle.registration_no)
                continue
            record_reading(
                session,
                vehicle,
                odometer_km=row.odometer_km,
                recorded_at=row.recorded_at or now,
                source=SOURCE,
            )
            read += 1

        await session.commit()

    print(f"  {typed} typed, {read} odometers recorded")
    if behind:
        print(
            f"  {len(behind)} reading(s) lower than what is on record, kept: "
            + ", ".join(behind[:6])
        )
    if unknown_type:
        print(f"  vehicle types not mapped: {sorted(unknown_type)}")
    if missing:
        print(
            f"  {len(missing)} bus(es) in the export are not on this site's "
            "fleet: " + ", ".join(missing[:6])
        )
    print("Fleet status loaded.")


if __name__ == "__main__":
    site = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SITE
    path = Path(sys.argv[2] if len(sys.argv) > 2 else DEFAULT_FILE)
    asyncio.run(seed(site, path))
