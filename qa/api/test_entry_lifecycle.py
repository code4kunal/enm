"""What happens to an entry after it is filed.

HANDOFF section 5 promises the Edit button "opens the entry form prefilled;
save updates in place". That is a read-modify-write, so the shape the API
returns has to be a shape it accepts.
"""
import pytest

from qa.api.test_permissions import LIVE_REGISTERS, _minimal_entry


@pytest.fixture
def an_entry(client_for, personas, qa_bus):
    """One entry per register, filed by the manager, for editing tests."""

    def _make(register: str) -> dict:
        with client_for("manager") as c:
            r = c.post(
                "/entries",
                json=_minimal_entry(register, personas["manager"].site, qa_bus),
            )
            assert r.status_code == 201, r.text
            return r.json()

    return _make


@pytest.mark.parametrize("register", LIVE_REGISTERS)
def test_an_entry_can_be_written_back_unchanged(
    client_for, personas, register, an_entry
):
    """The response has to be usable as a request.

    An edit form reads an entry, changes one field and writes it back. If the
    server emits a key it will not accept, every client must know to strip it
    and nothing in the contract says which.
    """
    entry = an_entry(register)
    body = {
        "register": register,
        "site": personas["manager"].site,
        "date": entry["date"],
        "data": entry["data"],
    }
    with client_for("manager") as c:
        r = c.put(f"/entries/{entry['id']}", json=body)

    if register == "breakdown":
        pytest.xfail(
            "qa/findings/2026-08-19-0004.md — GET emits `resolved_at` inside a "
            "breakdown's data and PUT forbids it, so a breakdown cannot be "
            "round-tripped."
        )
    assert r.status_code == 200, (
        f"{register} could not be written back unchanged: {r.text}"
    )


def test_editing_a_breakdown_moves_the_derived_report(
    client_for, personas, an_entry
):
    """Derived reports must follow their source.

    The DMR is computed on read, so an edit should show up immediately. This
    pins that: a cache or a nightly freeze added later would break it loudly.
    """
    site = personas["manager"].site
    entry = an_entry("breakdown")

    def loss_line() -> float:
        with client_for("manager") as c:
            j = c.get(
                f"/sites/{site}/reports/dmr", params={"date": entry["date"]}
            ).json()
        for line in j["lines"]:
            if line["label"] == "Loss of Kms due to breakdowns":
                return float(line.get("value") or 0)
        raise AssertionError("the DMR has no loss-of-kms line")

    before = loss_line()

    data = {k: v for k, v in entry["data"].items() if k != "resolved_at"}
    data["loss_km"] = 42.5
    data["defect_type"] = "ELECTRICAL"
    with client_for("manager") as c:
        r = c.put(
            f"/entries/{entry['id']}",
            json={
                "register": "breakdown",
                "site": site,
                "date": entry["date"],
                "data": data,
            },
        )
    assert r.status_code == 200, r.text

    assert loss_line() == pytest.approx(before + 42.5), (
        "the DMR did not follow the edit"
    )
