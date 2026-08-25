"""Stand-in SAP PM server for local end-to-end testing.

Not real SAP — SAP ships no lightweight local container, and its own trial
systems are multi-hour cloud provisions. This implements the exact contract
`app/services/sap/client.py` calls (see that file's docstring), in-memory,
so the whole posting chain / master sync / daily recon can be exercised
against real HTTP without BASIS ever confirming the actual connector.

`/_test/*` routes are test-harness controls, not part of the SAP contract —
namespaced so they can never collide with a real SAP path once one exists.
"""
from __future__ import annotations

import itertools
import os
from datetime import datetime, timezone
from typing import Any

from fastapi import FastAPI, Header, HTTPException, Request
from pydantic import BaseModel

EXPECTED_TOKEN = os.environ.get("MOCK_SAP_TOKEN", "dev-sap-token")

app = FastAPI(title="Mock SAP PM")

# --- in-memory state, reset on restart or via /_test/reset -------------------

state: dict[str, Any] = {}
counters: dict[str, itertools.count] = {}


def _reset() -> None:
    state["equipment"] = {}  # equipment_no -> {"equipment_no", "registration_no"}
    state["materials"] = {}  # material_no -> {"material_no", "description", "uom"}
    state["flocs"] = {}  # floc -> {"floc", "site_code"}
    state["notifications"] = {}  # notification_no -> {"equipment_no", "description"}
    state["orders"] = {}  # order_no -> {notification_no, status, qty_issued, created_at}
    counters["notification"] = itertools.count(1)
    counters["order"] = itertools.count(1)
    state["chaos_status"] = None  # set via /_test/chaos to make every call fail once


_reset()


@app.middleware("http")
async def _auth_and_chaos(request: Request, call_next):
    if not request.url.path.startswith("/_test") and request.url.path != "/health":
        auth = request.headers.get("authorization", "")
        if auth != f"Bearer {EXPECTED_TOKEN}":
            return _json_error(401, "Missing or invalid bearer token")
        if state["chaos_status"] is not None:
            code = state["chaos_status"]
            state["chaos_status"] = None
            return _json_error(code, "Chaos-injected failure")
    return await call_next(request)


def _json_error(status: int, message: str):
    from fastapi.responses import JSONResponse

    return JSONResponse(status_code=status, content={"error": message})


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


# --- job-card posting chain --------------------------------------------------


@app.get("/equipment/{equipment_no}")
def get_equipment(equipment_no: str) -> dict[str, Any]:
    record = state["equipment"].get(equipment_no)
    if record is None:
        raise HTTPException(404, f"Unknown equipment {equipment_no}")
    return record


class NotificationIn(BaseModel):
    equipment_no: str
    description: str


@app.post("/notifications")
def create_notification(body: NotificationIn) -> dict[str, str]:
    notification_no = f"NOTIF-{next(counters['notification']):06d}"
    state["notifications"][notification_no] = body.model_dump()
    return {"notification_no": notification_no}


class OrderIn(BaseModel):
    notification_no: str


@app.post("/orders")
def create_order(body: OrderIn) -> dict[str, str]:
    order_no = f"ORDER-{next(counters['order']):06d}"
    state["orders"][order_no] = {
        "notification_no": body.notification_no,
        "status": "REL",
        "qty_reserved": {},
        "qty_issued": {},
        "mechanic": None,
        "hours": None,
        "work_done": None,
        "created_at": datetime.now(timezone.utc).isoformat(),
    }
    return {"order_no": order_no}


class ComponentsIn(BaseModel):
    components: list[dict[str, Any]]


@app.post("/orders/{order_no}/components")
def add_components(order_no: str, body: ComponentsIn) -> dict[str, str]:
    """Reserves materials against the order. In real SAP this is a
    reservation (IW32/CS12), not a goods issue — actual `qty_issued` only
    moves at `confirm`, same as a stores clerk issuing parts alongside a
    mechanic's technical confirmation."""
    order = _require_order(order_no)
    for c in body.components:
        material_no = c.get("sap_material_no") or c.get("material_no")
        qty = c.get("qty_required") or c.get("qty") or 0
        order["qty_reserved"][material_no] = str(qty)
    return {"status": "ok"}


class ConfirmIn(BaseModel):
    mechanic: str | None = None
    hours: str | None = None
    work_done: str | None = None


@app.post("/orders/{order_no}/confirm")
def confirm(order_no: str, body: ConfirmIn) -> dict[str, str]:
    order = _require_order(order_no)
    order["mechanic"] = body.mechanic
    order["hours"] = body.hours
    order["work_done"] = body.work_done
    order["qty_issued"].update(order["qty_reserved"])
    if order["status"] != "TECO":
        order["status"] = "CNF"
    return {"status": "ok"}


@app.post("/orders/{order_no}/teco")
def teco(order_no: str) -> dict[str, str]:
    order = _require_order(order_no)
    order["status"] = "TECO"
    return {"status": "ok"}


@app.get("/orders/{order_no}")
def read_order(order_no: str) -> dict[str, Any]:
    order = _require_order(order_no)
    return {"status": order["status"], "qty_issued": order["qty_issued"]}


def _require_order(order_no: str) -> dict[str, Any]:
    order = state["orders"].get(order_no)
    if order is None:
        raise HTTPException(404, f"Unknown order {order_no}")
    return order


# --- master data reads --------------------------------------------------------


@app.get("/equipment")
def list_equipment() -> dict[str, list[dict[str, Any]]]:
    return {"items": list(state["equipment"].values())}


@app.get("/materials")
def list_materials() -> dict[str, list[dict[str, Any]]]:
    return {"items": list(state["materials"].values())}


@app.get("/functional-locations")
def list_functional_locations() -> dict[str, list[dict[str, Any]]]:
    return {"items": list(state["flocs"].values())}


# --- recon read ----------------------------------------------------------------


@app.get("/orders")
def list_orders_created_since(created_since: str) -> dict[str, list[dict[str, Any]]]:
    since = datetime.fromisoformat(created_since)
    items = [
        {"order_no": no, "created_at": o["created_at"]}
        for no, o in state["orders"].items()
        if datetime.fromisoformat(o["created_at"]) >= since
    ]
    return {"items": items}


# --- test harness controls ----------------------------------------------------


class SeedIn(BaseModel):
    equipment: list[dict[str, Any]] = []
    materials: list[dict[str, Any]] = []
    functional_locations: list[dict[str, Any]] = []


@app.post("/_test/seed")
def seed(body: SeedIn) -> dict[str, int]:
    for e in body.equipment:
        state["equipment"][e["equipment_no"]] = e
    for m in body.materials:
        state["materials"][m["material_no"]] = m
    for f in body.functional_locations:
        state["flocs"][f["floc"]] = f
    return {
        "equipment": len(state["equipment"]),
        "materials": len(state["materials"]),
        "functional_locations": len(state["flocs"]),
    }


@app.post("/_test/reset")
def reset() -> dict[str, str]:
    _reset()
    return {"status": "reset"}


@app.get("/_test/state")
def dump_state() -> dict[str, Any]:
    return {k: v for k, v in state.items() if k != "chaos_status"}


class ChaosIn(BaseModel):
    status_code: int = 502


@app.post("/_test/chaos")
def chaos(body: ChaosIn) -> dict[str, str]:
    """Makes the *next* authenticated call fail with `status_code`, then
    reverts to normal — for exercising SapUnavailable / retry / resume."""
    state["chaos_status"] = body.status_code
    return {"status": "armed", "next_call_returns": str(body.status_code)}
