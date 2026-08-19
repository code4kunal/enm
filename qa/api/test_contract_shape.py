"""The published schema has to describe the registers.

`backend/README.md` calls itself the authority on the wire format and
CLAUDE.md calls the contract the seam. A client that cannot learn the five
register field lists from the contract has to read the server's source, which
is not a contract at all.
"""
import httpx
import pytest

REGISTER_MODELS = {
    "work_done": "WorkDoneData",
    "coolant": "CoolantData",
    "driver_complaint": "DriverComplaintData",
    "breakdown": "BreakdownData",
}


@pytest.fixture(scope="module")
def schema(base_url):
    r = httpx.get(f"{base_url}/openapi.json", timeout=30.0)
    assert r.status_code == 200, "the API publishes no schema"
    return r.json()


@pytest.mark.parametrize("register,model", sorted(REGISTER_MODELS.items()))
def test_every_register_payload_is_published(schema, register, model):
    assert model in schema["components"]["schemas"], (
        f"{register}'s payload is not in the contract"
    )


def test_the_data_field_points_at_the_shapes_it_may_take(schema):
    data = schema["components"]["schemas"]["EntryCreate"]["properties"]["data"]
    assert "oneOf" in data, "`data` is still an untyped object"
    refs = {o["$ref"].rsplit("/", 1)[-1] for o in data["oneOf"]}
    assert set(REGISTER_MODELS.values()) <= refs


def test_a_breakdown_declares_the_fields_it_actually_takes(schema):
    """The two that finding 0004 turned on: `resolved_at` is lifecycle state
    and must not be in the payload; `route` is a real column and must be."""
    props = schema["components"]["schemas"]["BreakdownData"]["properties"]
    assert "resolved_at" not in props
    assert "route" in props
    assert set(schema["components"]["schemas"]["BreakdownData"]["required"]) == {
        "bus_no",
        "complaint",
    }


@pytest.mark.parametrize("register,model", sorted(REGISTER_MODELS.items()))
def test_the_published_required_fields_are_the_enforced_ones(
    schema, client_for, personas, qa_bus, register, model
):
    """A contract that says a field is required, on an API that accepts it
    missing, is worse than no contract."""
    required = set(schema["components"]["schemas"][model].get("required", []))
    site = personas["manager"].site
    for field in required:
        if field == "bus_no":
            continue
        data = {"bus_no": qa_bus, **{f: "x" for f in required if f != "bus_no"}}
        data.pop(field)
        with client_for("manager") as c:
            r = c.post(
                "/entries",
                json={
                    "register": register,
                    "site": site,
                    "date": "2026-08-19",
                    "data": data,
                },
            )
        assert r.status_code == 400, (
            f"{model}.{field} is published as required but was accepted missing"
        )


def test_the_client_knows_every_import_target_the_server_can_send(schema):
    """An enum the client does not fully know is a silent rewrite waiting.

    `ImportTarget.fromName` falls back to `vehicles` for anything it does not
    recognise, so a profile the server calls `snagReport` reads as a Vehicles
    import — and saving it from that screen writes `vehicles` back, replacing
    the depot's monthly snag mapping with something that was never configured.
    Nothing errors. See qa/findings/2026-08-19-0010.md.

    `tools/check_contract.py` cannot catch this: it compares Dart casts against
    schema types, and an enum's *members* are neither.
    """
    from pathlib import Path as _Path

    server = set(schema["components"]["schemas"]["ImportTarget"]["enum"])

    dart = _Path("app/lib/models/site_import.dart").read_text()
    body = dart[dart.index("enum ImportTarget {") : dart.index("const ImportTarget(")]
    client = {
        line.strip().split("(")[0]
        for line in body.splitlines()
        if line.strip() and line.strip()[0].islower() and "(" in line
    }

    missing = server - client
    assert not missing, (
        f"the server can return these import targets and the client would "
        f"silently read them as `vehicles`: {sorted(missing)}"
    )
