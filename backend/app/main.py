from __future__ import annotations

import logging
from contextlib import asynccontextmanager
from pathlib import Path

from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.cron import CronTrigger
from apscheduler.triggers.interval import IntervalTrigger
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from app.api import api_router
from app.config import settings
from app.errors import register_exception_handlers
from app.services.inspections import run_nightly
from app.services.notifications import scan_breakdown_sla
from app.services.odometer import scan_sites_due_for_sync

logging.basicConfig(
    level=logging.DEBUG if settings.debug else logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("enm")


@asynccontextmanager
async def lifespan(_app: FastAPI):
    scheduler: AsyncIOScheduler | None = None
    jobs = settings.notifications_enabled and settings.breakdown_sla_enabled
    if jobs or settings.odometer_sync_enabled or settings.schedule_generator_enabled:
        scheduler = AsyncIOScheduler(timezone=settings.timezone)
    if scheduler and jobs:
        scheduler.add_job(
            scan_breakdown_sla,
            IntervalTrigger(minutes=settings.breakdown_sla_scan_minutes),
            id="breakdown_sla_scan",
            max_instances=1,
            coalesce=True,
        )
        logger.info(
            "Breakdown SLA scan every %dm (threshold %dh)",
            settings.breakdown_sla_scan_minutes,
            settings.breakdown_sla_hours,
        )
    if scheduler and settings.odometer_sync_enabled:
        # Each site is pulled on its own configured interval; this is just the
        # tick that checks which are due. The client polls too, which is why
        # the pull is idempotent.
        scheduler.add_job(
            scan_sites_due_for_sync,
            IntervalTrigger(minutes=settings.odometer_scan_minutes),
            id="odometer_sync_scan",
            max_instances=1,
            coalesce=True,
        )
        logger.info(
            "Odometer sync scan every %dm", settings.odometer_scan_minutes
        )
    if scheduler and settings.schedule_generator_enabled:
        # After the last shift has written up its work, so the plan a
        # supervisor reads in the morning reflects the whole day.
        scheduler.add_job(
            run_nightly,
            CronTrigger(
                hour=settings.schedule_generator_hour,
                minute=settings.schedule_generator_minute,
                timezone=settings.timezone,
            ),
            id="inspection_schedule",
            max_instances=1,
            coalesce=True,
        )
        logger.info(
            "Inspection schedule generated daily at %02d:%02d %s",
            settings.schedule_generator_hour,
            settings.schedule_generator_minute,
            settings.timezone,
        )
    if scheduler:
        scheduler.start()
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
