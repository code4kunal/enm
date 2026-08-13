"""Breakdown investigations, and the off-road case list.

The investigation is Annexure-V: the root-cause follow-up to one breakdown.
Three of its columns are questions the system can already answer — when the bus
last had a PM, what that PM turned up, and what the driver had already
complained about — so they are offered filled in rather than looked up by hand
across three spreadsheets.
"""
from __future__ import annotations

from datetime import UTC, datetime, timedelta
from datetime import date as date_t

from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import NotFound, ValidationError
from app.models.checklist import InspectionEntry
from app.models.entry import BreakdownEntry, DriverComplaintEntry, Entry
from app.models.enums import CheckResult, Register
from app.models.master import Vehicle
from app.models.report import BreakdownInvestigation, OffRoadCase
from app.models.user import User

#: How far back to look for what the driver had already reported.
COMPLAINT_LOOKBACK_DAYS = 30


async def _last_pm(
    session: AsyncSession, vehicle_id: str, before: date_t
) -> InspectionEntry | None:
    """The bus's most recent PM before the breakdown.

    Any inspection counts — a daily check that missed something is as relevant
    to a root cause as a ten-day service.
    """
    return await session.scalar(
        select(InspectionEntry)
        .where(
            InspectionEntry.vehicle_id == vehicle_id,
            InspectionEntry.inspected_on <= before,
        )
        .order_by(InspectionEntry.inspected_on.desc())
        .limit(1)
    )


def _pm_findings(inspection: InspectionEntry | None) -> str:
    """What that PM reported: the lines that failed, else its remarks.

    "NO" is the honest answer when a PM found nothing — it is what the depot
    writes, and it means the inspection did happen and was clean.
    """
    if inspection is None:
        return ""
    failed = [
        f"{r.item.label}: {r.remark or 'not OK'}"
        for r in inspection.results
        if r.result is CheckResult.not_ok and r.item is not None
    ]
    if failed:
        return "; ".join(failed)
    return (inspection.remarks or "").strip() or "NO"


async def _related_complaints(
    session: AsyncSession, vehicle_id: str, before: date_t
) -> str:
    """What the driver had already reported on this bus, most recent first.

    A breakdown that a driver complained about twice beforehand is a different
    story from one that came out of nowhere, and that is the whole point of the
    column.
    """
    rows = await session.scalars(
        select(Entry)
        .join(DriverComplaintEntry, DriverComplaintEntry.entry_id == Entry.id)
        .where(
            Entry.bus_id == vehicle_id,
            Entry.register == Register.driver_complaint,
            Entry.entry_date < before,
            Entry.entry_date >= before - timedelta(days=COMPLAINT_LOOKBACK_DAYS),
        )
        .order_by(Entry.entry_date.desc())
        .limit(5)
    )
    parts = []
    for entry in rows.unique().all():
        detail = entry.driver_complaint
        if detail is None:
            continue
        parts.append(
            f"{entry.entry_date.strftime('%d-%m-%Y')}: {detail.complaint.strip()}"
        )
    return " | ".join(parts)


async def prefill(
    session: AsyncSession, entry: Entry
) -> dict[str, object]:
    """The three columns the system can answer for an investigator."""
    inspection = await _last_pm(session, entry.bus_id, entry.entry_date)
    return {
        "last_pm_on": inspection.inspected_on if inspection else None,
        "last_pm_findings": _pm_findings(inspection),
        "related_complaints": await _related_complaints(
            session, entry.bus_id, entry.entry_date
        ),
    }


async def load_breakdown(session: AsyncSession, entry_id: str) -> Entry:
    entry = await session.get(Entry, entry_id)
    if entry is None:
        raise NotFound("Breakdown not found")
    if entry.register is not Register.breakdown:
        raise ValidationError(
            "Only a breakdown can be investigated",
            {"entry_id": "not a breakdown"},
        )
    return entry


async def get_or_prefill(
    session: AsyncSession, entry: Entry
) -> BreakdownInvestigation:
    """The investigation for one breakdown, started from what is already known.

    Created on first open rather than on breakdown creation: an investigation
    that nobody has looked at is not a record, and the fleet would fill with
    empty ones.
    """
    investigation = await session.scalar(
        select(BreakdownInvestigation).where(
            BreakdownInvestigation.entry_id == entry.id
        )
    )
    if investigation is not None:
        return investigation

    investigation = BreakdownInvestigation(entry_id=entry.id, **await prefill(session, entry))
    session.add(investigation)
    await session.flush()
    return investigation


async def save(
    session: AsyncSession,
    investigation: BreakdownInvestigation,
    values: dict[str, object],
    actor: User,
) -> BreakdownInvestigation:
    for key in (
        "findings",
        "last_pm_on",
        "last_pm_findings",
        "related_complaints",
        "investigation_action",
    ):
        if key in values:
            setattr(investigation, key, values[key])
    investigation.updated_at = datetime.now(UTC)
    investigation.updated_by_id = actor.id
    await session.flush()
    return investigation


async def for_day(
    session: AsyncSession, site_code: str, day: date_t
) -> list[tuple[Entry, BreakdownInvestigation | None]]:
    """Every breakdown that day, with its investigation if one has been started."""
    entries = list(
        (
            await session.scalars(
                select(Entry)
                .join(BreakdownEntry, BreakdownEntry.entry_id == Entry.id)
                .where(
                    Entry.site_code == site_code,
                    Entry.entry_date == day,
                    Entry.register == Register.breakdown,
                )
                .order_by(Entry.entry_time, Entry.created_at)
            )
        ).unique().all()
    )
    if not entries:
        return []

    found = {
        i.entry_id: i
        for i in (
            await session.scalars(
                select(BreakdownInvestigation).where(
                    BreakdownInvestigation.entry_id.in_([e.id for e in entries])
                )
            )
        ).unique().all()
    }
    return [(e, found.get(e.id)) for e in entries]


# --- off-road cases ---------------------------------------------------------


async def open_cases(
    session: AsyncSession, site_code: str, day: date_t
) -> list[OffRoadCase]:
    """The off-road list as it stood on one morning, longest down first."""
    rows = await session.scalars(
        select(OffRoadCase)
        .where(
            OffRoadCase.site_code == site_code,
            OffRoadCase.off_road_since <= day,
            or_(OffRoadCase.returned_on.is_(None), OffRoadCase.returned_on > day),
        )
        .order_by(OffRoadCase.off_road_since)
    )
    return list(rows.unique().all())


async def open_case(
    session: AsyncSession,
    *,
    site_code: str,
    vehicle: Vehicle,
    values: dict[str, object],
    actor: User,
) -> OffRoadCase:
    """Put a bus off the road, or update the case it already has.

    One open case per bus: a bus with two simultaneous faults is still one bus
    off the road, and counting it twice would overstate the fleet that is down.
    """
    if vehicle.site_code != site_code:
        raise NotFound("Vehicle not found on this site")

    existing = await session.scalar(
        select(OffRoadCase).where(
            OffRoadCase.vehicle_id == vehicle.id,
            OffRoadCase.returned_on.is_(None),
        )
    )
    case = existing or OffRoadCase(
        site_code=site_code,
        vehicle_id=vehicle.id,
        off_road_since=values.get("off_road_since") or date_t.today(),
        odometer_km=vehicle.odometer_km or None,
    )
    if existing is None:
        session.add(case)

    for key in (
        "issue",
        "action_taken",
        "category",
        "off_road_since",
        "expected_days",
        "expected_ready_on",
        "spare_parts_required",
        "remarks",
        "awaiting_vendor",
        "odometer_km",
        "entry_id",
    ):
        if key in values and values[key] is not None:
            setattr(case, key, values[key])

    # A commitment in days and a date are the same promise; keep them agreed.
    if case.expected_days and not case.expected_ready_on:
        case.expected_ready_on = case.off_road_since + timedelta(days=case.expected_days)
    elif case.expected_ready_on and not case.expected_days:
        case.expected_days = max((case.expected_ready_on - case.off_road_since).days, 0)

    case.updated_at = datetime.now(UTC)
    case.updated_by_id = actor.id
    await session.flush()
    return case


async def close_case(
    session: AsyncSession, case: OffRoadCase, returned_on: date_t, actor: User
) -> OffRoadCase:
    if returned_on < case.off_road_since:
        raise ValidationError(
            "A bus cannot return before it went off the road",
            {"returned_on": "before off_road_since"},
        )
    case.returned_on = returned_on
    case.updated_at = datetime.now(UTC)
    case.updated_by_id = actor.id
    await session.flush()
    return case


async def resolve_vehicle(
    session: AsyncSession, site_code: str, raw: str
) -> Vehicle | None:
    """Find a bus from what the sheets write.

    The off-road and investigation sheets abbreviate a registration to its last
    few digits — "9716", "141" — so a suffix match is the only way to read them.
    Ambiguity is refused rather than guessed.
    """
    from app.services.masters import normalize_registration_no

    needle = normalize_registration_no(raw)
    if not needle:
        return None

    exact = await session.scalar(
        select(Vehicle).where(
            Vehicle.site_code == site_code, Vehicle.registration_no == needle
        )
    )
    if exact is not None:
        return exact

    matches = list(
        (
            await session.scalars(
                select(Vehicle).where(
                    Vehicle.site_code == site_code,
                    Vehicle.registration_no.endswith(needle),
                )
            )
        ).unique().all()
    )
    return matches[0] if len(matches) == 1 else None


