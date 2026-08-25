from __future__ import annotations

from datetime import datetime
from decimal import Decimal

from sqlalchemy import (
    Enum,
    ForeignKey,
    Numeric,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, TZDateTime, created_at_col, new_uuid, pk_uuid
from app.models.enums import (
    JOB_CARD_RECON_KIND_ENUM,
    JOB_CARD_SOURCE_ENUM,
    JOB_CARD_STATUS_ENUM,
    JobCardReconKind,
    JobCardSource,
    JobCardStatus,
)


class JobCard(Base):
    """One SAP maintenance order, born in ENM. See
    docs/superpowers/specs/2026-08-24-sap-pm-enm-integration-design.md,
    section 3, for the posting sequence and retry rules.

    `source_id` points at `entries.id` (source in entry/breakdown) or
    `inspection_entries.id` (source=inspection) — two different tables, so
    this is a loose reference rather than an FK, the same way `alerts`
    already points at `entries`/`inspection_slots` optionally.
    """

    __tablename__ = "job_cards"
    __table_args__ = (
        UniqueConstraint(
            "source", "source_id", name="uq_job_cards_source_source_id"
        ),
    )

    id: Mapped[str] = pk_uuid()
    site_code: Mapped[str] = mapped_column(
        String(50), ForeignKey("sites.code", ondelete="RESTRICT"), nullable=False
    )
    bus_id: Mapped[str] = mapped_column(
        String(32), ForeignKey("vehicles.id", ondelete="RESTRICT"), nullable=False
    )
    source: Mapped[JobCardSource] = mapped_column(
        Enum(
            JobCardSource,
            name=JOB_CARD_SOURCE_ENUM,
            values_callable=lambda e: [m.value for m in e],
        ),
        nullable=False,
    )
    source_id: Mapped[str] = mapped_column(String(32), nullable=False)
    #: Set when this job card grew out of a fleet-streams breakdown, so the
    #: two records can be cross-referenced. Independent of `source`, which
    #: names the ENM row (entry/inspection) the materials were saved against.
    streams_breakdown_id: Mapped[str | None] = mapped_column(
        String(64), nullable=True
    )

    status: Mapped[JobCardStatus] = mapped_column(
        Enum(
            JobCardStatus,
            name=JOB_CARD_STATUS_ENUM,
            values_callable=lambda e: [m.value for m in e],
        ),
        nullable=False,
        default=JobCardStatus.draft,
    )

    # --- posting checkpoints — each None until its step has succeeded ------
    sap_notification_no: Mapped[str | None] = mapped_column(
        String(40), nullable=True
    )
    sap_order_no: Mapped[str | None] = mapped_column(String(40), nullable=True)
    components_added_at: Mapped[datetime | None] = mapped_column(
        TZDateTime, nullable=True
    )
    confirmed_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)

    posted_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
    last_sap_error: Mapped[str | None] = mapped_column(Text, nullable=True)

    # --- confirmation, copied from the register/inspection at post ---------
    mechanic: Mapped[str | None] = mapped_column(String(255), nullable=True)
    hours: Mapped[Decimal | None] = mapped_column(Numeric(6, 2), nullable=True)
    work_done: Mapped[str | None] = mapped_column(Text, nullable=True)

    created_by_id: Mapped[str] = mapped_column(
        String(32), ForeignKey("users.id", ondelete="RESTRICT"), nullable=False
    )
    created_at: Mapped[datetime] = created_at_col()
    updated_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)

    components: Mapped[list[JobCardComponent]] = relationship(
        back_populates="job_card", cascade="all, delete-orphan", lazy="selectin"
    )


class JobCardComponent(Base):
    """One material line. `sap_material_no` is a plain string, not yet an FK
    to a `sap_materials` catalog — that table arrives with the SAP master
    sync phase. Validating against a catalog that doesn't exist would be
    validating against nothing."""

    __tablename__ = "job_card_components"

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_uuid)
    job_card_id: Mapped[str] = mapped_column(
        String(32),
        ForeignKey("job_cards.id", ondelete="CASCADE"),
        nullable=False,
    )
    sap_material_no: Mapped[str] = mapped_column(String(40), nullable=False)
    qty_required: Mapped[Decimal] = mapped_column(Numeric(10, 2), nullable=False)
    #: Comes back from SAP once material has actually been issued. 0 until
    #: then, never negative, never set by ENM itself.
    qty_issued: Mapped[Decimal] = mapped_column(
        Numeric(10, 2), nullable=False, default=0, server_default="0"
    )

    job_card: Mapped[JobCard] = relationship(back_populates="components")


class JobCardReconException(Base):
    """One disagreement the daily recon found between ENM and SAP. A person
    resolves it; nothing here ever edits `job_cards` or SAP — this is an
    exception list, not a third editor."""

    __tablename__ = "job_card_recon_exceptions"

    id: Mapped[str] = pk_uuid()
    site_code: Mapped[str] = mapped_column(
        String(50), ForeignKey("sites.code", ondelete="RESTRICT"), nullable=False
    )
    #: Null for a sap_only exception — there is no ENM card to point at.
    job_card_id: Mapped[str | None] = mapped_column(
        String(32), ForeignKey("job_cards.id", ondelete="SET NULL"), nullable=True
    )
    sap_order_no: Mapped[str | None] = mapped_column(String(40), nullable=True)
    kind: Mapped[JobCardReconKind] = mapped_column(
        Enum(
            JobCardReconKind,
            name=JOB_CARD_RECON_KIND_ENUM,
            values_callable=lambda e: [m.value for m in e],
        ),
        nullable=False,
    )
    detail: Mapped[str] = mapped_column(Text, nullable=False)
    detected_at: Mapped[datetime] = created_at_col()
    resolved_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
    resolved_by_id: Mapped[str | None] = mapped_column(
        String(32), ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
