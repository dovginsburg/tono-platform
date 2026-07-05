"""Async Redis client singleton for ephemeral state that must survive the
move to multiple worker processes: a module-level Python dict (what
WebAuthn challenges and the Slack/IP rate-limit windows used to be) is only
correct with exactly one process. This migration is explicitly about not
being pinned to that, so that state lives in Redis instead.
"""

from __future__ import annotations

import os
import threading
from typing import Optional

import redis.asyncio as redis

_redis: Optional["redis.Redis"] = None
_redis_lock = threading.Lock()


def get_redis() -> "redis.Redis":
    global _redis
    if _redis is None:
        with _redis_lock:
            if _redis is None:
                url = os.environ.get("REDIS_URL", "redis://localhost:6379/0")
                _redis = redis.from_url(url)
    return _redis


async def close_redis() -> None:
    global _redis
    if _redis is not None:
        await _redis.aclose()
        _redis = None


def reset_redis() -> None:
    """Drop the singleton without closing it. Same reasoning as
    `Backend.store.reset_store()`: each test's TestClient spins up its own
    event loop, and a redis-py connection pool created on one loop can't be
    reused on another, so tests force a fresh client per test."""
    global _redis
    _redis = None
