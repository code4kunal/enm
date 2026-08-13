from __future__ import annotations

from fastapi import APIRouter
from sqlalchemy import text

from app.config import settings
from app.deps import SessionDep

router = APIRouter(tags=["misc"])


@router.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok", "version": settings.version}


@router.get("/health/ready")
async def ready(session: SessionDep) -> dict[str, str]:
    """Liveness is cheap; readiness proves the DB round-trips."""
    await session.execute(text("SELECT 1"))
    return {"status": "ok", "version": settings.version, "database": "ok"}
