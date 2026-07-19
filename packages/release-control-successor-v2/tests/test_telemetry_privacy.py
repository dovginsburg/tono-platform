"""P0 privacy: exact finite flat schema; no bags/echoes/identifiers; validators
reject unknown/extra/missing keys and exact-type violations."""
import unittest

from release_control_successor_v2 import (
    Entitlement,
    EvaluationContext,
    ReleaseConfig,
    evaluate,
    validate_audit_receipt,
    validate_decision,
    validate_rollback_receipt,
    validate_telemetry,
    RollbackMode,
    RollbackReceipt,
    CapabilityClass,
    Reason,
)


class TelemetryPrivacyTest(unittest.TestCase):
    def _decision(self):
        config = ReleaseConfig(
            {"feat": {"percentage": 100, "issued_at": 1000, "ttl_seconds": 100000}}
        )
        context = EvaluationContext(
            build=1,
            schema=1,
            now=1500,
            cohort="account-1234-secret-token",
            ready=True,
            kill_switch=False,
        )
        return evaluate("feat", config, Entitlement(["feat"]), context)

    def test_telemetry_exact_key_set(self):
        payload = self._decision().to_telemetry().to_dict()
        self.assertEqual(
            set(payload.keys()),
            {"event_schema_version", "outcome", "reason", "capability_class"},
        )

    def test_telemetry_values_are_finite_scalars(self):
        payload = self._decision().to_telemetry().to_dict()
        self.assertIs(type(payload["event_schema_version"]), int)
        for key in ("outcome", "reason", "capability_class"):
            self.assertIs(type(payload[key]), str)

    def test_no_capability_or_cohort_leaks_into_telemetry(self):
        payload = self._decision().to_telemetry().to_dict()
        values = list(payload.values())
        self.assertNotIn("feat", values)
        self.assertNotIn("account-1234-secret-token", values)
        # And no value contains the secret as a substring either.
        for value in values:
            if isinstance(value, str):
                self.assertNotIn("account-1234-secret-token", value)
                self.assertNotIn("secret", value)

    def test_validator_accepts_real_payloads(self):
        d = self._decision()
        self.assertTrue(validate_decision(d.to_dict()))
        self.assertTrue(validate_telemetry(d.to_telemetry().to_dict()))
        self.assertTrue(validate_audit_receipt(d.to_audit_receipt().to_dict()))
        self.assertTrue(
            validate_rollback_receipt(
                RollbackReceipt(
                    RollbackMode.HALT, CapabilityClass.STANDARD, Reason.ROLLOUT
                ).to_dict()
            )
        )

    def test_validator_rejects_extra_key(self):
        payload = self._decision().to_telemetry().to_dict()
        payload["details"] = {"caller": "x"}
        self.assertFalse(validate_telemetry(payload))

    def test_validator_rejects_missing_key(self):
        payload = self._decision().to_telemetry().to_dict()
        del payload["reason"]
        self.assertFalse(validate_telemetry(payload))

    def test_validator_rejects_wrong_value_type(self):
        payload = self._decision().to_telemetry().to_dict()
        payload["outcome"] = 1
        self.assertFalse(validate_telemetry(payload))

    def test_validator_rejects_nested_or_bag_value(self):
        payload = self._decision().to_telemetry().to_dict()
        payload["reason"] = {"nested": "bag"}
        self.assertFalse(validate_telemetry(payload))

    def test_validator_rejects_unknown_enum_value(self):
        payload = self._decision().to_telemetry().to_dict()
        payload["outcome"] = "maybe"
        self.assertFalse(validate_telemetry(payload))

    def test_validator_rejects_non_dict_and_dict_subclass(self):
        class SneakyDict(dict):
            pass

        good = self._decision().to_telemetry().to_dict()
        self.assertFalse(validate_telemetry(SneakyDict(good)))
        self.assertFalse(validate_telemetry([("outcome", "deny")]))
        self.assertFalse(validate_telemetry(None))

    def test_bad_schema_version_rejected(self):
        payload = self._decision().to_telemetry().to_dict()
        payload["event_schema_version"] = 2
        self.assertFalse(validate_telemetry(payload))
        payload["event_schema_version"] = True  # bool must not pass int gate
        self.assertFalse(validate_telemetry(payload))


if __name__ == "__main__":
    unittest.main()
