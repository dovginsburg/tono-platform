"""Two distinct callers with equivalent safe inputs produce identical telemetry
and receipts; caller secrets/identifiers never leak."""
import unittest

from release_control_successor_v2 import (
    Entitlement,
    EvaluationContext,
    ReleaseConfig,
    evaluate,
)

SECRET_A = "caller-A-3f9a-private-identifier"
SECRET_B = "caller-B-7c21-private-identifier"


def _evaluate(cohort, kill_switch=False, allowlist=None, percentage=100):
    rule = {"percentage": percentage, "issued_at": 1000, "ttl_seconds": 100000}
    if allowlist is not None:
        rule["allowlist"] = allowlist
    config = ReleaseConfig({"feat": rule})
    context = EvaluationContext(
        build=10,
        schema=2,
        now=1500,
        cohort=cohort,
        ready=True,
        kill_switch=kill_switch,
    )
    return evaluate("feat", config, Entitlement(["feat"]), context)


class TwoCallerNoLeakTest(unittest.TestCase):
    def test_kill_switch_deny_is_identical_across_callers(self):
        a = _evaluate(SECRET_A, kill_switch=True)
        b = _evaluate(SECRET_B, kill_switch=True)
        self.assertEqual(a.to_telemetry().to_dict(), b.to_telemetry().to_dict())
        self.assertEqual(a.to_audit_receipt().to_dict(), b.to_audit_receipt().to_dict())
        self.assertEqual(a.to_dict(), b.to_dict())

    def test_allowlisted_allow_is_identical_across_callers(self):
        a = _evaluate(SECRET_A, allowlist=[SECRET_A, SECRET_B], percentage=0)
        b = _evaluate(SECRET_B, allowlist=[SECRET_A, SECRET_B], percentage=0)
        self.assertTrue(a.allowed and b.allowed)
        self.assertEqual(a.to_telemetry().to_dict(), b.to_telemetry().to_dict())
        self.assertEqual(a.to_audit_receipt().to_dict(), b.to_audit_receipt().to_dict())

    def test_no_secret_appears_in_any_serialized_output(self):
        for cohort, secret in ((SECRET_A, SECRET_A), (SECRET_B, SECRET_B)):
            decision = _evaluate(cohort, allowlist=[cohort], percentage=0)
            payloads = [
                decision.to_dict(),
                decision.to_telemetry().to_dict(),
                decision.to_audit_receipt().to_dict(),
            ]
            for payload in payloads:
                for value in payload.values():
                    if isinstance(value, str):
                        self.assertNotIn(secret, value)
                        self.assertNotIn("caller", value)
                        self.assertNotIn("private", value)


if __name__ == "__main__":
    unittest.main()
