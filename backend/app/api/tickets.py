from __future__ import annotations

from typing import Annotated, Any

from fastapi import APIRouter, Query
from pydantic import BaseModel

from app.deps import CurrentUser, EntrySite, SessionDep, assert_site_permission
from app.errors import NotFound
from app.models.enums import TicketSourceKind
from app.models.ticket import Ticket
from app.schemas.entry import EntryOut, EntryPhotoOut
from app.schemas.ticket import TicketSearchResult
from app.services import entries as entries_svc
from app.services import tickets as svc
from app.services.common import IST

router = APIRouter(prefix="/tickets", tags=["tickets"])


@router.get("/search", response_model=list[TicketSearchResult])
async def search(
    _user: CurrentUser,
    session: SessionDep,
    site: EntrySite,
    source_kind: Annotated[TicketSourceKind | None, Query()] = None,
    q: Annotated[str | None, Query(max_length=200)] = None,
    status: Annotated[str, Query()] = "open",
) -> list[TicketSearchResult]:
    tickets = await svc.search_tickets(
        session, site_code=site, source_kind=source_kind, q=q, status=status
    )
    return [
        TicketSearchResult(
            ticket_id=t.id,
            display_id=(
                t.source_entry.display_id if t.source_entry is not None else t.display_id
            ),
            title=svc.ticket_title(t),
            entry_date=svc.ticket_entry_date(t),
            status=t.status.value,
            source_kind=t.source_kind.value,
            **svc.ticket_context(t),
        )
        for t in tickets
    ]


class TicketDetailOut(BaseModel):
    ticket_id: str
    display_id: str
    status: str
    #: Always present -- `services/tickets.ticket_title()` already handles
    #: both source shapes (checklist item + bus for inspection-sourced,
    #: the register's own title field for entry-sourced). The one thing a
    #: person can read regardless of which source this ticket has.
    title: str
    #: The bus, resolved the same way regardless of source. Entry-sourced
    #: tickets also get this from `source_entry`, but a screen that can't
    #: assume `source_entry` is non-null needs it at the top level too.
    bus_no: str
    source_entry: EntryOut | None
    linked_sessions: list[dict[str, Any]] | None
    photos: list[EntryPhotoOut] = []
    #: HH:mm, site-local -- the moment mark_attended()/complete_ticket()
    #: stamped, not the ticket row's raw UTC timestamp. Null until that
    #: stage of the reported->attended->completed timeline has happened.
    attended_at: str | None = None
    completed_at: str | None = None


def _hhmm(dt: object) -> str | None:
    if dt is None:
        return None
    return dt.astimezone(IST).strftime("%H:%M")


@router.get("/{ticket_id}", response_model=TicketDetailOut)
async def get_ticket(
    ticket_id: str, user: CurrentUser, session: SessionDep
) -> TicketDetailOut:
    ticket = await session.get(Ticket, ticket_id)
    if ticket is None:
        raise NotFound("Ticket not found")
    site_code = (
        ticket.source_entry.site_code
        if ticket.source_entry is not None
        else ticket.source_inspection_result.inspection.site_code
    )
    # Matches GET /entries/{id}'s convention -- site reach alone isn't
    # enough, the caller also needs em_entry:read (same permission
    # /tickets/search already enforces via its EntrySite dependency).
    assert_site_permission(user, site_code, "em_entry:read")
    entry_out = None
    if ticket.source_entry is not None:
        entry_out = EntryOut(**entries_svc.serialize_entry(ticket.source_entry))
    # sessions_for_ticket works off the ticket id directly -- unlike
    # load_linked_sessions, it doesn't need a source Entry, so this is one
    # call for both source shapes (a Work Done session can link to any
    # ticket regardless of source kind).
    linked_sessions = await entries_svc.sessions_for_ticket(session, ticket.id)
    display_id = (
        ticket.source_entry.display_id if ticket.source_entry is not None else ticket.display_id
    )
    bus_no = (
        entry_out.data.get("bus_no", "")
        if entry_out is not None
        else ticket.source_inspection_result.inspection.vehicle.registration_no
    )
    return TicketDetailOut(
        ticket_id=ticket.id,
        display_id=display_id,
        status=ticket.status.value,
        title=svc.ticket_title(ticket),
        bus_no=bus_no,
        source_entry=entry_out,
        linked_sessions=linked_sessions,
        photos=entry_out.photos if entry_out is not None else [],
        attended_at=_hhmm(ticket.attended_at),
        completed_at=_hhmm(ticket.completed_at),
    )
