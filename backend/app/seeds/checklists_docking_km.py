"""Docking (P.M) checklists — one sheet per bus type × KM rung.

Built from the depot's maintenance-schedule PDFs (9M and 12M folders). D.I and
10 DAYS SERVICE are not in this module. Existing null-`milestone_km` P.M
templates from v2/v3 remain as fallbacks for buses booked without a rung.
"""
from __future__ import annotations

from typing import Any

from app.seeds.checklists_docking_km_data import DOCKING_KM_ITEMS
from app.seeds.docking_km import format_milestone_km

CHECKLISTS: list[dict[str, Any]] = []
for (variant, km), items in sorted(
    DOCKING_KM_ITEMS.items(), key=lambda x: (x[0][0], x[0][1])
):
    CHECKLISTS.append(
        {
            "work_type_code": "P.M",
            "variant": variant,
            "milestone_km": km,
            "name": f"Docking — {variant} @ {format_milestone_km(km)}",
            "category": "bus",
            "items": items,
        }
    )
