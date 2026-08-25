from __future__ import annotations

from httpx import AsyncClient

from tests.conftest import SUPER_ADMIN, auth_headers


async def test_super_admin_sees_every_site_without_a_grant(
    client: AsyncClient,
) -> None:
    admin = await auth_headers(client, SUPER_ADMIN)
    me = (await client.get("/auth/me", headers=admin)).json()
    assert me["site_access"] == []

    codes = [
        s["code"] for s in (await client.get("/sites", headers=admin)).json()["items"]
    ]
    assert codes == ["MBMT", "TDC", "UMT"] or set(codes) == {"MBMT", "TDC", "UMT"}


async def test_a_manager_sees_only_its_own_sites(client: AsyncClient) -> None:
    h = await auth_headers(client)
    codes = {s["code"] for s in (await client.get("/sites", headers=h)).json()["items"]}
    assert codes == {"MBMT", "UMT"}


async def test_site_list_carries_rollups(client: AsyncClient) -> None:
    h = await auth_headers(client)
    sites = (await client.get("/sites", headers=h)).json()["items"]
    mbmt = next(s for s in sites if s["code"] == "MBMT")
    assert mbmt["vehicle_count"] == 3
    assert mbmt["user_count"] >= 1


async def test_onboarding_a_site_is_super_admin_only(client: AsyncClient) -> None:
    manager = await auth_headers(client)
    body = {"code": "PNQ", "name": "Pune"}
    assert (
        await client.post("/sites", json=body, headers=manager)
    ).status_code == 403

    admin = await auth_headers(client, SUPER_ADMIN)
    r = await client.post("/sites", json=body, headers=admin)
    assert r.status_code == 201, r.text
    assert r.json()["code"] == "PNQ"
    assert r.json()["timezone"] == "Asia/Kolkata"

    # Duplicate code is a conflict, not a silent overwrite.
    assert (await client.post("/sites", json=body, headers=admin)).status_code == 409


async def test_onboarding_a_site_seeds_every_checklist_catalogue(
    client: AsyncClient,
) -> None:
    """A site created after the seed migrations still gets D.I., 10-day, and
    docking (P.M.) checklists — apply_catalogue must cover every seed module a
    migration has ever applied, not just the first one."""
    from app.db import SessionLocal
    from app.models.master import WorkType

    async with SessionLocal() as session:
        for code, name in (
            ("D.I", "Daily inspection"),
            ("10 DAYS SERVICE", "10 day inspection"),
            ("P.M", "Preventive maintenance docking"),
        ):
            session.add(WorkType(code=code, name=name, is_inspection=True))
        await session.commit()

    admin = await auth_headers(client, SUPER_ADMIN)
    r = await client.post(
        "/sites", json={"code": "PNQ2", "name": "Pune Two"}, headers=admin
    )
    assert r.status_code == 201, r.text

    checklists = (
        await client.get("/sites/PNQ2/checklists", headers=admin)
    ).json()["items"]
    by_code = {c["work_type_code"]: c for c in checklists if c["items"]}
    assert "D.I" in by_code
    assert "10 DAYS SERVICE" in by_code
    assert "P.M" in by_code


async def test_a_site_auto_created_by_adding_a_vehicle_still_gets_checklists(
    client: AsyncClient,
) -> None:
    """A site can spring into existence outside the onboarding screen — e.g. a
    vehicle added for a SiteOps-mapped code that was never POSTed to /sites.
    load_site()'s silent auto-create must seed checklists too, or that site's
    mechanics open a permanently empty form with no onboarding step to blame."""
    from app.db import SessionLocal
    from app.models.master import WorkType

    async with SessionLocal() as session:
        for code, name in (
            ("D.I", "Daily inspection"),
            ("10 DAYS SERVICE", "10 day inspection"),
            ("P.M", "Preventive maintenance docking"),
        ):
            session.add(WorkType(code=code, name=name, is_inspection=True))
        await session.commit()

    admin = await auth_headers(client, SUPER_ADMIN)
    r = await client.post(
        "/sites/PNQ5/vehicles",
        json={"registration_no": "MH12AB1234"},
        headers=admin,
    )
    assert r.status_code == 201, r.text

    checklists = (
        await client.get("/sites/PNQ5/checklists", headers=admin)
    ).json()["items"]
    by_code = {c["work_type_code"]: c for c in checklists if c["items"]}
    assert "D.I" in by_code
    assert "10 DAYS SERVICE" in by_code
    assert "P.M" in by_code


async def test_site_code_is_upper_cased_and_validated(client: AsyncClient) -> None:
    admin = await auth_headers(client, SUPER_ADMIN)
    r = await client.post("/sites", json={"code": " pnq ", "name": "Pune"}, headers=admin)
    assert r.status_code == 201
    assert r.json()["code"] == "PNQ"

    bad = await client.post(
        "/sites", json={"code": "no spaces", "name": "X"}, headers=admin
    )
    assert bad.status_code == 400


async def test_site_code_is_immutable(client: AsyncClient) -> None:
    admin = await auth_headers(client, SUPER_ADMIN)
    r = await client.put(
        "/sites/MBMT",
        json={"code": "OTHER", "name": "Renamed"},
        headers=admin,
    )
    assert r.status_code == 200
    assert r.json()["code"] == "MBMT"
    assert r.json()["name"] == "Renamed"


async def test_deactivating_a_site_refuses_new_entries_but_keeps_history(
    client: AsyncClient,
) -> None:
    admin = await auth_headers(client, SUPER_ADMIN)
    h = await auth_headers(client)

    payload = {
        "register": "work_done",
        "site": "MBMT",
        "date": "2026-08-13",
        "data": {"bus_no": "MH40LY1894", "reported_defects": "AC fault"},
    }
    first = await client.post("/entries", json=payload, headers=h)
    assert first.status_code == 201, first.text

    assert (
        await client.post("/sites/MBMT/deactivate", headers=admin)
    ).status_code == 200

    blocked = await client.post("/entries", json=payload, headers=h)
    assert blocked.status_code == 400
    assert "deactivated" in blocked.json()["error"]["message"]

    # History survives, and its users are untouched.
    listed = await client.get("/entries", params={"site": "MBMT"}, headers=h)
    assert listed.status_code == 200
    assert listed.json()["total"] == 1

    assert (
        await client.post("/sites/MBMT/activate", headers=admin)
    ).status_code == 200
    assert (await client.post("/entries", json=payload, headers=h)).status_code == 201


async def test_retiring_a_vehicle_keeps_it_on_past_entries(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    fleet = (await client.get("/sites/MBMT/vehicles", headers=h)).json()["items"]
    vehicle = next(v for v in fleet if v["registration_no"] == "MH40LY1894")

    created = await client.post(
        "/entries",
        json={
            "register": "work_done",
            "site": "MBMT",
            "date": "2026-08-13",
            "data": {"bus_no": "MH40LY1894", "reported_defects": "AC fault"},
        },
        headers=h,
    )
    assert created.status_code == 201

    assert (
        await client.post(f"/vehicles/{vehicle['id']}/deactivate", headers=h)
    ).status_code == 200

    # Gone from the dropdown…
    active = (
        await client.get(
            "/sites/MBMT/vehicles", params={"active": "true"}, headers=h
        )
    ).json()["items"]
    assert "MH40LY1894" not in [v["registration_no"] for v in active]

    # …but still resolvable on the entry that already references it.
    entry = (
        await client.get("/entries", params={"site": "MBMT"}, headers=h)
    ).json()["items"][0]
    assert entry["data"]["bus_no"] == "MH40LY1894"

    # And a new entry against it is refused.
    refused = await client.post(
        "/entries",
        json={
            "register": "work_done",
            "site": "MBMT",
            "date": "2026-08-13",
            "data": {"bus_no": "MH40LY1894", "reported_defects": "again"},
        },
        headers=h,
    )
    assert refused.status_code == 400


async def test_duplicate_registration_is_409(client: AsyncClient) -> None:
    h = await auth_headers(client)
    r = await client.post(
        "/sites/MBMT/vehicles",
        json={"registration_no": "mh40 ly1895"},
        headers=h,
    )
    assert r.status_code == 409


async def test_registration_is_normalised_on_create(client: AsyncClient) -> None:
    h = await auth_headers(client)
    r = await client.post(
        "/sites/MBMT/vehicles",
        json={"registration_no": " mh12 ab 3456 ", "make": "EKA"},
        headers=h,
    )
    assert r.status_code == 201, r.text
    assert r.json()["registration_no"] == "MH12AB3456"


async def test_a_supervisor_cannot_edit_the_fleet(client: AsyncClient) -> None:
    sup = await auth_headers(client, "TV4102")
    # Reading is fine — the entry form needs the dropdown.
    assert (await client.get("/sites/MBMT/vehicles", headers=sup)).status_code == 200
    r = await client.post(
        "/sites/MBMT/vehicles", json={"registration_no": "MH99XX0001"}, headers=sup
    )
    assert r.status_code == 403


async def test_no_access_to_another_sites_fleet(client: AsyncClient) -> None:
    h = await auth_headers(client)  # TV4021 holds MBMT and UMT, not TDC
    assert (await client.get("/sites/TDC/vehicles", headers=h)).status_code == 403
