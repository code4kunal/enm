"""The snag report: one sheet feeding several registers.

CLAUDE.md: "Don't parse import spreadsheets client-side. The server owns
parsing, validation and the row-level error report so there is exactly one
implementation." So these drive the real upload endpoints, and the thing they
care about most is that re-running a month changes nothing — that is what makes
a backfill safe to repeat.
"""
import json

import pytest

SNAG_MAPPING = {
    "date": "DATE",
    "bus": "VEHICLE NO",
    "work_type": "TYPE OF WORK",
    "complaint": "DRIVER COMPLAINT",
    "action": "ACTION TAKEN",
    "employee": "ATTEND BY",
}

HEADER = "DATE,VEHICLE NO,TYPE OF WORK,DRIVER COMPLAINT,ACTION TAKEN,ATTEND BY\n"


def _mappings():
    return json.dumps(
        [{"target_key": k, "source_column": v} for k, v in SNAG_MAPPING.items()]
    )


@pytest.fixture
def importer(client_for, personas, qa_bus, run_tag):
    """Upload helpers bound to the QA site's manager.

    Rows carry `run_tag` so a sheet is genuinely new on every run: an import is
    deduplicated on row content, and the scratch database survives between
    runs.
    """
    client = client_for("manager")
    site = personas["manager"].site

    def preview(body: str):
        return client.post(
            f"/sites/{site}/imports/preview",
            files={"file": ("snag.csv", body, "text/csv")},
            data={"target": "snagReport", "mappings": _mappings()},
        )

    def commit(token: str):
        return client.post(f"/sites/{site}/imports/commit", json={"token": token})

    def entry_count() -> int:
        return client.get("/entries", params={"site": site, "page_size": 1}).json()[
            "total"
        ]

    yield preview, commit, entry_count, client, site, qa_bus, run_tag
    client.close()


def test_a_sheet_previews_before_it_commits(importer):
    """Nothing is written until the operator has seen what will be."""
    preview, commit, count, _client, _site, bus, tag = importer
    before = count()
    r = preview(HEADER + f"2026-08-19,{bus},B.D,Preview probe {tag},Attended,Tushar\n")
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["total_rows"] == 1
    assert body["new_count"] == 1
    assert not body["errors"]
    assert count() == before, "preview wrote rows before the operator committed"

    assert commit(body["token"]).status_code == 200
    assert count() == before + 1


def test_re_importing_the_same_sheet_changes_nothing(importer):
    """The one that makes a backfill safe. A corrected sheet re-run used to
    double every figure the DMR and the control charts derive."""
    preview, commit, count, _client, _site, bus, tag = importer
    sheet = HEADER + (
        f"2026-08-18,{bus},B.D,Repeat probe {tag},Attended,Tushar\n"
        f"2026-08-18,{bus},D.C,Repeat AC {tag},Gas topped,Nilesh\n"
    )
    assert commit(preview(sheet).json()["token"]).status_code == 200
    settled = count()

    # The promise is about the register, not about the counters — see
    # qa/findings/2026-08-19-0008.md for the counters.
    for attempt in (2, 3):
        p = preview(sheet)
        assert p.status_code == 200
        assert commit(p.json()["token"]).status_code == 200
        assert count() == settled, (
            f"attempt {attempt} changed the register; a re-imported month "
            "must be a no-op"
        )


def test_a_bad_row_is_reported_by_row_number(importer):
    """The operator gets a row-level report, not a rejected file."""
    preview, _commit, _count, _client, _site, bus, tag = importer
    r = preview(
        HEADER
        + f"2026-08-19,{bus},B.D,Good row {tag},Attended,Tushar\n"
        + "2026-08-19,MH99ZZ9999,B.D,Unknown bus,Attended,Tushar\n"
    )
    assert r.status_code == 200, r.text
    errors = r.json()["errors"]
    assert errors, "an unknown bus was accepted silently"
    assert all("row_number" in e for e in errors)
    assert any(e["row_number"] >= 2 for e in errors), errors


def test_an_unrouted_work_type_is_rejected_by_name(importer):
    """A code the master does not route is refused loudly. Silently dropping
    it would lose a job nobody knows is missing."""
    preview, _commit, _count, _client, _site, bus, tag = importer
    r = preview(HEADER + f"2026-08-19,{bus},NONSENSE,Some work {tag},Attended,Tushar\n")
    assert r.status_code == 200, r.text
    errors = r.json()["errors"]
    assert errors, "an unknown TYPE OF WORK was accepted"
    assert any("NONSENSE" in json.dumps(e) for e in errors), errors


def test_a_commit_is_recorded_in_the_run_history(importer):
    """A permanent maintenance record needs to say where it came from."""
    preview, commit, _count, client, site, bus, tag = importer
    token = preview(
        HEADER + f"2026-08-17,{bus},B.D,History probe {tag},Attended,Tushar\n"
    ).json()["token"]
    run = commit(token).json()
    assert run["rows_accepted"] >= 1

    runs = client.get(f"/sites/{site}/imports").json()
    items = runs["items"] if isinstance(runs, dict) else runs
    assert any(r["id"] == run["id"] for r in items), "the commit left no run record"


def test_a_stale_token_cannot_be_committed_twice_into_new_rows(importer):
    """A preview is a staging artefact. Replaying it must not duplicate."""
    preview, commit, count, _client, _site, bus, tag = importer
    token = preview(
        HEADER + f"2026-08-16,{bus},B.D,Replay probe {tag},Attended,Tushar\n"
    ).json()["token"]
    assert commit(token).status_code == 200
    settled = count()

    again = commit(token)
    # Either the token is spent (4xx) or the fingerprint makes it a no-op.
    assert again.status_code >= 400 or count() == settled, (
        "replaying a committed preview created duplicate register rows"
    )


@pytest.mark.xfail(
    reason="qa/findings/2026-08-19-0008.md — `rows_accepted` counts rows that "
    "passed validation, not rows that reached a register, so it overstates by "
    "the number of duplicates and overlaps `rows_unchanged`.",
    strict=True,
)
def test_the_import_report_counts_what_it_wrote(importer):
    """Two rows in, one already present: one written, one recognised.

    The register total is right either way — fingerprinting works. This is
    about the account the operator is given of it.
    """
    preview, commit, count, _client, _site, bus, tag = importer
    first = HEADER + f"2026-08-14,{bus},B.D,Mixed OLD {tag},Attended,Tushar\n"
    assert commit(preview(first).json()["token"]).status_code == 200

    mixed = first + f"2026-08-14,{bus},D.C,Mixed NEW {tag},Gas topped,Nilesh\n"
    before = count()
    run = commit(preview(mixed).json()["token"]).json()
    written = count() - before

    assert written == 1, "the register itself is wrong, which is worse"
    assert run["rows_accepted"] == written, (
        f"reported {run['rows_accepted']} accepted, wrote {written}"
    )
    assert run["rows_accepted"] + run["rows_unchanged"] == 2, (
        "accepted and unchanged should partition the sheet, not overlap"
    )
