# Transvolt E&M Maintenance — workspace

Ground-operations platform for Transvolt's Engineering & Maintenance teams.
Two halves of one system; change them together.

```
app/       Flutter client (Riverpod + go_router). See app/README-ish notes in ../README.md
backend/   FastAPI + Postgres, "E&M Maintenance API Contract v1" at /api/v1
design/    Imported design reference: runnable prototype + handoff spec
```

## The contract is the seam

`backend/README.md` is the authority on the wire format. The Flutter client talks
to it only through the abstract repositories in `app/lib/data/repositories.dart`
— `SiteRepository`, `VehicleRepository`, `MasterDataRepository`,
`SiteConfigRepository`, `ImportRepository`, `EntryRepository`, `UserRepository`,
`AuthRepository`. Nothing above that layer knows HTTP exists.

When you change an endpoint, change the matching repository method and its fake in
the same pass. A drifting fake is worse than no fake.

## Vocabulary

**Site** is the tenant unit — one depot, one site. Admins onboard sites; managers
maintain each site's vehicles, master lists, docking config and import profiles.
Never write "depot" in new code.

Roles, most to least privileged: `admin` → `manager` → `supervisor` → `executive`.
Admin is platform-level (onboards sites, creates any user). Manager is site-level.

Every list in the app is site-scoped. The header site switcher is the only tenant
boundary the UI exposes, and the server re-checks `site_access` on every request.

## Conventions

- Vehicle registration numbers are stored uppercase with no whitespace (MH40LY1894).
- Dates are `yyyy-MM-dd` strings end to end — they sort lexically, which is what
  the period filters rely on, and they survive JSON without timezone drift.
- Times are `HH:mm` in site-local time. The backend defaults `entry_time` to site
  wall-clock (IST), not UTC.
- Money/volume/power values are decimals, never floats, on the backend.

## Running

```sh
cd backend && docker compose up -d      # :8000, migrates + seeds
cd app && flutter run -d chrome         # point at the API with --dart-define
```

Bootstrap login `TV4021` / `Transvolt@123` — rotate before any real depot.

## Don't

- Don't add a JSONB blob for register data. Each register has its own table with
  real columns and real FKs; the unified `data` object is a UI convenience only.
- Don't let a dropdown value reach an entry without an FK to its master table.
- Don't parse import spreadsheets client-side. The server owns parsing, validation
  and the row-level error report so there is exactly one implementation.
