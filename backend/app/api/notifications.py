from __future__ import annotations

from datetime import UTC, datetime
from typing import Annotated

from fastapi import APIRouter, Query, status
from sqlalchemy import func, select, update

from app.deps import CurrentUser, PageDep, SessionDep
from app.errors import NotFound
from app.models.notification import Notification
from app.models.user import DeviceToken
from app.schemas.common import Page
from app.schemas.notification import (
    DeviceTokenIn,
    DeviceTokenOut,
    NotificationOut,
    UnreadCountOut,
)

router = APIRouter(tags=["notifications"])


@router.get("/notifications", response_model=Page[NotificationOut])
async def list_notifications(
    user: CurrentUser,
    session: SessionDep,
    page: PageDep,
    unread_only: Annotated[bool, Query()] = False,
) -> Page[NotificationOut]:
    stmt = select(Notification).where(Notification.user_id == user.id)
    if unread_only:
        stmt = stmt.where(Notification.is_read.is_(False))

    total = int(
        await session.scalar(
            select(func.count()).select_from(
                stmt.with_only_columns(Notification.id).subquery()
            )
        )
        or 0
    )
    rows = await session.scalars(
        stmt.order_by(Notification.created_at.desc())
        .offset(page.offset)
        .limit(page.page_size)
    )
    return Page[NotificationOut](
        items=[NotificationOut.model_validate(n, from_attributes=True) for n in rows],
        page=page.page,
        page_size=page.page_size,
        total=total,
    )


@router.get("/notifications/unread-count", response_model=UnreadCountOut)
async def unread_count(user: CurrentUser, session: SessionDep) -> UnreadCountOut:
    n = await session.scalar(
        select(func.count())
        .select_from(Notification)
        .where(Notification.user_id == user.id, Notification.is_read.is_(False))
    )
    return UnreadCountOut(unread=int(n or 0))


@router.post("/notifications/{notification_id}/read", response_model=NotificationOut)
async def mark_read(
    notification_id: str, user: CurrentUser, session: SessionDep
) -> NotificationOut:
    row = await session.scalar(
        select(Notification).where(
            Notification.id == notification_id, Notification.user_id == user.id
        )
    )
    if row is None:
        raise NotFound("Notification not found")
    row.is_read = True
    await session.commit()
    return NotificationOut.model_validate(row, from_attributes=True)


@router.post("/notifications/read-all", status_code=status.HTTP_204_NO_CONTENT, response_model=None)
async def mark_all_read(user: CurrentUser, session: SessionDep) -> None:
    await session.execute(
        update(Notification)
        .where(Notification.user_id == user.id, Notification.is_read.is_(False))
        .values(is_read=True)
    )
    await session.commit()


# --- device registration ---------------------------------------------------


@router.post(
    "/devices/token", response_model=DeviceTokenOut, status_code=status.HTTP_201_CREATED
)
async def register_device(
    payload: DeviceTokenIn, user: CurrentUser, session: SessionDep
) -> DeviceTokenOut:
    """Idempotent: re-registering an FCM token re-points it at the current user."""
    row = await session.scalar(
        select(DeviceToken).where(DeviceToken.fcm_token == payload.fcm_token)
    )
    now = datetime.now(UTC)
    if row is None:
        row = DeviceToken(
            user_id=user.id, fcm_token=payload.fcm_token, platform=payload.platform
        )
        session.add(row)
    else:
        row.user_id = user.id
        row.platform = payload.platform
        row.is_active = True
    row.last_seen_at = now
    await session.commit()
    await session.refresh(row)
    return DeviceTokenOut(
        id=row.id, platform=row.platform, created_at=row.created_at
    )


@router.delete("/devices/token", status_code=status.HTTP_204_NO_CONTENT, response_model=None)
async def unregister_device(
    payload: DeviceTokenIn, user: CurrentUser, session: SessionDep
) -> None:
    await session.execute(
        update(DeviceToken)
        .where(
            DeviceToken.fcm_token == payload.fcm_token, DeviceToken.user_id == user.id
        )
        .values(is_active=False)
    )
    await session.commit()
