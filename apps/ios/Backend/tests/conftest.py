"""Shared pytest fixtures.

We point the store at a per-test temp DB and stub out the singleton so
each test gets a fresh slate. TONO_PROVIDER is forced to ``mock`` so the
suite runs without any real LLM keys.
"""

from __future__ import annotations

import importlib
import os
import sys
import tempfile
from typing import Iterator

import pytest


def _purge_backend_modules() -> None:
    """Remove every cached Backend.* module so the next ``import``
    rebuilds the chain with fresh module-level globals (especially
    ``Backend.store._store``).

    The fragile bit: ``from .store import get_store`` in another
    module binds the *function*, but ``get_store.__globals__`` is the
    ``Backend.store.__dict__`` snapshot at import time. If we don't
    purge ``Backend.store``, callers keep using the old module's
    singleton and any closed store stays around forever."""

    for name in list(sys.modules):
        if name == "Backend" or name.startswith("Backend."):
            del sys.modules[name]


@pytest.fixture(autouse=True)
def _isolate_db(tmp_path, monkeypatch) -> Iterator[str]:
    db_path = str(tmp_path / "tono_test.db")
    monkeypatch.setenv("TONO_DB_PATH", db_path)
    monkeypatch.setenv("TONO_PROVIDER", "mock")
    monkeypatch.setenv("FREE_DAILY_LIMIT", "3")  # keep tests fast

    _purge_backend_modules()

    yield db_path


@pytest.fixture
def client():
    """Yield a FastAPI TestClient wired to a fresh DB."""

    from fastapi.testclient import TestClient

    # Import after env is set + modules are purged so they re-init cleanly.
    from Backend.server import app

    with TestClient(app) as c:
        yield c
