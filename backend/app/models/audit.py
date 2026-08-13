from __future__ import annotations

from datetime import datetime

from sqlalchemy import ForeignKey, Index, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base, created_at_col, new_uuid


class AuditLog(Base):
    """Append-only trail for entry edits and user activate/deactivate.

    `before`/`after` are serialized JSON kept as TEXT — this table is written
    often and read rarely, and we never query inside the payload.
    """

    __tablename__ = "audit_logs"
    __table_args__ = (
        Index("ix_audit_logs_object_type_object_id", "object_type", "object_id"),
        Index("ix_audit_logs_created_at", "created_at"),
    )

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_uuid)
    actor_id: Mapped[str | None] = mapped_column(
        String(32), ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
    action: Mapped[str] = mapped_column(String(64), nullable=False)
    object_type: Mapped[str] = mapped_column(String(32), nullable=False)
    object_id: Mapped[str] = mapped_column(String(64), nullable=False)
    before: Mapped[str | None] = mapped_column(Text, nullable=True)
    after: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = created_at_col()
