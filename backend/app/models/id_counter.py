from __future__ import annotations

from sqlalchemy import Integer, String
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base


class IdCounter(Base):
    """Backs every `display_id` in the system. One row per (kind, year);
    `kind` is namespaced by the caller (`entry:breakdown`, `ticket:breakdown`,
    ...) so Entry and Ticket sequences never collide even when the
    underlying register/source_kind string is identical."""

    __tablename__ = "id_counters"

    kind: Mapped[str] = mapped_column(String(32), primary_key=True)
    year: Mapped[int] = mapped_column(Integer, primary_key=True)
    next_value: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
