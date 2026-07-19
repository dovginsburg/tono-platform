"""Total, non-accepting validators for the tuple-backed models.

Contract for every public validator:

* returns a real ``bool`` -- ``True`` only for a genuine, well-formed instance;
* returns ``False`` (never raises) for anything else: wrong type, empty
  ``tuple.__new__(Model, ())``, short tuples, or forged same-arity tuples with
  hostile contents;
* never rehashes, iterates, compares, or calls a caller-provided value -- a
  ``frozenset`` field is checked by *type identity only*, so hostile element
  ``__hash__`` / ``__eq__`` can never fire.
"""

from __future__ import annotations

from typing import Any

from . import models as _m
from ._safety import (
    guard,
    is_exact_bool,
    is_exact_frozenset,
    is_exact_int,
    is_exact_str,
    is_finite_real,
    read_field,
)

ROLLOUT_PERMILLE_MAX = 1000
NAME_MAX_LEN = 256
CHANNEL_MAX_LEN = 64


def _valid_release_config(x: Any) -> bool:
    if type(x) is not _m.ReleaseConfig:
        return False
    if tuple.__len__(x) != _m.RC_LEN:
        return False

    name = read_field(x, _m.RC_NAME)
    if not is_exact_str(name) or len(name) > NAME_MAX_LEN:
        return False
    if not is_exact_bool(read_field(x, _m.RC_ENABLED)):
        return False
    if not is_exact_bool(read_field(x, _m.RC_KILL_SWITCH)):
        return False

    min_build = read_field(x, _m.RC_MIN_BUILD)
    if not is_exact_int(min_build) or min_build < 0:
        return False

    schema_version = read_field(x, _m.RC_SCHEMA_VERSION)
    if not is_exact_int(schema_version) or schema_version < 0:
        return False

    ttl = read_field(x, _m.RC_TTL_SECONDS)
    # Strict finite TTL: a real, finite, strictly-positive scalar.
    if not is_finite_real(ttl) or not (ttl > 0):
        return False

    rollout = read_field(x, _m.RC_ROLLOUT_PERMILLE)
    if not is_exact_int(rollout) or rollout < 0 or rollout > ROLLOUT_PERMILLE_MAX:
        return False

    # Type identity only -- never probe the members.
    if not is_exact_frozenset(read_field(x, _m.RC_CAPABILITIES)):
        return False

    return True


def _valid_evaluation_context(x: Any) -> bool:
    if type(x) is not _m.EvaluationContext:
        return False
    if tuple.__len__(x) != _m.EC_LEN:
        return False

    build_number = read_field(x, _m.EC_BUILD_NUMBER)
    if not is_exact_int(build_number) or build_number < 0:
        return False

    schema_version = read_field(x, _m.EC_SCHEMA_VERSION)
    if not is_exact_int(schema_version) or schema_version < 0:
        return False

    if not is_exact_bool(read_field(x, _m.EC_READY)):
        return False

    if not is_finite_real(read_field(x, _m.EC_NOW)):
        return False
    if not is_finite_real(read_field(x, _m.EC_ISSUED_AT)):
        return False

    channel = read_field(x, _m.EC_CHANNEL)
    if not is_exact_str(channel) or len(channel) > CHANNEL_MAX_LEN:
        return False

    return True


def _valid_audit_receipt(x: Any) -> bool:
    if type(x) is not _m.AuditReceipt:
        return False
    if tuple.__len__(x) != _m.AR_LEN:
        return False

    if not is_exact_bool(read_field(x, _m.AR_RELEASED)):
        return False

    reason = read_field(x, _m.AR_REASON_CODE)
    if not is_exact_int(reason):
        return False

    build_number = read_field(x, _m.AR_BUILD_NUMBER)
    if not is_exact_int(build_number) or build_number < 0:
        return False

    schema_version = read_field(x, _m.AR_SCHEMA_VERSION)
    if not is_exact_int(schema_version) or schema_version < 0:
        return False

    if not is_finite_real(read_field(x, _m.AR_EVALUATED_AT)):
        return False

    return True


# Public wrappers: wrapped in ``guard`` so even a pathological ordinary
# exception can never escape as anything other than ``False``.


def is_valid_release_config(x: Any) -> bool:
    return guard(lambda: _valid_release_config(x), default=False)


def is_valid_evaluation_context(x: Any) -> bool:
    return guard(lambda: _valid_evaluation_context(x), default=False)


def is_valid_audit_receipt(x: Any) -> bool:
    return guard(lambda: _valid_audit_receipt(x), default=False)
