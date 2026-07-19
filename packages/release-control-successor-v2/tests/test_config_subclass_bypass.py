"""Repro class 2 — ReleaseConfig subclass get() bypass.

An exact ReleaseConfig subclass overriding get() to return a permissive rule for
an unknown flag must be rejected / fail closed.  The engine must never trust a
polymorphic accessor at this boundary.
"""
import unittest

from release_control_successor_v2 import (
    Entitlement,
    EvaluationContext,
    Outcome,
    Reason,
    ReleaseConfig,
    ReleaseRule,
    evaluate,
)


class PermissiveConfig(ReleaseConfig):
    """Hostile subclass: get() forges a fully-permissive rule for ANY flag."""

    def get(self, flag):
        return ReleaseRule.from_mapping(
            "evil",
            {"percentage": 100, "issued_at": 0, "ttl_seconds": 10_000_000},
        )


class ConfigSubclassBypassTest(unittest.TestCase):
    def _context(self):
        return EvaluationContext(
            build=50, schema=5, now=1000, cohort="c", ready=True, kill_switch=False
        )

    def test_subclass_get_override_cannot_enable_unknown_flag(self):
        config = PermissiveConfig({})  # base store is empty; "evil" is unknown
        entitlement = Entitlement(["evil"])  # even *with* a real entitlement...
        decision = evaluate("evil", config, entitlement, self._context())
        # ...the forged rule must not enable an unknown flag.
        self.assertFalse(decision.allowed)
        self.assertIs(decision.outcome, Outcome.DENY)
        self.assertIs(decision.reason, Reason.UNKNOWN_FLAG)

    def test_subclass_get_override_cannot_enable_known_flag_either(self):
        # A subclass instance is rejected wholesale, even for a real flag.
        config = PermissiveConfig(
            {"real": {"percentage": 100, "issued_at": 0, "ttl_seconds": 10_000_000}}
        )
        decision = evaluate("real", config, Entitlement(["real"]), self._context())
        self.assertFalse(decision.allowed)
        self.assertIs(decision.reason, Reason.UNKNOWN_FLAG)

    def test_plain_config_without_rule_denies_unknown_flag(self):
        config = ReleaseConfig({})
        decision = evaluate("evil", config, Entitlement(["evil"]), self._context())
        self.assertIs(decision.reason, Reason.UNKNOWN_FLAG)

    def test_forged_config_object_denies(self):
        # An arbitrary object presenting a get() method is not a ReleaseConfig.
        class DuckConfig:
            def get(self, flag):
                return ReleaseRule.from_mapping(
                    "x", {"percentage": 100, "issued_at": 0, "ttl_seconds": 1000}
                )

        decision = evaluate("x", DuckConfig(), Entitlement(["x"]), self._context())
        self.assertIs(decision.reason, Reason.UNKNOWN_FLAG)


if __name__ == "__main__":
    unittest.main()
