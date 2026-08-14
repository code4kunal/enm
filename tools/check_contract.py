#!/usr/bin/env python3
"""Check what the Flutter client assumes against what the API actually sends.

The wire format is written twice: 129-odd Pydantic schemas on one side, and
hand-written `fromJson` factories on the other. Nothing has ever compared them,
and both of the bugs that reached a browser lived exactly in that gap — a
Decimal serialised as `"250.00"` and then as `"57"`, each landing as
`type 'String' is not a subtype of type 'num?'`.

Rather than generate the Dart models — they carry judgement a generator would
flatten, like a kilometre reading that shows a dash because unknown is not zero
— this reads the casts the client already makes and asks the schema whether
they hold.

Deliberately not a Dart test and not a Python test: it belongs to neither half,
and it needs the API's schema and the client's source at the same time. Run it
with `make contract`.
"""
from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BACKEND = ROOT / "backend"
MODELS = ROOT / "app" / "lib" / "models"

#: What each Dart type demands of the JSON that feeds it. A cast to `num` is a
#: crash if the server sends a string, which is the whole reason this exists.
DART_TO_JSON: dict[str, set[str]] = {
    "num": {"number", "integer"},
    "int": {"number", "integer"},
    "double": {"number", "integer"},
    "String": {"string"},
    "bool": {"boolean"},
    "List": {"array"},
    "Map": {"object"},
}

#: `json['x'] as num?` — the shape every hand-written factory uses.
CAST = re.compile(
    r"""json\[\s*['"](?P<field>[a-z0-9_]+)['"]\s*\]\s+as\s+(?P<type>[A-Za-z_]+)"""
)

#: `class DmrLine {` / `class DmrDay extends …`
DART_CLASS = re.compile(r"^class\s+(?P<name>[A-Z]\w*)", re.MULTILINE)

#: Client-side names that do not match the schema they are fed by. Kept short
#: on purpose: a long list here means the two sides are drifting by name, which
#: is its own problem.
ALIASES: dict[str, str] = {
    "InvestigationDay": "InvestigationList",
    "ChartKind": "ChartKindOut",
    "ControlChart": "ControlChartOut",
    "ChartRow": "ChartRowOut",
    "ChartCell": "ChartCellOut",
    "FittedUnit": "FittedUnitOut",
    "UnitType": "UnitTypeOut",
    "BusHistory": "BusHistoryOut",
    "HistoryRow": "HistoryRowOut",
    "HistoryEvent": "HistoryEventOut",
    "OffRoadCase": "OffRoadOut",
    "Investigation": "InvestigationOut",
    "DmrDay": "DmrDayOut",
    "DmrMonth": "DmrMonthOut",
}


@dataclass(frozen=True, slots=True)
class Assumption:
    """One cast the client makes, and where it makes it."""

    dart_class: str
    field: str
    dart_type: str
    file: str
    line: int


@dataclass(frozen=True, slots=True)
class Finding:
    assumption: Assumption
    schema: str
    detail: str

    def __str__(self) -> str:
        a = self.assumption
        return (
            f"{a.file}:{a.line}  {a.dart_class}.{a.field}\n"
            f"    client reads it as {a.dart_type}, "
            f"but {self.schema}.{a.field} {self.detail}"
        )


def openapi() -> dict:
    """Build the schema in-process. No server, so CI needs no database."""
    sys.path.insert(0, str(BACKEND))
    from app.main import app  # noqa: PLC0415

    return app.openapi()


def dart_assumptions() -> list[Assumption]:
    """Every `json['field'] as Type` in the models, tagged with its class."""
    found: list[Assumption] = []
    for path in sorted(MODELS.glob("*.dart")):
        text = path.read_text()
        # Where each class starts, so a cast can be attributed to one.
        bounds = [(m.start(), m.group("name")) for m in DART_CLASS.finditer(text)]
        for match in CAST.finditer(text):
            owner = ""
            for start, name in bounds:
                if start < match.start():
                    owner = name
                else:
                    break
            found.append(
                Assumption(
                    dart_class=owner,
                    field=match.group("field"),
                    dart_type=match.group("type"),
                    file=str(path.relative_to(ROOT)),
                    line=text.count("\n", 0, match.start()) + 1,
                )
            )
    return found


def json_types(prop: dict) -> set[str]:
    """The JSON types a property may arrive as, unwrapping nullable unions."""
    if "type" in prop:
        return {prop["type"]}
    types: set[str] = set()
    for key in ("anyOf", "oneOf", "allOf"):
        for branch in prop.get(key, []):
            if branch.get("type") == "null":
                continue
            types |= json_types(branch)
    return types


def check() -> list[Finding]:
    schemas = openapi().get("components", {}).get("schemas", {})
    findings: list[Finding] = []

    for a in dart_assumptions():
        name = ALIASES.get(a.dart_class, a.dart_class)
        schema = schemas.get(name)
        if schema is None:
            # Not every client model mirrors one server schema, and a missing
            # match is not evidence of a bug — only a matched one can be wrong.
            continue
        props = schema.get("properties", {})
        if a.field not in props:
            findings.append(
                Finding(a, name, "does not exist — renamed or removed")
            )
            continue

        allowed = DART_TO_JSON.get(a.dart_type)
        if allowed is None:
            continue
        actual = json_types(props[a.field])
        if actual and not (actual & allowed):
            findings.append(
                Finding(a, name, f"is sent as {'/'.join(sorted(actual))}")
            )
    return findings


def main() -> int:
    findings = check()
    checked = len(dart_assumptions())

    if not findings:
        print(f"contract ok — {checked} client assumptions hold")
        return 0

    print(f"contract broken — {len(findings)} of {checked} assumptions fail:\n")
    for finding in findings:
        print(f"  {finding}\n")
    print(
        "Each of these is a crash the moment that field is read. Fix the "
        "schema or fix the cast; do not widen the cast to `dynamic`."
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
