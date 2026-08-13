from __future__ import annotations

from pydantic import BaseModel, Field

from app.models.enums import NotificationType, Platform
from app.schemas.common import ISTDateTime


class NotificationOut(BaseModel):
    id: str
    type: NotificationType
    title: str
    body: str
    entry_id: str | None
    depot: str | None = Field(default=None, alias="depot_code")
    is_read: bool
    created_at: ISTDateTime

    model_config = {"populate_by_name": True}


class UnreadCountOut(BaseModel):
    unread: int


class DeviceTokenIn(BaseModel):
    fcm_token: str = Field(min_length=10, max_length=512)
    platform: Platform = Platform.android


class DeviceTokenOut(BaseModel):
    id: str
    platform: Platform
    created_at: ISTDateTime
