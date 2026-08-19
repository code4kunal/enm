from __future__ import annotations

from datetime import datetime

from sqlalchemy import Enum, ForeignKey, Index, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, TZDateTime, created_at_col, new_uuid
from app.models.enums import IMPORT_TARGET_ENUM, ImportTarget


class SiteImportProfile(Base):
    """A saved translation from one site's spreadsheet shape to a target.

    Import formats vary site to site; the target shape is fixed. Sites resend
    the same monthly sheet, so the mapping is configured once and replayed —
    that is the whole point of profiles over a one-shot wizard.
    """

    __tablename__ = "site_import_profiles"
    __table_args__ = (Index("ix_site_import_profiles_site_code", "site_code"),)

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_uuid)
    site_code: Mapped[str] = mapped_column(
        String(50), ForeignKey("sites.code", ondelete="CASCADE"), nullable=False
    )
    name: Mapped[str] = mapped_column(String(160), nullable=False)
    target: Mapped[ImportTarget] = mapped_column(
        Enum(
            ImportTarget,
            name=IMPORT_TARGET_ENUM,
            values_callable=lambda e: [m.value for m in e],
        ),
        nullable=False,
    )
    sheet_name: Mapped[str | None] = mapped_column(String(120), nullable=True)
    header_row: Mapped[int] = mapped_column(
        Integer, nullable=False, default=1, server_default="1"
    )
    skip_rows: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0, server_default="0"
    )
    last_run_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
    created_by_id: Mapped[str | None] = mapped_column(
        String(32), ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
    created_at: Mapped[datetime] = created_at_col()

    mappings: Mapped[list[SiteImportMapping]] = relationship(
        back_populates="profile",
        cascade="all, delete-orphan",
        lazy="selectin",
        order_by="SiteImportMapping.target_key",
    )


class SiteImportMapping(Base):
    """Binds one source column (or a constant) to one target field."""

    __tablename__ = "site_import_mappings"

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_uuid)
    profile_id: Mapped[str] = mapped_column(
        String(32),
        ForeignKey("site_import_profiles.id", ondelete="CASCADE"),
        nullable=False,
    )
    target_key: Mapped[str] = mapped_column(String(64), nullable=False)
    source_column: Mapped[str] = mapped_column(
        String(255), nullable=False, default="", server_default=""
    )
    # A literal applied to every row, for sheets that omit a field the target
    # needs.
    constant_value: Mapped[str | None] = mapped_column(String(255), nullable=True)
    date_format: Mapped[str | None] = mapped_column(String(32), nullable=True)

    profile: Mapped[SiteImportProfile] = relationship(back_populates="mappings")


class SiteImportRun(Base):
    """One committed import, kept as site history."""

    __tablename__ = "site_import_runs"
    __table_args__ = (Index("ix_site_import_runs_site_code_run_at", "site_code", "run_at"),)

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_uuid)
    site_code: Mapped[str] = mapped_column(
        String(50), ForeignKey("sites.code", ondelete="CASCADE"), nullable=False
    )
    # Kept by value as well as by id: the run history has to survive the
    # profile being deleted.
    profile_id: Mapped[str | None] = mapped_column(
        String(32),
        ForeignKey("site_import_profiles.id", ondelete="SET NULL"),
        nullable=True,
    )
    profile_name: Mapped[str] = mapped_column(String(160), nullable=False)
    target: Mapped[ImportTarget] = mapped_column(
        Enum(
            ImportTarget,
            name=IMPORT_TARGET_ENUM,
            values_callable=lambda e: [m.value for m in e],
        ),
        nullable=False,
    )
    file_name: Mapped[str] = mapped_column(String(255), nullable=False)
    rows_accepted: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0, server_default="0"
    )
    #: Rows the sheet held that this site already had. On a re-run this is
    #: everything, and that is the point.
    rows_unchanged: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0, server_default="0"
    )
    rows_rejected: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0, server_default="0"
    )
    notes: Mapped[str] = mapped_column(
        Text, nullable=False, default="", server_default=""
    )
    run_at: Mapped[datetime] = created_at_col()
    run_by_id: Mapped[str | None] = mapped_column(
        String(32), ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
