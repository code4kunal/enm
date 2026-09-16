"""Docking (P.M) KM ladder shared by seed, catalogue and the checklist UI.

Only P.M uses these. D.I and 10 DAYS SERVICE stay variant-only (no KM).
"""
from __future__ import annotations

#: Odometer marks that have their own docking sheet — matches the depot PDF
#: folders (3k, then every 10k through 1.20 lakh).
DOCKING_MILESTONE_KM: tuple[int, ...] = (
    3_000,
    10_000,
    20_000,
    30_000,
    40_000,
    50_000,
    60_000,
    70_000,
    80_000,
    90_000,
    100_000,
    110_000,
    120_000,
)

DOCKING_VARIANTS: tuple[str, ...] = ("9M", "12M AC", "12M Non-AC")

#: Work type code for docking — never D.I or 10 DAYS SERVICE.
DOCKING_WORK_TYPE = "P.M"


def format_milestone_km(km: int) -> str:
    if km >= 100_000:
        return f"{km / 100_000:.2f}".rstrip("0").rstrip(".") + " lakh"
    return f"{km // 1000}k"
