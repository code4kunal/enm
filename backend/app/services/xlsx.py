"""Excel exports.

Only one so far — the DMR month grid, for depots that paste this straight
into their own workbook rather than filing the PDF.
"""
from __future__ import annotations

from datetime import date as date_t
from io import BytesIO

from openpyxl import Workbook
from openpyxl.styles import Alignment, Font
from openpyxl.utils import get_column_letter
from openpyxl.worksheet.worksheet import Worksheet

from app.services import dmr


def _bytes(workbook: Workbook) -> bytes:
    buffer = BytesIO()
    workbook.save(buffer)
    return buffer.getvalue()


def dmr_month(
    *,
    site_code: str,
    month: str,
    dates: list[date_t],
    values: dict[str, list[float | None]],
) -> bytes:
    """Parameters down the rows, one column per day, Total last."""
    workbook = Workbook()
    sheet: Worksheet = workbook.active
    sheet.title = "DMR"

    sheet.append(["Daily Maintenance Report (DMR)"])
    sheet.append([f"Location :- {site_code}", None, f"Month :- {month}"])
    sheet.append([])

    header = ["Sl.No", "Parameters", *[d.isoformat() for d in dates], "Total"]
    sheet.append(header)
    header_row = sheet.max_row
    for cell in sheet[header_row]:
        cell.font = Font(bold=True)

    for parameter in dmr.PARAMETERS:
        row_values = values.get(parameter.key, [])
        total = dmr.monthly_total(parameter, row_values)
        sheet.append(
            [
                parameter.number,
                parameter.label,
                *[
                    None
                    if v is None
                    else (round(float(v), 1) if parameter.decimal else int(v))
                    for v in row_values
                ],
                None
                if total is None
                else (round(total, 1) if parameter.decimal else int(total)),
            ]
        )
        sheet.cell(row=sheet.max_row, column=len(header)).font = Font(bold=True)

    sheet.column_dimensions["A"].width = 6
    sheet.column_dimensions["B"].width = 42
    for col in range(3, len(header) + 1):
        sheet.column_dimensions[get_column_letter(col)].width = 7
    sheet.freeze_panes = sheet.cell(row=header_row + 1, column=3)
    for row in sheet.iter_rows(min_row=header_row, max_row=sheet.max_row, min_col=3):
        for cell in row:
            cell.alignment = Alignment(horizontal="center")

    return _bytes(workbook)
