from __future__ import annotations

from sqlalchemy import ForeignKey, String
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base, created_at_col, new_uuid


class EntryPhoto(Base):
    """One-to-many, replacing the old single `Entry.photo_key`/`photo_url`
    columns. Reuses `services/storage.py`'s save/validate/delete unchanged --
    those were already generic per `entry_id` with random-named files,
    nothing about them assumed one photo per entry."""

    __tablename__ = "entry_photos"

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_uuid)
    entry_id: Mapped[str] = mapped_column(
        String(32), ForeignKey("entries.id", ondelete="CASCADE"), nullable=False
    )
    storage_key: Mapped[str] = mapped_column(String(255), nullable=False)
    url: Mapped[str] = mapped_column(String(500), nullable=False)
    caption: Mapped[str | None] = mapped_column(String(255), nullable=True)
    uploaded_by_id: Mapped[str | None] = mapped_column(
        String(32), ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
    created_at = created_at_col()
