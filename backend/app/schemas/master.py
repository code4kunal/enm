from __future__ import annotations

from pydantic import BaseModel


class DepotOut(BaseModel):
    code: str
    name: str


class BusOut(BaseModel):
    bus_no: str
    depot: str
    is_active: bool


class DepotList(BaseModel):
    items: list[DepotOut]


class BusList(BaseModel):
    items: list[BusOut]


class StringList(BaseModel):
    items: list[str]
