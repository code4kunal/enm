from __future__ import annotations

from datetime import date as date_t

from pydantic import BaseModel


class TicketSearchResult(BaseModel):
    ticket_id: str
    #: The source entry's own display_id (BD-2026-..., DC-2026-...) -- the
    #: id a person actually sees and would type. Ticket.display_id is a
    #: separate, unsurfaced column for inspection-sourced tickets (no entry
    #: to hang an id off), used only as a fallback here.
    display_id: str
    title: str
    entry_date: date_t
    status: str
    source_kind: str
    #: Prefill context for the Work Done linking form -- null for an
    #: inspection-sourced ticket (no register entry to read from).
    bus_no: str | None = None
    driver_name: str | None = None
    route: str | None = None
    defect_text: str | None = None
    defect_type: str | None = None
