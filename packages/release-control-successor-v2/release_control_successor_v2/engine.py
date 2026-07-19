"""The release-control decision engine.

``evaluate`` is a pure function of its four typed inputs.  It performs no I/O,
no clock/environment access, and never grants entitlement: it can only permit
an already-authorized capability or withhold (fail closed).  Every unhandled or
malformed path returns a ``DENY`` decision.

Gate precedence (a decision is returned by the first failing gate):

1. capability name well-formedness
2. protected capability -> always ALLOW (never withheld by release control)
3. context type
4. kill switch (fail closed, takes precedence)
5. readiness (fail closed, takes precedence)
6. context numeric validity
7. config type + known flag
8. entitlement authorization (never grants)
9. build compatibility
10. schema compatibility
11. TTL validity
12. explicit allowlist -> ALLOW
13. cohort percentage (0 never enables; 100 enables only here, after every
    other gate and entitlement authorization)

This module performs no I/O.
"""
from __future__ import annotations

from typing import Any, Optional

from ._enums import CapabilityClass, Outcome, Reason
from .config import (
    EvaluationContext,
    ReleaseConfig,
    ReleaseRule,
    valid_capability_name,
)
from .models import Decision

# Capabilities that release control may never disable or withhold.  This set is
# hardcoded and cannot be extended by any input.
PROTECTED_CAPABILITIES = frozenset({"safety", "help", "export", "delete", "recovery"})


def _deny(
    reason: Reason,
    capability_class: CapabilityClass,
    entitlement_verified: bool = False,
    rollout_percentage: int = 0,
) -> Decision:
    return Decision(
        Outcome.DENY, reason, capability_class, entitlement_verified, rollout_percentage
    )


def _allow(
    reason: Reason,
    capability_class: CapabilityClass,
    entitlement_verified: bool,
    rollout_percentage: int,
) -> Decision:
    return Decision(
        Outcome.ALLOW,
        reason,
        capability_class,
        entitlement_verified,
        rollout_percentage,
    )


def _authorizes(entitlement: Any, capability: str) -> bool:
    """True iff ``entitlement`` is *exactly* an :class:`Entitlement` that lists
    ``capability``.  Forged / malformed / unknown authorization fails closed."""
    # Imported lazily-by-name to avoid trusting a polymorphic ``authorizes``.
    from .config import Entitlement

    if type(entitlement) is not Entitlement:
        return False
    return capability in object.__getattribute__(entitlement, "_authorized")


def _build_compatible(rule: ReleaseRule, build: int) -> bool:
    if rule._min_build is not None and build < rule._min_build:
        return False
    if rule._max_build is not None and build > rule._max_build:
        return False
    return True


def _schema_compatible(rule: ReleaseRule, schema: int) -> bool:
    if rule._min_schema is not None and schema < rule._min_schema:
        return False
    if rule._max_schema is not None and schema > rule._max_schema:
        return False
    return True


def _ttl_reason(rule: ReleaseRule, now: int) -> Optional[Reason]:
    """Return a TTL failure reason, or ``None`` if the rule is live.

    ``now``, ``issued_at`` and ``ttl_seconds`` are all pre-validated exact ints
    in range, so this arithmetic cannot overflow or compare against a
    non-finite value.
    """
    issued_at = rule._issued_at
    if now < issued_at:
        return Reason.TTL_INVALID  # future-issued
    if now >= issued_at + rule._ttl_seconds:
        return Reason.TTL_EXPIRED
    return None


def _cohort_bucket(capability: str, cohort: str) -> int:
    """Deterministic, process-independent bucket in ``[0, 100)``.

    Uses a fixed FNV-1a hash (pure arithmetic, no imports, no I/O).  The bucket
    is used only for the gating comparison and is never emitted anywhere.
    """
    data = (capability + "\x00" + cohort).encode("utf-8")
    digest = 0xCBF29CE484222325
    for byte in data:
        digest ^= byte
        digest = (digest * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return digest % 100


def evaluate(
    capability: Any,
    config: Any,
    entitlement: Any,
    context: Any,
) -> Decision:
    """Return a fail-closed :class:`Decision` for ``capability``."""
    # 1. capability must be an exact, well-formed name.
    if not valid_capability_name(capability):
        return _deny(Reason.MALFORMED_INPUT, CapabilityClass.STANDARD)

    # 2. Protected capabilities are never withheld; this precedes every gate,
    #    including the kill switch and readiness.
    if capability in PROTECTED_CAPABILITIES:
        return _allow(
            Reason.PROTECTED_CAPABILITY, CapabilityClass.PROTECTED, False, 100
        )

    cap_class = CapabilityClass.STANDARD

    # 3. context must be exactly EvaluationContext.
    if type(context) is not EvaluationContext:
        return _deny(Reason.MALFORMED_INPUT, cap_class)

    # 4. Kill switch — fail closed and take precedence.
    if context._kill_switch:
        return _deny(Reason.KILL_SWITCH, cap_class)

    # 5. Readiness — fail closed and take precedence.
    if not context._ready:
        return _deny(Reason.NOT_READY, cap_class)

    # 6. Context numeric facts must be valid.
    if not context._numbers_valid:
        return _deny(Reason.MALFORMED_INPUT, cap_class)

    # 7. Config + known flag.  The config must be *exactly* a ReleaseConfig
    #    (subclasses and duck-typed objects are rejected), and the rule is read
    #    from the validated private store directly — never via the overridable
    #    ``get`` accessor — so a polymorphic override cannot forge a rule.
    if type(config) is not ReleaseConfig:
        return _deny(Reason.UNKNOWN_FLAG, cap_class)
    rule = object.__getattribute__(config, "_rules").get(capability)
    if type(rule) is not ReleaseRule:
        return _deny(Reason.UNKNOWN_FLAG, cap_class)

    # 8. Entitlement authorization — release control never grants.
    if not _authorizes(entitlement, capability):
        return _deny(Reason.NOT_ENTITLED, cap_class)

    entitlement_verified = True
    percentage = rule._percentage

    # 9. Build compatibility.
    if not _build_compatible(rule, context._build):
        return _deny(
            Reason.BUILD_INCOMPATIBLE, cap_class, entitlement_verified, percentage
        )

    # 10. Schema compatibility.
    if not _schema_compatible(rule, context._schema):
        return _deny(
            Reason.SCHEMA_INCOMPATIBLE, cap_class, entitlement_verified, percentage
        )

    # 11. TTL validity.
    ttl_reason = _ttl_reason(rule, context._now)
    if ttl_reason is not None:
        return _deny(ttl_reason, cap_class, entitlement_verified, percentage)

    # 12. Explicit allowlist.
    if context._cohort in rule._allowlist:
        return _allow(
            Reason.ALLOWLISTED, cap_class, entitlement_verified, percentage
        )

    # 13. Cohort percentage.  0 never enables; 100 enables (reached only here,
    #     after every other gate and entitlement authorization).
    if percentage <= 0:
        return _deny(Reason.COHORT_EXCLUDED, cap_class, entitlement_verified, 0)
    if percentage >= 100:
        return _allow(Reason.ROLLOUT, cap_class, entitlement_verified, 100)
    if _cohort_bucket(capability, context._cohort) < percentage:
        return _allow(Reason.ROLLOUT, cap_class, entitlement_verified, percentage)
    return _deny(Reason.COHORT_EXCLUDED, cap_class, entitlement_verified, percentage)
