# Site identity, SiteOps linking, and checklist provisioning

Design, 2026-08-26.

## Why

Production shipped with sites that had a fleet on SiteOps but zero local
vehicles, zero checklists, or a placeholder name — the direct cause of the
last bad delivery. Two independent regressions compounded:

**Backend: silent auto-vivification.** `sites.load_site()`
(`backend/app/services/sites.py:15`) creates a `Site` row with a throwaway
name (`f"Site {code[:8]}"`) from *any* endpoint that sees an unrecognized
code — `create_vehicle`, `put_config`, `create_profile`, `update_site` — not
just the explicit `POST /sites` onboarding flow. Until `c34c707` (2026-08-25),
that path never seeded a checklist catalogue either, so a site reached this
way opened a permanently empty inspection form.

**Client: onboarding silently stopped writing to the backend.** `ba9b9e1`
("integrate SiteOps onboarding sites dropdown API and discard local sites
API", 2026-08-20) repointed `ApiSiteRepository.fetchSites()` at SiteOps'
`/onboarding/sites/dropdown` and turned `createSite()` / `updateSite()` /
`setActive()` into no-ops that echoed back a locally-built `Site` object
without calling `POST /sites`, `PUT /sites/{code}`, or `.../activate`. The
onboarding screen looked like it worked and touched nothing server-side. This
half of the regression has since been reverted (`ApiSiteRepository` is back
to calling the real endpoints as of the current tree) but nothing changed on
the backend to stop the same class of bug recurring, and a sibling instance
is still live: `ApiMasterDataRepository._resolveSiteOpsSiteId()`
(`app/lib/data/api/api_repositories.dart:185`) fuzzy-matches a site's name
against SiteOps' dropdown on every staff-lookup call, because nothing
persists the E&M-site ↔ SiteOps-site link anywhere.

Three commits already landed as reactive patches — `c34c707` (union all
checklist seed versions, seed on every auto-create path), `0262f17` (expose a
manager-facing backfill endpoint since ECS has no `docker compose exec`),
`016e100` (a manual "sync fleet" button). They make an already-broken site
recoverable. This spec removes the mechanism that breaks it in the first
place, and adds the vehicle-category groundwork for trucks.

## Decisions

| Question | Decision |
| --- | --- |
| Who owns site identity? | E&M (`POST /sites`, real name/address, super-admin-only). SiteOps is an explicit, opt-in link — never silent. |
| Manual vehicle creation once a site is linked? | Disabled. SiteOps becomes the only path for new vehicles on a linked site — no two-register drift. Unlinked sites keep manual creation. |
| When does the fleet sync run? | Automatically, nightly, for every linked site — plus the existing manual "Sync fleet" button for an on-demand pull. |
| Existing placeholder-named prod sites? | Detect and report only; a super admin renames and links each by hand. No auto-repair of a name from a code that might not actually match. |
| Vehicle category (bus/truck) source? | Manual per-site flag today — SiteOps sends nothing to key it off. Wired to a real SiteOps field the moment one exists, same pattern `checklist_variant`/`ac_nac` already uses. |
| User → multi-site assignment? | No change — `UserSiteAccess`/`site_access` already supports it. Fixed indirectly: provisioning becomes atomic, so there is no window where an assignable site lacks vehicles or checklists. |

## Data model

`Site` gains:

- `siteops_site_id: str | None`, unique, nullable — the explicit link. Null
  means unlinked (manual-only site).
- `last_siteops_sync_at: datetime | None`
- `last_siteops_sync_result: JSON | None` — `{created, already_present,
  variant_backfilled, owned_elsewhere, skipped_no_registration}`, so "did last
  night's sync actually run, and what happened" is answerable without reading
  logs.

`SiteConfig` (the existing per-site settings aggregate behind `GET`/`PUT
/sites/{code}/config`) gains:

- `operating_categories: list[str]`, default `["bus"]`. Declares this site's
  nature of operations. Admin-editable through the same "replace the whole
  aggregate" endpoint `site_config.replace()` already implements.

Checklist catalogue seed entries (`app/seeds/checklists_v1/v2/v3.py`) gain a
`category` field. All three existing modules are tagged `"bus"` — no seed
data changes, only a new key on entries that already exist. A future
`checklists_truck_v1.py` tags its entries `"truck"`; no other code changes
when it lands.

## API changes

**New:** `POST /sites/{code}/siteops-link` (super admin). Body
`{siteops_site_id}`. One transaction: stores the link and timestamp, applies
the checklist catalogue for the site's current `operating_categories`, then
runs the vehicle sync against SiteOps synchronously. Does not return success
until all three are done — a site is never reachable in a half-provisioned
state. Audited as `site_siteops_linked`.

**Changed:** `POST /sites/{code}/vehicles/sync-from-siteops`
(`backend/app/api/sites.py:231`) drops `FleetSyncIn.siteops_site_id` from the
request body — it reads the stored link off the `Site` row instead of
trusting the client. 409s with "site is not linked to SiteOps" if
`siteops_site_id` is null. This is a breaking change to `FleetSyncIn`; the
Flutter `SiteRepository`/`VehicleRepository` call site and its fake in
`test/support/` update in the same pass, per repo convention.

**Changed:** `PUT /sites/{code}/config` re-runs `apply_catalogue` for the
site whenever `operating_categories` changes, so declaring `"truck"` on an
already-linked site provisions the truck catalogue immediately without
re-linking.

**Unchanged, still useful:** `POST /sites/{code}/checklists/sync-catalogue`
(`0262f17`) stays as the manual backfill escape hatch for the remediation
pass below.

**New, read-only:** `GET /sites/remediation/placeholder-names` (super admin)
— every `Site` whose `name` matches `^Site [A-Z0-9]{1,8}$` (the exact pattern
`load_site` used to generate), for the cleanup pass.

## Provisioning flow

```
POST /sites                          admin creates the site, real name
     |
     v
POST /sites/{code}/siteops-link      admin links it (opt-in, explicit)
     |
     +-- store siteops_site_id, last_siteops_sync_at
     +-- apply_catalogue(site, operating_categories)   [local, no SiteOps call]
     +-- sync_vehicles_from_siteops(site, siteops_site_id)
     |
     v
site is fully provisioned: named, has vehicles, has checklists
     |
     v
admin grants UserSiteAccess to whichever managers/supervisors need it
```

A nightly job (same slot as the existing 22:00 IST `notify_schedule_alerts`
job) re-runs `sync_vehicles_from_siteops` for every `Site` with
`siteops_site_id IS NOT NULL`, catching buses SiteOps adds later. It does
**not** touch checklists — those change only when `operating_categories`
changes, which `PUT /sites/{code}/config` already handles synchronously. A
per-site failure (`SiteOpsUnavailable`) is caught and recorded in
`last_siteops_sync_result`; it does not abort the run for other sites.

## Guardrail: `load_site` stops creating

`load_site()` becomes a strict getter — 404 on an unknown code. The four
call sites that relied on its auto-create behavior (`create_vehicle`,
`put_config`, `create_profile`, `update_site`) surface "unknown site — onboard
it first" instead of conjuring a placeholder row. `POST /sites` and the new
`siteops-link` endpoint are the only two ways a `Site` row comes into
existence, both explicit and both super-admin-gated.

## Checklist inheritance by category

`apply_catalogue(session, site_code)` (`backend/app/services/checklists.py:101`)
reads the site's `operating_categories` and only seeds catalogue entries
whose `category` is in that set. A bus-only site (the default, and every
site today) behaves exactly as it does now. A site with `operating_categories
= ["bus", "truck"]` also gets every `category="truck"` entry any installed
seed module defines — nothing per-site to configure beyond the flag itself.
`Vehicle.category` is explicitly **not** added in this pass: there is no
SiteOps field to populate it from yet, and an unused column is worse than no
column. When SiteOps starts sending vehicle type, that field maps onto
`operating_categories` derivation the same way `ac_nac` maps onto
`checklist_variant` today — a follow-up, not part of this spec.

## Client changes (`app/`)

- `ApiSiteRepository` already calls the real `/sites` endpoints (confirmed
  current — the `ba9b9e1` regression on this class was already reverted).
  No change needed there.
- New: a "Link to SiteOps" super-admin action on the site management screen,
  calling `POST /sites/{code}/siteops-link` with a SiteOps site picked from
  the existing `SiteOpsClient` dropdown.
- `ApiMasterDataRepository._resolveSiteOpsSiteId()` is deleted.
  `technicianStaff`/`supervisorStaff`/`mechanicStaff` take the
  `siteops_site_id` `GET /sites` now returns instead of fuzzy-matching a
  site name against SiteOps' dropdown on every call.
- Site config screen gets an `operating_categories` multi-select (bus /
  truck), wired to the existing `SiteConfigRepository`.
- `FleetSyncIn` / the "Sync fleet" button's request body drops
  `siteops_site_id` (server-side change above).

## Remediation (existing production data)

`GET /sites/remediation/placeholder-names` lists every already-broken site.
A super admin, per site: renames it to the real depot name, sets
`operating_categories` if it differs from the default, and calls
`siteops-link` with the matching SiteOps site id looked up by hand.
Deliberately manual — an automatic name-from-code repair risks mislabeling a
site on a code mismatch, and there are few enough of these to do by hand.

## Testing

- Backend: `load_site` 404s on an unknown code from all four previously-silent
  call sites (regression test for exactly this incident). `siteops-link`
  integration test covering link → catalogue → sync in one call, including
  the "already linked" and "site does not exist" error paths.
  `apply_catalogue` unit tests per `operating_categories` combination,
  including a fake `category="truck"` seed entry to prove the filter works
  without needing real truck checklist content. Nightly job test: one site
  raises `SiteOpsUnavailable`, the rest still sync, the failure lands in
  `last_siteops_sync_result`.
- Contract: `FleetSyncIn`'s removed field and `GET /sites`' new
  `siteops_site_id` field both flow through `tools/check_contract.py` — no
  client cast is left assuming the old shape.
- Flutter: `test/support/` fakes for `SiteRepository` gain a
  `linkToSiteOps()` method matching the new endpoint, so the site management
  screen's tests can drive the full flow against the fake, not just mocks.
- Manual, in a browser per `CLAUDE.md`'s testing expectation: onboard a new
  site, link it, confirm vehicles and the D.I./10-day checklist appear
  without a second click; flip `operating_categories` to include a
  fake/test-only truck category and confirm the matching seed entries (if
  any are installed) appear.

## Non-goals

- Real truck checklist content — no source material exists yet (same gap
  `PENDING.md` §5 already documents for docking PDFs). This spec only makes
  the plumbing ready for whenever that content exists.
- `Vehicle.category` / per-vehicle categorization — no SiteOps field to
  populate it from.
- Migrating existing SiteOps-integration call sites for anything other than
  sites/vehicles/staff lookups (e.g. `list_vehicle_types()` is unaffected).
