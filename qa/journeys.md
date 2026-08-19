# Journey catalogue

What a depot user does, and where the promise comes from. A journey with no
test is a hole, and the hole should be visible rather than absent.

| # | Journey | Oracle | Test |
| --- | --- | --- | --- |
| 1 | Sign in, reach the site, see the shell | HANDOFF 1-3 | `login_journey_test.dart` |
| 2 | Switch site; every list re-scopes | CLAUDE.md, "every list is site-scoped" | — |
| 3 | File one entry per live register | HANDOFF 4 | — |
| 4 | Search and filter a register by period | HANDOFF 5 | — |
| 5 | Open a breakdown, resolve it, fail to resolve twice | HANDOFF 6 | — |
| 6 | Export CSV; columns match the paper register | HANDOFF 5 | — |
| B | The client boots and paints the login card | HANDOFF 1 | `smoke_boots_test.dart` |
| P | Register x role write permission | CLAUDE.md role ladder | `test_permissions.py` |
| T | A manager cannot reach another site | CLAUDE.md, "server re-checks site_access" | `test_permissions.py` |
| I | Personas provision themselves | — (suite's own prerequisite) | `test_personas.py` |
| E | An entry can be written back unchanged | HANDOFF 5, "save updates in place" | `test_entry_lifecycle.py` |
| D | An edit moves the derived report | DMR is computed on read | `test_entry_lifecycle.py` |
| R | Every derived report renders | HANDOFF, Annexure-IV | `test_reports.py` |
| C | A chart claiming availability has data | the API's own `available` flag | `test_reports.py` |

A dash means the journey is not covered. Fill it in; never delete the row.

## Registers

Four are writable, not the five HANDOFF describes. `pm_schedule` was retired in
favour of Inspections — see `findings/2026-08-19-0003.md`.
