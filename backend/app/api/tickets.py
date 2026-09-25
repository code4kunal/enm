from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Query

from app.deps import CurrentUser, EntrySite, SessionDep
from app.models.enums import Register
from app.schemas.ticket import TicketSearchResult
from app.services import tickets as svc

router = APIRouter(prefix="/tickets", tags=["tickets"])


@router.get("/search", response_model=list[TicketSearchResult])
async def search(
    _user: CurrentUser,
    session: SessionDep,
    site: EntrySite,
    register: Annotated[Register | None, Query()] = None,
    q: Annotated[str | None, Query(max_length=200)] = None,
) -> list[TicketSearchResult]:
    tickets = await svc.search_tickets(session, site_code=site, register=register, q=q)
    return [
        TicketSearchResult(
            ticket_id=t.id,
            title=svc.ticket_title(t.source_entry),
            entry_date=t.source_entry.entry_date,
            status=t.status.value,
        )
        for t in tickets
    ]
