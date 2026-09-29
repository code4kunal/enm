from __future__ import annotations

import csv
import io
from datetime import UTC, datetime
from datetime import date as date_t
from typing import Annotated, Any

from fastapi import APIRouter, File, Query, UploadFile, status
from fastapi.responses import StreamingResponse
from sqlalchemy import func, select

from app.deps import (
    CurrentUser,
    EntrySite,
    PageDep,
    SessionDep,
    assert_site_permission,
)
from app.errors import Conflict, Forbidden, NotFound
from app.models.entry import Entry
from app.models.entry_photo import EntryPhoto
from app.models.enums import AuditAction, EntryStatus, Register
from app.schemas.common import Page
from app.schemas.entry import (
    CoolantDayCreate,
    CoolantDayOut,
    EntryCreate,
    EntryOut,
    EntryPhotoOut,
    EntryUpdate,
    SummaryOut,
)
from app.services import audit, notifications, storage
from app.services import entries as svc
from app.services import tickets as tickets_svc
from app.services.common import today_ist
from app.services.sites import (
    assert_date_is_plausible,
    assert_site_accepts_entries,
    load_site,
)

router = APIRouter(prefix="/entries", tags=["entries"])

RegisterQ = Annotated[Register | None, Query()]
StatusQ = Annotated[EntryStatus | None, Query()]
PeriodQ = Annotated[str | None, Query(pattern="^(today|last7|month|all)$")]


def _today() -> date_t:
    from app.schemas.common import IST

    return datetime.now(IST).date()


def _filters(
    site: str,
    register: Register | None,
    date_from: date_t | None,
    date_to: date_t | None,
    period: str | None,
    q: str | None,
    entry_status: EntryStatus | None,
    origin: str | None = None,
    has_open_ticket: bool | None = None,
):
    frm, to = svc.resolve_period(period, date_from, date_to, _today())
    return {
        "site_code": site,
        "register": register,
        "date_from": frm,
        "date_to": to,
        "q": q,
        "status": entry_status,
        "origin": origin,
        "has_open_ticket": has_open_ticket,
    }


async def _load(session: SessionDep, entry_id: str) -> Entry:
    entry = await session.get(Entry, entry_id)
    if entry is None:
        raise NotFound("Entry not found")
    return entry


def _can_edit(user, entry: Entry) -> bool:
    """Your own record, or somebody else's if you may delete records here.

    Editing another person's entry is the stronger act, so it takes the
    stronger grant: `em_entry:write` files your own work, `em_entry:delete`
    is what a supervisor holds to correct the shift's.
    """
    if not user.can_access(entry.site_code):
        return False
    if entry.created_by_id == user.id:
        return user.has_permission("em_entry:write")
    return user.has_permission("em_entry:delete")


# --- collection ------------------------------------------------------------


@router.get("", response_model=Page[EntryOut])
async def list_entries(
    _user: CurrentUser,
    session: SessionDep,
    site: EntrySite,
    page: PageDep,
    register: RegisterQ = None,
    date_from: Annotated[date_t | None, Query()] = None,
    date_to: Annotated[date_t | None, Query()] = None,
    period: PeriodQ = None,
    q: Annotated[str | None, Query(max_length=200)] = None,
    entry_status: Annotated[EntryStatus | None, Query(alias="status")] = None,
    origin: Annotated[str | None, Query()] = None,
    has_open_ticket: Annotated[bool | None, Query()] = None,
) -> Page[EntryOut]:
    filters = _filters(
        site,
        register,
        date_from,
        date_to,
        period,
        q,
        entry_status,
        origin,
        has_open_ticket,
    )
    stmt = svc.apply_filters(select(Entry), **filters)
    total = await svc.count_entries(session, stmt)
    rows = (
        (
            await session.scalars(
                stmt.order_by(Entry.entry_date.desc(), Entry.created_at.desc())
                .offset(page.offset)
                .limit(page.page_size)
            )
        )
        .unique()
        .all()
    )
    ticket_status = await svc.bulk_ticket_status(session, [e.id for e in rows])
    items = []
    for e in rows:
        status_pair = ticket_status.get(e.id)
        items.append(
            EntryOut(
                **svc.serialize_entry(e),
                ticket_status=status_pair[0] if status_pair else None,
                ticket_completed_at=status_pair[1] if status_pair else None,
            )
        )
    return Page[EntryOut](
        items=items,
        page=page.page,
        page_size=page.page_size,
        total=total,
    )


@router.post("", response_model=EntryOut, status_code=status.HTTP_201_CREATED)
async def create_entry(
    payload: EntryCreate,
    user: CurrentUser,
    session: SessionDep,
) -> EntryOut:
    site = assert_site_permission(user, payload.site, "em_entry:write")
    # A deactivated site keeps its history but accepts nothing new.
    site_row = await assert_site_accepts_entries(session, site)
    assert_date_is_plausible(site_row, payload.date, today_ist())
    entry = await svc.create_entry(
        session,
        register=payload.register,
        site_code=site,
        entry_date=payload.date,
        entry_time=payload.entry_time,
        raw_data=payload.data,
        creator=user,
    )
    await audit.record(
        session,
        actor_id=user.id,
        action=AuditAction.entry_created,
        object_type="entry",
        object_id=entry.id,
        after=svc.audit_snapshot(entry),
    )
    if payload.register in (Register.breakdown, Register.driver_complaint):
        await tickets_svc.create_ticket_for_entry(session, entry=entry, creator=user)
    if payload.register is Register.breakdown:
        await notifications.notify_breakdown_opened(session, entry)
    result = svc.serialize_entry(entry)
    await session.commit()
    return EntryOut(**result)


@router.post(
    "/coolant/day", response_model=CoolantDayOut, status_code=status.HTTP_201_CREATED
)
async def create_coolant_day(
    payload: CoolantDayCreate,
    user: CurrentUser,
    session: SessionDep,
    site: Annotated[str, Query(min_length=1, max_length=50)],
) -> CoolantDayOut:
    """Multiple Bus Inspection's Coolant Topping counterpart: one date, one
    submitting supervisor, every bus in one transaction."""
    site_code = assert_site_permission(user, site, "em_entry:write")
    site_row = await assert_site_accepts_entries(session, site_code)
    assert_date_is_plausible(site_row, payload.entry_date, today_ist())

    entries = await svc.create_coolant_day(
        session,
        site_code=site_code,
        entry_date=payload.entry_date,
        supervisor=payload.supervisor,
        rows=payload.rows,
        creator=user,
    )
    for entry in entries:
        await audit.record(
            session,
            actor_id=user.id,
            action=AuditAction.entry_created,
            object_type="entry",
            object_id=entry.id,
            after=svc.audit_snapshot(entry),
        )
    results = [svc.serialize_entry(entry) for entry in entries]
    await session.commit()
    return CoolantDayOut(items=[EntryOut(**r) for r in results])


# --- static sub-paths (declared before /{id}) ------------------------------


@router.get("/summary", response_model=SummaryOut)
async def summary(
    _user: CurrentUser,
    session: SessionDep,
    site: EntrySite,
    date: Annotated[date_t | None, Query()] = None,
) -> SummaryOut:
    """Single call powering the Home screen counters."""
    day = date or _today()

    counts = await session.execute(
        select(Entry.register, func.count())
        .where(Entry.site_code == site, Entry.entry_date == day)
        .group_by(Entry.register)
    )
    by_register = {r.value: 0 for r in Register}
    total = 0
    for register, n in counts.all():
        by_register[register.value] = n
        total += n

    open_breakdowns = await session.scalar(
        select(func.count())
        .select_from(Entry)
        .where(
            Entry.site_code == site,
            Entry.register == Register.breakdown,
            Entry.status == EntryStatus.open,
        )
    )
    return SummaryOut(
        date=day,
        site=site,
        total_today=total,
        by_register=by_register,
        open_breakdowns=int(open_breakdowns or 0),
    )


@router.get("/export")
async def export_csv(
    _user: CurrentUser,
    session: SessionDep,
    site: EntrySite,
    register: RegisterQ = None,
    date_from: Annotated[date_t | None, Query()] = None,
    date_to: Annotated[date_t | None, Query()] = None,
    period: PeriodQ = None,
    q: Annotated[str | None, Query(max_length=200)] = None,
    entry_status: Annotated[EntryStatus | None, Query(alias="status")] = None,
) -> StreamingResponse:
    filters = _filters(site, register, date_from, date_to, period, q, entry_status)
    stmt = svc.apply_filters(select(Entry), **filters).order_by(
        Entry.entry_date.desc(), Entry.created_at.desc()
    )
    rows = (await session.scalars(stmt)).unique().all()

    buf = io.StringIO()
    writer = csv.writer(buf)
    writer.writerow(["Register", "Date", "Site", "Bus No", "Details", "Entered By"])
    for e in rows:
        writer.writerow(
            [
                e.register.value,
                e.entry_date.isoformat(),
                e.site_code,
                e.vehicle.registration_no,
                svc.csv_details(e),
                f"{e.created_by.name} ({e.created_by.user_id})",
            ]
        )
    buf.seek(0)

    frm = (
        filters["date_from"] or (rows[-1].entry_date if rows else _today())
    ).isoformat()
    to = (filters["date_to"] or (rows[0].entry_date if rows else _today())).isoformat()
    filename = f"transvolt-em-register-{site}-{frm}-{to}.csv"
    return StreamingResponse(
        iter([buf.getvalue()]),
        media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


# --- item ------------------------------------------------------------------


@router.get("/{entry_id}", response_model=EntryOut)
async def get_entry(entry_id: str, user: CurrentUser, session: SessionDep) -> EntryOut:
    entry = await _load(session, entry_id)
    assert_site_permission(user, entry.site_code, "em_entry:read")
    result = svc.serialize_entry(entry)
    result["linked_sessions"] = await svc.load_linked_sessions(session, entry)
    status_pair = (await svc.bulk_ticket_status(session, [entry.id])).get(entry.id)
    result["ticket_status"] = status_pair[0] if status_pair else None
    result["ticket_completed_at"] = status_pair[1] if status_pair else None
    return EntryOut(**result)


@router.put("/{entry_id}", response_model=EntryOut)
async def update_entry(
    entry_id: str, payload: EntryUpdate, user: CurrentUser, session: SessionDep
) -> EntryOut:
    entry = await _load(session, entry_id)
    if not _can_edit(user, entry):
        raise Forbidden("You can only edit your own entries for this site")
    # An edit can move the date, so it gets the same guard as a new record.
    assert_date_is_plausible(
        await load_site(session, entry.site_code), payload.date, today_ist()
    )

    before: dict[str, Any] = svc.audit_snapshot(entry)
    await svc.update_entry(
        session,
        entry,
        entry_date=payload.date,
        entry_time=payload.entry_time,
        raw_data=payload.data,
        actor=user,
    )
    await audit.record(
        session,
        actor_id=user.id,
        action=AuditAction.entry_updated,
        object_type="entry",
        object_id=entry.id,
        before=before,
        after=svc.audit_snapshot(entry),
    )
    result = svc.serialize_entry(entry)
    await session.commit()
    return EntryOut(**result)


@router.post("/{entry_id}/raise_ticket", response_model=EntryOut)
async def raise_ticket(entry_id: str, user: CurrentUser, session: SessionDep) -> EntryOut:
    entry = await _load(session, entry_id)
    assert_site_permission(user, entry.site_code, "em_entry:write")
    if entry.register not in (Register.coolant, Register.driver_complaint):
        raise Conflict(
            "Only coolant and driver complaint entries can raise a ticket "
            "here — breakdowns raise theirs automatically, and PM/Docking "
            "now raises one from its inspection checklist"
        )

    await tickets_svc.create_ticket_for_entry(session, entry=entry, creator=user)
    entry.status = EntryStatus.open
    entry.updated_at = datetime.now(UTC)

    await audit.record(
        session,
        actor_id=user.id,
        action=AuditAction.ticket_raised,
        object_type="entry",
        object_id=entry.id,
        after=svc.audit_snapshot(entry, extra={"status": "open"}),
    )
    result = svc.serialize_entry(entry)
    await session.commit()
    return EntryOut(**result)


@router.post(
    "/{entry_id}/photos",
    response_model=list[EntryPhotoOut],
    status_code=status.HTTP_201_CREATED,
)
async def upload_photo(
    entry_id: str,
    user: CurrentUser,
    session: SessionDep,
    photo: Annotated[UploadFile, File()],
) -> list[EntryPhotoOut]:
    entry = await _load(session, entry_id)
    if not _can_edit(user, entry):
        raise Forbidden("You can only attach photos to your own entries")

    content = await photo.read()
    ext = storage.validate_photo(photo.content_type, len(content))
    key, url = storage.save_photo(entry.id, content, ext)

    session.add(
        EntryPhoto(entry_id=entry.id, storage_key=key, url=url, uploaded_by_id=user.id)
    )
    entry.updated_at = datetime.now(UTC)
    await audit.record(
        session,
        actor_id=user.id,
        action=AuditAction.entry_photo_set,
        object_type="entry",
        object_id=entry.id,
        after={"photo_url": url},
    )
    await session.commit()
    await session.refresh(entry, attribute_names=["photos"])
    return [EntryPhotoOut(id=p.id, url=p.url, caption=p.caption) for p in entry.photos]


@router.delete(
    "/{entry_id}/photos/{photo_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    response_model=None,
)
async def delete_photo(
    entry_id: str, photo_id: str, user: CurrentUser, session: SessionDep
) -> None:
    entry = await _load(session, entry_id)
    if not _can_edit(user, entry):
        raise Forbidden("You can only remove photos from your own entries")

    photo = await session.get(EntryPhoto, photo_id)
    if photo is None or photo.entry_id != entry_id:
        raise NotFound("Photo not found")

    key = photo.storage_key
    await session.delete(photo)
    entry.updated_at = datetime.now(UTC)
    await audit.record(
        session,
        actor_id=user.id,
        action=AuditAction.entry_photo_deleted,
        object_type="entry",
        object_id=entry.id,
    )
    await session.commit()
    storage.delete_photo(key)
