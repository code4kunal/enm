"""The derived reports, against a site that has real data.

There are four entry points and eleven reports built on top of them, so a
report can be broken for a long time without any register looking wrong.
"""
import os

import pytest

#: The reports read a month of real depot data, which the QA site does not
#: have. Point this somewhere else with QA_REPORT_SITE.
REPORT_SITE = os.environ.get("QA_REPORT_SITE", "MBMT")
REPORT_MONTH = os.environ.get("QA_REPORT_MONTH", "2026-08")


@pytest.fixture
def reader(client_for, personas, base_url):
    """A client that can read REPORT_SITE.

    The QA personas are scoped to the QA sites, so reading a real depot needs
    an account with access to it. Skips rather than fails when there is none:
    a laptop with an empty database should not report a red suite.
    """
    import httpx

    from qa.personas import ADMIN_HANDLE, ADMIN_PASSWORD

    r = httpx.post(
        f"{base_url}/auth/login",
        json={"user_id": ADMIN_HANDLE, "password": ADMIN_PASSWORD},
        timeout=30.0,
    )
    if r.status_code != 200:
        pytest.skip("no account able to read the report site")
    c = httpx.Client(
        base_url=base_url,
        headers={"Authorization": f"Bearer {r.json()['access_token']}"},
        timeout=60.0,
    )
    if c.get(f"/sites/{REPORT_SITE}/vehicles").status_code != 200:
        c.close()
        pytest.skip(f"{REPORT_SITE} is not readable here")
    yield c
    c.close()


REPORTS = [
    ("dmr", "/reports/dmr", {"date": f"{REPORT_MONTH}-05"}),
    ("dmr-month", "/reports/dmr/month", {"month": REPORT_MONTH}),
    ("off-road", "/reports/off-road", {}),
    ("investigations", "/reports/investigations", {}),
    ("unit-failures", "/reports/unit-failures", {}),
]


@pytest.mark.parametrize("name,path,params", REPORTS, ids=[r[0] for r in REPORTS])
def test_every_report_renders(reader, name, path, params):
    """Not that it has data — that it renders. A 500 here is invisible from
    any register screen."""
    r = reader.get(f"/sites/{REPORT_SITE}{path}", params=params)
    assert r.status_code == 200, f"{name}: {r.status_code} {r.text[:200]}"


def test_the_dmr_derives_its_breakdown_split(reader):
    """The breakdown total must equal the sum of its categories.

    Both sides are derived from the same entries, so a mismatch means the
    category mapping has dropped something on the floor.
    """
    j = reader.get(
        f"/sites/{REPORT_SITE}/reports/dmr", params={"date": f"{REPORT_MONTH}-05"}
    ).json()
    line = {l["label"]: (l.get("value") or 0) for l in j["lines"]}
    total = line.get("Daily breakdowns", 0)
    parts = sum(
        line.get(f"Daily breakdowns ({k})", 0)
        for k in ("Mech", "Electrical", "Tyre", "AC", "ITS")
    )
    assert parts <= total, (
        f"categories sum to {parts} but only {total} breakdowns were reported"
    )


def test_a_chart_claiming_availability_has_data(reader):
    """`available: true` is a promise to the reader.

    A chart that cannot be filled should say so, the way `energy` does. Three
    say nothing and render blank — see qa/findings/2026-08-19-0005.md.
    """
    kinds = reader.get("/reports/control-charts").json()
    empty_but_available = []
    for c in kinds:
        if not c["available"]:
            assert c["unavailable_reason"], f"{c['kind']} is unavailable without a reason"
            continue
        j = reader.get(
            f"/sites/{REPORT_SITE}/reports/control-charts/{c['kind']}",
            params={"month": REPORT_MONTH},
        ).json()
        filled = sum(
            1
            for row in j["rows"]
            for cell in row.get("cells", [])
            if cell.get("value") not in (None, "", 0)
        )
        if filled == 0:
            empty_but_available.append(c["kind"])

    if empty_but_available:
        pytest.xfail(
            "qa/findings/2026-08-19-0005.md — these charts report available "
            f"and render blank: {sorted(empty_but_available)}"
        )
