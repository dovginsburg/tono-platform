"""Entitlement non-grant: only an exact pre-existing authorization may proceed.

Release control may restrict an authorized capability but must never create
authorization.  Forged / malformed / unknown authorization fails closed.
"""
import unittest

from release_control_successor_v2 import (
    Entitlement,
    Reason,
    ReleaseConfig,
    evaluate,
)
from tests.support import make_config, make_context, make_entitlement


class EntitlementNonGrantTest(unittest.TestCase):
    def test_missing_entitlement_denies(self):
        d = evaluate("feat", make_config(), Entitlement([]), make_context())
        self.assertIs(d.reason, Reason.NOT_ENTITLED)
        self.assertFalse(d.allowed)

    def test_entitlement_for_other_capability_denies(self):
        d = evaluate("feat", make_config(), Entitlement(["other"]), make_context())
        self.assertIs(d.reason, Reason.NOT_ENTITLED)

    def test_forged_dict_entitlement_denies(self):
        d = evaluate("feat", make_config(), {"feat": True}, make_context())
        self.assertIs(d.reason, Reason.NOT_ENTITLED)

    def test_none_entitlement_denies(self):
        d = evaluate("feat", make_config(), None, make_context())
        self.assertIs(d.reason, Reason.NOT_ENTITLED)

    def test_entitlement_subclass_claiming_authorization_denies(self):
        class ForgedEntitlement(Entitlement):
            def authorizes(self, capability):
                return True

        forged = ForgedEntitlement([])  # authorizes nothing in the real store
        d = evaluate("feat", make_config(), forged, make_context())
        self.assertIs(d.reason, Reason.NOT_ENTITLED)

    def test_entitlement_from_hostile_container_authorizes_nothing(self):
        # A mapping is not an accepted capability container.
        forged = Entitlement({"feat": 1})
        self.assertEqual(forged.authorized, frozenset())
        d = evaluate("feat", make_config(), forged, make_context())
        self.assertIs(d.reason, Reason.NOT_ENTITLED)

    def test_entitlement_does_not_override_config_or_gates(self):
        # Even a valid entitlement cannot enable an unknown flag...
        d = evaluate("ghost", ReleaseConfig({}), Entitlement(["ghost"]), make_context())
        self.assertIs(d.reason, Reason.UNKNOWN_FLAG)
        # ...nor force a 0% rollout on.
        config = ReleaseConfig(
            {"feat": {"percentage": 0, "issued_at": 1000, "ttl_seconds": 100000}}
        )
        d2 = evaluate("feat", config, make_entitlement(), make_context(cohort="nobody"))
        self.assertIs(d2.reason, Reason.COHORT_EXCLUDED)

    def test_valid_entitlement_reaches_gates(self):
        d = evaluate("feat", make_config(), make_entitlement(), make_context())
        self.assertTrue(d.allowed)
        self.assertTrue(d.entitlement_verified)


if __name__ == "__main__":
    unittest.main()
