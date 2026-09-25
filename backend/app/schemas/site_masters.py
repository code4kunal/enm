from __future__ import annotations

from pydantic import BaseModel, Field, field_validator


class SparePartOut(BaseModel):
    id: str
    part_no: str
    name: str
    is_active: bool


class SparePartList(BaseModel):
    items: list[SparePartOut]


class SparePartCreate(BaseModel):
    part_no: str = Field(min_length=1, max_length=64)
    name: str = Field(min_length=1, max_length=160)

    @field_validator("part_no")
    @classmethod
    def _upper(cls, v: str) -> str:
        return " ".join(v.split()).upper()

    @field_validator("name")
    @classmethod
    def _strip(cls, v: str) -> str:
        return v.strip()


class SparePartUpdate(BaseModel):
    part_no: str | None = Field(default=None, min_length=1, max_length=64)
    name: str | None = Field(default=None, min_length=1, max_length=160)

    @field_validator("part_no")
    @classmethod
    def _upper(cls, v: str | None) -> str | None:
        return " ".join(v.split()).upper() if v else v

    @field_validator("name")
    @classmethod
    def _strip(cls, v: str | None) -> str | None:
        return v.strip() if v else v


class DriverOut(BaseModel):
    id: str
    driver_code: str
    name: str
    is_active: bool


class DriverList(BaseModel):
    items: list[DriverOut]


class DriverCreate(BaseModel):
    driver_code: str = Field(min_length=1, max_length=64)
    name: str = Field(min_length=1, max_length=160)

    @field_validator("driver_code")
    @classmethod
    def _upper(cls, v: str) -> str:
        return " ".join(v.split()).upper()

    @field_validator("name")
    @classmethod
    def _strip(cls, v: str) -> str:
        return v.strip()


class DriverUpdate(BaseModel):
    driver_code: str | None = Field(default=None, min_length=1, max_length=64)
    name: str | None = Field(default=None, min_length=1, max_length=160)

    @field_validator("driver_code")
    @classmethod
    def _upper(cls, v: str | None) -> str | None:
        return " ".join(v.split()).upper() if v else v

    @field_validator("name")
    @classmethod
    def _strip(cls, v: str | None) -> str | None:
        return v.strip() if v else v
