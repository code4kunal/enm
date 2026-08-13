from __future__ import annotations

from datetime import datetime

from sqlalchemy import Boolean, Enum, ForeignKey, Index, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base, created_at_col, new_uuid
from app.models.enums import NOTIFICATION_TYPE_ENUM, NotificationType


class Notification(Base):
    """In-app notification inbox. FCM push is the delivery channel; this table
    is the durable record the app reads on open."""

    __tablename__ = "notifications"
    __table_args__ = (
        Index("ix_notifications_user_id_is_read", "user_id", "is_read"),
        Index("ix_notifications_user_id_created_at", "user_id", "created_at"),
    )

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_uuid)
    user_id: Mapped[str] = mapped_column(
        String(32), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    type: Mapped[NotificationType] = mapped_column(
        Enum(
            NotificationType,
            name=NOTIFICATION_TYPE_ENUM,
            values_callable=lambda e: [m.value for m in e],
        ),
        nullable=False,
    )
    title: Mapped[str] = mapped_column(String(255), nullable=False)
    body: Mapped[str] = mapped_column(Text, nullable=False)
    entry_id: Mapped[str | None] = mapped_column(
        String(32), ForeignKey("entries.id", ondelete="CASCADE"), nullable=True
    )
    depot_code: Mapped[str | None] = mapped_column(String(16), nullable=True)
    is_read: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default="false"
    )
    created_at: Mapped[datetime] = created_at_col()
