from __future__ import annotations

import json
from datetime import datetime
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession

from app.models.audit import AuditLog
from app.models.enums import AuditAction


def _dump(payload: dict[str, Any] | None) -> str | None:
    if payload is None:
        return None
    return json.dumps(payload, default=str, ensure_ascii=False)


async def record(
    session: AsyncSession,
    *,
    actor_id: str | None,
    action: AuditAction,
    object_type: str,
    object_id: str,
    before: dict[str, Any] | None = None,
    after: dict[str, Any] | None = None,
) -> None:
    """Append an audit row. Caller owns the commit."""
    session.add(
        AuditLog(
            actor_id=actor_id,
            action=action.value,
            object_type=object_type,
            object_id=object_id,
            before=_dump(before),
            after=_dump(after),
        )
    )


async def list_logs(
    session: AsyncSession,
    *,
    actor_id: str | None = None,
    action: str | None = None,
    object_type: str | None = None,
    date_from: datetime | None = None,
    date_to: datetime | None = None,
    offset: int = 0,
    limit: int = 50,
) -> tuple[list[AuditLog], int]:
    """Newest-first page of audit rows, optionally filtered."""
    from sqlalchemy import func, select

    filters = []
    if actor_id:
        filters.append(AuditLog.actor_id == actor_id)
    if action:
        filters.append(AuditLog.action == action)
    if object_type:
        filters.append(AuditLog.object_type == object_type)
    if date_from is not None:
        filters.append(AuditLog.created_at >= date_from)
    if date_to is not None:
        filters.append(AuditLog.created_at <= date_to)

    count_stmt = select(func.count()).select_from(AuditLog)
    list_stmt = select(AuditLog).order_by(AuditLog.created_at.desc())
    for f in filters:
        count_stmt = count_stmt.where(f)
        list_stmt = list_stmt.where(f)

    total = int(await session.scalar(count_stmt) or 0)
    rows = list(
        (await session.scalars(list_stmt.offset(offset).limit(limit))).all()
    )
    return rows, total
