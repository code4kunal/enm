"""The six depot reports, as PDFs.

Each one is laid out the way the depot's own sheet is, because these get
printed and filed next to the paper ones. The grids go landscape; the lists
stay portrait.

Nothing here queries: every builder takes what the report services already
returned, so a PDF and the screen can never show different numbers.
"""
from __future__ import annotations

from datetime import date as date_t

from reportlab.lib.units import mm
from reportlab.platypus import Paragraph, Spacer

from app.models.report import FittedUnit, OffRoadCase
from app.services import control_charts, dmr, units
from app.services.pdf import base
from app.services.pdf.base import (
    AMBER_FILL,
    AMBER_INK,
    CELL,
    CELL_CENTRE,
    GREEN,
    RED_FILL,
    RED_INK,
    SUBTLE_FILL,
    DocInfo,
    Story,
)


def _day(value: date_t | None) -> str:
    return value.strftime("%d %b %Y") if value else "—"


def _month_label(month: str) -> str:
    try:
        year, mon = (int(p) for p in month.split("-", 1))
        return date_t(year, mon, 1).strftime("%b %Y")
    except (ValueError, TypeError):
        return month


# --- the Daily Maintenance Report --------------------------------------------


def dmr_day(
    *,
    site_code: str,
    day: date_t,
    values: dict[str, object],
    is_snapshot: bool,
    notes: str,
) -> Story:
    """The numbered sheet for one day."""
    outstanding = sum(
        1 for key in dmr.ENTERED_KEYS if values.get(key) is None
    )
    story = Story(
        DocInfo(
            title="Daily Maintenance Report",
            site_code=site_code,
            period=_day(day),
            note=(
                "Reported as it stood at the end of the day."
                if is_snapshot
                else f"Open — {outstanding} line(s) not yet entered."
                if outstanding
                else "Open — computed lines still move as the registers are written."
            ),
        )
    )

    rows: list[list] = [["Sl.No", "Parameters", "Figure"]]
    for parameter in dmr.PARAMETERS:
        raw = values.get(parameter.key)
        if raw is None:
            shown = "—"
        elif parameter.decimal:
            shown = f"{float(raw):.1f}"
        else:
            shown = f"{int(raw)}"
        rows.append(
            [
                str(parameter.number),
                Paragraph(parameter.label, CELL),
                shown,
            ]
        )

    # An entered line that nothing observes is shaded, so a supervisor can see
    # at a glance which figures are somebody's to supply.
    entered_rows = [
        i
        for i, parameter in enumerate(dmr.PARAMETERS, start=1)
        if not parameter.derived
    ]
    extra = [
        ("ALIGN", (0, 0), (0, -1), "CENTER"),
        ("ALIGN", (2, 0), (2, -1), "RIGHT"),
        ("FONTNAME", (2, 1), (2, -1), "Helvetica-Bold"),
    ]
    extra += [
        ("BACKGROUND", (0, row), (-1, row), SUBTLE_FILL) for row in entered_rows
    ]

    story.add(
        base.table(
            rows,
            widths=[16 * mm, 128 * mm, 24 * mm],
            extra=extra,
            zebra=False,
        )
    )
    if notes.strip():
        story.add(base.section("Notes"))
        story.add(Paragraph(notes.strip(), base.BODY_TEXT))
    story.add(
        base.note(
            "Shaded lines are entered by hand — nothing in the system observes "
            "them. The rest are computed from the registers."
        )
    )
    return story


def dmr_month(
    *,
    site_code: str,
    month: str,
    dates: list[date_t],
    values: dict[str, list[float | None]],
) -> Story:
    """Parameters down, one column per day."""
    story = Story(
        DocInfo(
            title="Daily Maintenance Report — month",
            site_code=site_code,
            period=_month_label(month),
            landscape_page=True,
        )
    )

    header: list = ["#", Paragraph("Parameters", CELL)]
    header += [Paragraph(str(d.day), CELL_CENTRE) for d in dates]
    rows: list[list] = [header]
    for parameter in dmr.PARAMETERS:
        row: list = [str(parameter.number), Paragraph(parameter.label, CELL)]
        for value in values.get(parameter.key, []):
            if value is None:
                row.append("—")
            elif parameter.decimal:
                row.append(f"{float(value):.1f}")
            else:
                row.append(f"{int(value)}")
        rows.append(row)

    label = 75 * mm
    day_width = base.grid_column(
        columns=len(dates), label_width=label, cap=8.5 * mm
    )
    widths = [7 * mm, label - 7 * mm] + [day_width] * len(dates)
    story.add(
        base.table(
            rows,
            widths=widths,
            align="CENTER",
            font_size=6,
            extra=[
                ("ALIGN", (2, 0), (-1, -1), "CENTER"),
                ("ALIGN", (0, 0), (0, -1), "CENTER"),
                ("LEFTPADDING", (2, 0), (-1, -1), 1),
                ("RIGHTPADDING", (2, 0), (-1, -1), 1),
            ],
        )
    )
    return story


# --- Annexure-IV control charts ----------------------------------------------


def control_chart(chart: control_charts.Chart) -> Story:
    """The fleet down, the days across, in the depot's own colours."""
    spec = chart.spec
    story = Story(
        DocInfo(
            title=f"Control chart — {spec.title}",
            site_code=chart.site_code,
            period=f"{_day(chart.from_date)} to {_day(chart.to_date)}",
            note=spec.legend,
            landscape_page=True,
        )
    )

    if not spec.available:
        story.add(Paragraph(spec.unavailable_reason, base.BODY_TEXT))
        return story

    header: list = [Paragraph("Bus No", CELL)]
    header += [Paragraph(str(d.day), CELL_CENTRE) for d in chart.dates]
    rows: list[list] = [header]

    # The colours are half the report, so they are painted rather than spelled
    # out the way the CSV has to.
    fills: list = []
    inks: list = []
    for r, row in enumerate(chart.rows, start=1):
        cells: list = [Paragraph(row.registration_no, CELL)]
        for c, cell in enumerate(row.cells, start=1):
            cells.append(cell.value or "")
            if cell.mark is control_charts.CellMark.pm:
                fills.append(("BACKGROUND", (c, r), (c, r), AMBER_FILL))
                inks.append(("TEXTCOLOR", (c, r), (c, r), AMBER_INK))
            elif cell.mark in (
                control_charts.CellMark.docking,
                control_charts.CellMark.breakdown,
            ):
                fills.append(("BACKGROUND", (c, r), (c, r), RED_FILL))
                inks.append(("TEXTCOLOR", (c, r), (c, r), RED_INK))
        rows.append(cells)

    label = 26 * mm
    day_width = base.grid_column(
        columns=len(chart.dates), label_width=label, cap=14 * mm
    )
    story.add(
        base.table(
            rows,
            widths=[label] + [day_width] * len(chart.dates),
            align="CENTER",
            font_size=6.5,
            zebra=False,
            extra=[
                ("ALIGN", (1, 0), (-1, -1), "CENTER"),
                ("LEFTPADDING", (1, 0), (-1, -1), 0.5),
                ("RIGHTPADDING", (1, 0), (-1, -1), 0.5),
                ("GRID", (0, 0), (-1, -1), 0.25, base.RULE),
                *fills,
                *inks,
            ],
        )
    )
    story.add(
        base.note(
            f"{chart.filled} block(s) filled across {len(chart.rows)} buses."
        )
    )
    return story


# --- off road / held-up buses ------------------------------------------------


def off_road(
    *, site_code: str, day: date_t, cases: list[OffRoadCase]
) -> Story:
    story = Story(
        DocInfo(
            title="Details of off-road (held-up) buses",
            site_code=site_code,
            period=_day(day),
            note=f"{len(cases)} bus(es) off the road on this date.",
            landscape_page=True,
        )
    )
    if not cases:
        story.add(Paragraph("Every bus on the road.", base.BODY_TEXT))
        return story

    rows: list[list] = [
        [
            "Sl.No",
            "Bus No",
            Paragraph("Issue", CELL),
            "Category",
            "Down since",
            "Days",
            Paragraph("Action taken", CELL),
            Paragraph("Spare parts", CELL),
            Paragraph("Vendor", CELL),
        ]
    ]
    held: list = []
    for i, case in enumerate(cases, start=1):
        days = case.days_down_on(day)
        rows.append(
            [
                str(i),
                case.vehicle.registration_no if case.vehicle else "",
                Paragraph(case.issue or "", CELL),
                case.category.value if case.category else "",
                _day(case.off_road_since),
                str(days),
                Paragraph(case.action_taken or "", CELL),
                Paragraph(case.spare_parts_required or "", CELL),
                "yes" if case.awaiting_vendor else "",
            ]
        )
        # The depot reports a bus down this long separately, so it is marked.
        if days >= dmr.HELD_DAYS:
            held.append(("TEXTCOLOR", (5, i), (5, i), RED_INK))
            held.append(("FONTNAME", (5, i), (5, i), "Helvetica-Bold"))

    story.add(
        base.table(
            rows,
            widths=[
                11 * mm,
                24 * mm,
                58 * mm,
                20 * mm,
                22 * mm,
                12 * mm,
                58 * mm,
                44 * mm,
                14 * mm,
            ],
            extra=[
                ("ALIGN", (5, 0), (5, -1), "CENTER"),
                ("ALIGN", (8, 0), (8, -1), "CENTER"),
                *held,
            ],
        )
    )
    story.add(
        base.note(
            f"Days in red have been down {dmr.HELD_DAYS} days or more. "
            "\"Vendor\" marks a bus waiting on someone outside the depot."
        )
    )
    return story


# --- Annexure-V breakdown investigations -------------------------------------


def investigations(*, site_code: str, day: date_t, items: list) -> Story:
    """One block per breakdown — this is a form people write on."""
    outstanding = sum(1 for i in items if not i.is_complete)
    story = Story(
        DocInfo(
            title="Breakdown investigation",
            site_code=site_code,
            period=_day(day),
            note=(
                f"{len(items)} breakdown(s), {outstanding} still to explain."
                if items
                else "No breakdowns on this date."
            ),
        )
    )
    if not items:
        return story

    for i, item in enumerate(items, start=1):
        rows: list[list] = [
            [
                Paragraph(f"<b>{i}. {item.registration_no}</b>", CELL),
                Paragraph(
                    f"{item.breakdown_time or '—'} · {item.location or '—'}", CELL
                ),
            ],
            [
                Paragraph("<b>Defect</b>", CELL),
                Paragraph(
                    f"{item.defect_type or '—'} · {item.breakdown_reason or ''}",
                    CELL,
                ),
            ],
            [
                Paragraph("<b>Loss of kms</b>", CELL),
                Paragraph(
                    "—" if item.loss_km is None else f"{float(item.loss_km):.1f}",
                    CELL,
                ),
            ],
            [
                Paragraph("<b>Last PM</b>", CELL),
                Paragraph(
                    f"{_day(item.last_pm_on)} — {item.last_pm_findings or 'not recorded'}",
                    CELL,
                ),
            ],
            [
                Paragraph("<b>Driver had reported</b>", CELL),
                Paragraph(item.related_complaints or "—", CELL),
            ],
            [
                Paragraph("<b>Findings</b>", CELL),
                Paragraph(item.findings or " ", CELL),
            ],
            [
                Paragraph("<b>Action to prevent recurrence</b>", CELL),
                Paragraph(item.investigation_action or " ", CELL),
            ],
        ]
        story.add(
            base.keep(
                base.table(
                    rows,
                    widths=[46 * mm, 136 * mm],
                    repeat_header=False,
                    zebra=False,
                    extra=[
                        ("GRID", (0, 0), (-1, -1), 0.3, base.RULE),
                        ("BACKGROUND", (0, 0), (-1, 0), SUBTLE_FILL),
                        # Room to write on the two lines a person supplies.
                        ("TOPPADDING", (0, 5), (-1, 6), 9),
                        ("BOTTOMPADDING", (0, 5), (-1, 6), 9),
                    ],
                ),
                Spacer(1, 7),
            )
        )

    story.add(
        base.note(
            "An investigation counts as done once it has both a finding and an "
            "action."
        )
    )
    return story


# --- Unit Failure Statement --------------------------------------------------


def unit_failures(
    *, site_code: str, month: str, stays: list[FittedUnit]
) -> Story:
    story = Story(
        DocInfo(
            title="Unit Failure Statement",
            site_code=site_code,
            period=_month_label(month),
            note=f"{len(stays)} unit(s) replaced this month.",
            landscape_page=True,
        )
    )
    if not stays:
        story.add(
            Paragraph(
                "No unit came off a bus this month.", base.BODY_TEXT
            )
        )
        return story

    rows: list[list] = [
        [
            "Sl.No",
            "Bus No",
            Paragraph("Name of unit", CELL),
            "Unit No",
            "Date fitted",
            "Date removed",
            "Kms covered",
            Paragraph("Reason for removal", CELL),
            Paragraph("Remarks", CELL),
        ]
    ]
    for i, stay in enumerate(stays, start=1):
        rows.append(
            [
                str(i),
                stay.vehicle.registration_no if stay.vehicle else "",
                Paragraph(stay.unit_type.name if stay.unit_type else "", CELL),
                stay.unit_no or "—",
                _day(stay.fitted_on),
                _day(stay.removed_on),
                # A dash, not a nil: an unknown life is not a life of zero.
                "—" if stay.kms_covered is None else f"{stay.kms_covered:,}",
                Paragraph(stay.removal_reason or "", CELL),
                Paragraph(stay.remarks or "", CELL),
            ]
        )

    story.add(
        base.table(
            rows,
            widths=[
                11 * mm,
                24 * mm,
                40 * mm,
                26 * mm,
                22 * mm,
                23 * mm,
                21 * mm,
                50 * mm,
                46 * mm,
            ],
            extra=[
                ("ALIGN", (0, 0), (0, -1), "CENTER"),
                ("ALIGN", (6, 0), (6, -1), "RIGHT"),
            ],
        )
    )
    story.add(
        base.note(
            "A dash under kms covered means a reading was missing — an unknown "
            "life, not a life of zero."
        )
    )
    return story


# --- the bus history card ----------------------------------------------------


def bus_history(card: units.History) -> Story:
    story = Story(
        DocInfo(
            title=f"Bus history — {card.registration_no}",
            site_code=card.site_code,
            period=f"{_month_label(card.months[0])} to {_month_label(card.months[-1])}"
            if card.months
            else "",
            note=(
                "The day a unit went on or came off. A unit currently fitted is "
                "marked in green."
            ),
            landscape_page=True,
        )
    )

    header: list = ["Sl.No", Paragraph("Name of unit", CELL)]
    header += [
        Paragraph(_month_label(m).split(" ")[0], CELL_CENTRE) for m in card.months
    ]
    rows: list[list] = [header]

    marks: list = []
    for r, row in enumerate(card.rows, start=1):
        cells: list = [str(r), Paragraph(row.unit_name, CELL)]
        if row.fitted_now:
            marks.append(("TEXTCOLOR", (1, r), (1, r), GREEN))
            marks.append(("FONTNAME", (1, r), (1, r), "Helvetica-Bold"))
        for c, event in enumerate(row.cells, start=2):
            cells.append(event.label if event else "")
            if event is None:
                continue
            if event.kind == "fitted":
                marks.append(("TEXTCOLOR", (c, r), (c, r), GREEN))
            elif event.kind == "removed":
                marks.append(("BACKGROUND", (c, r), (c, r), RED_FILL))
                marks.append(("TEXTCOLOR", (c, r), (c, r), RED_INK))
            else:
                marks.append(("BACKGROUND", (c, r), (c, r), AMBER_FILL))
                marks.append(("TEXTCOLOR", (c, r), (c, r), AMBER_INK))
        rows.append(cells)

    label = 72 * mm
    month_width = base.grid_column(
        columns=len(card.months), label_width=label, cap=16 * mm
    )
    story.add(
        base.table(
            rows,
            widths=[10 * mm, label - 10 * mm]
            + [month_width] * len(card.months),
            align="CENTER",
            font_size=6.5,
            zebra=False,
            extra=[
                ("ALIGN", (0, 0), (0, -1), "CENTER"),
                ("ALIGN", (2, 0), (-1, -1), "CENTER"),
                ("GRID", (0, 0), (-1, -1), 0.25, base.RULE),
                *marks,
            ],
        )
    )
    story.add(
        base.note(
            f"{card.events} change(s) recorded across {len(card.rows)} units. "
            "An empty row is a unit that has not been touched."
        )
    )
    return story
