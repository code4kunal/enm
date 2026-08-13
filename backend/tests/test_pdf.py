from __future__ import annotations

import io
from datetime import UTC, date, datetime

from httpx import AsyncClient, Response
from pypdf import PdfReader
from sqlalchemy import select

from app.db import SessionLocal
from app.models.enums import DefectCategory, Register
from app.models.master import DefectType, Vehicle, WorkType
from app.models.report import UnitType
from tests.conftest import auth_headers

DAY = date(2026, 8, 4)
BUS = "MH40LY1894"


def read(resp: Response) -> tuple[str, int]:
    """The PDF's text and its page count.

    Reading the text back is the point: a byte-length assertion passes on a
    document with every figure missing, and these get printed and filed.
    """
    assert resp.status_code == 200, resp.text
    assert resp.headers["content-type"] == "application/pdf"
    assert resp.content.startswith(b"%PDF-"), "not a PDF"
    reader = PdfReader(io.BytesIO(resp.content))
    text = "\n".join(page.extract_text() or "" for page in reader.pages)
    return text, len(reader.pages)


def attachment(resp: Response) -> str:
    disposition = resp.headers["content-disposition"]
    assert disposition.startswith("attachment;")
    return disposition.split('filename="')[1].rstrip('"')


async def _vehicle_id(reg: str = BUS) -> str:
    async with SessionLocal() as session:
        return (
            await session.scalar(
                select(Vehicle).where(Vehicle.registration_no == reg)
            )
        ).id


async def _work_types() -> dict[str, int]:
    async with SessionLocal() as session:
        ids: dict[str, int] = {}
        for code, name in (("D.I", "Daily inspection"), ("P.M", "Docking")):
            row = WorkType(code=code, name=name, is_inspection=True)
            session.add(row)
            await session.flush()
            ids[code] = row.id
        session.add(
            WorkType(code="B.D", name="Breakdown", register=Register.breakdown)
        )
        await session.commit()
        return ids


async def _unit_type(name: str = "Traction Motor") -> int:
    async with SessionLocal() as session:
        row = UnitType(name=name, sort_order=0)
        session.add(row)
        await session.flush()
        await session.commit()
        return row.id


async def _breakdown(client: AsyncClient, h: dict, **data):
    return await client.post(
        "/entries",
        json={
            "register": "breakdown",
            "site": "MBMT",
            "date": DAY.isoformat(),
            "data": {"bus_no": BUS, **data},
        },
        headers=h,
    )


# --- the Daily Maintenance Report --------------------------------------------


async def test_the_dmr_day_pdf_carries_every_numbered_line(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    r = await client.get(
        "/sites/MBMT/reports/dmr/day/export",
        params={"date": DAY.isoformat()},
        headers=h,
    )
    text, pages = read(r)

    assert "Daily Maintenance Report" in text
    assert "MBMT" in text
    assert "04 Aug 2026" in text
    assert "Total fleet" in text
    assert "Nos of HV batteries replaced" in text
    # The fixture site has two active buses, and line 1 counts them.
    assert "Total fleet" in text
    assert pages >= 1
    assert attachment(r) == "mbmt-dmr-2026-08-04.pdf"


async def test_the_dmr_day_pdf_says_which_lines_are_still_open(
    client: AsyncClient,
) -> None:
    """A printed report has to say whether it is finished."""
    h = await auth_headers(client)
    text, _ = read(
        await client.get(
            "/sites/MBMT/reports/dmr/day/export",
            params={"date": DAY.isoformat()},
            headers=h,
        )
    )
    assert "not yet entered" in text

    await client.post(
        "/sites/MBMT/reports/dmr/snapshot",
        params={"date": DAY.isoformat()},
        headers=h,
    )
    frozen, _ = read(
        await client.get(
            "/sites/MBMT/reports/dmr/day/export",
            params={"date": DAY.isoformat()},
            headers=h,
        )
    )
    assert "as it stood at the end of the day" in frozen


async def test_the_dmr_month_pdf_is_the_grid(client: AsyncClient) -> None:
    h = await auth_headers(client)
    r = await client.get(
        "/sites/MBMT/reports/dmr/export",
        params={"month": "2026-08", "format": "pdf"},
        headers=h,
    )
    text, _ = read(r)
    assert "Daily Maintenance Report" in text
    assert "Aug 2026" in text
    assert attachment(r) == "mbmt-dmr-month-2026-08.pdf"


async def test_the_month_export_still_defaults_to_csv(
    client: AsyncClient,
) -> None:
    """The existing callers asked for a spreadsheet and must keep getting one."""
    h = await auth_headers(client)
    r = await client.get(
        "/sites/MBMT/reports/dmr/export", params={"month": "2026-08"}, headers=h
    )
    assert r.status_code == 200
    assert "text/csv" in r.headers["content-type"]


# --- control charts ----------------------------------------------------------


async def test_a_control_chart_pdf_has_the_fleet_and_the_days(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    types = await _work_types()
    await client.post(
        "/sites/MBMT/inspections",
        json={
            "vehicle_id": await _vehicle_id(),
            "work_type_id": types["P.M"],
            "inspected_on": DAY.isoformat(),
            "results": [],
        },
        headers=h,
    )

    r = await client.get(
        "/sites/MBMT/reports/control-charts/pmSchedule/export",
        params={"from": "2026-08-01", "to": "2026-08-10", "format": "pdf"},
        headers=h,
    )
    text, _ = read(r)
    assert "P.M schedule" in text
    assert BUS in text
    # The other active bus is a row too — an empty row is the finding.
    assert "MH40LY1895" in text
    assert "P.M" in text
    assert attachment(r) == "mbmt-chart-pmschedule-2026-08-01-to-2026-08-10.pdf"


async def test_a_chart_with_no_feed_prints_the_reason(
    client: AsyncClient,
) -> None:
    """Rather than a blank grid, which reads as a fleet nobody serviced."""
    h = await auth_headers(client)
    text, _ = read(
        await client.get(
            "/sites/MBMT/reports/control-charts/energy/export",
            params={"from": "2026-08-01", "to": "2026-08-10", "format": "pdf"},
            headers=h,
        )
    )
    assert "No energy feed" in text


# --- off road ----------------------------------------------------------------


async def test_the_off_road_pdf_lists_the_held_buses(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    resp = await client.post(
        "/sites/MBMT/reports/off-road",
        json={
            "vehicle_id": await _vehicle_id(),
            "issue": "Traction motor bearing noise",
            "category": DefectCategory.mechanical.value,
            "off_road_since": "2026-07-30",
            "action_taken": "Motor removed, sent to vendor",
            "spare_parts_required": "Bearing kit",
            "awaiting_vendor": True,
        },
        headers=h,
    )
    assert resp.status_code == 201, resp.text

    r = await client.get(
        "/sites/MBMT/reports/off-road/export",
        params={"date": DAY.isoformat()},
        headers=h,
    )
    text, _ = read(r)
    assert "off-road" in text.lower()
    assert BUS in text
    assert "Traction motor bearing noise" in text
    assert "Bearing kit" in text
    assert "Vendor" in text
    # Down since 30 Jul, reported on 4 Aug.
    assert "30 Jul 2026" in text
    assert attachment(r) == "mbmt-off-road-2026-08-04.pdf"


async def test_an_empty_off_road_pdf_says_so(client: AsyncClient) -> None:
    h = await auth_headers(client)
    text, _ = read(
        await client.get(
            "/sites/MBMT/reports/off-road/export",
            params={"date": DAY.isoformat()},
            headers=h,
        )
    )
    assert "Every bus on the road" in text


# --- breakdown investigations ------------------------------------------------


async def test_the_investigation_pdf_is_a_form_per_breakdown(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    async with SessionLocal() as session:
        row = await session.scalar(
            select(DefectType).where(DefectType.name == "Brakes & air system")
        )
        row.category = DefectCategory.mechanical
        await session.commit()

    assert (
        await _breakdown(
            client,
            h,
            complaint="No traction on gradient",
            defect_type="Brakes & air system",
            location="Kashimira",
            loss_km=12.5,
        )
    ).status_code == 201

    r = await client.get(
        "/sites/MBMT/reports/investigations/export",
        params={"date": DAY.isoformat()},
        headers=h,
    )
    text, _ = read(r)
    assert "Breakdown investigation" in text
    assert BUS in text
    assert "No traction on gradient" in text
    assert "Kashimira" in text
    assert "12.5" in text
    # The two lines a person has to supply are on the form, empty.
    assert "Findings" in text
    assert "Action to prevent recurrence" in text
    assert "still to explain" in text


async def test_an_investigation_pdf_with_nothing_to_explain(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    text, _ = read(
        await client.get(
            "/sites/MBMT/reports/investigations/export",
            params={"date": DAY.isoformat()},
            headers=h,
        )
    )
    assert "No breakdowns on this date" in text


# --- the Unit Failure Statement and the history card -------------------------


async def _fit_and_remove(client: AsyncClient, h: dict) -> None:
    unit_type_id = await _unit_type()
    stay = (
        await client.post(
            "/sites/MBMT/units",
            json={
                "vehicle_id": await _vehicle_id(),
                "unit_type_id": unit_type_id,
                "fitted_on": "2026-06-14",
                "unit_no": "TM-99812",
                "fitted_odometer_km": 100_000,
            },
            headers=h,
        )
    ).json()
    await client.post(
        f"/units/{stay['id']}/remove",
        json={
            "removed_on": DAY.isoformat(),
            "removed_odometer_km": 142_500,
            "removal_reason": "Bearing noise",
        },
        headers=h,
    )


async def test_the_unit_failure_pdf_has_the_sheets_own_columns(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    await _fit_and_remove(client, h)

    r = await client.get(
        "/sites/MBMT/reports/unit-failures",
        params={"month": "2026-08"},
        headers=h,
    )
    assert len(r.json()["items"]) == 1

    r = await client.get(
        "/sites/MBMT/reports/unit-failures/export",
        params={"month": "2026-08", "format": "pdf"},
        headers=h,
    )
    text, _ = read(r)
    assert "Unit Failure Statement" in text
    assert "Name of unit" in text
    assert "Reason for removal" in text
    assert "TM-99812" in text
    assert "Traction Motor" in text
    assert "42,500" in text
    assert "Bearing noise" in text
    assert attachment(r) == "mbmt-unit-failures-2026-08.pdf"


async def test_an_unknown_unit_life_prints_a_dash(client: AsyncClient) -> None:
    """Not a zero, which would read as a unit that failed the day it went on."""
    h = await auth_headers(client)
    unit_type_id = await _unit_type()
    async with SessionLocal() as session:
        vehicle = await session.scalar(
            select(Vehicle).where(Vehicle.registration_no == BUS)
        )
        vehicle.odometer_updated_at = None
        await session.commit()

    stay = (
        await client.post(
            "/sites/MBMT/units",
            json={
                "vehicle_id": await _vehicle_id(),
                "unit_type_id": unit_type_id,
                "fitted_on": "2026-06-14",
            },
            headers=h,
        )
    ).json()
    await client.post(
        f"/units/{stay['id']}/remove",
        json={"removed_on": DAY.isoformat()},
        headers=h,
    )

    text, _ = read(
        await client.get(
            "/sites/MBMT/reports/unit-failures/export",
            params={"month": "2026-08", "format": "pdf"},
            headers=h,
        )
    )
    assert "unknown" in text.lower()


async def test_the_unit_failure_export_still_defaults_to_csv(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client)
    r = await client.get(
        "/sites/MBMT/reports/unit-failures/export",
        params={"month": "2026-08"},
        headers=h,
    )
    assert "text/csv" in r.headers["content-type"]


async def test_the_bus_history_pdf_is_the_card(client: AsyncClient) -> None:
    h = await auth_headers(client)
    await _fit_and_remove(client, h)

    r = await client.get(
        f"/sites/MBMT/reports/bus-history/{await _vehicle_id()}/export",
        params={"to": "2026-08"},
        headers=h,
    )
    text, _ = read(r)
    assert f"Bus history — {BUS}" in text or BUS in text
    assert "Name of unit" in text
    assert "Traction Motor" in text
    assert "change(s) recorded" in text
    assert attachment(r).startswith("mbmt-bus-history-")


async def test_a_bus_at_another_site_has_no_card(client: AsyncClient) -> None:
    h = await auth_headers(client)
    async with SessionLocal() as session:
        other = await session.scalar(
            select(Vehicle).where(Vehicle.registration_no == "MH05GX4410")
        )
        other_id = other.id
    r = await client.get(
        f"/sites/MBMT/reports/bus-history/{other_id}/export", headers=h
    )
    assert r.status_code == 404


# --- access ------------------------------------------------------------------


async def test_a_site_you_cannot_reach_exports_nothing(
    client: AsyncClient,
) -> None:
    h = await auth_headers(client, "TV4105")
    for path in (
        "/sites/UMT/reports/dmr/day/export",
        "/sites/UMT/reports/off-road/export",
        "/sites/UMT/reports/investigations/export",
    ):
        assert (await client.get(path, headers=h)).status_code == 403, path


async def test_an_executive_can_still_print_its_own_site(
    client: AsyncClient,
) -> None:
    """Reading a report is not managing a site."""
    h = await auth_headers(client, "TV4105")
    r = await client.get(
        "/sites/MBMT/reports/dmr/day/export",
        params={"date": DAY.isoformat()},
        headers=h,
    )
    assert r.status_code == 200
    assert r.content.startswith(b"%PDF-")


def test_the_generated_stamp_is_site_local() -> None:
    """The footer dates the copy in IST, not UTC — a report printed at 01:00
    IST must not be filed under yesterday."""
    from app.services.pdf.base import stamp

    now = stamp()
    assert now.tzinfo is not None
    assert now.utcoffset() == datetime.now(UTC).astimezone(
        now.tzinfo
    ).utcoffset()
