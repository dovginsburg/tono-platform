# rate_limit.py
# Per-IP sliding-window rate limiter + per-key (e.g. email) lockout.
#
# Two primitives:
#   check_ip_rate(scope, ip, limit, window=60)  → bool
#       Generic sliding window. Returns False if over limit.
#       `scope` lets us have separate buckets per endpoint ("auth", "analyze",
#       "register", etc) so a flood on /v1/auth doesn't eat the budget for
#       /v1/register.
#
#   check_keyed_rate(scope, key, limit, window=300)  → bool
#       For brute-force protection (e.g. OTP verification). `key` is
#       usually the email being verified; `scope` distinguishes
#       "verify_otp" vs "request_link" vs "coupon_redeem" so one failed
#       login doesn't lock the user out of all auth flows.
#       Returns False if over limit. Lockout duration = window seconds
#       after the FIRST failure.
#
# Both are in-memory (thread-safe). For multi-instance deployments, swap
# for Redis INCR + EXPIRE. For a single-VPS production deployment this is
# fine — when the process restarts, all buckets reset, which is the safe
# direction (a fresh start doesn't carry an attacker over the limit).
#
# Configuration is via env vars (with sensible defaults):
#   TONO_RATE_LIMIT_REGISTER_PER_MIN       (default 30)
#   TONO_RATE_LIMIT_AUTH_PER_MIN           (default 10) — request-link, verify-otp, coupon
#   TONO_RATE_LIMIT_ANALYZE_PUBLIC_PER_MIN (default 30) — /v1/analyze (the LLM passthrough)
#   TONO_RATE_LIMIT_OTP_LOCKOUT            (default 10) — max verify-otp attempts per email per 5 min
#   TONO_RATE_LIMIT_COUPON_PER_MIN         (default 5)  — coupon brute-force
#   TONO_RATE_LIMIT_DEFAULT_PER_MIN        (default 60) — catch-all for misc endpoints
#
# 429 responses use the same shape the rest of the API uses for rate-limit
# errors so the iOS client doesn't need a new error type.

from __future__ import annotations

import collections
import os
import threading
import time
from typing import Optional


class _SlidingWindow:
    """One named bucket's sliding window."""
    __slots__ = ("hits",)

    def __init__(self) -> None:
        self.hits: collections.deque[float] = collections.deque()


# Buckets keyed by (scope, identifier). Scope lets us have isolated budgets
# per endpoint family so a single attacker hammering /v1/auth/request-link
# can't starve the IP's budget for /v1/me or /v1/features.
_ip_buckets: dict[tuple[str, str], _SlidingWindow] = {}
_keyed_buckets: dict[tuple[str, str], _SlidingWindow] = {}

_ip_lock = threading.Lock()
_keyed_lock = threading.Lock()

# Eviction ceiling: if a bucket hasn't been touched in 10 minutes, drop it
# so the dict doesn't grow unbounded under sustained traffic.
_EVICTION_TTL_SEC = 600
_last_eviction: float = 0.0


def _evict_if_due(now: float) -> None:
    global _last_eviction
    if now - _last_eviction < _EVICTION_TTL_SEC:
        return
    _last_eviction = now
    cutoff = now - _EVICTION_TTL_SEC
    # IP buckets
    stale = [k for k, w in _ip_buckets.items() if not w.hits or w.hits[-1] < cutoff]
    for k in stale:
        _ip_buckets.pop(k, None)
    # Keyed buckets
    stale = [k for k, w in _keyed_buckets.items() if not w.hits or w.hits[-1] < cutoff]
    for k in stale:
        _keyed_buckets.pop(k, None)


def _record(buckets: dict, lock: threading.Lock, scope: str, ident: str, window: float) -> tuple[bool, int]:
    """Returns (allowed, current_count_in_window)."""
    now = time.time()
    with lock:
        _evict_if_due(now)
        key = (scope, ident)
        w = buckets.get(key)
        if w is None:
            w = _SlidingWindow()
            buckets[key] = w
        # Drop entries outside the window
        while w.hits and now - w.hits[0] > window:
            w.hits.popleft()
        w.hits.append(now)
        return True, len(w.hits)


def _peek(buckets: dict, lock: threading.Lock, scope: str, ident: str, window: float) -> int:
    """How many hits in the current window, without recording a new one."""
    now = time.time()
    with lock:
        _evict_if_due(now)
        w = buckets.get((scope, ident))
        if w is None:
            return 0
        # Drop expired in-place so the peek is accurate
        while w.hits and now - w.hits[0] > window:
            w.hits.popleft()
        return len(w.hits)


def check_ip_rate(scope: str, ip: str, limit: int, window: float = 60.0) -> tuple[bool, int]:
    """Per-IP rate limit. Returns (allowed, current_count_in_window)."""
    allowed, count = _record(_ip_buckets, _ip_lock, scope, ip, window)
    return (allowed and count <= limit), count


def check_keyed_rate(scope: str, key: str, limit: int, window: float = 300.0) -> tuple[bool, int]:
    """Per-key rate limit (e.g. per-email for OTP brute-force).

    Returns (allowed, current_count_in_window). Window defaults to 5 min
    so an attacker can't infinitely retry after a brief lockout.
    """
    allowed, count = _record(_keyed_buckets, _keyed_lock, scope, key, window)
    return (allowed and count <= limit), count


def keyed_attempts_remaining(scope: str, key: str, limit: int, window: float = 300.0) -> int:
    """How many more attempts the caller has before lockout. For the UI
    (e.g. iOS OTP screen showing "3 attempts left").
    """
    current = _peek(_keyed_buckets, _keyed_lock, scope, key, window)
    return max(0, limit - current)


def reset_keyed_rate(scope: str, key: str) -> None:
    """Wipe a key's bucket — call after a successful auth (so the next
    legitimate attempt isn't blocked by a stale lockout from minutes ago).
    """
    with _keyed_lock:
        _keyed_buckets.pop((scope, key), None)


# ---------------------------------------------------------------
# Scoped limit constants (read once at import)
# ---------------------------------------------------------------

# Per-endpoint-family IP budgets. Each tuple is (scope_name, per_minute).
RATE_SCOPES = {
    "register":      int(os.environ.get("TONO_RATE_LIMIT_REGISTER_PER_MIN", "30")),
    "auth":          int(os.environ.get("TONO_RATE_LIMIT_AUTH_PER_MIN", "10")),
    "analyze_pub":   int(os.environ.get("TONO_RATE_LIMIT_ANALYZE_PUBLIC_PER_MIN", "30")),
    "coupon":        int(os.environ.get("TONO_RATE_LIMIT_COUPON_PER_MIN", "5")),
    "default":       int(os.environ.get("TONO_RATE_LIMIT_DEFAULT_PER_MIN", "60")),
}

# OTP brute-force lockout — per email + per IP, 5 min window.
OTP_LOCKOUT_LIMIT = int(os.environ.get("TONO_RATE_LIMIT_OTP_LOCKOUT", "10"))
OTP_LOCKOUT_WINDOW = int(os.environ.get("TONO_RATE_LIMIT_OTP_WINDOW_SEC", "300"))