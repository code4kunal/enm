from __future__ import annotations

from pydantic import BaseModel, Field, field_validator

from app.models.enums import Register, Role


class MasterItemOut(BaseModel):
    """A row in an editable dropdown list (defect sources, defect types)."""

    id: int
    name: str
    is_active: bool
    sort_order: int


class MasterItemList(BaseModel):
    items: list[MasterItemOut]


class MasterItemCreate(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    sort_order: int | None = Field(default=None, ge=0, le=10_000)

    @field_validator("name")
    @classmethod
    def _strip(cls, v: str) -> str:
        return v.strip()


class MasterItemUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=120)
    is_active: bool | None = None
    sort_order: int | None = Field(default=None, ge=0, le=10_000)

    @field_validator("name")
    @classmethod
    def _strip(cls, v: str | None) -> str | None:
        return v.strip() if v else v


class StringList(BaseModel):
    items: list[str]


class WorkTypeOut(BaseModel):
    """A TYPE OF WORK code and the register its rows land in."""

    id: int
    code: str
    name: str
    register: Register | None = None
    is_active: bool
    sort_order: int


class WorkTypeList(BaseModel):
    items: list[WorkTypeOut]


class WorkTypeCreate(BaseModel):
    code: str = Field(min_length=1, max_length=32)
    name: str = Field(min_length=1, max_length=120)
    register: Register | None = None
    sort_order: int | None = Field(default=None, ge=0, le=10_000)

    @field_validator("code")
    @classmethod
    def _upper(cls, v: str) -> str:
        return " ".join(v.split()).upper()

    @field_validator("name")
    @classmethod
    def _strip_name(cls, v: str) -> str:
        return v.strip()


class WorkTypeUpdate(BaseModel):
    code: str | None = Field(default=None, min_length=1, max_length=32)
    name: str | None = Field(default=None, min_length=1, max_length=120)
    register: Register | None = None
    is_active: bool | None = None
    sort_order: int | None = Field(default=None, ge=0, le=10_000)

    @field_validator("code")
    @classmethod
    def _upper(cls, v: str | None) -> str | None:
        return " ".join(v.split()).upper() if v else v


class StaffOut(BaseModel):
    """A person a register entry can be attributed to."""

    id: str
    name: str
    user_id: str
    role: Role


class StaffList(BaseModel):
    items: list[StaffOut]
