from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Query

from app.deps import CurrentUser, EntrySite, SessionDep
from app.models.enums import TicketSourceKind
from app.schemas.ticket import TicketSearchResult
from app.services import tickets as svc

router = APIRouter(prefix="/tickets", tags=["tickets"])


@router.get("/search", response_model=list[TicketSearchResult])
async def search(
    _user: CurrentUser,
    session: SessionDep,
    site: EntrySite,
    source_kind: Annotated[TicketSourceKind | None, Query()] = None,
    q: Annotated[str | None, Query(max_length=200)] = None,
) -> list[TicketSearchResult]:
    tickets = await svc.search_tickets(session, site_code=site, source_kind=source_kind, q=q)
    return [
        TicketSearchResult(
            ticket_id=t.id,
            title=svc.ticket_title(t),
            entry_date=svc.ticket_entry_date(t),
            status=t.status.value,
            source_kind=t.source_kind.value,
        )
        for t in tickets
    ]
