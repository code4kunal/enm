from __future__ import annotations

from pydantic import BaseModel, EmailStr, Field, field_validator

from app.models.enums import Role
from app.schemas.common import ISTDateTime


class UserOut(BaseModel):
    id: str
    name: str
    user_id: str
    email: str | None
    role: Role
    depot_access: list[str]
    is_active: bool
    must_reset_password: bool = False
    created_at: ISTDateTime | None = None
    last_login_at: ISTDateTime | None = None


class UserBrief(BaseModel):
    """Embedded in Entry.created_by."""

    id: str
    name: str
    user_id: str


class UserCreate(BaseModel):
    name: str = Field(min_length=1, max_length=160)
    user_id: str = Field(min_length=1, max_length=64)
    email: EmailStr | None = None
    role: Role
    depot_access: list[str] = Field(min_length=1)
    temp_password: str | None = Field(default=None, min_length=6, max_length=128)

    @field_validator("user_id")
    @classmethod
    def _normalize_user_id(cls, v: str) -> str:
        return v.strip().upper()

    @field_validator("name")
    @classmethod
    def _strip_name(cls, v: str) -> str:
        return v.strip()

    @field_validator("depot_access")
    @classmethod
    def _normalize_depots(cls, v: list[str]) -> list[str]:
        seen: list[str] = []
        for code in v:
            code = code.strip().upper()
            if code and code not in seen:
                seen.append(code)
        return seen


class UserUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=160)
    user_id: str | None = Field(default=None, min_length=1, max_length=64)
    email: EmailStr | None = None
    role: Role | None = None
    depot_access: list[str] | None = Field(default=None, min_length=1)

    @field_validator("user_id")
    @classmethod
    def _normalize_user_id(cls, v: str | None) -> str | None:
        return v.strip().upper() if v else v

    @field_validator("depot_access")
    @classmethod
    def _normalize_depots(cls, v: list[str] | None) -> list[str] | None:
        if v is None:
            return None
        seen: list[str] = []
        for code in v:
            code = code.strip().upper()
            if code and code not in seen:
                seen.append(code)
        return seen


class ResetPasswordIn(BaseModel):
    temp_password: str = Field(min_length=6, max_length=128)


class ChangePasswordIn(BaseModel):
    current_password: str = Field(min_length=1, max_length=128)
    new_password: str = Field(min_length=8, max_length=128)
