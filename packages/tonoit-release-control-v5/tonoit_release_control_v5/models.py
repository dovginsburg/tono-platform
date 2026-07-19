"""Tuple-backed, deeply-immutable release-control models.

Each model is a :class:`typing.NamedTuple` -- a ``tuple`` subclass with
``__slots__ == ()`` (no instance ``__dict__``) whose fields cannot be reassigned
or deleted.  Because they are plain tuples, an adversary can forge exact-type but
malformed instances via ``tuple.__new__(Model, ...)``; the validators in
:mod:`tonoit_release_control_v5.validators` exist precisely to reject those
without ever raising.

The models carry field indices as module constants so validators/engine can read
by position (``tuple.__getitem__``) rather than by attribute, side-stepping the
namedtuple property descriptors entirely.
"""

from __future__ import annotations

from typing import NamedTuple


class ReleaseConfig(NamedTuple):
    """Declarative release rule.  All fields are immutable scalars plus one
    ``frozenset`` of capability tokens."""

    name: str
    enabled: bool
    kill_switch: bool
    min_build: int
    schema_version: int
    ttl_seconds: float
    rollout_permille: int
    capabilities: frozenset


class EvaluationContext(NamedTuple):
    """Immutable snapshot of the world an evaluation happens in."""

    build_number: int
    schema_version: int
    ready: bool
    now: float
    issued_at: float
    channel: str


class AuditReceipt(NamedTuple):
    """Immutable, scalar-only record of a single evaluation.

    Contains no caller strings or objects -- only the boolean outcome, an
    internal integer reason code, and finite numeric context scalars.
    """

    released: bool
    reason_code: int
    build_number: int
    schema_version: int
    evaluated_at: float


# --- positional field indices (validators/engine read by position) ---------

RC_NAME = 0
RC_ENABLED = 1
RC_KILL_SWITCH = 2
RC_MIN_BUILD = 3
RC_SCHEMA_VERSION = 4
RC_TTL_SECONDS = 5
RC_ROLLOUT_PERMILLE = 6
RC_CAPABILITIES = 7
RC_LEN = 8

EC_BUILD_NUMBER = 0
EC_SCHEMA_VERSION = 1
EC_READY = 2
EC_NOW = 3
EC_ISSUED_AT = 4
EC_CHANNEL = 5
EC_LEN = 6

AR_RELEASED = 0
AR_REASON_CODE = 1
AR_BUILD_NUMBER = 2
AR_SCHEMA_VERSION = 3
AR_EVALUATED_AT = 4
AR_LEN = 5
