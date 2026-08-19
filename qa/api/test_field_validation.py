"""Every field, every register, against what the depot was promised.

The register payload is `{"type": "object"}` in the published schema — the five
field lists are not in the contract at all — so these expectations come from
design/HANDOFF.md section 4 and CLAUDE.md's conventions, not from the API's own
models. See qa/findings/2026-08-19-0007.md.
"""
import pytest

REQUIRED_BY_REGISTER = {
    "work_done": "reported_defects",
    "driver_complaint": "complaint",
    "breakdown": "complaint",
}

BUS = "MH00QA0001"


def _post(client, site, register, data, **envelope):
    body = {"register": register, "site": site, "date": "2026-08-19", "data": data}
    body.update(envelope)
    return client.post("/entries", json=body)


@pytest.fixture
def mgr(client_for, personas, qa_bus):
    with client_for("manager") as c:
        yield c, personas["manager"].site


# --- required fields -------------------------------------------------------


@pytest.mark.parametrize("register,field", sorted(REQUIRED_BY_REGISTER.items()))
def test_a_required_field_is_named_in_the_error(mgr, register, field):
    """HANDOFF marks these with a red asterisk, and the form shows an inline
    error against the field — so the API has to say which field."""
    client, site = mgr
    r = _post(client, site, register, {"bus_no": BUS})
    assert r.status_code == 400
    assert r.json()["error"]["fields"].get(field) == "required"


@pytest.mark.parametrize("register,field", sorted(REQUIRED_BY_REGISTER.items()))
@pytest.mark.parametrize("blank", ["", "   ", "\t\n"])
def test_whitespace_does_not_satisfy_a_required_field(mgr, register, field, blank):
    """A register line reading "   " is a missing record, not a filled one."""
    client, site = mgr
    r = _post(client, site, register, {"bus_no": BUS, field: blank})
    assert r.status_code == 400, f"{register}.{field}={blank!r} was accepted"
    assert field in r.json()["error"]["fields"]


# --- the bus master --------------------------------------------------------


@pytest.mark.parametrize(
    "typed", [" mh00 qa0001 ", "mh00qa0001", "MH00 QA0001", "  MH00QA0001"]
)
def test_a_bus_number_is_normalised_however_it_is_typed(mgr, typed):
    """CLAUDE.md: stored uppercase with no whitespace. A fitter typing on a
    phone at 6am should not have an entry rejected over a space."""
    client, site = mgr
    r = _post(client, site, "work_done", {"bus_no": typed, "reported_defects": "x"})
    assert r.status_code == 201, f"{typed!r} was rejected: {r.text}"
    assert r.json()["data"]["bus_no"] == BUS


def test_a_bus_that_is_not_on_this_site_is_refused(mgr):
    client, site = mgr
    r = _post(client, site, "work_done", {"bus_no": "MH99ZZ9999", "reported_defects": "x"})
    assert r.status_code == 400
    assert "bus_no" in r.json()["error"]["fields"]


# --- master lists ----------------------------------------------------------


@pytest.mark.parametrize("field", ["defect_type", "defect_source"])
def test_a_dropdown_value_must_exist_in_its_master(mgr, field):
    """CLAUDE.md: "Don't let a dropdown value reach an entry without an FK to
    its master table." """
    client, site = mgr
    r = _post(
        client,
        site,
        "work_done",
        {"bus_no": BUS, "reported_defects": "x", field: "NOT A REAL VALUE"},
    )
    assert r.status_code == 400
    assert r.json()["error"]["fields"].get(field) == "not in master list"


# --- shape -----------------------------------------------------------------


def test_an_unknown_field_is_refused_rather_than_dropped(mgr):
    """Silently dropping an unknown key is how a client ships a typo into a
    permanent record and never learns."""
    client, site = mgr
    r = _post(client, site, "work_done",
              {"bus_no": BUS, "reported_defects": "x", "nonsense": "y"})
    assert r.status_code == 400
    assert "nonsense" in r.json()["error"]["fields"]


def test_the_shift_is_one_of_the_three_the_depot_runs(mgr):
    client, site = mgr
    r = _post(client, site, "work_done",
              {"bus_no": BUS, "reported_defects": "x", "shift": "Z"})
    assert r.status_code == 400
    assert "shift" in r.json()["error"]["fields"]


@pytest.mark.parametrize(
    "register,field,value",
    [
        ("coolant", "bcs_litres", -5),
        ("coolant", "tcs_litres", -0.1),
        ("coolant", "bcs_litres", 10**9),
        ("breakdown", "loss_km", -1),
    ],
)
def test_a_quantity_outside_its_range_is_refused(mgr, register, field, value):
    client, site = mgr
    data = {"bus_no": BUS, field: value}
    if register == "breakdown":
        data["complaint"] = "x"
    r = _post(client, site, register, data)
    assert r.status_code == 400, f"{register}.{field}={value} was accepted"
    assert field in r.json()["error"]["fields"]


@pytest.mark.parametrize("bad", ["25:99", "99:99", "half past two"])
def test_an_impossible_time_is_refused(mgr, bad):
    client, site = mgr
    r = _post(client, site, "breakdown",
              {"bus_no": BUS, "complaint": "x", "breakdown_time": bad})
    assert r.status_code == 400, f"breakdown_time={bad!r} was accepted"


def test_seconds_are_truncated_rather_than_rejected(mgr):
    """CLAUDE.md says times are HH:mm. Accepting HH:mm:ss and storing HH:mm is
    the right kind of leniency — it is what a picker sends."""
    client, site = mgr
    r = _post(client, site, "breakdown",
              {"bus_no": BUS, "complaint": "x", "breakdown_time": "14:20:59"})
    assert r.status_code == 201, r.text
    assert r.json()["data"]["breakdown_time"] == "14:20"


@pytest.mark.parametrize("bad", ["19-08-2026", "2026-02-30", "not a date"])
def test_an_impossible_date_is_refused(mgr, bad):
    client, site = mgr
    r = _post(client, site, "work_done",
              {"bus_no": BUS, "reported_defects": "x"}, date=bad)
    assert r.status_code == 400, f"date={bad!r} was accepted"


@pytest.mark.parametrize("far", ["2099-01-01", "2262-01-01", "1900-01-01"])
@pytest.mark.xfail(
    reason="qa/findings/2026-08-19-0006.md — any date is accepted, so a typed "
    "year silently creates a record no period filter will ever show.",
    strict=True,
)
def test_a_date_far_outside_the_fleet_lifetime_is_refused(mgr, far):
    client, site = mgr
    r = _post(client, site, "work_done",
              {"bus_no": BUS, "reported_defects": "x"}, date=far)
    assert r.status_code == 400, f"date={far} was accepted"
