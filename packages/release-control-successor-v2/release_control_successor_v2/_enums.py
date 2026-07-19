"""Closed enumerations for release-control decisions and receipts.

Every enumeration value is a plain built-in ``str``.  Enumeration members are
the *only* legal symbolic values at a serialize boundary; serialization always
emits ``member.value`` so the output contains built-in scalars only.  Any input
that is not exactly a member of one of these enumerations is coerced to a
documented inert default by :mod:`release_control_successor_v2._safety`.

This module performs no I/O and imports only :mod:`enum` from the standard
library.
"""
from __future__ import annotations

import enum


class Outcome(enum.Enum):
    """Whether release control permits (``ALLOW``) or withholds (``DENY``)."""

    ALLOW = "allow"
    DENY = "deny"


class CapabilityClass(enum.Enum):
    """Whether a capability is user-protected or a standard gated rollout."""

    PROTECTED = "protected"
    STANDARD = "standard"


class Reason(enum.Enum):
    """The single gate that determined a decision.

    ``UNSPECIFIED`` is the inert safe default used when a public model
    constructor is handed a hostile / malformed reason value.
    """

    UNSPECIFIED = "unspecified"
    MALFORMED_INPUT = "malformed_input"
    KILL_SWITCH = "kill_switch"
    NOT_READY = "not_ready"
    UNKNOWN_FLAG = "unknown_flag"
    NOT_ENTITLED = "not_entitled"
    BUILD_INCOMPATIBLE = "build_incompatible"
    SCHEMA_INCOMPATIBLE = "schema_incompatible"
    TTL_INVALID = "ttl_invalid"
    TTL_EXPIRED = "ttl_expired"
    COHORT_EXCLUDED = "cohort_excluded"
    ALLOWLISTED = "allowlisted"
    ROLLOUT = "rollout"
    PROTECTED_CAPABILITY = "protected_capability"


class RollbackMode(enum.Enum):
    """Finite, explicit rollback modes.

    ``NONE`` is the inert safe default; a hostile object that merely mimics the
    equality/hash of another member is rejected and coerced to ``NONE``.
    """

    NONE = "none"
    HALT = "halt"
    DRAIN = "drain"
    REVERT = "revert"
