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
