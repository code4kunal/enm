from __future__ import annotations

import logging
from datetime import UTC

from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.db import SessionLocal
from app.models.entry import Entry
from app.models.enums import NotificationType, Role
from app.models.notification import Notification
from app.models.user import DeviceToken, User, UserSiteAccess
from app.services import fcm

logger = logging.getLogger("enm.notifications")

SUPERVISORY_ROLES = (Role.manager, Role.supervisor)


async def _recipients_for_site(
    session: AsyncSession,
    site_code: str,
    roles: tuple[Role, ...],
    exclude_user_id: str | None = None,
) -> list[User]:
    stmt = (
        select(User)
        .join(UserSiteAccess, UserSiteAccess.user_id == User.id)
        .where(
            UserSiteAccess.site_code == site_code,
            User.is_active.is_(True),
            User.role.in_(roles),
        )
    )
    if exclude_user_id:
        stmt = stmt.where(User.id != exclude_user_id)
    return list((await session.scalars(stmt)).unique().all())


async def _active_tokens(session: AsyncSession, user_ids: list[str]) -> list[str]:
    if not user_ids:
        return []
    rows = await session.scalars(
        select(DeviceToken.fcm_token).where(
            DeviceToken.user_id.in_(user_ids), DeviceToken.is_active.is_(True)
        )
    )
    return list(rows.all())


async def _prune_dead_tokens(session: AsyncSession, dead: list[str]) -> None:
    if not dead:
        return
    await session.execute(
        update(DeviceToken)
        .where(DeviceToken.fcm_token.in_(dead))
        .values(is_active=False)
    )


async def fan_out(
    session: AsyncSession,
    *,
    users: list[User],
    type_: NotificationType,
    title: str,
    body: str,
    entry_id: str | None,
    site_code: str | None,
) -> None:
    """Persist an in-app notification per user, then push in one multicast."""
    if not settings.notifications_enabled or not users:
        return

    for user in users:
        session.add(
            Notification(
                user_id=user.id,
                type=type_,
                title=title,
                body=body,
                entry_id=entry_id,
                site_code=site_code,
            )
        )
    await session.flush()

    tokens = await _active_tokens(session, [u.id for u in users])
    dead = await fcm.send_push(
        tokens,
        title=title,
        body=body,
        data={
            "type": type_.value,
            "entry_id": entry_id or "",
            "site": site_code or "",
        },
    )
    await _prune_dead_tokens(session, dead)


# --- domain triggers -------------------------------------------------------


async def notify_breakdown_opened(session: AsyncSession, entry: Entry) -> None:
    users = await _recipients_for_site(
        session, entry.site_code, SUPERVISORY_ROLES, exclude_user_id=entry.created_by_id
    )
    bus_no = entry.vehicle.registration_no
    complaint = entry.breakdown.complaint if entry.breakdown else ""
    await fan_out(
        session,
        users=users,
        type_=NotificationType.breakdown_opened,
        title=f"Breakdown · {bus_no}",
        body=f"{complaint[:120]} — reported by {entry.created_by.name} at {entry.site_code}",
        entry_id=entry.id,
        site_code=entry.site_code,
    )


async def notify_breakdown_resolved(
    session: AsyncSession, entry: Entry, resolver: User
) -> None:
    managers = await _recipients_for_site(
        session, entry.site_code, (Role.manager,), exclude_user_id=resolver.id
    )
    recipients = {u.id: u for u in managers}
    if entry.created_by_id != resolver.id:
        recipients.setdefault(entry.created_by.id, entry.created_by)

    await fan_out(
        session,
        users=list(recipients.values()),
        type_=NotificationType.breakdown_resolved,
        title=f"Breakdown resolved · {entry.vehicle.registration_no}",
        body=f"Marked resolved by {resolver.name} at {entry.site_code}",
        entry_id=entry.id,
        site_code=entry.site_code,
    )


async def notify_account_event(
    session: AsyncSession, user: User, title: str, body: str
) -> None:
    await fan_out(
        session,
        users=[user],
        type_=NotificationType.account,
        title=title,
        body=body,
        entry_id=None,
        site_code=None,
    )


async def scan_breakdown_sla() -> int:
    """Background sweep: nudge on breakdowns left open past the SLA window.

    Fires at most once per breakdown (guarded by `sla_notified_at`).
    """
    from datetime import datetime, timedelta

    from app.models.entry import BreakdownEntry
    from app.models.enums import EntryStatus, Register

    if not (settings.notifications_enabled and settings.breakdown_sla_enabled):
        return 0

    cutoff = datetime.now(UTC) - timedelta(hours=settings.breakdown_sla_hours)
    sent = 0
    async with SessionLocal() as session:
        stale = (
            await session.scalars(
                select(Entry)
                .join(BreakdownEntry, BreakdownEntry.entry_id == Entry.id)
                .where(
                    Entry.register == Register.breakdown,
                    Entry.status == EntryStatus.open,
                    Entry.created_at <= cutoff,
                    BreakdownEntry.sla_notified_at.is_(None),
                )
                .limit(200)
            )
        ).unique().all()

        for entry in stale:
            users = await _recipients_for_site(
                session, entry.site_code, (Role.manager,)
            )
            await fan_out(
                session,
                users=users,
                type_=NotificationType.breakdown_sla_breach,
                title=f"Still open · {entry.vehicle.registration_no}",
                body=(
                    f"Breakdown at {entry.site_code} has been open for over "
                    f"{settings.breakdown_sla_hours}h"
                ),
                entry_id=entry.id,
                site_code=entry.site_code,
            )
            entry.breakdown.sla_notified_at = datetime.now(UTC)
            sent += 1

        await session.commit()

    if sent:
        logger.info("Breakdown SLA nudge sent for %d entries", sent)
    return sent


async def notify_schedule_alerts(session: AsyncSession, site_code: str) -> int:
    """Push the night's open alerts to the people who can act on them.

    One notification summarising the site, not one per alert: a supervisor who
    wakes to forty separate pushes reads none of them. Only alerts raised today
    count, so a problem that has been open for a week does not re-notify every
    night — it is already on the alert list.
    """
    from app.models.enums import AlertStatus, AlertType
    from app.models.inspection import Alert
    from app.services.common import today_ist

    today = today_ist()
    rows = list(
        (
            await session.scalars(
                select(Alert).where(
                    Alert.site_code == site_code,
                    Alert.status == AlertStatus.open,
                    Alert.raised_on == today,
                )
            )
        ).all()
    )
    if not rows:
        return 0

    counts: dict[AlertType, int] = {}
    for alert in rows:
        counts[alert.type] = counts.get(alert.type, 0) + 1

    labels = {
        AlertType.missed_inspection: "missed inspection",
        AlertType.breakdown_open: "open breakdown",
        AlertType.service_overdue: "overdue service",
    }
    parts = [
        f"{n} {labels[t]}{'s' if n != 1 else ''}"
        for t, n in sorted(counts.items(), key=lambda kv: kv[0].value)
    ]

    users = await _recipients_for_site(session, site_code, SUPERVISORY_ROLES)
    if not users:
        return 0

    await fan_out(
        session,
        users=users,
        type_=NotificationType.schedule_alert,
        title=f"{site_code} · {len(rows)} to look at",
        body=", ".join(parts) + ". Open Alerts for the list.",
        site_code=site_code,
    )
    return len(rows)
