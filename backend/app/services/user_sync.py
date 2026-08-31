from __future__ import annotations

from dataclasses import dataclass

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.enums import Role
from app.models.user import User, UserSiteAccess
from app.services import platform_identity, siteops


def _map_role(role_names: list[str]) -> Role:
    """Best-effort label only — real authorization is unaffected by this
    value (it comes from live per-request token claims). Conservative on
    purpose, matching `masters._checklist_variant_from_ac_nac`: an
    unrecognised role name leaves the display role at `executive` rather
    than guess upward.

    Capped at `manager`: a SiteOps role name never writes `super_admin`
    here. The column is a label for anyone signing in through SiteOps, but
    it is also the fallback authorization path when live claims cannot be
    resolved — platform-wide reach may not be decided by a substring match
    over a name SiteOps supplied.
    """
    names = {str(n).strip().lower() for n in role_names}
    if any(("super" in n and "admin" in n) or "manager" in n for n in names):
        return Role.manager
    if any("supervisor" in n for n in names):
        return Role.supervisor
    return Role.executive


@dataclass(slots=True)
class UserSyncResult:
    synced: int = 0
    #: Adopted a pre-existing local-password account by handle and converted
    #: it to platform-managed.
    adopted: int = 0
    #: Was inactive locally; SiteOps marks it active again.
    reactivated: int = 0
    #: Site access removed for a platform-managed user SiteOps no longer
    #: staffs here (deactivated, or reassigned elsewhere).
    deactivated: int = 0

    def as_dict(self) -> dict:
        return {
            "synced": self.synced,
            "adopted": self.adopted,
            "reactivated": self.reactivated,
            "deactivated": self.deactivated,
        }


async def sync_users_from_siteops(
    session: AsyncSession, site_code: str, siteops_site_id: str
) -> UserSyncResult:
    """Overwrite this site's platform-managed users from SiteOps.

    SiteOps is the source of truth for who is staffed here. Creates or
    adopts a shadow row per person, mirrors `is_active`, maps a display role,
    and reconciles `UserSiteAccess` for platform-managed users to exactly
    match the fetched roster. Local-only accounts (a `password_hash` set) and
    their site access are never touched.
    """
    rows = await siteops.list_site_users(siteops_site_id, is_active=None)

    result = UserSyncResult()
    seen_ids: set[str] = set()
    for row in rows:
        sub = str(row.get("id") or "").strip()
        username = str(row.get("username") or "").strip()
        if not sub or not username:
            continue

        handle = username.strip().upper()
        pre_existing = await session.scalar(
            select(User).where(User.user_id == handle)
        )
        was_local = pre_existing is not None and pre_existing.password_hash is not None

        # A SiteOps id or handle that collides with a super admin — the
        # break-glass bootstrap account, most plausibly — is skipped whole.
        # `ensure_user` refuses to adopt it (see `SyncProtectedSuperAdmin`):
        # adopting would clear its password, and this loop would then
        # overwrite its role and active flag, and `admin.py`'s
        # platform-managed write guard would leave no way back in.
        try:
            person = await platform_identity.ensure_user(
                session,
                sub=sub,
                user_name=username,
                name=str(row.get("full_name") or "") or None,
                email=str(row.get("email") or "") or None,
                source="sync",
            )
        except platform_identity.SyncProtectedSuperAdmin:
            continue

        grants = await siteops.user_grants(sub)
        role = _map_role((grants or {}).get("roles") or [])
        is_active = bool(row.get("is_active", True))

        if was_local:
            result.adopted += 1
        if person.role != role:
            person.role = role
        if person.is_active != is_active:
            if is_active:
                result.reactivated += 1
            person.is_active = is_active
        if is_active:
            if site_code not in person.site_access:
                person.site_links.append(UserSiteAccess(site_code=site_code))
            seen_ids.add(person.id)
        result.synced += 1

    # Reconcile: drop this site's access for platform-managed users SiteOps
    # no longer staffs here — deactivated, or reassigned elsewhere.
    stale = (
        await session.scalars(
            select(UserSiteAccess)
            .join(User, User.id == UserSiteAccess.user_id)
            .where(
                UserSiteAccess.site_code == site_code,
                User.password_hash.is_(None),
                # A super admin is skipped above and never appears in
                # `seen_ids`; it must not lose access as a side effect.
                User.role != Role.super_admin,
                UserSiteAccess.user_id.not_in(seen_ids or {"__none__"}),
            )
        )
    ).all()
    for link in stale:
        await session.delete(link)
        result.deactivated += 1

    await session.flush()
    return result


async def sync_all_users_from_siteops() -> list[dict]:
    """Nightly: refresh platform-managed users for every site linked to
    SiteOps. Per-site failures are recorded on the site row and do not abort
    the run — the same contract as `masters.sync_all_linked_sites`.
    """
    from datetime import UTC, datetime

    from app.db import SessionLocal
    from app.models.master import Site
    from app.services.siteops import SiteOpsUnavailable

    outcomes: list[dict] = []
    async with SessionLocal() as session:
        linked = list(
            (
                await session.scalars(
                    select(Site).where(Site.siteops_site_id.is_not(None))
                )
            ).all()
        )
        for site in linked:
            assert site.siteops_site_id is not None
            try:
                result = await sync_users_from_siteops(
                    session, site.code, site.siteops_site_id
                )
                payload = {**result.as_dict(), "ok": True}
            except SiteOpsUnavailable as e:
                payload = {"ok": False, "error": str(e)}
            except Exception as e:  # noqa: BLE001 — never abort the batch
                payload = {"ok": False, "error": str(e)}
            site.last_siteops_user_sync_at = datetime.now(UTC)
            site.last_siteops_user_sync_result = payload
            outcomes.append({"site_code": site.code, **payload})
        await session.commit()
    return outcomes
