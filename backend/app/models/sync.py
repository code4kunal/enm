from __future__ import annotations

from datetime import datetime

from sqlalchemy import String
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base, TZDateTime


class SyncCursor(Base):
    """A one-row-per-name bookmark for a catch-up job.

    Its first user is `app.services.streams.replay_on_startup` — "resume the
    fleet-streams event replay after this id" — but the shape carries no
    streams-specific meaning; a future nightly sync can keep its own
    "last synced at" here under a different `name` rather than growing a
    dedicated column somewhere per job.
    """

    __tablename__ = "sync_cursors"

    name: Mapped[str] = mapped_column(String(64), primary_key=True)
    value: Mapped[str | None] = mapped_column(String(255), nullable=True)
    updated_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
