from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field

from app.schemas.entry import BusNo


class FleetStreamsEventIn(BaseModel):
    """One open/update/clear from fleet-streams' `serving` process.

    Field names and shape are fixed by the companion spec on the
    fleet-streams side — this is a wire contract, not ours to redesign.
    """

    model_config = ConfigDict(extra="ignore")

    vehicle_id: BusNo
    action: Literal["open", "update", "clear"]
    breakdown_id: int
    category: str | None = None
    severity: str | None = None
    note: str | None = None
    contact: str | None = None
    by_whom: str | None = None
    eta_min: int | None = None
    lat: Decimal | None = None
    lon: Decimal | None = None
    ts: datetime
    odo_km: int | None = None


class FleetStreamsOdometerReadingIn(BaseModel):
    model_config = ConfigDict(extra="ignore")

    vehicle_id: BusNo
    odo_km: Annotated[int, Field(ge=0)]
    odo_ts: datetime


class FleetStreamsOdometerBatchIn(BaseModel):
    model_config = ConfigDict(extra="ignore")

    readings: list[FleetStreamsOdometerReadingIn]


class FleetStreamsEventOut(BaseModel):
    """Always 200 — fleet-streams must not retry-loop on a rejected event.

    `applied=False` says the event was understood but not acted on (e.g. an
    unrecognized plate); it is not an error.
    """

    applied: bool
    reason: str | None = None
