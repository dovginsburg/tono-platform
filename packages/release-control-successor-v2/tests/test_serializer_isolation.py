"""Every serialize path returns a newly isolated plain dict of built-in scalars."""
import unittest

from release_control_successor_v2 import (
    AuditReceipt,
    CapabilityClass,
    Decision,
    Outcome,
    Reason,
    RollbackMode,
    RollbackReceipt,
    TelemetryEvent,
)

_SCALARS = (str, int, bool)


class SerializerIsolationTest(unittest.TestCase):
    def _models(self):
        decision = Decision(Outcome.ALLOW, Reason.ROLLOUT, CapabilityClass.STANDARD, True, 50)
        return [
            decision,
            decision.to_telemetry(),
            decision.to_audit_receipt(),
            TelemetryEvent(Outcome.DENY, Reason.KILL_SWITCH, CapabilityClass.STANDARD),
            AuditReceipt(Outcome.DENY, Reason.NOT_READY, CapabilityClass.STANDARD, False, 0),
            RollbackReceipt(RollbackMode.DRAIN, CapabilityClass.STANDARD, Reason.ROLLOUT),
        ]

    def test_each_call_returns_a_fresh_plain_dict(self):
        for model in self._models():
            with self.subTest(model=type(model).__name__):
                first = model.to_dict()
                second = model.to_dict()
                self.assertIs(type(first), dict)
                self.assertIsNot(first, second)
                self.assertEqual(first, second)

    def test_values_are_built_in_scalars_only(self):
        for model in self._models():
            with self.subTest(model=type(model).__name__):
                for key, value in model.to_dict().items():
                    self.assertIs(type(key), str)
                    self.assertIn(type(value), _SCALARS, "%s -> %r" % (key, value))

    def test_mutating_a_returned_dict_does_not_affect_the_model(self):
        for model in self._models():
            with self.subTest(model=type(model).__name__):
                payload = model.to_dict()
                snapshot = dict(payload)
                payload["outcome"] = "TAMPERED"
                payload["injected"] = ["bag"]
                self.assertEqual(model.to_dict(), snapshot)

    def test_bool_values_are_exact_bool_not_int(self):
        decision = Decision(Outcome.ALLOW, Reason.ROLLOUT, CapabilityClass.STANDARD, True, 50)
        self.assertIs(type(decision.to_dict()["entitlement_verified"]), bool)


if __name__ == "__main__":
    unittest.main()
