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

## 1. Flutter: no tests on the new screens

`lib/screens/schedule_screen.dart`, `schedule/slot_editor.dart` and
`schedule/alerts_pane.dart` are verified only by having been driven in a
browser. The state layer (`state/schedule.dart`) has no test double yet —
`test/support/` has fakes for the other eight repositories but not
`InspectionRepository`, so a `fakeContainer()` cannot yet drive the calendar.

## 2. Notifications reach the database, not a phone

`notify_schedule_alerts` writes one in-app notification per supervisor and
manager at 22:00 and pushes through FCM **only if** `FCM_CREDENTIALS_FILE` and
`FCM_PROJECT_ID` are set. Without them the alert is in the app and nowhere
else. Set both to get the push.

## 3. Two work types are routed on an assumption

`C/F` (carried forward) routes to the work-done register and `P.M` / `PM`
(dockings — the sheet says "80K DOCKING", "110K DOCKING") route to the PM
schedule. Those two were not specified; the other six came from the brief.
Change them in Admin → master data, or in `scripts/seed.py::WORK_TYPES` before
a fresh seed — the routing is data, not code.

## 4. The daily-inspection cycle is a guess at 1 day

`D.I` is seeded as every bus every night, uncapped, per the instruction. The
sheet itself shows 40 D.I events over 10 days across 25 of 57 buses, which is
nothing like nightly — so either the sheet under-records D.I, or the real
cadence is longer. Worth confirming against the depot before the first live
month. `scripts/seed_import_profile.py::INSPECTION_PLANS` holds it.

## 5. Microsoft SSO

`ApiAuthRepository.signInWithMicrosoft` still throws a clear "use your User ID"
message. `POST /auth/sso` does real Entra ID validation (JWKS, iss, aud, exp);
what is missing is MSAL on the device to obtain the token. Set `MS_TENANT_ID` /
`MS_CLIENT_ID`, then wire an MSAL client and post the id_token.

## 6. Photo attachment

`PhotoAttachButton` toggles a flag only. The endpoints exist
(`POST/DELETE /entries/{id}/photo`). Needs `image_picker`, then an `uploadPhoto`
on `EntryRepository` calling `ApiClient.upload` — the multipart path is already
written and used by the import.

## 7. Offline capture

Ground staff work with patchy connectivity. Entries should queue locally and
sync when the network returns. The repository interface is the right seam: a
`QueuedEntryRepository` decorating the real one, backed by local storage.

## 8. Smaller things

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
