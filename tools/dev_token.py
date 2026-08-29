#!/usr/bin/env python3
"""Mint a siteops-platform-shaped token, for testing E&M without the platform.

Development only. It signs with `SITEOPS_JWT_SECRET` from `backend/.env` —
the same key the platform signs with — so the API accepts the result exactly
as it would a real sign-in. That is the point: you can test that a permission
gates what it should without waiting for somebody to build a role first.

    python tools/dev_token.py --user test.mechanic \\
        --perm em_entry:read --perm em_entry:write \\
        --site 4f13262d-a2ac-41d0-972e-88c0fc965a24

    # everything, the way a platform `admin` arrives:
    python tools/dev_token.py --user boss --admin

Then:

    TOKEN=$(python tools/dev_token.py --user test.mechanic --perm em_entry:read)
    curl -H "Authorization: Bearer $TOKEN" localhost:8123/api/v1/auth/me

A site id only reaches a site if some E&M site carries it in
`sites.siteops_site_id`; an unlinked site 403s, which is the correct answer
and the first thing to check when a real user says they cannot see their
depot.
"""

from __future__ import annotations

import argparse
import re
import sys
import uuid
from datetime import UTC, datetime, timedelta
from pathlib import Path

try:
    import jwt
except ModuleNotFoundError:  # pragma: no cover - a dev machine without PyJWT
    sys.exit("PyJWT is not installed. `pip install pyjwt`, or run this in the API image.")

ENV = Path(__file__).resolve().parent.parent / "backend" / ".env"


def secret() -> str:
    if not ENV.exists():
        sys.exit(f"{ENV} not found — cannot sign without the platform's secret.")
    match = re.search(
        r"^SITEOPS_JWT_SECRET=(.+)$", ENV.read_text(encoding="utf-8"), re.MULTILINE
    )
    if not match or not match.group(1).strip():
        sys.exit("SITEOPS_JWT_SECRET is not set in backend/.env.")
    return match.group(1).strip()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--user", default="test.mechanic", help="username claim")
    parser.add_argument("--sub", default=None, help="platform user id (default: random)")
    parser.add_argument(
        "--perm",
        action="append",
        default=[],
        metavar="em_entry:read",
        help="repeatable; the permissions the token carries",
    )
    parser.add_argument(
        "--site",
        action="append",
        default=[],
        metavar="UUID",
        help="repeatable; platform site ids, matched against sites.siteops_site_id",
    )
    parser.add_argument(
        "--role", action="append", default=[], help="repeatable role names"
    )
    parser.add_argument(
        "--admin",
        action="store_true",
        help="arrive as a platform admin, which bypasses every permission check",
    )
    parser.add_argument("--hours", type=int, default=8, help="lifetime, default 8h")
    args = parser.parse_args()

    roles = list(args.role) or (["admin"] if args.admin else ["Maintenance"])
    if args.admin and "admin" not in roles:
        roles.append("admin")

    payload = {
        "sub": args.sub or str(uuid.uuid4()),
        "user_name": args.user,
        "employee_code": "DEV-000",
        "roles": roles,
        "permissions": args.perm,
        "site_ids": args.site,
        "project_ids": [],
        "security_stamp": "dev",
        "type": "access",
        "exp": datetime.now(UTC) + timedelta(hours=args.hours),
        "jti": str(uuid.uuid4()),
    }
    print(jwt.encode(payload, secret(), algorithm="HS256"))


if __name__ == "__main__":
    main()
