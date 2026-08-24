"""put the 9M docking checklist in the database

Revision ID: 0015
Revises: 0014
Create Date: 2026-08-24

`0014` seeded D.I and ten-day from the depot's own sheets but left P.M
(docking) with a template and no lines — PENDING.md section 5 explains why:
the docking PDFs are 26 files that do not survive text extraction reliably.

This migration adds one line set instead, read by hand rather than parsed:
the 9M variant's docking checklist, transcribed from
`data/MBMT/August/9M DOCKING SHEET/1.20Lakh Maintanence Schedule.pdf` (not in
the repository — same reason as the D.I/ten-day sheets). That PDF is the
superset of every lower milestone (10k through 1.10 lakh), so one checklist
covers the whole 10k–1.20 lakh range rather than one variant per milestone —
see `app/seeds/checklists_v2.py` for why. 12M AC / 12M Non-AC docking remain
unshipped.

Same idempotency rules as 0014: applied per site, skipped where a template
already carries lines (a depot's own edits are never overwritten), and
`downgrade` only removes items that were never answered.
"""
from __future__ import annotations

import uuid

import sqlalchemy as sa
from alembic import op

from app.seeds.checklists_v2 import CHECKLISTS

revision = "0015"
down_revision = "0014"
branch_labels = None
depends_on = None

#: Marks the rows this migration owns, so `downgrade` removes exactly them.
SEED_MARK = "seed:0015"


def upgrade() -> None:
    bind = op.get_bind()

    sites = [r[0] for r in bind.execute(sa.text("SELECT code FROM sites"))]
    if not sites:
        # A brand-new database has no sites yet; onboarding applies the
        # catalogue instead. Nothing to do, and that is not a failure.
        return

    work_types = {
        code: wt_id
        for wt_id, code in bind.execute(sa.text("SELECT id, code FROM work_types"))
    }

    for site_code in sites:
        for template in CHECKLISTS:
            work_type_id = work_types.get(template["work_type_code"])
            if work_type_id is None:
                continue

            existing = bind.execute(
                sa.text(
                    "SELECT id FROM checklist_templates "
                    "WHERE site_code = :site AND work_type_id = :wt "
                    "AND variant IS NOT DISTINCT FROM :variant"
                ),
                {
                    "site": site_code,
                    "wt": work_type_id,
                    "variant": template["variant"],
                },
            ).scalar()

            if existing is None:
                template_id = uuid.uuid4().hex
                bind.execute(
                    sa.text(
                        "INSERT INTO checklist_templates "
                        "(id, site_code, work_type_id, name, variant, is_active) "
                        "VALUES (:id, :site, :wt, :name, :variant, true)"
                    ),
                    {
                        "id": template_id,
                        "site": site_code,
                        "wt": work_type_id,
                        "name": template["name"],
                        "variant": template["variant"],
                    },
                )
            else:
                template_id = existing
                # Already carries lines: this is a depot that has its own, and
                # replacing them would discard whatever it changed.
                has_items = bind.execute(
                    sa.text(
                        "SELECT 1 FROM checklist_items "
                        "WHERE template_id = :t LIMIT 1"
                    ),
                    {"t": template_id},
                ).scalar()
                if has_items:
                    continue

            for item in template["items"]:
                bind.execute(
                    sa.text(
                        "INSERT INTO checklist_items "
                        "(id, template_id, section, label, sort_order, "
                        " response_type, is_required, is_active, chart_key) "
                        "VALUES (:id, :t, :section, :label, :sort_order, "
                        " CAST(:response_type AS response_type_enum), "
                        " :is_required, true, :chart_key)"
                    ),
                    {
                        "id": uuid.uuid4().hex,
                        "t": template_id,
                        "section": item["section"] or "",
                        "label": item["label"],
                        "sort_order": item["sort_order"],
                        "response_type": item["response_type"],
                        "is_required": item["is_required"],
                        "chart_key": item["chart_key"],
                    },
                )


def downgrade() -> None:
    """Remove only what this migration could have added.

    An inspection answers a line, so a line that has been answered is part of a
    maintenance record and is not deleted — the template is left standing and
    the downgrade is a no-op for it.
    """
    bind = op.get_bind()
    work_types = {
        code: wt_id
        for wt_id, code in bind.execute(sa.text("SELECT id, code FROM work_types"))
    }

    for template in CHECKLISTS:
        work_type_id = work_types.get(template["work_type_code"])
        if work_type_id is None:
            continue
        labels = [item["label"] for item in template["items"]]
        bind.execute(
            sa.text(
                "DELETE FROM checklist_items ci "
                "USING checklist_templates ct "
                "WHERE ci.template_id = ct.id "
                "  AND ct.work_type_id = :wt "
                "  AND ct.variant IS NOT DISTINCT FROM :variant "
                "  AND ci.label = ANY(:labels) "
                "  AND NOT EXISTS ("
                "      SELECT 1 FROM inspection_results ir "
                "      WHERE ir.item_id = ci.id)"
            ),
            {
                "wt": work_type_id,
                "variant": template["variant"],
                "labels": labels,
            },
        )
