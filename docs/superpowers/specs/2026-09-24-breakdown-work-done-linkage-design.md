# Linking Daily Work Done to Breakdowns (and other registers)

Design, 2026-09-24.

## Why

Today a breakdown is reported (`register=breakdown`, `BreakdownEntry` at
`backend/app/models/entry.py:238-275`) and a mechanic's Daily Work Done entry
(`register=work_done`, `WorkDoneEntry` at `backend/app/models/entry.py:179-203`)
are two completely disconnected rows in the same `entries` table. Nothing on
`work_done_entries` references the breakdown it was actually done against —
`employee` ("attended by") and `supervisor` are free text, `defect_source_id`
points at a master-list lookup, not at another entry. A breakdown's own
`attended_time`/`resolved_at` are entered by hand on the breakdown record
itself, disconnected from whatever Work Done entries were actually filed
against it. There is also no constraint stopping duplicate Work Done entries
for the same vehicle/day/shift, and Registers list rows only expose an Edit
action — there's no read-only View, and no way to see, from a breakdown, what
work was actually logged against it.

This spec makes Work Done the place where work against any register entry
(breakdown first, but generically any register) gets recorded, closes the
loop back onto the breakdown's own timing fields, and adds the missing View
affordance to Registers.

## Decisions

| Question | Decision |
| --- | --- |
| What can Work Done link to? | Any register entry (breakdown, coolant, driver_complaint, pm_schedule) via a single FK, since all registers are rows in the same `entries` table (`register` discriminator) — not a true polymorphic type+id pair. |
| How many sources per Work Done entry? | Exactly one (`source_entry_id`, nullable). Accepted limitation: a vehicle worked against two breakdowns in the same shift needs a primary pick — not solved here. |
| Is linking mandatory? | No — `source_entry_id` is nullable. Routine/general work logs with no source. |
| Source picker UX | Two-step: pick register type, then typeahead search by title/ID within that type, via a new `GET /entries/search` endpoint. |
| One-per-shift constraint | New unique constraint on Work Done entries: `(bus_id, entry_date, shift)`. |
| Breakdown timing fields | Collapse to exactly three: `reported_time` (renamed from `mechanic_reported_time`, made `NOT NULL`), `attended_time`, `resolved_at`. `breakdown_time` (the moment of breakdown itself) is dropped — confirmed data loss on existing rows is acceptable. |
| Where does `attended_time` come from? | Write-time derived: set once, from the first Work Done entry whose `source_entry_id` points at this breakdown. No longer manually entered. |
| Where does `resolved_at` come from? | Either of two paths, both kept: the existing standalone `POST /entries/{id}/resolve`, or a "mark breakdown resolved" flag + time captured on a linked Work Done entry. Both funnel through one shared resolve function so they can't drift. |
| Breakdown → linked Work Done view | Lives on the dedicated Breakdowns screen (`breakdowns_screen.dart`), not the generic Registers screen. |
| Registers View action | Registers screen gets a read-only View action alongside Edit, for every register type (not breakdown-specific). |
| Rollout | Local only. No push, no PR, no promotion until tested locally — this spec covers implementation, not release. |

## Data model

### `work_done_entries` (`backend/app/models/entry.py:179-203`)

New columns:
- `source_entry_id: int | None` — FK to `entries.id`, indexed. Nullable.
- `resolves_breakdown: bool` default `False`.
- `resolved_time: Time | None` — required (validated at the schema layer, not
  the DB layer) when `resolves_breakdown` is `True`.

New constraint:
- One-per-vehicle-per-shift, on `(bus_id, entry_date, shift)`. `bus_id` and
  `entry_date` live on the `Entry` header, `shift` on this detail table, so a
  plain table-level `UniqueConstraint` can't express it, and an app-level
  check-then-insert is racy under concurrent submissions from two devices.
  Enforce it with a Postgres trigger function (`BEFORE INSERT OR UPDATE ON
  work_done_entries`) that joins to `entries` and raises if a conflicting row
  already exists for the same `(bus_id, entry_date, shift)` — atomic at the
  database level, matching the codebase's preference for real DB-level
  guarantees over application-level ones. Pre-migration: run an audit query
  for existing duplicate `(bus_id, entry_date, shift)` rows — the trigger
  migration must not be applied while duplicates exist; resolve (merge or
  flag) them first.

Validation: reject `source_entry_id` where the target row's `register ==
'work_done'` — a Work Done entry cannot source another Work Done entry.

### `breakdown_entries` (`backend/app/models/entry.py:238-275`)

- Drop `breakdown_time`.
- Rename `mechanic_reported_time` → `reported_time`; add `NOT NULL`,
  backfilling existing nulls from `entries.entry_time` (the header's own
  entry timestamp is the closest available signal for pre-migration rows).
- `attended_time` stays a stored column but stops being user-editable via the
  create/update payload — it's now written only by the service layer (see
  below). Keep it on `BreakdownData` as output-only; remove it from
  create/update input validation (schema already uses `extra="forbid"` at
  `backend/app/schemas/entry.py:60-73`, so this is a matter of moving the
  field between an input model and an output model, not just documentation).
- `resolved_at` / `resolved_by_id` unchanged in shape, but two write paths
  instead of one (see Decisions table).

### Why not compute `attended_time` / resolution status at read time instead

Rejected alternative: never store `attended_time`, always derive it (and a
breakdown's "has work been attended" state) via a join over
`work_done_entries.source_entry_id` at serialization time. This pushes
complexity into every read path instead of the one write path — breakdowns
are read in the Registers list, the dedicated Breakdowns screen, the
`open_breakdowns` summary (`backend/app/api/entries.py:180-194`), and the
admin audit export, all of which would each need the extra join or a
materialized view. Write-time denormalization keeps those four read paths
untouched and puts the one piece of new logic in the Work Done create/update
path, which already touches the breakdown's parent Entry management code.

## API contract changes

`backend/app/schemas/entry.py`:
- `WorkDoneData`: add `source_entry_id: int | None`, `resolves_breakdown:
  bool = False`, `resolved_time: str | None` (`HH:mm`, validated required
  when `resolves_breakdown` is `True`). The breakdown's `resolved_at`
  (`TZDateTime`) is built by combining this Work Done entry's own
  `entry_date` with `resolved_time`, localized to the site's wall-clock
  timezone — the same convention `entry_time` already defaults to (site
  wall-clock/IST, not UTC), not the moment the API request happens to land.
- `BreakdownData`: drop `breakdown_time`; rename `mechanic_reported_time` →
  `reported_time` (required on create); move `attended_time`/`resolved_at`
  out of the writable input model into the response/output serialization
  only.

`backend/app/api/entries.py`:
- New `GET /entries/search?register=<register>&q=<text>` — returns
  `[{id, title, entry_date}]`. `title` is computed per register using the
  same display logic `registers_screen.dart` already uses for row labels
  (breakdown → truncated `complaint` + bus reg no.; coolant/driver_complaint
  /pm_schedule → their existing primary display field).
- Breakdown GET response gains `linked_work_done: [{id, entry_date, shift,
  employee, reported_defects, resolves_breakdown}]` — entries where
  `source_entry_id` equals this breakdown's id, ordered by
  `(entry_date, shift)`.
- `_resolve_breakdown(entry, resolved_by_id, resolved_time)` extracted as a
  single shared function used by both `POST /entries/{id}/resolve`
  (`backend/app/api/entries.py:288-317`) and the Work Done
  create/update path when `resolves_breakdown` is set — so the two paths
  cannot diverge on what "resolved" means.
- Work Done create/update: when `source_entry_id` is set and points at a
  breakdown, in the same transaction: set the breakdown's `attended_time` if
  currently unset; if `resolves_breakdown` is set, call the shared resolve
  function.

## Flutter changes

- `register_form_screen.dart`: Work Done form gains a "Link to" section —
  register-type dropdown, then typeahead hitting `/entries/search`. When the
  selected source is a breakdown, show a "Mark breakdown resolved" checkbox +
  time field.
- `breakdowns_screen.dart`: `_BreakdownCard` gains a "Linked Work Done"
  expandable list — date/shift/attended-by (`employee`)/resolved-flag per
  entry, each tappable to `Routes.editEntry(id)` (same deep-link pattern the
  in-flight admin audit work already added).
- `registers_screen.dart`: `_ResultRow` (`registers_screen.dart:474-553`)
  gains a **View** action next to Edit, opening `register_form_screen.dart`
  in a new read-only mode (fields and submit disabled).
- Bug fix bundled in, since this work already touches the resolve path:
  `app/lib/models/entry.dart`'s `EntryStatus` enum has only `open|done`,
  while the backend has `open|done|resolved`
  (`backend/app/models/enums.py:49-52`). Extend the Flutter enum to three
  values and remove the now-dead status parameter from
  `entriesProvider.notifier.resolveBreakdown`
  (`app/lib/state/entries.dart:160-167`), whose value the API already
  ignores (`app/lib/data/api/api_repositories.dart:645-649`).

## Migration

Alembic revision, in order:
1. Audit query for existing `(bus_id, entry_date, shift)` duplicates in
   `work_done_entries` joined to `entries` — surface a report; migration
   authoring stops here if duplicates exist, pending manual resolution.
2. Add `work_done_entries.source_entry_id` (FK → `entries.id`, indexed),
   `resolves_breakdown` (bool, default false), `resolved_time` (nullable
   Time).
3. Add the `(bus_id, entry_date, shift)` unique constraint.
4. `breakdown_entries`: backfill `mechanic_reported_time` from
   `entries.entry_time` where null, rename column to `reported_time`, set
   `NOT NULL`. Drop `breakdown_time`.

## Testing

- Backend: unique-constraint rejection (duplicate bus/date/shift), Work Done
  → breakdown resolve path sets `attended_time` once and only once across
  multiple linked entries, both resolve paths (`/resolve` endpoint and
  Work Done flag) converge on identical breakdown state, `source_entry_id`
  rejects a `work_done`-register target, `/entries/search` returns correct
  titles per register type.
- Frontend: Work Done form source picker round-trip, read-only View mode
  renders but cannot submit, Breakdowns screen linked-entries list renders
  and deep-links correctly, `EntryStatus` three-value enum doesn't break
  existing open/done filtering.
- Existing coverage note: `backend/README.md:198-204` already documents
  "breakdown open/resolve/409" as covered — extend that suite rather than
  duplicating it.
