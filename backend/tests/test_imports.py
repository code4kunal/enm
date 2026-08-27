from __future__ import annotations

import io
import json

from httpx import AsyncClient
from openpyxl import Workbook

from tests.conftest import auth_headers


def _files(body: str, name: str = "sheet.csv") -> dict:
    return {"file": (name, body.encode("utf-8"), "text/csv")}


def _mappings(pairs: dict[str, str], **extra) -> str:
    return json.dumps(
        [
            {"target_key": k, "source_column": v, **extra.get(k, {})}
            for k, v in pairs.items()
        ]
    )


async def _preview(
    client: AsyncClient, headers: dict, *, target: str, body: str, mappings: str, **form
):
    return await client.post(
        "/sites/MBMT/imports/preview",
        files=_files(body),
        data={"target": target, "mappings": mappings, **form},
        headers=headers,
    )


async def _commit(client: AsyncClient, headers: dict, token: str):
    return await client.post(
        "/sites/MBMT/imports/commit", json={"token": token}, headers=headers
    )


FLEET = (
    "Registration No,Make,Model\n"
    "MH40LY1895,EKA,E9\n"
    "\n"  # a blank row in the middle
    "MH12AB0001,EKA,E9\n"
    ",EKA,E9\n"  # row 5: missing the required registration
)


async def test_inspect_reports_sheets_columns_and_samples(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    r = await client.post(
        "/sites/MBMT/imports/inspect",
        files=_files(FLEET),
        data={"header_row": "1"},
        headers=h,
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["columns"] == ["Registration No", "Make", "Model"]
    assert body["total_rows"] == 3
    assert body["sample_rows"][0]["Registration No"] == "MH40LY1895"


async def test_blank_and_duplicate_headers_stay_addressable(
    client: AsyncClient,
) -> None:
    """A mapping has to be able to name exactly one column."""
    h = await auth_headers(client)
    r = await client.post(
        "/sites/MBMT/imports/inspect",
        files=_files("Reg,Make,,Make\nMH1,EKA,x,ELECTRA\n"),
        data={"header_row": "1"},
        headers=h,
    )
    assert r.json()["columns"] == ["Reg", "Make", "Column 3", "Make (2)"]


async def test_a_blank_row_does_not_shift_the_row_numbers(
    client: AsyncClient,
) -> None:
    """The number reported has to be the row the user sees in Excel."""
    h = await auth_headers(client)
    r = await _preview(
        client,
        h,
        target="vehicles",
        body=FLEET,
        mappings=_mappings({"registration_no": "Registration No", "make": "Make"}),
    )
    assert r.status_code == 200, r.text
    assert [e["row_number"] for e in r.json()["errors"]] == [5]


async def test_preview_writes_nothing_until_commit(client: AsyncClient) -> None:
    h = await auth_headers(client)
    before = len(
        (await client.get("/sites/MBMT/vehicles", headers=h)).json()["items"]
    )

    r = await _preview(
        client,
        h,
        target="vehicles",
        body=FLEET,
        mappings=_mappings({"registration_no": "Registration No", "make": "Make"}),
    )
    body = r.json()
    assert body["new_count"] == 1
    assert body["update_count"] == 1

    after = len((await client.get("/sites/MBMT/vehicles", headers=h)).json()["items"])
    assert after == before

    run = await _commit(client, h, body["token"])
    assert run.status_code == 200, run.text
    assert run.json()["rows_accepted"] == 2
    assert run.json()["rows_rejected"] == 1

    regs = {
        v["registration_no"]
        for v in (await client.get("/sites/MBMT/vehicles", headers=h)).json()["items"]
    }
    assert "MH12AB0001" in regs


async def test_re_running_the_same_sheet_updates_rather_than_duplicates(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    mappings = _mappings({"registration_no": "Registration No", "make": "Make"})

    for _ in range(2):
        preview = await _preview(
            client, h, target="vehicles", body=FLEET, mappings=mappings
        )
        await _commit(client, h, preview.json()["token"])

    fleet = (await client.get("/sites/MBMT/vehicles", headers=h)).json()["items"]
    regs = [v["registration_no"] for v in fleet]
    assert len(regs) == len(set(regs))
    assert regs.count("MH12AB0001") == 1


async def test_a_stale_token_is_gone(client: AsyncClient) -> None:
    h = await auth_headers(client)
    preview = await _preview(
        client,
        h,
        target="vehicles",
        body=FLEET,
        mappings=_mappings({"registration_no": "Registration No"}),
    )
    token = preview.json()["token"]
    assert (await _commit(client, h, token)).status_code == 200

    replay = await _commit(client, h, token)
    assert replay.status_code == 410
    assert "upload the file again" in replay.json()["error"]["message"]


async def test_an_unmapped_required_field_is_refused_before_parsing(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    r = await _preview(
        client, h, target="vehicles", body=FLEET, mappings=_mappings({"make": "Make"})
    )
    assert r.status_code == 400
    assert "Registration No" in r.json()["error"]["message"]


async def test_a_vehicle_off_the_fleet_is_rejected_by_name(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    r = await _preview(
        client,
        h,
        target="odometers",
        body="Reg,KM\nMH40LY1895,50000\nMH99ZZ9999,10\n",
        mappings=_mappings({"registration_no": "Reg", "odometer_km": "KM"}),
    )
    assert r.status_code == 200, r.text
    errors = r.json()["errors"]
    assert len(errors) == 1
    assert errors[0]["message"] == "MH99ZZ9999 is not on the MBMT fleet"


async def test_an_odometer_import_never_moves_backwards(
    client: AsyncClient,
) -> None:
    """A lower figure is a stale sheet, not a correction — skipped silently."""
    h = await auth_headers(client)
    fleet = (await client.get("/sites/MBMT/vehicles", headers=h)).json()["items"]
    vehicle = next(v for v in fleet if v["registration_no"] == "MH40LY1895")
    await client.put(
        f"/vehicles/{vehicle['id']}/odometer", json={"odometer_km": 50000}, headers=h
    )

    preview = await _preview(
        client,
        h,
        target="odometers",
        body="Reg,KM\nMH40LY1895,10\n",
        mappings=_mappings({"registration_no": "Reg", "odometer_km": "KM"}),
    )
    # It is accepted as a row — it just does not lower the reading.
    assert preview.json()["errors"] == []
    await _commit(client, h, preview.json()["token"])

    fleet = (await client.get("/sites/MBMT/vehicles", headers=h)).json()["items"]
    again = next(v for v in fleet if v["registration_no"] == "MH40LY1895")
    assert again["odometer_km"] == 50000


async def test_a_dropdown_value_off_the_master_list_is_rejected(
    client: AsyncClient,
) -> None:
    """Imports never auto-create master rows."""
    h = await auth_headers(client)
    r = await _preview(
        client,
        h,
        target="workDone",
        body=(
            "Date,Bus,Defect,Source\n"
            "2026-08-13,MH40LY1895,AC fault,Driver report\n"
            "2026-08-13,MH40LY1895,AC fault,Invented source\n"
        ),
        mappings=_mappings(
            {
                "date": "Date",
                "bus": "Bus",
                "defects": "Defect",
                "source": "Source",
            }
        ),
    )
    assert r.status_code == 200, r.text
    errors = r.json()["errors"]
    assert len(errors) == 1
    assert "Invented source" in errors[0]["message"]


async def test_a_source_date_format_is_honoured(client: AsyncClient) -> None:
    h = await auth_headers(client)
    mappings = json.dumps(
        [
            {"target_key": "date", "source_column": "Date", "date_format": "dd/MM/yyyy"},
            {"target_key": "bus", "source_column": "Bus"},
            {"target_key": "defects", "source_column": "Defect"},
        ]
    )
    r = await _preview(
        client,
        h,
        target="workDone",
        body="Date,Bus,Defect\n13/08/2026,MH40LY1895,AC fault\n",
        mappings=mappings,
    )
    assert r.json()["errors"] == []

    await _commit(client, h, r.json()["token"])
    entries = (
        await client.get("/entries", params={"site": "MBMT"}, headers=h)
    ).json()["items"]
    assert entries[0]["date"] == "2026-08-13"


async def test_an_unparseable_date_names_the_expected_format(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    r = await _preview(
        client,
        h,
        target="workDone",
        body="Date,Bus,Defect\nnot-a-date,MH40LY1895,AC fault\n",
        mappings=_mappings(
            {"date": "Date", "bus": "Bus", "defects": "Defect"}
        ),
    )
    assert "yyyy-MM-dd" in r.json()["errors"][0]["message"]


async def test_a_constant_fills_a_column_the_sheet_omits(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    mappings = json.dumps(
        [
            {"target_key": "date", "source_column": "", "constant_value": "2026-08-13"},
            {"target_key": "bus", "source_column": "Bus"},
            {"target_key": "defects", "source_column": "Defect"},
        ]
    )
    r = await _preview(
        client,
        h,
        target="workDone",
        body="Bus,Defect\nMH40LY1895,AC fault\n",
        mappings=mappings,
    )
    assert r.json()["errors"] == []
    assert r.json()["rows"][0]["date"] == "2026-08-13"


async def test_backfilled_breakdowns_land_resolved(client: AsyncClient) -> None:
    """A 2024 breakdown must not light up today's open-breakdown banner."""
    h = await auth_headers(client)
    r = await _preview(
        client,
        h,
        target="breakdown",
        body="Date,Bus,Complaint\n2024-03-04,MH40LY1895,No traction\n",
        mappings=_mappings(
            {"date": "Date", "bus": "Bus", "complaint": "Complaint"}
        ),
    )
    await _commit(client, h, r.json()["token"])

    entries = (
        await client.get(
            "/entries", params={"site": "MBMT", "register": "breakdown"}, headers=h
        )
    ).json()["items"]
    assert entries[0]["status"] == "resolved"


async def test_an_xlsx_upload_is_parsed_server_side(client: AsyncClient) -> None:
    h = await auth_headers(client)
    workbook = Workbook()
    sheet = workbook.active
    sheet.title = "Fleet"
    sheet.append(["Registration No", "Make"])
    sheet.append(["MH77XY1234", "EKA"])
    buffer = io.BytesIO()
    workbook.save(buffer)

    r = await client.post(
        "/sites/MBMT/imports/inspect",
        files={
            "file": (
                "fleet.xlsx",
                buffer.getvalue(),
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            )
        },
        data={"header_row": "1"},
        headers=h,
    )
    assert r.status_code == 200, r.text
    assert r.json()["sheet_names"] == ["Fleet"]
    assert r.json()["columns"] == ["Registration No", "Make"]


async def test_import_profiles_round_trip(client: AsyncClient) -> None:
    h = await auth_headers(client)
    body = {
        "name": "MBMT monthly fleet",
        "target": "vehicles",
        "header_row": 1,
        "skip_rows": 0,
        "mappings": [
            {"target_key": "registration_no", "source_column": "Registration No"}
        ],
    }
    created = await client.post("/sites/MBMT/import-profiles", json=body, headers=h)
    assert created.status_code == 201, created.text
    profile_id = created.json()["id"]

    listed = await client.get("/sites/MBMT/import-profiles", headers=h)
    assert [p["id"] for p in listed.json()["items"]] == [profile_id]

    updated = await client.put(
        f"/sites/MBMT/import-profiles/{profile_id}",
        json={**body, "name": "Renamed", "mappings": []},
        headers=h,
    )
    assert updated.json()["name"] == "Renamed"
    assert updated.json()["mappings"] == []

    assert (
        await client.delete(f"/import-profiles/{profile_id}", headers=h)
    ).status_code == 204
    assert (await client.get("/sites/MBMT/import-profiles", headers=h)).json()[
        "items"
    ] == []


async def test_run_history_is_kept(client: AsyncClient) -> None:
    h = await auth_headers(client)
    preview = await _preview(
        client,
        h,
        target="vehicles",
        body=FLEET,
        mappings=_mappings({"registration_no": "Registration No"}),
    )
    await _commit(client, h, preview.json()["token"])

    runs = (await client.get("/sites/MBMT/imports", headers=h)).json()["items"]
    assert len(runs) == 1
    assert runs[0]["target"] == "vehicles"
    assert runs[0]["run_by"] == "Rahul Sharma"


async def test_importing_is_manager_only(client: AsyncClient) -> None:
    sup = await auth_headers(client, "TV4102")
    r = await _preview(
        client,
        sup,
        target="vehicles",
        body=FLEET,
        mappings=_mappings({"registration_no": "Registration No"}),
    )
    assert r.status_code == 403


# --- the MBMT snag report, and re-importing it -------------------------------

SNAG_MAP = {
    "work_type": "TYPE OF WORK",
    "bus": "VEHICLE NO",
    "date": "DATE",
    "complaint": "DRIVER COMPLAINT",
    "action": "ACTION TAKEN",
    "employee": "ATTEND BY",
}

SNAG_SHEET = (
    "DATE,VEHICLE NO,TYPE OF WORK,DRIVER COMPLAINT,ACTION TAKEN,ATTEND BY\n"
    "2026-08-01,MH40LY1894,B.D,No traction,Contactor replaced,Tushar\n"
    "2026-08-01,MH40LY1895,D.C,AC not cooling,Gas topped,Nilesh\n"
    "2026-08-02,MH40LY1894,Depot,Routine check,Cleaned,Tushar\n"
    # The real sheet fills this column on inspection rows too — "DAILY
    # INSPECTION" or similar. A blank one is rejected, which is worth
    # knowing: the preview requires a complaint on every row, including the
    # ones TYPE OF WORK routes to an inspection rather than a register.
    "2026-08-02,MH40LY1895,D.I,DAILY INSPECTION,Checked and cleared,Tushar\n"
)


async def _snag_work_types() -> None:
    """The vocabulary the sheet's TYPE OF WORK column names."""
    from app.db import SessionLocal
    from app.models.enums import Register as R
    from app.models.master import WorkType

    async with SessionLocal() as session:
        session.add_all(
            [
                WorkType(code="B.D", name="Breakdown", register=R.breakdown),
                WorkType(
                    code="D.C", name="Driver complaint", register=R.driver_complaint
                ),
                WorkType(code="Depot", name="Daily work", register=R.work_done),
                WorkType(code="D.I", name="Daily inspection", is_inspection=True),
            ]
        )
        await session.commit()


async def _counts() -> dict[str, int]:
    from sqlalchemy import func, select

    from app.db import SessionLocal
    from app.models.checklist import InspectionEntry
    from app.models.entry import Entry

    async with SessionLocal() as session:
        return {
            "entries": await session.scalar(select(func.count()).select_from(Entry)),
            "inspections": await session.scalar(
                select(func.count()).select_from(InspectionEntry)
            ),
        }


async def _import_snag(client: AsyncClient, h: dict, body: str = SNAG_SHEET):
    preview = await _preview(
        client, h, target="snagReport", body=body, mappings=_mappings(SNAG_MAP)
    )
    assert preview.status_code == 200, preview.text
    return await _commit(client, h, preview.json()["token"])


async def test_type_of_work_routes_the_sheet_to_its_registers(
    client: AsyncClient,
) -> None:
    """One sheet, five registers, routed by a master the depot controls."""
    h = await auth_headers(client)
    await _snag_work_types()

    assert (await _import_snag(client, h)).status_code == 200
    counts = await _counts()
    assert counts["entries"] == 3
    assert counts["inspections"] == 1

    registers = {
        e["register"]
        for e in (await client.get("/entries?site=MBMT", headers=h)).json()["items"]
    }
    assert registers == {"breakdown", "driver_complaint", "work_done"}


async def test_the_route_column_reaches_the_breakdown_register(
    client: AsyncClient,
) -> None:
    """ROUTE was mapped, validated and then dropped on the floor.

    Every register's map is a filter — a snag key absent from it is simply not
    carried — so a column can be bound in the profile, pass every row check and
    still reach no table. This is the test that says it lands.
    """
    h = await auth_headers(client)
    await _snag_work_types()

    sheet = (
        "DATE,VEHICLE NO,TYPE OF WORK,DRIVER COMPLAINT,ROUTE,LOCATION\n"
        "2026-08-01,MH40LY1894,B.D,No traction,7,Kashimira signal\n"
    )
    preview = await _preview(
        client,
        h,
        target="snagReport",
        body=sheet,
        mappings=_mappings(
            {
                "date": "DATE",
                "bus": "VEHICLE NO",
                "work_type": "TYPE OF WORK",
                "complaint": "DRIVER COMPLAINT",
                "route": "ROUTE",
                "loc": "LOCATION",
            }
        ),
    )
    assert preview.status_code == 200, preview.text
    assert (await _commit(client, h, preview.json()["token"])).status_code == 200

    items = (await client.get("/entries?site=MBMT", headers=h)).json()["items"]
    breakdowns = [e for e in items if e["register"] == "breakdown"]
    assert len(breakdowns) == 1
    assert breakdowns[0]["data"]["route"] == "7"
    assert breakdowns[0]["data"]["location"] == "Kashimira signal"


async def test_re_importing_the_same_month_changes_nothing(
    client: AsyncClient,
) -> None:
    """The one that makes backfill safe.

    Re-running a corrected sheet, or loading a month that was loaded before,
    used to double every register entry — and with it every figure the DMR and
    the control charts derive.
    """
    h = await auth_headers(client)
    await _snag_work_types()

    await _import_snag(client, h)
    first = await _counts()

    await _import_snag(client, h)
    assert await _counts() == first

    # And a third time, in case the second merely deduped against itself.
    await _import_snag(client, h)
    assert await _counts() == first


async def test_a_re_import_never_touches_hand_entered_work(
    client: AsyncClient,
) -> None:
    """An import matches only rows it wrote. What a supervisor typed has no
    fingerprint, so it can never be matched, updated or counted as seen."""
    h = await auth_headers(client)
    await _snag_work_types()
    await _import_snag(client, h)

    typed = await client.post(
        "/entries",
        json={
            "register": "breakdown",
            "site": "MBMT",
            "date": "2026-08-01",
            "data": {"bus_no": "MH40LY1894", "complaint": "No traction"},
        },
        headers=h,
    )
    assert typed.status_code == 201, typed.text
    before = await _counts()

    await _import_snag(client, h)
    assert await _counts() == before

    still_there = await client.get(f"/entries/{typed.json()['id']}", headers=h)
    assert still_there.status_code == 200


async def test_a_second_month_backfills_alongside_the_first(
    client: AsyncClient,
) -> None:
    """Backfill is the point: an older sheet loads without disturbing what is
    already there."""
    h = await auth_headers(client)
    await _snag_work_types()
    await _import_snag(client, h)
    august = await _counts()

    july = SNAG_SHEET.replace("2026-08-0", "2026-07-0")
    await _import_snag(client, h, july)

    both = await _counts()
    assert both["entries"] == august["entries"] * 2
    assert both["inspections"] == august["inspections"] * 2

    # And re-running July is still a no-op.
    await _import_snag(client, h, july)
    assert await _counts() == both


async def test_a_corrected_row_arrives_as_a_new_entry(
    client: AsyncClient,
) -> None:
    """Documenting the edge rather than claiming it is solved: the fingerprint
    is the row's content, so an edited row is a different row. The correction
    lands; the superseded entry stays until someone removes it."""
    h = await auth_headers(client)
    await _snag_work_types()
    await _import_snag(client, h)
    before = await _counts()

    corrected = SNAG_SHEET.replace("Contactor replaced", "Contactor and relay replaced")
    await _import_snag(client, h, corrected)

    after = await _counts()
    assert after["entries"] == before["entries"] + 1


async def test_every_imported_row_names_the_upload_that_wrote_it(
    client: AsyncClient,
) -> None:
    """"Where did this figure come from?" is a question a depot asks a month
    later, and the answer has to be in the row."""
    from sqlalchemy import func, select

    from app.db import SessionLocal
    from app.models.entry import Entry

    h = await auth_headers(client)
    await _snag_work_types()
    await _import_snag(client, h)

    runs = (await client.get("/sites/MBMT/imports", headers=h)).json()["items"]
    assert len(runs) == 1
    run_id = runs[0]["id"]

    async with SessionLocal() as session:
        linked = await session.scalar(
            select(func.count())
            .select_from(Entry)
            .where(Entry.import_run_id == run_id)
        )
        total = await session.scalar(select(func.count()).select_from(Entry))
    assert linked == total > 0


async def test_a_register_sheet_re_imports_without_duplicating(
    client: AsyncClient,
) -> None:
    """The snag report is not the only sheet that gets re-run."""
    h = await auth_headers(client)
    sheet = (
        "Date,Bus,Defect,Source\n"
        "2026-08-13,MH40LY1895,AC fault,Driver report\n"
    )
    mappings = _mappings(
        {"date": "Date", "bus": "Bus", "defects": "Defect", "source": "Source"}
    )

    for _ in range(3):
        preview = await _preview(
            client, h, target="workDone", body=sheet, mappings=mappings
        )
        await _commit(client, h, preview.json()["token"])

    assert (await _counts())["entries"] == 1


async def test_the_run_report_says_a_re_run_changed_nothing(
    client: AsyncClient,
) -> None:
    """`rows_accepted` counts what the sheet held, which on a repeat is all of
    it — so on its own it reads as a full reload. `rows_unchanged` is what
    tells a manager the second upload was a no-op."""
    h = await auth_headers(client)
    await _snag_work_types()

    await _import_snag(client, h)
    await _import_snag(client, h)

    runs = (await client.get("/sites/MBMT/imports", headers=h)).json()["items"]
    assert len(runs) == 2
    # Both uploads land in the same second, so run_at cannot order them —
    # compare the pair rather than assume which came back first.
    assert sorted(r["rows_unchanged"] for r in runs) == [0, 3]
    # Rows read is the same both times, which is exactly why it cannot be the
    # number a manager reads to see whether anything happened.
    assert len({r["rows_accepted"] for r in runs}) == 1


async def test_an_inspection_row_needs_no_driver_complaint(
    client: AsyncClient,
) -> None:
    """A checklist sweep has nothing a driver complained about.

    The column is required on rows that become register entries, and MBMT's
    sheet fills it on inspection rows too — which is the only reason this went
    unnoticed. A blank one is not a broken row.
    """
    h = await auth_headers(client)
    await _snag_work_types()

    preview = await _preview(
        client,
        h,
        target="snagReport",
        body=(
            "DATE,VEHICLE NO,TYPE OF WORK,DRIVER COMPLAINT,ACTION TAKEN,ATTEND BY\n"
            "2026-08-02,MH40LY1895,D.I,,Checked and cleared,Tushar\n"
        ),
        mappings=_mappings(SNAG_MAP),
    )
    assert preview.status_code == 200, preview.text
    assert preview.json()["errors"] == []

    await _commit(client, h, preview.json()["token"])
    counts = await _counts()
    assert counts["inspections"] == 1
    assert counts["entries"] == 0


async def test_a_register_row_still_owes_its_driver_complaint(
    client: AsyncClient,
) -> None:
    """The exemption is for inspections only — a breakdown with no complaint is
    still a row nobody can act on."""
    h = await auth_headers(client)
    await _snag_work_types()

    r = await _preview(
        client,
        h,
        target="snagReport",
        body=(
            "DATE,VEHICLE NO,TYPE OF WORK,DRIVER COMPLAINT,ACTION TAKEN,ATTEND BY\n"
            "2026-08-02,MH40LY1895,B.D,,Towed in,Tushar\n"
        ),
        mappings=_mappings(SNAG_MAP),
    )
    errors = r.json()["errors"]
    assert len(errors) == 1
    assert errors[0]["field"] == "Driver Complaint"


async def test_an_unknown_work_type_is_vivified_on_snag_import(
    client: AsyncClient,
) -> None:
    """Snag vocabulary grows with the sheet — a new TYPE OF WORK must not
    drop the row. It lands as daily work-done until a manager re-routes it."""
    h = await auth_headers(client)
    await _snag_work_types()

    r = await _preview(
        client,
        h,
        target="snagReport",
        body=(
            "DATE,VEHICLE NO,TYPE OF WORK,DRIVER COMPLAINT,ACTION TAKEN,ATTEND BY\n"
            "2026-08-02,MH40LY1895,I.M,Seat torn,Stitched,Tushar\n"
        ),
        mappings=_mappings(SNAG_MAP),
    )
    assert r.status_code == 200, r.text
    assert r.json()["errors"] == []
    assert r.json()["new_count"] == 1

    await _commit(client, h, r.json()["token"])
    counts = await _counts()
    assert counts["entries"] == 1


async def test_snag_import_adds_missing_buses_instead_of_rejecting(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    await _snag_work_types()

    r = await _preview(
        client,
        h,
        target="snagReport",
        body=(
            "DATE,VEHICLE NO,TYPE OF WORK,DRIVER COMPLAINT,ACTION TAKEN,ATTEND BY\n"
            "2026-08-02,MH05FJ3510,B.D,Horn dead,Replaced,Tushar\n"
        ),
        mappings=_mappings(SNAG_MAP),
    )
    assert r.status_code == 200, r.text
    assert r.json()["errors"] == []
    await _commit(client, h, r.json()["token"])
    fleet = (await client.get("/sites/MBMT/vehicles", headers=h)).json()["items"]
    assert any(v["registration_no"] == "MH05FJ3510" for v in fleet)


async def test_na_vehicle_on_snag_lands_on_fleetwide_placeholder(
    client: AsyncClient,
) -> None:
    """Fleet-wide daily inspection rows write N/A — keep the day, don't drop it."""
    h = await auth_headers(client)
    await _snag_work_types()

    r = await _preview(
        client,
        h,
        target="snagReport",
        body=(
            "DATE,VEHICLE NO,TYPE OF WORK,DRIVER COMPLAINT,ACTION TAKEN,ATTEND BY\n"
            "2026-08-02,N/A,D.I,DAILY INSPECTION,All buses checked,Tushar\n"
        ),
        mappings=_mappings(SNAG_MAP),
    )
    assert r.status_code == 200, r.text
    assert r.json()["errors"] == []
    await _commit(client, h, r.json()["token"])
    counts = await _counts()
    assert counts["inspections"] == 1
    fleet = (await client.get("/sites/MBMT/vehicles", headers=h)).json()["items"]
    assert any(v["registration_no"] == "FLEETWIDE" for v in fleet)
