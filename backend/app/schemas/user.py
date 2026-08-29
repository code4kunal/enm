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
    #: empty and ignored for a super admin, who reaches every site
    site_access: list[str]
    #: Reaches every site without a stored grant. True for an E&M super admin
    #: and for a platform `admin`, whose E&M `role` column is only a label.
    governs_all_sites: bool = False
    #: What this account may do, as `em_<resource>:<action>` names. Granted in
    #: siteops-platform for a platform user; derived from `role` for an
    #: E&M-local one. The client gates its navigation on these rather than on
    #: `role`, which is a label once the platform is the authority.
    permissions: list[str] = Field(default_factory=list)
    is_active: bool
    must_reset_password: bool = False
    created_at: ISTDateTime | None = None
    last_login_at: ISTDateTime | None = None


class UserCreatedOut(UserOut):
    """Create/reset echo the generated password exactly once — the admin reads
    it aloud to a mechanic and it is never retrievable again."""

    temp_password: str | None = None


class UserBrief(BaseModel):
    """Embedded in Entry.created_by."""

    id: str
    name: str
    user_id: str


class UserCreate(BaseModel):
    name: str = Field(min_length=1, max_length=500)
    user_id: str = Field(min_length=1, max_length=64)
    email: EmailStr | None = None
    role: Role
    #: a super admin needs none; every other role needs at least one
    site_access: list[str] = Field(default_factory=list)
    temp_password: str | None = Field(default=None, min_length=6, max_length=128)

    @field_validator("user_id")
    @classmethod
    def _normalize_user_id(cls, v: str) -> str:
        return v.strip().upper()

    @field_validator("name")
    @classmethod
    def _strip_name(cls, v: str) -> str:
        return v.strip()

    @field_validator("site_access")
    @classmethod
    def _normalize_sites(cls, v: list[str]) -> list[str]:
        seen: list[str] = []
        for code in v:
            code = code.strip().upper()
            if code and code not in seen:
                seen.append(code)
        return seen


class UserUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=500)
    user_id: str | None = Field(default=None, min_length=1, max_length=64)
    email: EmailStr | None = None
    role: Role | None = None
    site_access: list[str] | None = None

    @field_validator("user_id")
    @classmethod
    def _normalize_user_id(cls, v: str | None) -> str | None:
        return v.strip().upper() if v else v

    @field_validator("site_access")
    @classmethod
    def _normalize_sites(cls, v: list[str] | None) -> list[str] | None:
        if v is None:
            return None
        seen: list[str] = []
        for code in v:
            code = code.strip().upper()
            if code and code not in seen:
                seen.append(code)
        return seen


class ResetPasswordIn(BaseModel):
    #: omitted means the server generates one and returns it once
    temp_password: str | None = Field(default=None, min_length=6, max_length=128)


class TempPasswordOut(BaseModel):
    temp_password: str


class ChangePasswordIn(BaseModel):
    current_password: str = Field(min_length=1, max_length=128)
    new_password: str = Field(min_length=8, max_length=128)
