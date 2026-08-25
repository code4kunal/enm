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
    #: E.164, e.g. "+919876543210". Unset means this user never gets a
    #: WhatsApp push — the same graceful-skip every other channel gets.
    whatsapp_number: Mapped[str | None] = mapped_column(String(20), nullable=True)
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

    site_links: Mapped[list[UserSiteAccess]] = relationship(
        back_populates="user",
        cascade="all, delete-orphan",
        lazy="selectin",
        order_by="UserSiteAccess.site_code",
    )

    @property
    def is_super_admin(self) -> bool:
        return self.role is Role.super_admin

    @property
    def site_access(self) -> list[str]:
        """Explicit grants. Empty and ignored for a super admin — always ask
        `can_access` rather than reading this."""
        return [link.site_code for link in self.site_links]

    def can_access(self, site_code: str) -> bool:
        """A super admin reaches every site without a stored grant.

        Storing every code would go stale the moment a site is onboarded.
        """
        return self.is_super_admin or site_code in self.site_access

    def can_grant(self, role: Role) -> bool:
        return role in self.role.grantable_roles


class UserSiteAccess(Base):
    __tablename__ = "user_site_access"

    user_id: Mapped[str] = mapped_column(
        String(32), ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    site_code: Mapped[str] = mapped_column(
        String(50), ForeignKey("sites.code", ondelete="CASCADE"), primary_key=True
    )

    user: Mapped[User] = relationship(back_populates="site_links")


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
