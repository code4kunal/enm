# Pending work

State after the site-management, snag-import and inspection-schedule work.

## Verified at this commit

- `make check` — 240 backend tests, 221 app tests, both linters, and 298
  client-to-schema assumptions. Runs in about four minutes.
- `make migrate-check` — 0001 → 0013 → base → 0013 on a throwaway database.
- CI runs all of it on every push and pull request.
- MBMT's August snag report imported end to end from a cold database: 57
  vehicles, 201 entries routed across five registers by TYPE OF WORK, 89
  inspections. Re-importing it is a no-op, which is what makes backfill safe.
- The fleet's models and odometers loaded from the depot's VehicleStatus
  export, which is also what the nightly sync reads.
- Inspection checklists live: D.I 14/14/12 checks by bus model, ten-day 57
  each. Driven in Chrome — picking a bus loads its variant, everything
  defaulted to OK.
- Docking scheduled off the odometer ladder: 13 rungs, 4 buses due.

## 1. Reports: all six are built

**Built and driven in a browser:** the Daily Maintenance Report (day view, month
grid, CSV export, nightly freeze at 22:05), the off-road / held-up list,
breakdown investigations, the Annexure-IV control charts (six grids, CSV
export, colour marks carried per cell), the Unit Failure Statement (CSV export)
and the bus history card. Every one of them downloads as a PDF, rendered
server-side and delivered through the platform share sheet.

Two of the six charts are still empty for a reason rather than a bug. Tyre
pressure and bus washing read from a checklist line the depot nominates with
`chart_key`, and no line on any sheet MBMT gave us records either thing — see
section 6, it is a depot process gap, not a nomination we forgot to make.
kWh/km has no feed at all and says so on screen.

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

## 5. Docking has a schedule but no checklist

The daily and ten-day checklists are seeded from the depot's own sheets. The
docking ones are not: they exist only as 26 PDFs, and the layout does not
survive text extraction. Measured across all of them, 32% of what a parser
reads as a section heading is really wrapped item text, and items truncate with
it — `Check whether the controller high voltage connector` loses `is connected
firmly`.

A one-in-three structural error rate is worse than nothing for a permanent
maintenance record, so nothing was shipped. **Deliberately parked** — a docking
is scheduled and recorded, it just has no lines to tick.

To pick it up later: ask the depot for the source files. The same folder holds
PDF copies of the daily and ten-day sheets that arrived separately as .xlsx and
parsed perfectly, so the docking schedules very likely exist as Excel too. That
turns this into an afternoon with `scripts/seed_checklists.py`.

## 6. Master data the depot still owes us

`defect_types` (16 GROUP values), `unit_types` (74) and `work_types` came off
MBMT's own sheets. **`defect_sources` did not** — the seven values in
`scripts/seed.py` were copied from `design/HANDOFF.md`, and no snag column maps
to a defect source, so `defect_source_id` is null on every imported row and
only hand-typed work-done entries ever set it. Ask the depot for their list, or
drop the field.

Two control charts are blocked further upstream than PENDING once said. Tyre
pressure and bus washing wait on a `chart_key` nomination, but neither check
exists on the D.I sheet (14 lines, none about tyres or washing) or the ten-day
sheet — its closest is line 19, "Check all tyres wear, damages and deformity",
which is wear, not pressure. Nominating a line cannot fix this; MBMT has to
start recording both.

`fitted_units` is still empty, so the Unit Failure Statement and the bus
history card render with a master and no data.

## 7. `C/F` is routed on an assumption

`C/F` (carried forward) files as day-to-day work done. That one was not
specified; the rest came from you. Change it in the work-type master — the
routing is data, not code.

## 8. Microsoft SSO

`ApiAuthRepository.signInWithMicrosoft` still throws a clear "use your User ID"
message. `POST /auth/sso` does real Entra ID validation (JWKS, iss, aud, exp);
what is missing is MSAL on the device to obtain the token. Set `MS_TENANT_ID` /
`MS_CLIENT_ID`, then wire an MSAL client and post the id_token.

## 9. Photo attachment

`PhotoAttachButton` toggles a flag only. The endpoints exist
(`POST/DELETE /entries/{id}/photo`). Needs `image_picker`, then an `uploadPhoto`
on `EntryRepository` calling `ApiClient.upload` — the multipart path is already
written and used by the import.

## 10. Offline capture

Ground staff work with patchy connectivity. Entries should queue locally and
sync when the network returns. The repository interface is the right seam: a
`QueuedEntryRepository` decorating the real one, backed by local storage.

## 11. Smaller things

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
