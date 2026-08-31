# SiteOps User Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make SiteOps the source of truth for user administration on SiteOps-linked sites — E&M mirrors users in via a nightly + on-demand sync and stops allowing local edits to platform-managed accounts, while unlinked sites and the break-glass admin keep working exactly as today.

**Architecture:** A new `user_sync.py` service mirrors the existing `masters.sync_vehicles_from_siteops` overwrite pattern: pull `siteops.list_site_users()`, `ensure_user()` a shadow row per person, mirror `is_active`, map a display-only role, and reconcile `UserSiteAccess` for platform-managed users to exactly match the roster. `admin.py`'s write endpoints reject edits to any user whose `password_hash IS NULL` (the existing, already-used signal for "this is a platform shadow row"). A pre-existing gap in `ensure_user`'s handle-based adoption — which silently kept a local password alive on an adopted row — is closed with a new `source` parameter.

**Tech Stack:** FastAPI, SQLAlchemy 2.0 async, Alembic, APScheduler, pytest + httpx `AsyncClient`, Flutter/Riverpod.

**Spec:** `docs/superpowers/specs/2026-08-31-siteops-user-sync-design.md`

## Global Constraints

- "Platform-managed" is decided by **`password_hash IS NULL` alone** — not additionally gated on having a `UserSiteAccess` row to a linked site. (The spec's phrasing mentioned both; the linked-site qualifier is dropped here because a platform user can legitimately have zero `UserSiteAccess` rows before their first sync ever runs, which would make that qualifier toothless exactly when it matters most. `password_hash IS NULL` is already a complete signal — every row that has it was created by `platform_identity.ensure_user`, never any other path.)
- The sync is per-site and **overwrite-based**, matching `masters.sync_vehicles_from_siteops` exactly — never append-only.
- The synced `role` column is a **display label only**. Real authorization continues to come from live per-request token claims (`user.attach_claims`) — nothing in this plan touches that path.
- The bootstrap break-glass account always has `password_hash` set and is therefore never touched by the guard or the sync.
- Alembic revision for this plan is `0018`, `down_revision = "0017"`.
- Every new/changed backend function gets a docstring only where the *why* isn't obvious from the code — match the terse, no-restating-the-obvious style already in this codebase (see `masters.py`, `platform_identity.py`).

---

### Task 1: Alembic migration + `Site` model columns

**Files:**
- Create: `backend/alembic/versions/0018_siteops_user_sync_columns.py`
- Modify: `backend/app/models/master.py:56-63`
- Test: `backend/tests/test_fleet_sync.py` (no new test file — this task is verified by the migration actually applying; Task 4's tests exercise the new columns)

**Interfaces:**
- Produces: `Site.last_siteops_user_sync_at: datetime | None`, `Site.last_siteops_user_sync_result: dict | None` — consumed by Task 4 (`user_sync.py`) and Task 5 (the sync endpoint).

- [ ] **Step 1: Add the two columns to the `Site` model**

In `backend/app/models/master.py`, right after the existing `last_siteops_sync_result` line (line 59):

```python
    last_siteops_sync_result: Mapped[dict | None] = mapped_column(JSON, nullable=True)
    last_siteops_user_sync_at: Mapped[datetime | None] = mapped_column(
        TZDateTime, nullable=True
    )
    last_siteops_user_sync_result: Mapped[dict | None] = mapped_column(
        JSON, nullable=True
    )
    created_at: Mapped[datetime] = created_at_col()
```

(`JSON` and `TZDateTime` are already imported at the top of this file — no import changes needed.)

- [ ] **Step 2: Write the migration**

Create `backend/alembic/versions/0018_siteops_user_sync_columns.py`:

```python
"""siteops user sync bookkeeping on sites

Revision ID: 0018
Revises: 0017
Create Date: 2026-08-31

Mirrors the existing `last_siteops_sync_at`/`last_siteops_sync_result` pair
used for fleet sync, but for the new user-sync stream — kept as separate
columns since they track a distinct sync run, not the same one.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0018"
down_revision = "0017"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "sites",
        sa.Column("last_siteops_user_sync_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column(
        "sites", sa.Column("last_siteops_user_sync_result", sa.JSON(), nullable=True)
    )


def downgrade() -> None:
    op.drop_column("sites", "last_siteops_user_sync_result")
    op.drop_column("sites", "last_siteops_user_sync_at")
```

- [ ] **Step 3: Apply the migration against the local test/dev database**

Run: `cd backend && docker compose exec api alembic upgrade head`
Expected: output ends with `Running upgrade 0017 -> 0018, siteops user sync bookkeeping on sites`

- [ ] **Step 4: Verify the columns exist**

Run: `docker exec enm_db psql -U enm -d enm -c "\d sites"` (or `enm_test` if testing against the test DB)
Expected: `last_siteops_user_sync_at` and `last_siteops_user_sync_result` appear in the column list.

- [ ] **Step 5: Commit**

```bash
git add backend/alembic/versions/0018_siteops_user_sync_columns.py backend/app/models/master.py
git commit -m "Add sites.last_siteops_user_sync_at/_result columns"
```

---

### Task 2: `siteops.list_site_users` gains an `is_active` filter

**Files:**
- Modify: `backend/app/services/siteops.py:168-188`
- Test: `backend/tests/test_platform_login.py` (add one test to this file — it already covers `siteops.py` mocking patterns and is the natural home for a `siteops.py`-level unit test)

**Interfaces:**
- Produces: `siteops.list_site_users(site_id: str, is_active: bool | None = True) -> list[dict[str, Any]]` — consumed by Task 4 (`user_sync.py`, calling with `is_active=None`) and unchanged for the existing caller in `master.py:108` (calls with no `is_active` arg, defaults to `True`, identical behavior to today).

- [ ] **Step 1: Write the failing test**

Add to `backend/tests/test_platform_login.py` (append at the end of the file):

```python
async def test_list_site_users_default_filters_active_only(monkeypatch) -> None:
    """Unchanged default — the staff dropdown must keep seeing only actives."""
    seen_params: list[dict] = []

    async def fake_get(path: str, params: dict, *, missing_ok: bool = False):
        seen_params.append(params)
        return {"data": []}

    monkeypatch.setattr(siteops, "_get", fake_get)
    await siteops.list_site_users("some-site-id")
    assert seen_params[0]["is_active"] == "true"


async def test_list_site_users_none_omits_the_filter(monkeypatch) -> None:
    """The sync job needs deactivated SiteOps users too, to mirror the flip."""
    seen_params: list[dict] = []

    async def fake_get(path: str, params: dict, *, missing_ok: bool = False):
        seen_params.append(params)
        return {"data": []}

    monkeypatch.setattr(siteops, "_get", fake_get)
    await siteops.list_site_users("some-site-id", is_active=None)
    assert "is_active" not in seen_params[0]
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd backend && pytest tests/test_platform_login.py -k "list_site_users" -v`
Expected: `FAIL` — `list_site_users() got an unexpected keyword argument 'is_active'` (the second test) and the first test currently passes trivially (it's asserting today's hardcoded behavior) but re-run both together to confirm the signature error surfaces.

- [ ] **Step 3: Implement**

Replace `list_site_users` in `backend/app/services/siteops.py:168-188`:

```python
async def list_site_users(
    site_id: str, is_active: bool | None = True
) -> list[dict[str, Any]]:
    """Every platform user assigned to one site.

    What the "reported by" and "supervisor" dropdowns are built from now that
    people are staffed in the platform rather than in E&M: a mechanic who has
    never opened E&M still has to be nameable on somebody else's entry.

    `is_active=None` drops the filter — the user sync needs deactivated
    SiteOps accounts too, to mirror a deactivation into E&M; the dropdown
    caller keeps the default (`True`) so a departed mechanic stops appearing
    there unchanged.
    """
    params = {"site_id": site_id, "pagination": "false"}
    if is_active is not None:
        params["is_active"] = "true" if is_active else "false"
    body = await _get("/users/", params)
    if isinstance(body, list):
        return [r for r in body if isinstance(r, dict)]
    if not isinstance(body, dict):
        return []
    data = body.get("data")
    if isinstance(data, list):
        return [r for r in data if isinstance(r, dict)]
    if isinstance(data, dict) and isinstance(data.get("items"), list):
        return [r for r in data["items"] if isinstance(r, dict)]
    return []
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd backend && pytest tests/test_platform_login.py -k "list_site_users" -v`
Expected: `2 passed`

- [ ] **Step 5: Run the full test file to check nothing else broke**

Run: `cd backend && pytest tests/test_platform_login.py -v`
Expected: all pass (no regressions in the login/refresh tests).

- [ ] **Step 6: Commit**

```bash
git add backend/app/services/siteops.py backend/tests/test_platform_login.py
git commit -m "siteops.list_site_users: allow fetching inactive users too"
```

---

### Task 3: `ensure_user` gains `source`, closing the adoption gap

**Files:**
- Modify: `backend/app/services/platform_identity.py:30-72`
- Modify: `backend/app/api/master.py:119-125` (pass `source="sync"`)
- Create: `backend/tests/test_platform_identity.py`

**Interfaces:**
- Consumes: nothing new.
- Produces: `platform_identity.ensure_user(session, *, sub, user_name, name=None, email=None, source: Literal["login", "sync"] = "login") -> User` — consumed by Task 4 (`user_sync.py`, calling with `source="sync"`). Existing callers (`auth.py:158`, `deps.py:49`) are unchanged (they omit `source`, so it defaults to `"login"` — identical behavior to before this task).

- [ ] **Step 1: Write the failing tests**

Create `backend/tests/test_platform_identity.py`:

```python
"""platform_identity.ensure_user: shadow rows, adoption, and the sync-source fix.

A depot that signed in locally before the SiteOps integration keeps its
account when SiteOps later reports the same handle — `ensure_user` adopts it
by matching `user_id`. A live login (`source="login"`) already proved the
password belongs to that person, so it's left alone. A background sync or
staff-list fetch (`source="sync"`) has proved no such thing — SiteOps is
simply reporting a handle — so adopting there must also convert the row to
platform-managed (clear the password) or it stays silently editable through
E&M's local admin surface forever, defeating the whole migration for that
one account.
"""
from __future__ import annotations

import uuid

from app.db import SessionLocal
from app.models.enums import Role
from app.models.user import User
from app.security import hash_password
from app.services import platform_identity
from tests.conftest import PASSWORD


async def test_login_source_adopts_without_clearing_password() -> None:
    async with SessionLocal() as session:
        session.add(
            User(
                id="localacct0001",
                name="Pre-integration",
                user_id="PREINT",
                role=Role.executive,
                password_hash=hash_password(PASSWORD),
            )
        )
        await session.commit()

        user = await platform_identity.ensure_user(
            session, sub=str(uuid.uuid4()), user_name="preint", source="login"
        )
        assert user.id == "localacct0001"
        assert user.password_hash is not None


async def test_sync_source_clears_password_on_adoption() -> None:
    async with SessionLocal() as session:
        session.add(
            User(
                id="localacct0002",
                name="Pre-integration",
                user_id="PREINT2",
                role=Role.executive,
                password_hash=hash_password(PASSWORD),
                must_reset_password=True,
            )
        )
        await session.commit()

        user = await platform_identity.ensure_user(
            session, sub=str(uuid.uuid4()), user_name="preint2", source="sync"
        )
        assert user.id == "localacct0002"
        assert user.password_hash is None
        assert user.must_reset_password is False


async def test_sync_source_leaves_a_fresh_shadow_row_untouched() -> None:
    async with SessionLocal() as session:
        user = await platform_identity.ensure_user(
            session, sub=str(uuid.uuid4()), user_name="brandnew", source="sync"
        )
        assert user.password_hash is None
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd backend && pytest tests/test_platform_identity.py -v`
Expected: `FAIL` — `ensure_user() got an unexpected keyword argument 'source'`

- [ ] **Step 3: Implement the `source` parameter and adoption fix**

Replace `ensure_user` in `backend/app/services/platform_identity.py:30-72`:

```python
from typing import Literal
```

Add that import at the top of the file (alongside the existing imports), then replace the function:

```python
async def ensure_user(
    session: AsyncSession,
    *,
    sub: str,
    user_name: str,
    name: str | None = None,
    email: str | None = None,
    source: Literal["login", "sync"] = "login",
) -> User:
    """Find or create the shadow row for a platform identity.

    `source="sync"` marks a background reconciliation (the user sync, or the
    staff-list dropdown fetch) rather than a live sign-in. If it adopts a
    pre-existing local-password account by handle, that account is converted
    to platform-managed (password cleared) — a live login already proved the
    password belongs to this person, so `source="login"` leaves it alone.
    """
    handle = (user_name or sub).strip().upper()
    user = await session.get(User, local_id(sub))

    if user is None and user_name:
        # Adopt the local account of the same handle. A depot that signed in
        # as TV4021 before the integration keeps its entries, its audit trail
        # and its authorship instead of starting a second identity.
        user = await session.scalar(select(User).where(User.user_id == handle))

    if user is not None:
        if source == "sync" and user.password_hash is not None:
            user.password_hash = None
            user.must_reset_password = False
            await session.flush()
        return user

    # `users.email` is unique. A platform account whose address already
    # belongs to some other E&M row is still a real person who needs to sign
    # in, so the shadow row goes without the address rather than 500ing on
    # the constraint.
    address = (email or "").strip().lower() or None
    if address and await session.scalar(select(User.id).where(User.email == address)):
        address = None

    user = User(
        id=local_id(sub),
        name=(name or user_name or sub).strip(),
        user_id=handle,
        email=address,
        role=Role.executive,
        password_hash=None,
        must_reset_password=False,
    )
    session.add(user)
    await session.commit()
    return await session.scalar(
        select(User).where(User.id == user.id).options(selectinload(User.site_links))
    )
```

- [ ] **Step 4: Update `master.py`'s call site to pass `source="sync"`**

In `backend/app/api/master.py:119-125`, the `_platform_staff` call to `ensure_user` (a background staff-list fetch, not a live login) becomes:

```python
        person = await platform_identity.ensure_user(
            session,
            sub=sub,
            user_name=username,
            name=str(row.get("full_name") or "") or None,
            email=str(row.get("email") or "") or None,
            source="sync",
        )
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd backend && pytest tests/test_platform_identity.py -v`
Expected: `3 passed`

- [ ] **Step 6: Run the full backend suite to check nothing else broke**

Run: `cd backend && pytest -q`
Expected: all pass (`auth.py:158` and `deps.py:49` still call `ensure_user` without `source`, defaulting to `"login"` — identical to prior behavior).

- [ ] **Step 7: Commit**

```bash
git add backend/app/services/platform_identity.py backend/app/api/master.py backend/tests/test_platform_identity.py
git commit -m "Close ensure_user's adoption gap: sync-sourced adoption clears the local password"
```

---

### Task 4: `AuditAction.users_synced_from_siteops` and `UserOut.is_platform_managed`

**Files:**
- Modify: `backend/app/models/enums.py:152-186`
- Modify: `backend/app/schemas/user.py:9-28`
- Modify: `backend/app/api/admin.py:31-45` (the `_out` helper)
- Test: `backend/tests/test_admin.py`

**Interfaces:**
- Produces: `AuditAction.users_synced_from_siteops` (consumed by Task 5), `UserOut.is_platform_managed: bool` (consumed by Flutter Task 9/10).

- [ ] **Step 1: Write the failing test**

Add to `backend/tests/test_admin.py`:

```python
async def test_list_users_reports_platform_managed_flag(client: AsyncClient) -> None:
    from app.db import SessionLocal
    from app.models.enums import Role
    from app.models.user import User

    async with SessionLocal() as session:
        session.add(
            User(
                id="platmgd00001",
                name="Platform Person",
                user_id="PLATPERSON",
                role=Role.executive,
                password_hash=None,
            )
        )
        await session.commit()

    h = await auth_headers(client)
    r = await client.get("/admin/users", params={"q": "PLATPERSON"}, headers=h)
    item = r.json()["items"][0]
    assert item["is_platform_managed"] is True

    local = (
        await client.get("/admin/users", params={"q": "TV4105"}, headers=h)
    ).json()["items"][0]
    assert local["is_platform_managed"] is False
```

Add the missing import at the top of the file if not already present:

```python
from httpx import AsyncClient

from tests.conftest import PASSWORD, SUPER_ADMIN, auth_headers
```

(These are already imported in `test_admin.py:3-5` — no change needed there, just confirming.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd backend && pytest tests/test_admin.py -k platform_managed_flag -v`
Expected: `FAIL` — `KeyError: 'is_platform_managed'`

- [ ] **Step 3: Add the enum member**

In `backend/app/models/enums.py`, add to the `AuditAction` enum right after `fleet_synced_from_siteops` (line 184):

```python
    fleet_synced_from_siteops = "fleet_synced_from_siteops"
    users_synced_from_siteops = "users_synced_from_siteops"
    site_siteops_linked = "site_siteops_linked"
```

- [ ] **Step 4: Add the schema field**

In `backend/app/schemas/user.py`, add to `UserOut` right after `governs_all_sites` (line 19):

```python
    governs_all_sites: bool = False
    #: True for any shadow row `ensure_user` created or adopted — password is
    #: null by construction. E&M's write endpoints reject edits to these; the
    #: account is administered in SiteOps.
    is_platform_managed: bool = False
```

- [ ] **Step 5: Populate it in `admin.py`'s `_out` helper**

In `backend/app/api/admin.py:31-45`:

```python
def _out(user: User) -> UserOut:
    return UserOut(
        id=user.id,
        name=user.name,
        user_id=user.user_id,
        email=user.email,
        role=user.role,
        site_access=user.site_access,
        governs_all_sites=user.is_super_admin,
        permissions=sorted(user.permissions),
        is_active=user.is_active,
        must_reset_password=user.must_reset_password,
        is_platform_managed=user.password_hash is None,
        created_at=user.created_at,
        last_login_at=user.last_login_at,
    )
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `cd backend && pytest tests/test_admin.py -k platform_managed_flag -v`
Expected: `1 passed`

- [ ] **Step 7: Run the full admin test file**

Run: `cd backend && pytest tests/test_admin.py -v`
Expected: all pass.

- [ ] **Step 8: Commit**

```bash
git add backend/app/models/enums.py backend/app/schemas/user.py backend/app/api/admin.py backend/tests/test_admin.py
git commit -m "Add AuditAction.users_synced_from_siteops and UserOut.is_platform_managed"
```

---

### Task 5: `user_sync.py` service

**Files:**
- Create: `backend/app/services/user_sync.py`
- Create: `backend/tests/test_user_sync.py`

**Interfaces:**
- Consumes: `siteops.list_site_users(site_id, is_active=None)` (Task 2), `siteops.user_grants(user_id)` (existing), `platform_identity.ensure_user(..., source="sync")` (Task 3).
- Produces: `UserSyncResult` dataclass (`.synced`, `.adopted`, `.reactivated`, `.deactivated`, `.as_dict()`), `sync_users_from_siteops(session, site_code, siteops_site_id) -> UserSyncResult` (consumed by Task 6's endpoint), `sync_all_users_from_siteops() -> list[dict]` (consumed by Task 7's scheduler job).

- [ ] **Step 1: Write the failing tests**

Create `backend/tests/test_user_sync.py`:

```python
"""user_sync.sync_users_from_siteops: the overwrite semantics that make
SiteOps the source of truth for a linked site's roster.
"""
from __future__ import annotations

from sqlalchemy import select

from app.db import SessionLocal
from app.models.enums import Role
from app.models.user import User, UserSiteAccess
from app.security import hash_password
from app.services import siteops, user_sync
from tests.conftest import PASSWORD


def _fake_list_site_users(rows: list[dict]):
    async def fake(site_id: str, is_active: bool | None = None) -> list[dict]:
        return rows

    return fake


def _fake_user_grants(roles: list[str]):
    async def fake(user_id: str) -> dict:
        return {"roles": roles, "permissions": []}

    return fake


ROWS = [
    {
        "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        "username": "newhand1",
        "full_name": "New Hand One",
        "email": "newhand1@transvolt.in",
        "is_active": True,
    },
    {
        "id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
        "username": "newhand2",
        "full_name": "New Hand Two",
        "email": "newhand2@transvolt.in",
        "is_active": False,
    },
]


async def test_sync_creates_shadow_rows_and_site_access(monkeypatch) -> None:
    monkeypatch.setattr(siteops, "list_site_users", _fake_list_site_users(ROWS))
    monkeypatch.setattr(siteops, "user_grants", _fake_user_grants(["Manager"]))

    async with SessionLocal() as session:
        result = await user_sync.sync_users_from_siteops(
            session, "MBMT", "siteops-uuid-1"
        )
        await session.commit()

    assert result.synced == 2
    assert result.adopted == 0

    async with SessionLocal() as session:
        active = await session.scalar(
            select(User).where(User.user_id == "NEWHAND1")
        )
        inactive = await session.scalar(
            select(User).where(User.user_id == "NEWHAND2")
        )
        assert active.is_active is True
        assert active.role is Role.manager
        assert "MBMT" in active.site_access
        assert inactive.is_active is False
        # A deactivated SiteOps user is not staffed on the site.
        assert "MBMT" not in inactive.site_access


async def test_sync_adopts_a_pre_existing_local_account_and_clears_its_password(
    monkeypatch,
) -> None:
    async with SessionLocal() as session:
        session.add(
            User(
                id="localacct0003",
                name="Pre-integration Person",
                user_id="NEWHAND1",
                role=Role.executive,
                password_hash=hash_password(PASSWORD),
            )
        )
        await session.commit()

    monkeypatch.setattr(siteops, "list_site_users", _fake_list_site_users(ROWS[:1]))
    monkeypatch.setattr(siteops, "user_grants", _fake_user_grants(["Manager"]))

    async with SessionLocal() as session:
        result = await user_sync.sync_users_from_siteops(
            session, "MBMT", "siteops-uuid-1"
        )
        await session.commit()

    assert result.adopted == 1

    async with SessionLocal() as session:
        row = await session.get(User, "localacct0003")
        assert row.password_hash is None


async def test_sync_removes_site_access_for_a_user_no_longer_on_the_roster(
    monkeypatch,
) -> None:
    monkeypatch.setattr(siteops, "list_site_users", _fake_list_site_users(ROWS))
    monkeypatch.setattr(siteops, "user_grants", _fake_user_grants(["Manager"]))
    async with SessionLocal() as session:
        await user_sync.sync_users_from_siteops(session, "MBMT", "siteops-uuid-1")
        await session.commit()

    # Next sync: SiteOps no longer lists NEWHAND1 for this site at all.
    monkeypatch.setattr(siteops, "list_site_users", _fake_list_site_users(ROWS[1:]))
    async with SessionLocal() as session:
        result = await user_sync.sync_users_from_siteops(
            session, "MBMT", "siteops-uuid-1"
        )
        await session.commit()
    assert result.deactivated >= 1

    async with SessionLocal() as session:
        row = await session.scalar(select(User).where(User.user_id == "NEWHAND1"))
        assert "MBMT" not in row.site_access


async def test_sync_reactivates_a_user_siteops_marks_active_again(
    monkeypatch,
) -> None:
    monkeypatch.setattr(siteops, "list_site_users", _fake_list_site_users(ROWS))
    monkeypatch.setattr(siteops, "user_grants", _fake_user_grants(["Manager"]))
    async with SessionLocal() as session:
        await user_sync.sync_users_from_siteops(session, "MBMT", "siteops-uuid-1")
        await session.commit()

    reactivated_row = dict(ROWS[1])
    reactivated_row["is_active"] = True
    monkeypatch.setattr(
        siteops, "list_site_users", _fake_list_site_users([reactivated_row])
    )
    async with SessionLocal() as session:
        result = await user_sync.sync_users_from_siteops(
            session, "MBMT", "siteops-uuid-1"
        )
        await session.commit()
    assert result.reactivated == 1
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd backend && pytest tests/test_user_sync.py -v`
Expected: `FAIL` — `ModuleNotFoundError: No module named 'app.services.user_sync'`

- [ ] **Step 3: Implement `user_sync.py`**

Create `backend/app/services/user_sync.py`:

```python
from __future__ import annotations

from dataclasses import dataclass

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.enums import Role
from app.models.user import User, UserSiteAccess
from app.services import platform_identity, siteops


def _map_role(role_names: list[str]) -> Role:
    """Best-effort label only — real authorization is unaffected by this
    value (it comes from live per-request token claims). Conservative on
    purpose, matching `masters._checklist_variant_from_ac_nac`: an
    unrecognised role name leaves the display role at `executive` rather
    than guess upward.
    """
    names = {str(n).strip().lower() for n in role_names}
    if any("super" in n and "admin" in n for n in names):
        return Role.super_admin
    if any("manager" in n for n in names):
        return Role.manager
    if any("supervisor" in n for n in names):
        return Role.supervisor
    return Role.executive


@dataclass(slots=True)
class UserSyncResult:
    synced: int = 0
    #: Adopted a pre-existing local-password account by handle and converted
    #: it to platform-managed.
    adopted: int = 0
    #: Was inactive locally; SiteOps marks it active again.
    reactivated: int = 0
    #: Site access removed for a platform-managed user SiteOps no longer
    #: staffs here (deactivated, or reassigned elsewhere).
    deactivated: int = 0

    def as_dict(self) -> dict:
        return {
            "synced": self.synced,
            "adopted": self.adopted,
            "reactivated": self.reactivated,
            "deactivated": self.deactivated,
        }


async def sync_users_from_siteops(
    session: AsyncSession, site_code: str, siteops_site_id: str
) -> UserSyncResult:
    """Overwrite this site's platform-managed users from SiteOps.

    SiteOps is the source of truth for who is staffed here. Creates or
    adopts a shadow row per person, mirrors `is_active`, maps a display role,
    and reconciles `UserSiteAccess` for platform-managed users to exactly
    match the fetched roster. Local-only accounts (a `password_hash` set) and
    their site access are never touched.
    """
    rows = await siteops.list_site_users(siteops_site_id, is_active=None)

    result = UserSyncResult()
    seen_ids: set[str] = set()
    for row in rows:
        sub = str(row.get("id") or "").strip()
        username = str(row.get("username") or "").strip()
        if not sub or not username:
            continue

        handle = username.strip().upper()
        pre_existing = await session.scalar(
            select(User).where(User.user_id == handle)
        )
        was_local = pre_existing is not None and pre_existing.password_hash is not None

        grants = await siteops.user_grants(sub)
        role = _map_role((grants or {}).get("roles") or [])
        is_active = bool(row.get("is_active", True))

        person = await platform_identity.ensure_user(
            session,
            sub=sub,
            user_name=username,
            name=str(row.get("full_name") or "") or None,
            email=str(row.get("email") or "") or None,
            source="sync",
        )
        if was_local:
            result.adopted += 1
        if person.role != role:
            person.role = role
        if person.is_active != is_active:
            if is_active:
                result.reactivated += 1
            person.is_active = is_active
        if is_active and site_code not in person.site_access:
            person.site_links.append(UserSiteAccess(site_code=site_code))
        seen_ids.add(person.id)
        result.synced += 1

    # Reconcile: drop this site's access for platform-managed users SiteOps
    # no longer staffs here — deactivated, or reassigned elsewhere.
    stale = (
        await session.scalars(
            select(UserSiteAccess)
            .join(User, User.id == UserSiteAccess.user_id)
            .where(
                UserSiteAccess.site_code == site_code,
                User.password_hash.is_(None),
                UserSiteAccess.user_id.not_in(seen_ids or {"__none__"}),
            )
        )
    ).all()
    for link in stale:
        await session.delete(link)
        result.deactivated += 1

    await session.flush()
    return result


async def sync_all_users_from_siteops() -> list[dict]:
    """Nightly: refresh platform-managed users for every site linked to
    SiteOps. Per-site failures are recorded on the site row and do not abort
    the run — the same contract as `masters.sync_all_linked_sites`.
    """
    from datetime import UTC, datetime

    from app.db import SessionLocal
    from app.models.master import Site
    from app.services.siteops import SiteOpsUnavailable

    outcomes: list[dict] = []
    async with SessionLocal() as session:
        linked = list(
            (
                await session.scalars(
                    select(Site).where(Site.siteops_site_id.is_not(None))
                )
            ).all()
        )
        for site in linked:
            assert site.siteops_site_id is not None
            try:
                result = await sync_users_from_siteops(
                    session, site.code, site.siteops_site_id
                )
                payload = {**result.as_dict(), "ok": True}
            except SiteOpsUnavailable as e:
                payload = {"ok": False, "error": str(e)}
            except Exception as e:  # noqa: BLE001 — never abort the batch
                payload = {"ok": False, "error": str(e)}
            site.last_siteops_user_sync_at = datetime.now(UTC)
            site.last_siteops_user_sync_result = payload
            outcomes.append({"site_code": site.code, **payload})
        await session.commit()
    return outcomes
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd backend && pytest tests/test_user_sync.py -v`
Expected: `4 passed`

- [ ] **Step 5: Run the full backend suite**

Run: `cd backend && pytest -q`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add backend/app/services/user_sync.py backend/tests/test_user_sync.py
git commit -m "Add user_sync service: mirror SiteOps-linked sites' users into E&M"
```

---

### Task 6: manual sync endpoint `POST /sites/{code}/users/sync-from-siteops`

**Files:**
- Modify: `backend/app/schemas/site.py` (add `UserSyncOut`)
- Modify: `backend/app/api/sites.py` (add the endpoint, right after the existing fleet sync endpoint at line 359)
- Test: `backend/tests/test_user_sync.py` (append HTTP-level tests)

**Interfaces:**
- Consumes: `user_sync.sync_users_from_siteops` (Task 5), `AuditAction.users_synced_from_siteops` (Task 4).
- Produces: `POST /sites/{code}/users/sync-from-siteops` → `UserSyncOut`, consumed by Flutter Task 11's "Sync now" button.

- [ ] **Step 1: Write the failing tests**

Append to `backend/tests/test_user_sync.py`:

```python
from httpx import AsyncClient

from tests.conftest import SUPER_ADMIN, auth_headers


async def test_sync_endpoint_requires_a_linked_site(
    client: AsyncClient, monkeypatch
) -> None:
    monkeypatch.setattr(siteops, "list_site_users", _fake_list_site_users([]))
    h = await auth_headers(client, SUPER_ADMIN)
    r = await client.post("/sites/TDC/users/sync-from-siteops", headers=h)
    assert r.status_code == 409


async def test_sync_endpoint_syncs_a_linked_site(
    client: AsyncClient, monkeypatch
) -> None:
    from app.db import SessionLocal
    from app.models.master import Site

    async with SessionLocal() as session:
        site = await session.get(Site, "MBMT")
        site.siteops_site_id = "siteops-uuid-1"
        await session.commit()

    monkeypatch.setattr(siteops, "list_site_users", _fake_list_site_users(ROWS))
    monkeypatch.setattr(siteops, "user_grants", _fake_user_grants(["Manager"]))
    h = await auth_headers(client, SUPER_ADMIN)
    r = await client.post("/sites/MBMT/users/sync-from-siteops", headers=h)
    assert r.status_code == 200, r.text
    assert r.json()["synced"] == 2


async def test_sync_endpoint_is_manager_only(client: AsyncClient) -> None:
    supervisor = await auth_headers(client, "TV4102")
    r = await client.post("/sites/MBMT/users/sync-from-siteops", headers=supervisor)
    assert r.status_code == 403
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd backend && pytest tests/test_user_sync.py -k endpoint -v`
Expected: `FAIL` — `404 Not Found` (route doesn't exist yet).

- [ ] **Step 3: Add the `UserSyncOut` schema**

In `backend/app/schemas/site.py`, add near `FleetSyncOut`:

```python
class UserSyncOut(BaseModel):
    synced: int
    adopted: int
    reactivated: int = 0
    deactivated: int = 0
```

- [ ] **Step 4: Add the endpoint**

In `backend/app/api/sites.py`, add the import of `user_sync` to the existing `from app.services import (...)` block (line 35-40), and add `UserSyncOut` to the `from app.schemas.site import (...)` block (line 18-33):

```python
from app.services import (
    audit,
    checklists,
    masters,
    odometer,
    service_due,
    ...  # existing entries unchanged
    user_sync,
)
```

Then add the endpoint right after `sync_fleet_from_siteops` (after line 359):

```python
@router.post("/sites/{code}/users/sync-from-siteops", response_model=UserSyncOut)
async def sync_users_from_siteops_endpoint(
    code: str, user: CurrentUser, session: SessionDep
) -> UserSyncOut:
    """Overwrite this site's platform-managed users from SiteOps.

    Uses the site's stored `siteops_site_id`. SiteOps is the source of truth:
    creates/adopts shadow rows, mirrors active status, maps a display role,
    and reconciles site access for platform-managed users to match the
    fetched roster. Local-only accounts are never touched.
    """
    site_code = assert_site_permission(user, code, "em_user:write")
    site = await sites.load_site(session, site_code)
    if not site.siteops_site_id:
        raise Conflict(
            "site is not linked to SiteOps", {"siteops_site_id": "required"}
        )

    result = await user_sync.sync_users_from_siteops(
        session, site_code, site.siteops_site_id
    )
    sync_result = result.as_dict()
    site.last_siteops_user_sync_at = datetime.now(UTC)
    site.last_siteops_user_sync_result = sync_result
    await audit.record(
        session,
        actor_id=user.id,
        action=AuditAction.users_synced_from_siteops,
        object_type="site",
        object_id=site_code,
        after=sync_result,
    )
    await session.commit()
    return UserSyncOut(**sync_result)
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd backend && pytest tests/test_user_sync.py -v`
Expected: all pass (7 tests total in this file).

- [ ] **Step 6: Run the full backend suite**

Run: `cd backend && pytest -q`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add backend/app/schemas/site.py backend/app/api/sites.py backend/tests/test_user_sync.py
git commit -m "Add POST /sites/{code}/users/sync-from-siteops"
```

---

### Task 7: nightly scheduler registration

**Files:**
- Modify: `backend/app/main.py:14-23` (imports), `:100-112` (job registration)

**Interfaces:**
- Consumes: `user_sync.sync_all_users_from_siteops` (Task 5).

- [ ] **Step 1: Add the import**

In `backend/app/main.py`, alongside the existing `from app.services.masters import sync_all_linked_sites` (line 20):

```python
from app.services.masters import sync_all_linked_sites
from app.services.user_sync import sync_all_users_from_siteops
```

- [ ] **Step 2: Register the job**

In `backend/app/main.py`, right after the `siteops_fleet_sync` job registration (after line 112, still inside the `if scheduler and settings.schedule_generator_enabled:` block):

```python
        # Refresh platform-managed users from SiteOps for every linked site —
        # a person added or deactivated in SiteOps shows up here without a
        # manual Sync click. Runs 5m after the fleet sync so both settle
        # before anyone opens the Users pane in the morning.
        scheduler.add_job(
            sync_all_users_from_siteops,
            CronTrigger(
                hour=settings.schedule_generator_hour,
                minute=min(settings.schedule_generator_minute + 15, 59),
                timezone=settings.timezone,
            ),
            id="siteops_user_sync",
            max_instances=1,
            coalesce=True,
        )
```

- [ ] **Step 3: Verify the app still starts cleanly**

Run: `cd backend && docker compose up -d --build api && docker compose logs api --tail 40`
Expected: no tracebacks; the app reaches its normal "Uvicorn running" log line. (APScheduler doesn't log each job registration by name, so there's nothing further to grep for here — a clean startup is the signal.)

- [ ] **Step 4: Run the full backend suite**

Run: `cd backend && pytest -q`
Expected: all pass (the test suite doesn't start the real scheduler — `PLATFORM_LOGIN_ENABLED`/scheduler config is test-environment-scoped — so this step is purely a startup-safety check, not a job-firing test).

- [ ] **Step 5: Commit**

```bash
git add backend/app/main.py
git commit -m "Schedule nightly SiteOps user sync"
```

---

### Task 8: `admin.py` write guard for platform-managed users

**Files:**
- Modify: `backend/app/api/admin.py:127-131` (add helper), `:238-381` (insert guard calls)
- Test: `backend/tests/test_admin.py`

**Interfaces:**
- Consumes: `User.password_hash` (existing column).

- [ ] **Step 1: Write the failing test**

Add to `backend/tests/test_admin.py`:

```python
async def test_platform_managed_user_cannot_be_edited_locally(
    client: AsyncClient,
) -> None:
    from app.db import SessionLocal
    from app.models.enums import Role
    from app.models.user import User

    async with SessionLocal() as session:
        session.add(
            User(
                id="platmgd00002",
                name="Plat User",
                user_id="PLATUSER",
                role=Role.executive,
                password_hash=None,
            )
        )
        await session.commit()

    h = await auth_headers(client, SUPER_ADMIN)
    target = (
        await client.get("/admin/users", params={"q": "PLATUSER"}, headers=h)
    ).json()["items"][0]

    put = await client.put(
        f"/admin/users/{target['id']}", json={"name": "Renamed"}, headers=h
    )
    assert put.status_code == 409

    deactivate = await client.post(
        f"/admin/users/{target['id']}/deactivate", headers=h
    )
    assert deactivate.status_code == 409

    activate = await client.post(f"/admin/users/{target['id']}/activate", headers=h)
    assert activate.status_code == 409

    reset = await client.post(
        f"/admin/users/{target['id']}/reset-password", headers=h
    )
    assert reset.status_code == 409
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd backend && pytest tests/test_admin.py -k platform_managed_user_cannot -v`
Expected: `FAIL` — all four assertions fail (each currently returns 200).

- [ ] **Step 3: Add the guard helper**

In `backend/app/api/admin.py`, right after the existing `_load` helper (line 127-131):

```python
async def _load(session: SessionDep, user_id: str) -> User:
    user = await session.get(User, user_id)
    if user is None:
        raise NotFound("User not found")
    return user


def _assert_platform_editable(user: User) -> None:
    """SiteOps owns any shadow row it created — `password_hash is None` is a
    complete signal for that, set only by `ensure_user`. Only a local account
    (the break-glass admin, or one predating the integration) may be edited
    here."""
    if user.password_hash is None:
        raise Conflict(
            "Managed by SiteOps — edit there.", {"user_id": "platform-managed"}
        )
```

- [ ] **Step 4: Call the guard in the four write endpoints**

In `update_user` (`admin.py:238-242`), right after `_load`:

```python
async def update_user(
    user_id: str, payload: UserUpdate, actor: ManagerUser, session: SessionDep
) -> UserOut:
    user = await _load(session, user_id)
    _assert_platform_editable(user)
    before = {
```

In `deactivate_user` (`admin.py:302-306`):

```python
async def deactivate_user(
    user_id: str, actor: ManagerUser, session: SessionDep
) -> UserOut:
    user = await _load(session, user_id)
    _assert_platform_editable(user)
    if user.id == actor.id:
```

In `activate_user` (`admin.py:329-334`):

```python
async def activate_user(
    user_id: str, actor: ManagerUser, session: SessionDep
) -> UserOut:
    user = await _load(session, user_id)
    _assert_platform_editable(user)
    _assert_sites_within_reach(actor, user.site_access)
```

In `reset_password` (`admin.py:355-364`):

```python
async def reset_password(
    user_id: str,
    actor: ManagerUser,
    session: SessionDep,
    payload: ResetPasswordIn | None = None,
) -> TempPasswordOut:
    """Returns the new password once — it is never retrievable again."""
    user = await _load(session, user_id)
    _assert_platform_editable(user)
    _assert_sites_within_reach(actor, user.site_access)
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd backend && pytest tests/test_admin.py -k platform_managed_user_cannot -v`
Expected: `1 passed`

- [ ] **Step 6: Run the full admin test file and full suite**

Run: `cd backend && pytest tests/test_admin.py -v && pytest -q`
Expected: all pass. (`create_user` is deliberately not guarded — it only ever targets a *new* handle; `_assert_unique` already 409s on any existing handle, platform-managed or not, so there's no separate case to add.)

- [ ] **Step 7: Commit**

```bash
git add backend/app/api/admin.py backend/tests/test_admin.py
git commit -m "Reject local edits to SiteOps-managed users"
```

---

### Task 9: Flutter `AppUser.isPlatformManaged`

**Files:**
- Modify: `app/lib/models/app_user.dart`

**Interfaces:**
- Produces: `AppUser.isPlatformManaged: bool` — consumed by Task 10 (repository mapping) and Task 11 (UI).

- [ ] **Step 1: Add the field to the constructor and class body**

In `app/lib/models/app_user.dart`, modify the constructor (lines 72-83):

```dart
  const AppUser({
    required this.id,
    required this.name,
    required this.userId,
    required this.email,
    required this.role,
    required this.sites,
    required this.active,
    this.mustResetPassword = false,
    this.permissions = const <String>{},
    this.isPlatformManaged = false,
    bool? governsAllSites,
  }) : _governsAllSites = governsAllSites;
```

Add the field declaration near `permissions` (after line 114):

```dart
  final Set<String> permissions;

  /// True for any account SiteOps manages — created via `ensure_user` on the
  /// backend, password always null there. E&M's admin screens hide edit
  /// actions for these; the account is administered in SiteOps.
  final bool isPlatformManaged;

  final bool? _governsAllSites;
```

- [ ] **Step 2: Update `copyWith`**

In `app_user.dart:175-198`:

```dart
  AppUser copyWith({
    String? name,
    String? userId,
    String? email,
    UserRole? role,
    List<String>? sites,
    bool? active,
    bool? mustResetPassword,
    Set<String>? permissions,
    bool? isPlatformManaged,
    bool? governsAllSites,
  }) {
    return AppUser(
      id: id,
      name: name ?? this.name,
      userId: userId ?? this.userId,
      email: email ?? this.email,
      role: role ?? this.role,
      sites: sites ?? this.sites,
      active: active ?? this.active,
      mustResetPassword: mustResetPassword ?? this.mustResetPassword,
      permissions: permissions ?? this.permissions,
      isPlatformManaged: isPlatformManaged ?? this.isPlatformManaged,
      governsAllSites: governsAllSites ?? _governsAllSites,
    );
  }
```

- [ ] **Step 3: Update `toJson`/`fromJson`**

In `app_user.dart:200-229`:

```dart
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'user_id': userId,
        'email': email.isEmpty ? null : email,
        'role': role.wireName,
        'site_access': sites,
        'is_active': active,
        'must_reset_password': mustResetPassword,
        'permissions': permissions.toList()..sort(),
        'is_platform_managed': isPlatformManaged,
        'governs_all_sites': governsAllSites,
      };

  factory AppUser.fromJson(Map<String, dynamic> json) => AppUser(
        id: json['id'] as String,
        name: json['name'] as String,
        userId: json['user_id'] as String,
        email: json['email'] as String? ?? '',
        role: UserRole.fromWire(json['role'] as String?),
        sites: List<String>.from(
          json['site_access'] as List<dynamic>? ?? <dynamic>[],
        ),
        active: json['is_active'] as bool? ?? true,
        mustResetPassword: json['must_reset_password'] as bool? ?? false,
        permissions: <String>{
          for (final p in (json['permissions'] as List<dynamic>? ?? <dynamic>[]))
            p as String,
        },
        isPlatformManaged: json['is_platform_managed'] as bool? ?? false,
        governsAllSites: json['governs_all_sites'] as bool?,
      );
```

- [ ] **Step 4: Run the existing model tests**

Run: `cd app && flutter test test/models/ 2>/dev/null || flutter test --plain-name "AppUser"`
Expected: all existing `AppUser` tests still pass (no test file may exist yet for this model — if `flutter test test/models/` reports "No tests found", that's fine; the field is exercised by Task 10/11's tests instead).

- [ ] **Step 5: Commit**

```bash
git add app/lib/models/app_user.dart
git commit -m "Add AppUser.isPlatformManaged"
```

---

### Task 10: `ApiUserRepository` mapping + `FakeUserRepository` fixture support

**Files:**
- Modify: `app/lib/data/api/api_repositories.dart:763-780` (`_userFromWire`)
- Modify: `app/test/support/fake_repositories.dart` (add a way to seed a platform-managed fixture user)

**Interfaces:**
- Consumes: `AppUser.isPlatformManaged` (Task 9), backend's `is_platform_managed` field (Task 4).
- Produces: `FakeUserRepository`'s store now supports platform-managed fixture users — consumed by Task 11's widget test.

- [ ] **Step 1: Map the new field in `_userFromWire`**

In `app/lib/data/api/api_repositories.dart:763-780`:

```dart
  AppUser _userFromWire(Map<String, dynamic> json) => AppUser(
        id: json['id'] as String,
        name: json['name'] as String,
        userId: json['user_id'] as String,
        email: json['email'] as String? ?? '',
        role: UserRole.fromWire(json['role'] as String?),
        sites: List<String>.from(
          json['site_access'] as List<dynamic>? ?? <dynamic>[],
        ),
        active: json['is_active'] as bool? ?? true,
        mustResetPassword: json['must_reset_password'] as bool? ?? false,
        permissions: <String>{
          for (final p in (json['permissions'] as List<dynamic>? ?? <dynamic>[]))
            p as String,
        },
        isPlatformManaged: json['is_platform_managed'] as bool? ?? false,
        governsAllSites: json['governs_all_sites'] as bool?,
      );
```

- [ ] **Step 2: Locate the `FakeStore` seed data for users**

Run: `grep -n "FakeStore\|users = \[" app/test/support/fake_repositories.dart | head -20`

Read the surrounding seed list (the fixture users constructed with `AppUser(...)`) to find where to add one platform-managed fixture user. Since the exact seed list wasn't captured verbatim during planning, this step is: open `app/test/support/fake_repositories.dart`, find the `FakeStore`'s initial `users` list (a `List<AppUser>` built with `AppUser(...)` literals, analogous to `conftest.py`'s `_seed()`), and add one more entry with `isPlatformManaged: true`, e.g.:

```dart
AppUser(
  id: 'platform-1',
  name: 'Platform Person',
  userId: 'PLATPERSON',
  email: '',
  role: UserRole.executive,
  sites: const <String>['MBMT'],
  active: true,
  isPlatformManaged: true,
),
```

- [ ] **Step 3: Run the Flutter analyzer to confirm no type errors**

Run: `cd app && flutter analyze lib/data/api/api_repositories.dart test/support/fake_repositories.dart`
Expected: `No issues found!`

- [ ] **Step 4: Commit**

```bash
git add app/lib/data/api/api_repositories.dart app/test/support/fake_repositories.dart
git commit -m "Map is_platform_managed through ApiUserRepository and the fake"
```

---

### Task 11: `UsersPane` UI — hide actions, tag, "Sync now"

**Files:**
- Modify: `app/lib/screens/admin/users_pane.dart`
- Test: whichever widget test file covers `UsersPane` today (`grep -rn "UsersPane" app/test/` to find it; if none exists, this task's manual verification in Task 12 is the coverage — do not invent a placeholder test file).

**Interfaces:**
- Consumes: `AppUser.isPlatformManaged` (Task 9), `ApiClient.post` (existing, `app/lib/data/api/api_client.dart:105-106`), `sessionProvider`'s `site` field (existing, `app/lib/state/session.dart:37`).

- [ ] **Step 1: Hide Edit/Reset/Deactivate for platform-managed rows, show a tag instead**

In `app/lib/screens/admin/users_pane.dart`, `_UserRow.build` (lines 649-680), replace the actions `Wrap`:

```dart
            if (user.isPlatformManaged)
              const TagBadge(
                label: 'MANAGED IN SITEOPS',
                background: T.indigoTint,
                foreground: T.indigo,
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  OutlineActionButton(
                    label: 'Edit',
                    onPressed: onEdit,
                    accent: T.green,
                    fontSize: 12.5,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 13, vertical: 7),
                  ),
                  OutlineActionButton(
                    label: 'Reset password',
                    onPressed: onReset,
                    accent: T.blue,
                    fontSize: 12.5,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 13, vertical: 7),
                  ),
                  OutlineActionButton(
                    label: user.active ? 'Deactivate' : 'Activate',
                    // A manager cannot lock themselves out.
                    onPressed: isSelf && user.active ? null : onToggle,
                    foreground: user.active ? T.redInk : T.greenInk,
                    borderColor: user.active ? T.redBorderTint : T.green,
                    fontSize: 12.5,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 13, vertical: 7),
                  ),
                ],
              ),
```

(This replaces the unconditional `Wrap(...)` block that currently spans lines 649-680 — the closing bracket structure stays the same, only the top-level widget becomes an `if/else` instead of a bare `Wrap`.)

- [ ] **Step 2: Add a "Sync now" button and wire it to the endpoint**

In `_UsersPaneState`, add a syncing-state field near the other state fields (line 30-36):

```dart
class _UsersPaneState extends ConsumerState<UsersPane> {
  UserDraft? _draft;
  String? _error;
  bool _saving = false;
  bool _syncing = false;
```

Add the sync method near `_toggleActive`/`_resetPassword` (after line 131):

```dart
  Future<void> _syncFromSiteOps() async {
    final site = ref.read(sessionProvider).site;
    if (site.isEmpty || _syncing) return;
    setState(() => _syncing = true);
    try {
      final json = await ref
          .read(apiClientProvider)
          .post('/sites/$site/users/sync-from-siteops');
      final r = json as Map<String, dynamic>;
      final synced = r['synced'] as int? ?? 0;
      final adopted = r['adopted'] as int? ?? 0;
      final parts = <String>[
        '$synced synced',
        if (adopted > 0) '$adopted adopted',
      ];
      ref.read(toastProvider.notifier).show('Users: ${parts.join(', ')}.');
      ref.invalidate(usersProvider);
    } on ApiException catch (e) {
      if (mounted) ref.read(toastProvider.notifier).show(e.message);
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }
```

Add the import for `apiClientProvider` at the top of the file (alongside the existing imports, line 6):

```dart
import '../../state/providers.dart';
import '../../state/session.dart';
```

(`apiClientProvider` lives in `state/providers.dart`, already the import path used by `vehicle_master_screen.dart:5` for the identical pattern.)

Add the button next to the header's `+ Create user` action — modify `ScreenHeader`'s usage (lines 149-167) to add a second action, or place a `TextButton.icon` immediately above the header if `ScreenHeader` takes only one `action` widget. Check `ScreenHeader`'s signature first:

Run: `grep -n "class ScreenHeader" -A 15 app/lib/widgets/*.dart`

If `ScreenHeader.action` accepts only a single widget, wrap both buttons in a `Row`:

```dart
        ScreenHeader(
          title: 'Users',
          subtitle: session.governsAllSites
              ? 'Every account across the estate. Create logins, assign roles '
                  'and site access. Inactive users cannot sign in.'
              : 'Staff on your sites. You can create supervisors and '
                  'executives; promotion is a super-admin action.',
          action: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextButton.icon(
                onPressed: _syncing ? null : _syncFromSiteOps,
                icon: _syncing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync, size: 18),
                label: Text(
                  _syncing ? 'Syncing…' : 'Sync now',
                  style: AppText.sans(size: 14, weight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 8),
              FilledActionButton(
                label: '+ Create user',
                onPressed: () => _open(
                  UserDraft(
                    role: session.user?.role.grantableRoles.last ??
                        UserRole.executive,
                  ),
                ),
                fontSize: 14,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
              ),
            ],
          ),
        ),
```

- [ ] **Step 3: Run the Flutter analyzer**

Run: `cd app && flutter analyze lib/screens/admin/users_pane.dart`
Expected: `No issues found!`

- [ ] **Step 4: Find and update (or note the absence of) a `UsersPane` widget test**

Run: `grep -rln "UsersPane" app/test/`

If a test file references `UsersPane` and asserts on the presence of "Edit"/"Reset password" buttons for every row, add one case using the platform-managed fixture user from Task 10 asserting those buttons are absent and "MANAGED IN SITEOPS" is present instead. If no such widget test exists, do not create one from scratch here — note this explicitly to the user during Task 12's manual verification, since UI widget-test scaffolding is out of scope for this plan (the design spec's testing plan calls for manual verification against the running app, which Task 12 covers).

- [ ] **Step 5: Commit**

```bash
git add app/lib/screens/admin/users_pane.dart
git commit -m "Users pane: hide local-edit actions for SiteOps-managed users, add Sync now"
```

---

### Task 12: local end-to-end verification

**Files:** none (verification only).

- [ ] **Step 1: Bring up the local stack with the new migration applied**

Run: `cd backend && docker compose up -d --build && docker compose exec api alembic upgrade head`
Expected: containers healthy, migration at `0018`.

- [ ] **Step 2: Link a real site and run the manual sync against the real SiteOps sandbox**

Using the credentials/site already configured in `backend/.env` (`SITEOPS_BASE_URL=https://platform-service.transvolt.in/api/v1`), log in as the seeded super admin and call the new endpoint for a site whose `siteops_site_id` is known:

```bash
TOKEN=$(curl -s -X POST http://localhost:8123/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"user_id":"ADMIN","password":"admin123"}' | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
curl -s -X POST http://localhost:8123/api/v1/sites/MBMT/users/sync-from-siteops \
  -H "Authorization: Bearer $TOKEN"
```

Expected: a JSON body with `synced`/`adopted`/`reactivated`/`deactivated` counts, not a 409/502.

- [ ] **Step 3: Confirm the mirror landed correctly in Postgres**

Run: `docker exec enm_db psql -U enm -d enm -c "SELECT user_id, role, is_active, password_hash IS NULL AS platform_managed FROM users WHERE id IN (SELECT user_id FROM user_site_access WHERE site_code='MBMT');"`
Expected: rows with `platform_managed = t` and a plausible `role` value pulled from the real SiteOps roster — use this output to sanity-check the `_map_role` mapping in `user_sync.py` against real role-name strings (per the design spec's open question) and adjust the mapping if the real names don't match the `super_admin`/`manager`/`supervisor` substrings assumed there.

- [ ] **Step 4: Confirm the adoption-gap fix against a real collision**

```bash
curl -s -X POST http://localhost:8123/api/v1/admin/users \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"Collision Test","user_id":"<a real SiteOps handle from step 3, not yet synced>","role":"executive","site_access":["MBMT"],"temp_password":"Temp@1234"}'
```

Then re-run the sync from Step 2 and re-run the query from Step 3 for that specific `user_id` — confirm `password_hash` is now null and a subsequent `PUT /admin/users/{id}` on it returns 409.

- [ ] **Step 5: Run the Flutter app against the local backend and check the Users pane**

Run: `cd app && flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8123/api/v1`

In the running app: open Admin → Users, confirm synced users show the "MANAGED IN SITEOPS" tag with no Edit/Reset/Deactivate buttons, confirm local-only users (e.g. the bootstrap admin) still show all three actions, and click "Sync now" to confirm it round-trips and refreshes the list.

- [ ] **Step 6: Run the full backend and Flutter test suites one more time**

Run: `cd backend && pytest -q && cd ../app && flutter analyze`
Expected: all green.

---

## Self-Review Notes

- **Spec coverage:** scope-by-linked-site (Tasks 6/8 gate on `siteops_site_id`/`password_hash`), break-glass preserved (never touched — it always has `password_hash` set), sync+overwrite (Task 5), nightly+on-demand (Tasks 6/7), adoption-gap fix (Task 3) — all covered. The spec's "AND has UserSiteAccess to a linked site" qualifier on the guard was deliberately dropped in Task 8 per the Global Constraints note — a stricter, more correct reading of the same intent.
- **Placeholder scan:** no TBDs; Task 11 Step 4 explicitly declines to fabricate a widget-test file that may not exist rather than writing a fake placeholder test.
- **Type consistency:** `UserSyncResult`/`UserSyncOut` field names (`synced`, `adopted`, `reactivated`, `deactivated`) match across Task 5 (dataclass), Task 6 (schema + endpoint), and Task 12 (manual curl verification). `ensure_user`'s `source` parameter name and `Literal["login", "sync"]` type match across Task 3's definition and Task 3/5's call sites.
