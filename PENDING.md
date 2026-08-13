# Pending work

State after the site-management, snag-import and inspection-schedule work.

## Verified at this commit

- Backend: `pytest` — 183 passing. `ruff check` clean. `alembic upgrade head`
  runs 0001 → 0009.
- App: `flutter analyze` clean, `flutter test` — 196 passing.
- Driven in Chrome against the live API on `:8123`: sign in as the seeded super
  admin, site picker, home, Schedule → Calendar and Alerts, all reading the
  real database.
- MBMT's own August snag report imported end to end: 57 vehicles, 288 register
  entries routed across five registers by TYPE OF WORK, 611 inspection slots
  generated, 24 open-breakdown alerts raised.

## 1. Reports: all six are built

**Built and driven in a browser:** the Daily Maintenance Report (day view, month
grid, CSV export, nightly freeze at 22:05), the off-road / held-up list,
breakdown investigations, the Annexure-IV control charts (six grids, CSV
export, colour marks carried per cell), the Unit Failure Statement (CSV export)
and the bus history card.

Two of the six charts are still empty for a reason rather than a bug. Tyre
pressure and bus washing read from a checklist line the depot nominates with
`chart_key`; until the D.I checklist is written and one line on it carries that
key, both grids stay blank. kWh/km has no feed at all and says so on screen.

The **Unit Failure Statement** and **bus history card** now have capture
screens and the depot's own 74-unit master, but no data yet — a unit reaches
the statement by being taken off a bus, and nothing has been recorded.

Ten DMR lines are entered rather than derived because nothing observes them.
Line 30, HV batteries replaced, became derived once fitted units were
recordable. Only kWh/km (line 24) is still blocked, on an energy feed.

## 2. One thing about sheets I could not confirm interactively

`EditorSheet` pins the save button, and a widget test shows the field area has
a real scroll extent — so a long form is usable either way. But under browser
automation neither the wheel nor a drag moved the field area, and I could not
tell whether that is the automation or the app. Worth a minute with a real
mouse on the off-road form: if the middle fields cannot be reached, the body
needs a `Scrollbar`/`ListView` rather than a `SingleChildScrollView`.

## 3. Flutter: no tests on the new screens

The schedule, inspection-form, checklist and reports screens are verified by
having been driven in a browser, plus model-level tests for the reports.
`test/support/` has fakes for the original eight repositories but not
`InspectionRepository`, `ChecklistRepository` or `ReportRepository`, so
`fakeContainer()` cannot yet drive those screens end to end.

## 4. Notifications reach the database, not a phone

`notify_schedule_alerts` writes one in-app notification per supervisor and
manager at 22:00 and pushes through FCM **only if** `FCM_CREDENTIALS_FILE` and
`FCM_PROJECT_ID` are set. Without them the alert is in the app and nowhere
else. Set both to get the push.

## 5. The checklists are empty and waiting

`D.I`, `10 DAYS SERVICE` and `P.M` each have a checklist under
**Site → Master data → Checklists**, and all three are empty. Nothing was
invented: the lines have to be the depot's own. Type them there, or send the
checklist documents and they can be seeded the way the snag report was.

Until a checklist has lines, its Home card says "Checklist not written yet" and
its form refuses to save.

## 6. `C/F` is routed on an assumption

`C/F` (carried forward) files as day-to-day work done. That one was not
specified; the rest came from you. Change it in the work-type master — the
routing is data, not code.

## 7. Microsoft SSO

`ApiAuthRepository.signInWithMicrosoft` still throws a clear "use your User ID"
message. `POST /auth/sso` does real Entra ID validation (JWKS, iss, aud, exp);
what is missing is MSAL on the device to obtain the token. Set `MS_TENANT_ID` /
`MS_CLIENT_ID`, then wire an MSAL client and post the id_token.

## 8. Photo attachment

`PhotoAttachButton` toggles a flag only. The endpoints exist
(`POST/DELETE /entries/{id}/photo`). Needs `image_picker`, then an `uploadPhoto`
on `EntryRepository` calling `ApiClient.upload` — the multipart path is already
written and used by the import.

## 9. Offline capture

Ground staff work with patchy connectivity. Entries should queue locally and
sync when the network returns. The repository interface is the right seam: a
`QueuedEntryRepository` decorating the real one, backed by local storage.

## 10. Smaller things

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
