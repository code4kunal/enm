import os

import httpx
import pytest

from qa.personas import provision, token_for


@pytest.fixture(scope="session")
def base_url() -> str:
    """The isolated stack, not the database you work in.

    `tools/qa_stack.sh up` clones dev into a scratch database and serves it on
    its own port. The clone is what makes the floor both isolated and
    realistic: a freshly migrated database has no depot data, so every report
    test would skip, while a copy carries MBMT's real month.
    """
    url = os.environ.get("QA_API_BASE", "http://localhost:8124/api/v1")
    try:
        httpx.get(f"{url}/health", timeout=5.0)
    except httpx.HTTPError:
        pytest.skip(
            f"no QA stack at {url} — run `make qa-up` "
            "(or set QA_API_BASE to point somewhere else)"
        )
    return url


@pytest.fixture(scope="session")
def personas(base_url):
    return provision(base_url)


@pytest.fixture
def client_for(base_url, personas):
    """A logged-in client for one persona key."""

    def _make(key: str) -> httpx.Client:
        return httpx.Client(
            base_url=base_url,
            headers={"Authorization": f"Bearer {token_for(base_url, personas[key])}"},
            timeout=30.0,
        )

    return _make


@pytest.fixture(scope="session")
def qa_bus(base_url, personas):
    """One vehicle on the QA site, created by its manager. Idempotent."""
    from qa.personas import token_for as _token

    reg = "MH00QA0001"
    site = personas["manager"].site
    with httpx.Client(
        base_url=base_url,
        headers={"Authorization": f"Bearer {_token(base_url, personas['manager'])}"},
        timeout=30.0,
    ) as c:
        r = c.post(f"/sites/{site}/vehicles", json={"registration_no": reg})
        if r.status_code not in (200, 201, 409):
            r.raise_for_status()
    return reg


@pytest.fixture(scope="session")
def run_tag() -> str:
    """A short marker unique to this run.

    The scratch database survives between runs, and an import is deduplicated
    on the content of its rows — so a sheet with fixed text is already present
    the second time the suite runs, and a test asserting it was written would
    fail for a reason that has nothing to do with the app.
    """
    import secrets

    return secrets.token_hex(3).upper()
