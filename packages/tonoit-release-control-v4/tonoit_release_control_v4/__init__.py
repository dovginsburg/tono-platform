"""tonoit release-control -- malformed-model successor (v4).

An inert, stdlib-only, additive package. It is imported by nothing in the
platform and wired into no runtime, build, schema, network, or storage path.
Its sole purpose is to demonstrate a hardened evaluation surface that stays
*total* (never raises) and *safe* (never falsely accepts, never grants, never
executes hostile keys/callables) when handed adversarial, exact-type-but-
malformed tuple-backed model instances.

Public API
----------
Models (deeply immutable, tuple-backed):
    ``ReleaseConfig``, ``EvaluationContext``, ``AuditReceipt``
Validators (total, non-accepting):
    ``is_valid_release_config``, ``is_valid_evaluation_context``,
    ``is_valid_audit_receipt``
Engine (total, default-off, strict gate precedence):
    ``evaluate``, ``is_released``
Telemetry (total, finite scalar-only, echo-free):
    ``telemetry_of``, ``serialize_config``
Capabilities (read-only, no grant authority):
    ``PROTECTED_CAPABILITIES``, ``protected_capabilities``
Reason codes:
    ``REASON_*``, ``reason_name``
Constants:
    ``VERSION``, ``CANONICAL_CONFIG``
"""

from __future__ import annotations

from ._safety import guard as _guard
from .capabilities import PROTECTED_CAPABILITIES, protected_capabilities
from .engine import evaluate, is_released
from .models import AuditReceipt, EvaluationContext, ReleaseConfig
from .reasons import (
    REASON_BUILD_TOO_LOW,
    REASON_DISABLED,
    REASON_ERROR,
    REASON_EXPIRED,
    REASON_INVALID_CONFIG,
    REASON_INVALID_CONTEXT,
    REASON_KILLED,
    REASON_NOT_READY,
    REASON_RELEASED,
    REASON_ROLLOUT_ZERO,
    REASON_SCHEMA_MISMATCH,
    reason_name,
)
from .telemetry import serialize_config, telemetry_of
from .validators import (
    is_valid_audit_receipt,
    is_valid_evaluation_context,
    is_valid_release_config,
)

VERSION = "4.0.0"

# A canonical, well-formed, deeply-immutable example configuration.
CANONICAL_CONFIG = ReleaseConfig(
    name="tonoit.release_control.v4.example",
    enabled=True,
    kill_switch=False,
    min_build=1,
    schema_version=1,
    ttl_seconds=86400.0,
    rollout_permille=1000,
    capabilities=frozenset({"read"}),
)

__all__ = [
    "ReleaseConfig",
    "EvaluationContext",
    "AuditReceipt",
    "is_valid_release_config",
    "is_valid_evaluation_context",
    "is_valid_audit_receipt",
    "evaluate",
    "is_released",
    "telemetry_of",
    "serialize_config",
    "PROTECTED_CAPABILITIES",
    "protected_capabilities",
    "reason_name",
    "REASON_RELEASED",
    "REASON_INVALID_CONFIG",
    "REASON_INVALID_CONTEXT",
    "REASON_KILLED",
    "REASON_NOT_READY",
    "REASON_BUILD_TOO_LOW",
    "REASON_SCHEMA_MISMATCH",
    "REASON_EXPIRED",
    "REASON_DISABLED",
    "REASON_ROLLOUT_ZERO",
    "REASON_ERROR",
    "VERSION",
    "CANONICAL_CONFIG",
]
