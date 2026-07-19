"""Fail-closed normalization of untrusted inputs into genuine built-ins.

Every helper here uses identity type checks (``type(x) is T``) so it never
invokes a caller's ``__eq__``/``__hash__``/``__bool__``. Nothing here rehashes
or probes caller-supplied mapping keys. Helpers are total for ordinary
Exception-derived hostility; ``BaseException`` (process control) is never
caught and therefore propagates.
"""

from __future__ import annotations

import math

from ._reasons import (
    MAX_ALLOWLIST,
    MAX_BUILD,
    MAX_COHORT,
    MAX_EPOCH,
    MAX_FLAG_LEN,
    MAX_ID_LEN,
    MAX_SCHEMA,
)

# Sentinel distinguishing "no TTL supplied" from "TTL supplied but invalid".
_MISSING = object()


def is_genuine_str(x):
    return type(x) is str


def norm_flag(x):
    """Return a genuine, length-bounded flag name, or None."""
    if type(x) is str and 0 < len(x) <= MAX_FLAG_LEN:
        return x
    return None


def norm_id(x):
    if type(x) is str and 0 < len(x) <= MAX_ID_LEN:
        return x
    return None


def norm_bool(x, default=False):
    return x if type(x) is bool else default


def norm_cohort(x):
    # bool is excluded because type(True) is bool, not int.
    if type(x) is int and 0 <= x <= MAX_COHORT:
        return x
    return 0


def norm_build(x):
    if type(x) is int and 0 <= x <= MAX_BUILD:
        return x
    return 0


def norm_context_build(x):
    if type(x) is int and 0 <= x <= MAX_BUILD:
        return x
    return -1


def norm_schema(x):
    if type(x) is int and 0 <= x <= MAX_SCHEMA:
        return x
    return 0


def norm_context_schema(x):
    if type(x) is int and 0 <= x <= MAX_SCHEMA:
        return x
    return -1


def norm_epoch(x):
    """Return a finite in-range epoch float, or None (fail closed)."""
    if type(x) not in (int, float):
        return None
    try:
        f = float(x)
    except Exception:
        return None
    if not math.isfinite(f):
        return None
    if 0.0 <= f <= MAX_EPOCH:
        return f
    return None


def norm_expires_at(x):
    """Normalize an optional expiry.

    Returns (has_ttl, ttl_valid, expires_at_float).
    ``None`` means no TTL constraint; anything else must validate as a finite,
    strictly-positive, in-range epoch or the TTL fails closed.
    """
    if x is None:
        return (False, False, 0.0)
    if type(x) not in (int, float):
        return (True, False, 0.0)
    try:
        f = float(x)
    except Exception:
        return (True, False, 0.0)
    if not math.isfinite(f):
        return (True, False, 0.0)
    if 0.0 < f <= MAX_EPOCH:
        return (True, True, f)
    return (True, False, 0.0)


def norm_allowlist(x):
    """Build a frozenset of genuine, bounded str ids from a built-in container.

    Only exact list/tuple/set/frozenset are accepted; anything else (including
    dicts and custom iterables) fails closed to an empty allowlist. Iterating a
    built-in container never rehashes hostile mapping keys.
    """
    if type(x) not in (list, tuple, set, frozenset):
        return frozenset()
    out = set()
    try:
        for item in x:
            if len(out) >= MAX_ALLOWLIST:
                break
            if type(item) is str and 0 < len(item) <= MAX_ID_LEN:
                out.add(item)
    except Exception:
        return frozenset()
    return frozenset(out)


def is_valid_ttl(expires_at, now):
    """Public validator: True iff a finite future TTL relative to a finite now."""
    try:
        fe = norm_epoch(expires_at)
        fn = norm_epoch(now)
        if fe is None or fn is None:
            return False
        if fe <= 0.0:
            return False
        return fn < fe
    except Exception:
        return False
