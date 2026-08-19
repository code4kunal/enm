# QA Agent Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the deterministic QA floor — a browser-driven UI journey and an
API journey that both run against the real stack — plus the hunter agent definition,
proving the toolchain works before more journeys are written on top of it.

**Architecture:** Two tiers. A deterministic floor gates merges: `qa/api/` speaks
HTTP as a client, `app/integration_test/` drives real Chrome via `flutter drive`.
An exploratory hunter agent runs on demand, judges the app against
`design/HANDOFF.md` rather than against source, and files findings with failing
tests attached. This plan builds the floor's foundation and one journey per side.
Journeys 2–6 are a separate plan, written only once Task 4's pattern is proven.

**Tech Stack:** Dart `integration_test` + `flutter drive -d chrome` + chromedriver;
Python 3.11 + httpx + pytest; Postgres 16 from `backend/docker-compose.yml`.

**Spec:** `docs/superpowers/specs/2026-08-19-qa-agent-design.md`

## Global Constraints

- **The floor never imports application code.** `qa/api/` must not import from
  `backend.app`. It uses HTTP and `backend/README.md` only.
- **Finders come from `design/HANDOFF.md`, not from widget source.** A journey
  looks for text the user was promised. If the app disagrees, the app is wrong.
- **Never test as `super_admin`.** It bypasses `site_access` and hides every
  tenant bug. `KUNAL`/`admin` is used only to provision personas.
- **API base URL** is passed as `--dart-define=API_BASE_URL=...`, default
  `http://localhost:8123/api/v1`. This name already exists in
  `app/test/integration/api_live_test.dart`; do not invent a second one.
- **Registers are exactly five:** `work_done`, `coolant`, `driver_complaint`,
  `breakdown`, `pm_schedule`. **Roles are exactly four:** `super_admin`,
  `manager`, `supervisor`, `executive`.
- **Dates are `yyyy-MM-dd` strings; times are `HH:mm`.** Registration numbers are
  uppercase with no whitespace.
- Every task ends with a commit.

---

### Task 1: Make `flutter drive -d chrome` run at all

Nothing else in this plan works until this does. The measured state of this
machine on 2026-08-19: ChromeDriver 143.0.7499.40, Chrome 151.0.7922.138. Those
major versions must match or session creation fails with an error that reads like
a Flutter fault and is not one. `integration_test` is bundled with the SDK but is
absent from `pubspec.yaml`.

**Files:**
- Modify: `app/pubspec.yaml` (dev_dependencies)
- Create: `app/integration_test/smoke_boots_test.dart`
- Create: `app/test_driver/integration_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces: a working `flutter drive` invocation that later tasks copy verbatim,
  and the driver entrypoint `app/test_driver/integration_test.dart` that every
  future `integration_test` file is run through.

- [ ] **Step 1: Confirm the version mismatch is real on this machine**

```bash
chromedriver --version
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --version
```

Expected: two different leading major numbers (143 vs 151 as measured). If they
already match, skip Step 2.

- [ ] **Step 2: Install a matching chromedriver**

```bash
brew upgrade chromedriver || brew install chromedriver
chromedriver --version
```

Expected: the major version now equals Chrome's (151 as measured). macOS
quarantines the binary; clear it or chromedriver dies silently:

```bash
xattr -d com.apple.quarantine "$(which chromedriver)" 2>/dev/null || true
```

- [ ] **Step 3: Add `integration_test` to dev_dependencies**

In `app/pubspec.yaml`, under `dev_dependencies`, after the `flutter_lints` line:

```yaml
  integration_test:
    sdk: flutter
```

Then:

```bash
cd app && flutter pub get
```

- [ ] **Step 4: Create the driver entrypoint**

`app/test_driver/integration_test.dart` — this file is boilerplate required by
`flutter drive` and never changes:

```dart
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
```

- [ ] **Step 5: Write the smallest possible failing journey**

`app/integration_test/smoke_boots_test.dart`. It asserts only that the app boots
and paints the login screen. The strings come from `design/HANDOFF.md` section 1,
which specifies the heading "E & M MAINTENANCE" and the button "Sign in with
Microsoft".

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:transvolt_em/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the app boots to the login screen', (tester) async {
    app.main();
    // The login screen animates in; settle with a timeout rather than
    // pumpAndSettle(), which never returns while the chevrons loop.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 2));

    // design/HANDOFF.md section 1: the card carries this heading and this
    // button. Asserted as the user reads them, not as the widget tree spells
    // them.
    expect(find.text('E & M MAINTENANCE'), findsOneWidget);
    expect(find.text('Sign in with Microsoft'), findsOneWidget);
  });
}
```

- [ ] **Step 6: Run it and watch it fail for the right reason**

```bash
cd app && flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/smoke_boots_test.dart \
  -d chrome \
  --dart-define=API_BASE_URL=http://localhost:8123/api/v1
```

Expected on first run: either PASS, or a failure naming the *finder*
("Expected: exactly one matching node"). Either is success for this task — the
toolchain ran.

A failure mentioning `chromedriver`, `session not created`, or
`Unable to start`, means Step 2 did not take. Do not proceed; fix the driver.

If the animated chevrons make the test hang, the cause is `pumpAndSettle` on a
looping animation. This test already avoids it. Never reintroduce it.

- [ ] **Step 7: If the finder failed, correct it against HANDOFF — not against source**

Read `design/HANDOFF.md` section 1 again and use the exact strings it specifies.
If the app genuinely does not render what HANDOFF promises, that is the first
finding: record it at `qa/findings/` (format in Task 5) and change the test to
assert what HANDOFF says, leaving it red. A red floor test describing a real
spec violation is a correct outcome, not a blocked task.

- [ ] **Step 8: Commit**

```bash
git add app/pubspec.yaml app/pubspec.lock app/test_driver app/integration_test
git commit -m "Drive the real client in a real browser

CanvasKit paints to a canvas, so the DOM carries no text and Playwright
sees an empty page. Flutter's own integration_test drives the widget tree
inside real Chrome instead, which is the only way to test this client as
a user sees it.

chromedriver must match Chrome's major version or session creation fails
with an error that reads like a Flutter fault."
```

---

### Task 2: Provision QA personas

The live database cannot support role testing: it holds zero managers, and every
account except the bootstrap super admin carries `must_reset_password`. The suite
creates what it needs rather than depending on seeded staff.

**Files:**
- Create: `qa/__init__.py` (empty)
- Create: `qa/personas.py`
- Create: `qa/conftest.py`
- Create: `qa/requirements.txt`
- Test: `qa/api/test_personas.py`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `Persona` dataclass with fields `handle: str`, `password: str`,
    `role: str`, `site: str`.
  - `provision(base_url: str) -> dict[str, Persona]` returning keys
    `"manager"`, `"supervisor"`, `"executive"`, `"other_manager"`.
  - `token_for(base_url: str, p: Persona) -> str` returning a bearer token.
  - pytest fixtures `base_url`, `personas`, `client_for` used by all later
    API tasks.

- [ ] **Step 1: Create the Python dependency list**

`qa/requirements.txt`:

```
httpx==0.27.2
pytest==8.3.3
pytest-asyncio==0.24.0
```

Install into the existing backend venv so there is one interpreter:

```bash
backend/.venv/bin/pip install -r qa/requirements.txt
```

- [ ] **Step 2: Write the failing test**

`qa/api/test_personas.py`:

```python
"""The suite must be able to create the identities it tests as.

The live database has no manager and every seeded account demands a password
reset, so nothing here depends on data that happens to be present.
"""
from qa.personas import provision, token_for


def test_provision_creates_all_four_roles(base_url):
    people = provision(base_url)
    assert set(people) == {"manager", "supervisor", "executive", "other_manager"}
    assert people["manager"].role == "manager"
    # The tenant probe must live on a different site or it proves nothing.
    assert people["other_manager"].site != people["manager"].site


def test_each_persona_can_log_in_without_a_password_reset(base_url):
    people = provision(base_url)
    for name, p in people.items():
        token = token_for(base_url, p)
        assert token, f"{name} could not log in"


def test_provision_is_idempotent(base_url):
    first = provision(base_url)
    second = provision(base_url)
    assert {k: v.handle for k, v in first.items()} == {
        k: v.handle for k, v in second.items()
    }
```

- [ ] **Step 3: Run it to verify it fails**

```bash
backend/.venv/bin/python -m pytest qa/api/test_personas.py -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'qa.personas'`.

- [ ] **Step 4: Write the fixtures**

`qa/conftest.py`:

```python
import os

import pytest

from qa.personas import provision, token_for


@pytest.fixture(scope="session")
def base_url() -> str:
    return os.environ.get("QA_API_BASE", "http://localhost:8123/api/v1")


@pytest.fixture(scope="session")
def personas(base_url):
    return provision(base_url)


@pytest.fixture
def client_for(base_url, personas):
    """A logged-in httpx client for one persona key."""
    import httpx

    def _make(key: str) -> httpx.Client:
        token = token_for(base_url, personas[key])
        return httpx.Client(
            base_url=base_url,
            headers={"Authorization": f"Bearer {token}"},
            timeout=30.0,
        )

    return _make
```

- [ ] **Step 5: Write the implementation**

`qa/personas.py`:

```python
"""Identities the QA floor tests as.

Deliberately not the seeded staff: the live database has no manager at all, and
every account but the bootstrap super admin carries `must_reset_password`, so
none of them can be logged in as without first driving a reset.

`QA_OTHER` is a manager on a second site and exists only to prove `site_access`
is re-checked server-side on every request.
"""
from __future__ import annotations

from dataclasses import dataclass

import httpx

#: The bootstrap super admin. Used ONLY to create the personas below. No test
#: asserts anything while holding this token: super_admin bypasses site_access,
#: so every tenant bug is invisible from this seat.
ADMIN_HANDLE = "KUNAL"
ADMIN_PASSWORD = "admin"

#: One known password for every QA identity. These accounts exist only on a
#: throwaway database.
QA_PASSWORD = "QaFloor@2026"

PRIMARY_SITE = "QASITE"
OTHER_SITE = "QASITE2"


@dataclass(frozen=True)
class Persona:
    handle: str
    password: str
    role: str
    site: str


_WANTED = (
    ("manager", "QA_MGR", "manager", PRIMARY_SITE),
    ("supervisor", "QA_SUP", "supervisor", PRIMARY_SITE),
    ("executive", "QA_EXEC", "executive", PRIMARY_SITE),
    ("other_manager", "QA_OTHER", "manager", OTHER_SITE),
)


def _admin_token(base_url: str) -> str:
    r = httpx.post(
        f"{base_url}/auth/login",
        json={"user_id": ADMIN_HANDLE, "password": ADMIN_PASSWORD},
        timeout=30.0,
    )
    r.raise_for_status()
    return r.json()["access_token"]


def _ensure_site(client: httpx.Client, code: str, name: str) -> None:
    r = client.post("/admin/sites", json={"code": code, "name": name})
    if r.status_code not in (200, 201, 409):
        r.raise_for_status()


def _ensure_user(client: httpx.Client, p: Persona) -> None:
    r = client.post(
        "/admin/users",
        json={
            "name": p.handle.replace("_", " ").title(),
            "user_id": p.handle,
            "role": p.role,
            "password": p.password,
            "sites": [p.site],
            "must_reset_password": False,
        },
    )
    if r.status_code not in (200, 201, 409):
        r.raise_for_status()


def provision(base_url: str) -> dict[str, Persona]:
    """Create the QA sites and identities. Idempotent."""
    token = _admin_token(base_url)
    with httpx.Client(
        base_url=base_url,
        headers={"Authorization": f"Bearer {token}"},
        timeout=30.0,
    ) as client:
        _ensure_site(client, PRIMARY_SITE, "QA Floor Site")
        _ensure_site(client, OTHER_SITE, "QA Tenant Probe Site")

        people: dict[str, Persona] = {}
        for key, handle, role, site in _WANTED:
            p = Persona(handle=handle, password=QA_PASSWORD, role=role, site=site)
            _ensure_user(client, p)
            people[key] = p
        return people


def token_for(base_url: str, p: Persona) -> str:
    r = httpx.post(
        f"{base_url}/auth/login",
        json={"user_id": p.handle, "password": p.password},
        timeout=30.0,
    )
    r.raise_for_status()
    return r.json()["access_token"]
```

- [ ] **Step 6: Run the tests**

```bash
cd /Users/kunalsaxena/transvolt-enm && backend/.venv/bin/python -m pytest qa/api/test_personas.py -v
```

Expected: PASS, with the API running on :8123.

If `/admin/sites` or `/admin/users` reject the payload, read
`backend/README.md` for the correct request shape and fix `personas.py`. Do not
read `backend/app/api/admin.py` — the floor is a client, and a client has only
the published contract.

- [ ] **Step 7: Commit**

```bash
git add qa/
git commit -m "Give the QA floor its own identities

The live database has no manager — the site-level role that owns master
data — and every account but the bootstrap super admin must reset its
password before it can log in. Neither is something a test suite should
work around; it creates what it needs.

QA_OTHER is a manager on a second site and exists only to prove
site_access is re-checked on every request."
```

---

### Task 3: The register/role permission matrix

Five registers by four roles is twenty combinations, plus a cross-site refusal
for each. A human spot-checks three. This is the clearest place the suite beats
a person, so it comes before any second UI journey.

**Files:**
- Create: `qa/api/test_permissions.py`

**Interfaces:**
- Consumes: `client_for` and `personas` fixtures from Task 2.
- Produces: nothing later tasks import.

- [ ] **Step 1: Write the failing test**

`qa/api/test_permissions.py`:

```python
"""Who may write to which register, and who may reach another site's data.

Expectations come from CLAUDE.md's role ladder (admin > manager > supervisor >
executive) and its claim that the server re-checks site_access on every
request. They do not come from reading the API's own permission code.
"""
import pytest

REGISTERS = [
    "work_done",
    "coolant",
    "driver_complaint",
    "breakdown",
    "pm_schedule",
]

#: An executive reads; it does not file work. Manager and supervisor are the
#: two seats that actually keep the registers.
MAY_WRITE = {"manager": True, "supervisor": True, "executive": False}


def _minimal_entry(register: str, site: str, bus_no: str) -> dict:
    """The smallest body each register accepts, per design/HANDOFF.md section 4."""
    base = {"register": register, "site": site, "date": "2026-08-19"}
    required = {
        "work_done": {"bus_no": bus_no, "reported_defects": "QA probe"},
        "coolant": {"bus_no": bus_no},
        "driver_complaint": {"bus_no": bus_no, "complaint": "QA probe"},
        "breakdown": {"bus_no": bus_no, "complaint": "QA probe"},
        "pm_schedule": {"bus_no": bus_no, "defects_noticed": "QA probe"},
    }[register]
    return {**base, "data": required}


@pytest.mark.parametrize("register", REGISTERS)
@pytest.mark.parametrize("role", sorted(MAY_WRITE))
def test_write_permission_matches_the_role_ladder(
    client_for, personas, register, role, qa_bus
):
    body = _minimal_entry(register, personas[role].site, qa_bus)
    with client_for(role) as c:
        r = c.post("/entries", json=body)

    if MAY_WRITE[role]:
        assert r.status_code == 201, f"{role} should file {register}: {r.text}"
    else:
        assert r.status_code == 403, (
            f"{role} must not file {register}, got {r.status_code}"
        )


@pytest.mark.parametrize("register", REGISTERS)
def test_a_manager_cannot_reach_another_site(client_for, personas, register):
    """The tenant boundary. QA_OTHER manages a different site entirely."""
    victim_site = personas["manager"].site
    with client_for("other_manager") as c:
        r = c.get("/entries", params={"site": victim_site, "register": register})
    assert r.status_code == 403, (
        f"a manager of {personas['other_manager'].site} read {victim_site}'s "
        f"{register} and got {r.status_code}"
    )
```

- [ ] **Step 2: Add the `qa_bus` fixture**

The matrix needs a vehicle on the QA site. Append to `qa/conftest.py`:

```python
@pytest.fixture(scope="session")
def qa_bus(base_url, personas):
    """One vehicle on the QA site, created by its manager. Idempotent."""
    import httpx

    from qa.personas import token_for

    reg = "MH00QA0001"
    token = token_for(base_url, personas["manager"])
    with httpx.Client(
        base_url=base_url,
        headers={"Authorization": f"Bearer {token}"},
        timeout=30.0,
    ) as c:
        r = c.post(
            "/vehicles",
            json={"registration_no": reg, "site": personas["manager"].site},
        )
        if r.status_code not in (200, 201, 409):
            r.raise_for_status()
    return reg
```

- [ ] **Step 3: Run the matrix**

```bash
cd /Users/kunalsaxena/transvolt-enm && backend/.venv/bin/python -m pytest qa/api/test_permissions.py -v
```

Expected: 15 write cases and 5 tenant cases collected, 20 total.

**Any failure here is a finding, not a broken test.** Record it under
`qa/findings/` using Task 5's format and leave the test red. Do not soften an
assertion to make it pass — that is the exact developer reflex this suite exists
to avoid.

- [ ] **Step 4: Commit**

```bash
git add qa/api/test_permissions.py qa/conftest.py
git commit -m "Check every register against every role

Five registers by four roles is twenty combinations plus a cross-site
refusal each. A person spot-checks three and calls it covered.

The cross-site case is the one that matters most for a multi-depot
rollout: QA_OTHER manages a different site and must be refused."
```

---

### Task 4: The first real UI journey — sign in and reach the depot

Task 1 proved the toolchain. This proves a user can get through the front door,
which every later journey starts with.

**Files:**
- Create: `app/integration_test/login_journey_test.dart`
- Create: `app/integration_test/support/journey.dart`

**Interfaces:**
- Consumes: the `flutter drive` invocation proven in Task 1.
- Produces: `signIn(WidgetTester, {required String userId, required String password, required String depot})`
  in `support/journey.dart`, which every later UI journey calls first.

- [ ] **Step 1: Write the shared sign-in helper**

`app/integration_test/support/journey.dart`. HANDOFF section 1 specifies the
User ID field, the Password field, a black "Sign in" button, then a depot select
stage with a "Continue to {depot}" CTA.

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Settles animation without pumpAndSettle, which never returns while the
/// login chevrons loop.
Future<void> settle(WidgetTester tester, {int seconds = 3}) async {
  for (var i = 0; i < seconds; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
}

/// Signs in with a User ID and picks a depot, per design/HANDOFF.md section 1.
Future<void> signIn(
  WidgetTester tester, {
  required String userId,
  required String password,
  required String depot,
}) async {
  await settle(tester);

  final fields = find.byType(EditableText);
  expect(
    fields,
    findsNWidgets(2),
    reason: 'HANDOFF section 1 specifies a User ID field and a Password field',
  );

  await tester.enterText(fields.at(0), userId);
  await tester.enterText(fields.at(1), password);
  await settle(tester, seconds: 1);

  await tester.tap(find.text('Sign in'));
  await settle(tester);

  // Depot select stage: a grid of depot buttons, then a green CTA.
  await tester.tap(find.text(depot));
  await settle(tester, seconds: 1);
  await tester.tap(find.text('Continue to $depot'));
  await settle(tester);
}
```

- [ ] **Step 2: Write the failing journey**

`app/integration_test/login_journey_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:transvolt_em/main.dart' as app;

import 'support/journey.dart';

/// Must match qa/personas.py.
const String kUser = String.fromEnvironment('QA_USER', defaultValue: 'QA_MGR');
const String kPassword =
    String.fromEnvironment('QA_PASSWORD', defaultValue: 'QaFloor@2026');
const String kDepot = String.fromEnvironment('QA_SITE', defaultValue: 'QASITE');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a manager signs in and lands on their depot', (tester) async {
    app.main();
    await signIn(
      tester,
      userId: kUser,
      password: kPassword,
      depot: kDepot,
    );

    // design/HANDOFF.md section 2: the shell header carries the E&M mark and a
    // depot selector. Section 3: Home shows the five register cards.
    expect(find.text('E&M'), findsOneWidget);
    expect(find.textContaining(kDepot), findsWidgets);

    // The five paper registers, named as HANDOFF section 4 names them.
    for (final name in <String>[
      'Daily Work Done',
      'Coolant Topping',
      'Driver Complaints',
      'Breakdown Report',
      'PM Schedule Attention',
    ]) {
      expect(find.textContaining(name), findsWidgets, reason: '$name card');
    }
  });
}
```

- [ ] **Step 3: Ensure the personas exist before driving the UI**

```bash
cd /Users/kunalsaxena/transvolt-enm && backend/.venv/bin/python -m pytest qa/api/test_personas.py -q
```

Expected: PASS. The UI journey logs in as `QA_MGR`, which must already exist.

- [ ] **Step 4: Run the journey**

```bash
cd app && flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/login_journey_test.dart \
  -d chrome \
  --dart-define=API_BASE_URL=http://localhost:8123/api/v1
```

Expected: PASS, or a finder failure naming exactly which promised element is
missing.

- [ ] **Step 5: Treat any mismatch as a finding**

If a register card name differs from HANDOFF's wording, the app is wrong — those
are the names on the paper registers. File it under `qa/findings/` (Task 5) and
leave the assertion as HANDOFF has it.

- [ ] **Step 6: Commit**

```bash
git add app/integration_test
git commit -m "Walk a manager through the front door

Every journey starts here, so it gets its own helper rather than being
copied. The assertions name the five paper registers as HANDOFF names
them: if the app disagrees, the app is wrong."
```

---

### Task 5: Findings format, Makefile targets, and CI

The floor only protects anything if it runs. Everything here is a Makefile
target so a laptop and CI issue the same commands, matching the convention the
root `Makefile` already states.

**Files:**
- Create: `qa/findings/README.md`
- Create: `qa/findings/TEMPLATE.md`
- Create: `qa/journeys.md`
- Modify: `Makefile`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: the invocations proven in Tasks 1–4.
- Produces: `make qa-smoke`, `make qa-api`, `make qa-ui`.

- [ ] **Step 1: Write the findings template**

`qa/findings/TEMPLATE.md`:

```markdown
SEVERITY: high | medium | low
PERSONA:  <role> @ <site>
ORACLE:   <file:line the promise comes from>
REPRO:
  1.
  2.
EXPECTED: what the depot was promised
ACTUAL:   what the app did
TEST:     <path::test_name>  (added, currently FAILING)
```

`qa/findings/README.md`:

```markdown
# Findings

One file per bug, named `YYYY-MM-DD-NNNN.md`, from `TEMPLATE.md`.

Every finding carries a failing test in the floor. That is what stops the same
bug being found twice, and it is why the hunter is worth its tokens: its output
is not a report, it is a permanent raising of the floor.

A finding is never closed by weakening its test. It is closed by the app doing
what `design/HANDOFF.md` says.
```

- [ ] **Step 1b: Write the journey catalogue**

`qa/journeys.md`. This is the checklist the floor is measured against, written
from HANDOFF rather than from the app, so a gap in coverage is visible as an
unticked line rather than as an absence nobody notices.

```markdown
# Journey catalogue

Each line names a thing a depot user does, and where the promise comes from.
A journey with no test is a hole, and the hole should be visible.

| # | Journey | Oracle | Test |
| --- | --- | --- | --- |
| 1 | Sign in, pick a depot, land on Home | HANDOFF section 1-3 | `login_journey_test.dart` |
| 2 | Switch site; every list re-scopes | CLAUDE.md, "every list is site-scoped" | — |
| 3 | File one entry per register | HANDOFF section 4 | — |
| 4 | Search and filter a register by period | HANDOFF section 5 | — |
| 5 | Open a breakdown, resolve it, fail to resolve twice | HANDOFF section 6 | — |
| 6 | Export CSV; columns match the paper register | HANDOFF section 5 | — |
| P | Register x role write permission | CLAUDE.md role ladder | `qa/api/test_permissions.py` |
| T | A manager cannot reach another site | CLAUDE.md, "server re-checks site_access" | `qa/api/test_permissions.py` |

A dash in Test means the journey is not covered yet. Fill it in; never delete
the row.
```

- [ ] **Step 2: Add the Makefile targets**

Append to `Makefile`, after the existing `contract` target:

```makefile
# --- QA floor ----------------------------------------------------------------

.PHONY: qa-api
qa-api: ## API journeys against a running API on $(API_PORT)
	@QA_API_BASE=$(API_BASE) $(PY) -m pytest qa/api -q

.PHONY: qa-ui
qa-ui: ## UI journeys in real Chrome against a running API
	@cd $(APP) && $(FLUTTER) drive \
		--driver=test_driver/integration_test.dart \
		--target=integration_test/login_journey_test.dart \
		-d chrome --dart-define=API_BASE_URL=$(API_BASE)

.PHONY: qa-smoke
qa-smoke: qa-api qa-ui ## The floor. Both halves, against the real stack.
```

- [ ] **Step 3: Verify the targets**

```bash
cd /Users/kunalsaxena/transvolt-enm && make qa-api && make qa-ui
```

Expected: both green, with the API up on :8123.

- [ ] **Step 4: Add the CI job**

In `.github/workflows/ci.yml`, add a job alongside the existing ones. It reuses
the `postgres:16` service container already declared for the backend job, so
local Docker and CI agree on the major version:

```yaml
  qa-floor:
    name: QA floor
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_USER: enm
          POSTGRES_PASSWORD: enm
          POSTGRES_DB: enm
        options: >-
          --health-cmd pg_isready --health-interval 5s
          --health-timeout 3s --health-retries 10
        ports:
          - 5432:5432
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: ${{ env.PYTHON_VERSION }}
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: ${{ env.FLUTTER_VERSION }}
          channel: stable
      # flutter drive -d chrome needs a browser and a matching driver. The
      # majors must agree or session creation fails.
      - uses: browser-actions/setup-chrome@v1
        with:
          install-chromedriver: true
      - name: Install backend and QA dependencies
        run: |
          python -m venv backend/.venv
          backend/.venv/bin/pip install -r backend/requirements.txt
          backend/.venv/bin/pip install -r qa/requirements.txt
      - name: Migrate and seed
        env:
          DATABASE_URL: postgresql+asyncpg://enm:enm@localhost:5432/enm
        run: |
          cd backend && .venv/bin/python -m alembic upgrade head
          .venv/bin/python -m scripts.seed
      - name: Start the API
        env:
          DATABASE_URL: postgresql+asyncpg://enm:enm@localhost:5432/enm
        run: |
          cd backend && .venv/bin/uvicorn app.main:app --port 8123 &
          for i in $(seq 1 30); do
            curl -sf http://localhost:8123/api/v1/health && break || sleep 2
          done
      - name: QA floor
        run: make qa-smoke
```

- [ ] **Step 5: Commit**

```bash
git add qa/findings qa/journeys.md Makefile .github/workflows/ci.yml
git commit -m "Run the QA floor the same way on a laptop and on CI

Everything is a Makefile target, which is the rule the root Makefile
already sets: what CI does and what a laptop does are the same commands.

CI installs Chrome and a matching chromedriver explicitly. A mismatched
driver fails with an error that reads like a Flutter fault and is not."
```

---

### Task 6: The hunter agent definition

The ceiling. It reports; it never edits the app.

**Files:**
- Create: `.claude/agents/qa-hunter.md`

**Interfaces:**
- Consumes: the findings format from Task 5, the personas from Task 2.
- Produces: an agent invocable as `subagent_type: "qa-hunter"`.

- [ ] **Step 1: Write the agent definition**

`.claude/agents/qa-hunter.md`:

```markdown
---
name: qa-hunter
description: Explores the running Transvolt E&M app as a user and hunts for ways it fails the depot. Use on demand or nightly, never as a merge gate.
tools: Bash, Read, Grep, Glob, Write, mcp__claude-in-chrome__tabs_context_mcp, mcp__claude-in-chrome__tabs_create_mcp, mcp__claude-in-chrome__tabs_close_mcp, mcp__claude-in-chrome__navigate, mcp__claude-in-chrome__computer, mcp__claude-in-chrome__read_page, mcp__claude-in-chrome__javascript_tool
---

You are a QA engineer at a bus depot, not a developer on this project. Your job
is to disprove that this app is ready for the depot floor.

## Your oracle

What the app SHOULD do comes from, and only from:

- `design/HANDOFF.md` — the screens, the register field lists, the roles
- `data/MBMT/**` — the depot's own spreadsheets
- `backend/README.md` — the wire contract
- `CLAUDE.md` — the vocabulary and the role ladder

**You must not read `app/lib/**`, `backend/app/**`, or any existing test.**
Reading the implementation is how a tester starts asserting what the code does
instead of what the depot was promised. If you catch yourself wanting to look,
that is the moment to write a finding about the ambiguity instead.

## How you work

- Sign in as `QA_MGR`, `QA_SUP` or `QA_EXEC` (password in `qa/personas.py`).
  **Never as `KUNAL`.** super_admin bypasses `site_access`, so every tenant bug
  is invisible from that seat.
- Drive the real UI at the running dev server in Chrome. Look at what is
  painted: clipped text, a Save button below the fold, a control that does
  nothing, a number formatted wrong, a form that loses what was typed.
- Use `curl` against the API when you need to know whether the UI or the server
  is at fault.
- Ambiguity resolves to "broken, needs a human ruling". Never "probably fine".

## What you produce

For every bug, both of these or it does not count:

1. A finding at `qa/findings/YYYY-MM-DD-NNNN.md` using
   `qa/findings/TEMPLATE.md`.
2. A **failing** deterministic test added to `qa/api/` or
   `app/integration_test/`, so the floor rises and this bug can never be found
   twice.

## What you never do

- Never edit `app/` or `backend/`. You report; a human decides the fix. An
  agent that both finds and fixes will eventually make the test match the bug.
- Never weaken an assertion to make a suite green.
- Never report a finding you have not reproduced.
- Never file a duplicate: read `qa/findings/` first.

## Where to look first

The depot's reality, not the happy path:

- A bus number with a space or lower case in it, which CLAUDE.md says is
  normalised.
- A date at a month boundary; the period chips sort dates lexically.
- An executive attempting to write.
- A manager of one site reaching for another site's data.
- A register form against HANDOFF section 4's exact field list — a missing
  field is a missing column on a permanent maintenance record.
- A very long defect description; a form with every field at its maximum.
```

- [ ] **Step 2: Verify the agent is registered**

```bash
cd /Users/kunalsaxena/transvolt-enm && ls .claude/agents/
```

Expected: `qa-hunter.md` present. It becomes available as
`subagent_type: "qa-hunter"` in the next session.

- [ ] **Step 3: Commit**

```bash
git add .claude/agents/qa-hunter.md
git commit -m "Add the hunter that tests as a user, not a developer

It reads HANDOFF and the depot's spreadsheets and is denied app/lib and
backend/app, so it asserts what the depot was promised rather than what
the code happens to do. It never signs in as super_admin, which bypasses
site_access and hides every tenant bug.

Its deliverable for every bug is a failing test in the floor. That is
what makes this a ratchet instead of a report."
```

---

## Not in this plan

- **Journeys 2–6** from the spec's first cut (site switch, one entry per
  register, register search and filter, breakdown open/resolve, CSV export).
  They repeat Task 4's pattern and should be written only once that pattern is
  proven, in a follow-up plan.
- **The hunter's realistic-data environment.** The spec calls for it to run
  against a restore of the production-shaped dump. Wire that after the floor is
  green.
- **Password reset.** Every seeded account carries `must_reset_password`. Task 2
  sidesteps it by creating accounts with the flag off. Testing the reset flow
  itself needs the flow read first, and may deserve its own design.
