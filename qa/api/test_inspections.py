"""Inspections and the checklists they are filled against.

An inspection is a checklist sweep, not a register entry: D.I and the ten-day
service have their own form and their own record. What matters most here is
that every bus on the fleet has something to tick — a bus that maps to an empty
template produces an inspection recording nothing, and reads afterwards exactly
like one where every check passed.
"""
import os

import pytest

REPORT_SITE = os.environ.get("QA_REPORT_SITE", "MBMT")

#: The two sweeps seeded from the depot's own sheets. `P.M` is deliberately
#: empty — the docking checklists exist only as PDFs that do not survive text
#: extraction, and PENDING section 5 records why nothing was shipped.
SWEEPS_WITH_CHECKS = ("D.I", "10 DAYS SERVICE")


@pytest.fixture(scope="module")
def depot(base_url):
    import httpx

    from qa.personas import ADMIN_HANDLE, ADMIN_PASSWORD

    r = httpx.post(
        f"{base_url}/auth/login",
        json={"user_id": ADMIN_HANDLE, "password": ADMIN_PASSWORD},
        timeout=30.0,
    )
    if r.status_code != 200:
        pytest.skip("no account able to read the depot site")
    c = httpx.Client(
        base_url=base_url,
        headers={"Authorization": f"Bearer {r.json()['access_token']}"},
        timeout=90.0,
    )
    if c.get(f"/sites/{REPORT_SITE}/vehicles").status_code != 200:
        c.close()
        pytest.skip(f"{REPORT_SITE} not readable here")
    yield c
    c.close()


@pytest.fixture(scope="module")
def checklists(depot):
    j = depot.get(f"/sites/{REPORT_SITE}/checklists").json()
    return j["items"] if isinstance(j, dict) else j


@pytest.fixture(scope="module")
def fleet(depot):
    return depot.get(f"/sites/{REPORT_SITE}/vehicles").json()["items"]


@pytest.mark.parametrize("code", SWEEPS_WITH_CHECKS)
def test_every_active_bus_has_something_to_tick(checklists, fleet, code):
    """The trap this guards: a bus with no `checklist_variant` falls back to a
    template with zero items, and its inspection records nothing at all. Every
    bus carries a variant today. The next one onboarded might not.
    """
    templates = {
        t["variant"]: t for t in checklists if t["work_type_code"] == code
    }
    assert templates, f"{code} has no checklist at all"

    empty = []
    for bus in fleet:
        if not bus.get("is_active", True):
            continue
        variant = bus.get("checklist_variant")
        template = templates.get(variant) or templates.get(None)
        if template is None or not template.get("items"):
            empty.append((bus["registration_no"], variant))
    assert not empty, (
        f"{code}: these buses map to a checklist with no checks — an "
        f"inspection against it records nothing: {empty[:6]}"
    )


def test_the_docking_checklist_is_empty_on_purpose(checklists):
    """Pinned so a future reader does not mistake a deliberate gap for a bug,
    and so shipping the docking sheets shows up here as a failure to update.
    See PENDING section 5."""
    pm = [t for t in checklists if t["work_type_code"] == "P.M"]
    if not pm:
        pytest.skip("no P.M checklist on this site")
    assert all(not t["items"] for t in pm), (
        "the docking checklist has checks now — PENDING section 5 and this "
        "test both need updating"
    )


@pytest.mark.parametrize("code", SWEEPS_WITH_CHECKS)
def test_a_checklist_line_is_never_blank(checklists, code):
    """A blank line on a maintenance record is worse than a missing one: it
    reads as a check that exists and was not done."""
    for t in [x for x in checklists if x["work_type_code"] == code]:
        for item in t["items"]:
            assert (item.get("label") or "").strip(), (
                f"{code}/{t['variant']} has an unlabelled check: {item}"
            )


def _pairing(fleet, checklists, code="D.I"):
    """A template with checks, and a bus that takes its variant."""
    for t in checklists:
        if t["work_type_code"] != code or not t["items"]:
            continue
        bus = next(
            (b for b in fleet if b.get("checklist_variant") == t["variant"]), None
        )
        if bus:
            return t, bus
    return None, None


def test_an_inspection_can_be_filed(depot, fleet, checklists, run_tag):
    """The record itself, before its contents."""
    template, bus = _pairing(fleet, checklists)
    if template is None:
        pytest.skip("no D.I checklist paired with a bus")
    r = depot.post(
        f"/sites/{REPORT_SITE}/inspections",
        json={
            "vehicle_id": bus["id"],
            "work_type_id": template["work_type_id"],
            "inspected_on": "2026-07-05",
            "done_by": f"QA floor {run_tag}",
            "results": [],
        },
    )
    assert r.status_code in (200, 201, 409), r.text


@pytest.mark.xfail(
    reason="qa/findings/2026-08-19-0009.md — create_inspection resolves the "
    "site's variant-less template, which holds no items, so every real "
    "checklist answer is rejected as unknown. 90 inspections in MBMT's data, "
    "zero recorded answers.",
    strict=True,
)
def test_an_inspection_records_the_answers_given(depot, fleet, checklists):
    """A sweep that records no answers records nothing.

    The date is deliberately one with no inspection yet: the duplicate check
    runs before the item lookup, so a 409 hides this entirely.
    """
    template, bus = _pairing(fleet, checklists)
    if template is None:
        pytest.skip("no D.I checklist paired with a bus")

    answers = [{"item_id": i["id"], "result": "ok"} for i in template["items"][:3]]
    r = depot.post(
        f"/sites/{REPORT_SITE}/inspections",
        json={
            "vehicle_id": bus["id"],
            "work_type_id": template["work_type_id"],
            "inspected_on": "2026-06-11",
            "done_by": "QA floor",
            "results": answers,
        },
    )
    assert r.status_code in (200, 201), (
        f"a checklist answer from this site's own checklist was refused: "
        f"{r.text}"
    )
    assert len(r.json().get("results", [])) == len(answers)


def test_the_calendar_covers_the_window_it_reports(depot):
    """The scheduler's own arithmetic: as many days as it says it spans."""
    from datetime import date

    j = depot.get(
        f"/sites/{REPORT_SITE}/inspections/calendar", params={"month": "2026-08"}
    ).json()
    start = date.fromisoformat(j["from_date"])
    end = date.fromisoformat(j["to_date"])
    assert len(j["days"]) == (end - start).days + 1, (
        f"calendar returned {len(j['days'])} days for {start}..{end}"
    )
    # `scheduled` counts slots still awaiting their sweep, not every slot:
    # a missed or completed one is returned too but is not outstanding work.
    outstanding = sum(
        1 for d in j["days"] for s in d["slots"] if s["status"] == "scheduled"
    )
    assert j["scheduled"] == outstanding, (
        f"header says {j['scheduled']} outstanding, grid holds {outstanding}"
    )
    statuses = {s["status"] for d in j["days"] for s in d["slots"]}
    assert statuses <= {"scheduled", "missed", "done"}, f"unknown slot status: {statuses}"
