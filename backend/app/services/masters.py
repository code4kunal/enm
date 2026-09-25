from __future__ import annotations

from dataclasses import dataclass
from datetime import date as date_t
from datetime import datetime

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import ValidationError
from app.models.master import DefectSource, DefectType, Driver, SparePart, Vehicle
from app.services import siteops


def normalize_registration_no(raw: str) -> str:
    """Registration numbers are stored uppercase with no whitespace."""
    return "".join(raw.split()).upper()


def _parse_siteops_date(raw: object | None) -> date_t | None:
    """SiteOps sends dates as ISO strings or dd-mm-yyyy; ignore junk."""
    if raw is None:
        return None
    text = str(raw).strip()
    if not text or text.lower() in {"none", "null", "n/a", "-"}:
        return None
    for fmt in ("%Y-%m-%d", "%d-%m-%Y", "%d/%m/%Y", "%Y/%m/%d"):
        try:
            return datetime.strptime(text[:10], fmt).date()
        except ValueError:
            continue
    return None


def _checklist_variant_from_ac_nac(ac_nac: str | None) -> str | None:
    """SiteOps' free-text AC/non-AC field to one of our three checklist
    variants — conservative on purpose: an unrecognised value leaves the bus
    on the site's unscoped checklist (a real, if generic, form) rather than
    risk filing it under the wrong docking sheet."""
    if not ac_nac:
        return None
    v = ac_nac.strip().upper()
    if v.startswith("9M"):
        return "9M"
    if v.startswith("12M"):
        if "NAC" in v or "NON" in v:
            return "12M Non-AC"
        if "AC" in v:
            return "12M AC"
    return None


#: Synthetic placeholder for fleet-wide snag rows — not a SiteOps bus.
_FLEETWIDE_REGISTRATION = "FLEETWIDE"


@dataclass(slots=True)
class FleetSyncResult:
    created: int = 0
    #: On this site and still in SiteOps; attributes already matched.
    already_present: int = 0
    #: On this site; make / model / checklist_variant rewritten from SiteOps.
    updated: int = 0
    variant_backfilled: int = 0
    #: Was retired locally; SiteOps still lists it — brought back.
    reactivated: int = 0
    #: Active locally but absent from SiteOps — retired so the master matches.
    deactivated: int = 0
    #: Registration exists on a *different* ENM site — never moved automatically.
    owned_elsewhere: int = 0
    skipped_no_registration: int = 0

    def as_dict(self) -> dict:
        return {
            "created": self.created,
            "already_present": self.already_present,
            "updated": self.updated,
            "variant_backfilled": self.variant_backfilled,
            "reactivated": self.reactivated,
            "deactivated": self.deactivated,
            "owned_elsewhere": self.owned_elsewhere,
            "skipped_no_registration": self.skipped_no_registration,
        }

async def sync_vehicles_from_siteops(
    session: AsyncSession, site_code: str, siteops_site_id: str
) -> FleetSyncResult:
    """Overwrite this site's local fleet from SiteOps.

    SiteOps is the source of truth for who is on the site. Sync creates missing
    rows, rewrites make / model / checklist_variant from SiteOps, reactivates
    buses that returned, and retires active local buses that SiteOps no longer
    lists. Past entries keep their FK to a retired vehicle; dropdowns drop it.

    Vehicle Master may still read SiteOps live for display, but inspections,
    off-road and units resolve against the ENM-native vehicle id — so every
    SiteOps bus needs a local row.
    """
    rows = await siteops.list_all_vehicles(siteops_site_id)

    siteops_regs: set[str] = set()
    for r in rows:
        raw = str(r.get("vehicle_no") or "")
        if raw.strip():
            siteops_regs.add(normalize_registration_no(raw))

    existing = {
        v.registration_no: v
        for v in (
            await session.scalars(
                select(Vehicle).where(Vehicle.site_code == site_code)
            )
        )
        .unique()
        .all()
    }
    # Also need cross-site ownership checks for SiteOps regs not on this site.
    if siteops_regs:
        for v in (
            await session.scalars(
                select(Vehicle).where(
                    Vehicle.registration_no.in_(siteops_regs),
                    Vehicle.site_code != site_code,
                )
            )
        ).unique().all():
            existing.setdefault(v.registration_no, v)

    result = FleetSyncResult()
    for row in rows:
        raw_reg = str(row.get("vehicle_no") or "")
        if not raw_reg.strip():
            result.skipped_no_registration += 1
            continue
        registration_no = normalize_registration_no(raw_reg)
        variant = _checklist_variant_from_ac_nac(row.get("ac_nac"))
        make = str(row.get("make") or "")
        model = str(row.get("model") or "")
        reg_date = _parse_siteops_date(
            row.get("date_of_reg") or row.get("registration_date")
        )
        fitness = _parse_siteops_date(
            row.get("fitness_expiry_date")
            or row.get("fitness_renewal_date")
            or row.get("fitness_expiry")
        )
        insurance = _parse_siteops_date(
            row.get("insurance_expiry_date")
            or row.get("insurance_renewal_date")
            or row.get("insurance_expiry")
        )

        found = existing.get(registration_no)
        if found is not None:
            if found.site_code != site_code:
                result.owned_elsewhere += 1
                continue

            changed = False
            if found.make != make:
                found.make = make
                changed = True
            if found.model != model:
                found.model = model
                changed = True
            if found.checklist_variant != variant:
                if found.checklist_variant is None and variant is not None:
                    result.variant_backfilled += 1
                found.checklist_variant = variant
                changed = True
            # SiteOps wins when it has a value; leave manual ENM dates alone
            # when SiteOps sends nothing.
            if reg_date is not None and found.registration_date != reg_date:
                found.registration_date = reg_date
                changed = True
            if fitness is not None and found.fitness_renewal_date != fitness:
                found.fitness_renewal_date = fitness
                changed = True
            if insurance is not None and found.insurance_renewal_date != insurance:
                found.insurance_renewal_date = insurance
                changed = True
            if not found.is_active:
                found.is_active = True
                result.reactivated += 1
                changed = True
            if changed:
                result.updated += 1
            else:
                result.already_present += 1
            continue

        vehicle = Vehicle(
            registration_no=registration_no,
            site_code=site_code,
            make=make,
            model=model,
            checklist_variant=variant,
            registration_date=reg_date,
            fitness_renewal_date=fitness,
            insurance_renewal_date=insurance,
        )
        session.add(vehicle)
        existing[registration_no] = vehicle
        result.created += 1

    for reg, vehicle in existing.items():
        if vehicle.site_code != site_code:
            continue
        if reg == _FLEETWIDE_REGISTRATION:
            continue
        if reg in siteops_regs:
            continue
        if vehicle.is_active:
            vehicle.is_active = False
            result.deactivated += 1

    await session.flush()
    return result


async def sync_all_linked_sites() -> list[dict]:
    """Nightly: refresh local fleets for every site linked to SiteOps.

    Per-site failures are recorded on the site row and do not abort the run.
    """
    from datetime import UTC, datetime

    from app.db import SessionLocal
    from app.models.master import Site
    from app.services.siteops import SiteOpsUnavailable

    outcomes: list[dict] = []
    async with SessionLocal() as session:
        linked = list(
            (
                await session.scalars(
                    select(Site).where(Site.siteops_site_id.is_not(None))
                )
            ).all()
        )
        for site in linked:
            assert site.siteops_site_id is not None
            try:
                result = await sync_vehicles_from_siteops(
                    session, site.code, site.siteops_site_id
                )
                payload = {**result.as_dict(), "ok": True}
            except SiteOpsUnavailable as e:
                payload = {"ok": False, "error": str(e)}
            except Exception as e:  # noqa: BLE001 — never abort the batch
                payload = {"ok": False, "error": str(e)}
            site.last_siteops_sync_at = datetime.now(UTC)
            site.last_siteops_sync_result = payload
            outcomes.append({"site_code": site.code, **payload})
        await session.commit()
    return outcomes


async def resolve_vehicle(
    session: AsyncSession, *, registration_no: str, site_code: str
) -> Vehicle:
    """The vehicle must be on this site's fleet. Server normalizes case/spaces.

    Never conjures a vehicle from entry text — a typo or another site's bus
    would silently join this site's master (registration numbers are unique
    across the whole fleet, so a bus already owned elsewhere would 500 rather
    than fail cleanly). A bus joins the fleet through Vehicle Master or an
    import, not by being typed into a register.
    """
    normalized = normalize_registration_no(registration_no)
    vehicle = await session.scalar(
        select(Vehicle).where(
            Vehicle.registration_no == normalized, Vehicle.site_code == site_code
        )
    )
    if vehicle is None:
        raise ValidationError(
            f"{normalized} is not on the {site_code} fleet",
            {"bus_no": "unknown vehicle"},
        )
    if not vehicle.is_active:
        raise ValidationError(
            f"{normalized} is retired", {"bus_no": "vehicle is retired"}
        )
    return vehicle


async def resolve_defect_source(
    session: AsyncSession, name: str | None
) -> DefectSource | None:
    """Resolve by name, ignoring `is_active`.

    Hiding a master row must not break entries that already reference it —
    filter on `is_active` when serving the dropdown, never when resolving.
    """
    if not name:
        return None
    row = await session.scalar(
        select(DefectSource).where(
            func.lower(DefectSource.name) == name.strip().lower()
        )
    )
    if row is None:
        raise ValidationError(
            f"Unknown defect source: {name}", {"defect_source": "not in master list"}
        )
    return row


async def resolve_defect_type(
    session: AsyncSession, name: str | None
) -> DefectType | None:
    if not name:
        return None
    row = await session.scalar(
        select(DefectType).where(func.lower(DefectType.name) == name.strip().lower())
    )
    if row is None:
        raise ValidationError(
            f"Unknown defect type: {name}", {"defect_type": "not in master list"}
        )
    return row


async def resolve_spare_parts(
    session: AsyncSession, spare_part_ids: list[str], *, site_code: str
) -> list[SparePart]:
    """Mirrors `entries._resolve_attendees`: ids must belong to this site,
    inactive rows still resolve (history keeps reading), unknown ids 400."""
    if not spare_part_ids:
        return []
    rows = (
        await session.scalars(
            select(SparePart).where(
                SparePart.id.in_(spare_part_ids), SparePart.site_code == site_code
            )
        )
    ).unique().all()
    by_id = {p.id: p for p in rows}
    missing = [pid for pid in spare_part_ids if pid not in by_id]
    if missing:
        raise ValidationError(
            f"spare_part_ids: unknown spare part {missing[0]}",
            {"spare_part_ids": "unknown spare part"},
        )
    seen: set[str] = set()
    ordered: list[SparePart] = []
    for pid in spare_part_ids:
        if pid not in seen:
            seen.add(pid)
            ordered.append(by_id[pid])
    return ordered


async def resolve_driver(
    session: AsyncSession, driver_code: str | None, *, site_code: str
) -> Driver | None:
    """Resolve by code, ignoring `is_active` — same rule as
    `resolve_defect_source`/`resolve_spare_parts`: hiding a driver from the
    picker must not break entries that already reference it."""
    if not driver_code:
        return None
    row = await session.scalar(
        select(Driver).where(
            func.lower(Driver.driver_code) == driver_code.strip().lower(),
            Driver.site_code == site_code,
        )
    )
    if row is None:
        raise ValidationError(
            f"Unknown driver: {driver_code}", {"driver_id": "not in driver master"}
        )
    return row
