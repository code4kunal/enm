# Journey catalogue

What a depot user does, and where the promise comes from. A journey with no
test is a hole, and the hole should be visible rather than absent.

| # | Journey | Oracle | Test |
| --- | --- | --- | --- |
| 1 | Sign in, reach the site, see the shell | HANDOFF 1-3 | `login_journey_test.dart` |
| 2 | The header names the site being worked in | CLAUDE.md, the only tenant boundary the UI exposes | `register_journey_test.dart` |
| 3 | Home offers a card per live register | HANDOFF 3-4 | `register_journey_test.dart` |
| 4 | The Registers view offers its period chips | HANDOFF 5 | `register_journey_test.dart` |
| 5 | The breakdown tracker reads sensibly, full or empty | HANDOFF 6 | `register_journey_test.dart` |
| 6 | Every export produces a real CSV or PDF | HANDOFF 5 | `test_reports_consistency.py` |
| B | The client boots and paints the login card | HANDOFF 1 | `smoke_boots_test.dart` |
| P | Register x role write permission | CLAUDE.md role ladder | `test_permissions.py` |
| T | A manager cannot reach another site | CLAUDE.md, "server re-checks site_access" | `test_permissions.py` |
| I | Personas provision themselves | — (suite's own prerequisite) | `test_personas.py` |
| E | An entry can be written back unchanged | HANDOFF 5, "save updates in place" | `test_entry_lifecycle.py` |
| D | An edit moves the derived report | DMR is computed on read | `test_entry_lifecycle.py` |
| R | Every derived report renders | HANDOFF, Annexure-IV | `test_reports.py` |
| C | A chart claiming availability has data | the API's own `available` flag | `test_reports.py` |
| V | Every field validated: required, blank, enum, range, master FK | HANDOFF 4, CLAUDE.md | `test_field_validation.py` |
| N | A bus number normalises however it is typed | CLAUDE.md conventions | `test_field_validation.py` |
| X | The DMR agrees with the entries it derives from | both derive from one source | `test_reports_consistency.py` |
| M | The month grid agrees with the day view | two endpoints, one truth | `test_reports_consistency.py` |
| Z | Every export produces a real CSV or PDF | HANDOFF 5, the depot prints these | `test_reports_consistency.py` |
| A | A chart says whether *this depot* can answer it | the API's `available` flag | `test_reports.py` |
| S | The contract publishes every register payload | README, "authority on the wire format" | `test_contract_shape.py` |
| Q | Published required fields are the enforced ones | a contract that lies is worse than none | `test_contract_shape.py` |
| L | A record cannot be dated outside the fleet's life | CLAUDE.md period filters | `test_field_validation.py` |
| IM | A re-imported month is a no-op | PENDING, "what makes backfill safe" | `test_imports.py` |
| IE | A bad import row is reported by row number | CLAUDE.md, server owns the error report | `test_imports.py` |
| CK | Every active bus has a checklist with checks | HANDOFF, an inspection is a sweep | `test_inspections.py` |
| IN | An inspection records the answers given | HANDOFF, the sweep's whole content | `test_inspections.py` |
| NF | A breakdown reaches its site's supervisor | HANDOFF 6 | `test_notifications.py` |
| NT | A notification never crosses a site boundary | CLAUDE.md site_access | `test_notifications.py` |

A dash means the journey is not covered. Fill it in; never delete the row.

## Registers

Four are writable, not the five HANDOFF describes. `pm_schedule` was retired in
favour of Inspections — see `findings/2026-08-19-0003.md`.
