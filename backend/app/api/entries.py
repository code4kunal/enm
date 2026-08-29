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
from app.models.entry import BreakdownEntry, Entry
from app.models.enums import AuditAction, EntryStatus, Register
from app.schemas.common import Page
from app.schemas.entry import EntryCreate, EntryOut, EntryUpdate, PhotoOut, SummaryOut
from app.services import audit, notifications, storage
from app.services import entries as svc
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
):
    frm, to = svc.resolve_period(period, date_from, date_to, _today())
    return {
        "site_code": site,
        "register": register,
        "date_from": frm,
        "date_to": to,
        "q": q,
        "status": entry_status,
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
) -> Page[EntryOut]:
    filters = _filters(site, register, date_from, date_to, period, q, entry_status)
    stmt = svc.apply_filters(select(Entry), **filters)
    total = await svc.count_entries(session, stmt)
    rows = (
        await session.scalars(
            stmt.order_by(Entry.entry_date.desc(), Entry.created_at.desc())
            .offset(page.offset)
            .limit(page.page_size)
        )
    ).unique().all()
    return Page[EntryOut](
        items=[EntryOut(**svc.serialize_entry(e)) for e in rows],
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
        after=svc.serialize_data(entry),
    )
    if payload.register is Register.breakdown:
        await notifications.notify_breakdown_opened(session, entry)
    result = svc.serialize_entry(entry)
    await session.commit()
    return EntryOut(**result)


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

    frm = (filters["date_from"] or (rows[-1].entry_date if rows else _today())).isoformat()
    to = (filters["date_to"] or (rows[0].entry_date if rows else _today())).isoformat()
    filename = f"transvolt-em-register-{site}-{frm}-{to}.csv"
    return StreamingResponse(
        iter([buf.getvalue()]),
        media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


# --- item ------------------------------------------------------------------


@router.get("/{entry_id}", response_model=EntryOut)
async def get_entry(
    entry_id: str, user: CurrentUser, session: SessionDep
) -> EntryOut:
    entry = await _load(session, entry_id)
    assert_site_permission(user, entry.site_code, "em_entry:read")
    return EntryOut(**svc.serialize_entry(entry))


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

    before: dict[str, Any] = svc.serialize_data(entry)
    await svc.update_entry(
        session,
        entry,
        entry_date=payload.date,
        entry_time=payload.entry_time,
        raw_data=payload.data,
    )
    await audit.record(
        session,
        actor_id=user.id,
        action=AuditAction.entry_updated,
        object_type="entry",
        object_id=entry.id,
        before=before,
        after=svc.serialize_data(entry),
    )
    result = svc.serialize_entry(entry)
    await session.commit()
    return EntryOut(**result)


@router.post("/{entry_id}/resolve", response_model=EntryOut)
async def resolve_breakdown(
    entry_id: str, user: CurrentUser, session: SessionDep
) -> EntryOut:
    entry = await _load(session, entry_id)
    assert_site_permission(user, entry.site_code, "em_entry:write")
    if entry.register is not Register.breakdown:
        raise Conflict("Only breakdown entries can be resolved")
    if entry.status is EntryStatus.resolved:
        raise Conflict("Breakdown is already resolved")

    now = datetime.now(UTC)
    entry.status = EntryStatus.resolved
    entry.updated_at = now
    detail: BreakdownEntry = entry.breakdown
    detail.resolved_at = now
    detail.resolved_by_id = user.id

    await audit.record(
        session,
        actor_id=user.id,
        action=AuditAction.entry_resolved,
        object_type="entry",
        object_id=entry.id,
        after={"status": "resolved"},
    )
    await notifications.notify_breakdown_resolved(session, entry, user)
    result = svc.serialize_entry(entry)
    await session.commit()
    return EntryOut(**result)


@router.post("/{entry_id}/photo", response_model=PhotoOut)
async def upload_photo(
    entry_id: str,
    user: CurrentUser,
    session: SessionDep,
    photo: Annotated[UploadFile, File()],
) -> PhotoOut:
    entry = await _load(session, entry_id)
    if not _can_edit(user, entry):
        raise Forbidden("You can only attach photos to your own entries")

    content = await photo.read()
    ext = storage.validate_photo(photo.content_type, len(content))
    old_key = entry.photo_key
    key, url = storage.save_photo(entry.id, content, ext)

    entry.photo_key, entry.photo_url = key, url
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
    storage.delete_photo(old_key)
    return PhotoOut(photo_url=url)


@router.delete("/{entry_id}/photo", status_code=status.HTTP_204_NO_CONTENT, response_model=None)
async def delete_photo(
    entry_id: str, user: CurrentUser, session: SessionDep
) -> None:
    entry = await _load(session, entry_id)
    if not _can_edit(user, entry):
        raise Forbidden("You can only remove photos from your own entries")

    key = entry.photo_key
    entry.photo_key, entry.photo_url = None, None
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
