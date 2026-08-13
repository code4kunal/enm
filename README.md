# Transvolt E&M Maintenance

Ground-operations platform for Transvolt's Engineering & Maintenance staff.
Digitises the five physical registers — Daily Work Done, Coolant Topping, Driver
Complaints, Breakdown Report, PM Schedule Attention — column for column, and
adds site onboarding, per-site fleet and preventive-maintenance scheduling,
spreadsheet import, a breakdown tracker and user administration.

```
app/       Flutter client (the deliverable)
backend/   FastAPI + Postgres API
design/    Imported design reference: runnable prototype + handoff spec
CLAUDE.md  Shared conventions for both halves
```

## Running

```sh
# API — :8000 is taken on this machine, so use 8123
cd backend
API_PORT=8123 PUBLIC_BASE_URL=http://localhost:8123 docker compose up -d

# Client, offline against in-memory fakes
cd app && flutter run -d chrome

# Client, against the live API
flutter run -d chrome \
  --dart-define=USE_API=true \
  --dart-define=API_BASE_URL=http://localhost:8123/api/v1

flutter test      # 177 tests
flutter analyze   # clean
```

Only the web platform is scaffolded. `flutter create --platforms=ios,android .`
adds the others; the app code is platform-agnostic. Verified on Flutter 3.47.0.

### Signing in to the offline demo

Every seeded account uses `Transvolt@123`.

| User ID | Who | Sees |
| --- | --- | --- |
| `TV1001` | Priya Deshmukh, **Super Admin** | Every site, Sites + Users admin |
| `TV4021` | Rahul Sharma, Manager | MBMT + UMT, Site section, Users on their sites |
| `TV4102` | Sanjay Pawar, Supervisor | MBMT registers only |
| `TV3987` | Arif Khan, Executive | MBMT registers only |
| `TV3610` | Deepak Rane | Seeded inactive — rejected at sign-in |

Against the live API, use the backend's bootstrap manager (`TV4021` /
`Transvolt@123` — rotate before any real depot).

## Roles

`super_admin` → `manager` → `supervisor` → `executive`.

A **super admin** is platform-level: it onboards sites, maintains the tenant-wide
master lists, and creates users of any role including other super admins. Its
site access is not a stored list — it reaches every site, including ones
onboarded after the account was made.

A **manager** is the admin *of its own sites*: fleet, docking configuration,
import profiles, and the supervisors and executives who work there. It cannot
mint peers; promotion is a super-admin act.

Site scoping is enforced in the client for the sake of the UI and again on the
server, which is the part that counts.

## Architecture

```
app/lib/
  models/      Domain types — Site, Vehicle, SiteConfig, ImportProfile,
               RegisterEntry, AppUser, RegisterDef/FieldDef
  data/
    registers.dart       The five registers, column for column
    import_targets.dart  What each import target accepts, derived from the above
    repositories.dart    Abstract contracts the UI is written against
    api/                 HTTP implementations + the register field map
    fake/                In-memory implementations over one shared store
  state/       Riverpod controllers and derived selectors
  screens/     login, shell, home, entry form, registers, breakdowns,
               site/{fleet,master data,docking,import}, admin/{sites,users},
               profile
  widgets/     Shared primitives
  theme/       Design tokens and the Material 3 theme built from them
```

**Data layer.** Every screen talks to `SiteRepository`, `VehicleRepository`,
`MasterDataRepository`, `SiteConfigRepository`, `ImportRepository`,
`EntryRepository`, `UserRepository`, `AuthRepository` — never to a concrete
implementation. `--dart-define=USE_API=true` swaps all eight from the fakes to
the HTTP clients; `state/providers.dart` is the only file that knows which.

The fakes share **one in-memory store**, so importing a vehicle list actually
changes what the entry form's bus dropdown offers and signing in actually scopes
what is visible. Independent per-repository stubs would reproduce neither.

**Backend compatibility.** The client speaks the site vocabulary throughout. At
sign-in it probes `GET /sites`; a backend that still says `depot` and has no
site/config/import endpoints is detected once, and the features it lacks fail
with a message that says so rather than a raw 404. See
`backend/PROMPT_site_management.md` for the work that closes the gap.

**State.** Riverpod. `sessionProvider` holds auth stage, the signed-in user and
the active site. Derived providers keep filtering out of the widgets.

**Navigation.** `go_router` with a `ShellRoute`, so the header, tabs and bottom
nav persist across every route including the entry form.

**Responsive.** One breakpoint at 640px: top tab row above it, fixed bottom nav
below it.

## Docking schedule — preventive maintenance

The "docking schedule" is the site's **service plan**, modelled the way paid car
servicing works: a service falls due on whichever comes first, distance or
elapsed time. A site keeps a ladder of plans — minor every 10,000 km or 90 days,
major every 40,000 km or a year — and the app computes, per vehicle per plan,
what is overdue, what is due soon, and what is comfortable.

That makes the **odometer** the load-bearing number, so every vehicle master
carries one and it is refreshed on a schedule rather than when someone happens
to open a screen. `OdometerSyncController` polls `syncOdometers` on the site's
configured interval (default 60 min, floor 5 min), pulls once on arrival, and
re-arms whenever the site or interval changes. The server runs the same job.

A vehicle with **no odometer reading at all** reports `NO ODOMETER`, never
"0 km" — a stale telematics feed has to be visible, not invisible. An odometer
never moves backwards: a lower manual reading is rejected, a lower imported one
is skipped as a stale sheet.

## Import

Import formats vary site to site, so the *target* is fixed and the *source* is
whatever that site already keeps. An **import profile** is the saved translation
between the two — configured once, replayed every month.

The flow is profile → file → mapping → preview → commit. Columns whose names
match are bound automatically; a required field left unbound blocks the preview.
The preview is a dry run showing exactly which rows will land and why the rest
were rejected, with row numbers matching the source sheet. Nothing is written
until commit.

Writes upsert by natural key, so re-running last month's sheet does not double
the fleet. Targets: vehicles, defect sources, defect types, service schedule,
odometer readings, and historical backfill of all five registers.

Parsing and validation belong on the server so there is one implementation and
one row-error report. The offline demo reads `.csv` only; `.xlsx` needs the API.

## Design fidelity

`app/lib/theme/tokens.dart` transcribes the handoff's tokens verbatim — every
colour, radius, shadow and motion curve. Translucent values are ARGB literals
rather than `withOpacity`/`withValues` so the file compiles on every Flutter
channel. Type is IBM Plex Sans / IBM Plex Mono via `google_fonts`.

Deliberate departures from the prototype, all toward production correctness:

1. **Site access is scoped to the user.** The prototype shows all eight sites to
   everyone.
2. **Inline buttons meet the 44px touch minimum** the handoff states, rather
   than the prototype's ~30px. These are tapped on tablets in a depot.
3. **Sign-out moved to the account screen.** The avatar used to sign out on a
   single tap, which is a bad thing to hit by accident mid-entry.

## Testing

177 tests. What they cover:

- **Registers** — the five column sets, locked against drift.
- **Dates** — midnight-wrapping breakdown durations, period filters.
- **Entries** — site scoping, bus normalisation, attribution, breakdown
  open/resolve, every filter and free-text search.
- **Users and roles** — grant restrictions, site scoping, soft delete,
  duplicate IDs, temporary-password issuance.
- **Sites** — visibility by role, onboarding validation, deactivation removing a
  site from the switcher.
- **Fleet** — normalisation, duplicates, retire/restore feeding the dropdown.
- **Docking schedule** — every derived figure, all six validation rules, and
  the due calculation across overdue / due-soon / never-serviced / no-odometer.
- **Import** — the CSV reader (quotes, embedded newlines, BOM, duplicate
  headers, header offset, row numbering), auto-mapping, row rejection, unknown
  vehicles, bad dates, upsert-not-duplicate, constants, profile reuse.
- **API contract** — the client parsed against **responses captured from the
  running backend** (`app/test/fixtures/`), which is what caught the client and
  server disagreeing about `data` field names.

Not covered: widget/golden tests, and the live-socket integration test in
`app/test/integration/` — it self-skips when the API is unreachable, and could
not execute in the sandbox used to build this (the Dart VM's sockets are
intercepted). Run it yourself with the API up:

```sh
cd app && flutter test test/integration/api_live_test.dart
```

## Not yet wired

- **Microsoft SSO** needs MSAL on device; the credential path works today.
- **Photo attachment** toggles a flag only. The backend already has the endpoint.
- **Offline capture.** Ground staff work with patchy connectivity; entries should
  queue locally and sync. The repository interface is the right seam.
- **The backend half of site management** — see
  `backend/PROMPT_site_management.md`.
