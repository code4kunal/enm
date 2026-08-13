"""The house style every report PDF is built from.

The depot files these on paper, so the PDF is the deliverable rather than a
preview of one: a title block that says which site and which period, tables
whose headers repeat when they break across pages, and a footer that dates the
copy. Anything a supervisor would have to write on by hand is left room for.

A PDF can carry the colour conventions the CSV export cannot — a docking marked
red, a PM day shaded — so the control charts come out of here looking like the
Annexure-IV sheets rather than like a spreadsheet of suffixes.
"""
from __future__ import annotations

import io
from collections.abc import Sequence
from dataclasses import dataclass, field
from datetime import datetime

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.pagesizes import A4, landscape
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.platypus import (
    BaseDocTemplate,
    Frame,
    KeepTogether,
    PageBreak,
    PageTemplate,
    Paragraph,
    Spacer,
    Table,
    TableStyle,
)

from app.services.common import now_ist

#: The depot's own colours, matched to the app so a printed chart and the
#: screen read the same way.
INK = colors.HexColor("#1A1D19")
BODY = colors.HexColor("#454B42")
MUTED = colors.HexColor("#8A9086")
RULE = colors.HexColor("#E2E5DF")
HEADER_RULE = colors.HexColor("#C7CCC3")
GREEN = colors.HexColor("#4F7A3A")
AMBER_INK = colors.HexColor("#8A6D1F")
AMBER_FILL = colors.HexColor("#F5EEDD")
RED_INK = colors.HexColor("#C2452D")
RED_FILL = colors.HexColor("#FBEFEC")
SUBTLE_FILL = colors.HexColor("#F7F8F5")

#: Helvetica is WinAnsi, so a U+2713 tick renders as a blank box. A bullet says
#: the same thing and is in the encoding.
TICK = "•"

_styles = getSampleStyleSheet()

TITLE = ParagraphStyle(
    "TvTitle",
    parent=_styles["Title"],
    fontName="Helvetica-Bold",
    fontSize=14,
    leading=17,
    alignment=0,
    spaceAfter=2,
    textColor=INK,
)
SUBTITLE = ParagraphStyle(
    "TvSubtitle",
    parent=_styles["Normal"],
    fontName="Helvetica",
    fontSize=9,
    leading=12,
    textColor=MUTED,
    spaceAfter=0,
)
SECTION = ParagraphStyle(
    "TvSection",
    parent=_styles["Normal"],
    fontName="Helvetica-Bold",
    fontSize=10.5,
    leading=13,
    textColor=INK,
    spaceBefore=10,
    spaceAfter=5,
)
BODY_TEXT = ParagraphStyle(
    "TvBody",
    parent=_styles["Normal"],
    fontName="Helvetica",
    fontSize=8.5,
    leading=11,
    textColor=BODY,
)
CELL = ParagraphStyle(
    "TvCell",
    parent=BODY_TEXT,
    fontSize=8,
    leading=10,
)
CELL_CENTRE = ParagraphStyle("TvCellCentre", parent=CELL, alignment=TA_CENTER)
NOTE = ParagraphStyle(
    "TvNote",
    parent=_styles["Normal"],
    fontName="Helvetica-Oblique",
    fontSize=8,
    leading=10.5,
    textColor=MUTED,
    spaceBefore=6,
)


@dataclass(slots=True)
class DocInfo:
    """What the title block and the footer say."""

    title: str
    site_code: str
    #: "13 Aug 2026", "Aug 2026", "01 Aug 2026 to 10 Aug 2026".
    period: str = ""
    #: One line under the title — what the report counts, or how to read it.
    note: str = ""
    landscape_page: bool = False


@dataclass(slots=True)
class Story:
    """Flowables plus the document they belong to."""

    info: DocInfo
    flowables: list = field(default_factory=list)

    def add(self, flowable) -> None:
        self.flowables.append(flowable)

    def extend(self, flowables: Sequence) -> None:
        self.flowables.extend(flowables)


class _Doc(BaseDocTemplate):
    """A4 with a repeating footer, portrait or landscape."""

    def __init__(self, buffer, info: DocInfo) -> None:
        page = landscape(A4) if info.landscape_page else A4
        super().__init__(
            buffer,
            pagesize=page,
            leftMargin=14 * mm,
            rightMargin=14 * mm,
            topMargin=14 * mm,
            bottomMargin=16 * mm,
            title=f"{info.title} — {info.site_code}",
            author="Transvolt E&M Maintenance",
            subject=info.period,
        )
        self._info = info
        frame = Frame(
            self.leftMargin,
            self.bottomMargin,
            self.width,
            self.height,
            id="body",
            leftPadding=0,
            rightPadding=0,
            topPadding=0,
            bottomPadding=0,
        )
        self.addPageTemplates(
            [PageTemplate(id="page", frames=[frame], onPage=self._furniture)]
        )

    def _furniture(self, canvas, doc) -> None:
        canvas.saveState()
        width, _ = doc.pagesize
        y = self.bottomMargin - 6 * mm

        canvas.setStrokeColor(RULE)
        canvas.setLineWidth(0.5)
        canvas.line(self.leftMargin, y + 4 * mm, width - self.rightMargin, y + 4 * mm)

        canvas.setFont("Helvetica", 7.5)
        canvas.setFillColor(MUTED)
        stamp = now_ist().strftime("%d %b %Y %H:%M")
        canvas.drawString(
            self.leftMargin,
            y,
            f"Transvolt E&M · {self._info.site_code} · generated {stamp} IST",
        )
        canvas.drawRightString(width - self.rightMargin, y, f"Page {canvas.getPageNumber()}")
        canvas.restoreState()


def title_block(info: DocInfo) -> list:
    """The heading every report opens with."""
    out: list = [Paragraph(info.title, TITLE)]
    line = " · ".join(part for part in (info.site_code, info.period) if part)
    if line:
        out.append(Paragraph(line, SUBTITLE))
    if info.note:
        out.append(Spacer(1, 3))
        out.append(Paragraph(info.note, BODY_TEXT))
    out.append(Spacer(1, 9))
    return out


def table(
    rows: list[list],
    *,
    widths: list[float] | None = None,
    align: str = "LEFT",
    repeat_header: bool = True,
    extra: Sequence | None = None,
    font_size: float = 8,
    zebra: bool = True,
) -> Table:
    """A table in the house style: ruled rows, a header that repeats on break.

    `repeat_header` is what keeps a two-page statement readable — a column of
    dates with no heading on page two is a column of unlabelled numbers.
    """
    t = Table(
        rows,
        colWidths=widths,
        repeatRows=1 if repeat_header else 0,
        hAlign=align,
    )
    style: list = [
        ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
        ("FONTNAME", (0, 1), (-1, -1), "Helvetica"),
        ("FONTSIZE", (0, 0), (-1, -1), font_size),
        ("TEXTCOLOR", (0, 0), (-1, 0), INK),
        ("TEXTCOLOR", (0, 1), (-1, -1), BODY),
        ("LINEBELOW", (0, 0), (-1, 0), 0.7, HEADER_RULE),
        ("LINEBELOW", (0, 1), (-1, -2), 0.3, RULE),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("TOPPADDING", (0, 0), (-1, -1), 3.5),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 3.5),
        ("LEFTPADDING", (0, 0), (-1, -1), 4),
        ("RIGHTPADDING", (0, 0), (-1, -1), 4),
    ]
    if zebra:
        style.append(
            ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, SUBTLE_FILL])
        )
    if extra:
        style.extend(extra)
    t.setStyle(TableStyle(style))
    return t


#: Printable width inside the margins, portrait and landscape.
PORTRAIT_WIDTH = A4[0] - 28 * mm
LANDSCAPE_WIDTH = A4[1] - 28 * mm


def grid_column(
    *, columns: int, label_width: float, landscape_page: bool = True, cap: float
) -> float:
    """How wide each day/month column should be to fill the page.

    A fixed width leaves a ten-day chart stranded in the left third of a
    landscape sheet, looking like a fragment of a bigger report. The cap keeps
    a short window from stretching into something absurd.
    """
    available = (LANDSCAPE_WIDTH if landscape_page else PORTRAIT_WIDTH) - label_width
    return min(cap, available / max(columns, 1))


def note(text: str) -> Paragraph:
    return Paragraph(text, NOTE)


def section(text: str) -> Paragraph:
    return Paragraph(text, SECTION)


def keep(*flowables) -> KeepTogether:
    """Hold a heading with what it heads, so a break cannot orphan it."""
    return KeepTogether(list(flowables))


def page_break() -> PageBreak:
    return PageBreak()


def render(story: Story) -> bytes:
    """Build the document. Returns the PDF bytes."""
    buffer = io.BytesIO()
    doc = _Doc(buffer, story.info)
    flowables = title_block(story.info) + story.flowables
    doc.build(flowables)
    return buffer.getvalue()


def filename(kind: str, site_code: str, period: str) -> str:
    """A name that sorts and says what it is once it is on someone's desk."""
    stem = "-".join(
        part.strip().replace(" ", "-").replace("/", "-")
        for part in (site_code, kind, period)
        if part and part.strip()
    )
    return f"{stem}.pdf".lower()


def stamp() -> datetime:
    return now_ist()
