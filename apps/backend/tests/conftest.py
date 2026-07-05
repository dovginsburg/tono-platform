"""Shared pytest fixtures.

Tests run against a real local Postgres + Redis (see apps/backend's
docker-compose.yml, or a bare local install — either works, this just
needs *something* listening on TEST_DATABASE_URL/TEST_REDIS_URL). That's a
deliberate choice consistent with this project's testing philosophy
elsewhere (e.g. the passkey suite drives a real WebAuthn ceremony rather
than mocking the crypto): a migration from SQLite to Postgres is
specifically about behavior only a real Postgres server has (row locking,
genuine concurrent connections), which a mocked or sqlite-backed test
double can't exercise.

Isolation between tests: rather than a fresh SQLite file per test (the old
approach — cheap because SQLite is just a file), every test truncates the
shared Postgres test database and flushes the shared Redis test database.
On top of that we still purge every cached `Backend.*` module before each
test (carried over from the pre-Postgres conftest): a couple of tests
(e.g. test_slack.py's rate-limit tests) reach into module internals
directly and reassign them mid-test, and without a fresh reimport every
test that behavior leaks into whatever test runs next — the app's router
was built from the *original* module object at `Backend.server` import
time, so a test-local `import Backend.slack as slack_mod` after some
other test deleted-and-reimported it would silently point at a different
module than the one actually serving requests. Purging first keeps
`Backend.store`/`Backend.redis_client`'s module-level singletons fresh
too, which is what actually matters for the event-loop-per-TestClient
problem described above (a fresh module means `_store`/`_redis` start as
`None` again, so the next `get_store()`/`get_redis()` call builds a new
engine/client bound to whatever loop is current).
"""

from __future__ import annotations

import os
import sys
from typing import Iterator

import pytest
import pytest_asyncio
from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine

TEST_DATABASE_URL = os.environ.get(
    "TEST_DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/tono_test"
)
TEST_REDIS_URL = os.environ.get("TEST_REDIS_URL", "redis://localhost:6379/15")


def _purge_backend_modules() -> None:
    for name in list(sys.modules):
        if name == "Backend" or name.startswith("Backend."):
            del sys.modules[name]


@pytest_asyncio.fixture(autouse=True)
async def _isolate_state(monkeypatch) -> Iterator[None]:
    monkeypatch.setenv("DATABASE_URL", TEST_DATABASE_URL)
    monkeypatch.setenv("REDIS_URL", TEST_REDIS_URL)
    monkeypatch.setenv("TONO_PROVIDER", "mock")
    monkeypatch.setenv("FREE_DAILY_LIMIT", "3")  # keep tests fast

    from Backend.db import metadata
    from Backend.store import normalize_database_url

    engine = create_async_engine(normalize_database_url(TEST_DATABASE_URL))
    async with engine.begin() as conn:
        await conn.run_sync(metadata.create_all)
        # Reverse creation order so FK-referenced tables (accounts) are
        # truncated after the tables that reference them (users,
        # webauthn_credentials) — CASCADE would handle this anyway, but
        # being explicit costs nothing.
        for table in reversed(metadata.sorted_tables):
            await conn.execute(text(f'TRUNCATE TABLE "{table.name}" RESTART IDENTITY CASCADE'))
    await engine.dispose()

    import redis.asyncio as redis

    r = redis.from_url(TEST_REDIS_URL)
    await r.flushdb()
    await r.aclose()

    _purge_backend_modules()

    yield


@pytest.fixture
def client():
    """Yield a FastAPI TestClient wired to the (freshly truncated) test DB."""

    from fastapi.testclient import TestClient
    from Backend.server import app

    with TestClient(app) as c:
        yield c


@pytest_asyncio.fixture
async def store():
    """A `Store` instance for tests that need to reach into the DB directly
    (bypassing the API) to set up state a webhook or admin flow would
    normally produce — e.g. marking an account Pro without driving a full
    mocked Stripe event.

    Deliberately NOT `Backend.store.get_store()`, the singleton the app
    itself uses: that one is created inside the `client` fixture's
    `TestClient` lifespan, bound to TestClient's own internal event loop.
    This fixture instead builds a second, independent `Store` bound to
    *this* test coroutine's event loop — asyncpg connections can't be
    awaited from a different loop than the one they were created on, so a
    test that's `async def` (running on pytest-asyncio's loop) needs its
    own engine rather than reusing the app's."""
    from Backend.store import Store, normalize_database_url

    s = Store(normalize_database_url(TEST_DATABASE_URL))
    yield s
    await s.close()
