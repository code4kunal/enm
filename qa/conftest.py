import os

import httpx
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
    """A logged-in client for one persona key."""

    def _make(key: str) -> httpx.Client:
        return httpx.Client(
            base_url=base_url,
            headers={"Authorization": f"Bearer {token_for(base_url, personas[key])}"},
            timeout=30.0,
        )

    return _make
