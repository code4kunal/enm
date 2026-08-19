"""The derived reports, cross-checked against the entries they come from.

Four registers carry eleven reports. A report can be wrong for a month without
any register screen looking odd, so these do not ask "did it render" — they ask
"does it agree with the source".

Runs against a site with a real month of data (the QA stack clones dev).
"""
import collections
import os

import pytest

REPORT_SITE = os.environ.get("QA_REPORT_SITE", "MBMT")
REPORT_MONTH = os.environ.get("QA_REPORT_MONTH", "2026-08")


@pytest.fixture(scope="module")
def admin(base_url):
    """A reader for the depot site. The QA personas are scoped to QA sites."""
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
        timeout=120.0,
    )
    if c.get(f"/sites/{REPORT_SITE}/vehicles").status_code != 200:
        c.close()
        pytest.skip(f"{REPORT_SITE} not readable here")
    yield c
    c.close()


@pytest.fixture(scope="module")
def breakdowns(admin):
    """Ground truth: every breakdown on the site, straight from the register."""
    per_day = collections.Counter()
    loss = collections.Counter()
    page = 1
    while True:
        j = admin.get(
            "/entries",
            params={
                "site": REPORT_SITE,
                "register": "breakdown",
                "page": page,
                "page_size": 200,
            },
        ).json()
        for e in j["items"]:
            per_day[e["date"]] += 1
            loss[e["date"]] += float(e["data"].get("loss_km") or 0)
        if page * 200 >= j["total"]:
            break
        page += 1
    if not per_day:
        pytest.skip("no breakdowns on the report site")
    return per_day, loss


def _day_lines(admin, day):
    j = admin.get(f"/sites/{REPORT_SITE}/reports/dmr", params={"date": day}).json()
    return {l["label"]: l.get("value") for l in j["lines"]}


def test_the_dmr_counts_the_breakdowns_that_exist(admin, breakdowns):
    """Line 13 against the register itself, every day that has one."""
    per_day, _ = breakdowns
    wrong = []
    for day, n in sorted(per_day.items()):
        reported = _day_lines(admin, day).get("Daily breakdowns") or 0
        if abs(reported - n) > 1e-9:
            wrong.append((day, n, reported))
    assert not wrong, f"DMR disagrees with the register on: {wrong}"


def test_the_dmr_totals_the_loss_kms_that_were_recorded(admin, breakdowns):
    per_day, loss = breakdowns
    wrong = []
    for day in sorted(per_day):
        reported = _day_lines(admin, day).get("Loss of Kms due to breakdowns") or 0
        if abs(reported - loss[day]) > 0.01:
            wrong.append((day, round(loss[day], 2), reported))
    assert not wrong, f"DMR loss-kms disagrees with the register on: {wrong}"


def test_the_breakdown_split_never_exceeds_the_total(admin, breakdowns):
    """Both sides derive from the same rows, so the categories cannot outnumber
    the breakdowns they categorise."""
    per_day, _ = breakdowns
    for day in sorted(per_day):
        line = _day_lines(admin, day)
        total = line.get("Daily breakdowns") or 0
        parts = sum(
            line.get(f"Daily breakdowns ({k})") or 0
            for k in ("Mech", "Electrical", "Tyre", "AC", "ITS")
        )
        assert parts <= total, f"{day}: categories {parts} > total {total}"


def test_the_month_grid_agrees_with_the_day_view(admin):
    """Two endpoints, one truth. The month grid is what the depot prints."""
    m = admin.get(
        f"/sites/{REPORT_SITE}/reports/dmr/month", params={"month": REPORT_MONTH}
    ).json()
    label = {l["key"]: l["label"] for l in m["lines"]}
    keys = [
        k
        for k in ("breakdowns", "breakdowns_mechanical", "breakdowns_electrical",
                  "driver_complaints", "total_fleet")
        if k in m["values"]
    ]
    wrong = []
    for i, day in enumerate(m["dates"]):
        day_line = _day_lines(admin, day)
        for k in keys:
            grid = m["values"][k][i]
            single = day_line.get(label[k])
            if (grid or 0) != (single or 0):
                wrong.append((day, label[k], grid, single))
    assert not wrong, f"month grid and day view disagree: {wrong[:5]}"


EXPORTS = [
    ("dmr", "/reports/dmr/export", {"month": REPORT_MONTH}, "csv"),
    ("dmr-day", "/reports/dmr/day/export", {"date": f"{REPORT_MONTH}-05"}, "pdf"),
    ("off-road", "/reports/off-road/export", {}, "pdf"),
    ("investigations", "/reports/investigations/export", {}, "pdf"),
    ("unit-failures", "/reports/unit-failures/export", {}, "csv"),
]


@pytest.mark.parametrize("name,path,params,kind", EXPORTS, ids=[e[0] for e in EXPORTS])
def test_every_export_produces_a_real_file(admin, name, path, params, kind):
    """A depot prints these. An export that 200s with an empty body is worse
    than one that fails, because nobody notices until the meeting."""
    r = admin.get(f"/sites/{REPORT_SITE}{path}", params=params)
    assert r.status_code == 200, f"{name}: {r.status_code} {r.text[:160]}"
    assert r.content, f"{name}: empty body"
    if kind == "pdf":
        assert r.content[:4] == b"%PDF", f"{name}: not a PDF"
    else:
        assert r.text.strip(), f"{name}: empty CSV"


def test_every_control_chart_exports(admin):
    kinds = [c["kind"] for c in admin.get("/reports/control-charts").json()]
    assert kinds, "no control charts are declared"
    for kind in kinds:
        r = admin.get(
            f"/sites/{REPORT_SITE}/reports/control-charts/{kind}/export",
            params={"month": REPORT_MONTH},
        )
        assert r.status_code == 200, f"{kind}: {r.status_code}"
        assert r.text.strip(), f"{kind}: empty CSV"


def test_a_chart_covers_every_bus_on_the_fleet(admin):
    """A chart with a missing row is a bus nobody will notice going unserviced."""
    fleet = len(admin.get(f"/sites/{REPORT_SITE}/vehicles").json()["items"])
    for kind in [c["kind"] for c in admin.get("/reports/control-charts").json()]:
        j = admin.get(
            f"/sites/{REPORT_SITE}/reports/control-charts/{kind}",
            params={"month": REPORT_MONTH},
        ).json()
        assert len(j["rows"]) == fleet, (
            f"{kind}: {len(j['rows'])} rows for a fleet of {fleet}"
        )
