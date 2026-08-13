"""Report PDFs.

`base` is the house style; `reports` builds each of the depot's sheets from
what the report services already returned. Callers only need `render` and the
builder for the report they are serving.
"""
from __future__ import annotations

from app.services.pdf.base import DocInfo, Story, filename, render
from app.services.pdf.reports import (
    bus_history,
    control_chart,
    dmr_day,
    dmr_month,
    investigations,
    off_road,
    unit_failures,
)

__all__ = [
    "DocInfo",
    "Story",
    "bus_history",
    "control_chart",
    "dmr_day",
    "dmr_month",
    "filename",
    "investigations",
    "off_road",
    "render",
    "unit_failures",
]
