"""put the depot's checklists in the database, not in a spreadsheet

Revision ID: 0014
Revises: 0013
Create Date: 2026-08-19

`0006` built the checklist tables and `0011` gave them variants, but the lines
themselves only ever arrived by running `scripts/seed_checklists.py` against
MBMT's own D.I and ten-day workbooks. Those files are not in the repository and
never will be — `.gitignore` keeps a customer's operational records out of the
history — so a fresh database migrated to head had the tables and nothing to
put in them, and a deployment could not reproduce a single check.

The lines are 211 rows of short text, about 15 kB. That is small enough to be
data rather than an import, so it lives in `app/seeds/checklists_v1.py` and is
applied here.

Applied per site, for every site that exists. A site with checks already — MBMT,
seeded from the sheets — is left exactly as it is: this fills a gap, it does not
overwrite a depot's own edits.

Sites onboarded later are not covered by a migration that has already run. That
is `app/services/checklists.py::apply_catalogue`, called when a site is created.
"""
from __future__ import annotations

import uuid

import sqlalchemy as sa
from alembic import op

from app.seeds.checklists_v1 import CHECKLISTS

revision = "0014"
down_revision = "0013"
branch_labels = None
depends_on = None

#: Marks the rows this migration owns, so `downgrade` removes exactly them and
#: leaves anything the depot wrote by hand alone.
SEED_MARK = "seed:0014"


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
