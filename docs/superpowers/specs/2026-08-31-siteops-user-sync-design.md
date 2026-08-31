# SiteOps as source of truth for user administration

Design, 2026-08-31.

## Why

SiteOps already decides who a person is and what they may do: `/auth/login`
asks it first (`backend/app/api/auth.py:118-181`), and every request's real
authorization comes from live token claims (`user.attach_claims`,
`backend/app/models/user.py:76-148`), not from E&M's local `role` column.

But E&M's user *administration* surface never followed. `POST /admin/users`,
`PUT /admin/users/{id}`, activate/deactivate, and reset-password
(`backend/app/api/admin.py:142-381`) are 100% local Postgres — nothing calls
out to SiteOps for these, and nothing pulls SiteOps's user list in. Today a
platform user only gets a local shadow row (`platform_identity.ensure_user`,
`backend/app/services/platform_identity.py:30-72`) if they've already logged
in once, or happened to appear in the "reported by" dropdown fetch
(`backend/app/api/master.py:97-135`). Someone created in SiteOps who hasn't
done either is invisible to E&M's admin Users pane, and nothing stops a
manager from independently editing role or site access for someone SiteOps
already governs — the two systems can silently disagree about who a person is
supposed to be.

This mirrors the sibling migration already done for fleet
(`2026-08-26-site-siteops-architecture-design.md`): SiteOps push a roster in,
E&M stops being a second place edits happen. Same precedent, applied to
users instead of vehicles.

## Decisions

| Question | Decision |
| --- | --- |
| Scope | SiteOps-linked sites only (`sites.siteops_site_id IS NOT NULL`). Unlinked sites keep today's local `admin.py` CRUD unchanged — same fallback boundary fleet sync already uses. |
| Who administers users on a linked site? | SiteOps exclusively. E&M's admin endpoints become read-only for users governed by those sites. |
| Break-glass account | Exactly one local-password account (the bootstrap super_admin), created only via startup seeding, never through an API, and excluded from the sync/overwrite entirely. |
| Persistence model | Sync + overwrite into local Postgres, matching the existing "overwrite local fleet from SiteOps instead of appending" pattern — not a live per-request query. |
| Sync trigger | Nightly scheduled job + on-demand manual trigger, same shape as fleet sync. |
| What changes for login/authorization? | Nothing. Per-request claims (`attach_claims`) are already SiteOps-sourced and untouched by this work. The synced `role` column is a display label only, same as it is today for platform users. |

## The adoption gap this spec closes

`ensure_user()` (`platform_identity.py:38-49`) matches a new platform
identity to an existing local row by handle (`user_id`) and returns it
**unchanged** — it does not clear `password_hash`, reset `role`, or touch
`UserSiteAccess`. Sequence that breaks the "SiteOps is the source of truth"
guarantee:

1. A user is created in SiteOps as `KUNALS`.
2. Before any sync runs, someone creates a **local** E&M account with
   `user_id = KUNALS` and a password via today's `admin.py`.
3. The sync (or a later login) calls `ensure_user()`, matches the handle,
   and adopts that row as-is — it keeps its password, so
   `password_hash IS NOT NULL` forever after.
4. The read-only guard below keys off `password_hash IS NULL`. This adopted
   row never trips it and stays E&M-editable indefinitely, silently
   defeating the migration for that one account.

**Fix:** when adoption happens from a sync/staff-list context (not a live
login — a person actively signing in with a local password they already
know is a different situation, handled below), `ensure_user` must also:
- clear `password_hash` and `must_reset_password`
- let the site's `UserSiteAccess` reconciliation (below) fully replace that
  user's rows for the linked site

`ensure_user` gains a `source: Literal["login", "sync"]` parameter.
`source="sync"` performs the normalization above after matching; `source="login"`
keeps today's behavior unchanged — a live login is `_platform_login`
succeeding, i.e. SiteOps has already vouched for the password, and clearing
`password_hash` there isn't needed since the account is being adopted at the
moment it's confirmed to actually be that platform identity's account, not
speculatively during a background sync.

`master.py`'s `_platform_staff` (`backend/app/api/master.py:97-135`) calls
`ensure_user` too, to populate the "reported by"/"supervisor" dropdown from
SiteOps's staff list — the same background-adoption scenario as the sync
job, not a live login. It must pass `source="sync"` as well, or the same gap
stays open through this second call site: a dropdown fetch would silently
adopt a local-password row and leave it editable, exactly like the
unpatched sync path would.

One remaining case: a local account with a matching handle that has **never**
logged in and never been touched by a sync yet, where an admin edits it
locally *between* its SiteOps creation and the first sync. That edit
succeeds (the row still looks local-only at that moment) and is silently
overwritten on the next sync. This is accepted as correct: the row is about
to become platform-managed regardless of when the sync notices it, and the
alternative (blocking local admin edits on any handle that also exists in
SiteOps) would require checking SiteOps on every local admin write, adding a
network call to a path this spec is explicitly trying to keep local-only for
non-SiteOps users.

## Data model

`Site` gains (same shape as its existing fleet-sync bookkeeping):
- `last_siteops_user_sync_at: datetime | None`
- `last_siteops_user_sync_result: JSON | None` — `{synced, adopted,
  deactivated, error}` counts, kept separate from
  `last_siteops_sync_result` (fleet) since it's a distinct sync stream.

No new columns on `User` or `UserSiteAccess`. "Platform-managed" is already
expressible as `password_hash IS NULL` — reused rather than duplicated as a
new flag.

## Sync job

New `backend/app/services/user_sync.py`, modeled on
`masters.sync_all_linked_sites` / `sync_vehicles_from_siteops`:

`sync_users_from_siteops(session, site_code, siteops_site_id)`:
1. `siteops.list_site_users(site_id, is_active=None)` — the function gains an
   `is_active: bool | None = None` parameter (default `True`, preserving
   `master.py`'s existing dropdown caller unchanged); the sync passes `None`
   to fetch everyone, active or not. Today's hardcoded `is_active: "true"`
   filter would otherwise mean a user deactivated in SiteOps never surfaces
   here and stays stuck "active" in E&M forever.
2. For each returned user: `ensure_user(..., source="sync")`, then set
   `is_active` from SiteOps's flag, then `siteops.user_grants(user_id)`
   (one call per user — no bulk roles-by-site endpoint exists in the
   current integration) to map to a display `role`.
3. Reconcile `UserSiteAccess` for this site: replace the site's rows for
   every platform-managed user (`password_hash IS NULL`) with exactly what
   was just fetched — add missing, drop stale. Only rows for
   platform-managed users are touched; a local-only user's site access on
   an unlinked site is never in scope.
4. Per-site error isolation identical to fleet sync
   (`masters.py:177-212`): one site's `SiteOpsUnavailable` doesn't abort the
   batch, is recorded on `last_siteops_user_sync_result`, and the loop
   continues.

**Role-label mapping** (SiteOps role name → local `Role` enum, display
only — real authorization is unaffected): no real SiteOps role-name string
exists anywhere in this repo yet to build this against. Before
implementation, pull an actual sample from the SiteOps sandbox already
configured in `.env` (`platform-service.transvolt.in`) during local testing,
rather than guess a mapping and find out it's wrong against real data.

**Scheduling:** registered on the existing `AsyncIOScheduler` in
`backend/app/main.py`, `CronTrigger(hour=schedule_generator_hour,
minute=schedule_generator_minute+15)` (fleet sync already claims +10), job id
`"siteops_user_sync"`.

**Manual trigger:** `POST /sites/{code}/users/sync-from-siteops`, mirroring
`POST /sites/{code}/vehicles/sync-from-siteops`
(`backend/app/api/sites.py:305-352`) exactly — same `em_user:write`
permission gate, same not-linked 409, same audit-log entry pattern
(new `AuditAction.users_synced_from_siteops`).

## API changes (`admin.py`)

`list_users`: unchanged response shape. Returns a fuller list once the sync
job is proactively populating shadow rows, closing the "never logged in,
never in a dropdown, invisible to admin" gap described above.

`create_user` / `update_user` / `deactivate` / `activate` /
`reset_password`: each gains one guard — if the target user is
platform-managed (`password_hash IS NULL`) **and** has `UserSiteAccess` to
any SiteOps-linked site, reject with `409 Conflict`, `"Managed by SiteOps —
edit there."` Local-only users, users solely on unlinked sites, and the
break-glass account are unaffected.

## Flutter changes

`app/lib/data/repositories.dart` `UserRepository` / `AppUser` model: add
`isPlatformManaged: bool`, threaded from the backend's `password_hash IS
NULL` check (already exposed nowhere client-side today — new field on
`UserOut`).

`app/lib/screens/admin/users_pane.dart`:
- Row-level: hide Edit / Reset password / Deactivate-Activate
  (`users_pane.dart:653-678`) when `isPlatformManaged`; show a static
  "Managed in SiteOps" tag instead.
- "+ Create user" (`users_pane.dart:156-166`) stays for local-only creation,
  hidden when every site the manager governs is SiteOps-linked (nothing
  left to locally administer).
- New "Sync now" button in the pane toolbar, calling the manual
  sync-from-siteops endpoint — same affordance the Vehicle Master screen
  already has for fleet.

`app/test/support/fake_repositories.dart`: `FakeUserRepository` gains
`isPlatformManaged` on its fixture users and honors it the same way the real
API does, so widget tests can cover the hidden-actions behavior.

## Testing plan

Backend:
- `user_sync.py`: overwrite semantics (add/remove `UserSiteAccess` rows),
  per-site error isolation, `is_active` mirroring, adoption normalization
  (`source="sync"` clears `password_hash` on an adopted local-handle row).
- `admin.py`: 409 guard on each write endpoint against a platform-managed
  user; unaffected behavior for local-only users and the break-glass account.

Local integration (per your ask to test this locally first):
1. `docker compose up -d` against the real SiteOps sandbox already
   configured in `.env`.
2. Hit `POST /sites/{code}/users/sync-from-siteops` for a real linked site,
   confirm rows land correctly in `users` / `user_site_access`, and pull a
   real role-name sample to finalize the display-label mapping.
3. Confirm the adoption-gap scenario directly: create a local user with a
   handle that also exists in SiteOps, run the sync, confirm `password_hash`
   clears and the guard now blocks local edits.
4. Run the Flutter app against the local backend, confirm the Users pane
   shows synced users read-only with the "Managed in SiteOps" tag, and that
   "Sync now" works.

Flutter: update `FakeUserRepository` and any existing `users_pane` widget
tests for `isPlatformManaged` and the hidden-actions behavior.
