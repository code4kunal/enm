from __future__ import annotations

import os

os.environ.setdefault(
    "DATABASE_URL",
    os.environ.get(
        "TEST_DATABASE_URL", "postgresql+asyncpg://enm:enm@localhost:5433/enm_test"
    ),
)
os.environ.setdefault("JWT_SECRET", "test-secret")
os.environ.setdefault("NOTIFICATIONS_ENABLED", "true")
os.environ.setdefault("BREAKDOWN_SLA_ENABLED", "false")
os.environ.setdefault("MEDIA_ROOT", "/tmp/enm-test-media")
os.environ.setdefault("ENM_FEED_TOKEN", "test-feed-token")

from collections.abc import AsyncIterator  # noqa: E402

import pytest  # noqa: E402
from httpx import ASGITransport, AsyncClient  # noqa: E402

from app.db import SessionLocal, engine  # noqa: E402
from app.main import app  # noqa: E402
from app.models import Base  # noqa: E402
from app.models.enums import Role  # noqa: E402
from app.models.master import DefectSource, DefectType, Site, Vehicle  # noqa: E402
from app.models.user import User, UserSiteAccess  # noqa: E402
from app.security import hash_password  # noqa: E402

PASSWORD = "Test@1234"
#: The seeded super admin, which reaches every site without a grant.
SUPER_ADMIN = "TV1001"


@pytest.fixture(scope="session", autouse=True)
async def _schema() -> AsyncIterator[None]:
    from sqlalchemy import text

    async with engine.begin() as conn:
        await conn.execute(text("CREATE EXTENSION IF NOT EXISTS pg_trgm"))
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)
        await conn.execute(
            text(
                "CREATE INDEX IF NOT EXISTS ix_entries_search_text_trgm "
                "ON entries USING gin (search_text gin_trgm_ops)"
            )
        )
    yield
    await engine.dispose()


@pytest.fixture(autouse=True)
async def _clean() -> AsyncIterator[None]:
    """Truncate between tests so each one starts from the seeded baseline."""
    from sqlalchemy import text

    async with engine.begin() as conn:
        await conn.execute(
            text(
                "TRUNCATE audit_logs, notifications, device_tokens, refresh_tokens, "
                "work_done_entries, coolant_entries, driver_complaint_entries, "
                "breakdown_entries, pm_schedule_entries, "
                "job_card_recon_exceptions, job_card_components, job_cards, "
                "sap_materials, entries, "
                "fitted_units, unit_types, off_road_cases, breakdown_investigations, "
                "dmr_days, inspection_results, inspection_entries, checklist_items, "
                "checklist_templates, alerts, inspection_slots, inspection_plans, "
                "work_types, "
                "site_import_runs, site_import_mappings, site_import_profiles, "
                "service_plans, shift_windows, site_configs, odometer_readings, "
                "user_site_access, users, vehicles, defect_sources, defect_types, "
                "sync_cursors, "
                "sites RESTART IDENTITY CASCADE"
            )
        )
    await _seed()
    yield


async def _seed() -> None:
    async with SessionLocal() as session:
        session.add_all(
            [
                Site(code="MBMT", name="Mira Bhayandar"),
                Site(code="UMT", name="Ulhasnagar"),
                Site(code="TDC", name="Thane Site"),
            ]
        )
        await session.flush()
        session.add_all(
            [
                Vehicle(
                    registration_no="MH40LY1894",
                    site_code="MBMT",
                    sap_equipment_no="EQ-1894",
                ),
                Vehicle(registration_no="MH40LY1895", site_code="MBMT"),
                Vehicle(
                    registration_no="MH40LY9999", site_code="MBMT", is_active=False
                ),
                Vehicle(registration_no="MH05GX4410", site_code="UMT"),
            ]
        )
        session.add_all(
            [
                DefectSource(name="Driver report", sort_order=0),
                DefectSource(name="Breakdown", sort_order=1),
            ]
        )
        session.add_all(
            [
                DefectType(name="Brakes & air system", sort_order=0),
                DefectType(name="Electrical / HV", sort_order=1),
            ]
        )
        session.add_all(
            [
                User(
                    name="Kunal Saxena",
                    user_id="TV1001",
                    role=Role.super_admin,
                    password_hash=hash_password(PASSWORD),
                    # A super admin's site_access is empty and ignored.
                    site_links=[],
                ),
                User(
                    name="Rahul Sharma",
                    user_id="TV4021",
                    email="rahul.sharma@transvolt.in",
                    role=Role.manager,
                    password_hash=hash_password(PASSWORD),
                    site_links=[
                        UserSiteAccess(site_code="MBMT"),
                        UserSiteAccess(site_code="UMT"),
                    ],
                ),
                User(
                    name="Sanjay Pawar",
                    user_id="TV4102",
                    role=Role.supervisor,
                    password_hash=hash_password(PASSWORD),
                    site_links=[UserSiteAccess(site_code="MBMT")],
                ),
                User(
                    name="Sunil Patil",
                    user_id="TV4105",
                    role=Role.executive,
                    password_hash=hash_password(PASSWORD),
                    site_links=[UserSiteAccess(site_code="MBMT")],
                ),
                # app.services.streams.SYSTEM_USER_ID — attributes entries
                # ingested from fleet-streams, which has no human to name.
                # Inactive and password-less: it never logs in.
                User(
                    name="fleet-streams",
                    user_id="FLEETSTREAMS",
                    role=Role.executive,
                    password_hash=None,
                    is_active=False,
                    site_links=[],
                ),
            ]
        )
        await session.commit()


@pytest.fixture
async def client() -> AsyncIterator[AsyncClient]:
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test/api/v1"
    ) as c:
        yield c


async def login(client: AsyncClient, user_id: str = "TV4021") -> str:
    resp = await client.post(
        "/auth/login", json={"user_id": user_id, "password": PASSWORD}
    )
    assert resp.status_code == 200, resp.text
    return resp.json()["access_token"]


async def auth_headers(client: AsyncClient, user_id: str = "TV4021") -> dict[str, str]:
    return {"Authorization": f"Bearer {await login(client, user_id)}"}
