"""Fresh, finite, scalar-only telemetry and serialization.

Outputs contain only genuine built-in scalars (bool/int/float/str) under our
own fixed string keys. No caller-supplied key, string, id, object, reason, or
nested structure is ever echoed or retained, and every call returns a freshly
built dict.
"""

from __future__ import annotations

from ._models import AuditReceipt, Decision, ReleaseConfig, _get
from ._reasons import (
    GATE_INPUT,
    REASON_INVALID,
    TELEMETRY_SCHEMA_VERSION,
)


def _invalid_telemetry():
    return {
        "released": False,
        "reason_code": REASON_INVALID,
        "gate": GATE_INPUT,
        "bucket": -1,
        "schema_version": TELEMETRY_SCHEMA_VERSION,
    }


def telemetry_of(decision):
    if type(decision) is AuditReceipt:
        return decision.telemetry()
    if type(decision) is not Decision:
        return _invalid_telemetry()
    try:
        return {
            "released": bool(_get(decision, 0)),
            "reason_code": int(_get(decision, 1)),
            "gate": int(_get(decision, 2)),
            "bucket": int(_get(decision, 3)),
            "schema_version": TELEMETRY_SCHEMA_VERSION,
        }
    except Exception:
        return _invalid_telemetry()


def serialize_config(config):
    if type(config) is not ReleaseConfig or _get(config, 0) is not True:
        return {
            "valid": False,
            "rule_count": 0,
            "killed": False,
            "ready": False,
            "schema_version": TELEMETRY_SCHEMA_VERSION,
        }
    try:
        return {
            "valid": True,
            "rule_count": int(len(_get(config, 3))),
            "killed": bool(_get(config, 1)),
            "ready": bool(_get(config, 2)),
            "schema_version": TELEMETRY_SCHEMA_VERSION,
        }
    except Exception:
        return {
            "valid": False,
            "rule_count": 0,
            "killed": False,
            "ready": False,
            "schema_version": TELEMETRY_SCHEMA_VERSION,
        }


def audit_receipt(decision):
    """Build an immutable, scalar-only audit/rollback receipt from a decision."""
    if type(decision) is not Decision:
        return AuditReceipt(False, REASON_INVALID, GATE_INPUT, TELEMETRY_SCHEMA_VERSION)
    try:
        return AuditReceipt(
            bool(_get(decision, 0)),
            int(_get(decision, 1)),
            int(_get(decision, 2)),
            TELEMETRY_SCHEMA_VERSION,
        )
    except Exception:
        return AuditReceipt(False, REASON_INVALID, GATE_INPUT, TELEMETRY_SCHEMA_VERSION)
