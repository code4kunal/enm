from __future__ import annotations

import json
from datetime import UTC, datetime
from typing import Annotated

from fastapi import APIRouter, File, Form, UploadFile, status
from pydantic import TypeAdapter
from pydantic import ValidationError as PydanticValidationError
from sqlalchemy import select

from app.deps import CurrentUser, SessionDep, assert_site_permission
from app.errors import NotFound, ValidationError
from app.models.enums import AuditAction, ImportTarget
from app.models.site_import import (
    SiteImportMapping,
    SiteImportProfile,
    SiteImportRun,
)
from app.models.user import User
from app.schemas.site_import import (
    ColumnMappingIO,
    ImportCommitIn,
    ImportPreviewOut,
    ImportProfileIn,
    ImportProfileList,
    ImportProfileOut,
    ImportRunList,
    ImportRunOut,
    SourceInspectionOut,
)
from app.services import audit, imports, sites
from app.services.spreadsheet import read_sheet

router = APIRouter(tags=["imports"])

_MAPPINGS = TypeAdapter(list[ColumnMappingIO])
#: Sheets are read fully into memory; this bounds that.
MAX_UPLOAD_BYTES = 15 * 1024 * 1024
SAMPLE_ROWS = 5


def _profile_out(profile: SiteImportProfile) -> ImportProfileOut:
    return ImportProfileOut(
        id=profile.id,
        site_code=profile.site_code,
        name=profile.name,
        target=profile.target,
        mappings=[
            ColumnMappingIO(
                target_key=m.target_key,
                source_column=m.source_column,
                constant_value=m.constant_value,
                date_format=m.date_format,
            )
            for m in profile.mappings
        ],
        sheet_name=profile.sheet_name,
        header_row=profile.header_row,
        skip_rows=profile.skip_rows,
        last_run_at=profile.last_run_at,
    )


async def _load_profile(session: SessionDep, profile_id: str) -> SiteImportProfile:
    profile = await session.get(SiteImportProfile, profile_id)
    if profile is None:
        raise NotFound("Import profile not found")
    return profile


async def _read_upload(file: UploadFile) -> bytes:
    data = await file.read()
    if len(data) > MAX_UPLOAD_BYTES:
        raise ValidationError(
            f"{file.filename} is larger than "
            f"{MAX_UPLOAD_BYTES // (1024 * 1024)} MB",
            {"file": "too large"},
        )
    return data


# --- profiles --------------------------------------------------------------


@router.get("/sites/{code}/import-profiles", response_model=ImportProfileList)
async def list_profiles(
    code: str, user: CurrentUser, session: SessionDep
) -> ImportProfileList:
    site_code = assert_site_permission(user, code, "em_import:read")
    rows = await session.scalars(
        select(SiteImportProfile)
        .where(SiteImportProfile.site_code == site_code)
        .order_by(SiteImportProfile.name)
    )
    return ImportProfileList(items=[_profile_out(p) for p in rows])


@router.post(
    "/sites/{code}/import-profiles",
    response_model=ImportProfileOut,
    status_code=status.HTTP_201_CREATED,
)
async def create_profile(
    code: str, payload: ImportProfileIn, user: CurrentUser, session: SessionDep
) -> ImportProfileOut:
    site_code = assert_site_permission(user, code, "em_import:write")
    await sites.load_site(session, site_code)

    profile = SiteImportProfile(
        site_code=site_code,
        name=payload.name,
        target=payload.target,
        sheet_name=payload.sheet_name,
        header_row=payload.header_row,
        skip_rows=payload.skip_rows,
        created_by_id=user.id,
        mappings=[_mapping_row(m) for m in payload.mappings],
    )
    session.add(profile)
    await session.commit()
    await session.refresh(profile)
    return _profile_out(profile)


@router.put("/sites/{code}/import-profiles/{profile_id}", response_model=ImportProfileOut)
async def update_profile(
    code: str,
    profile_id: str,
    payload: ImportProfileIn,
    user: CurrentUser,
    session: SessionDep,
) -> ImportProfileOut:
    site_code = assert_site_permission(user, code, "em_import:write")
    profile = await _load_profile(session, profile_id)
    if profile.site_code != site_code:
        raise NotFound("Import profile not found on this site")

    profile.name = payload.name
    profile.target = payload.target
    profile.sheet_name = payload.sheet_name
    profile.header_row = payload.header_row
    profile.skip_rows = payload.skip_rows
    profile.mappings = [_mapping_row(m) for m in payload.mappings]

    await session.commit()
    await session.refresh(profile)
    return _profile_out(profile)


@router.delete(
    "/import-profiles/{profile_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    response_model=None,
)
async def delete_profile(
    profile_id: str, user: CurrentUser, session: SessionDep
) -> None:
    profile = await _load_profile(session, profile_id)
    assert_site_permission(user, profile.site_code, "em_import:write")
    await session.delete(profile)
    await session.commit()


def _mapping_row(mapping: ColumnMappingIO) -> SiteImportMapping:
    return SiteImportMapping(
        target_key=mapping.target_key,
        source_column=mapping.source_column,
        constant_value=mapping.constant_value,
        date_format=mapping.date_format,
    )


# --- inspect / preview / commit --------------------------------------------


@router.post("/sites/{code}/imports/inspect", response_model=SourceInspectionOut)
async def inspect(
    code: str,
    user: CurrentUser,
    file: Annotated[UploadFile, File()],
    header_row: Annotated[int, Form()] = 1,
    sheet_name: Annotated[str | None, Form()] = None,
) -> SourceInspectionOut:
    """Open the file and report its sheets, headers and a few rows.

    Runs before a profile is complete, so it takes no mappings.
    """
    assert_site_permission(user, code, "em_import:read")
    data = await _read_upload(file)
    sheet = read_sheet(
        file_name=file.filename or "upload",
        data=data,
        sheet_name=sheet_name or None,
        header_row=header_row,
    )
    return SourceInspectionOut(
        file_name=file.filename or "upload",
        sheet_names=sheet.sheet_names,
        columns=sheet.columns,
        sample_rows=[r.values for r in sheet.rows[:SAMPLE_ROWS]],
        total_rows=len(sheet.rows),
    )


@router.post("/sites/{code}/imports/preview", response_model=ImportPreviewOut)
async def preview(
    code: str,
    user: CurrentUser,
    session: SessionDep,
    file: Annotated[UploadFile, File()],
    target: Annotated[str, Form()],
    mappings: Annotated[str, Form()],
    header_row: Annotated[int, Form()] = 1,
    skip_rows: Annotated[int, Form()] = 0,
    sheet_name: Annotated[str | None, Form()] = None,
) -> ImportPreviewOut:
    """Dry run: map and validate every row, write nothing, stage under a token."""
    site_code = assert_site_permission(user, code, "em_import:write")
    parsed_target = _parse_target(target)
    parsed_mappings = _parse_mappings(mappings)
    imports.require_mappings(parsed_target, parsed_mappings)

    data = await _read_upload(file)
    sheet = read_sheet(
        file_name=file.filename or "upload",
        data=data,
        sheet_name=sheet_name or None,
        header_row=header_row,
        skip_rows=skip_rows,
    )

    staged = await imports.build_preview(
        session,
        site_code=site_code,
        target=parsed_target,
        file_name=file.filename or "upload",
        rows=sheet.rows,
        mappings=parsed_mappings,
        actor=user,
    )
    # Snag preview may have vivified work types / groups / buses so every
    # written row can pass validation — those masters must survive the request.
    if parsed_target is ImportTarget.snag_report:
        await session.commit()
    return ImportPreviewOut(
        token=staged.token,
        file_name=staged.file_name,
        target=staged.target,
        rows=staged.rows,
        errors=staged.errors,
        total_rows=staged.total_rows,
        new_count=staged.new_count,
        update_count=staged.update_count,
    )


@router.post("/sites/{code}/imports/commit", response_model=ImportRunOut)
async def commit(
    code: str, payload: ImportCommitIn, user: CurrentUser, session: SessionDep
) -> ImportRunOut:
    """Apply exactly what was previewed. A stale token is 410 Gone."""
    site_code = assert_site_permission(user, code, "em_import:write")
    staged = imports.previews.take(payload.token, site_code)

    # Built before the rows so every one of them can carry its id — that is
    # what makes "which upload wrote this?" answerable a month later.
    run = SiteImportRun(
        site_code=site_code,
        profile_name=staged.file_name,
        target=staged.target,
        file_name=staged.file_name,
        rows_accepted=0,
        rows_rejected=0,
        run_by_id=user.id,
    )
    session.add(run)
    await session.flush()

    accepted, unchanged, rejected = await imports.commit(
        session, staged, user, run_id=run.id
    )
    run.rows_accepted = accepted
    run.rows_unchanged = unchanged
    run.rows_rejected = rejected
    await audit.record(
        session,
        actor_id=user.id,
        action=AuditAction.import_committed,
        object_type="import",
        object_id=site_code,
        after={"target": staged.target.value, "rows": accepted},
    )
    await session.flush()
    await session.commit()
    await session.refresh(run)
    return _run_out(run, user.name)


@router.get("/sites/{code}/imports", response_model=ImportRunList)
async def list_runs(
    code: str, user: CurrentUser, session: SessionDep
) -> ImportRunList:
    site_code = assert_site_permission(user, code, "em_import:read")
    rows = list(
        (
            await session.scalars(
                select(SiteImportRun)
                .where(SiteImportRun.site_code == site_code)
                .order_by(SiteImportRun.run_at.desc())
                .limit(50)
            )
        ).all()
    )
    names: dict[str, str] = {}
    for run in rows:
        if run.run_by_id and run.run_by_id not in names:
            actor = await session.get(User, run.run_by_id)
            names[run.run_by_id] = actor.name if actor else ""
    return ImportRunList(
        items=[_run_out(r, names.get(r.run_by_id or "", "")) for r in rows]
    )


def _run_out(run: SiteImportRun, run_by: str) -> ImportRunOut:
    return ImportRunOut(
        id=run.id,
        site_code=run.site_code,
        profile_name=run.profile_name,
        target=run.target,
        file_name=run.file_name,
        rows_accepted=run.rows_accepted,
        rows_unchanged=run.rows_unchanged,
        rows_rejected=run.rows_rejected,
        run_at=run.run_at or datetime.now(UTC),
        run_by=run_by,
    )


def _parse_target(raw: str) -> ImportTarget:
    try:
        return ImportTarget(raw)
    except ValueError as exc:
        raise ValidationError(
            f"Unknown import target: {raw}", {"target": "unknown"}
        ) from exc


def _parse_mappings(raw: str) -> list[ColumnMappingIO]:
    """Sent as a JSON string inside the multipart body so an unsaved mapping
    can still be previewed."""
    try:
        return _MAPPINGS.validate_python(json.loads(raw or "[]"))
    except (json.JSONDecodeError, PydanticValidationError) as exc:
        raise ValidationError(
            "Could not read the column mappings", {"mappings": "malformed"}
        ) from exc
