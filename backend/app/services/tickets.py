from __future__ import annotations

from datetime import datetime

from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import Conflict
from app.models.checklist import ChecklistItem, InspectionEntry, InspectionResult
from app.models.entry import BreakdownEntry, Entry
from app.models.enums import EntryStatus, Register, TicketSourceKind, TicketStatus
from app.models.master import Vehicle
from app.models.ticket import Ticket
from app.models.user import User

#: Which register types may ever have a ticket automatically or via "Raise
#: ticket". PM/Docking's ticket path now runs through InspectionEntry (see
#: create_ticket_for_inspection_result) — pm_schedule is retired for entry
#: creation, so it can never be a source here.
TICKETABLE_REGISTERS = frozenset(
    {Register.breakdown, Register.coolant, Register.driver_complaint}
)

_REGISTER_SOURCE_KIND: dict[Register, TicketSourceKind] = {
    Register.breakdown: TicketSourceKind.breakdown,
    Register.coolant: TicketSourceKind.coolant,
    Register.driver_complaint: TicketSourceKind.driver_complaint,
}

#: work_type.code -> the ticket source kind an inspection failure raises.
#: Matches the same literal codes `docking_km.py`'s DOCKING_WORK_TYPE and the
#: seeded catalogue already use ("D.I", "10 DAYS SERVICE", "P.M").
_INSPECTION_WORK_TYPE_SOURCE_KIND: dict[str, TicketSourceKind] = {
    "D.I": TicketSourceKind.daily_inspection,
    "10 DAYS SERVICE": TicketSourceKind.ten_day_inspection,
    "P.M": TicketSourceKind.pm_docking,
}


async def create_ticket_for_entry(
    session: AsyncSession, *, entry: Entry, creator: User
) -> Ticket:
    if entry.register not in TICKETABLE_REGISTERS:
        raise Conflict(f"{entry.register.value} entries cannot have a ticket")
    existing = await session.scalar(
        select(Ticket).where(Ticket.source_entry_id == entry.id)
    )
    if existing is not None:
        raise Conflict("This entry already has a ticket")
    # Assigning the relationship (not just the FK id) populates it in memory
    # immediately, so a caller can use the returned ticket's source without
    # forcing a lazy load outside an awaited context.
    ticket = Ticket(
        source_entry=entry,
        source_kind=_REGISTER_SOURCE_KIND[entry.register],
        created_by_id=creator.id,
    )
    session.add(ticket)
    await session.flush()
    return ticket


async def create_ticket_for_inspection_result(
    session: AsyncSession, *, result: InspectionResult, creator: User
) -> Ticket | None:
    """Automatic — called for every `not_ok` result when an inspection is
    recorded. One ticket per failed check line, not per inspection.

    Returns `None`, rather than raising, when the work type's code isn't one
    of the fixed ticketable ones (D.I / 10 DAYS SERVICE / P.M) — a master-data
    rename can move a code out of that set at any time (`is_inspection` stays
    true), and the recorded failure is real regardless; it just can't be
    turned into a ticket automatically. The caller (`record_inspection`) must
    not let one unmapped code abort the whole inspection.
    """
    existing = await session.scalar(
        select(Ticket).where(Ticket.source_inspection_result_id == result.id)
    )
    if existing is not None:
        raise Conflict("This inspection result already has a ticket")
    work_type_code = result.inspection.work_type.code
    source_kind = _INSPECTION_WORK_TYPE_SOURCE_KIND.get(work_type_code)
    if source_kind is None:
        return None
    ticket = Ticket(
        source_inspection_result=result,
        source_kind=source_kind,
        created_by_id=creator.id,
    )
    session.add(ticket)
    await session.flush()
    return ticket


#: How each register's own text is rendered as a ticket's search title.
_TITLE_FIELD = {
    Register.breakdown: lambda d: d.complaint,
    Register.coolant: lambda _d: "Coolant topping",
    Register.driver_complaint: lambda d: d.complaint,
    #: Retired for new tickets, but a pre-existing ticket can still have one
    #: as its source -- ticket_title must keep reading it.
    Register.pm_schedule: lambda d: d.defects_noticed,
}


def ticket_title(ticket: Ticket) -> str:
    if ticket.source_entry_id is not None:
        entry = ticket.source_entry
        label = _TITLE_FIELD[entry.register](entry.detail)
        bus = entry.vehicle.registration_no
        return f"{label[:60]} · {bus}"
    result = ticket.source_inspection_result
    label = result.item.label
    bus = result.inspection.vehicle.registration_no
    return f"{label[:60]} · {bus}"


def ticket_entry_date(ticket: Ticket):
    if ticket.source_entry_id is not None:
        return ticket.source_entry.entry_date
    return ticket.source_inspection_result.inspection.inspected_on


async def search_tickets(
    session: AsyncSession,
    *,
    site_code: str,
    source_kind: TicketSourceKind | None,
    q: str | None,
) -> list[Ticket]:
    entry_stmt = (
        select(Ticket)
        .join(Entry, Entry.id == Ticket.source_entry_id)
        .where(Entry.site_code == site_code, Ticket.status == TicketStatus.open)
    )
    inspection_stmt = (
        select(Ticket)
        .join(InspectionResult, InspectionResult.id == Ticket.source_inspection_result_id)
        .join(InspectionEntry, InspectionEntry.id == InspectionResult.inspection_id)
        .join(ChecklistItem, ChecklistItem.id == InspectionResult.item_id)
        .join(Vehicle, Vehicle.id == InspectionEntry.vehicle_id)
        .where(InspectionEntry.site_code == site_code, Ticket.status == TicketStatus.open)
    )
    if source_kind is not None:
        entry_stmt = entry_stmt.where(Ticket.source_kind == source_kind)
        inspection_stmt = inspection_stmt.where(Ticket.source_kind == source_kind)
    if q:
        needle = f"%{q.strip().lower()}%"
        entry_stmt = entry_stmt.where(
            or_(Entry.search_text.like(needle), Ticket.id == q.strip(), Entry.id == q.strip())
        )
        inspection_stmt = inspection_stmt.where(
            or_(
                InspectionResult.remark.ilike(needle),
                ChecklistItem.label.ilike(needle),
                Vehicle.registration_no.ilike(needle),
                Ticket.id == q.strip(),
            )
        )
    entry_tickets = (await session.scalars(entry_stmt)).unique().all()
    inspection_tickets = (
        []
        if source_kind is not None and source_kind not in _INSPECTION_WORK_TYPE_SOURCE_KIND.values()
        else (await session.scalars(inspection_stmt)).unique().all()
    )
    combined = [*entry_tickets, *inspection_tickets]
    combined.sort(key=ticket_entry_date, reverse=True)
    return combined


def mark_attended(ticket: Ticket, at: datetime) -> None:
    """Set once, from the first Work Done session logged against this ticket."""
    if ticket.attended_at is not None:
        return
    ticket.attended_at = at
    if ticket.source_entry_id is not None and ticket.source_entry.register is Register.breakdown:
        detail: BreakdownEntry = ticket.source_entry.breakdown
        detail.attended_time = at.timetz().replace(tzinfo=None)


async def complete_ticket(
    _session: AsyncSession, *, ticket: Ticket, completed_by: User, completed_at: datetime
) -> None:
    if ticket.status is TicketStatus.completed:
        raise Conflict("This ticket is already completed")
    ticket.status = TicketStatus.completed
    ticket.completed_at = completed_at
    ticket.completed_by_id = completed_by.id

    if ticket.source_entry_id is None:
        # Inspection-sourced: nothing else to mirror. The result's own
        # ticket_status (surfaced via InspectionResult.ticket) is now
        # "completed" — that's the whole signal back to the inspection.
        return

    source = ticket.source_entry
    source.status = EntryStatus.resolved
    source.updated_at = completed_at
    if source.register is Register.breakdown:
        detail: BreakdownEntry = source.breakdown
        detail.resolved_at = completed_at
        detail.resolved_by_id = completed_by.id
