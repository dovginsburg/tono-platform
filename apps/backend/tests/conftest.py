"""Shared pytest fixtures.

We point the store at a per-test temp DB and stub out the singleton so
each test gets a fresh slate. TONO_PROVIDER is forced to ``mock`` so the
suite runs without any real LLM keys.
"""

from __future__ import annotations

import os
import sys
from typing import Iterator

import pytest


def _purge_backend_modules() -> None:
    """Remove every cached backend.* (or Backend.* on case-insensitive FS)
    module so the next ``import`` rebuilds the chain with fresh module-level
    globals (especially ``backend.store._store``).

    The fragile bit: ``from .store import get_store`` in another
    module binds the *function*, but ``get_store.__globals__`` is the
    ``backend.store.__dict__`` snapshot at import time. If we don't
    purge ``backend.store``, callers keep using the old module's
    singleton and any closed store stays around forever.
    """
    for name in list(sys.modules):
        if name in ("Backend", "backend") or name.startswith(
            ("Backend.", "backend.")
        ):
            del sys.modules[name]


@pytest.fixture(autouse=True)
def _isolate_db(tmp_path, monkeypatch) -> Iterator[str]:
    db_path = str(tmp_path / "tono_test.db")
    monkeypatch.setenv("TONO_DB_PATH", db_path)
    monkeypatch.setenv("TONO_PROVIDER", "mock")

    _purge_backend_modules()

    # Reset the rate-limit buckets between tests. Without this, a test that
    # hits /v1/register 5 times leaks its IP into the next test's "auth"
    # scope, masking real failures (test pollution). The buckets are
    # module-level state in backend.rate_limit; resetting them per-test
    # gives each test a clean IP rate-limit state.
    try:
        import backend.rate_limit as _rl
        _rl._ip_buckets.clear()
        _rl._keyed_buckets.clear()
    except (ImportError, AttributeError):
        # Module not yet imported (no rate_limit.py in older branches).
        pass

    yield db_path


@pytest.fixture
def client():
    """Yield a FastAPI TestClient wired to a fresh DB."""

    from fastapi.testclient import TestClient

    # Import after env is set + modules are purged so they re-init cleanly.
    from backend.server import app

    with TestClient(app) as c:
        yield c