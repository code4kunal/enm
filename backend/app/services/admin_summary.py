"""Estate-wide Admin Summary — site-wise incident counts for super admins."""

from __future__ import annotations

from datetime import date as date_t
from datetime import timedelta

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.checklist import InspectionEntry
from app.models.entry import Entry
from app.models.enums import Register
from app.models.master import Site, Vehicle
from app.models.report import OffRoadCase
from app.models.site_config import SiteConfig
from app.models.user import User
from app.services import sites as sites_svc
from app.services.common import today_ist


def resolve_period(
    mode: str,
    *,
    date_from: date_t | None = None,
    date_to: date_t | None = None,
    month: str | None = None,
) -> tuple[date_t, date_t]:
    """Return inclusive [from, to] dates for the admin summary window."""
    today = today_ist()
    if mode == "today":
        return today, today
    if mode == "week":
        return today - timedelta(days=6), today
    if mode == "month":
        if month and len(month) >= 7:
            year, mon = int(month[:4]), int(month[5:7])
            start = date_t(year, mon, 1)
            if mon == 12:
                end = date_t(year, 12, 31)
            else:
                end = date_t(year, mon + 1, 1) - timedelta(days=1)
            return start, min(end, today) if year == today.year and mon == today.month else end
        start = today.replace(day=1)
        return start, today
    if mode == "custom":
        start = date_from or today
        end = date_to or today
        if end < start:
            start, end = end, start
        return start, end
    # Default: this month
    return today.replace(day=1), today


async def build_summary(
    session: AsyncSession,
    *,
    date_from: date_t,
    date_to: date_t,
) -> dict:
    """One payload: estate totals, per-site metrics, bus/truck groupings."""
    site_rows = list(
        (await session.scalars(select(Site).order_by(Site.code))).all()
    )
    codes = [s.code for s in site_rows]
    vehicle_counts, user_counts = await sites_svc.rollups(session, codes)

    configs = {
        row.site_code: list(row.operating_categories or ["bus"])
        for row in (
            await session.scalars(
                select(SiteConfig).where(SiteConfig.site_code.in_(codes))
            )
        ).all()
    } if codes else {}

    # Entries by site × register in the period.
    entry_counts: dict[str, dict[str, int]] = {c: {} for c in codes}
    if codes:
        rows = await session.execute(
            select(Entry.site_code, Entry.register, func.count())
            .where(
                Entry.site_code.in_(codes),
                Entry.entry_date >= date_from,
                Entry.entry_date <= date_to,
            )
            .group_by(Entry.site_code, Entry.register)
        )
        for site_code, register, n in rows.all():
            entry_counts.setdefault(site_code, {})[register.value] = int(n)

    # Inspections completed in the period.
    insp_counts: dict[str, int] = dict.fromkeys(codes, 0)
    if codes:
        rows = await session.execute(
            select(InspectionEntry.site_code, func.count())
            .where(
                InspectionEntry.site_code.in_(codes),
                InspectionEntry.inspected_on >= date_from,
                InspectionEntry.inspected_on <= date_to,
            )
            .group_by(InspectionEntry.site_code)
        )
        for site_code, n in rows.all():
            insp_counts[site_code] = int(n)

    # Open off-road cases (point-in-time, still down).
    off_counts: dict[str, int] = dict.fromkeys(codes, 0)
    if codes:
        rows = await session.execute(
            select(OffRoadCase.site_code, func.count())
            .where(
                OffRoadCase.site_code.in_(codes),
                OffRoadCase.returned_on.is_(None),
            )
            .group_by(OffRoadCase.site_code)
        )
        for site_code, n in rows.all():
            off_counts[site_code] = int(n)

    sites_out: list[dict] = []
    totals = {
        "work_done": 0,
        "driver_complaints": 0,
        "breakdowns": 0,
        "coolant": 0,
        "inspections": 0,
        "open_off_road": 0,
    }
    for site in site_rows:
        by_reg = entry_counts.get(site.code, {})
        metrics = {
            "work_done": by_reg.get(Register.work_done.value, 0),
            "driver_complaints": by_reg.get(Register.driver_complaint.value, 0),
            "breakdowns": by_reg.get(Register.breakdown.value, 0),
            "coolant": by_reg.get(Register.coolant.value, 0),
            "inspections": insp_counts.get(site.code, 0),
            "open_off_road": off_counts.get(site.code, 0),
        }
        for k, v in metrics.items():
            totals[k] += v
        categories = configs.get(site.code) or ["bus"]
        sites_out.append(
            {
                "site_code": site.code,
                "name": site.name,
                "is_active": site.is_active,
                "operating_categories": categories,
                "vehicle_count": vehicle_counts.get(site.code, 0),
                "user_count": user_counts.get(site.code, 0),
                **metrics,
            }
        )

    active_sites = sum(1 for s in site_rows if s.is_active)
    total_vehicles = await session.scalar(
        select(func.count()).select_from(Vehicle).where(Vehicle.is_active.is_(True))
    )
    total_users = await session.scalar(
        select(func.count()).select_from(User).where(User.is_active.is_(True))
    )

    bus_sites = [
        s for s in sites_out if "bus" in (s["operating_categories"] or [])
    ]
    truck_sites = [
        s for s in sites_out if "truck" in (s["operating_categories"] or [])
    ]

    def _segment_totals(rows: list[dict]) -> dict:
        keys = (
            "work_done",
            "driver_complaints",
            "breakdowns",
            "coolant",
            "inspections",
            "open_off_road",
        )
        out = {k: sum(int(r[k]) for r in rows) for k in keys}
        out["site_count"] = len(rows)
        return out

    return {
        "date_from": date_from,
        "date_to": date_to,
        "estate": {
            "sites": len(site_rows),
            "active_sites": active_sites,
            "vehicles": int(total_vehicles or 0),
            "users": int(total_users or 0),
            **totals,
        },
        "sites": sites_out,
        "segments": {
            "bus": {"label": "Bus Services", "totals": _segment_totals(bus_sites), "sites": bus_sites},
            "truck": {
                "label": "Truck Services",
                "totals": _segment_totals(truck_sites),
                "sites": truck_sites,
            },
        },
    }