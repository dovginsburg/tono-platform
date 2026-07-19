"""Immutable, minimized decision and receipt models plus their validators.

Every public constructor here is *total*: it never raises on hostile input.
Each field is coerced through an exact-type gate to a documented inert safe
constant (see :mod:`release_control_successor_v2._safety`).  Every ``to_dict``
returns a freshly built plain ``dict`` whose values are built-in scalars only
(``str`` / ``int`` / ``bool``); no nested objects, bags, caller strings, raw
identifiers, hashes, or reason echoes ever appear.

This module performs no I/O.
"""
from __future__ import annotations

from typing import Any, Callable, Dict, Mapping

from ._enums import CapabilityClass, Outcome, Reason, RollbackMode
from ._safety import Immutable, coerce_bool, coerce_enum, coerce_int_in_range

# Frozen top-level schema versions.  Bumping any of these is the only supported
# way to change a serialized shape; unknown/extra/missing keys are rejected.
DECISION_SCHEMA_VERSION = 1
TELEMETRY_SCHEMA_VERSION = 1
AUDIT_SCHEMA_VERSION = 1
ROLLBACK_SCHEMA_VERSION = 1


class Decision(Immutable):
    """The result of :func:`release_control_successor_v2.evaluate`.

    Fail-closed defaults: an unrecognized outcome coerces to ``DENY``, an
    unrecognized reason to ``UNSPECIFIED``, an unrecognized class to
    ``STANDARD``.
    """

    __slots__ = (
        "_outcome",
        "_reason",
        "_capability_class",
        "_entitlement_verified",
        "_rollout_percentage",
    )

    def __init__(
        self,
        outcome: Any,
        reason: Any,
        capability_class: Any,
        entitlement_verified: Any,
        rollout_percentage: Any,
    ) -> None:
        self._set("_outcome", coerce_enum(outcome, Outcome, Outcome.DENY))
        self._set("_reason", coerce_enum(reason, Reason, Reason.UNSPECIFIED))
        self._set(
            "_capability_class",
            coerce_enum(capability_class, CapabilityClass, CapabilityClass.STANDARD),
        )
        self._set("_entitlement_verified", coerce_bool(entitlement_verified, False))
        self._set(
            "_rollout_percentage",
            coerce_int_in_range(rollout_percentage, 0, 100, 0),
        )

    @property
    def allowed(self) -> bool:
        return self._outcome is Outcome.ALLOW

    @property
    def outcome(self) -> Outcome:
        return self._outcome

    @property
    def reason(self) -> Reason:
        return self._reason

    @property
    def capability_class(self) -> CapabilityClass:
        return self._capability_class

    @property
    def entitlement_verified(self) -> bool:
        return self._entitlement_verified

    @property
    def rollout_percentage(self) -> int:
        return self._rollout_percentage

    def to_dict(self) -> Dict[str, Any]:
        return {
            "decision_schema_version": DECISION_SCHEMA_VERSION,
            "outcome": self._outcome.value,
            "reason": self._reason.value,
            "capability_class": self._capability_class.value,
            "entitlement_verified": self._entitlement_verified,
            "rollout_percentage": self._rollout_percentage,
        }

    def to_telemetry(self) -> "TelemetryEvent":
        return TelemetryEvent(self._outcome, self._reason, self._capability_class)

    def to_audit_receipt(self) -> "AuditReceipt":
        return AuditReceipt(
            self._outcome,
            self._reason,
            self._capability_class,
            self._entitlement_verified,
            self._rollout_percentage,
        )

    def __eq__(self, other: Any) -> bool:
        return type(other) is Decision and self.to_dict() == other.to_dict()

    def __hash__(self) -> int:
        return hash(tuple(sorted(self.to_dict().items())))

    def __repr__(self) -> str:
        return "Decision(%r)" % (self.to_dict(),)


class TelemetryEvent(Immutable):
    """The single, exact, finite telemetry schema.

    Exactly four keys, all finite built-in scalars/enums.  It carries no
    capability name, cohort id, caller string, identifier, hash, reason echo,
    or any nested bag.  Two callers with equivalent safe inputs therefore emit
    byte-identical telemetry.
    """

    __slots__ = ("_outcome", "_reason", "_capability_class")

    def __init__(self, outcome: Any, reason: Any, capability_class: Any) -> None:
        self._set("_outcome", coerce_enum(outcome, Outcome, Outcome.DENY))
        self._set("_reason", coerce_enum(reason, Reason, Reason.UNSPECIFIED))
        self._set(
            "_capability_class",
            coerce_enum(capability_class, CapabilityClass, CapabilityClass.STANDARD),
        )

    @property
    def outcome(self) -> Outcome:
        return self._outcome

    @property
    def reason(self) -> Reason:
        return self._reason

    @property
    def capability_class(self) -> CapabilityClass:
        return self._capability_class

    def to_dict(self) -> Dict[str, Any]:
        return {
            "event_schema_version": TELEMETRY_SCHEMA_VERSION,
            "outcome": self._outcome.value,
            "reason": self._reason.value,
            "capability_class": self._capability_class.value,
        }

    def __eq__(self, other: Any) -> bool:
        return type(other) is TelemetryEvent and self.to_dict() == other.to_dict()

    def __hash__(self) -> int:
        return hash(tuple(sorted(self.to_dict().items())))

    def __repr__(self) -> str:
        return "TelemetryEvent(%r)" % (self.to_dict(),)


class AuditReceipt(Immutable):
    """Minimized, immutable audit receipt.

    Records the decision, the deciding reason, the capability class, whether a
    pre-existing entitlement was verified (proving the non-grant property), and
    the config-declared rollout percentage (a bounded ``int`` derived from
    config, never from caller identity).
    """

    __slots__ = (
        "_outcome",
        "_reason",
        "_capability_class",
        "_entitlement_verified",
        "_rollout_percentage",
    )

    def __init__(
        self,
        outcome: Any,
        reason: Any,
        capability_class: Any,
        entitlement_verified: Any,
        rollout_percentage: Any,
    ) -> None:
        self._set("_outcome", coerce_enum(outcome, Outcome, Outcome.DENY))
        self._set("_reason", coerce_enum(reason, Reason, Reason.UNSPECIFIED))
        self._set(
            "_capability_class",
            coerce_enum(capability_class, CapabilityClass, CapabilityClass.STANDARD),
        )
        self._set("_entitlement_verified", coerce_bool(entitlement_verified, False))
        self._set(
            "_rollout_percentage",
            coerce_int_in_range(rollout_percentage, 0, 100, 0),
        )

    @property
    def outcome(self) -> Outcome:
        return self._outcome

    @property
    def reason(self) -> Reason:
        return self._reason

    @property
    def capability_class(self) -> CapabilityClass:
        return self._capability_class

    @property
    def entitlement_verified(self) -> bool:
        return self._entitlement_verified

    @property
    def rollout_percentage(self) -> int:
        return self._rollout_percentage

    def to_dict(self) -> Dict[str, Any]:
        return {
            "receipt_schema_version": AUDIT_SCHEMA_VERSION,
            "outcome": self._outcome.value,
            "reason": self._reason.value,
            "capability_class": self._capability_class.value,
            "entitlement_verified": self._entitlement_verified,
            "rollout_percentage": self._rollout_percentage,
        }

    def __eq__(self, other: Any) -> bool:
        return type(other) is AuditReceipt and self.to_dict() == other.to_dict()

    def __hash__(self) -> int:
        return hash(tuple(sorted(self.to_dict().items())))

    def __repr__(self) -> str:
        return "AuditReceipt(%r)" % (self.to_dict(),)


class RollbackReceipt(Immutable):
    """Minimized, immutable rollback receipt.

    ``mode`` must be exactly a :class:`RollbackMode` member; anything else
    (including an object whose equality/hash mimic a real member, or an
    unhashable value) is coerced to the inert ``RollbackMode.NONE`` so the
    hostile object is never retained nor emitted.
    """

    __slots__ = ("_mode", "_capability_class", "_reason")

    def __init__(self, mode: Any, capability_class: Any, reason: Any) -> None:
        self._set("_mode", coerce_enum(mode, RollbackMode, RollbackMode.NONE))
        self._set(
            "_capability_class",
            coerce_enum(capability_class, CapabilityClass, CapabilityClass.STANDARD),
        )
        self._set("_reason", coerce_enum(reason, Reason, Reason.UNSPECIFIED))

    @property
    def mode(self) -> RollbackMode:
        return self._mode

    @property
    def capability_class(self) -> CapabilityClass:
        return self._capability_class

    @property
    def reason(self) -> Reason:
        return self._reason

    def to_dict(self) -> Dict[str, Any]:
        return {
            "receipt_schema_version": ROLLBACK_SCHEMA_VERSION,
            "mode": self._mode.value,
            "capability_class": self._capability_class.value,
            "reason": self._reason.value,
        }

    def __eq__(self, other: Any) -> bool:
        return type(other) is RollbackReceipt and self.to_dict() == other.to_dict()

    def __hash__(self) -> int:
        return hash(tuple(sorted(self.to_dict().items())))

    def __repr__(self) -> str:
        return "RollbackReceipt(%r)" % (self.to_dict(),)


# --------------------------------------------------------------------------- #
# Validators — the package's own gate that every serialized payload must pass. #
# --------------------------------------------------------------------------- #

_OUTCOME_VALUES = frozenset(member.value for member in Outcome)
_REASON_VALUES = frozenset(member.value for member in Reason)
_CAP_CLASS_VALUES = frozenset(member.value for member in CapabilityClass)
_ROLLBACK_MODE_VALUES = frozenset(member.value for member in RollbackMode)


def _is_version(expected: int) -> Callable[[Any], bool]:
    def check(value: Any) -> bool:
        return type(value) is int and value == expected

    return check


def _in_str_set(allowed: frozenset) -> Callable[[Any], bool]:
    def check(value: Any) -> bool:
        # ``type(value) is str`` first: a hostile key value never reaches the
        # (safe, str-only) membership test.
        return type(value) is str and value in allowed

    return check


def _is_bool(value: Any) -> bool:
    return type(value) is bool


def _is_percentage(value: Any) -> bool:
    return type(value) is int and 0 <= value <= 100


def _valid_flat(payload: Any, spec: Mapping[str, Callable[[Any], bool]]) -> bool:
    """True iff ``payload`` is an exact ``dict`` with exactly ``spec``'s keys
    (no missing, no extra) and every value passes its predicate."""
    if type(payload) is not dict:
        return False
    if set(payload.keys()) != set(spec.keys()):
        return False
    for key, predicate in spec.items():
        if not predicate(payload[key]):
            return False
    return True


_DECISION_SPEC = {
    "decision_schema_version": _is_version(DECISION_SCHEMA_VERSION),
    "outcome": _in_str_set(_OUTCOME_VALUES),
    "reason": _in_str_set(_REASON_VALUES),
    "capability_class": _in_str_set(_CAP_CLASS_VALUES),
    "entitlement_verified": _is_bool,
    "rollout_percentage": _is_percentage,
}

_TELEMETRY_SPEC = {
    "event_schema_version": _is_version(TELEMETRY_SCHEMA_VERSION),
    "outcome": _in_str_set(_OUTCOME_VALUES),
    "reason": _in_str_set(_REASON_VALUES),
    "capability_class": _in_str_set(_CAP_CLASS_VALUES),
}

_AUDIT_SPEC = {
    "receipt_schema_version": _is_version(AUDIT_SCHEMA_VERSION),
    "outcome": _in_str_set(_OUTCOME_VALUES),
    "reason": _in_str_set(_REASON_VALUES),
    "capability_class": _in_str_set(_CAP_CLASS_VALUES),
    "entitlement_verified": _is_bool,
    "rollout_percentage": _is_percentage,
}

_ROLLBACK_SPEC = {
    "receipt_schema_version": _is_version(ROLLBACK_SCHEMA_VERSION),
    "mode": _in_str_set(_ROLLBACK_MODE_VALUES),
    "capability_class": _in_str_set(_CAP_CLASS_VALUES),
    "reason": _in_str_set(_REASON_VALUES),
}


def validate_decision(payload: Any) -> bool:
    return _valid_flat(payload, _DECISION_SPEC)


def validate_telemetry(payload: Any) -> bool:
    return _valid_flat(payload, _TELEMETRY_SPEC)


def validate_audit_receipt(payload: Any) -> bool:
    return _valid_flat(payload, _AUDIT_SPEC)


def validate_rollback_receipt(payload: Any) -> bool:
    return _valid_flat(payload, _ROLLBACK_SPEC)
