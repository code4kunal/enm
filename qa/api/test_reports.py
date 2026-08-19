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


def test_an_unavailable_chart_always_says_why(reader):
    """`available: false` with no reason is a blank grid with no explanation."""
    for c in reader.get(
        "/reports/control-charts", params={"site": REPORT_SITE}
    ).json():
        if not c["available"]:
            assert c["unavailable_reason"].strip(), (
                f"{c['kind']} is unavailable without saying why"
            )


def test_a_chart_fed_by_a_nominated_line_is_unavailable_without_one(reader):
    """Tyre pressure and bus washing read a checklist line the depot marks with
    `chart_key`. With no line marked there is no source at all, and a grid that
    reports itself available and renders blank cannot be told apart from a
    month where nobody checked.

    Coolant topping is deliberately not in this rule: it is wired to the
    coolant register, so an empty month there is real data.
    """
    by_kind = {
        c["kind"]: c
        for c in reader.get(
            "/reports/control-charts", params={"site": REPORT_SITE}
        ).json()
    }
    keys = {"tyrePressure": "tyre_pressure", "busWashing": "washing"}
    for kind in keys:
        spec = by_kind[kind]
        chart = reader.get(
            f"/sites/{REPORT_SITE}/reports/control-charts/{kind}",
            params={"month": REPORT_MONTH},
        ).json()
        filled = sum(
            1
            for row in chart["rows"]
            for cell in row.get("cells", [])
            if cell.get("value") not in (None, "", 0)
        )
        if filled == 0:
            assert not spec["available"], (
                f"{kind} renders blank but reports itself available"
            )
            assert not chart["available"], (
                f"{kind} chart body reports available while the catalogue does not"
            )
            assert keys[kind] in chart["unavailable_reason"], (
                f"{kind}'s reason should name the key that would fix it: "
                f"{chart['unavailable_reason']!r}"
            )


def test_the_catalogue_and_the_site_can_disagree(reader):
    """What the system can answer, versus what this depot can. The difference
    is the point: an unnominated line is a site problem, not a build problem.
    """
    catalogue = {c["kind"]: c["available"] for c in reader.get("/reports/control-charts").json()}
    at_site = {
        c["kind"]: c["available"]
        for c in reader.get("/reports/control-charts", params={"site": REPORT_SITE}).json()
    }
    assert set(catalogue) == set(at_site)
    # A site can never be able to answer something the system cannot.
    for kind, sys_ok in catalogue.items():
        if not sys_ok:
            assert not at_site[kind], f"{kind} unavailable system-wide but available at a site"
