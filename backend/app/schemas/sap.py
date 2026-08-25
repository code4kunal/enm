from __future__ import annotations

from pydantic import BaseModel


class SapSyncOut(BaseModel):
    equipment_matched: int
    materials_synced: int
    flocs_matched: int
    synced_at: str


class SapMaterialOut(BaseModel):
    sap_material_no: str
    description: str
    uom: str


class SapMaterialList(BaseModel):
    items: list[SapMaterialOut]
