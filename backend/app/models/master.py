from __future__ import annotations

from sqlalchemy import Boolean, ForeignKey, Index, Integer, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, new_uuid


class Depot(Base):
    __tablename__ = "depots"

    code: Mapped[str] = mapped_column(String(16), primary_key=True)
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    is_active: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=True, server_default="true"
    )

    buses: Mapped[list[Bus]] = relationship(back_populates="depot")


class Bus(Base):
    __tablename__ = "buses"
    __table_args__ = (
        UniqueConstraint("bus_no", name="uq_buses_bus_no"),
        Index("ix_buses_depot_code_is_active", "depot_code", "is_active"),
    )

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_uuid)
    # normalized: uppercase, no spaces
    bus_no: Mapped[str] = mapped_column(String(32), nullable=False)
    depot_code: Mapped[str] = mapped_column(
        String(16), ForeignKey("depots.code", ondelete="RESTRICT"), nullable=False
    )
    is_active: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=True, server_default="true"
    )

    depot: Mapped[Depot] = relationship(back_populates="buses")


class DefectSource(Base):
    """Master list backing the Defect Source dropdown."""

    __tablename__ = "defect_sources"
    __table_args__ = (UniqueConstraint("name", name="uq_defect_sources_name"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    sort_order: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    is_active: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=True, server_default="true"
    )


class DefectType(Base):
    """Master list backing the Defect Type dropdown."""

    __tablename__ = "defect_types"
    __table_args__ = (UniqueConstraint("name", name="uq_defect_types_name"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    sort_order: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    is_active: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=True, server_default="true"
    )
