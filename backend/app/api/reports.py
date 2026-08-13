from __future__ import annotations

import csv
import io
from datetime import date as date_t
from datetime import timedelta
from decimal import Decimal
from typing import Annotated

from fastapi import APIRouter, Query, Response, status

from app.deps import CurrentUser, SessionDep, assert_site_access, assert_site_admin
from app.errors import NotFound, ValidationError
from app.models.enums import AuditAction
from app.models.master import Vehicle
from app.models.report import OffRoadCase
from app.schemas.report import (
    ChartCellOut,
    ChartKindOut,
    ChartRowOut,
    ControlChartOut,
    DmrDayOut,
    DmrEnteredIn,
    DmrLine,
    DmrMonthOut,
    InvestigationIn,
    InvestigationList,
    InvestigationOut,
    OffRoadClose,
    OffRoadIn,
    OffRoadList,
    OffRoadOut,
)
from app.services import audit, control_charts, dmr, investigations
from app.services.common import today_ist

router = APIRouter(tags=["reports"])

#: A month grid at most; anything wider belongs in a download.
MAX_REPORT_DAYS = 62


def _parse_day(raw: str | None, fallback: date_t) -> date_t:
    if not raw:
        return fallback
    try:
        return date_t.fromisoformat(raw)
    except ValueError as exc:
        raise ValidationError(
            "`date` must be yyyy-MM-dd", {"date": "expected yyyy-MM-dd"}
        ) from exc


def _lines(values: dict[str, object]) -> list[DmrLine]:
    out: list[DmrLine] = []
    for parameter in dmr.PARAMETERS:
        raw = values.get(parameter.key)
        out.append(
            DmrLine(
                number=parameter.number,
                label=parameter.label,
                key=parameter.key,
                derived=parameter.derived,
                value=None if raw is None else Decimal(str(raw)),
                is_decimal=parameter.decimal,
            )
        )
    return out


# --- Daily Maintenance Report ----------------------------------------------


@router.get("/sites/{code}/reports/dmr", response_model=DmrDayOut)
async def dmr_day(
    code: str,
    user: CurrentUser,
    session: SessionDep,
    date: Annotated[str | None, Query()] = None,
) -> DmrDayOut:
    """One day of the DMR: derived lines computed, entered lines as stored."""
    site_code = assert_site_access(user, code)
    day = _parse_day(date, today_ist())

    values, is_snapshot = await dmr.compose(session, site_code, day)
    row = await dmr.get_day(session, site_code, day)
    await session.commit()

    return DmrDayOut(
        site_code=site_code,
        report_date=day,
        lines=_lines(values),
        notes=str(values.get("notes") or ""),
        is_snapshot=is_snapshot,
        generated_at=row.generated_at if row else None,
    )


@router.put("/sites/{code}/reports/dmr", response_model=DmrDayOut)
async def save_dmr_day(
    code: str,
    payload: DmrEnteredIn,
    user: CurrentUser,
    session: SessionDep,
    date: Annotated[str | None, Query()] = None,
) -> DmrDayOut:
    """Record the lines nothing else in the system observes."""
    site_code = assert_site_access(user, code)
    day = _parse_day(date, today_ist())

    await dmr.save_entered(
        session, site_code, day, payload.model_dump(exclude_unset=True), user
    )
    await audit.record(
        session,
        actor_id=user.id,
        action=AuditAction.dmr_updated,
        object_type="dmr",
        object_id=f"{site_code}:{day.isoformat()}",
    )
    await session.commit()
    return await dmr_day(code, user, session, date=day.isoformat())


@router.post("/sites/{code}/reports/dmr/snapshot", response_model=DmrDayOut)
async def snapshot_dmr(
    code: str,
    user: CurrentUser,
    session: SessionDep,
    date: Annotated[str | None, Query()] = None,
) -> DmrDayOut:
    """Freeze the derived lines as reported. Runs nightly; this is on demand."""
    site_code = assert_site_admin(user, code)
    day = _parse_day(date, today_ist())
    await dmr.snapshot(session, site_code, day)
    await session.commit()
    return await dmr_day(code, user, session, date=day.isoformat())


async def _month_grid(
    session: SessionDep, site_code: str, month: str
) -> DmrMonthOut:
    try:
        first = date_t.fromisoformat(f"{month}-01")
    except ValueError as exc:
        raise ValidationError(
            "`month` must be yyyy-MM", {"month": "expected yyyy-MM"}
        ) from exc

    last = (first.replace(day=28) + timedelta(days=4)).replace(day=1) - timedelta(days=1)
    today = today_ist()
    if last > today:
        last = max(today, first)

    dates: list[date_t] = []
    columns: dict[str, list[float | None]] = {p.key: [] for p in dmr.PARAMETERS}
    day = first
    while day <= last and len(dates) < MAX_REPORT_DAYS:
        values, _ = await dmr.compose(session, site_code, day)
        dates.append(day)
        for parameter in dmr.PARAMETERS:
            raw = values.get(parameter.key)
            columns[parameter.key].append(
                None if raw is None else float(raw)
            )
        day += timedelta(days=1)

    return DmrMonthOut(
        site_code=site_code,
        month=month,
        dates=dates,
        lines=_lines({}),
        values=columns,
    )


@router.get("/sites/{code}/reports/dmr/month", response_model=DmrMonthOut)
async def dmr_month(
    code: str,
    user: CurrentUser,
    session: SessionDep,
    month: Annotated[str | None, Query()] = None,
) -> DmrMonthOut:
    """The month grid: parameters down the page, one column per day."""
    site_code = assert_site_access(user, code)
    grid = await _month_grid(
        session, site_code, month or today_ist().strftime("%Y-%m")
    )
    await session.commit()
    return grid


@router.get("/sites/{code}/reports/dmr/export")
async def export_dmr(
    code: str,
    user: CurrentUser,
    session: SessionDep,
    month: Annotated[str | None, Query()] = None,
) -> Response:
    """The month in the layout the depot already sends on."""
    site_code = assert_site_access(user, code)
    target = month or today_ist().strftime("%Y-%m")
    grid = await _month_grid(session, site_code, target)
    await session.commit()

    buffer = io.StringIO()
    writer = csv.writer(buffer)
    writer.writerow(["Daily Maintenance Report (DMR)"])
    writer.writerow([f"Location :- {site_code}"])
    writer.writerow([])
    writer.writerow(["Sl.No", "Parameters", *[d.isoformat() for d in grid.dates]])
    for parameter in dmr.PARAMETERS:
        row = grid.values[parameter.key]
        writer.writerow(
            [
                parameter.number,
                parameter.label,
                *[
                    ""
                    if v is None
                    else (f"{v:.1f}" if parameter.decimal else f"{int(v)}")
                    for v in row
                ],
            ]
        )

    return Response(
        content=buffer.getvalue(),
        media_type="text/csv",
        headers={
            "Content-Disposition": (
                f'attachment; filename="dmr-{site_code}-{target}.csv"'
            )
        },
    )


# --- Breakdown investigation (Annexure-V) ----------------------------------


def _investigation_out(entry, investigation) -> InvestigationOut:
    detail = entry.breakdown
    return InvestigationOut(
        entry_id=entry.id,
        registration_no=entry.vehicle.registration_no if entry.vehicle else "",
        model=(entry.vehicle.model if entry.vehicle else "") or "",
        odometer_km=entry.vehicle.odometer_km if entry.vehicle else None,
        driver_id=detail.driver_id if detail else None,
        defect_type=(
            detail.defect_type.name if detail and detail.defect_type else ""
        ),
        breakdown_reason=detail.complaint if detail else "",
        location=detail.location if detail else None,
        breakdown_time=detail.breakdown_time if detail else None,
        mechanic_reported_time=detail.mechanic_reported_time if detail else None,
        attended_time=detail.attended_time if detail else None,
        loss_km=detail.loss_km if detail else None,
        attended_details=detail.attended_details if detail else None,
        entry_date=entry.entry_date,
        findings=investigation.findings if investigation else None,
        last_pm_on=investigation.last_pm_on if investigation else None,
        last_pm_findings=investigation.last_pm_findings if investigation else None,
        related_complaints=(
            investigation.related_complaints if investigation else None
        ),
        investigation_action=(
            investigation.investigation_action if investigation else None
        ),
        is_complete=bool(investigation and investigation.is_complete),
        updated_by=(
            investigation.updated_by.name
            if investigation and investigation.updated_by
            else ""
        ),
    )


@router.get(
    "/sites/{code}/reports/investigations", response_model=InvestigationList
)
async def investigations_for_day(
    code: str,
    user: CurrentUser,
    session: SessionDep,
    date: Annotated[str | None, Query()] = None,
) -> InvestigationList:
    """Every breakdown that day, with its investigation where one exists."""
    site_code = assert_site_access(user, code)
    day = _parse_day(date, today_ist())
    pairs = await investigations.for_day(session, site_code, day)
    items = [_investigation_out(e, i) for e, i in pairs]
    return InvestigationList(
        site_code=site_code,
        report_date=day,
        items=items,
        outstanding=sum(1 for i in items if not i.is_complete),
    )


@router.get(
    "/breakdowns/{entry_id}/investigation", response_model=InvestigationOut
)
async def open_investigation(
    entry_id: str, user: CurrentUser, session: SessionDep
) -> InvestigationOut:
    """Open one investigation, pre-filled from what is already known."""
    entry = await investigations.load_breakdown(session, entry_id)
    assert_site_access(user, entry.site_code)
    investigation = await investigations.get_or_prefill(session, entry)
    await session.commit()
    await session.refresh(investigation)
    return _investigation_out(entry, investigation)


@router.put(
    "/breakdowns/{entry_id}/investigation", response_model=InvestigationOut
)
async def save_investigation(
    entry_id: str,
    payload: InvestigationIn,
    user: CurrentUser,
    session: SessionDep,
) -> InvestigationOut:
    entry = await investigations.load_breakdown(session, entry_id)
    assert_site_access(user, entry.site_code)
    investigation = await investigations.get_or_prefill(session, entry)
    await investigations.save(
        session, investigation, payload.model_dump(exclude_unset=True), user
    )
    await session.commit()
    await session.refresh(investigation)
    return _investigation_out(entry, investigation)


# --- Off-road / held-up buses ----------------------------------------------


def _off_road_out(case: OffRoadCase, day: date_t) -> OffRoadOut:
    days_down = case.days_down_on(day)
    return OffRoadOut(
        id=case.id,
        site_code=case.site_code,
        vehicle_id=case.vehicle_id,
        registration_no=case.vehicle.registration_no if case.vehicle else "",
        model=(case.vehicle.model if case.vehicle else "") or "",
        odometer_km=case.odometer_km,
        issue=case.issue,
        action_taken=case.action_taken,
        category=case.category,
        off_road_since=case.off_road_since,
        expected_days=case.expected_days,
        expected_ready_on=case.expected_ready_on,
        returned_on=case.returned_on,
        spare_parts_required=case.spare_parts_required,
        remarks=case.remarks,
        awaiting_vendor=case.awaiting_vendor,
        days_down=days_down,
        is_held=days_down >= dmr.HELD_DAYS,
    )


@router.get("/sites/{code}/reports/off-road", response_model=OffRoadList)
async def off_road_for_day(
    code: str,
    user: CurrentUser,
    session: SessionDep,
    date: Annotated[str | None, Query()] = None,
) -> OffRoadList:
    """The defective-bus list as it stood that morning."""
    site_code = assert_site_access(user, code)
    day = _parse_day(date, today_ist())
    cases = await investigations.open_cases(session, site_code, day)
    return OffRoadList(
        site_code=site_code,
        report_date=day,
        items=[_off_road_out(c, day) for c in cases],
    )


@router.post(
    "/sites/{code}/reports/off-road",
    response_model=OffRoadOut,
    status_code=status.HTTP_201_CREATED,
)
async def put_off_road(
    code: str, payload: OffRoadIn, user: CurrentUser, session: SessionDep
) -> OffRoadOut:
    """Put a bus off the road, or update the case it already has."""
    site_code = assert_site_admin(user, code)
    vehicle = await session.get(Vehicle, payload.vehicle_id)
    if vehicle is None:
        raise NotFound("Vehicle not found")

    values = payload.model_dump(exclude_unset=True)
    values.pop("vehicle_id", None)
    case = await investigations.open_case(
        session, site_code=site_code, vehicle=vehicle, values=values, actor=user
    )
    await session.commit()
    await session.refresh(case)
    return _off_road_out(case, today_ist())


@router.post("/off-road/{case_id}/close", response_model=OffRoadOut)
async def close_off_road(
    case_id: str, payload: OffRoadClose, user: CurrentUser, session: SessionDep
) -> OffRoadOut:
    """The bus ran again."""
    case = await session.get(OffRoadCase, case_id)
    if case is None:
        raise NotFound("Off-road case not found")
    assert_site_admin(user, case.site_code)
    await investigations.close_case(session, case, payload.returned_on, user)
    await session.commit()
    await session.refresh(case)
    return _off_road_out(case, payload.returned_on)


def _chart_out(chart: control_charts.Chart) -> ControlChartOut:
    spec = chart.spec
    return ControlChartOut(
        kind=spec.kind,
        title=spec.title,
        legend=spec.legend,
        unit=spec.unit,
        available=spec.available,
        unavailable_reason=spec.unavailable_reason,
        site_code=chart.site_code,
        from_date=chart.from_date,
        to_date=chart.to_date,
        dates=chart.dates,
        rows=[
            ChartRowOut(
                vehicle_id=row.vehicle_id,
                registration_no=row.registration_no,
                cells=[
                    ChartCellOut(value=c.value, mark=c.mark, title=c.title)
                    for c in row.cells
                ],
            )
            for row in chart.rows
        ],
        filled=chart.filled,
    )


def _chart_window(
    from_date: str | None, to_date: str | None
) -> tuple[date_t, date_t]:
    """Default to the month the caller is looking at, ending today."""
    end = _parse_day(to_date, today_ist())
    start = _parse_day(from_date, end.replace(day=1))
    return start, end


@router.get("/reports/control-charts", response_model=list[ChartKindOut])
async def list_control_charts(user: CurrentUser) -> list[ChartKindOut]:
    """Which charts exist, and which of them have data behind them."""
    del user
    return [
        ChartKindOut(
            kind=spec.kind,
            title=spec.title,
            legend=spec.legend,
            unit=spec.unit,
            available=spec.available,
            unavailable_reason=spec.unavailable_reason,
        )
        for spec in control_charts.CHARTS
    ]


@router.get(
    "/sites/{code}/reports/control-charts/{kind}",
    response_model=ControlChartOut,
)
async def control_chart(
    code: str,
    kind: control_charts.ChartKind,
    user: CurrentUser,
    session: SessionDep,
    from_date: Annotated[str | None, Query(alias="from")] = None,
    to_date: Annotated[str | None, Query(alias="to")] = None,
) -> ControlChartOut:
    """Annexure-IV: the fleet down, the days across, one mark per bus per day."""
    site_code = assert_site_access(user, code)
    start, end = _chart_window(from_date, to_date)
    chart = await control_charts.build(
        session,
        site_code=site_code,
        kind=kind,
        from_date=start,
        to_date=end,
    )
    return _chart_out(chart)


@router.get("/sites/{code}/reports/control-charts/{kind}/export")
async def export_control_chart(
    code: str,
    kind: control_charts.ChartKind,
    user: CurrentUser,
    session: SessionDep,
    from_date: Annotated[str | None, Query(alias="from")] = None,
    to_date: Annotated[str | None, Query(alias="to")] = None,
) -> Response:
    """The grid as the depot files it, colours carried as a suffix.

    A CSV cannot hold a fill colour, so a marked block is exported as its value
    with the mark appended — `2 (BD)` — rather than silently losing the half of
    the chart that the colour carries.
    """
    site_code = assert_site_access(user, code)
    start, end = _chart_window(from_date, to_date)
    chart = await control_charts.build(
        session, site_code=site_code, kind=kind, from_date=start, to_date=end
    )

    suffix = {
        control_charts.CellMark.pm: " (PM)",
        control_charts.CellMark.docking: " (DOCKING)",
        control_charts.CellMark.breakdown: " (BD)",
    }
    buffer = io.StringIO()
    writer = csv.writer(buffer)
    writer.writerow([chart.spec.title])
    writer.writerow([f"Location :- {site_code}"])
    writer.writerow([f"{chart.from_date.isoformat()} to {chart.to_date.isoformat()}"])
    writer.writerow([chart.spec.legend])
    writer.writerow([])
    writer.writerow(["Bus No", *[str(d.day) for d in chart.dates]])
    for row in chart.rows:
        writer.writerow(
            [
                row.registration_no,
                *[
                    f"{c.title or c.value}{suffix.get(c.mark, '')}".strip()
                    for c in row.cells
                ],
            ]
        )

    name = f"{site_code}-{kind.value}-{chart.from_date}-to-{chart.to_date}.csv"
    return Response(
        content=buffer.getvalue(),
        media_type="text/csv",
        headers={"Content-Disposition": f'attachment; filename="{name}"'},
    )
