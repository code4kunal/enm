from __future__ import annotations

from typing import Annotated, Any

from fastapi import APIRouter, Query

from app.deps import CurrentUser
from app.services import siteops

router = APIRouter(prefix="/siteops", tags=["siteops"])


@router.get("/sites")
async def list_sites(_user: CurrentUser) -> list[dict[str, Any]]:
    """Every SiteOps site, for mapping onto E&M site codes.

    Proxied server-side with the service key so the client never needs its
    own SiteOps session just to populate the site switcher.
    """
    return await siteops.list_sites()


@router.get("/vehicles")
async def list_vehicles(
    _user: CurrentUser,
    page: Annotated[int, Query(ge=1)] = 1,
    page_size: Annotated[int, Query(ge=1, le=100)] = 25,
    site_id: str | None = None,
    search: str | None = None,
) -> dict[str, Any]:
    """The platform's vehicle master, one page at a time."""
    params: dict[str, Any] = {"page": page, "page_size": page_size}
    if site_id:
        params["site_id"] = site_id
    if search:
        params["search"] = search
    return await siteops.list_vehicles(params)


@router.get("/vehicle-types")
async def list_vehicle_types(_user: CurrentUser) -> dict[str, Any]:
    return await siteops.list_vehicle_types()
