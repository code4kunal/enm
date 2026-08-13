"""The reactive inspection scheduler.

A site's inspections are a *rotation*, not a calendar rule: every bus is due
`cycle_days` after its own last inspection of that kind, so 57 buses on a
10-day cycle spread themselves across the month at roughly five a night rather
than all falling due on the 1st.

The generator runs every night and again on demand. It is reactive in the sense
that matters on a depot floor: whatever actually happened yesterday — an
inspection done early, one missed, a bus retired — is read back out of the
register before tomorrow is planned. Re-running it is safe and converges;
running it twice in one night changes nothing the second time.

Three rules shape the plan, and they came from how MBMT already works:

1. **Missed work jumps the queue.** A bus that slipped is inserted at the front
   of the next night; buses already booked keep the date they were given. A
   depot that reshuffles the whole calendar every time one bus is late never
   builds a routine.
2. **A hand-edited slot is pinned.** Someone who moved a slot had a reason the
   generator cannot see, so it is never moved back.
3. **Capacity is finite, where it is finite at all.** The daily inspection
   covers the whole fleet every night, so it is uncapped. The 10-day service is
   limited by bay time — MBMT gets through about five a night — so it books to
   that cap and the rest queue in due order.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import date as date_t
from datetime import datetime, timedelta

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.checklist import InspectionEntry
from app.models.entry import BreakdownEntry, Entry
from app.models.enums import (
    AlertStatus,
    AlertType,
    EntryStatus,
    SlotStatus,
)
from app.models.inspection import Alert, InspectionPlan, InspectionSlot
from app.models.master import Site, Vehicle
from app.services import service_due
from app.services.common import today_ist
from app.services.site_config import get_or_create

logger = logging.getLogger("enm.inspections")

#: How far ahead to lay out the calendar, as a multiple of the cycle: far
#: enough to see the rotation repeat, not so far that it pretends to know next
#: quarter. A daily inspection therefore books about a week ahead and the
#: 10-day service about a month.
HORIZON_CYCLES = 3
MIN_HORIZON_DAYS = 7
MAX_HORIZON_DAYS = 60


def horizon_for(cycle_days: int) -> int:
    return min(
        max(cycle_days * HORIZON_CYCLES, MIN_HORIZON_DAYS), MAX_HORIZON_DAYS
    )


@dataclass(slots=True)
class GenerationResult:
    site_code: str
    generated_on: date_t
    created: int = 0
    missed: int = 0
    completed: int = 0
    alerts_raised: int = 0

    @property
    def changed(self) -> bool:
        return bool(self.created or self.missed or self.completed or self.alerts_raised)


# --- reading what actually happened ----------------------------------------


async def last_done_by_vehicle(
    session: AsyncSession, site_code: str, work_type_id: int
) -> dict[str, date_t]:
    """The most recent date each bus had this inspection.

    Read from what was actually recorded, not from the slots the scheduler
    booked, so an inspection written up by hand counts as much as a planned
    one. Two sources are merged: `inspection_entries`, which is where an
    inspection lands now, and `entries.work_type_id`, which is where the
    historical snag-report import put them before inspections became their own
    record. The later of the two wins.
    """
    merged: dict[str, date_t] = {}

    inspected = await session.execute(
        select(InspectionEntry.vehicle_id, func.max(InspectionEntry.inspected_on))
        .where(
            InspectionEntry.site_code == site_code,
            InspectionEntry.work_type_id == work_type_id,
        )
        .group_by(InspectionEntry.vehicle_id)
    )
    for vehicle_id, last in inspected.all():
        merged[vehicle_id] = last

    historical = await session.execute(
        select(Entry.bus_id, func.max(Entry.entry_date))
        .where(Entry.site_code == site_code, Entry.work_type_id == work_type_id)
        .group_by(Entry.bus_id)
    )
    for vehicle_id, last in historical.all():
        current = merged.get(vehicle_id)
        if current is None or last > current:
            merged[vehicle_id] = last

    return merged


async def _discharge_slots(
    session: AsyncSession, site_code: str, today: date_t
) -> int:
    """Close out slots that the register shows were actually done."""
    open_slots = list(
        (
            await session.scalars(
                select(InspectionSlot).where(
                    InspectionSlot.site_code == site_code,
                    InspectionSlot.status == SlotStatus.scheduled,
                )
            )
        ).all()
    )
    if not open_slots:
        return 0

    completed = 0
    for slot in open_slots:
        # An inspection done a little early still discharges the booking; one
        # done late discharges it too, and the slot is marked done rather than
        # missed because the work exists.
        window_start = slot.scheduled_on - timedelta(days=1)
        inspection = await session.scalar(
            select(InspectionEntry)
            .where(
                InspectionEntry.site_code == site_code,
                InspectionEntry.vehicle_id == slot.vehicle_id,
                InspectionEntry.work_type_id == slot.work_type_id,
                InspectionEntry.inspected_on >= window_start,
                InspectionEntry.inspected_on <= today,
            )
            .order_by(InspectionEntry.inspected_on)
            .limit(1)
        )
        if inspection is not None:
            slot.status = SlotStatus.done
            slot.completed_on = inspection.inspected_on
            slot.updated_at = datetime.now(tz=None).astimezone()
            completed += 1
            continue

        # Historical rows imported before inspections became their own record.
        entry = await session.scalar(
            select(Entry)
            .where(
                Entry.site_code == site_code,
                Entry.bus_id == slot.vehicle_id,
                Entry.work_type_id == slot.work_type_id,
                Entry.entry_date >= window_start,
                Entry.entry_date <= today,
            )
            .order_by(Entry.entry_date)
            .limit(1)
        )
        if entry is None:
            continue
        slot.status = SlotStatus.done
        slot.completed_entry_id = entry.id
        slot.completed_on = entry.entry_date
        slot.updated_at = datetime.now(tz=None).astimezone()
        completed += 1
    return completed


async def _mark_missed(
    session: AsyncSession, site_code: str, today: date_t
) -> list[InspectionSlot]:
    """Anything still booked for a night that has passed was missed."""
    stale = list(
        (
            await session.scalars(
                select(InspectionSlot).where(
                    InspectionSlot.site_code == site_code,
                    InspectionSlot.status == SlotStatus.scheduled,
                    InspectionSlot.scheduled_on < today,
                )
            )
        ).all()
    )
    for slot in stale:
        slot.status = SlotStatus.missed
        slot.updated_at = datetime.now(tz=None).astimezone()
    return stale


# --- planning ---------------------------------------------------------------


@dataclass(slots=True)
class _Due:
    """A bus's place in the rotation. Mutated as it is booked forward."""

    vehicle: Vehicle
    due_on: date_t
    never_done: bool
    #: Slipped a booked night. Goes to the front regardless of what else is due
    #: and regardless of any later booking it already holds.
    urgent: bool = False

    def overdue_by(self, today: date_t) -> int:
        return max((today - self.due_on).days, 0)


async def _plan_one(
    session: AsyncSession,
    *,
    site_code: str,
    plan: InspectionPlan,
    vehicles: list[Vehicle],
    today: date_t,
    urgent: set[str],
) -> int:
    """Lay out the rotation for one inspection type. Returns slots created.

    Walks the horizon one night at a time, filling each night from whichever
    buses are due by then, worst first. A bus that is booked comes straight
    back into the queue due again `cycle_days` later, which is what makes this
    a rotation rather than a one-shot list: over a 10-day cycle each bus comes
    round roughly three times in a 30-day horizon, and a daily inspection books
    the whole fleet every night.
    """
    horizon_days = horizon_for(plan.cycle_days)
    horizon_end = today + timedelta(days=horizon_days)
    last_done = await last_done_by_vehicle(session, site_code, plan.work_type_id)
    cycle = timedelta(days=plan.cycle_days)

    # What each night already holds, so a re-run tops up rather than
    # double-books. Buses already booked keep the date they were given —
    # "missed jumps the queue, others hold".
    #
    # `on_day` counts slots of *any* status: a night a bus already has a slot
    # for is spoken for, and one already marked done still occupies that date
    # as far as the unique constraint is concerned. Capacity, though, only
    # counts work that still stands.
    taken: dict[date_t, int] = {}
    existing_days: dict[str, date_t] = {}
    on_day: dict[date_t, set[str]] = {}
    for slot in (
        await session.scalars(
            select(InspectionSlot).where(
                InspectionSlot.site_code == site_code,
                InspectionSlot.work_type_id == plan.work_type_id,
                InspectionSlot.scheduled_on >= today,
            )
        )
    ).all():
        on_day.setdefault(slot.scheduled_on, set()).add(slot.vehicle_id)
        if slot.status in (SlotStatus.scheduled, SlotStatus.done):
            taken[slot.scheduled_on] = taken.get(slot.scheduled_on, 0) + 1
        if slot.status is not SlotStatus.scheduled:
            continue
        current = existing_days.get(slot.vehicle_id)
        if current is None or slot.scheduled_on > current:
            existing_days[slot.vehicle_id] = slot.scheduled_on

    queue: list[_Due] = []
    for vehicle in vehicles:
        if vehicle.id in urgent:
            # It slipped a night. It goes at the front of the next one, on top
            # of whatever it already holds later — that is what "missed jumps
            # the queue, others hold their dates" means.
            queue.append(
                _Due(
                    vehicle=vehicle,
                    due_on=today,
                    never_done=last_done.get(vehicle.id) is None,
                    urgent=True,
                )
            )
            continue
        booked_on = existing_days.get(vehicle.id)
        if booked_on is not None:
            # Continue the rotation after the booking it already holds.
            queue.append(
                _Due(vehicle=vehicle, due_on=booked_on + cycle, never_done=False)
            )
            continue
        last = last_done.get(vehicle.id)
        due = today if last is None else last + cycle
        queue.append(
            _Due(vehicle=vehicle, due_on=max(due, today), never_done=last is None)
        )

    # 0 means uncapped: every due bus is booked, which is what a daily
    # inspection of the whole fleet means.
    per_day = plan.slots_per_day if plan.slots_per_day > 0 else max(len(vehicles), 1)

    created = 0
    day = today
    while day <= horizon_end:
        room = per_day - taken.get(day, 0)
        if room <= 0:
            day += timedelta(days=1)
            continue

        # Worst first: never inspected, then most overdue, then earliest due,
        # then registration so a tie is stable rather than arbitrary.
        ready = sorted(
            (d for d in queue if d.due_on <= day),
            key=lambda d: (
                not d.urgent,
                not d.never_done,
                -d.overdue_by(day),
                d.due_on,
                d.vehicle.registration_no,
            ),
        )
        for item in ready[:room]:
            if item.vehicle.id in on_day.get(day, set()):
                continue
            session.add(
                InspectionSlot(
                    site_code=site_code,
                    vehicle_id=item.vehicle.id,
                    work_type_id=plan.work_type_id,
                    scheduled_on=day,
                    status=SlotStatus.scheduled,
                )
            )
            taken[day] = taken.get(day, 0) + 1
            on_day.setdefault(day, set()).add(item.vehicle.id)
            created += 1
            # Straight back into the rotation, due again a cycle later.
            item.due_on = day + cycle
            item.never_done = False
            item.urgent = False
        day += timedelta(days=1)

    await session.flush()
    return created


# --- alerts -----------------------------------------------------------------


async def _raise_alert(
    session: AsyncSession,
    *,
    site_code: str,
    alert_type: AlertType,
    dedupe_key: str,
    title: str,
    body: str,
    today: date_t,
    vehicle_id: str | None = None,
    slot_id: str | None = None,
    entry_id: str | None = None,
) -> bool:
    """Raise one alert unless the same problem is already open."""
    existing = await session.scalar(
        select(Alert).where(
            Alert.site_code == site_code, Alert.dedupe_key == dedupe_key
        )
    )
    if existing is not None:
        return False
    session.add(
        Alert(
            site_code=site_code,
            type=alert_type,
            dedupe_key=dedupe_key,
            title=title,
            body=body,
            vehicle_id=vehicle_id,
            slot_id=slot_id,
            entry_id=entry_id,
            raised_on=today,
        )
    )
    return True


async def _scan_alerts(
    session: AsyncSession,
    *,
    site_code: str,
    missed: list[InspectionSlot],
    today: date_t,
) -> int:
    raised = 0

    for slot in missed:
        vehicle = await session.get(Vehicle, slot.vehicle_id)
        label = vehicle.registration_no if vehicle else slot.vehicle_id
        code = slot.work_type.code if slot.work_type else "inspection"
        raised += await _raise_alert(
            session,
            site_code=site_code,
            alert_type=AlertType.missed_inspection,
            dedupe_key=f"missed:{slot.id}",
            title=f"Missed {code} · {label}",
            body=(
                f"{label} was booked for {code} on "
                f"{slot.scheduled_on.isoformat()} and no entry was recorded. "
                "It has been moved to the front of the queue."
            ),
            today=today,
            vehicle_id=slot.vehicle_id,
            slot_id=slot.id,
        )

    # Breakdowns still open. One alert per breakdown, not per night.
    open_breakdowns = list(
        (
            await session.scalars(
                select(Entry)
                .join(BreakdownEntry, BreakdownEntry.entry_id == Entry.id)
                .where(
                    Entry.site_code == site_code,
                    Entry.status == EntryStatus.open,
                )
            )
        ).unique().all()
    )
    for entry in open_breakdowns:
        label = entry.vehicle.registration_no if entry.vehicle else entry.bus_id
        days = (today - entry.entry_date).days
        raised += await _raise_alert(
            session,
            site_code=site_code,
            alert_type=AlertType.breakdown_open,
            dedupe_key=f"breakdown:{entry.id}",
            title=f"Breakdown still open · {label}",
            body=(
                f"Reported {entry.entry_date.isoformat()}"
                + (f", {days} days ago" if days > 0 else ", today")
                + " and not yet resolved."
            ),
            today=today,
            vehicle_id=entry.bus_id,
            entry_id=entry.id,
        )

    # Distance/time services that have gone past due.
    for due in await service_due.for_site(session, site_code, today):
        if due.status != "overdue":
            continue
        raised += await _raise_alert(
            session,
            site_code=site_code,
            alert_type=AlertType.service_overdue,
            dedupe_key=f"service:{due.vehicle_id}:{due.plan_code}",
            title=f"{due.plan_name} overdue · {due.registration_no}",
            body=(
                f"{due.registration_no} is past its {due.plan_name} "
                f"({due.plan_code})."
                + (
                    f" {abs(due.km_remaining):,} km over."
                    if due.km_remaining is not None and due.km_remaining < 0
                    else ""
                )
            ),
            today=today,
            vehicle_id=due.vehicle_id,
        )

    return raised


async def resolve_stale_alerts(session: AsyncSession, site_code: str) -> int:
    """Close alerts whose underlying problem has gone away.

    Without this the list only ever grows, and a list that only grows stops
    being read.
    """
    closed = 0
    open_alerts = list(
        (
            await session.scalars(
                select(Alert).where(
                    Alert.site_code == site_code,
                    Alert.status != AlertStatus.resolved,
                )
            )
        ).all()
    )
    for alert in open_alerts:
        gone = False
        if alert.type is AlertType.breakdown_open and alert.entry_id:
            entry = await session.get(Entry, alert.entry_id)
            gone = entry is None or entry.status is not EntryStatus.open
        elif alert.type is AlertType.missed_inspection and alert.slot_id:
            slot = await session.get(InspectionSlot, alert.slot_id)
            gone = slot is None or slot.status is SlotStatus.done
        if gone:
            alert.status = AlertStatus.resolved
            closed += 1
    return closed


# --- the run ----------------------------------------------------------------


async def generate_for_site(
    session: AsyncSession, site_code: str, today: date_t | None = None
) -> GenerationResult:
    """One night's planning for one site. Safe to run repeatedly."""
    today = today or today_ist()
    result = GenerationResult(site_code=site_code, generated_on=today)

    # Ensures the site has a config row; its `inspection_slots_per_day` is the
    # default a new plan is created with, not a cap applied here — each plan
    # carries its own, and 0 there means uncapped.
    await get_or_create(session, site_code)
    plans = list(
        (
            await session.scalars(
                select(InspectionPlan).where(
                    InspectionPlan.site_code == site_code,
                    InspectionPlan.is_active.is_(True),
                )
            )
        ).all()
    )
    vehicles = list(
        (
            await session.scalars(
                select(Vehicle)
                .where(Vehicle.site_code == site_code, Vehicle.is_active.is_(True))
                .order_by(Vehicle.registration_no)
            )
        ).all()
    )

    result.completed = await _discharge_slots(session, site_code, today)
    missed = await _mark_missed(session, site_code, today)
    result.missed = len(missed)
    await session.flush()

    # Which buses slipped, per inspection type — they lead tomorrow's queue.
    urgent_by_type: dict[int, set[str]] = {}
    for slot in missed:
        urgent_by_type.setdefault(slot.work_type_id, set()).add(slot.vehicle_id)

    for plan in plans:
        result.created += await _plan_one(
            session,
            site_code=site_code,
            plan=plan,
            vehicles=vehicles,
            today=today,
            urgent=urgent_by_type.get(plan.work_type_id, set()),
        )

    await resolve_stale_alerts(session, site_code)
    result.alerts_raised = await _scan_alerts(
        session, site_code=site_code, missed=missed, today=today
    )
    await session.flush()
    return result


async def run_nightly() -> list[GenerationResult]:
    """The 22:00 job: plan every active site, then notify.

    One site failing must not stop the others — a depot with a bad config
    should not silently cost every other depot its schedule.
    """
    from app.db import SessionLocal
    from app.services.notifications import notify_schedule_alerts

    results: list[GenerationResult] = []
    async with SessionLocal() as session:
        codes = list(
            (
                await session.scalars(
                    select(Site.code).where(Site.is_active.is_(True))
                )
            ).all()
        )

    for code in codes:
        async with SessionLocal() as session:
            try:
                result = await generate_for_site(session, code)
                await session.commit()
            except Exception:  # noqa: BLE001 - one bad site must not stop the rest
                await session.rollback()
                logger.exception("Schedule generation failed for %s", code)
                continue
            results.append(result)
            if result.changed:
                logger.info(
                    "%s: %d booked, %d missed, %d completed, %d alerts",
                    code,
                    result.created,
                    result.missed,
                    result.completed,
                    result.alerts_raised,
                )
            try:
                await notify_schedule_alerts(session, code)
                await session.commit()
            except Exception:  # noqa: BLE001
                await session.rollback()
                logger.exception("Schedule notification failed for %s", code)
    return results
