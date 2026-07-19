"""Fail-closed evaluation: gates, deterministic cohort, capabilities.

Release control decides only whether a *flag* is released. It never grants an
entitlement or authority; authority is an input gate that must already be
satisfied by the context. Protected safety/help/export/delete/recovery
capabilities are always available and cannot be gated off.
"""

from __future__ import annotations

import hashlib

from ._models import Decision, EvaluationContext, ReleaseConfig, ReleaseRule, _get
from ._reasons import (
    GATE_AUTHORITY,
    GATE_BUILD,
    GATE_COHORT,
    GATE_INPUT,
    GATE_KILL,
    GATE_NONE,
    GATE_READY,
    GATE_SCHEMA,
    GATE_TTL,
    GATE_ALLOWLIST,
    PROTECTED_CAPABILITIES,
    REASON_BUILD_GATE,
    REASON_INVALID,
    REASON_KILLED,
    REASON_NO_AUTHORITY,
    REASON_NOT_IN_COHORT,
    REASON_NOT_READY,
    REASON_OK,
    REASON_SCHEMA_GATE,
    REASON_TTL_EXPIRED,
    REASON_UNKNOWN_FLAG,
    MAX_COHORT,
)


def cohort_bucket(flag, subject):
    """Deterministic 0..99 bucket, stable across processes (SHA-256 based)."""
    if type(flag) is not str or type(subject) is not str:
        return -1
    try:
        data = (flag + "\x00" + subject).encode("utf-8", "strict")
        digest = hashlib.sha256(data).digest()
        return int.from_bytes(digest[:8], "big") % 100
    except Exception:
        return -1


def _rule_well_formed(rule):
    """Defense in depth against forged rules bypassing the constructor."""
    try:
        return (
            type(_get(rule, 0)) is bool
            and type(_get(rule, 1)) is str
            and type(_get(rule, 2)) is int and 0 <= _get(rule, 2) <= MAX_COHORT
            and type(_get(rule, 3)) is frozenset
            and type(_get(rule, 4)) is bool
            and type(_get(rule, 5)) is bool
            and type(_get(rule, 6)) is int and _get(rule, 6) >= 0
            and type(_get(rule, 7)) is int and _get(rule, 7) >= 0
            and type(_get(rule, 8)) is bool
            and type(_get(rule, 9)) is bool
            and type(_get(rule, 10)) is bool
            and type(_get(rule, 11)) is float
        )
    except Exception:
        return False


def _find_rule(config, flag):
    # flag is a confirmed genuine str; rule flags are genuine strs. Comparing
    # two genuine strs never runs hostile code.
    for rule in _get(config, 3):
        if type(rule) is ReleaseRule and _get(rule, 1) == flag:
            return rule
    return None


def evaluate(config, flag, context):
    if type(config) is not ReleaseConfig or _get(config, 0) is not True:
        return Decision(False, REASON_INVALID, GATE_INPUT, -1)
    if type(context) is not EvaluationContext or _get(context, 0) is not True:
        return Decision(False, REASON_INVALID, GATE_INPUT, -1)
    if type(flag) is not str:
        return Decision(False, REASON_UNKNOWN_FLAG, GATE_INPUT, -1)

    rule = _find_rule(config, flag)
    if rule is None:
        return Decision(False, REASON_UNKNOWN_FLAG, GATE_NONE, -1)
    if not _rule_well_formed(rule):
        return Decision(False, REASON_INVALID, GATE_INPUT, -1)

    cfg_killed = _get(config, 1)
    cfg_ready = _get(config, 2)
    r_cohort = _get(rule, 2)
    r_allow = _get(rule, 3)
    r_auth = _get(rule, 4)
    r_ready = _get(rule, 5)
    r_build = _get(rule, 6)
    r_schema = _get(rule, 7)
    r_killed = _get(rule, 8)
    r_has_ttl = _get(rule, 9)
    r_ttl_valid = _get(rule, 10)
    r_expires = _get(rule, 11)

    ctx_subject = _get(context, 1)
    ctx_build = _get(context, 2)
    ctx_schema = _get(context, 3)
    ctx_now = _get(context, 4)
    ctx_auth = _get(context, 5)
    ctx_ready = _get(context, 6)

    # 1. Kill switch (highest precedence).
    if cfg_killed is True or r_killed is True:
        return Decision(False, REASON_KILLED, GATE_KILL, -1)
    # 2. Readiness.
    if cfg_ready is not True or (r_ready is True and ctx_ready is not True):
        return Decision(False, REASON_NOT_READY, GATE_READY, -1)
    # 3. Authority (checked, never granted).
    if r_auth is True and ctx_auth is not True:
        return Decision(False, REASON_NO_AUTHORITY, GATE_AUTHORITY, -1)
    # 4. Build gate.
    if r_build > 0 and not (ctx_build >= 0 and ctx_build >= r_build):
        return Decision(False, REASON_BUILD_GATE, GATE_BUILD, -1)
    # 5. Schema gate.
    if r_schema > 0 and not (ctx_schema >= 0 and ctx_schema == r_schema):
        return Decision(False, REASON_SCHEMA_GATE, GATE_SCHEMA, -1)
    # 6. TTL gate.
    if r_has_ttl and not (r_ttl_valid and ctx_now < r_expires):
        return Decision(False, REASON_TTL_EXPIRED, GATE_TTL, -1)
    # 7. Allowlist override -> release.
    if len(r_allow) > 0 and ctx_subject in r_allow:
        return Decision(True, REASON_OK, GATE_ALLOWLIST, -1)
    # 8. Deterministic cohort.
    bucket = cohort_bucket(flag, ctx_subject)
    if 0 <= bucket < r_cohort:
        return Decision(True, REASON_OK, GATE_COHORT, bucket)
    return Decision(False, REASON_NOT_IN_COHORT, GATE_COHORT, bucket)


def is_released(config, flag, context):
    return bool(_get(evaluate(config, flag, context), 0))


def is_capability_available(config, capability, context):
    # Protected capabilities are always available, regardless of config,
    # context, or kill switches. Release control can never disable them.
    if type(capability) is str and capability in PROTECTED_CAPABILITIES:
        return True
    if type(capability) is not str:
        return False
    return is_released(config, capability, context)


def protected_capabilities():
    return PROTECTED_CAPABILITIES


def release_grants_entitlements():
    # Invariant: release control never grants entitlements or authority.
    return False
