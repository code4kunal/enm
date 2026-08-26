"""Nuclear wipe of site-scoped data — keep masters + bootstrap admin.

Preserves:
  - work_types, defect_sources, defect_types, unit_types
  - checklist *seed modules in code* (re-applied on POST /sites)
  - bootstrap super admin (BOOTSTRAP_USER_ID)

Wipes:
  - every site and everything hanging off it (vehicles, entries,
    inspections, per-site checklists, configs, imports, …)
  - non-bootstrap users and their grants/tokens

Usage:
    cd backend && .venv/bin/python -m scripts.wipe_sites --yes

Requires SEED_ON_START / scripts.seed to have already created masters + admin.
After wipe, onboard from the UI: code, name, SiteOps site, bus/truck.
"""
from __future__ import annotations

import argparse
import asyncio
import os
import sys

from sqlalchemy import text

from app.db import engine


#: Tables wiped, FK-safe order via CASCADE from sites where possible.
_TRUNCATE = """
TRUNCATE
  audit_logs,
  notifications,
  device_tokens,
  refresh_tokens,
  work_done_entries,
  coolant_entries,
  driver_complaint_entries,
  breakdown_entries,
  pm_schedule_entries,
  entries,
  fitted_units,
  off_road_cases,
  breakdown_investigations,
  dmr_days,
  inspection_results,
  inspection_entries,
  checklist_items,
  checklist_templates,
  alerts,
  inspection_slots,
  inspection_plans,
  site_import_runs,
  site_import_mappings,
  site_import_profiles,
  service_plans,
  shift_windows,
  site_configs,
  odometer_readings,
  user_site_access,
  vehicles,
  sites
RESTART IDENTITY CASCADE
"""


async def wipe(*, keep_user_id: str) -> None:
    async with engine.begin() as conn:
        await conn.execute(text(_TRUNCATE))
        # Drop every user except the bootstrap admin.
        result = await conn.execute(
            text(
                "DELETE FROM users WHERE upper(user_id) <> upper(:uid) "
                "RETURNING user_id"
            ),
            {"uid": keep_user_id},
        )
        removed = [row[0] for row in result]
    print(f"Wiped site-scoped data. Removed users: {removed or '(none)'}")
    print(f"Kept bootstrap admin: {keep_user_id}")
    print("Masters (work_types, defect_*, unit_types) untouched.")
    print("Next: Admin → Onboard site (code, name, SiteOps, bus/truck).")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--yes",
        action="store_true",
        help="Required confirmation — refuses otherwise.",
    )
    parser.add_argument(
        "--keep-user",
        default=os.environ.get("BOOTSTRAP_USER_ID", "ADMIN"),
        help="Bootstrap admin user_id to keep (default BOOTSTRAP_USER_ID / ADMIN).",
    )
    args = parser.parse_args()
    if not args.yes:
        print("Refusing: pass --yes to wipe all sites and operational data.", file=sys.stderr)
        sys.exit(2)
    asyncio.run(wipe(keep_user_id=args.keep_user))


if __name__ == "__main__":
    main()
