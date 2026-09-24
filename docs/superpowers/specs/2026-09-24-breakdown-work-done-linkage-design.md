# Ticket-based work tracking: sources → Daily Work Done

Design, 2026-09-24. Supersedes the first revision of this file (a direct
`work_done_entries.source_entry_id → entries.id` FK with no shared queue
state), after review against the shared "Defect Management Workflow"
diagram (`~/Desktop/Defect Management Workflow-2026-09-23-111033.pdf`).

## Why

The diagram shows something richer than "Work Done points at a source":
every defect source (breakdown, coolant, complaint, inspection, PM/docking,
manual/auto defect entry) generates or links a **ticket**, which lands in a
shared "Daily Work Done Pending List". Allocation (shift/date/supervisor/
attending person) happens per ticket, work either completes in the current
shift or **carries forward** — original allocation is retained as history,
a new shift/date/person/supervisor is assigned, and the ticket returns to
the pending queue — until eventually work completes and the original
source's status auto-updates.

A single `source_entry_id` FK on `work_done_entries` can't represent this:
it has no shared state across sessions (no queue position, no "this ticket
is still open across 3 shifts" concept), and it assumed one Work Done row
per source rather than a chain of sessions. This revision introduces a
`tickets` table as the spine between a source and the (potentially many)
Work Done sessions logged against it over multiple days.

It also surfaces two things the first revision got wrong:
- The one-per-shift uniqueness constraint should be scoped to the
  **ticket**, not the vehicle — a bus can have two open tickets (e.g. a
  breakdown and a PM job) each getting their own session in the same shift.
  This resolves the same-shift conflict the first revision accepted as an
  unsolved limitation.
- "Attended by" is a **multi-select of engineers/mechanics**, not a single
  free-text name — and it turns out this is easy to make FK-backed:
  mechanics are already `users` rows (seeded under `Role.executive`,
  `backend/scripts/seed_staff.py`), `users.id` is already the FK target used
  elsewhere (`entries.created_by_id`, `breakdown_entries.resolved_by_id`,
  `backend/app/models/entry.py:141-143,265-267`), and users are
  soft-deactivated (`is_active`) rather than hard-deleted — so an FK
  survives staff turnover without needing the free-text workaround that
  justified `employee`/`supervisor` being plain strings in the first place
  (`backend/app/models/entry.py:196-199`).

## Decisions

| Question | Decision |
| --- | --- |
| Ticket entity | New `tickets` table. 1:1 with its source (`source_entry_id`, `NOT NULL UNIQUE`) — one ticket per source, always; tickets are never shared across multiple sources. |
| Ticket creation | Automatic for Breakdown, at entry creation (matches its existing always-open-until-resolved behavior). Explicit "Raise ticket" action for Coolant, Driver Complaint, PM/Docking — these still default to `status=done` on creation as today; a ticket only exists if someone raises one. |
| Rollout scope this pass | Breakdown, Coolant, Driver Complaint, PM/Docking get full ticket treatment. Daily/10-Day Inspection and Manual/Auto Defect Entry (shown in the diagram but not existing concepts in this codebase) are out of scope. |
| Work Done sessions | `work_done_entries` gains `ticket_id` (nullable FK). Each row is still a normal `Entry`/register row (Registers list, edit/view, audit trail — unchanged), now representing **one shift's session** against a ticket. A ticket accumulates many sessions over many days. Linking is still optional — general/routine work logs with no ticket. |
| Carry-forward mechanics | No extra state machine. A session either completes the ticket or doesn't (`completes_ticket: bool`); an incomplete session's row is left frozen as history, the ticket stays `open`, and it resurfaces in the pending list for the next shift's allocation. The next session is a new `work_done_entries` row when someone actually logs it — no placeholder row is pre-created. |
| Uniqueness constraint | `(ticket_id, entry_date, shift)` — ticket-scoped, not vehicle-scoped. `entry_date` lives on the `Entry` header, not on `work_done_entries`, so this still spans two tables and can't be a plain table-level `UniqueConstraint`; it's enforced with a Postgres trigger on `work_done_entries` instead. |
| Completion propagation | One shared service function, called when a session sets `completes_ticket=True`: ticket → `completed`, `completed_at`/`completed_by_id` set. For Breakdown specifically, also mirrors into `breakdown_entries.resolved_at`/`resolved_by_id` (preserves the field names existing code — SLA notifications, breakdown UI — already reads) and flips header `Entry.status` to `resolved`. For Coolant/Complaint/PM, flips header `Entry.status` to `resolved` only (no per-register detail fields exist for these today). |
| `attended_time`/`attended_at` | Ticket-level, derived: set once, from the first Work Done session ever logged against it. Mirrored into `breakdown_entries.attended_time` when the source is a breakdown. |
| Attending person(s) | New `work_done_attendees` join table (`work_done_entry_id` FK, `user_id` FK → `users.id`), multi-select. Replaces the single free-text `employee` column, which is dropped — same data-loss tradeoff already accepted for `breakdown_time`: old rows keep their free-text value in history/audit only, new rows use the join table. |
| Supervisor | Unchanged — stays a single free-text field. The diagram treats "Assign Supervisor" as a separate single-value step from the attending-person multi-select. |
| Source picker in Work Done form | Searches **open tickets**, not raw entries — register-type filter, then typeahead by title/ID (title computed from the ticket's one source, e.g. "Breakdown #124 · MH40LY1894 · AC not cooling"). |
| "Raise ticket" action placement | A button on the source entry's row (Breakdown/Coolant/Complaint/PM in Registers) for the three explicit-opt-in types. Not needed for Breakdown, which auto-creates. |
| Registers View action | Still added: read-only View next to Edit, for every register type — independent of the ticket work above. |
| Rollout | Local only. No push, PR, or promotion until tested locally. |

## Data model

### `tickets` (new table)

- `id`: PK.
- `source_entry_id`: FK → `entries.id`, `NOT NULL`, `UNIQUE`.
- `status`: `open | completed`. "Pending" vs "allocated" vs "in progress" are
  not stored — they're derived by whether an incomplete session exists.
- `completed_at`: `TZDateTime | null`.
- `completed_by_id`: FK → `users.id`, nullable.
- `attended_at`: `TZDateTime | null` — set once, from the first session.
- `created_at`, `created_by_id` (FK → `users.id`).

### `work_done_entries` changes (`backend/app/models/entry.py:179-203`)

New columns:
- `ticket_id`: FK → `tickets.id`, nullable, indexed.
- `completes_ticket`: `bool`, default `False`.
- `completion_time`: `Time | null` — required at the schema layer when
  `completes_ticket` is `True`. Combined with this session's own
  `entry_date`, localized to site wall-clock time (same convention
  `entry_time` already uses), to produce the ticket's `completed_at` and,
  for breakdown sources, `breakdown_entries.resolved_at`.

Dropped:
- `employee` (free-text "Attended By") — replaced by `work_done_attendees`.

New constraint:
- One session per `(ticket_id, entry_date, shift)`, enforced only where
  `ticket_id IS NOT NULL` (unlinked/general work has no such constraint).
  `entry_date` lives on the `Entry` header, not on `work_done_entries`, so
  this spans two tables and can't be a plain table-level
  `UniqueConstraint` — it's enforced with a Postgres trigger on
  `work_done_entries` instead, which also avoids the race an app-level
  check-then-insert would have under two devices submitting the same
  ticket/shift concurrently.

### `work_done_attendees` (new table)

- `work_done_entry_id`: FK → `work_done_entries.entry_id`.
- `user_id`: FK → `users.id`.
- Composite PK on `(work_done_entry_id, user_id)`.

### `breakdown_entries` (`backend/app/models/entry.py:238-275`)

Unchanged from the prior revision's plan:
- Drop `breakdown_time`. Confirmed acceptable data loss on existing rows.
- Rename `mechanic_reported_time` → `reported_time`, `NOT NULL`, backfilled
  from `entries.entry_time` where null.
- `attended_time` and `resolved_at`/`resolved_by_id` stop being
  user-editable input — they're now write targets of the ticket-completion
  propagation function described above, not fields on the create/update
  payload.

### Coolant / Driver Complaint / PM-Docking entries

No schema changes to their detail tables. Their only new behavior is the
"Raise ticket" action (creates a `tickets` row with `source_entry_id` =
this entry) and, on ticket completion, their header `Entry.status` flips
`open → resolved` (today they're created straight to `done` and have no
open/resolved concept — raising a ticket is what puts one of these entries
into an `open` state for the first time).

## API contract changes

`backend/app/schemas/entry.py`:
- `WorkDoneData`: add `ticket_id: int | None`, `completes_ticket: bool =
  False`, `completion_time: str | None` (`HH:mm`, required if
  `completes_ticket`), `attendee_user_ids: list[str] = []`. Remove
  `employee`. Validate `completes_ticket` is only ever `True` when
  `ticket_id` is set — unlinked/general work can't complete a ticket that
  doesn't exist.
- `BreakdownData`: as in the prior revision — drop `breakdown_time`; rename
  `mechanic_reported_time` → `reported_time`; `attended_time`/`resolved_at`
  move to output-only.

New/changed endpoints in `backend/app/api/entries.py`:
- `POST /entries/{id}/raise_ticket` — for Coolant/Complaint/PM entries only
  (409 if the entry already has a ticket, or if register is `breakdown`
  since that path is automatic, or `work_done` since a session can't be a
  source). Creates the `tickets` row and flips header status to `open`.
- Breakdown creation (`POST /entries` with `register=breakdown`) also
  creates its `tickets` row in the same transaction — automatic, no client
  action.
- `GET /tickets/search?register=<register>&q=<text>` — returns
  `[{ticket_id, title, entry_date, status}]` for `status=open` tickets whose
  source is of the given register, `title` computed the same way as
  `registers_screen.dart`'s existing row labels.
- Breakdown GET response gains `linked_sessions`: Work Done entries where
  `ticket_id` matches this breakdown's ticket, each with `entry_date`,
  `shift`, `attendees: [{user_id, name}]`, `reported_defects`,
  `completes_ticket`.
- `_complete_ticket(ticket, completed_by_id, completion_time)` — the one
  shared function for the completion propagation described in Decisions.
  Both the Work Done save path and (if kept for backward compatibility) a
  direct completion action call into this single function, so they can't
  diverge on what "complete" means. Given tickets now generalize what
  `/entries/{id}/resolve` did for breakdowns alone, that endpoint's internal
  logic is refactored to delegate to `_complete_ticket` rather than
  duplicating the state transition.

## Flutter changes

- `registers_screen.dart`: `_ResultRow` gains **View** (read-only, all
  register types) and, for Coolant/Complaint/PM rows without an existing
  open ticket, a **Raise ticket** action.
- `register_form_screen.dart` (Work Done form): "Link to" section becomes a
  ticket picker — register-type filter, then typeahead against
  `/tickets/search`. Attending person becomes a multi-select against
  `/master/staff`. A "Mark ticket complete" checkbox + time field appears
  when a ticket is linked.
- `MasterDataRepository.staff()` (`app/lib/data/api/api_repositories.dart:132-138`)
  currently discards the `id` the backend already returns, collapsing the
  response to `List<String>` — this is also used for the `supervisor` field
  elsewhere, so it can't simply be changed in place without touching every
  caller. Add a new method (e.g. `staffDirectory()`) returning ID-carrying
  items (mirroring `MasterListItem`, `app/lib/models/site.dart:275-298`) for
  the new attendee multi-select, and leave `staff()` and its existing
  callers (including `supervisor`) untouched.
- `breakdowns_screen.dart`: `_BreakdownCard` gains a "Linked Work Done"
  expandable list sourced from `linked_sessions`, each entry showing
  date/shift/attendees/`completes_ticket`, tappable to
  `Routes.editEntry(id)`.
- Bundled bug fix (unchanged from prior revision): extend
  `app/lib/models/entry.dart`'s `EntryStatus` to three values
  (`open|done|resolved`) and drop the dead status parameter from
  `entriesProvider.notifier.resolveBreakdown`
  (`app/lib/state/entries.dart:160-167`).

## Migration

Alembic revision, in order:
1. Create `tickets`.
2. Create `work_done_attendees`.
3. Add `work_done_entries.ticket_id`, `completes_ticket`, `completion_time`.
4. Backfill: every existing Breakdown entry (open or resolved) gets a
   `tickets` row — `status='completed'` with `completed_at`/`completed_by_id`
   copied from `breakdown_entries.resolved_at`/`resolved_by_id` where the
   breakdown is resolved, else `status='open'`. This makes old breakdowns
   visible in the new linked-sessions UI immediately. Existing
   `work_done_entries` rows are **not** retroactively linked to these
   backfilled tickets — there's no reliable way to infer which historical
   session belongs to which breakdown, which is the gap this feature
   closes going forward. Old sessions simply show with no ticket.
5. Drop `work_done_entries.employee` (after confirming no other read path
   depends on it beyond history/audit, which reads through
   `serialize_data`/`audit_snapshot` snapshots already taken at write time,
   unaffected by dropping the live column).
6. Add a Postgres trigger enforcing one session per
   `(ticket_id, entry_date, shift)`, scoped to `ticket_id IS NOT NULL` —
   not a table-level `UniqueConstraint`, since `entry_date` lives on the
   `Entry` header rather than on `work_done_entries`. Audit for existing
   violations first (should be none pre-feature, since `ticket_id` doesn't
   exist yet on any row until this migration populates it going forward).
7. `breakdown_entries`: backfill `mechanic_reported_time` from
   `entries.entry_time` where null, rename to `reported_time`, set
   `NOT NULL`. Drop `breakdown_time`.

## Testing

- Backend: raising a ticket twice on the same source 409s; a `work_done`
  register entry cannot be a ticket's source; two tickets on the same bus
  get independent sessions in the same shift (uniqueness doesn't
  false-positive); a second incomplete session correctly carries forward
  (ticket stays open, first session's row unchanged); `completes_ticket`
  converges Breakdown's `/resolve` endpoint and the Work Done path to
  identical state; attendee multi-select persists and still resolves names
  after a user is deactivated (`is_active=false`); `/tickets/search`
  filters correctly per register.
- Frontend: ticket picker round-trip, multi-select attendee picker,
  read-only View mode, Raise-ticket action appears only where applicable,
  Breakdowns screen linked-sessions list renders and deep-links.
- Existing coverage note: `backend/README.md:198-204` documents "breakdown
  open/resolve/409" as covered — extend rather than duplicate, since
  `/resolve` now delegates to `_complete_ticket`.
