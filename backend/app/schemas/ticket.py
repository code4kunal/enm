from __future__ import annotations

from datetime import date as date_t

from pydantic import BaseModel


class TicketSearchResult(BaseModel):
    ticket_id: str
    title: str
    entry_date: date_t
    status: str
