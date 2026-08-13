from __future__ import annotations

from datetime import datetime

from sqlalchemy import (
    Boolean,
    Enum,
    ForeignKey,
    Index,
    String,
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, TZDateTime, created_at_col, new_uuid
from app.models.enums import PLATFORM_ENUM, ROLE_ENUM, Platform, Role


class User(Base):
    __tablename__ = "users"
    __table_args__ = (
        UniqueConstraint("user_id", name="uq_users_user_id"),
        UniqueConstraint("email", name="uq_users_email"),
        Index("ix_users_is_active", "is_active"),
    )

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_uuid)
    name: Mapped[str] = mapped_column(String(160), nullable=False)
    # ground-staff login handle, e.g. TV4021
    user_id: Mapped[str] = mapped_column(String(64), nullable=False)
    # optional; presence enables Microsoft SSO
    email: Mapped[str | None] = mapped_column(String(255), nullable=True)
    password_hash: Mapped[str | None] = mapped_column(String(255), nullable=True)
    role: Mapped[Role] = mapped_column(
        Enum(Role, name=ROLE_ENUM, values_callable=lambda e: [m.value for m in e]),
        nullable=False,
    )
    is_active: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=True, server_default="true"
    )
    must_reset_password: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default="false"
    )
    created_at: Mapped[datetime] = created_at_col()
    updated_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
    last_login_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)

    depot_links: Mapped[list[UserDepotAccess]] = relationship(
        back_populates="user",
        cascade="all, delete-orphan",
        lazy="selectin",
        order_by="UserDepotAccess.depot_code",
    )

    @property
    def depot_access(self) -> list[str]:
        return [link.depot_code for link in self.depot_links]

    def can_access(self, depot_code: str) -> bool:
        return depot_code in self.depot_access


class UserDepotAccess(Base):
    __tablename__ = "user_depot_access"

    user_id: Mapped[str] = mapped_column(
        String(32), ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    depot_code: Mapped[str] = mapped_column(
        String(16), ForeignKey("depots.code", ondelete="CASCADE"), primary_key=True
    )

    user: Mapped[User] = relationship(back_populates="depot_links")


class RefreshToken(Base):
    """DB-backed refresh tokens so deactivation revokes sessions immediately."""

    __tablename__ = "refresh_tokens"
    __table_args__ = (
        UniqueConstraint("token_hash", name="uq_refresh_tokens_token_hash"),
        Index("ix_refresh_tokens_user_id_revoked_at", "user_id", "revoked_at"),
    )

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_uuid)
    user_id: Mapped[str] = mapped_column(
        String(32), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    token_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    expires_at: Mapped[datetime] = mapped_column(TZDateTime, nullable=False)
    revoked_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
    created_at: Mapped[datetime] = created_at_col()
    user_agent: Mapped[str | None] = mapped_column(String(255), nullable=True)


class DeviceToken(Base):
    """FCM registration tokens, one row per device per user."""

    __tablename__ = "device_tokens"
    __table_args__ = (
        UniqueConstraint("fcm_token", name="uq_device_tokens_fcm_token"),
        Index("ix_device_tokens_user_id_is_active", "user_id", "is_active"),
    )

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_uuid)
    user_id: Mapped[str] = mapped_column(
        String(32), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    fcm_token: Mapped[str] = mapped_column(String(512), nullable=False)
    platform: Mapped[Platform] = mapped_column(
        Enum(
            Platform,
            name=PLATFORM_ENUM,
            values_callable=lambda e: [m.value for m in e],
        ),
        nullable=False,
        default=Platform.android,
    )
    is_active: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=True, server_default="true"
    )
    created_at: Mapped[datetime] = created_at_col()
    last_seen_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
