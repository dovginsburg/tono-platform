"""Repro class 3 — unhashable / raising hostile enum values.

Public Decision, TelemetryEvent, AuditReceipt and RollbackReceipt constructors
must not raise for ``[]`` / ``{}`` / custom unhashable values, nor invoke a
raising ``__eq__`` / ``__hash__`` / ``__str__``.  They must validate the exact
type before any membership test and fail closed / coerce only to documented
inert safe constants.
"""
import unittest

from release_control_successor_v2 import (
    AuditReceipt,
    Decision,
    RollbackReceipt,
    TelemetryEvent,
    validate_audit_receipt,
    validate_decision,
    validate_rollback_receipt,
    validate_telemetry,
)
from tests.hostile import RaisingObject, unhashable_values


class UnhashableEnumValuesTest(unittest.TestCase):
    def _build_all(self, bad):
        return (
            Decision(bad, bad, bad, bad, bad),
            TelemetryEvent(bad, bad, bad),
            AuditReceipt(bad, bad, bad, bad, bad),
            RollbackReceipt(bad, bad, bad),
        )

    def test_constructors_never_raise_on_unhashable(self):
        for bad in unhashable_values():
            with self.subTest(bad=type(bad).__name__):
                try:
                    decision, telemetry, audit, rollback = self._build_all(bad)
                except Exception as exc:  # pragma: no cover - failure path
                    self.fail(
                        "constructor raised on unhashable %s: %r"
                        % (type(bad).__name__, exc)
                    )
                self.assertTrue(validate_decision(decision.to_dict()))
                self.assertTrue(validate_telemetry(telemetry.to_dict()))
                self.assertTrue(validate_audit_receipt(audit.to_dict()))
                self.assertTrue(validate_rollback_receipt(rollback.to_dict()))

    def test_constructors_never_call_raising_dunders(self):
        bad = RaisingObject()
        try:
            self._build_all(bad)
        except Exception as exc:  # pragma: no cover - failure path
            self.fail("constructor invoked a hostile dunder: %r" % (exc,))

    def test_hostile_values_coerce_to_inert_safe_defaults(self):
        bad = object()
        decision, telemetry, audit, rollback = self._build_all(bad)
        self.assertEqual(decision.to_dict()["outcome"], "deny")
        self.assertEqual(decision.to_dict()["reason"], "unspecified")
        self.assertEqual(decision.to_dict()["capability_class"], "standard")
        self.assertEqual(decision.to_dict()["entitlement_verified"], False)
        self.assertEqual(decision.to_dict()["rollout_percentage"], 0)
        self.assertEqual(telemetry.to_dict()["outcome"], "deny")
        self.assertEqual(audit.to_dict()["reason"], "unspecified")
        self.assertEqual(rollback.to_dict()["mode"], "none")

    def test_scalar_fields_reject_bool_and_nonfinite_and_huge(self):
        # entitlement_verified: bool-exact only; rollout_percentage: int 0..100.
        for hostile_pct in (True, 1.5, float("inf"), float("nan"), 10 ** 40, -1, 101):
            with self.subTest(pct=repr(hostile_pct)):
                decision = Decision("deny", "unspecified", "standard", 0, hostile_pct)
                # Note: string enum inputs are also coerced (exact type only).
                self.assertEqual(decision.to_dict()["rollout_percentage"], 0)
                self.assertEqual(decision.to_dict()["outcome"], "deny")

    def test_bool_is_not_accepted_as_percentage(self):
        # bool is a subtype of int at runtime; it must not pass the int gate.
        receipt = AuditReceipt("deny", "unspecified", "standard", True, True)
        self.assertEqual(receipt.to_dict()["rollout_percentage"], 0)
        self.assertEqual(receipt.to_dict()["entitlement_verified"], True)


if __name__ == "__main__":
    unittest.main()
