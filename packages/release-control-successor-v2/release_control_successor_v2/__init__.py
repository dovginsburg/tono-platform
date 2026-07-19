"""release_control_successor_v2 — a fail-closed, privacy-first release-control core.

This package is **source-only, standard-library-only, and imported by nothing**.
It is unwired and default-off: importing it starts no work, opens no files or
sockets, reads no environment/clock, and integrates with no runtime.  It is a
pure decision core — every input is supplied as plain data and every output is
a freshly built plain ``dict`` of built-in scalars.

Design invariants:

* **Fail closed.** Unknown / malformed flags, configs, entitlements and
  contexts default off.  Only exact plain trusted types are accepted at public
  boundaries; subclasses, custom mappings/sequences, hostile objects,
  ``bool``-as-``int``, non-finite/huge numbers and raising accessors cannot
  bypass safety.
* **Never grants.** Release control may restrict an already-authorized
  capability but can never create entitlement or capability.
* **Protected capabilities** (``safety``, ``help``, ``export``, ``delete``,
  ``recovery``) can never be disabled or withheld.
* **Minimized privacy.** Telemetry and receipts have one exact, finite,
  flat schema of scalar/enum values.  No details/context/payload/config/reason
  bags, nested objects, caller strings, raw identifiers, hashes, or reason
  echoes.  Two callers with equivalent safe inputs emit identical output.
"""
from __future__ import annotations

from ._enums import CapabilityClass, Outcome, Reason, RollbackMode
from .config import (
    Entitlement,
    EvaluationContext,
    ReleaseConfig,
    ReleaseRule,
    valid_capability_name,
)
from .engine import PROTECTED_CAPABILITIES, evaluate
from .models import (
    AuditReceipt,
    Decision,
    RollbackReceipt,
    TelemetryEvent,
    validate_audit_receipt,
    validate_decision,
    validate_rollback_receipt,
    validate_telemetry,
)

__all__ = [
    # engine
    "evaluate",
    "PROTECTED_CAPABILITIES",
    # enums
    "Outcome",
    "Reason",
    "CapabilityClass",
    "RollbackMode",
    # inputs
    "ReleaseConfig",
    "ReleaseRule",
    "Entitlement",
    "EvaluationContext",
    "valid_capability_name",
    # outputs
    "Decision",
    "TelemetryEvent",
    "AuditReceipt",
    "RollbackReceipt",
    # validators
    "validate_decision",
    "validate_telemetry",
    "validate_audit_receipt",
    "validate_rollback_receipt",
]

__version__ = "0.0.0"
