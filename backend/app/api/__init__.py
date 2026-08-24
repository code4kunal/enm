from fastapi import APIRouter

from app.api import (
    admin,
    auth,
    checklists,
    entries,
    health,
    imports,
    inspections,
    integrations,
    job_cards,
    master,
    notifications,
    reports,
    siteops,
    sites,
)

api_router = APIRouter()
api_router.include_router(health.router)
api_router.include_router(auth.router)
api_router.include_router(sites.router)
api_router.include_router(master.router)
api_router.include_router(imports.router)
api_router.include_router(inspections.router)
api_router.include_router(checklists.router)
api_router.include_router(reports.router)
api_router.include_router(entries.router)
api_router.include_router(admin.router)
api_router.include_router(notifications.router)
api_router.include_router(siteops.router)
api_router.include_router(integrations.router)
api_router.include_router(job_cards.router)

__all__ = ["api_router"]
