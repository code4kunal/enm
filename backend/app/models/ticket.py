from __future__ import annotations

from datetime import datetime
from typing import TYPE_CHECKING

from sqlalchemy import Enum, ForeignKey, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, TZDateTime, created_at_col, new_uuid
from app.models.enums import TICKET_STATUS_ENUM, TicketStatus
from app.models.user import User

if TYPE_CHECKING:
    from app.models.entry import Entry


class Ticket(Base):
    """The spine between a source entry and its chain of Work Done sessions.

    One ticket per source, always — `source_entry_id` is unique. A breakdown's
    ticket is created automatically; Coolant/Driver Complaint/PM-Docking
    tickets are raised explicitly (see `services/tickets.py`).
    """

    __tablename__ = "tickets"

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_uuid)
    source_entry_id: Mapped[str] = mapped_column(
        String(32),
        ForeignKey("entries.id", ondelete="CASCADE"),
        nullable=False,
        unique=True,
    )
    status: Mapped[TicketStatus] = mapped_column(
        Enum(
            TicketStatus,
            name=TICKET_STATUS_ENUM,
            values_callable=lambda e: [m.value for m in e],
        ),
        nullable=False,
        default=TicketStatus.open,
    )
    completed_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
    completed_by_id: Mapped[str | None] = mapped_column(
        String(32), ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
    # Set once, from the first Work Done session logged against this ticket.
    attended_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
    created_at: Mapped[datetime] = created_at_col()
    created_by_id: Mapped[str] = mapped_column(
        String(32), ForeignKey("users.id", ondelete="RESTRICT"), nullable=False
    )

    source_entry: Mapped["Entry"] = relationship(
        lazy="joined", foreign_keys=[source_entry_id]
    )
    completed_by: Mapped[User | None] = relationship(
        lazy="joined", foreign_keys=[completed_by_id]
    )
    created_by: Mapped[User] = relationship(lazy="joined", foreign_keys=[created_by_id])
