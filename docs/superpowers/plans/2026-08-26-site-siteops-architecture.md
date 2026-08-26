# Site identity, SiteOps linking, and checklist provisioning — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace silent site auto-vivification with an explicit, atomic SiteOps link that provisions a site's vehicles and checklists in one step, and make checklist inheritance key off a site's declared `operating_categories` instead of unioning every checklist onto every site.

**Architecture:** `Site` gains a persisted `siteops_site_id` link plus sync bookkeeping; `SiteConfig` gains `operating_categories`. `sites.load_site()` becomes a strict getter (404 on miss) — the only two ways a `Site` row is created are `POST /sites` and the new `POST /sites/{code}/siteops-link`, which stores the link, seeds the checklist catalogue for the site's declared categories, and syncs vehicles from SiteOps, all in one transaction. A nightly job refreshes vehicles for every linked site. The client drops its fuzzy SiteOps-id name-matching in favor of the persisted id.

**Tech Stack:** FastAPI + SQLAlchemy (async) + Alembic + Postgres (backend); Flutter + Riverpod (client).

**Spec:** `docs/superpowers/specs/2026-08-26-site-siteops-architecture-design.md`

## Global Constraints

- Vehicle registration numbers: stored uppercase, no whitespace.
- Dates: `yyyy-MM-dd` strings; times: `HH:mm` site-local (IST).
- Money/volume/power: decimals, never floats (not touched by this plan).
- Never a JSONB blob for register/domain data — real columns and FKs. `last_siteops_sync_result` is diagnostic sync metadata, not a domain record, so `JSON` is acceptable there per the spec.
- `app/seeds/checklists_v1.py` / `checklists_v2.py` / `checklists_v3.py` are frozen history — **do not edit them**. Category tagging happens in `checklists.py`, not the seed files.
- Every backend endpoint change updates its Flutter repository method and `test/support/` fake in the same task — a drifting fake is worse than no fake.
- Run `cd backend && make lint-backend && make test-backend` after each backend task; `cd app && make lint-app && make test-app` after each Flutter task. Both must pass before committing.

---

## Task 1: Migration — SiteOps link fields and operating_categories

**Files:**
- Create: `backend/alembic/versions/0017_siteops_link_and_categories.py`
- Modify: `backend/app/models/master.py:29-54` (`Site` class)
- Modify: `backend/app/models/site_config.py:22-76` (`SiteConfig` class)
- Test: `backend/tests/test_sites.py`

**Interfaces:**
- Produces: `Site.siteops_site_id: str | None`, `Site.last_siteops_sync_at: datetime | None`, `Site.last_siteops_sync_result: dict | None`; `SiteConfig.operating_categories: list[str]` (default `["bus"]`). Every later task relies on these exact names.

- [ ] **Step 1: Write the failing test**

Add to `backend/tests/test_sites.py`:

```python
async def test_new_site_has_no_siteops_link(client: AsyncClient) -> None:
    h = await auth_headers(client, SUPER_ADMIN)
    await client.post(
        "/sites", json={"code": "MIGTEST", "name": "Migration Test"}, headers=h
    )

    async with SessionLocal() as session:
        site = await session.get(Site, "MIGTEST")
        assert site.siteops_site_id is None
        assert site.last_siteops_sync_at is None
        assert site.last_siteops_sync_result is None


async def test_site_config_defaults_to_bus_operations(client: AsyncClient) -> None:
    from app.services import site_config

    h = await auth_headers(client, SUPER_ADMIN)
    await client.post(
        "/sites", json={"code": "MIGTEST2", "name": "Migration Test 2"}, headers=h
    )

    async with SessionLocal() as session:
        config = await site_config.get_or_create(session, "MIGTEST2")
        assert config.operating_categories == ["bus"]
```

Make sure `from app.db import SessionLocal` and `from app.models.master import Site` are imported at the top of the file (add them if missing — check the existing import block first).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && .venv/bin/pytest tests/test_sites.py -k "siteops_link or operations" -v`
Expected: FAIL with `AttributeError: 'Site' object has no attribute 'siteops_site_id'` (or equivalent for `operating_categories`).

- [ ] **Step 3: Add the migration**

Create `backend/alembic/versions/0017_siteops_link_and_categories.py`:

```python
"""siteops link fields on sites, operating_categories on site_configs

Revision ID: 0017
Revises: 0016
Create Date: 2026-08-26

A site's link to its SiteOps counterpart was passed by the client on every
sync-from-siteops call and never stored — nothing let a nightly job find
"every linked site", and every staff lookup re-guessed the SiteOps id by
fuzzy-matching a site name. `siteops_site_id` persists the link once,
explicitly, on the site row.

`operating_categories` lets checklist provisioning key off what a site
actually runs instead of unioning every checklist onto every site regardless
of fleet composition.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0017"
down_revision = "0016"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "sites", sa.Column("siteops_site_id", sa.String(64), nullable=True)
    )
    op.create_unique_constraint(
        "uq_sites_siteops_site_id", "sites", ["siteops_site_id"]
    )
    op.add_column(
        "sites",
        sa.Column("last_siteops_sync_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column(
        "sites", sa.Column("last_siteops_sync_result", sa.JSON(), nullable=True)
    )
    op.add_column(
        "site_configs",
        sa.Column(
            "operating_categories",
            postgresql.ARRAY(sa.String(20)),
            nullable=False,
            server_default="{bus}",
        ),
    )


def downgrade() -> None:
    op.drop_column("site_configs", "operating_categories")
    op.drop_column("sites", "last_siteops_sync_result")
    op.drop_column("sites", "last_siteops_sync_at")
    op.drop_constraint("uq_sites_siteops_site_id", "sites", type_="unique")
    op.drop_column("sites", "siteops_site_id")
```

Update `backend/app/models/master.py`. Add `JSON` to the `sqlalchemy` import block at the top (alongside `Boolean, Date, Enum, ForeignKey, ...`), then add to the `Site` class right after `commissioned_on`:

```python
    siteops_site_id: Mapped[str | None] = mapped_column(
        String(64), unique=True, nullable=True
    )
    last_siteops_sync_at: Mapped[datetime | None] = mapped_column(
        TZDateTime, nullable=True
    )
    last_siteops_sync_result: Mapped[dict | None] = mapped_column(
        JSON, nullable=True
    )
```

Update `backend/app/models/site_config.py`. Add `from sqlalchemy.dialects.postgresql import ARRAY` to the imports, then add to the `SiteConfig` class right after `odometer_sync_source`:

```python
    #: Declares this site's nature of operations. Checklist provisioning
    #: (`checklists.apply_catalogue`) only seeds catalogue entries tagged
    #: with a category in this set.
    operating_categories: Mapped[list[str]] = mapped_column(
        ARRAY(String(20)),
        nullable=False,
        default=lambda: ["bus"],
        server_default="{bus}",
    )
```

- [ ] **Step 4: Run the migration and verify the test passes**

Run: `cd backend && .venv/bin/python -m alembic upgrade head`
Run: `cd backend && .venv/bin/pytest tests/test_sites.py -k "siteops_link or operations" -v`
Expected: PASS

- [ ] **Step 5: Verify migration reversibility**

Run: `cd backend && .venv/bin/python -m alembic downgrade -1 && .venv/bin/python -m alembic upgrade head`
Expected: both commands exit 0.

- [ ] **Step 6: Commit**

```bash
cd backend
git add alembic/versions/0017_siteops_link_and_categories.py app/models/master.py app/models/site_config.py tests/test_sites.py
git commit -m "Add SiteOps link fields on sites and operating_categories on site configs"
```

---

## Task 2: Checklist catalogue filtered by operating_categories

**Files:**
- Modify: `backend/app/services/checklists.py:101-153` (`apply_catalogue`)
- Test: `backend/tests/test_checklists.py`

**Interfaces:**
- Consumes: `SiteConfig.operating_categories` (Task 1).
- Produces: `checklists.apply_catalogue(session, site_code) -> int` (signature unchanged — every existing call site keeps working). `checklists._seed_catalogues() -> list[tuple[str, list[dict]]]` — monkeypatch target for tests and the seam a future truck seed module plugs into.

- [ ] **Step 1: Write the failing test**

Add to `backend/tests/test_checklists.py` (check existing imports at the top of the file and add `from app.db import SessionLocal`, `from app.models.checklist import ChecklistTemplate`, `from app.models.master import Site`, `from app.services import checklists, site_config`, `from sqlalchemy import select` if not already present):

```python
async def test_apply_catalogue_only_seeds_matching_categories(monkeypatch) -> None:
    bus_entry = {
        "work_type_code": "10 DAYS SERVICE",
        "variant": "test-bus-variant",
        "name": "bus test template",
        "items": [
            {
                "section": "S",
                "label": "Bus check",
                "sort_order": 0,
                "response_type": "ok_not_ok",
                "is_required": True,
                "chart_key": None,
            }
        ],
    }
    truck_entry = {
        "work_type_code": "10 DAYS SERVICE",
        "variant": "test-truck-variant",
        "name": "truck test template",
        "items": [
            {
                "section": "S",
                "label": "Truck check",
                "sort_order": 0,
                "response_type": "ok_not_ok",
                "is_required": True,
                "chart_key": None,
            }
        ],
    }
    monkeypatch.setattr(
        checklists,
        "_seed_catalogues",
        lambda: [("bus", [bus_entry]), ("truck", [truck_entry])],
    )

    async with SessionLocal() as session:
        session.add(Site(code="CATTEST", name="Category Test", is_active=True))
        await session.flush()
        config = await site_config.get_or_create(session, "CATTEST")
        assert config.operating_categories == ["bus"]
        await checklists.apply_catalogue(session, "CATTEST")
        await session.commit()

    async with SessionLocal() as session:
        templates = (
            (
                await session.scalars(
                    select(ChecklistTemplate).where(
                        ChecklistTemplate.site_code == "CATTEST"
                    )
                )
            )
            .unique()
            .all()
        )
        variants = {t.variant for t in templates}
        assert "test-bus-variant" in variants
        assert "test-truck-variant" not in variants

        config = await session.get(SiteConfig, "CATTEST")
        config.operating_categories = ["bus", "truck"]
        await session.commit()

    async with SessionLocal() as session:
        await checklists.apply_catalogue(session, "CATTEST")
        await session.commit()

    async with SessionLocal() as session:
        templates = (
            (
                await session.scalars(
                    select(ChecklistTemplate).where(
                        ChecklistTemplate.site_code == "CATTEST"
                    )
                )
            )
            .unique()
            .all()
        )
        assert "test-truck-variant" in {t.variant for t in templates}
```

Add `from app.models.site_config import SiteConfig` to the test file's imports if not already present.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && .venv/bin/pytest tests/test_checklists.py -k category -v`
Expected: FAIL with `AttributeError: module 'app.services.checklists' has no attribute '_seed_catalogues'`.

- [ ] **Step 3: Implement the filter**

In `backend/app/services/checklists.py`, add `from typing import Any` to the imports, then replace the `apply_catalogue` function:

```python
def _seed_catalogues() -> list[tuple[str, list[dict[str, Any]]]]:
    """Every installed catalogue, tagged by the operations it belongs to.

    A future truck catalogue is one more entry here — the seed files
    themselves (checklists_v1/v2/v3) are frozen history and are never edited
    after they ship; see their own docstrings.
    """
    from app.seeds.checklists_v1 import CHECKLISTS as CHECKLISTS_V1
    from app.seeds.checklists_v2 import CHECKLISTS as CHECKLISTS_V2
    from app.seeds.checklists_v3 import CHECKLISTS as CHECKLISTS_V3

    return [
        ("bus", CHECKLISTS_V1),
        ("bus", CHECKLISTS_V2),
        ("bus", CHECKLISTS_V3),
    ]


async def apply_catalogue(session: AsyncSession, site_code: str) -> int:
    """Give a site the checklists its declared operating_categories call for.

    Migrations 0014 (D.I. / 10-day, `checklists_v1`), 0015 (P.M. docking 9M,
    `checklists_v2`) and 0016 (P.M. docking 12M AC/Non-AC, `checklists_v3`)
    put these in the database for every site that existed when each ran. A
    site created afterwards is past all three, so it needs the same
    catalogue applied here or its mechanics open an empty form — this must
    stay in sync with every seed module a migration has ever applied, not
    just the first one.

    Only catalogue entries whose category is in the site's
    `operating_categories` are seeded — a bus-only site (the default, and
    every site today) is unaffected; a site that also runs trucks picks up
    any `category="truck"` catalogue the moment one is installed.

    Never overwrites: a template that already has lines belongs to the depot,
    whether it edited ours or wrote its own.
    """
    from app.services import site_config as site_config_service

    config = await site_config_service.get_or_create(session, site_code)
    active_categories = set(config.operating_categories)
    entries = [
        entry
        for category, catalogue in _seed_catalogues()
        if category in active_categories
        for entry in catalogue
    ]

    codes = {t["work_type_code"] for t in entries}
    work_types = {
        wt.code: wt
        for wt in (
            await session.scalars(select(WorkType).where(WorkType.code.in_(codes)))
        ).all()
    }

    added = 0
    for entry in entries:
        work_type = work_types.get(entry["work_type_code"])
        if work_type is None:
            continue
        template = await ensure_template(
            session, site_code, work_type, variant=entry["variant"]
        )
        if template.items:
            continue
        template.name = entry["name"]
        for item in entry["items"]:
            template.items.append(
                ChecklistItem(
                    section=item["section"] or "",
                    label=item["label"],
                    sort_order=item["sort_order"],
                    response_type=ResponseType(item["response_type"]),
                    is_required=item["is_required"],
                    chart_key=item["chart_key"],
                )
            )
            added += 1
    await session.flush()
    return added
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend && .venv/bin/pytest tests/test_checklists.py -v`
Expected: PASS (including the pre-existing tests in this file — the default `["bus"]` category set means every existing site's behavior is unchanged).

- [ ] **Step 5: Commit**

```bash
cd backend
git add app/services/checklists.py tests/test_checklists.py
git commit -m "Filter checklist catalogue application by a site's operating_categories"
```

---

## Task 3: Strict load_site — kill silent auto-vivification

**Files:**
- Modify: `backend/app/services/sites.py:1-35` (imports, `load_site`)
- Test: `backend/tests/test_sites.py`

**Interfaces:**
- Produces: `sites.load_site(session, code) -> Site` now raises `NotFound` (404) instead of creating a row. Tasks 5 and 6 call this and rely on the 404 behavior.

- [ ] **Step 1: Write the failing test**

Add to `backend/tests/test_sites.py`:

```python
async def test_create_vehicle_404s_on_unknown_site(client: AsyncClient) -> None:
    h = await auth_headers(client, SUPER_ADMIN)
    r = await client.post(
        "/sites/GHOSTCODE/vehicles",
        json={"registration_no": "MH01AB1234", "make": "EKA", "model": "EV9M"},
        headers=h,
    )
    assert r.status_code == 404, r.text


async def test_put_config_404s_on_unknown_site(client: AsyncClient) -> None:
    h = await auth_headers(client, SUPER_ADMIN)
    r = await client.put(
        "/sites/GHOSTCODE2/config",
        json={"service_plans": [{"code": "X", "name": "X", "interval_km": 1000}]},
        headers=h,
    )
    assert r.status_code == 404, r.text


async def test_create_vehicle_rejected_once_site_is_siteops_linked(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client, SUPER_ADMIN)
    await client.post(
        "/sites", json={"code": "LINKEDVEH", "name": "Linked Vehicle Test"}, headers=h
    )
    async with SessionLocal() as session:
        site = await session.get(Site, "LINKEDVEH")
        site.siteops_site_id = "siteops-uuid-linkedveh"
        await session.commit()

    r = await client.post(
        "/sites/LINKEDVEH/vehicles",
        json={"registration_no": "MH01AB9999", "make": "EKA", "model": "EV9M"},
        headers=h,
    )
    assert r.status_code == 409, r.text
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && .venv/bin/pytest tests/test_sites.py -k "unknown_site or siteops_linked" -v`
Expected: FAIL — `create_vehicle`/`put_config` currently 200 on an unknown site (silently creating it), and the linked-site guard doesn't exist yet.

- [ ] **Step 3: Implement**

In `backend/app/services/sites.py`, replace the imports at the top:

```python
from __future__ import annotations

import re
from datetime import UTC, datetime
from datetime import date as date_t
from datetime import timedelta

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import Conflict, NotFound, ValidationError
from app.models.master import Site, Vehicle
from app.models.user import User, UserSiteAccess
from app.schemas.site import SiteOut, VehicleOut
```

Replace `load_site`:

```python
async def load_site(session: AsyncSession, code: str) -> Site:
    """The site must already exist — onboarded via POST /sites or linked via
    POST /sites/{code}/siteops-link. Never creates one: a site conjured from
    whichever endpoint happened to see its code first is how a depot ended up
    with a placeholder name and no checklists in production.
    """
    clean_code = code.strip().upper()
    site = await session.get(Site, clean_code)
    if site is None:
        raise NotFound(f"Site {clean_code} does not exist — onboard it first")
    return site
```

In `backend/app/api/sites.py`, update `create_vehicle` to capture the site and guard on the link:

```python
async def create_vehicle(
    code: str, payload: VehicleCreate, user: CurrentUser, session: SessionDep
) -> VehicleOut:
    site_code = assert_site_admin(user, code)
    site = await sites.load_site(session, site_code)
    if site.siteops_site_id is not None:
        raise Conflict(
            f"{site_code} is linked to SiteOps; vehicles come from the "
            "SiteOps sync, not manual creation",
            {"site": "linked to siteops"},
        )
```

(Leave the rest of the function body unchanged — only the first three lines change; `Conflict` is already imported in this file.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend && .venv/bin/pytest tests/test_sites.py tests/test_fleet_sync.py tests/test_checklists.py -v`
Expected: PASS. (`put_config`, `create_profile`, `update_site` all route through `load_site` already, so they 404 correctly with no further code change — verify `test_put_config_404s_on_unknown_site` passes as evidence.)

- [ ] **Step 5: Commit**

```bash
cd backend
git add app/services/sites.py app/api/sites.py tests/test_sites.py
git commit -m "Stop load_site from silently creating a placeholder site"
```

---

## Task 4: operating_categories on SiteConfigIO — PUT /config reapplies the catalogue

**Files:**
- Modify: `backend/app/schemas/site_config.py:37-54` (`SiteConfigIO`)
- Modify: `backend/app/services/site_config.py:79-118,171-227` (`to_io`, `replace`)
- Test: `backend/tests/test_site_config.py`

**Interfaces:**
- Consumes: `checklists.apply_catalogue` (Task 2).
- Produces: `SiteConfigIO.operating_categories: list[str]`. The Flutter `SiteConfig` model (Task 11) mirrors this field name.

- [ ] **Step 1: Write the failing test**

Check `backend/tests/test_site_config.py` for its existing fixture pattern (how it builds a valid `SiteConfigIO` payload for `PUT /sites/{code}/config`) before writing this test, and follow the same shape. Add:

```python
async def test_put_config_reapplies_catalogue_when_categories_change(
    client: AsyncClient, monkeypatch
) -> None:
    from app.services import checklists

    calls: list[str] = []
    original = checklists.apply_catalogue

    async def _tracking(session, site_code):
        calls.append(site_code)
        return await original(session, site_code)

    monkeypatch.setattr(checklists, "apply_catalogue", _tracking)

    h = await auth_headers(client, SUPER_ADMIN)
    await client.post(
        "/sites", json={"code": "CATCFG", "name": "Category Config Test"}, headers=h
    )

    payload = _valid_config_payload()  # use the file's existing helper/fixture
    payload["operating_categories"] = ["bus", "truck"]

    r = await client.put("/sites/CATCFG/config", json=payload, headers=h)
    assert r.status_code == 200, r.text
    assert r.json()["operating_categories"] == ["bus", "truck"]
    assert "CATCFG" in calls

    calls.clear()
    r2 = await client.put("/sites/CATCFG/config", json=payload, headers=h)
    assert r2.status_code == 200, r2.text
    assert calls == []  # unchanged categories: no re-seed
```

If the file has no existing payload-building helper, inline the minimal valid body directly (mirror whatever the file's other `PUT /config` tests already send — same `service_plans`/`reminder_lead_km`/etc. shape as `SiteConfigIO`).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && .venv/bin/pytest tests/test_site_config.py -k reapplies -v`
Expected: FAIL — `operating_categories` isn't a recognized field on `SiteConfigIO` yet (422, or silently dropped and the assertion on the response fails).

- [ ] **Step 3: Implement**

In `backend/app/schemas/site_config.py`, add to `SiteConfigIO`:

```python
    operating_categories: list[str] = Field(default_factory=lambda: ["bus"])
```

In `backend/app/services/site_config.py`, update `to_io` — add `operating_categories=config.operating_categories,` to the `SiteConfigIO(...)` constructor call (next to `max_vehicles_in_service=config.max_vehicles_in_service,`).

Update `replace`, inserting after the `config.odometer_sync_source = payload.odometer_sync.source` line and before `config.updated_at = datetime.now(UTC)`:

```python
    normalized_categories = sorted(
        {c.strip().lower() for c in payload.operating_categories if c.strip()}
    ) or ["bus"]
    categories_changed = set(config.operating_categories) != set(normalized_categories)
    config.operating_categories = normalized_categories
```

At the end of `replace`, after the shift-window loop and `await session.flush()`, before `return config`:

```python
    if categories_changed:
        from app.services import checklists

        await checklists.apply_catalogue(session, site_code)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend && .venv/bin/pytest tests/test_site_config.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd backend
git add app/schemas/site_config.py app/services/site_config.py tests/test_site_config.py
git commit -m "Add operating_categories to site config; reapply catalogue when it changes"
```

---

## Task 5: POST /sites/{code}/siteops-link — atomic provisioning

**Files:**
- Modify: `backend/app/models/enums.py:152-190` (`AuditAction`)
- Modify: `backend/app/schemas/site.py:30-40,146-158` (`SiteOut`, new `SiteOpsLinkIn`/`SiteOpsLinkOut`)
- Modify: `backend/app/services/sites.py` (new `link_to_siteops`, `site_out` update)
- Modify: `backend/app/api/sites.py` (new route)
- Test: `backend/tests/test_fleet_sync.py`

**Interfaces:**
- Consumes: `checklists.apply_catalogue` (Task 2), `masters.sync_vehicles_from_siteops` (existing, unchanged signature), `sites.load_site` (Task 3).
- Produces: `sites.link_to_siteops(session, site_code, siteops_site_id) -> Site` (populates `siteops_site_id`, `last_siteops_sync_at`, `last_siteops_sync_result` on the returned `Site`). Task 7's nightly job writes the same three fields the same way.

- [ ] **Step 1: Write the failing test**

Add to `backend/tests/test_fleet_sync.py`:

```python
from app.models.checklist import ChecklistTemplate


async def test_siteops_link_provisions_catalogue_and_fleet(
    client: AsyncClient, monkeypatch
) -> None:
    monkeypatch.setattr(
        siteops, "list_all_vehicles", _fake_list_all_vehicles(SITEOPS_ROWS)
    )
    h = await auth_headers(client, SUPER_ADMIN)
    await client.post(
        "/sites", json={"code": "FRESH", "name": "Fresh Site"}, headers=h
    )

    r = await client.post(
        "/sites/FRESH/siteops-link",
        json={"siteops_site_id": "siteops-uuid-fresh"},
        headers=h,
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["created"] == 4
    assert body["site"]["siteops_site_id"] == "siteops-uuid-fresh"

    async with SessionLocal() as session:
        vehicles = (
            await session.scalars(
                select(Vehicle).where(Vehicle.site_code == "FRESH")
            )
        ).all()
        assert len(vehicles) == 4

        templates = (
            (
                await session.scalars(
                    select(ChecklistTemplate).where(
                        ChecklistTemplate.site_code == "FRESH"
                    )
                )
            )
            .unique()
            .all()
        )
        assert len(templates) > 0


async def test_siteops_link_rejects_a_siteops_id_already_linked_elsewhere(
    client: AsyncClient, monkeypatch
) -> None:
    monkeypatch.setattr(siteops, "list_all_vehicles", _fake_list_all_vehicles([]))
    h = await auth_headers(client, SUPER_ADMIN)
    await client.post("/sites", json={"code": "FIRSTL", "name": "First"}, headers=h)
    await client.post("/sites", json={"code": "SECONDL", "name": "Second"}, headers=h)

    r1 = await client.post(
        "/sites/FIRSTL/siteops-link",
        json={"siteops_site_id": "shared-uuid"},
        headers=h,
    )
    assert r1.status_code == 200, r1.text

    r2 = await client.post(
        "/sites/SECONDL/siteops-link",
        json={"siteops_site_id": "shared-uuid"},
        headers=h,
    )
    assert r2.status_code == 409, r2.text


async def test_siteops_link_is_super_admin_only(client: AsyncClient) -> None:
    h = await auth_headers(client, "TV4102")  # a supervisor, per existing fixtures
    r = await client.post(
        "/sites/MBMT/siteops-link",
        json={"siteops_site_id": "irrelevant"},
        headers=h,
    )
    assert r.status_code == 403
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && .venv/bin/pytest tests/test_fleet_sync.py -k siteops_link -v`
Expected: FAIL with 404 (route doesn't exist yet).

- [ ] **Step 3: Implement**

In `backend/app/models/enums.py`, add to `AuditAction` (alongside `fleet_synced_from_siteops`):

```python
    site_siteops_linked = "site_siteops_linked"
```

In `backend/app/schemas/site.py`, add `siteops_site_id: str | None = None` to `SiteOut`, and add near `FleetSyncIn`/`FleetSyncOut`:

```python
class SiteOpsLinkIn(BaseModel):
    siteops_site_id: str = Field(min_length=1, max_length=64)


class SiteOpsLinkOut(BaseModel):
    site: SiteOut
    created: int
    already_present: int
    variant_backfilled: int
    owned_elsewhere: int
    skipped_no_registration: int
```

In `backend/app/services/sites.py`, update `site_out` to pass through the new field:

```python
def site_out(
    site: Site, vehicle_count: int = 0, user_count: int = 0
) -> SiteOut:
    return SiteOut(
        code=site.code,
        name=site.name,
        is_active=site.is_active,
        timezone=site.timezone,
        address=site.address,
        commissioned_on=site.commissioned_on,
        siteops_site_id=site.siteops_site_id,
        vehicle_count=vehicle_count,
        user_count=user_count,
    )
```

Add to `backend/app/services/sites.py`:

```python
async def link_to_siteops(
    session: AsyncSession, site_code: str, siteops_site_id: str
) -> Site:
    """Explicitly, atomically connect a site to its SiteOps counterpart.

    One transaction: store the link, seed whatever checklist catalogue the
    site's declared operating_categories call for, then pull its fleet from
    SiteOps. A site is never left reachable half-provisioned — the caller
    commits only after all three steps succeed.
    """
    from app.services import checklists, masters

    site = await load_site(session, site_code)

    clash = await session.scalar(
        select(Site.code).where(
            Site.siteops_site_id == siteops_site_id, Site.code != site.code
        )
    )
    if clash:
        raise Conflict(
            f"SiteOps site {siteops_site_id} is already linked to {clash}",
            {"siteops_site_id": "already linked"},
        )

    site.siteops_site_id = siteops_site_id
    await checklists.apply_catalogue(session, site.code)
    result = await masters.sync_vehicles_from_siteops(
        session, site.code, siteops_site_id
    )
    site.last_siteops_sync_at = datetime.now(UTC)
    site.last_siteops_sync_result = {
        "created": result.created,
        "already_present": result.already_present,
        "variant_backfilled": result.variant_backfilled,
        "owned_elsewhere": result.owned_elsewhere,
        "skipped_no_registration": result.skipped_no_registration,
    }
    return site
```

In `backend/app/api/sites.py`, add `SiteOpsLinkIn, SiteOpsLinkOut` to the `from app.schemas.site import (...)` block, then add the route near `sync_fleet_from_siteops`:

```python
@router.post("/sites/{code}/siteops-link", response_model=SiteOpsLinkOut)
async def link_site_to_siteops(
    code: str, payload: SiteOpsLinkIn, actor: SuperAdminUser, session: SessionDep
) -> SiteOpsLinkOut:
    """One-shot provisioning: link, seed checklists, sync the fleet.

    Nothing about this site is reachable in a half-provisioned state — by the
    time this returns 200, the site has a checklist catalogue for its
    declared operating_categories and every vehicle SiteOps knows about.
    """
    site = await sites.link_to_siteops(session, code, payload.siteops_site_id)
    await audit.record(
        session,
        actor_id=actor.id,
        action=AuditAction.site_siteops_linked,
        object_type="site",
        object_id=site.code,
        after={"siteops_site_id": payload.siteops_site_id},
    )
    await session.commit()
    result = site.last_siteops_sync_result or {}
    return SiteOpsLinkOut(
        site=sites.site_out(site),
        created=result.get("created", 0),
        already_present=result.get("already_present", 0),
        variant_backfilled=result.get("variant_backfilled", 0),
        owned_elsewhere=result.get("owned_elsewhere", 0),
        skipped_no_registration=result.get("skipped_no_registration", 0),
    )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend && .venv/bin/pytest tests/test_fleet_sync.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd backend
git add app/models/enums.py app/schemas/site.py app/services/sites.py app/api/sites.py tests/test_fleet_sync.py
git commit -m "Add POST /sites/{code}/siteops-link for atomic site provisioning"
```

---

## Task 6: sync-from-siteops reads the persisted link

**Files:**
- Modify: `backend/app/schemas/site.py:146-150` (drop `FleetSyncIn`)
- Modify: `backend/app/api/sites.py:231-266` (`sync_fleet_from_siteops`)
- Test: `backend/tests/test_fleet_sync.py`

**Interfaces:**
- Consumes: `Site.siteops_site_id` (Task 1), `sites.load_site` (Task 3).
- Produces: `POST /sites/{code}/vehicles/sync-from-siteops` now takes no request body. This is a breaking API change — the Flutter call site updates in Task 12.

- [ ] **Step 1: Update the existing tests to the new contract**

In `backend/tests/test_fleet_sync.py`, add a helper and update the four existing tests to link the site directly (bypassing the link endpoint's own auto-sync, so each test controls exactly one sync call) instead of passing `siteops_site_id` in the request body:

```python
async def _link_directly(site_code: str, siteops_site_id: str) -> None:
    async with SessionLocal() as session:
        site = await session.get(Site, site_code)
        site.siteops_site_id = siteops_site_id
        await session.commit()
```

Add `from app.models.master import Site, Vehicle` (extend the existing `Vehicle`-only import) if `Site` isn't already imported by this point in the file (Task 5 already needs it — check first).

Change each of `test_sync_creates_vehicles_and_maps_checklist_variant`,
`test_sync_is_idempotent_and_never_overwrites_a_set_variant`,
`test_sync_never_moves_a_vehicle_owned_by_another_site`,
`test_sync_is_manager_only` to call `await _link_directly(<site>, <id>)` before the `client.post(...)`, and drop `json={"siteops_site_id": ...}` from every `client.post(".../sync-from-siteops", ...)` call in this file (keep `headers=h`).

Add a new test:

```python
async def test_sync_rejects_an_unlinked_site(client: AsyncClient) -> None:
    h = await auth_headers(client, SUPER_ADMIN)
    r = await client.post("/sites/MBMT/vehicles/sync-from-siteops", headers=h)
    assert r.status_code == 409, r.text
```

(This assumes the seeded `MBMT` fixture site has no `siteops_site_id` by default — confirm by grepping `scripts/seed.py` for `MBMT`; if it does set one, use a different unlinked seeded site code instead.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd backend && .venv/bin/pytest tests/test_fleet_sync.py -v`
Expected: FAIL — `test_sync_rejects_an_unlinked_site` 200s instead of 409ing, and the updated tests 422 (extra/missing body field) or otherwise mismatch the still-old endpoint.

- [ ] **Step 3: Implement**

In `backend/app/schemas/site.py`, delete the `FleetSyncIn` class entirely (keep `FleetSyncOut`).

In `backend/app/api/sites.py`, remove `FleetSyncIn` from the schema import block, then replace `sync_fleet_from_siteops`:

```python
@router.post("/sites/{code}/vehicles/sync-from-siteops", response_model=FleetSyncOut)
async def sync_fleet_from_siteops(
    code: str, user: CurrentUser, session: SessionDep
) -> FleetSyncOut:
    """Mirror SiteOps' vehicle master into this site's local fleet.

    Reads the SiteOps link stored on the site — the client no longer
    supplies it, so it can't drift from whatever
    POST /sites/{code}/siteops-link actually recorded.
    """
    site_code = assert_site_admin(user, code)
    site = await sites.load_site(session, site_code)
    if site.siteops_site_id is None:
        raise Conflict(f"{site_code} is not linked to SiteOps", {"site": "not linked"})

    result = await masters.sync_vehicles_from_siteops(
        session, site_code, site.siteops_site_id
    )
    site.last_siteops_sync_at = datetime.now(UTC)
    site.last_siteops_sync_result = {
        "created": result.created,
        "already_present": result.already_present,
        "variant_backfilled": result.variant_backfilled,
        "owned_elsewhere": result.owned_elsewhere,
        "skipped_no_registration": result.skipped_no_registration,
    }
    await audit.record(
        session,
        actor_id=user.id,
        action=AuditAction.fleet_synced_from_siteops,
        object_type="site",
        object_id=site_code,
        after={"created": result.created, "variant_backfilled": result.variant_backfilled},
    )
    await session.commit()
    return FleetSyncOut(
        created=result.created,
        already_present=result.already_present,
        variant_backfilled=result.variant_backfilled,
        owned_elsewhere=result.owned_elsewhere,
        skipped_no_registration=result.skipped_no_registration,
    )
```

- [ ] **Step 4: Run tests, run the contract check**

Run: `cd backend && .venv/bin/pytest tests/test_fleet_sync.py -v`
Expected: PASS

Run: `cd backend && ../.venv/bin/python ../tools/check_contract.py` (or `make contract` from the repo root, per the CI job) — expected to now flag the Flutter side still assuming a request body; that flag is resolved in Task 12, not this task. Note the failure and proceed.

- [ ] **Step 5: Commit**

```bash
cd backend
git add app/schemas/site.py app/api/sites.py tests/test_fleet_sync.py
git commit -m "Read SiteOps link from the site row instead of trusting the client"
```

---

## Task 7: Nightly SiteOps fleet sync

**Files:**
- Modify: `backend/app/services/masters.py:1-11` (imports, new `sync_all_linked_sites`)
- Modify: `backend/app/config.py:104-108` (new settings)
- Modify: `backend/app/main.py` (register the job)
- Test: `backend/tests/test_fleet_sync.py`

**Interfaces:**
- Consumes: `masters.sync_vehicles_from_siteops` (existing), `Site.siteops_site_id`/`last_siteops_sync_at`/`last_siteops_sync_result` (Task 1).
- Produces: `masters.sync_all_linked_sites() -> None`, registered as the `siteops_fleet_sync` scheduler job.

- [ ] **Step 1: Write the failing test**

Add to `backend/tests/test_fleet_sync.py`:

```python
async def test_nightly_sync_continues_past_a_failed_site() -> None:
    from app.services import masters as masters_service
    from app.services.siteops import SiteOpsUnavailable

    async def _fake_sync(session, site_code, siteops_site_id):
        if site_code == "BADSITE":
            raise SiteOpsUnavailable("boom")
        from app.services.masters import FleetSyncResult

        return FleetSyncResult(created=1)

    async with SessionLocal() as session:
        session.add(
            Site(
                code="GOODSITE",
                name="Good Site",
                is_active=True,
                siteops_site_id="id-good",
            )
        )
        session.add(
            Site(
                code="BADSITE",
                name="Bad Site",
                is_active=True,
                siteops_site_id="id-bad",
            )
        )
        await session.commit()

    import unittest.mock

    with unittest.mock.patch.object(
        masters_service, "sync_vehicles_from_siteops", _fake_sync
    ):
        await masters_service.sync_all_linked_sites()

    async with SessionLocal() as session:
        good = await session.get(Site, "GOODSITE")
        bad = await session.get(Site, "BADSITE")
        assert good.last_siteops_sync_result["created"] == 1
        assert "error" in bad.last_siteops_sync_result
        assert good.last_siteops_sync_at is not None
        assert bad.last_siteops_sync_at is not None
```

Use `unittest.mock.patch.object` rather than `monkeypatch` here since the fixture is function-scoped and this test has no `monkeypatch` parameter already in scope for a module-level function call from inside `sync_all_linked_sites` (which opens its own sessions) — `monkeypatch.setattr(masters_service, "sync_vehicles_from_siteops", _fake_sync)` works identically if you prefer to add the `monkeypatch` fixture parameter instead; either is fine, pick whichever matches this file's existing style once you check it.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && .venv/bin/pytest tests/test_fleet_sync.py -k nightly -v`
Expected: FAIL with `AttributeError: module 'app.services.masters' has no attribute 'sync_all_linked_sites'`.

- [ ] **Step 3: Implement**

In `backend/app/services/masters.py`, update the imports at the top:

```python
from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import ValidationError
from app.models.master import DefectSource, DefectType, Site, Vehicle
from app.services import siteops
```

Add at the end of the file:

```python
async def sync_all_linked_sites() -> None:
    """Nightly job: refresh every SiteOps-linked site's fleet.

    Mirrors `inspections.run_nightly` — one site's SiteOps outage must not
    stop the rest from syncing. Checklists are not touched here; they only
    change when a site's operating_categories change, which
    `site_config.replace()` already handles synchronously.
    """
    from app.db import SessionLocal
    from app.services.siteops import SiteOpsUnavailable

    async with SessionLocal() as session:
        codes = list(
            (
                await session.scalars(
                    select(Site.code).where(Site.siteops_site_id.is_not(None))
                )
            ).all()
        )

    for code in codes:
        async with SessionLocal() as session:
            site = await session.get(Site, code)
            if site is None or site.siteops_site_id is None:
                continue
            try:
                result = await sync_vehicles_from_siteops(
                    session, site.code, site.siteops_site_id
                )
                site.last_siteops_sync_result = {
                    "created": result.created,
                    "already_present": result.already_present,
                    "variant_backfilled": result.variant_backfilled,
                    "owned_elsewhere": result.owned_elsewhere,
                    "skipped_no_registration": result.skipped_no_registration,
                }
            except SiteOpsUnavailable as e:
                site.last_siteops_sync_result = {"error": str(e)}
            site.last_siteops_sync_at = datetime.now(UTC)
            await session.commit()
```

In `backend/app/config.py`, add after the `odometer_scan_minutes` line:

```python
    # --- siteops fleet sync ---
    siteops_sync_enabled: bool = True
    siteops_sync_hour: int = 23
    siteops_sync_minute: int = 0
```

In `backend/app/main.py`, add `from app.services.masters import sync_all_linked_sites` to the imports, change the scheduler-creation condition to also cover this job:

```python
    if (
        jobs
        or settings.odometer_sync_enabled
        or settings.schedule_generator_enabled
        or settings.siteops_sync_enabled
    ):
        scheduler = AsyncIOScheduler(timezone=settings.timezone)
```

and add the job registration after the `dmr_snapshot` block, before `if scheduler: scheduler.start()`:

```python
    if scheduler and settings.siteops_sync_enabled:
        scheduler.add_job(
            sync_all_linked_sites,
            CronTrigger(
                hour=settings.siteops_sync_hour,
                minute=settings.siteops_sync_minute,
                timezone=settings.timezone,
            ),
            id="siteops_fleet_sync",
            max_instances=1,
            coalesce=True,
        )
        logger.info(
            "SiteOps fleet sync daily at %02d:%02d %s",
            settings.siteops_sync_hour,
            settings.siteops_sync_minute,
            settings.timezone,
        )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend && .venv/bin/pytest tests/test_fleet_sync.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd backend
git add app/services/masters.py app/config.py app/main.py tests/test_fleet_sync.py
git commit -m "Add a nightly job that refreshes every SiteOps-linked site's fleet"
```

---

## Task 8: Remediation — list placeholder-named sites

**Files:**
- Modify: `backend/app/services/sites.py` (new `placeholder_named_sites`)
- Modify: `backend/app/api/sites.py` (new route)
- Test: `backend/tests/test_sites.py`

**Interfaces:**
- Produces: `GET /sites/remediation/placeholder-names` (super admin), `sites.placeholder_named_sites(session) -> list[Site]`.

- [ ] **Step 1: Write the failing test**

Add to `backend/tests/test_sites.py`:

```python
async def test_remediation_lists_only_placeholder_named_sites(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client, SUPER_ADMIN)
    async with SessionLocal() as session:
        session.add(Site(code="GHOST1", name="Site GHOST1", is_active=True))
        session.add(Site(code="REAL1", name="Actual Depot Name", is_active=True))
        await session.commit()

    r = await client.get("/sites/remediation/placeholder-names", headers=h)
    assert r.status_code == 200, r.text
    codes = {s["code"] for s in r.json()["items"]}
    assert "GHOST1" in codes
    assert "REAL1" not in codes


async def test_remediation_is_super_admin_only(client: AsyncClient) -> None:
    h = await auth_headers(client, "TV4102")
    r = await client.get("/sites/remediation/placeholder-names", headers=h)
    assert r.status_code == 403
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && .venv/bin/pytest tests/test_sites.py -k remediation -v`
Expected: FAIL with 404 (route doesn't exist).

- [ ] **Step 3: Implement**

In `backend/app/services/sites.py`, add (near the top, after the imports — `re` is already imported from Task 3):

```python
_PLACEHOLDER_NAME = re.compile(r"^Site [A-Z0-9]{1,8}$")


async def placeholder_named_sites(session: AsyncSession) -> list[Site]:
    """Every site whose name still matches load_site's old auto-generated
    placeholder — a site silently conjured before this fix shipped, never
    renamed by an admin since.
    """
    rows = list((await session.scalars(select(Site).order_by(Site.code))).all())
    return [s for s in rows if _PLACEHOLDER_NAME.match(s.name)]
```

In `backend/app/api/sites.py`, add the route after `list_sites`:

```python
@router.get("/sites/remediation/placeholder-names", response_model=SiteList)
async def list_placeholder_named_sites(
    _actor: SuperAdminUser, session: SessionDep
) -> SiteList:
    """Read-only: sites still carrying load_site's old auto-generated name.

    Fix each by hand — rename, set operating_categories if it differs from
    the default, then POST .../siteops-link with the matching SiteOps id.
    """
    rows = await sites.placeholder_named_sites(session)
    vehicles, users = await sites.rollups(session, [s.code for s in rows])
    return SiteList(
        items=[
            sites.site_out(s, vehicles.get(s.code, 0), users.get(s.code, 0))
            for s in rows
        ]
    )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend && .venv/bin/pytest tests/test_sites.py -v`
Expected: PASS

- [ ] **Step 5: Run the full backend suite and contract check**

Run: `cd backend && make lint-backend && make test-backend`
Run: `cd backend && make contract` (or the repo-root equivalent) — this must now be fully clean on the backend side; any remaining failure should be exactly the Flutter `FleetSyncIn` body mismatch, resolved in Task 12.

- [ ] **Step 6: Commit**

```bash
cd backend
git add app/services/sites.py app/api/sites.py tests/test_sites.py
git commit -m "Add a read-only remediation listing for placeholder-named sites"
```

---

## Task 9: Flutter — Site model, SiteRepository.linkToSiteOps, fakes

**Files:**
- Modify: `app/lib/models/site.dart`
- Modify: `app/lib/data/repositories.dart:27-47` (`SiteRepository`)
- Modify: `app/lib/data/api/api_repositories.dart:262-314` (`ApiSiteRepository`)
- Modify: `app/test/support/fake_site_repositories.dart`
- Modify: `app/lib/state/sites.dart:62-125` (`SitesController`)
- Test: `app/test/state/sites_controller_test.dart` (check whether this file already exists — if not, check `app/test/` for the existing convention on where `SitesController` is tested today and add to that file instead of creating a new one)

**Interfaces:**
- Produces: `Site.siteopsSiteId: String?`; `SiteRepository.linkToSiteOps(String code, String siteopsSiteId) -> Future<Site>`; `SitesController.linkToSiteOps(String code, String siteopsSiteId) -> Future<Site>`. Task 10's UI calls the controller method.

- [ ] **Step 1: Write the failing test**

First run `grep -rl "SitesController\|sitesAdminProvider" app/test/` to find the existing test file for site admin behavior, and add this test there (matching that file's existing `fakeContainer()`/`ProviderContainer` setup style):

```dart
test('linkToSiteOps persists the siteops id on the site', () async {
  final container = fakeContainer();
  await container.read(sitesAdminProvider.future); // load initial list

  final updated = await container
      .read(sitesAdminProvider.notifier)
      .linkToSiteOps('MBMT', 'siteops-uuid-test');

  expect(updated.siteopsSiteId, 'siteops-uuid-test');
  final list = container.read(sitesAdminProvider).valueOrNull ?? const [];
  expect(
    list.firstWhere((s) => s.code == 'MBMT').siteopsSiteId,
    'siteops-uuid-test',
  );
});
```

If no such file exists, create `app/test/state/sites_controller_test.dart` following the import/setup pattern of a sibling controller test (check `app/test/state/` for one, e.g. a vehicles controller test, and mirror its imports and `fakeContainer` usage exactly).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test <the test file path> --plain-name "linkToSiteOps"`
Expected: FAIL — `linkToSiteOps` doesn't exist on `SiteRepository`/`SitesController` yet.

- [ ] **Step 3: Implement**

In `app/lib/models/site.dart`, add the field, constructor parameter, `copyWith`, `toJson`, `fromJson`:

```dart
  const Site({
    required this.code,
    required this.name,
    required this.isActive,
    this.timezone = 'Asia/Kolkata',
    this.address = '',
    this.commissionedOn,
    this.vehicleCount = 0,
    this.userCount = 0,
    this.siteopsSiteId,
  });

  // ... existing fields ...

  /// The linked SiteOps site's own id. Null means this site is manual-only
  /// — no vehicle sync, no nightly refresh.
  final String? siteopsSiteId;
```

```dart
  Site copyWith({
    String? name,
    bool? isActive,
    String? timezone,
    String? address,
    String? commissionedOn,
    int? vehicleCount,
    int? userCount,
    bool clearCommissionedOn = false,
    String? siteopsSiteId,
  }) {
    return Site(
      code: code,
      name: name ?? this.name,
      isActive: isActive ?? this.isActive,
      timezone: timezone ?? this.timezone,
      address: address ?? this.address,
      commissionedOn:
          clearCommissionedOn ? null : (commissionedOn ?? this.commissionedOn),
      vehicleCount: vehicleCount ?? this.vehicleCount,
      userCount: userCount ?? this.userCount,
      siteopsSiteId: siteopsSiteId ?? this.siteopsSiteId,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'code': code,
        'name': name,
        'is_active': isActive,
        'timezone': timezone,
        'address': address,
        'commissioned_on': commissionedOn,
        'siteops_site_id': siteopsSiteId,
      };

  factory Site.fromJson(Map<String, dynamic> json) => Site(
        code: json['code'] as String,
        name: json['name'] as String,
        isActive: json['is_active'] as bool? ?? true,
        timezone: json['timezone'] as String? ?? 'Asia/Kolkata',
        address: json['address'] as String? ?? '',
        commissionedOn: json['commissioned_on'] as String?,
        vehicleCount: json['vehicle_count'] as int? ?? 0,
        userCount: json['user_count'] as int? ?? 0,
        siteopsSiteId: json['siteops_site_id'] as String?,
      );
```

In `app/lib/data/repositories.dart`, add to `SiteRepository`:

```dart
  /// Explicit, one-shot: links this site to a SiteOps site, seeds its
  /// checklist catalogue, and syncs its fleet — all server-side, atomically.
  Future<Site> linkToSiteOps(String code, String siteopsSiteId);
```

In `app/lib/data/api/api_repositories.dart`, add to `ApiSiteRepository`:

```dart
  @override
  Future<Site> linkToSiteOps(String code, String siteopsSiteId) async {
    final json = await _api.post(
      '/sites/$code/siteops-link',
      body: {'siteops_site_id': siteopsSiteId},
    );
    final body = json as Map<String, dynamic>;
    return Site.fromJson(body['site'] as Map<String, dynamic>);
  }
```

In `app/test/support/fake_site_repositories.dart`, add to `FakeSiteRepository`:

```dart
  @override
  Future<Site> linkToSiteOps(String code, String siteopsSiteId) async {
    await Future<void>.delayed(_latency);
    final i = _store.sites.indexWhere((s) => s.code == code);
    if (i == -1) throw ApiException('Site $code not found');
    final updated = _store.sites[i].copyWith(siteopsSiteId: siteopsSiteId);
    _store.sites[i] = updated;
    return updated;
  }
```

In `app/lib/state/sites.dart`, add to `SitesController`:

```dart
  Future<Site> linkToSiteOps(String code, String siteopsSiteId) async {
    final saved = await _repo.linkToSiteOps(code, siteopsSiteId);
    _patch((list) => list.map((s) => s.code == saved.code ? saved : s).toList());
    ref.invalidate(sitesProvider);
    return saved;
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd app && flutter test <the test file path>`
Expected: PASS

Run: `cd app && flutter analyze` — must be clean (every `SiteRepository` implementer now has to implement `linkToSiteOps`; confirm no other implementer besides `ApiSiteRepository`/`FakeSiteRepository` exists via `grep -rn "implements SiteRepository" app/`).

- [ ] **Step 5: Commit**

```bash
cd app
git add lib/models/site.dart lib/data/repositories.dart lib/data/api/api_repositories.dart test/support/fake_site_repositories.dart lib/state/sites.dart test/
git commit -m "Add SiteRepository.linkToSiteOps and persist siteopsSiteId on Site"
```

---

## Task 10: Flutter — "Link to SiteOps" action in the Sites admin pane

**Files:**
- Modify: `app/lib/screens/admin/sites_pane.dart`

**Interfaces:**
- Consumes: `SitesController.linkToSiteOps` (Task 9), `siteOpsClientProvider` (existing).

- [ ] **Step 1: Write the failing test**

Add a widget test (create `app/test/screens/sites_pane_test.dart` if no such file exists — check `app/test/screens/` for the convention first and mirror it):

```dart
testWidgets('site row shows a Link SiteOps action and an unlinked badge', (
  tester,
) async {
  final store = FakeStore.seeded();
  final container = fakeContainer(store);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: SitesPane())),
    ),
  );
  await tester.pumpAndSettle();

  expect(find.text('Link SiteOps'), findsWidgets);
});
```

Adjust `FakeStore.seeded()` / widget wiring to match whatever helper this test directory already uses for other admin-pane widget tests — check an existing one (e.g. a fleet or master-data pane test) and copy its setup exactly.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/screens/sites_pane_test.dart`
Expected: FAIL — no "Link SiteOps" text in the tree yet.

- [ ] **Step 3: Implement**

In `app/lib/screens/admin/sites_pane.dart`, add a link handler to `_SitesPaneState`:

```dart
  Future<void> _link(Site site) async {
    final siteopsId = await showDialog<String>(
      context: context,
      builder: (ctx) => _SiteOpsPickerDialog(ref: ref),
    );
    if (siteopsId == null || siteopsId.isEmpty) return;

    try {
      final linked = await ref
          .read(sitesAdminProvider.notifier)
          .linkToSiteOps(site.code, siteopsId);
      if (!mounted) return;
      ref.read(toastProvider.notifier).show(
            '${linked.code} linked to SiteOps — ${linked.vehicleCount} '
            'vehicles synced',
          );
    } on ApiException catch (e) {
      if (mounted) ref.read(toastProvider.notifier).show(e.message);
    }
  }
```

Pass it down to `_SiteRow` in the `build` method:

```dart
                _SiteRow(
                  site: s,
                  onEdit: () => _open(SiteDraft.fromSite(s)),
                  onToggle: () => _toggle(s),
                  onLink: () => _link(s),
                ),
```

In `_SiteRow`, add the `onLink` field and render the button plus a linked/unlinked badge:

```dart
class _SiteRow extends ConsumerWidget {
  const _SiteRow({
    required this.site,
    required this.onEdit,
    required this.onToggle,
    required this.onLink,
  });

  final Site site;
  final VoidCallback onEdit;
  final VoidCallback onToggle;
  final VoidCallback onLink;
```

Add a badge next to the existing `NOT COMMISSIONED`/`INACTIVE` ones:

```dart
                if (site.siteopsSiteId == null)
                  const TagBadge(
                    label: 'NOT LINKED TO SITEOPS',
                    background: T.amberTint,
                    foreground: T.amber,
                  ),
```

Add the action button next to `Edit`/`Deactivate`:

```dart
                const SizedBox(width: 8),
                OutlineActionButton(
                  label: site.siteopsSiteId == null ? 'Link SiteOps' : 'Re-sync',
                  onPressed: onLink,
                  accent: T.green,
                  fontSize: 12.5,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
                ),
```

Add the picker dialog at the bottom of the file:

```dart
class _SiteOpsPickerDialog extends StatefulWidget {
  const _SiteOpsPickerDialog({required this.ref});

  final WidgetRef ref;

  @override
  State<_SiteOpsPickerDialog> createState() => _SiteOpsPickerDialogState();
}

class _SiteOpsPickerDialogState extends State<_SiteOpsPickerDialog> {
  late final Future<List<Map<String, dynamic>>> _sitesFuture = _load();

  Future<List<Map<String, dynamic>>> _load() async {
    final json =
        await widget.ref.read(siteOpsClientProvider).get('/onboarding/sites/dropdown');
    final data = (json is Map ? json['data'] : json) as List<dynamic>? ?? const [];
    return data.cast<Map<String, dynamic>>();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: T.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text('Link to SiteOps', style: AppText.sans(size: 17, weight: FontWeight.w700)),
      content: SizedBox(
        width: 360,
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _sitesFuture,
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator(color: T.green)),
              );
            }
            final rows = snapshot.data!;
            if (rows.isEmpty) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Text('No SiteOps sites available.'),
              );
            }
            return SizedBox(
              height: 320,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: rows.length,
                itemBuilder: (context, i) {
                  final row = rows[i];
                  final id = row['id']?.toString() ?? '';
                  final name = row['name']?.toString() ?? id;
                  return ListTile(
                    title: Text(name, style: AppText.sans(size: 14)),
                    subtitle: Text(id, style: AppText.mono(size: 11, color: T.muted)),
                    onTap: () => Navigator.of(context).pop(id),
                  );
                },
              ),
            );
          },
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Cancel', style: AppText.sans(size: 14, color: T.secondary)),
        ),
      ],
    );
  }
}
```

Add `import '../../data/api/siteops_client.dart';` if `siteOpsClientProvider` isn't already resolvable from an existing import in this file (check first — it may already be re-exported via `state/providers.dart`).

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd app && flutter test test/screens/sites_pane_test.dart`
Expected: PASS

Run: `cd app && flutter analyze`
Expected: clean

- [ ] **Step 5: Commit**

```bash
cd app
git add lib/screens/admin/sites_pane.dart test/
git commit -m "Add a Link to SiteOps action to the sites admin pane"
```

---

## Task 11: Flutter — operating_categories on SiteConfig, docking pane control

**Files:**
- Modify: `app/lib/models/site_config.dart`
- Modify: `app/lib/screens/site/docking_pane.dart:611-699` (`_Parameters`)

**Interfaces:**
- Produces: `SiteConfig.operatingCategories: List<String>`, mirroring the backend field name from Task 4.

- [ ] **Step 1: Write the failing test**

Check `app/test/models/` (or wherever `SiteConfig` round-trip tests currently live — `grep -rl "class SiteConfig" app/test/` if unsure) and add:

```dart
test('SiteConfig round-trips operating_categories through JSON', () {
  final config = SiteConfig(
    siteCode: 'MBMT',
    operatingCategories: const ['bus', 'truck'],
  );
  final json = config.toJson();
  expect(json['operating_categories'], ['bus', 'truck']);

  final restored = SiteConfig.fromJson(json);
  expect(restored.operatingCategories, ['bus', 'truck']);
});
```

Adjust the constructor call to match `SiteConfig`'s actual required-field set (check its constructor signature first — `reminderLeadKm` etc. likely have defaults already, per the `this.reminderLeadKm = 500` pattern seen elsewhere in the file).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test <that test file> --plain-name "operating_categories"`
Expected: FAIL — no such constructor parameter.

- [ ] **Step 3: Implement**

In `app/lib/models/site_config.dart`, add to `SiteConfig`: a constructor parameter `this.operatingCategories = const ['bus']`, a field `final List<String> operatingCategories;`, a `copyWith` parameter/assignment `operatingCategories: operatingCategories ?? this.operatingCategories`, a `toJson` entry `'operating_categories': operatingCategories,`, and a `fromJson` entry:

```dart
        operatingCategories:
            (json['operating_categories'] as List<dynamic>?)
                    ?.map((e) => e as String)
                    .toList() ??
                const ['bus'],
```

(Match the exact surrounding style already used for `reminderLeadKm`/`odometerSync` at each of these four spots — constructor, field, `copyWith`, `toJson`, `fromJson`.)

In `app/lib/screens/site/docking_pane.dart`, add a categories editor to `_Parameters`. Below the existing `rows`-driven `Wrap`/`LayoutBuilder` block (after its closing `),` and before the `],`/closing of `Column`'s `children`), add:

```dart
          const SizedBox(height: 14),
          Text('Operations', style: AppText.sectionTitle),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: <String>['bus', 'truck'].map((category) {
              final selected = config.operatingCategories.contains(category);
              return FilterChip(
                label: Text(category, style: AppText.sans(size: 13)),
                selected: selected,
                onSelected: editing
                    ? (value) => controller.update((c) {
                          final next = List<String>.from(c.operatingCategories);
                          if (value) {
                            if (!next.contains(category)) next.add(category);
                          } else {
                            next.remove(category);
                          }
                          return c.copyWith(operatingCategories: next);
                        })
                    : null,
              );
            }).toList(),
          ),
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd app && flutter test <that test file>`
Expected: PASS

Run: `cd app && flutter analyze`
Expected: clean

- [ ] **Step 5: Commit**

```bash
cd app
git add lib/models/site_config.dart lib/screens/site/docking_pane.dart test/
git commit -m "Add operating_categories to the SiteConfig model and docking pane"
```

---

## Task 12: Flutter — Vehicle Master sync button drops siteops_site_id

**Files:**
- Modify: `app/lib/screens/vehicle_master_screen.dart:597-624` (`_syncFleetFromSiteOps`)

**Interfaces:**
- Consumes: `POST /sites/{code}/vehicles/sync-from-siteops` with no body (Task 6).

- [ ] **Step 1: Write the failing test**

Check `app/test/screens/` for an existing `vehicle_master_screen_test.dart`. If a test already exercises `_syncFleetFromSiteOps`'s request shape via a fake/mock `ApiClient`, update its expectation to assert no body is sent; if none exists, skip to Step 3 — this is a small, low-risk deletion and the contract check (Step 4) is the real safety net here.

- [ ] **Step 2: N/A if no existing test covers this call**

- [ ] **Step 3: Implement**

In `app/lib/screens/vehicle_master_screen.dart`, update `_syncFleetFromSiteOps`:

```dart
  Future<void> _syncFleetFromSiteOps(SelectedSiteState site) async {
    final enmSite = ref.read(sessionProvider).site;
    if (enmSite.isEmpty) return;

    setState(() => _syncing = true);
    try {
      final json = await ref
          .read(apiClientProvider)
          .post('/sites/$enmSite/vehicles/sync-from-siteops');
      final r = json as Map<String, dynamic>;
      final created = r['created'] as int? ?? 0;
      final backfilled = r['variant_backfilled'] as int? ?? 0;
      _toast(created == 0 && backfilled == 0
          ? 'Fleet already up to date.'
          : 'Synced: $created new, $backfilled checklist variant(s) filled in.');
      ref.invalidate(siteVehiclesProvider);
      unawaited(_fetch(site.id));
    } catch (e) {
      _toast(e.toString().replaceAll('Exception: ', ''), isError: true);
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }
```

(The old code guarded on `site.id` being non-null/non-empty before calling; that guard is no longer meaningful since the server resolves the SiteOps id itself. A site that isn't linked now surfaces the server's 409 "not linked to SiteOps" through the existing `catch (e)` branch, which is the more accurate error path than silently returning.)

- [ ] **Step 4: Verify against the contract check**

Run: `cd backend && make contract` (or the repo-root equivalent)
Expected: clean — this was the failure flagged as expected in Task 6, Step 4; it should be resolved now.

Run: `cd app && flutter analyze`
Expected: clean

- [ ] **Step 5: Commit**

```bash
cd app
git add lib/screens/vehicle_master_screen.dart
git commit -m "Drop siteops_site_id from the manual fleet sync request body"
```

---

## Task 13: Flutter — delete fuzzy SiteOps-id resolution

**Files:**
- Modify: `app/lib/data/api/api_repositories.dart:90-203` (`ApiMasterDataRepository`)
- Modify: `app/lib/state/providers.dart:214-258` (`technicianStaffProvider`, `supervisorStaffProvider`, `mechanicStaffProvider`)
- Test: `app/test/` — the repository test covering `technicianStaff`/`supervisorStaff`/`mechanicStaff`, if one exists (`grep -rl "technicianStaff\|_resolveSiteOpsSiteId" app/test/`); otherwise this task relies on `flutter analyze` plus the manual verification in Task 14.

**Interfaces:**
- Consumes: `Site.siteopsSiteId` (Task 9), returned by `GET /sites` and therefore available wherever the currently-selected `Site` object is held.
- Removes: `ApiMasterDataRepository._resolveSiteOpsSiteId`.

- [ ] **Step 1: Write the failing test (if a fixture test exists)**

If `grep -rl "_resolveSiteOpsSiteId\|technicianStaff" app/test/` finds an existing test asserting the fuzzy-match fallback behavior, that test needs to be deleted or rewritten to assert the method now requires a non-empty `siteId` and throws/returns empty otherwise — do that first, matching this file's existing conventions, then proceed. If no such test exists, skip to Step 2.

- [ ] **Step 2: Run to confirm current behavior (baseline)**

Run: `cd app && flutter test <whichever test file, if any>`
Note the current pass/fail state before changing anything.

- [ ] **Step 3: Implement**

In `app/lib/data/api/api_repositories.dart`, delete the `_resolveSiteOpsSiteId` method entirely (`app/lib/data/api/api_repositories.dart:185-203`), then simplify `technicianStaff`, `supervisorStaff`, `mechanicStaff` to require the id directly instead of falling back to it:

```dart
  @override
  Future<List<String>> technicianStaff({required String siteName, String? siteId}) async {
    if (siteId == null || siteId.isEmpty) return const <String>[];
    try {
      final json = await siteOpsClient.get(
        '/users/',
        query: <String, String>{
          'page': '1',
          'page_size': '100',
          'pagination': 'false',
          'is_active': 'true',
          'site_id': siteId,
          'role_id': _technicianRoleId,
        },
      );
      final data = (json is Map ? json['data'] : json) as List<dynamic>? ?? [];
      return data
          .map((j) => (j as Map<String, dynamic>)['full_name']?.toString() ?? '')
          .where((v) => v.isNotEmpty)
          .toList();
    } catch (_) {
      return const <String>[];
    }
  }
```

Apply the same shape (drop the `_resolveSiteOpsSiteId` fallback branch, keep the rest identical) to `supervisorStaff` and `mechanicStaff`.

In `app/lib/state/providers.dart`, update the three providers to source `siteOpsSiteId` from the currently selected `Site`'s persisted field instead of `selectedSiteProvider`'s live state:

```dart
final technicianStaffProvider = FutureProvider<List<String>>((ref) async {
  final repo = ref.watch(masterDataRepositoryProvider);
  final siteName = ref.watch(sessionProvider.select((s) => s.site));
  final sites = ref.watch(sitesAdminProvider).valueOrNull ?? const <Site>[];
  final siteOpsSiteId =
      sites.firstWhereOrNull((s) => s.code == siteName)?.siteopsSiteId ?? '';
  if (siteName.isEmpty) return const <String>[];

  try {
    return await repo.technicianStaff(siteName: siteName, siteId: siteOpsSiteId);
  } catch (_) {
    return const <String>[];
  }
});
```

Apply the same `sites.firstWhereOrNull((s) => s.code == siteName)?.siteopsSiteId ?? ''` substitution to `supervisorStaffProvider` and `mechanicStaffProvider`, replacing their `ref.watch(selectedSiteProvider.select((s) => s.id)) ?? ''` line. Add `import 'package:collection/collection.dart';` at the top of `providers.dart` for `firstWhereOrNull` if it isn't already imported (check first — this package is likely already a dependency given Riverpod's own usage patterns in this codebase; verify via `app/pubspec.yaml`). If `sitesAdminProvider` isn't appropriate here (e.g. a non-admin user's `MasterData` load shouldn't depend on the admin-only sites list), use `ref.watch(sitesProvider)` instead — check which provider actually holds the general (non-admin-gated) site list with `siteopsSiteId` populated, by grepping for where `GET /sites` backs a non-admin-facing provider, and use that one.

Leave the `masterDataProvider`'s own `siteOpsSiteId`-based `vehicleNumbers` call (`app/lib/state/providers.dart:190-192`) untouched — that one keys off the site switcher's live SiteOps id for a different reason (matching SiteOps' own vehicle listing UUIDs) and is out of scope for this plan.

- [ ] **Step 4: Run tests and analyzer**

Run: `cd app && flutter test` (full suite)
Run: `cd app && flutter analyze`
Expected: both clean.

- [ ] **Step 5: Commit**

```bash
cd app
git add lib/data/api/api_repositories.dart lib/state/providers.dart
git commit -m "Use the persisted SiteOps link instead of fuzzy name-matching for staff lookups"
```

---

## Task 14: Full-suite verification and manual browser check

**Files:** none (verification only).

- [ ] **Step 1: Full backend suite**

Run: `cd backend && make check`
Expected: all backend tests, linters, and contract checks pass (per `PENDING.md`'s baseline: "240 backend tests... Runs in about four minutes" — this count will now be higher).

- [ ] **Step 2: Full app suite**

Run: `cd app && make lint-app && make test-app && make build-app`
Expected: pass.

- [ ] **Step 3: Migration round-trip**

Run: `cd backend && .venv/bin/python -m alembic downgrade base && .venv/bin/python -m alembic upgrade head`
Expected: exits 0.

- [ ] **Step 4: Manual browser verification (per CLAUDE.md's testing expectation)**

Run: `cd backend && docker compose up -d` (fresh local stack, `SEED_ON_START=true`), then `cd app && flutter run -d chrome`.

Drive, in a browser:
1. As the bootstrap super admin, onboard a new site (`POST /sites` via the "+ Onboard site" form).
2. Link it to a SiteOps site via the new "Link SiteOps" action. Confirm the toast reports vehicles synced, and that Vehicle Master shows them without a second click.
3. Open the site's Docking pane; confirm the D.I./10-day checklist is populated with no separate action (`operating_categories` defaulted to `["bus"]`).
4. Flip on a fake/test-only `"truck"` category in the Docking pane's Operations chips and save; confirm no crash (there is no real truck catalogue yet, so 0 templates is the correct outcome — the plumbing is what's under test, not content).
5. Try creating a vehicle manually on the now-linked site; confirm it's rejected with the "linked to SiteOps" message.
6. As super admin, visit the sites admin pane and confirm a site's `NOT LINKED TO SITEOPS` badge / `Link SiteOps` vs `Re-sync` label toggles correctly.

- [ ] **Step 5: Confirm this satisfies the spec's non-goals**

Re-read `docs/superpowers/specs/2026-08-26-site-siteops-architecture-design.md`'s "Non-goals" section — verify nothing in this plan accidentally added `Vehicle.category` or real truck checklist content. If it did, that's a scope violation to back out before calling this done.

No commit for this task — it's verification of Tasks 1–13.
