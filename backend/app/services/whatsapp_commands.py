"""The two inbound WhatsApp commands. No conversational flow, no material
picking — "the bot is the UI" only for these two lines.

docs/superpowers/specs/2026-08-24-sap-pm-enm-integration-design.md, section 5.
"""
from __future__ import annotations

from datetime import UTC, datetime

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.entry import Entry
from app.models.enums import AuditAction, EntryStatus, JobCardStatus, Register
from app.models.job_card import JobCard
from app.models.user import User
from app.services import audit, notifications
from app.services import entries as entries_svc
from app.services.masters import find_vehicle_by_registration
from app.services.sites import assert_date_is_plausible, assert_site_accepts_entries

HELP_TEXT = (
    "Commands:\n"
    "DOWN <registration> <note> — report a breakdown\n"
    "STATUS <registration> — check what's open on a bus"
)

#: Attributed the same way fleet-streams' ingest attributes system-written
#: entries — there is no logged-in person on the other end of a WhatsApp
#: message. Reuses that same seeded account rather than minting a second one.
SYSTEM_USER_ID = "FLEETSTREAMS"


async def _system_user(session: AsyncSession) -> User:
    user = await session.scalar(select(User).where(User.user_id == SYSTEM_USER_ID))
    if user is None:
        raise RuntimeError(f"System user {SYSTEM_USER_ID!r} is missing — run migrations")
    return user


async def handle_command(session: AsyncSession, _from_number: str, text: str) -> str:
    """Returns the reply text. Never raises — an unparseable or failing
    command gets a one-line explanation back, not a dropped message.

    `_from_number` isn't read yet — kept on the signature since a future
    "only verified numbers may file" check belongs here, not in the route."""
    parts = text.strip().split(maxsplit=2)
    if not parts:
        return HELP_TEXT

    command = parts[0].upper()
    if command == "DOWN" and len(parts) >= 2:
        registration = parts[1]
        note = parts[2] if len(parts) > 2 else ""
        return await _handle_down(session, registration, note)
    if command == "STATUS" and len(parts) >= 2:
        return await _handle_status(session, parts[1])
    return HELP_TEXT


async def _handle_down(session: AsyncSession, registration: str, note: str) -> str:
    vehicle = await find_vehicle_by_registration(session, registration)
    if vehicle is None:
        return f"{registration.upper()} is not on the fleet — nothing filed."

    try:
        site = await assert_site_accepts_entries(session, vehicle.site_code)
        today = datetime.now(UTC).date()
        assert_date_is_plausible(site, today, today)

        system_user = await _system_user(session)
        entry = await entries_svc.create_entry(
            session,
            register=Register.breakdown,
            site_code=vehicle.site_code,
            entry_date=today,
            entry_time=None,
            raw_data={
                "bus_no": vehicle.registration_no,
                "complaint": note or "Reported by WhatsApp",
                "remarks": "via WhatsApp",
            },
            creator=system_user,
        )
        await audit.record(
            session,
            actor_id=system_user.id,
            action=AuditAction.entry_created,
            object_type="entry",
            object_id=entry.id,
            after={"source": "whatsapp"},
        )
        await notifications.notify_breakdown_opened(session, entry)
        await session.commit()
    except Exception as exc:  # noqa: BLE001 — a bad WhatsApp message must get a reply, not a 500
        await session.rollback()
        return f"Could not file that: {exc}"

    return f"Breakdown filed for {vehicle.registration_no}. Reported to the depot."


async def _handle_status(session: AsyncSession, registration: str) -> str:
    vehicle = await find_vehicle_by_registration(session, registration)
    if vehicle is None:
        return f"{registration.upper()} is not on the fleet."

    open_breakdown = await session.scalar(
        select(Entry)
        .where(
            Entry.bus_id == vehicle.id,
            Entry.register == Register.breakdown,
            Entry.status == EntryStatus.open,
        )
        .order_by(Entry.created_at.desc())
        .limit(1)
    )
    open_card = await session.scalar(
        select(JobCard)
        .where(JobCard.bus_id == vehicle.id, JobCard.status != JobCardStatus.teco)
        .order_by(JobCard.created_at.desc())
        .limit(1)
    )

    if not open_breakdown and not open_card:
        return f"{vehicle.registration_no}: nothing open."

    lines = [f"{vehicle.registration_no}:"]
    if open_breakdown:
        lines.append(f"- open breakdown: {open_breakdown.breakdown.complaint[:80]}")
    if open_card:
        order = open_card.sap_order_no or "not yet posted"
        lines.append(f"- job card {open_card.status.value}, SAP order {order}")
    return "\n".join(lines)
