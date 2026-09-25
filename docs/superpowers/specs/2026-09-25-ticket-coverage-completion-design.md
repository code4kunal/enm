# Ticket coverage completion: inspections, spare parts, driver master, coolant day-entry

Design, 2026-09-25. Extends `2026-09-24-breakdown-work-done-linkage-design.md`
(the `tickets` spine, now merged to `main`) to close the gaps that spec
explicitly left out of scope, plus additional client feedback gathered
against the "Defect Management Workflow" diagram and the legacy software's
Daily Work Done / Coolant / Driver Complaint / Breakdown / Inspection flows.

## Why

A gap audit of `main` post-merge against the client's full feedback found
four things still missing, three of them structural:

1. **Daily Inspection, 10-Day Inspection, and PM/Docking generate no ticket.**
   The prior spec named this out of scope. Worse: PM/Docking's *only* ticket
   path today targets the retired `pm_schedule` register — real PM/Docking
   work happens through `InspectionEntry` (checklist-based), which has zero
   ticket code. This is a design gap, not just an unbuilt feature.
2. **No spare-parts catalog.** `spare_parts_used` is independent free text on
   three registers; the client wants a Unit → Spare Part Number lookup.
3. **Source of Defect (manual vs auto) isn't surfaced.** The signal already
   exists in the schema (`Entry.source_fingerprint`, `WorkDoneEntry.ticket_id`)
   but is neither exposed nor labeled.
4. **Driver Complaint's `driver_id` is free text**, not linked to any driver
   master — same problem on `breakdown_entries.driver_id`. And **Coolant
   Topping is still one entry per bus**, not the day-based single entry
   covering all vehicles the client asked for.

This revision closes all four, reusing the `tickets` spine wherever the
requirement is "an issue generates work in the DWD pending list, tracked
back to its source."

## Decisions

| Question | Decision |
| --- | --- |
| Inspection ticket granularity | One ticket per **failed checklist result** (`InspectionResult`), not per inspection. A daily inspection with three failures is three DWD work items, same as three separate defects would be — matches how Breakdown/Coolant/Complaint are each one ticket per one defect. |
| `tickets.source_entry_id` | Becomes **nullable**. New nullable `source_inspection_result_id` FK → `inspection_results.id`, `UNIQUE`. Check constraint: exactly one of the two is set. A ticket's source is either a register entry or an inspection result — never both, never neither. |
| Filtering/search across two source shapes | New `tickets.source_kind` enum column (`breakdown \| coolant \| driver_complaint \| pm_schedule \| daily_inspection \| ten_day_inspection \| pm_docking`), stamped once at creation. Avoids a polymorphic join across `entries` and `inspection_results` on every search — the ticket picker's register-type filter becomes a plain `WHERE source_kind = ...`. Derived from `work_type.code` at creation time (`"D.I"` → `daily_inspection`, `"10 DAYS SERVICE"` → `ten_day_inspection`, `"P.M"` → `pm_docking`, matching the same code strings `docking_km.py`'s `DOCKING_WORK_TYPE` already hardcodes). |
| Inspection ticket creation | Automatic, inside `record_inspection`, same transaction — matches Breakdown's precedent and the requirement wording ("the issue **should generate**..."), not an opt-in "Raise ticket" button. |
| PM/Docking's existing (broken) ticket path | Removed. `Register.pm_schedule` comes out of `TICKETABLE_REGISTERS` — that register is retired for entry creation already; keeping it ticketable was dead code pointing at rows nothing creates anymore. Live PM/Docking tickets now come exclusively from `InspectionEntry` results where `work_type.code == "P.M"`. |
| Multiple Bus Inspection | New `POST /sites/{code}/inspections/batch` — shared fields (work type, date, time, supervisor) + a list of per-vehicle payloads (vehicle, odometer, results). Each vehicle becomes its own `InspectionEntry` row in one transaction; failures across all of them raise their tickets together. Existing single-bus endpoint is unchanged and still used for the single-bus flow. |
| ODO Punch | **Already correct — no work needed.** `services/checklists.record_inspection` already calls `odometer_service.record_reading(..., source=f"inspection {work_type.code}")` on a forward-only odometer value, so `InspectionEntry.odometer_km` already writes through to `OdometerReading`. The batch endpoint (below) reuses this same function per vehicle, so it inherits this for free. This item is a verification task, not a build task. |
| Spare Part catalog | New `spare_parts` master (`part_no`, `name`), **site-scoped like `Vehicle`** (`site_code` FK) — a depot's stocked parts are its own, unlike the tenant-wide `DefectSource`/`DefectType`/`WorkType` dropdowns. New `work_done_spare_parts` join table (`work_done_entry_id`, `spare_part_id`), mirroring `work_done_attendees`. `WorkDoneData.spare_parts_used` (free text) is dropped in favor of `spare_part_ids: list[str]`, same migration pattern the merged branch used for `employee` → `work_done_attendees`. Coolant/PM's own `spare_parts_used` columns are **not** touched this pass — Work Done is where the client's "Unit/Spare Part lookup" requirement actually lives (it's a Work Done bullet in the feedback), and touching three registers' free-text fields at once is unnecessary scope. |
| Source of Defect: manual vs auto | No new schema. Add a computed `entry_origin: manual \| linked \| imported` to `WorkDoneData`'s serialized output: `imported` if `Entry.source_fingerprint is not None`, `linked` if `ticket_id is not None`, else `manual`. Filterable via a new `origin` query param on the entries list endpoint. |
| Driver master | New `drivers` table (`driver_code`, `name`), **site-scoped like `Vehicle`** — a driver belongs to one depot's fleet, same reasoning as spare parts above. FK it from `driver_complaint_entries.driver_id` (currently absent — added by the merged branch as free text, per the earlier audit) **and** `breakdown_entries.driver_id` (currently free `String(64)`). Both free-text columns are dropped after backfill: existing values are copied into new `drivers` rows keyed by driver_code where the text looks like a code, else a driver row is created with that text as `name` and a generated code — best-effort, no data silently lost, matches the "confirmed acceptable data loss" precedent only where a value truly can't round-trip (it always can here, since the text becomes the name). |
| Coolant day-based entry | **No schema change.** `CoolantEntry` stays one row per bus — that's still the correct storage shape (each bus's litres, topped-by, supervisor are independent facts). What's missing is the *entry workflow*: a new `POST /entries/coolant/day` accepting one `entry_date` + a list of `{vehicle_id, bcs_litres, tcs_litres, topped_by}`, writing one `Entry`/`CoolantEntry` pair per vehicle in a single transaction, all sharing the same date and submitting supervisor. This is what "one daily entry auto-provides bus-wise entries" means operationally — one form action, N rows, not N form submissions. |
| Coolant × Work Done integration | Coolant already gained "Raise ticket" in the merged branch — no further work needed; this requirement is satisfied. |
| Traceability polish | Add `supervisor` to the `linked_sessions` payload (`GET` on any ticketed entry, not just Breakdown — generalize the field the merged branch added). Flutter's linked-sessions list gains an explicit "Originally logged — `<date/shift/supervisor/attendees>`" header on the first session and "Completed by — `<date/shift/supervisor/attendees>`" on whichever session has `completes_ticket=true`, instead of an undifferentiated flat list. |
| Complete/Pending filter | New filter chip pair in Registers and a new "Pending work" tab, backed by a straightforward `has_open_ticket: bool` query param — `true` returns entries whose `Entry` is a ticket source with `status=open`; `false`/omitted is today's behavior. Pure additive query, no new backend state. |
| Permissions for the new endpoints | No new permission resources. E&M's permissions are registered with the live siteops-platform (`app/permissions.py` → `POST /access-control/permissions/sync`), which is prod-only (no local/sandbox tier) — minting a new resource would need a platform administrator to grant it on a role before anyone could use the feature, outside this codebase's control. Spare Parts and Drivers CRUD/typeahead gate under the existing `em_master:read`/`em_master:write` (same as `DefectSource`/`DefectType`/staff); the Coolant bulk endpoint and inspection batch endpoint gate under the existing `em_entry:write` and `em_inspection:write` respectively. |
| Rollout | Local only, same as the prior spec, until tested locally end-to-end. |

## Data model

### `tickets` (`backend/app/models/ticket.py`) — modified

- `source_entry_id`: **now nullable**, `UNIQUE` (was `NOT NULL UNIQUE`).
- `source_inspection_result_id`: new, `FK → inspection_results.id`, nullable,
  `UNIQUE`.
- `source_kind`: new `TicketSourceKind` enum, `NOT NULL`.
- `CHECK` constraint: `(source_entry_id IS NULL) != (source_inspection_result_id IS NULL)`.
- `source_inspection_result` relationship, `lazy="joined"`, mirroring
  `source_entry`.

### `spare_parts` (new table)

- `id`: PK.
- `site_code`: FK → `sites.code`, `NOT NULL`.
- `part_no`: `String(64)`, `NOT NULL`.
- `name`: `String(160)`, `NOT NULL`.
- `is_active`: `bool`, default `True`.
- `UniqueConstraint(site_code, part_no)`.

### `work_done_spare_parts` (new table)

- `work_done_entry_id`: FK → `work_done_entries.entry_id`.
- `spare_part_id`: FK → `spare_parts.id`.
- Composite PK on `(work_done_entry_id, spare_part_id)`.

### `work_done_entries` — modified

- Drop `spare_parts_used` (free text). Replaced by the `work_done_spare_parts`
  join, same drop-after-migrate pattern as `employee`.

### `drivers` (new table)

- `id`: PK.
- `site_code`: FK → `sites.code`, `NOT NULL`.
- `driver_code`: `String(32)`, `NOT NULL`.
- `name`: `String(160)`, `NOT NULL`.
- `is_active`: `bool`, default `True`.
- `UniqueConstraint(site_code, driver_code)`.

### `driver_complaint_entries` / `breakdown_entries` — modified

- `driver_id` (both tables, currently free text) → `driver_id: FK → drivers.id, nullable`.
  Existing free-text values backfilled into `drivers` rows first (see
  Migration), then the column is retyped in place — not renamed, since
  `driver_id` was always meant to be an id.

### `inspection_entries` / `inspection_results` — unchanged

No schema change. `InspectionResult.id` becomes a ticket source via the
`tickets` table changes above; nothing on the inspection side needs to know
about tickets.

## API contract changes

`backend/app/schemas/entry.py`:
- `WorkDoneData`: replace `spare_parts_used: OptText` with
  `spare_part_ids: list[str] = []`. Add computed, output-only `entry_origin:
  Literal["manual", "linked", "imported"]` (not accepted on write — same
  read-only-echo pattern as `attendees`).
- `DriverComplaintData` / `BreakdownData`: `driver_id: OptText` →
  `driver_id: str | None` validated against the site's `drivers` table
  (same pattern `defect_source_id` already uses against `DefectSource`).
- `CoolantData`: unchanged (still one row's shape) — new bulk wrapper schema
  `CoolantDayCreate { entry_date: date, entries: list[CoolantDayRow] }` where
  `CoolantDayRow` is `{vehicle_id, bcs_litres, tcs_litres, topped_by}`, no
  `supervisor` per row (one submitting supervisor for the whole day).

New/changed endpoints:
- `POST /entries/coolant/day` — the bulk Coolant entry. Writes one
  `Entry`+`CoolantEntry` pair per row, all `entry_date` = the payload date,
  in one transaction. Returns the created entries.
- `POST /sites/{code}/inspections/batch` — Multiple Bus Inspection. Shared
  header + list of per-vehicle bodies; each becomes one `InspectionEntry`;
  any `not_ok` result across any vehicle raises its ticket in the same
  transaction.
- `record_inspection` (existing, both single and batch) — after persisting
  results, for each `result.result is CheckResult.not_ok`, calls a new
  `tickets.create_ticket_for_inspection_result(session, result=result,
  inspection=inspection, creator=user)`, which derives `source_kind` from
  `inspection.work_type.code` and stamps `source_inspection_result_id`.
- `GET /entries?...&origin=manual|linked|imported` — filters Work Done rows
  by the derived `entry_origin`.
- `GET /entries?...&has_open_ticket=true|false` — Complete/Pending filter.
- `GET /master/spare-parts?site=<code>&q=<text>` — typeahead, same shape as
  existing master-list lookups.
- `GET /master/drivers?site=<code>&q=<text>` — same.
- `linked_sessions` (generalized off Breakdown-only): gains `supervisor` per
  session.
- `tickets.ticket_title()` gains a branch for `source_inspection_result`:
  `f"{item.label[:60]} · {vehicle.registration_no}"`.
- `tickets.search_tickets()` filters on `source_kind` directly instead of
  joining `Entry.register`; the `register` query param on `/tickets/search`
  is generalized to `source_kind` (accepting both register values and the
  three new inspection kinds) — Flutter's ticket picker passes whichever
  `source_kind` matches the register it's raising from.

## Flutter changes

- `register_form_screen.dart` (Work Done form): spare parts field becomes a
  typeahead multi-add against `/master/spare-parts`, same widget pattern the
  merged branch's attendee multi-select already established. `entry_origin`
  shown as a small badge (read-only) once the ticket-link section is visible.
- Registers screen: two new filter chips, "Complete" / "Pending", wired to
  `has_open_ticket`. A "Pending" tab/section surfaces open-ticket rows across
  all registers in one list — this is the DWD Pending List the client asked
  for explicitly.
- Driver Complaint / Breakdown forms: `driver_id` free-text field becomes a
  typeahead against `/master/drivers`.
- New "Coolant — daily entry" screen: one date picker, one table listing
  every active vehicle at the site with inline BCS/TCS litre fields and a
  "topped by" field per row, one submit action → `POST /entries/coolant/day`.
  Replaces the per-bus Coolant form as the primary entry path; the per-bus
  form stays reachable for corrections via Registers → Edit.
- Daily/10-Day Inspection screens: add a bus-multi-select mode alongside the
  existing single-bus flow, posting to the batch endpoint when more than one
  vehicle is selected.
- `breakdowns_screen.dart` / any other linked-sessions consumer: render
  `supervisor` in each session row; give the first session and the
  `completes_ticket=true` session distinct visual treatment ("Originally
  logged" / "Completed by") instead of a flat list.

## Migration

Alembic revisions, in order:
1. `spare_parts`, `work_done_spare_parts`.
2. Backfill: for each distinct non-null `work_done_entries.spare_parts_used`
   value, best-effort split on common delimiters (`,`/`;`/newline) into
   `spare_parts` rows scoped to that entry's site (`part_no` generated,
   `name` = the split text), and link via `work_done_spare_parts`. Rows that
   don't split cleanly become one `spare_parts` row with the whole text as
   `name`. No data dropped — everything becomes *something* in the catalog,
   even if not perfectly parsed; a manager can merge/clean up catalog rows
   afterward same as any master-list hygiene task.
3. Drop `work_done_entries.spare_parts_used`.
4. `drivers`.
5. Backfill: distinct non-null `driver_complaint_entries.driver_id` and
   `breakdown_entries.driver_id` text values become `drivers` rows
   (site-scoped from the entry's site), then both columns are retyped to the
   FK and repointed at the matching row.
6. Add `tickets.source_kind` (`NOT NULL`, backfilled `'breakdown'`/`'coolant'`/
   `'driver_complaint'`/`'pm_schedule'` from the existing `Entry.register` of
   each ticket's current `source_entry_id` — all existing tickets are
   entry-sourced, so this backfill is unambiguous).
7. Make `tickets.source_entry_id` nullable; add
   `tickets.source_inspection_result_id`; add the two-column check
   constraint.
8. Remove `Register.pm_schedule` from `TICKETABLE_REGISTERS` (code change,
   not a migration) — no existing `pm_schedule` tickets to worry about, since
   that register has been uncreatable since the prior merge.

## Testing

Per the client's ask, this needs behavioral coverage beyond unit tests —
propagation through to the reports that already read ticket/entry state
(DMR's derived lines, the audit trail, PDF exports) is exactly what "did it
actually update downstream" verifies.

- **Backend unit**: one ticket per failed inspection result (not per
  inspection); a passing-only inspection creates zero tickets; batch
  inspection raises tickets for every vehicle's failures in one transaction;
  `source_kind` round-trips through `/tickets/search`; the two-column check
  constraint rejects a ticket with both or neither source set; spare-part
  multi-select persists and survives a part being deactivated; driver
  typeahead validation rejects an unknown `driver_id`; Coolant day-entry
  writes N independent `CoolantEntry` rows sharing one date and rolls back
  entirely if one row's vehicle is invalid; `has_open_ticket` filter matches
  exactly the entries whose ticket is `open`; `entry_origin` correctly
  resolves all three states from `source_fingerprint`/`ticket_id`.
- **Backend integration / propagation**: create a Daily Inspection failure →
  confirm it appears in the DWD pending list → complete it via a Work Done
  session → confirm the `InspectionResult`'s ticket flips `completed` →
  confirm the ticket's `linked_sessions` shows the completing session →
  confirm nothing in the DMR/PDF report pipeline breaks on inspection-sourced
  tickets (they were built assuming `source_entry_id` always non-null;
  anything walking `ticket.source_entry` directly needs to now branch on
  `source_kind`).
- **Frontend**: bulk Coolant screen round-trip (N vehicles, one submit, N
  rows created); multi-bus inspection flow; spare-parts and driver
  typeaheads; Complete/Pending filter chips; linked-sessions original-vs-
  completed rendering.
- **End-to-end sanity pass** (post-implementation, before calling this done):
  walk each of the four client-facing flows in the running app exactly as a
  depot user would — raise a Daily Inspection failure, carry a Work Done
  ticket across a shift change, submit a day's Coolant entry for all buses,
  log a Driver Complaint against a real driver — and confirm each one's
  effect is visible in Registers, the Pending list, and the relevant report
  (DMR / bus history / PDF) before reporting the work complete.
