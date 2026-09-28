# Driver Complaint / Breakdown traceability: display IDs, ticket history, linking UX

Design, 2026-09-28. Scoped to Driver Complaint and Breakdown per client
priority, but the four shared plumbing pieces (display IDs, ticket detail
view, Work Done linking UX, `attended_time`) are register-agnostic and every
other ticketable register (Coolant, PM/Docking, inspections) benefits for
free the day this ships — they are not re-scoped per register later.

## Why

Two client-facing gaps surfaced against the live app:

1. **No traceability.** Every entry is an opaque UUID; there is no
   human-readable number to write on a paper handoff or read over a phone
   call. Tickets exist (`tickets` spine, merged) but there is no screen to
   see them — only an indirect "open ticket" filter on the register list.
   Registers themselves are "naive": tapping a row jumps straight into an
   editable form with no read-only view, and nothing shows a Driver
   Complaint or Breakdown's full work history — only its own fields and
   (via a recent change) a flat, undifferentiated session list.
2. **Linking friction.** The Work Done form's ticket-link block sits near
   the bottom of the form, behind a register-filter dropdown plus a raw-UUID
   text search, and picking a ticket prefills nothing — the mechanic
   re-types bus/driver/route/defect that's already on the linked record.
   Driver Complaint additionally never opens a ticket automatically, so
   there's often nothing to link to without an extra manual click.
3. Two reference mockups (`Breakdown.pdf`, `Driver Completed.pdf`) show the
   target "Work Order Report" shape: a display ID, a linked-source card, a
   three-point timeline (reported / attended / completed), work sessions
   with mechanic + spare parts, photos, and a captured location — used here
   as the layout reference for the new Ticket Detail screen.

## Decisions

| Question | Decision |
| --- | --- |
| Display ID format | `<PREFIX>-<YYYY>-<NNNNNN>`, e.g. `BD-2026-000123`, `DC-2026-000123`, `WD-2026-000123`. Per-type-per-year, zero-padded to 6 digits, resets each year — matches how the paper registers numbered pages. Every `Entry` and every `Ticket` gets one regardless of register/source_kind (`display_id` is `NOT NULL` on both tables — a migration backfilling only some rows would leave a nullable column with dead branches), but this pass only *surfaces* them in the UI for Breakdown/Driver Complaint/Work Done. `Entry.register` → prefix: `work_done`→`WD`, `breakdown`→`BD`, `driver_complaint`→`DC`, `coolant`→`CT`, `pm_schedule`→`PS`. `Ticket.source_kind` → prefix: `breakdown`→`BD`, `driver_complaint`→`DC`, `coolant`→`CT`, `daily_inspection`→`DI`, `ten_day_inspection`→`TD`, `pm_docking`→`PM`, `pm_schedule`→`PS` (retired, only pre-existing rows use it). Entry and Ticket prefixes intentionally share letters for the same concept (`BD`, `DC`, `CT`, `PS`) since they're never displayed side by side in a way that could confuse one for the other — each always appears labeled ("Entry #" vs a ticket's own display). |
| Counter mechanism | New `id_counters(kind TEXT, year INT, next_value INT, PRIMARY KEY(kind, year))` table. Allocation is `INSERT ... ON CONFLICT (kind, year) DO UPDATE SET next_value = id_counters.next_value + 1 RETURNING next_value`, done inside the same transaction as entry/ticket creation. Atomic under concurrent creates without app-level locking — Postgres serializes the upsert. `kind` is namespaced by table so `Entry` and `Ticket` never share a counter even when the underlying concept is the same string (`Register.breakdown` and `TicketSourceKind.breakdown` are both `"breakdown"`): entries allocate under `f"entry:{register.value}"`, tickets under `f"ticket:{source_kind.value}"`. Fully independent sequences — an `Entry`'s and its `Ticket`'s numbers are unrelated and not expected to match. |
| Where `display_id` lives | On `Entry` (all registers, so Work Done gets one too) and on `Ticket` (every ticket, including inspection-sourced ones with no backing `Entry`). Both are `NOT NULL` — the invariant is "every row of this table has one," not "one per source." **Which one the UI shows**: for a ticket with a `source_entry` (Breakdown, Driver Complaint — always true for both this pass), the screen shows the **entry's** `display_id` (`BD-2026-…`, `DC-2026-…`) as the record's one human identifier, matching the mockups ("Breakdown ID: BD-9683" is the breakdown record's own id, not a separate ticket number). `Ticket.display_id` is not surfaced anywhere in this pass's UI — it exists now (so the column isn't added twice later) but only becomes user-visible once inspection-sourced tickets (no source entry) get their own screen, out of scope here. |
| Driver Complaint auto-opens a ticket | Yes — `Register.driver_complaint` joins `Register.breakdown` in the automatic-ticket-on-create path in `POST /entries` (currently only breakdown gets this; `raise_ticket` stays as a fallback for any complaint entry created before this ships, and remains available for Coolant unchanged). |
| Ticket Detail screen | One new screen/endpoint reused from two entry points: a new `/tickets` list (open + resolved, searchable) and a **View** button on Breakdown/Driver Complaint register rows. Shows the source entry's own fields, the reported → attended → resolved timeline, every Work Done session ever logged against the ticket (not just the latest), photos, and location. **Edit is untouched** — still the register form, reachable only from Registers, per existing instruction that breakdown editing stays there. |
| `GET /tickets/search` closed-ticket support | Add `status: open \| completed \| all` query param (default stays `open`, so existing callers — the Work Done linking picker — are unaffected). The new `/tickets` list screen is the first caller to pass `all` or `completed`. |
| `GET /tickets/{id}` (new) | Returns the ticket, its source entry's full field set, and its `linked_sessions` (already exists off Breakdown — generalized here to be a first-class part of the ticket response, not a per-register bolt-on). |
| Work Done linking UX | Move `_TicketLinkSection` from after the Unit section to immediately after the Shift field — first block in the form. Replace the register-filter `AppSelect` + separate free-text field + plain-text result list with one `AppMultiSelect`-style searchable typeahead (single-select) matching free text **or** the source entry's `display_id`. On pick, populate a new read-only "Linked ticket context" block (bus, driver, route, original complaint/defect text) sourced from the ticket's `source_entry` — the mechanic no longer retypes it. The Work Done form's own editable fields (attended details, spare parts, mechanics, times) are unchanged; only the now-redundant re-entry of source-entry fields is removed for a linked session. |
| Work Done `attended_time` | New explicit `attended_time: HHMM` on `WorkDoneData`, same shape and same-record validation pattern as `completion_time` (no requirement it be set — a session that only attends, without completing, may still omit it, matching today's optionality). When present, `mark_attended(ticket, _session_moment(entry, detail.attended_time))` uses it instead of the bare `_session_moment(entry)`, which today silently uses the entry's own submission moment. |
| Photos | **Correction from the first draft**: this repo already has a working single-photo-per-entry feature — `services/storage.py` (local-disk save/validate/delete), `POST`/`DELETE /entries/{id}/photo`, `Entry.photo_key`/`photo_url`, and a Flutter picker already wired into `register_form_screen.dart`'s save flow for every register. The first draft proposed a parallel S3 + presigned-URL `entry_attachments` system, which would have duplicated it on inconsistent infra (cloud storage nobody's configured locally, next to disk storage that already works) — dropped. Instead: promote the existing single `photo_key`/`photo_url` columns on `Entry` into a new one-to-many `entry_photos` table (`entry_id`, `storage_key`, `url`, `caption`, `uploaded_by_id`, `created_at`), reusing `storage.save_photo`/`storage.delete_photo` as-is (already generic per `entry_id`, already random-named, nothing about them assumes one-per-entry). Scoped to Breakdown, Driver Complaint, and Work Done this pass — every other register keeps today's single-photo behavior unchanged, since multi-photo isn't part of this spec's scope. |
| Location capture | New `latitude NUMERIC(9,6)`, `longitude NUMERIC(9,6)`, `location_source ENUM(gps, map, manual)` on `breakdown_entries` and `driver_complaint_entries` — additive to the existing free-text `location`/route fields, not a replacement. Captured client-side at entry-creation time; the existing text fields keep describing *what* the location is ("Depot A → Andheri"), the new columns capture *where*, precisely. |
| Map widget | `flutter_map` + OpenStreetMap raster tiles, not `google_maps_flutter` — no API key or billing account needed, and depot-grade location display doesn't need Google's tiles. Used only for optional "pick on map" and a small static preview on the Ticket Detail screen; not embedded in every list row. |
| Platform reality for camera/GPS | The app runs via `flutter run -d chrome` (per this repo's README) — this is a **web** build, not a native mobile app. `image_picker` on web opens the OS file picker (camera-capture attribute works on phones' mobile browsers, but on desktop Chrome it's a plain file chooser, not a live in-app camera view like the mockups suggest). Browser Geolocation likewise prompts the standard browser permission dialog, not a native OS one, and only works over `localhost` or HTTPS. None of this blocks the feature — it works today for the existing single-photo picker — but "camera capture" on a desktop test session will look like a file dialog, not the mockup's live camera screen. Worth knowing going in so a desktop QA pass isn't read as a bug. |
| Rollout | Local only, same as prior specs, until tested end-to-end. |

## Data model

### `id_counters` (new table)

- `kind`: `String(32)`, part of composite PK — one of the `TicketSourceKind`
  values, or `"work_done"` (a `Register` value that isn't itself a
  `TicketSourceKind`).
- `year`: `Integer`, part of composite PK.
- `next_value`: `Integer`, `NOT NULL default 1`.

### `entries` — modified

- `display_id`: `String(20)`, `NOT NULL`, `UNIQUE`. Backfilled in creation
  order per register during migration.

### `tickets` — modified

- `display_id`: `String(20)`, `NOT NULL`, `UNIQUE`. Backfilled in creation
  order per `source_kind`.

### `work_done_entries` — modified

- `attended_time`: `Time`, nullable — mirrors `completion_time`'s shape.

### `breakdown_entries` / `driver_complaint_entries` — modified

- `latitude`: `Numeric(9, 6)`, nullable.
- `longitude`: `Numeric(9, 6)`, nullable.
- `location_source`: new `LocationSource` enum (`gps`, `map`, `manual`),
  nullable.

### `entry_photos` (new table, replaces `Entry.photo_key`/`Entry.photo_url`)

- `id`: PK, `String(32)`, `default=new_uuid`.
- `entry_id`: `FK → entries.id, ondelete=CASCADE`, `NOT NULL`.
- `storage_key`: `String(255)`, `NOT NULL` — same value shape `storage.save_photo` already returns.
- `url`: `String(500)`, `NOT NULL`.
- `caption`: `String(255)`, nullable.
- `uploaded_by_id`: `FK → users.id, ondelete=SET NULL`, nullable.
- `created_at`: standard `created_at_col()`.

`Entry.photo_key` / `Entry.photo_url` are dropped after migrating any
existing value into this table as that entry's first row — same
drop-after-migrate pattern this repo already used for `WorkDoneEntry.employee`
→ `work_done_attendees`.

## API contract changes

`backend/app/schemas/entry.py`:
- `WorkDoneData`: add `attended_time: HHMM | None = None`.
- All entry `*Data` output serializers gain `display_id: str` (read-only,
  server-stamped, never accepted on write).
- `BreakdownData` / `DriverComplaintData`: add `latitude: Decimal | None`,
  `longitude: Decimal | None`, `location_source: Literal["gps","map","manual"]
  | None`.

New/changed endpoints:
- `POST /entries` (driver_complaint branch): after `create_ticket_for_entry`
  runs for breakdown, add the same call for `Register.driver_complaint`.
- `GET /tickets/search`: add `status: Literal["open","completed","all"] =
  "open"` query param, threaded into `search_tickets()`'s existing
  `Ticket.status == TicketStatus.open` filter (becomes conditional).
- `GET /tickets/{ticket_id}` (new): ticket + source entry (full field set,
  via existing `serialize_entry`) + `linked_sessions` + photos.
- `POST /entries/{entry_id}/photos` (new, multipart) and
  `DELETE /entries/{entry_id}/photos/{photo_id}` (new) **replace**
  `POST`/`DELETE /entries/{entry_id}/photo` for every register, not just
  these three — one backend surface, no register branching, since photos
  were already entry-scoped, not register-scoped. Both reuse
  `storage.validate_photo`/`storage.save_photo`/`storage.delete_photo`
  unchanged, only swapping the single-column update for an `entry_photos`
  row. Registers other than Breakdown/Driver Complaint/Work Done keep
  today's one-photo Flutter widget, which simply caps itself at index 0 of
  the same list the new endpoint returns — no UI change for them, no second
  backend code path to maintain.
- `services/entries.create_entry` (or its ticket-adjacent caller): after
  inserting the row, allocates `display_id` via the `id_counters` upsert in
  the same transaction.
- `services/tickets.create_ticket_for_entry` /
  `create_ticket_for_inspection_result`: same allocation for
  `Ticket.display_id`.
- `services/tickets.search_tickets`: ticket picker's free-text match (`q`)
  additionally matches the joined source entry's `display_id`
  (case-insensitive prefix or exact) — this is the id the user actually
  sees and would type (`BD-2026-…`, `DC-2026-…`), not `Ticket.display_id`,
  which stays unsurfaced this pass (see the display-id Decision row above).

## Flutter changes

- `register_form_screen.dart`:
  - `_TicketLinkSection` moves to immediately after the Shift field.
  - Ticket picker becomes a single searchable typeahead (reusing the
    `AppMultiSelect` widget's search/filter internals in single-select mode,
    the same generalization already used for the mechanic picker), querying
    `ticketSearchProvider` with `q` matching text or display ID.
  - New read-only "Linked ticket context" block renders once a ticket is
    picked: bus, driver, route, original complaint/defect — sourced from the
    ticket search result's echoed source-entry fields (the search endpoint
    already returns enough for `ticket_title`; extend the result shape with
    the handful of fields this block needs).
  - New "Attended time" `HHMM` field, next to the existing "Attended
    details" field.
  - Photo capture: the existing single-photo picker becomes a gallery
    (pick/remove multiple, each with an optional caption) for Breakdown,
    Driver Complaint, and Work Done — reusing the same pick-then-upload-on-
    save flow already implemented, just against the list-returning endpoint.
  - Location capture: on Breakdown/Driver Complaint forms, attempt device
    GPS on form open (`location_source = gps`), fall back to a "pick on
    map" (`flutter_map`) or manual lat/long entry (`location_source = map` /
    `manual`) if GPS is denied or the user overrides.
- New `tickets_screen.dart` + `Routes.tickets` route: list of tickets for
  the active site, status filter (open/completed/all), search by text or
  display ID, tap-through to Ticket Detail.
- New `ticket_detail_screen.dart` + `Routes.ticketDetail(id)`: renders the
  layout from the two reference mockups — header (display ID, status,
  vehicle, shift), source fields, linked-source card, reported/attended/
  completed timeline, all linked Work Done sessions (mechanic, spare parts,
  attended/completion times), photos, location (static `flutter_map`
  preview + coordinates).
- `registers_screen.dart`: Breakdown and Driver Complaint rows gain a
  **View** action (navigates to Ticket Detail if the entry has a ticket,
  else a plain read-only field dump) alongside the existing **Edit** action
  (unchanged, still the register form).
- `data/repositories.dart` / `data/api/api_repositories.dart`:
  `TicketRepository` gains `get(ticketId)`. `EntryRepository.attachPhoto`
  changes return type from `Future<String>` (one URL) to
  `Future<List<EntryPhoto>>` (the full updated list, `{id, url, caption}`
  each); `removePhoto(entryId)` becomes `removePhoto(entryId, photoId)`. Both
  call sites in `register_form_screen.dart` update accordingly — this is a
  breaking signature change to an existing method, not an addition.
- Fakes (`test/support/fake_repositories.dart`) updated in the same pass for
  both new methods, per this repo's "a drifting fake is worse than no fake"
  rule.

## Migration

Alembic revisions, in order:
1. `id_counters`.
2. `entries.display_id` (nullable first), backfill per-register in
   `entry_date`-then-`created_at` order (best available proxy for original
   sequence, since no creation-order column beyond `created_at` exists),
   then `ALTER COLUMN ... SET NOT NULL` + unique index.
3. `tickets.display_id`, same pattern keyed by `source_kind` +
   `created_at`.
4. `work_done_entries.attended_time`.
5. `breakdown_entries` / `driver_complaint_entries`: `latitude`,
   `longitude`, `location_source`.
6. `entry_photos`; backfill each entry with a non-null `photo_key` into one
   row; drop `entries.photo_key` / `entries.photo_url`.

## Testing

- **Backend unit**: `id_counters` allocation is race-safe under concurrent
  creates (two simulated concurrent inserts for the same kind+year never
  collide); `display_id` format matches
  `^[A-Z]{2}-\d{4}-\d{6}$`; counters roll over correctly at a year boundary
  (`entry_date` in a new year gets `000001`, not a continuation); driver
  complaint creation now opens a ticket exactly like breakdown;
  `GET /tickets/search?status=all` returns both open and completed;
  `GET /tickets/search` (default) still excludes completed, unchanged;
  `GET /tickets/{id}` 404s for another site's ticket (site-scoping holds);
  `mark_attended` uses the form's `attended_time` when present, falls back
  to entry-submission moment when absent; `POST /entries/{id}/photos` twice
  produces two rows, not a replace; `DELETE` removes exactly the named photo
  and leaves the others; every existing single-photo test in
  `test_entries.py` still passes unchanged against the new endpoints
  (behavior-preserving for the one-photo case); location fields round-trip
  through `GET`-then-`PUT`.
- **Backend integration**: create a Driver Complaint → ticket appears in
  `/tickets/search` immediately (no manual raise) → link a Work Done session
  with `attended_time` set → ticket's `attended_at` matches the given time,
  not the session's submission time → complete via a second session →
  `GET /tickets/{id}` shows both sessions in `linked_sessions`, correctly
  ordered, with the completing one flagged.
- **Frontend**: ticket picker typeahead matches both free text and display
  ID; picking a ticket populates the read-only context block and it's not
  editable; Tickets screen status filter and search; View button on a
  Breakdown/Driver Complaint row opens Ticket Detail showing every linked
  session; multi-photo gallery round-trips (pick two, save, both appear in
  Ticket Detail, remove one, the other survives); location capture records
  GPS by default and falls back to manual/map when denied.
- **End-to-end sanity pass** (post-implementation): file a Driver Complaint
  as a depot user, confirm its ticket appears unprompted in `/tickets`,
  link and complete it from Work Done with an explicit attended time, then
  open its Ticket Detail view and confirm the full history (both sessions,
  both timestamps, any photos, the captured location) renders — the same
  walk for a Breakdown.
