"""Stable integer reason codes.

Reason codes are integers, not strings, so telemetry stays finite-scalar-only
and never echoes a caller-provided label.  A read-only name lookup is offered
for humans, but it maps *our* constant codes to *our* constant strings and never
hashes a caller value.
"""

from __future__ import annotations

from types import MappingProxyType

REASON_RELEASED = 1
REASON_INVALID_CONFIG = 2
REASON_INVALID_CONTEXT = 3
REASON_KILLED = 4
REASON_NOT_READY = 5
REASON_BUILD_TOO_LOW = 6
REASON_SCHEMA_MISMATCH = 7
REASON_EXPIRED = 8
REASON_DISABLED = 9
REASON_ROLLOUT_ZERO = 10
REASON_ERROR = 11

_NAMES = MappingProxyType(
    {
        REASON_RELEASED: "released",
        REASON_INVALID_CONFIG: "invalid_config",
        REASON_INVALID_CONTEXT: "invalid_context",
        REASON_KILLED: "killed",
        REASON_NOT_READY: "not_ready",
        REASON_BUILD_TOO_LOW: "build_too_low",
        REASON_SCHEMA_MISMATCH: "schema_mismatch",
        REASON_EXPIRED: "expired",
        REASON_DISABLED: "disabled",
        REASON_ROLLOUT_ZERO: "rollout_zero",
        REASON_ERROR: "error",
    }
)


def reason_name(code: int) -> str:
    """Return the human label for one of *our* codes, else ``"unknown"``.

    Only ``int`` codes are looked up; a non-int caller value is never hashed
    against the internal table.
    """
    if type(code) is not int:
        return "unknown"
    return _NAMES.get(code, "unknown")
