from __future__ import annotations

from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import Conflict
from app.models.entry import Entry
from app.models.enums import Register
from app.models.ticket import Ticket
from app.models.user import User

#: Which register types may ever have a ticket. Work Done is the *referencer*
#: (it points at a ticket), never a source itself.
TICKETABLE_REGISTERS = frozenset(
    {Register.breakdown, Register.coolant, Register.driver_complaint, Register.pm_schedule}
)


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
    ticket = Ticket(source_entry_id=entry.id, created_by_id=creator.id)
    session.add(ticket)
    await session.flush()
    return ticket


#: How each register's own text is rendered as a ticket's search title.
_TITLE_FIELD = {
    Register.breakdown: lambda d: d.complaint,
    Register.coolant: lambda d: "Coolant topping",
    Register.driver_complaint: lambda d: d.complaint,
    Register.pm_schedule: lambda d: d.defects_noticed,
}


def ticket_title(entry: Entry) -> str:
    label = _TITLE_FIELD[entry.register](entry.detail)
    bus = entry.vehicle.registration_no
    return f"{label[:60]} · {bus}"


async def search_tickets(
    session: AsyncSession,
    *,
    site_code: str,
    register: Register | None,
    q: str | None,
) -> list[Ticket]:
    stmt = (
        select(Ticket)
        .join(Entry, Entry.id == Ticket.source_entry_id)
        .where(Entry.site_code == site_code, Ticket.status == "open")
    )
    if register is not None:
        stmt = stmt.where(Entry.register == register)
    if q:
        needle = f"%{q.strip().lower()}%"
        stmt = stmt.where(
            or_(Entry.search_text.like(needle), Ticket.id == q.strip())
        )
    rows = (
        await session.scalars(stmt.order_by(Entry.entry_date.desc()))
    ).unique().all()
    return list(rows)
