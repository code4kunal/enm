from fastapi import APIRouter

from app.api import admin, auth, entries, health, master, notifications

api_router = APIRouter()
api_router.include_router(health.router)
api_router.include_router(auth.router)
api_router.include_router(master.router)
api_router.include_router(entries.router)
api_router.include_router(admin.router)
api_router.include_router(notifications.router)

__all__ = ["api_router"]
