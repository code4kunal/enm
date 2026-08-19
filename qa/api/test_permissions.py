"""Who may write to which register, and who may reach another site's data.

Expectations come from CLAUDE.md's role ladder — admin > manager > supervisor
> executive — and from its claim that the server re-checks `site_access` on
every request. They do not come from reading the API's permission code. A test
that reads the implementation inherits the implementation's blind spots.
"""
import pytest

#: Four, not the five HANDOFF describes. `pm_schedule` was retired in favour of
#: Inspections and the handoff was never amended — see
#: qa/findings/2026-08-19-0003.md.
LIVE_REGISTERS = [
    "work_done",
    "coolant",
    "driver_complaint",
    "breakdown",
]

WRITING_ROLES = ["manager", "supervisor"]


def _minimal_entry(register: str, site: str, bus_no: str) -> dict:
    """The smallest body each register accepts, per design/HANDOFF.md section 4."""
    required = {
        "work_done": {"bus_no": bus_no, "reported_defects": "QA probe"},
        "coolant": {"bus_no": bus_no},
        "driver_complaint": {"bus_no": bus_no, "complaint": "QA probe"},
        "breakdown": {"bus_no": bus_no, "complaint": "QA probe"},
        "pm_schedule": {"bus_no": bus_no, "defects_noticed": "QA probe"},
    }[register]
    return {
        "register": register,
        "site": site,
        "date": "2026-08-19",
        "data": required,
    }


@pytest.mark.parametrize("register", LIVE_REGISTERS)
@pytest.mark.parametrize("role", WRITING_ROLES)
def test_the_seats_that_keep_the_registers_can_file(
    client_for, personas, register, role, qa_bus
):
    body = _minimal_entry(register, personas[role].site, qa_bus)
    with client_for(role) as c:
        r = c.post("/entries", json=body)
    assert r.status_code == 201, f"{role} should be able to file {register}: {r.text}"


@pytest.mark.parametrize("register", LIVE_REGISTERS)
@pytest.mark.xfail(
    reason="qa/findings/2026-08-19-0002.md — an executive is named the least "
    "privileged role but writes like a manager. Ruling needed; the assertion "
    "is left as the role ladder implies rather than changed to match the code.",
    strict=True,
)
def test_an_executive_may_not_file_work(client_for, personas, register, qa_bus):
    body = _minimal_entry(register, personas["executive"].site, qa_bus)
    with client_for("executive") as c:
        r = c.post("/entries", json=body)
    assert r.status_code == 403, (
        f"an executive filed {register} and got {r.status_code}"
    )


@pytest.mark.parametrize("role", WRITING_ROLES)
def test_the_pm_register_is_retired(client_for, personas, role, qa_bus):
    """Retired deliberately, in favour of Inspections. Pinned so the reason
    survives: a bare 400 here would look like a regression to the next reader.
    See qa/findings/2026-08-19-0003.md."""
    body = _minimal_entry("pm_schedule", personas[role].site, qa_bus)
    with client_for(role) as c:
        r = c.post("/entries", json=body)
    assert r.status_code == 400
    assert r.json()["error"]["fields"]["register"] == "retired"
    assert "replaced by Inspections" in r.json()["error"]["message"]


@pytest.mark.parametrize("register", LIVE_REGISTERS)
def test_a_manager_cannot_read_another_site(client_for, personas, register):
    """The tenant boundary. QA_OTHER manages a different site entirely, and
    CLAUDE.md claims the server re-checks site_access on every request."""
    victim = personas["manager"].site
    with client_for("other_manager") as c:
        r = c.get("/entries", params={"site": victim, "register": register})
    assert r.status_code == 403, (
        f"a manager of {personas['other_manager'].site} read {victim}'s "
        f"{register} and got {r.status_code}"
    )
