"""Protected capabilities can never be disabled or withheld by release control."""
import unittest

from release_control_successor_v2 import (
    CapabilityClass,
    PROTECTED_CAPABILITIES,
    Reason,
    ReleaseConfig,
    evaluate,
)
from tests.support import make_context, make_entitlement


class ProtectedCapabilityTest(unittest.TestCase):
    def test_expected_protected_set(self):
        self.assertEqual(
            PROTECTED_CAPABILITIES,
            frozenset({"safety", "help", "export", "delete", "recovery"}),
        )

    def test_protected_capabilities_always_allowed(self):
        # Even under a kill switch, not-ready, empty config, and no entitlement.
        hostile_context = make_context(kill_switch=True, ready=False)
        for capability in PROTECTED_CAPABILITIES:
            with self.subTest(capability=capability):
                d = evaluate(capability, ReleaseConfig({}), None, hostile_context)
                self.assertTrue(d.allowed)
                self.assertIs(d.reason, Reason.PROTECTED_CAPABILITY)
                self.assertIs(d.capability_class, CapabilityClass.PROTECTED)

    def test_protected_allowed_even_with_fully_malformed_inputs(self):
        for capability in PROTECTED_CAPABILITIES:
            with self.subTest(capability=capability):
                d = evaluate(capability, None, None, None)
                self.assertTrue(d.allowed)
                self.assertIs(d.capability_class, CapabilityClass.PROTECTED)

    def test_protected_telemetry_and_audit_marked_protected(self):
        d = evaluate("delete", None, None, None)
        self.assertEqual(d.to_telemetry().to_dict()["capability_class"], "protected")
        self.assertEqual(d.to_audit_receipt().to_dict()["capability_class"], "protected")

    def test_standard_capability_not_treated_as_protected(self):
        d = evaluate("safety_extra", ReleaseConfig({}), None, make_context())
        self.assertIs(d.capability_class, CapabilityClass.STANDARD)
        self.assertFalse(d.allowed)


if __name__ == "__main__":
    unittest.main()
