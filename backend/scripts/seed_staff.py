"""Create a site's staff accounts from the names on its own snag report.

The people are already named on the sheet — floor supervisors in
"SUPERVISOR (FLOOR)" and mechanics in "ATTEND BY" — so the roster comes from
real operating data rather than invented placeholders.

    python -m scripts.seed_staff MBMT /srv/data/MBMT/August/SNAG*.xlsx

Every account is created with `must_reset_password` set and a generated
password printed once here; a super admin can also set or reset a password for
any of them from Admin → Users. The site must already exist.
"""
from __future__ import annotations

import asyncio
import re
import sys

from sqlalchemy import func, select

from app.db import SessionLocal
from app.models.enums import Role
from app.models.master import Site
from app.models.user import User, UserSiteAccess
from app.security import generate_temp_password, hash_password
from app.services.spreadsheet import read_sheet

SUPERVISOR_COLUMN = "SUPERVISOR (FLOOR)"
MECHANIC_COLUMN = "ATTEND BY"

#: Not people: contractor crews and placeholders that appear in the same column.
NOT_A_PERSON = {
    "N/A",
    "NA",
    "NIL",
    "NONE",
    "-",
    "EKA TEAM",
    "JTAC TEAM",
    "J.K TYRE TEAM",
    "JTAC",
}


def split_names(cell: str) -> list[str]:
    """One cell may hold a whole crew: "NANDRAJ/VILAS/ABHISHEK\\n/SANKET"."""
    text = re.sub(r"\s+", " ", cell or "").strip()
    if not text or text.upper() in NOT_A_PERSON:
        return []
    out: list[str] = []
    for part in re.split(r"[/,&+]", text):
        name = re.sub(r"\s+", " ", part).strip().upper()
        if not name or name in NOT_A_PERSON or len(name) < 2:
            continue
        if name not in out:
            out.append(name)
    return out


def handle_for(name: str) -> str:
    """A login handle from the name, until real employee numbers are loaded."""
    return re.sub(r"[^A-Z0-9.]+", ".", name.upper()).strip(".")[:64]


def title(name: str) -> str:
    return " ".join(part.capitalize() for part in name.split())


def read_people(path: str) -> tuple[list[str], list[str]]:
    with open(path, "rb") as handle:
        sheet = read_sheet(file_name=path, data=handle.read(), header_row=1)

    missing = [
        c for c in (SUPERVISOR_COLUMN, MECHANIC_COLUMN) if c not in sheet.columns
    ]
    if missing:
        sys.exit(f"Sheet has no {' or '.join(missing)} column")

    supervisors: list[str] = []
    mechanics: list[str] = []
    for row in sheet.rows:
        for name in split_names(row.get(SUPERVISOR_COLUMN)):
            if name not in supervisors:
                supervisors.append(name)
        for name in split_names(row.get(MECHANIC_COLUMN)):
            if name not in mechanics:
                mechanics.append(name)

    # A floor supervisor who also turns a spanner is a supervisor, not two
    # accounts.
    mechanics = [m for m in mechanics if m not in supervisors]
    return supervisors, mechanics


async def _create(session, name: str, role: Role, site_code: str) -> str | None:
    handle = handle_for(name)
    exists = await session.scalar(
        select(User.id).where(func.upper(User.user_id) == handle)
    )
    if exists:
        return None
    password = generate_temp_password()
    session.add(
        User(
            name=title(name),
            user_id=handle,
            role=role,
            password_hash=hash_password(password),
            must_reset_password=True,
            site_links=[UserSiteAccess(site_code=site_code)],
        )
    )
    return password


async def main(site_code: str, path: str) -> None:
    supervisors, mechanics = read_people(path)

    async with SessionLocal() as session:
        if await session.get(Site, site_code) is None:
            sys.exit(
                f"Site {site_code} does not exist — onboard it from Admin → "
                "Sites first."
            )

        print(f"{site_code}: {len(supervisors)} supervisors, "
              f"{len(mechanics)} mechanics on the sheet")
        for role, names in (
            (Role.supervisor, supervisors),
            (Role.executive, mechanics),
        ):
            for name in names:
                password = await _create(session, name, role, site_code)
                if password is None:
                    print(f"  {handle_for(name):18s} already present")
                else:
                    print(
                        f"  {handle_for(name):18s} {role.value:10s} "
                        f"password: {password}"
                    )
        await session.commit()
    print("Staff ready. Passwords are shown once — reset any of them from "
          "Admin → Users.")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit("usage: python -m scripts.seed_staff SITE_CODE PATH_TO_SHEET")
    asyncio.run(main(sys.argv[1].upper(), sys.argv[2]))
