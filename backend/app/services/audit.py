from __future__ import annotations

import json
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
