from __future__ import annotations

from pydantic import BaseModel, Field

from app.schemas.user import UserOut


class LoginIn(BaseModel):
    user_id: str = Field(min_length=1, max_length=64)
    password: str = Field(min_length=1, max_length=128)


class SSOLoginIn(BaseModel):
    ms_id_token: str = Field(min_length=10)


class RefreshIn(BaseModel):
    refresh_token: str = Field(min_length=10)


class TokenOut(BaseModel):
    access_token: str
    refresh_token: str
    expires_in: int
    user: UserOut
