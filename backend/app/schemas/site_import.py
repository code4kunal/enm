from __future__ import annotations

from pydantic import BaseModel, Field

from app.models.enums import ImportTarget
from app.schemas.common import ISTDateTime


class ColumnMappingIO(BaseModel):
    target_key: str = Field(min_length=1, max_length=64)
    source_column: str = Field(default="", max_length=255)
    #: a literal applied to every row, for sheets missing a column the target needs
    constant_value: str | None = Field(default=None, max_length=255)
    date_format: str | None = Field(default=None, max_length=32)


class ImportProfileIn(BaseModel):
    name: str = Field(min_length=1, max_length=500)
    target: ImportTarget
    mappings: list[ColumnMappingIO] = Field(default_factory=list)
    sheet_name: str | None = Field(default=None, max_length=120)
    header_row: int = Field(default=1, ge=1, le=1000)
    skip_rows: int = Field(default=0, ge=0, le=1000)


class ImportProfileOut(BaseModel):
    id: str
    site_code: str
    name: str
    target: ImportTarget
    mappings: list[ColumnMappingIO]
    sheet_name: str | None = None
    header_row: int
    skip_rows: int
    last_run_at: ISTDateTime | None = None


class ImportProfileList(BaseModel):
    items: list[ImportProfileOut]


class SourceInspectionOut(BaseModel):
    file_name: str
    sheet_names: list[str]
    columns: list[str]
    sample_rows: list[dict[str, str]]
    total_rows: int


class RowErrorOut(BaseModel):
    #: the row number the user sees in Excel — blank rows must not shift it
    row_number: int
    field: str = ""
    message: str


class ImportPreviewOut(BaseModel):
    token: str
    file_name: str
    target: ImportTarget
    rows: list[dict[str, str]]
    errors: list[RowErrorOut]
    total_rows: int
    new_count: int = 0
    update_count: int = 0


class ImportCommitIn(BaseModel):
    token: str = Field(min_length=1, max_length=64)


class ImportRunOut(BaseModel):
    id: str
    site_code: str
    profile_name: str
    target: ImportTarget
    file_name: str
    rows_accepted: int
    #: Already present, so nothing was written for them.
    rows_unchanged: int = 0
    rows_rejected: int
    run_at: ISTDateTime
    run_by: str = ""


class ImportRunList(BaseModel):
    items: list[ImportRunOut]
