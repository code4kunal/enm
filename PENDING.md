# Pending work

State after the site-management, snag-import and inspection-schedule work.

## Verified at this commit

- Backend: `pytest` — 113 passing. `ruff check` clean. `alembic upgrade head`
  runs 0001 → 0005; `alembic revision --autogenerate` produces an empty diff.
- App: `flutter analyze` clean, `flutter test` — 178 passing.
- Driven in Chrome against the live API on `:8123`: sign in as the seeded super
  admin, site picker, home, Schedule → Calendar and Alerts, all reading the
  real database.
- MBMT's own August snag report imported end to end: 57 vehicles, 288 register
  entries routed across five registers by TYPE OF WORK, 611 inspection slots
  generated, 24 open-breakdown alerts raised.

## 1. Reports: three of six are built, three are not

**Built and driven in a browser:** the Daily Maintenance Report (day view, month
grid, CSV export, nightly freeze at 22:05), the off-road / held-up list, and
breakdown investigations.

**Not built:**

- **Control charts** (Annexure-IV). Six bus × date grids. Three are computable
  today — coolant topping, P.M schedule, driver complaints + breakdowns. Two
  more (tyre pressure, bus washing) fall out for free once the D.I checklist
  has those lines. Only kWh/km is blocked, on energy data nothing captures.
- **Unit Failure Statement** and **Bus History**. `unit_types` and
  `fitted_units` are modelled and seeded with the nine components the statement
  lists, but there is no capture screen and no data. They are one dataset seen
  two ways: the statement is removals in a month, the history card is the same
  events pivoted per bus. `kms_covered` derives from the odometers.

Eleven DMR lines are entered rather than derived because nothing observes them.
Two would become derivable with data we could capture: HV batteries replaced
(line 30) once fitted units are recorded, and kWh/km (line 24) with an energy
feed.

## 2. Flutter: no tests on the new screens

The schedule, inspection-form, checklist and reports screens are verified only
by having been driven in a browser. `test/support/` has fakes for the original
eight repositories but not `InspectionRepository`, `ChecklistRepository` or
`ReportRepository`, so `fakeContainer()` cannot yet drive those screens.

## 3. Notifications reach the database, not a phone

`notify_schedule_alerts` writes one in-app notification per supervisor and
manager at 22:00 and pushes through FCM **only if** `FCM_CREDENTIALS_FILE` and
`FCM_PROJECT_ID` are set. Without them the alert is in the app and nowhere
else. Set both to get the push.

## 4. The checklists are empty and waiting

`D.I`, `10 DAYS SERVICE` and `P.M` each have a checklist under
**Site → Master data → Checklists**, and all three are empty. Nothing was
invented: the lines have to be the depot's own. Type them there, or send the
checklist documents and they can be seeded the way the snag report was.

Until a checklist has lines, its Home card says "Checklist not written yet" and
its form refuses to save.

## 5. `C/F` is routed on an assumption

`C/F` (carried forward) files as day-to-day work done. That one was not
specified; the rest came from you. Change it in the work-type master — the
routing is data, not code.

## 6. Microsoft SSO

`ApiAuthRepository.signInWithMicrosoft` still throws a clear "use your User ID"
message. `POST /auth/sso` does real Entra ID validation (JWKS, iss, aud, exp);
what is missing is MSAL on the device to obtain the token. Set `MS_TENANT_ID` /
`MS_CLIENT_ID`, then wire an MSAL client and post the id_token.

## 7. Photo attachment

`PhotoAttachButton` toggles a flag only. The endpoints exist
(`POST/DELETE /entries/{id}/photo`). Needs `image_picker`, then an `uploadPhoto`
on `EntryRepository` calling `ApiClient.upload` — the multipart path is already
written and used by the import.

## 8. Offline capture

Ground staff work with patchy connectivity. Entries should queue locally and
sync when the network returns. The repository interface is the right seam: a
`QueuedEntryRepository` decorating the real one, backed by local storage.

## 9. Smaller things

- **Import previews are process-local.** `PreviewStore` holds staged uploads in
  memory for 30 minutes. Move it to Redis before running more than one uvicorn
  worker, or a commit will 410 at random.
- **Staff user IDs are derived from names** (`NANDRAJ`, `RAHUL.K`) because the
  snag report has no employee numbers. Replace them with real ones when they
  are available; `scripts/seed_staff.py::handle_for` is the only place that
  shape is decided.
- **Telematics is a stub.** `odometer.TelematicsProvider.is_configured` is
  always false, so `POST .../odometer/sync` succeeds with an empty list and the
  fleet relies on manual readings and the odometer import. Implement `fetch`
  against the real provider.
- **Mobile platforms.** Only web is scaffolded:
  `cd app && flutter create --platforms=ios,android,macos .`
- **`design/` is a frozen reference.** Re-import rather than hand-editing.
