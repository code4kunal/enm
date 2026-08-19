# A QA agent for Transvolt E&M

Design, 2026-08-19.

## Why

There is no QA person, and nothing tests the running system. Both halves are
well covered against their own assumptions and the seam between them is checked
only on paper:

| layer | what exists | what it proves |
| --- | --- | --- |
| Backend | 240 pytest tests vs real Postgres | the API is self-consistent |
| Flutter | 221 tests vs fakes in `test/support/` | the UI is self-consistent |
| Contract | `tools/check_contract.py`, 298 casts vs OpenAPI | the two agree statically |
| `app/test/integration/api_live_test.dart` | tagged `live`, skips when unreachable | has never run in CI |
| UI through a browser | nothing | nothing |

No user journey — log in, switch site, file a breakdown, find it in the
register, export it — has been executed by anything but a person clicking
through Chrome. The 221 app tests run against fakes, which is exactly how they
stay green while the seam goes untested.

## What was measured before designing

Three facts were established against the running system rather than assumed.
They constrain everything below.

**The UI is opaque to DOM tooling.** The client renders with CanvasKit:

    renderer:            canvaskit
    canvasCount:         0
    flt-semantics-host:  present but empty (0 nodes)
    bodyTextLen:         0

Playwright, Selenium and Cypress would all see an empty page. Flutter inserts a
`flt-semantics-placeholder`, but consuming it does not build the tree because
`main.dart` never calls `ensureSemantics()`. Any DOM-based plan requires a
testability change to production code.

**The database cannot support role testing as it stands.** 1 super_admin, 2
supervisors, 23 executives, and **zero managers** — the site-level role that
owns vehicles, master lists, docking config and import profiles. Every user
except the bootstrap super admin carries `must_reset_password = true`, so none
of them can be logged in as without first driving a reset.

**Only one credential works.** `KUNAL` / `admin`, super_admin. That is the
worst possible seat to test from: super_admin bypasses `site_access` entirely,
so every tenant-boundary bug is invisible from it.

## Shape

A ratchet: a deterministic floor that gates merges, and an exploratory ceiling
that raises the floor.

    CI (every push)              On demand / nightly
    +----------------------+     +------------------------+
    | smoke      ~90s      |     | hunter                 |
    | regression ~8m       |     |  - reads HANDOFF.md    |
    |                      |<----|  - drives real UI      |
    | deterministic        | new |  - files bug + TEST    |
    | blocks the merge     | test|  - never touches app/  |
    +----------------------+     +------------------------+
           floor                        ceiling

The hunter's output contract is the whole point: **every bug it reports arrives
with a failing deterministic test** added to the floor. It never finds the same
bug twice, and coverage only ratchets up.

### Components

    qa/
      api/            Python + httpx + pytest. Speaks HTTP as a client.
                      Not the backend's own suite: no app imports, no fixtures,
                      no database access. Journeys, not units.
      personas.py     Provisions its own users at known passwords.
      journeys.md     The catalogue, written from HANDOFF.md.
      findings/       One file per bug the hunter has ever found.

    app/integration_test/
      *_journey.dart  flutter drive -d chrome. Real UI, real API, real Postgres.

    .claude/agents/qa-hunter.md
                      The exploratory agent definition.

### Tiers

| tier | trigger | budget | gates a merge |
| --- | --- | --- | --- |
| smoke | every push | ~90s | yes |
| regression | every PR, nightly | ~8 min | yes |
| hunter | on demand, nightly | tokens | no |

## Staying a critic

The failure mode to design against is an agent that asserts what the code does
instead of what the depot was promised. Five mechanisms, not prompt tone:

1. **Oracle isolation.** The hunter may read `design/HANDOFF.md`,
   `data/MBMT/*.xlsx` and `backend/README.md` (the wire contract). It may not
   read `app/lib/**`, `backend/app/**`, or any existing test. A test that reads
   the implementation inherits the implementation's blind spots.
2. **Never super_admin.** Work as manager, supervisor and executive. Actively
   attempt cross-site access that should be refused.
3. **Adversarial framing.** The task is to disprove shippability, not confirm
   it. Ambiguity resolves to "broken, needs a human ruling", never "probably
   fine".
4. **The paper register wins.** Where the app disagrees with HANDOFF or MBMT's
   own sheet, the app is wrong — regardless of what the suite says.
5. **No fakes anywhere.** Real browser, real API, real Postgres.

## Test data

Two environments, deliberately different.

**Floor** — a fresh migrated and seeded database per run, with a scratch site.
Deterministic, parallel-safe, no MBMT data. The suite provisions its own
personas, because the live database has no manager and every other account
demands a password reset.

**Hunter** — a restore of the production-shaped dump: 57 real buses, 201 real
entries, the depot's actual mess. Realistic data is where the interesting bugs
are.

Personas the suite creates per run, on its own site:

| handle | role | used for |
| --- | --- | --- |
| `QA_MGR` | manager | master data, site config, imports |
| `QA_SUP` | supervisor | entry capture, breakdown resolve |
| `QA_EXEC` | executive | read-only, must be refused writes |
| `QA_OTHER` | manager on a *second* site | tenant-boundary probes |

`QA_OTHER` exists solely to prove `site_access` is re-checked server-side on
every request, which is the claim in the project's own CLAUDE.md.

## First cut

Six smoke journeys, drawn from HANDOFF sections 5 to 7:

1. Log in, land on the right site, see the site switcher.
2. Switch site; every list re-scopes.
3. File one entry per register (5), each with its exact HANDOFF field list.
4. Search and filter the register; period chips return the right rows.
5. Open a breakdown, mark it resolved, confirm it cannot resolve twice.
6. Export CSV and check the columns against the paper register.

Plus the API half: the register x role permission matrix. Five registers by
four roles is twenty combinations, plus cross-site refusal for each — a human
spot-checks three of those and calls it done.

## Finding format

    qa/findings/YYYY-MM-DD-NNNN.md

    SEVERITY: high | medium | low
    PERSONA:  supervisor @ MBMT
    ORACLE:   design/HANDOFF.md:70
    REPRO:    1. ...
              2. ...
    EXPECTED: what the depot was promised
    ACTUAL:   what the app did
    TEST:     qa/api/test_x.py::test_y  (added, currently FAILING)

The hunter never edits `app/` or `backend/`. It reports and it writes tests.
Fixes stay a human decision — an agent that both finds and fixes will sometimes
make the test match the bug.

## Out of scope

- Load, soak and performance testing.
- Visual regression by pixel diff. Too flaky to gate a merge; the hunter's eye
  covers gross visual breakage.
- Testing the docking checklist flow, which has no seeded content yet.
- Mobile platforms. Only web is scaffolded.

## Settled

**Postgres comes from the local Docker stack.** `backend/docker-compose.yml`
already provides it and `make db` already provisions `enm_test` with `pg_trgm`.
The floor creates its scratch database there rather than standing up its own.
CI keeps the `postgres:16` service container `ci.yml` already declares — same
image, same major version, so the two agree.

**The UI runs in real Chrome.** `flutter drive -d chrome`, not a headless
widget harness. This is what makes the floor a user test rather than a
developer one: real rendering, real network, real navigation.

## Open questions

- `flutter drive -d chrome` has never run in this workflow. CI will need Chrome
  installed and a display; locally it drives the desktop browser. Worth proving
  with one trivial journey before writing five more.
- Password reset is a journey the suite should cover, but the reset flow has
  not been read yet — it may need its own design. Every seeded account carries
  `must_reset_password`, so this is on the critical path for persona setup.
