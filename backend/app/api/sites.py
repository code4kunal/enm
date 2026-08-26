from __future__ import annotations

from datetime import UTC, datetime
from typing import Annotated

from fastapi import APIRouter, Query, status
from sqlalchemy import select

from app.deps import (
    CurrentUser,
    SessionDep,
    SuperAdminUser,
    assert_site_access,
    assert_site_admin,
)
from app.errors import Conflict, NotFound
from app.models.enums import AuditAction
from app.models.master import Site, Vehicle
from app.schemas.site import (
    FleetSyncIn,
    FleetSyncOut,
    OdometerIn,
    OdometerSyncOut,
    ServiceDueList,
    ServiceRecordIn,
    SiteCreate,
    SiteList,
    SiteOut,
    SiteUpdate,
    VehicleCreate,
    VehicleList,
    VehicleOut,
    VehicleUpdate,
)
from app.schemas.site_config import SiteConfigIO
from app.services import (
    audit,
    checklists,
    masters,
    odometer,
    service_due,
    site_config,
    sites,
)
from app.services.common import today_ist

router = APIRouter(tags=["sites"])


# --- sites -----------------------------------------------------------------


@router.get("/sites", response_model=SiteList)
async def list_sites(user: CurrentUser, session: SessionDep) -> SiteList:
    """Every site for a super admin; the caller's grants otherwise.

    This endpoint answering is what tells the client the site-management
    release has landed.
    """
    rows = await sites.visible_sites(session, user)
    vehicles, users = await sites.rollups(session, [s.code for s in rows])
    return SiteList(
        items=[
            sites.site_out(s, vehicles.get(s.code, 0), users.get(s.code, 0))
            for s in rows
        ]
    )


@router.post("/sites", response_model=SiteOut, status_code=status.HTTP_201_CREATED)
async def create_site(
    payload: SiteCreate, actor: SuperAdminUser, session: SessionDep
) -> SiteOut:
    if await session.get(Site, payload.code):
        raise Conflict(
            f"Site {payload.code} already exists", {"code": "duplicate"}
        )
    site = Site(
        code=payload.code,
        name=payload.name,
        timezone=payload.timezone,
        address=payload.address,
        commissioned_on=payload.commissioned_on,
    )
    session.add(site)
    await session.flush()
    # Migrations 0014/0015/0016 gave the standard checklists to every site that
    # existed when they ran; a site created afterwards is past all of them and
    # would open an empty inspection form without this.
    await checklists.apply_catalogue(session, site.code)
    await audit.record(
        session,
        actor_id=actor.id,
        action=AuditAction.site_created,
        object_type="site",
        object_id=site.code,
        after={"code": site.code, "name": site.name},
    )
    await session.commit()
    return sites.site_out(site)


@router.put("/sites/{code}", response_model=SiteOut)
async def update_site(
    code: str, payload: SiteUpdate, actor: SuperAdminUser, session: SessionDep
) -> SiteOut:
    """The code is immutable — entries reference it."""
    site = await sites.load_site(session, code)
    before = {"name": site.name, "timezone": site.timezone, "address": site.address}

    if payload.name is not None:
        site.name = payload.name.strip()
    if payload.timezone is not None:
        site.timezone = payload.timezone.strip()
    if payload.address is not None:
        site.address = payload.address.strip()
    if "commissioned_on" in payload.model_fields_set:
        site.commissioned_on = payload.commissioned_on
    site.updated_at = datetime.now(UTC)

    await audit.record(
        session,
        actor_id=actor.id,
        action=AuditAction.site_updated,
        object_type="site",
        object_id=site.code,
        before=before,
        after={"name": site.name, "timezone": site.timezone, "address": site.address},
    )
    await session.commit()
    return sites.site_out(site)


@router.post("/sites/{code}/activate", response_model=SiteOut)
async def activate_site(
    code: str, actor: SuperAdminUser, session: SessionDep
) -> SiteOut:
    return await _set_site_active(code, True, actor, session)


@router.post("/sites/{code}/deactivate", response_model=SiteOut)
async def deactivate_site(
    code: str, actor: SuperAdminUser, session: SessionDep
) -> SiteOut:
    """Soft: history is retained, no new entries are accepted, and the site
    drops out of the switcher. Its users stay active."""
    return await _set_site_active(code, False, actor, session)


async def _set_site_active(
    code: str, active: bool, actor: SuperAdminUser, session: SessionDep
) -> SiteOut:
    site = await sites.load_site(session, code)
    site.is_active = active
    site.updated_at = datetime.now(UTC)
    await audit.record(
        session,
        actor_id=actor.id,
        action=(
            AuditAction.site_activated if active else AuditAction.site_deactivated
        ),
        object_type="site",
        object_id=site.code,
    )
    await session.commit()
    return sites.site_out(site)


# --- vehicles --------------------------------------------------------------


@router.get("/sites/{code}/vehicles", response_model=VehicleList)
async def list_vehicles(
    code: str,
    user: CurrentUser,
    session: SessionDep,
    include_inactive: Annotated[bool, Query()] = False,
    active: Annotated[bool | None, Query()] = None,
) -> VehicleList:
    site_code = assert_site_access(user, code)
    stmt = select(Vehicle).where(Vehicle.site_code == site_code)
    if active is not None:
        stmt = stmt.where(Vehicle.is_active.is_(active))
    elif not include_inactive:
        stmt = stmt.where(Vehicle.is_active.is_(True))
    rows = await session.scalars(stmt.order_by(Vehicle.registration_no))
    return VehicleList(items=[sites.vehicle_out(v) for v in rows])


@router.post(
    "/sites/{code}/vehicles",
    response_model=VehicleOut,
    status_code=status.HTTP_201_CREATED,
)
async def create_vehicle(
    code: str, payload: VehicleCreate, user: CurrentUser, session: SessionDep
) -> VehicleOut:
    site_code = assert_site_admin(user, code)
    await sites.load_site(session, site_code)

    exists = await session.scalar(
        select(Vehicle.id).where(Vehicle.registration_no == payload.registration_no)
    )
    if exists:
        raise Conflict(
            f"{payload.registration_no} is already registered",
            {"registration_no": "duplicate"},
        )

    vehicle = Vehicle(
        registration_no=payload.registration_no,
        site_code=site_code,
        make=payload.make.strip(),
        model=payload.model.strip(),
        battery_capacity_kwh=payload.battery_capacity_kwh,
    )
    session.add(vehicle)
    await session.flush()
    await audit.record(
        session,
        actor_id=user.id,
        action=AuditAction.vehicle_created,
        object_type="vehicle",
        object_id=vehicle.id,
        after={"registration_no": vehicle.registration_no, "site": site_code},
    )
    await session.commit()
    return sites.vehicle_out(vehicle)


@router.post("/sites/{code}/vehicles/sync-from-siteops", response_model=FleetSyncOut)
async def sync_fleet_from_siteops(
    code: str, payload: FleetSyncIn, user: CurrentUser, session: SessionDep
) -> FleetSyncOut:
    """Mirror SiteOps' vehicle master into this site's local fleet.

    SiteOps is the source of truth for the fleet's own attributes; this only
    ever creates the local row inspections/checklists/history need to attach
    to, or backfills a still-unset `checklist_variant`. Never touches a
    vehicle a manager already edited.
    """
    site_code = assert_site_admin(user, code)
    await sites.load_site(session, site_code)
    result = await masters.sync_vehicles_from_siteops(
        session, site_code, payload.siteops_site_id
    )
    await audit.record(
        session,
        actor_id=user.id,
        action=AuditAction.fleet_synced_from_siteops,
        object_type="site",
        object_id=site_code,
        after={
            "created": result.created,
            "variant_backfilled": result.variant_backfilled,
        },
    )
    await session.commit()
    return FleetSyncOut(
        created=result.created,
        already_present=result.already_present,
        variant_backfilled=result.variant_backfilled,
        owned_elsewhere=result.owned_elsewhere,
        skipped_no_registration=result.skipped_no_registration,
    )


@router.put("/sites/{code}/vehicles/{vehicle_id}", response_model=VehicleOut)
async def update_vehicle(
    code: str,
    vehicle_id: str,
    payload: VehicleUpdate,
    user: CurrentUser,
    session: SessionDep,
) -> VehicleOut:
    site_code = assert_site_admin(user, code)
    vehicle = await _load_vehicle(session, vehicle_id)
    if vehicle.site_code != site_code:
        raise NotFound("Vehicle not found on this site")

    if payload.registration_no and payload.registration_no != vehicle.registration_no:
        clash = await session.scalar(
            select(Vehicle.id).where(
                Vehicle.registration_no == payload.registration_no,
                Vehicle.id != vehicle.id,
            )
        )
        if clash:
            raise Conflict(
                f"{payload.registration_no} is already registered",
                {"registration_no": "duplicate"},
            )
        vehicle.registration_no = payload.registration_no
    if payload.make is not None:
        vehicle.make = payload.make.strip()
    if payload.model is not None:
        vehicle.model = payload.model.strip()
    if "battery_capacity_kwh" in payload.model_fields_set:
        vehicle.battery_capacity_kwh = payload.battery_capacity_kwh
    if payload.is_active is not None:
        vehicle.is_active = payload.is_active

    await audit.record(
        session,
        actor_id=user.id,
        action=AuditAction.vehicle_updated,
        object_type="vehicle",
        object_id=vehicle.id,
        after={"registration_no": vehicle.registration_no},
    )
    await session.commit()
    return sites.vehicle_out(vehicle)


@router.post("/vehicles/{vehicle_id}/activate", response_model=VehicleOut)
async def activate_vehicle(
    vehicle_id: str, user: CurrentUser, session: SessionDep
) -> VehicleOut:
    return await _set_vehicle_active(vehicle_id, True, user, session)


@router.post("/vehicles/{vehicle_id}/deactivate", response_model=VehicleOut)
async def deactivate_vehicle(
    vehicle_id: str, user: CurrentUser, session: SessionDep
) -> VehicleOut:
    """Retired vehicles stay on past entries but leave the entry dropdown —
    which is why this is a flag, not a delete."""
    return await _set_vehicle_active(vehicle_id, False, user, session)


async def _set_vehicle_active(
    vehicle_id: str, active: bool, user: CurrentUser, session: SessionDep
) -> VehicleOut:
    vehicle = await _load_vehicle(session, vehicle_id)
    assert_site_admin(user, vehicle.site_code)
    vehicle.is_active = active
    await audit.record(
        session,
        actor_id=user.id,
        action=(
            AuditAction.vehicle_activated
            if active
            else AuditAction.vehicle_deactivated
        ),
        object_type="vehicle",
        object_id=vehicle.id,
    )
    await session.commit()
    return sites.vehicle_out(vehicle)


# --- odometers -------------------------------------------------------------


@router.post("/sites/{code}/vehicles/odometer/sync", response_model=OdometerSyncOut)
async def sync_odometers(
    code: str, user: CurrentUser, session: SessionDep
) -> OdometerSyncOut:
    """Pull from telematics now.

    Idempotent — the client polls on the configured interval and the server
    runs the same job, so a pull that finds nothing new reports `skipped`
    rather than failing.
    """
    site_code = assert_site_access(user, code)
    result = await odometer.sync_site(session, site_code)
    await session.commit()
    return result


@router.put("/vehicles/{vehicle_id}/odometer", response_model=VehicleOut)
async def set_odometer(
    vehicle_id: str, payload: OdometerIn, user: CurrentUser, session: SessionDep
) -> VehicleOut:
    vehicle = await _load_vehicle(session, vehicle_id)
    assert_site_admin(user, vehicle.site_code)
    await odometer.set_manual(session, vehicle, payload.odometer_km)
    await audit.record(
        session,
        actor_id=user.id,
        action=AuditAction.odometer_set,
        object_type="vehicle",
        object_id=vehicle.id,
        after={"odometer_km": vehicle.odometer_km},
    )
    await session.commit()
    return sites.vehicle_out(vehicle)


@router.post("/vehicles/{vehicle_id}/services", response_model=VehicleOut)
async def record_service(
    vehicle_id: str,
    payload: ServiceRecordIn,
    user: CurrentUser,
    session: SessionDep,
) -> VehicleOut:
    """Close out a service and re-anchor the next one."""
    vehicle = await _load_vehicle(session, vehicle_id)
    assert_site_admin(user, vehicle.site_code)
    await odometer.record_service(
        session,
        vehicle,
        plan_code=payload.plan_code,
        odometer_km=payload.odometer_km,
        serviced_on=payload.serviced_on,
    )
    await audit.record(
        session,
        actor_id=user.id,
        action=AuditAction.vehicle_serviced,
        object_type="vehicle",
        object_id=vehicle.id,
        after={
            "plan_code": vehicle.last_service_code,
            "odometer_km": vehicle.last_service_km,
        },
    )
    await session.commit()
    return sites.vehicle_out(vehicle)


# --- config and due list ---------------------------------------------------


@router.get("/sites/{code}/config", response_model=SiteConfigIO)
async def get_config(
    code: str, user: CurrentUser, session: SessionDep
) -> SiteConfigIO:
    site_code = assert_site_access(user, code)
    config = await site_config.get_or_create(session, site_code)
    payload = await site_config.to_io(session, config)
    await session.commit()
    return payload


@router.put("/sites/{code}/config", response_model=SiteConfigIO)
async def put_config(
    code: str, payload: SiteConfigIO, user: CurrentUser, session: SessionDep
) -> SiteConfigIO:
    """Replaces the whole aggregate. 422-equivalent on an incoherent config —
    the client checks the same rules first, but this is the authority."""
    site_code = assert_site_admin(user, code)
    await sites.load_site(session, site_code)
    config = await site_config.replace(
        session, site_code=site_code, payload=payload, actor=user
    )
    await audit.record(
        session,
        actor_id=user.id,
        action=AuditAction.site_config_updated,
        object_type="site_config",
        object_id=site_code,
    )
    result = await site_config.to_io(session, config)
    await session.commit()
    return result


@router.get("/sites/{code}/services/due", response_model=ServiceDueList)
async def services_due(
    code: str, user: CurrentUser, session: SessionDep
) -> ServiceDueList:
    site_code = assert_site_access(user, code)
    rows = await service_due.for_site(session, site_code, today_ist())
    await session.commit()
    return ServiceDueList(items=rows)


async def _load_vehicle(session: SessionDep, vehicle_id: str) -> Vehicle:
    vehicle = await session.get(Vehicle, vehicle_id)
    if vehicle is None:
        raise NotFound("Vehicle not found")
    return vehicle
