"""Publish the register payloads in the schema.

`EntryCreate.data` is a plain object at runtime because the register decides
which shape it takes, and that dispatch happens in `validate_data`. The cost
was that the schema said `{"type": "object"}` and nothing more: the five field
lists — the heart of the contract, one per paper register — appeared nowhere a
client could read them.

That left `tools/check_contract.py` unable to reach exactly the part of the
wire where the registers differ, and left a new client to learn the fields from
the server's source or by trial and error.

The schemas here are generated from the same models the API validates with, so
they cannot drift from what it actually accepts.
"""
from __future__ import annotations

from typing import Any

from fastapi import FastAPI
from fastapi.openapi.utils import get_openapi
from pydantic.json_schema import models_json_schema

from app.schemas.entry import REGISTER_DATA_SCHEMAS

#: Envelopes whose `data` is a register payload.
_ENVELOPES = ("EntryCreate", "EntryUpdate")


def _register_payload_schemas() -> dict[str, Any]:
    """The five register models, as JSON Schema, keyed by model name."""
    _, defs = models_json_schema(
        [(model, "validation") for model in REGISTER_DATA_SCHEMAS.values()],
        ref_template="#/components/schemas/{model}",
    )
    return defs.get("$defs", {})


def describe_register_payloads(schema: dict[str, Any]) -> dict[str, Any]:
    """Point `data` at the five shapes it may actually take."""
    defs = _register_payload_schemas()
    if not defs:
        return schema

    components = schema.setdefault("components", {}).setdefault("schemas", {})
    for name, definition in defs.items():
        components.setdefault(name, definition)

    by_register = {
        register.value: model.__name__
        for register, model in REGISTER_DATA_SCHEMAS.items()
    }
    one_of = [
        {"$ref": f"#/components/schemas/{name}"}
        for name in dict.fromkeys(by_register.values())
    ]

    for envelope in _ENVELOPES:
        properties = components.get(envelope, {}).get("properties", {})
        if "data" not in properties:
            continue
        properties["data"] = {
            "title": "Data",
            "description": (
                "The register payload. Which shape applies is decided by "
                "`register`: "
                + ", ".join(f"`{r}` -> {n}" for r, n in sorted(by_register.items()))
                + ". Unknown keys are rejected rather than ignored."
            ),
            "oneOf": one_of,
        }
    return schema


def install(app: FastAPI) -> None:
    """Replace `app.openapi` with one that describes the register payloads."""

    def custom_openapi() -> dict[str, Any]:
        if app.openapi_schema:
            return app.openapi_schema
        app.openapi_schema = describe_register_payloads(
            get_openapi(
                title=app.title,
                version=app.version,
                routes=app.routes,
                description=app.description or None,
            )
        )
        return app.openapi_schema

    app.openapi = custom_openapi  # type: ignore[method-assign]
