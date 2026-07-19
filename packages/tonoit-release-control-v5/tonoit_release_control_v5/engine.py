"""Total evaluation engine.

``evaluate`` never raises and never propagates ``IndexError`` from a malformed
config/context: it validates first and defaults *off* for anything it cannot
positively confirm.  Gate precedence is fixed and strict:

    invalid -> kill switch -> readiness -> build floor -> schema -> TTL ->
    enabled flag -> rollout

Unknown/unconfirmable states resolve to "not released".  No I/O, no clock, no
network -- ``now`` is supplied by the caller's context.
"""

from __future__ import annotations

from typing import Any

from . import models as _m
from . import reasons as _r
from ._safety import guard, read_field
from .validators import is_valid_evaluation_context, is_valid_release_config


def _receipt(released: bool, reason_code: int, build_number: int,
             schema_version: int, evaluated_at: float) -> _m.AuditReceipt:
    return _m.AuditReceipt(
        released=bool(released),
        reason_code=int(reason_code),
        build_number=int(build_number),
        schema_version=int(schema_version),
        evaluated_at=float(evaluated_at),
    )


def _evaluate(config: Any, context: Any) -> _m.AuditReceipt:
    # Default-off precedence starts with validity: never trust field reads on an
    # unvalidated instance.
    if not is_valid_release_config(config):
        return _receipt(False, _r.REASON_INVALID_CONFIG, 0, 0, 0.0)
    if not is_valid_evaluation_context(context):
        return _receipt(False, _r.REASON_INVALID_CONTEXT, 0, 0, 0.0)

    # All reads below are on validated instances; positional reads keep us clear
    # of descriptors regardless.
    enabled = read_field(config, _m.RC_ENABLED)
    kill_switch = read_field(config, _m.RC_KILL_SWITCH)
    min_build = read_field(config, _m.RC_MIN_BUILD)
    cfg_schema = read_field(config, _m.RC_SCHEMA_VERSION)
    ttl_seconds = read_field(config, _m.RC_TTL_SECONDS)
    rollout = read_field(config, _m.RC_ROLLOUT_PERMILLE)

    build_number = read_field(context, _m.EC_BUILD_NUMBER)
    ctx_schema = read_field(context, _m.EC_SCHEMA_VERSION)
    ready = read_field(context, _m.EC_READY)
    now = read_field(context, _m.EC_NOW)
    issued_at = read_field(context, _m.EC_ISSUED_AT)

    def deny(reason: int) -> _m.AuditReceipt:
        return _receipt(False, reason, build_number, ctx_schema, now)

    # 1. Kill switch overrides all.
    if kill_switch:
        return deny(_r.REASON_KILLED)
    # 2. Readiness.
    if not ready:
        return deny(_r.REASON_NOT_READY)
    # 3. Build floor.
    if build_number < min_build:
        return deny(_r.REASON_BUILD_TOO_LOW)
    # 4. Schema match.
    if ctx_schema != cfg_schema:
        return deny(_r.REASON_SCHEMA_MISMATCH)
    # 5. Strict finite TTL (config validated ttl > 0 and finite). A context
    # issued in the future cannot be positively confirmed, and expiry begins at
    # the exact TTL boundary rather than one instant after it.
    age = now - issued_at
    if age < 0 or age >= ttl_seconds:
        return deny(_r.REASON_EXPIRED)
    # 6. Enabled flag.
    if not enabled:
        return deny(_r.REASON_DISABLED)
    # 7. Rollout gate (deterministic, non-hashing: permille must be positive).
    if rollout <= 0:
        return deny(_r.REASON_ROLLOUT_ZERO)

    return _receipt(True, _r.REASON_RELEASED, build_number, ctx_schema, now)


def evaluate(config: Any, context: Any) -> _m.AuditReceipt:
    """Total: always returns a valid :class:`AuditReceipt`, never raises."""
    return guard(
        lambda: _evaluate(config, context),
        default=_receipt(False, _r.REASON_ERROR, 0, 0, 0.0),
    )


def is_released(config: Any, context: Any) -> bool:
    """Total boolean shortcut for ``evaluate(...).released``."""
    return guard(lambda: bool(read_field(evaluate(config, context), _m.AR_RELEASED)), default=False)
