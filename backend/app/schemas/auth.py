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


class SSOConfigOut(BaseModel):
    """What the sign-in screen needs to offer Microsoft sign-in.

    Served rather than compiled into the client so one build works against a
    site that has SSO and one that does not — and so the button can hide
    itself instead of failing when someone taps it.
    """

    enabled: bool = False
    tenant_id: str | None = None
    client_id: str | None = None
    #: Where Entra sends the browser back. The client passes the one it used;
    #: this is the value the app registration must list.
    authority: str | None = None
    scopes: list[str] = Field(default_factory=lambda: ["openid", "profile", "email"])
