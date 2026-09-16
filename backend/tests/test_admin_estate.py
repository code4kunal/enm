"""Admin estate summary and audit trail."""

from __future__ import annotations

from httpx import AsyncClient

from tests.conftest import SUPER_ADMIN, auth_headers


async def test_summary_is_super_admin_only(client: AsyncClient) -> None:
    manager = await auth_headers(client, "TV4021")
    r = await client.get("/admin/summary", headers=manager)
    assert r.status_code == 403

    h = await auth_headers(client, SUPER_ADMIN)
    r = await client.get("/admin/summary", params={"period": "today"}, headers=h)
    assert r.status_code == 200, r.text
    body = r.json()
    assert "estate" in body and "sites" in body and "segments" in body
    assert "bus" in body["segments"] and "truck" in body["segments"]
    assert "work_done" in body["estate"]
    assert "driver_complaints" in body["estate"]
    assert "inspections" in body["estate"]
    assert "open_off_road" in body["estate"]


async def test_audit_lists_and_filters(client: AsyncClient) -> None:
    h = await auth_headers(client, SUPER_ADMIN)
    # Creating a user writes an audit row.
    created = await client.post(
        "/admin/users",
        json={
            "name": "Audit Probe",
            "user_id": "TV8801",
            "role": "executive",
            "site_access": ["MBMT"],
            "temp_password": "Temp@1234",
        },
        headers=h,
    )
    assert created.status_code == 201, created.text

    r = await client.get("/admin/audit", params={"page_size": 20}, headers=h)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["total"] >= 1
    assert any(i["action"] for i in body["items"])

    export = await client.get("/admin/audit/export", headers=h)
    assert export.status_code == 200
    assert "text/csv" in export.headers.get("content-type", "")
    assert "actor_user_id" in export.text


async def test_audit_is_super_admin_only(client: AsyncClient) -> None:
    manager = await auth_headers(client, "TV4021")
    r = await client.get("/admin/audit", headers=manager)
    assert r.status_code == 403
