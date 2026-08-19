"""Who hears about a breakdown, and who does not.

A breakdown opening is the one event the app pushes at people. It has to reach
the supervisors and managers of that site and nobody else — a notification is a
tenant leak the same way a register row is.
"""
import pytest

BUS = "MH00QA0001"


def _open_breakdown(client, site, complaint):
    return client.post(
        "/entries",
        json={
            "register": "breakdown",
            "site": site,
            "date": "2026-08-19",
            "data": {"bus_no": BUS, "complaint": complaint},
        },
    )


def test_opening_a_breakdown_reaches_the_sites_supervisor(
    client_for, personas, qa_bus, run_tag
):
    site = personas["manager"].site
    with client_for("supervisor") as sup:
        before = sup.get("/notifications/unread-count").json()["unread"]

    with client_for("manager") as mgr:
        r = _open_breakdown(mgr, site, f"Notification probe {run_tag}")
        assert r.status_code == 201, r.text

    with client_for("supervisor") as sup:
        after = sup.get("/notifications/unread-count").json()["unread"]
        assert after > before, "the supervisor was not told about a breakdown"
        items = sup.get("/notifications").json()["items"]
        assert any(n["type"] == "breakdown_opened" for n in items)


def test_a_breakdown_does_not_reach_another_site(
    client_for, personas, qa_bus, run_tag
):
    """QA_OTHER manages a different site. A notification crossing that line
    leaks a bus number and a fault to a depot with no business seeing it."""
    site = personas["manager"].site
    with client_for("other_manager") as other:
        before = other.get("/notifications/unread-count").json()["unread"]

    with client_for("manager") as mgr:
        assert _open_breakdown(
            mgr, site, f"Tenant probe {run_tag}"
        ).status_code == 201

    with client_for("other_manager") as other:
        after = other.get("/notifications/unread-count").json()["unread"]
        assert after == before, (
            f"a manager of {personas['other_manager'].site} was notified about "
            f"{site}'s breakdown"
        )


def test_reading_one_notification_lowers_the_count_by_one(
    client_for, personas, qa_bus, run_tag
):
    site = personas["manager"].site
    with client_for("manager") as mgr:
        _open_breakdown(mgr, site, f"Read probe {run_tag}")

    with client_for("supervisor") as sup:
        items = sup.get("/notifications").json()["items"]
        unread = [n for n in items if not n.get("read_at")]
        if not unread:
            pytest.skip("nothing unread to read")
        before = sup.get("/notifications/unread-count").json()["unread"]
        assert sup.post(f"/notifications/{unread[0]['id']}/read").status_code in (
            200,
            204,
        )
        after = sup.get("/notifications/unread-count").json()["unread"]
        assert after == before - 1, f"unread went {before} -> {after}"


def test_read_all_clears_the_badge(client_for, personas, qa_bus, run_tag):
    site = personas["manager"].site
    with client_for("manager") as mgr:
        _open_breakdown(mgr, site, f"Read-all probe {run_tag}")

    with client_for("supervisor") as sup:
        assert sup.post("/notifications/read-all").status_code in (200, 204)
        assert sup.get("/notifications/unread-count").json()["unread"] == 0


def test_a_notification_never_carries_another_sites_work(client_for, personas):
    """Whatever is in the list, all of it belongs to a site the reader can see."""
    with client_for("other_manager") as other:
        items = other.get("/notifications").json()["items"]
    allowed = {personas["other_manager"].site}
    for n in items:
        if n.get("site_code"):
            assert n["site_code"] in allowed, (
                f"notification from {n['site_code']} reached a manager of {allowed}"
            )
