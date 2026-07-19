"""tonoit release-control (successor-v3) — isolated, default-off, stdlib-only.

A source-only, fail-closed release-gating library. It is NOT wired into any
runtime, schema, telemetry sink, provider, account, or build; importing it and
calling it performs no I/O and no network access. It decides only whether a
named flag is *released* for a given evaluation context. It never grants an
entitlement or authority, and it can never disable the protected safety, help,
export, delete, or recovery capabilities.

Adoption is gated: nothing here takes effect until a separate, reviewed change
explicitly constructs a config and calls :func:`evaluate` from a wired caller.
"""

from __future__ import annotations

from ._credscan import scan_credentials
from ._evaluate import (
    cohort_bucket,
    evaluate,
    is_capability_available,
    is_released,
    protected_capabilities,
    release_grants_entitlements,
)
from ._models import (
    AuditReceipt,
    Decision,
    Entitlement,
    EvaluationContext,
    ReleaseConfig,
    ReleaseRule,
)
from ._normalize import is_valid_ttl
from ._reasons import (
    GATE_ALLOWLIST,
    GATE_AUTHORITY,
    GATE_BUILD,
    GATE_COHORT,
    GATE_INPUT,
    GATE_KILL,
    GATE_NONE,
    GATE_READY,
    GATE_SCHEMA,
    GATE_TTL,
    PROTECTED_CAPABILITIES,
    REASON_BUILD_GATE,
    REASON_INVALID,
    REASON_KILLED,
    REASON_NO_AUTHORITY,
    REASON_NOT_IN_ALLOWLIST,
    REASON_NOT_IN_COHORT,
    REASON_NOT_READY,
    REASON_OK,
    REASON_SCHEMA_GATE,
    REASON_TTL_EXPIRED,
    REASON_UNKNOWN_FLAG,
    TELEMETRY_SCHEMA_VERSION,
)
from ._telemetry import audit_receipt, serialize_config, telemetry_of
from ._validate import (
    is_valid_config,
    is_valid_context,
    is_valid_entitlement,
    is_valid_flag_name,
    is_valid_rule,
)

__all__ = [
    # models
    "ReleaseRule", "ReleaseConfig", "EvaluationContext", "Entitlement",
    "Decision", "AuditReceipt",
    # evaluation / capabilities
    "evaluate", "is_released", "is_capability_available", "cohort_bucket",
    "protected_capabilities", "release_grants_entitlements",
    # validators
    "is_valid_config", "is_valid_rule", "is_valid_context",
    "is_valid_entitlement", "is_valid_flag_name", "is_valid_ttl",
    # outputs
    "telemetry_of", "serialize_config", "audit_receipt", "scan_credentials",
    # constants
    "PROTECTED_CAPABILITIES", "TELEMETRY_SCHEMA_VERSION",
    "REASON_OK", "REASON_UNKNOWN_FLAG", "REASON_KILLED", "REASON_NOT_READY",
    "REASON_NO_AUTHORITY", "REASON_BUILD_GATE", "REASON_SCHEMA_GATE",
    "REASON_TTL_EXPIRED", "REASON_NOT_IN_ALLOWLIST", "REASON_NOT_IN_COHORT",
    "REASON_INVALID",
    "GATE_NONE", "GATE_KILL", "GATE_READY", "GATE_AUTHORITY", "GATE_BUILD",
    "GATE_SCHEMA", "GATE_TTL", "GATE_ALLOWLIST", "GATE_COHORT", "GATE_INPUT",
]
