"""Finite, scalar-only, echo-free telemetry and config serialization.

Both entry points are total (never raise for malformed ``AuditReceipt`` /
``ReleaseConfig``) and emit only fresh dicts of finite numeric scalars with our
own constant string keys.  No caller string or object is retained or echoed; a
``frozenset`` field contributes only its ``len`` (a count), never its members --
so hostile element ``__hash__`` / ``__eq__`` is never executed.
"""

from __future__ import annotations

from typing import Any, Dict

from . import models as _m
from ._safety import guard, is_finite_real, read_field
from .validators import is_valid_audit_receipt, is_valid_release_config


def _telemetry_of(receipt: Any) -> Dict[str, float]:
    if not is_valid_audit_receipt(receipt):
        return {
            "valid": 0,
            "released": 0,
            "reason_code": 0,
            "build_number": 0,
            "schema_version": 0,
            "evaluated_at": 0.0,
        }
    released = read_field(receipt, _m.AR_RELEASED)
    reason_code = read_field(receipt, _m.AR_REASON_CODE)
    build_number = read_field(receipt, _m.AR_BUILD_NUMBER)
    schema_version = read_field(receipt, _m.AR_SCHEMA_VERSION)
    evaluated_at = read_field(receipt, _m.AR_EVALUATED_AT)
    return {
        "valid": 1,
        "released": 1 if released else 0,
        "reason_code": int(reason_code),
        "build_number": int(build_number),
        "schema_version": int(schema_version),
        "evaluated_at": float(evaluated_at) if is_finite_real(evaluated_at) else 0.0,
    }


def _serialize_config(config: Any) -> Dict[str, float]:
    if not is_valid_release_config(config):
        return {
            "valid": 0,
            "enabled": 0,
            "kill_switch": 0,
            "min_build": 0,
            "schema_version": 0,
            "ttl_seconds": 0.0,
            "rollout_permille": 0,
            "capability_count": 0,
        }
    enabled = read_field(config, _m.RC_ENABLED)
    kill_switch = read_field(config, _m.RC_KILL_SWITCH)
    min_build = read_field(config, _m.RC_MIN_BUILD)
    schema_version = read_field(config, _m.RC_SCHEMA_VERSION)
    ttl_seconds = read_field(config, _m.RC_TTL_SECONDS)
    rollout = read_field(config, _m.RC_ROLLOUT_PERMILLE)
    capabilities = read_field(config, _m.RC_CAPABILITIES)
    return {
        "valid": 1,
        "enabled": 1 if enabled else 0,
        "kill_switch": 1 if kill_switch else 0,
        "min_build": int(min_build),
        "schema_version": int(schema_version),
        "ttl_seconds": float(ttl_seconds),
        "rollout_permille": int(rollout),
        # ``len`` counts members without hashing/iterating them.
        "capability_count": int(len(capabilities)),
    }


def telemetry_of(receipt: Any) -> Dict[str, float]:
    """Total: a fresh finite-scalar-only telemetry dict, never raises."""
    return guard(lambda: _telemetry_of(receipt), default={
        "valid": 0,
        "released": 0,
        "reason_code": 0,
        "build_number": 0,
        "schema_version": 0,
        "evaluated_at": 0.0,
    })


def serialize_config(config: Any) -> Dict[str, float]:
    """Total: a fresh finite-scalar-only config fingerprint, never raises."""
    return guard(lambda: _serialize_config(config), default={
        "valid": 0,
        "enabled": 0,
        "kill_switch": 0,
        "min_build": 0,
        "schema_version": 0,
        "ttl_seconds": 0.0,
        "rollout_permille": 0,
        "capability_count": 0,
    })
