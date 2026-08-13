from __future__ import annotations

import logging
from contextlib import asynccontextmanager
from pathlib import Path

from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.interval import IntervalTrigger
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from app.api import api_router
from app.config import settings
from app.errors import register_exception_handlers
from app.services.notifications import scan_breakdown_sla

logging.basicConfig(
    level=logging.DEBUG if settings.debug else logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("enm")


@asynccontextmanager
async def lifespan(_app: FastAPI):
    scheduler: AsyncIOScheduler | None = None
    if settings.notifications_enabled and settings.breakdown_sla_enabled:
        scheduler = AsyncIOScheduler(timezone=settings.timezone)
        scheduler.add_job(
            scan_breakdown_sla,
            IntervalTrigger(minutes=settings.breakdown_sla_scan_minutes),
            id="breakdown_sla_scan",
            max_instances=1,
            coalesce=True,
        )
        scheduler.start()
        logger.info(
            "Breakdown SLA scan every %dm (threshold %dh)",
            settings.breakdown_sla_scan_minutes,
            settings.breakdown_sla_hours,
        )
    try:
        yield
    finally:
        if scheduler:
            scheduler.shutdown(wait=False)


def create_app() -> FastAPI:
    app = FastAPI(
        title=settings.app_name,
        version=settings.version,
        openapi_url=f"{settings.api_prefix}/openapi.json",
        docs_url=f"{settings.api_prefix}/docs",
        redoc_url=None,
        lifespan=lifespan,
    )

    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origins,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
        expose_headers=["Content-Disposition"],
    )

    register_exception_handlers(app)
    app.include_router(api_router, prefix=settings.api_prefix)

    media_root = Path(settings.media_root)
    media_root.mkdir(parents=True, exist_ok=True)
    app.mount(
        settings.media_url_path,
        StaticFiles(directory=media_root),
        name="media",
    )
    return app


app = create_app()
