"""Gate behavior: precedence, fail-closed defaults, build/schema, cohort 0/100."""
import unittest

from release_control_successor_v2 import (
    Entitlement,
    EvaluationContext,
    Outcome,
    Reason,
    ReleaseConfig,
    evaluate,
)
from tests.support import make_config, make_context, make_entitlement


class EngineGateTest(unittest.TestCase):
    def test_baseline_allows(self):
        d = evaluate("feat", make_config(), make_entitlement(), make_context())
        self.assertTrue(d.allowed)
        self.assertIs(d.outcome, Outcome.ALLOW)
        self.assertIs(d.reason, Reason.ROLLOUT)

    def test_unknown_flag_denies(self):
        d = evaluate("other", make_config(), make_entitlement(("other",)), make_context())
        self.assertIs(d.reason, Reason.UNKNOWN_FLAG)
        self.assertFalse(d.allowed)

    def test_malformed_capability_denies(self):
        for bad in ("", "has space", "UPPER OK?", "x" * 65, 123, None, ["feat"]):
            with self.subTest(cap=repr(bad)):
                d = evaluate(bad, make_config(), make_entitlement(), make_context())
                self.assertFalse(d.allowed)
                self.assertIs(d.reason, Reason.MALFORMED_INPUT)

    def test_non_context_object_denies(self):
        d = evaluate("feat", make_config(), make_entitlement(), object())
        self.assertIs(d.reason, Reason.MALFORMED_INPUT)

    def test_kill_switch_denies_and_takes_precedence(self):
        # Kill switch beats readiness and everything downstream.
        d = evaluate(
            "feat",
            make_config(),
            make_entitlement(),
            make_context(kill_switch=True, ready=False),
        )
        self.assertIs(d.reason, Reason.KILL_SWITCH)
        self.assertFalse(d.allowed)

    def test_kill_switch_fails_closed_on_malformed(self):
        # A non-bool kill switch is treated as killed.
        d = evaluate(
            "feat", make_config(), make_entitlement(), make_context(kill_switch="yes")
        )
        self.assertIs(d.reason, Reason.KILL_SWITCH)

    def test_not_ready_denies(self):
        d = evaluate("feat", make_config(), make_entitlement(), make_context(ready=False))
        self.assertIs(d.reason, Reason.NOT_READY)

    def test_readiness_fails_closed_on_malformed(self):
        d = evaluate("feat", make_config(), make_entitlement(), make_context(ready="yes"))
        self.assertIs(d.reason, Reason.NOT_READY)

    def test_malformed_numeric_context_denies(self):
        for bad in (float("inf"), float("nan"), 10 ** 40, True, "150", None):
            with self.subTest(build=repr(bad)):
                d = evaluate(
                    "feat", make_config(), make_entitlement(), make_context(build=bad)
                )
                self.assertIs(d.reason, Reason.MALFORMED_INPUT)

    def test_build_incompatible_low_and_high(self):
        for build in (99, 201):
            with self.subTest(build=build):
                d = evaluate(
                    "feat", make_config(), make_entitlement(), make_context(build=build)
                )
                self.assertIs(d.reason, Reason.BUILD_INCOMPATIBLE)
                self.assertFalse(d.allowed)

    def test_build_boundaries_inclusive(self):
        for build in (100, 200):
            with self.subTest(build=build):
                d = evaluate(
                    "feat", make_config(), make_entitlement(), make_context(build=build)
                )
                self.assertTrue(d.allowed)

    def test_schema_incompatible(self):
        for schema in (4, 10):
            with self.subTest(schema=schema):
                d = evaluate(
                    "feat", make_config(), make_entitlement(), make_context(schema=schema)
                )
                self.assertIs(d.reason, Reason.SCHEMA_INCOMPATIBLE)

    def test_cohort_zero_never_enables(self):
        config = ReleaseConfig(
            {"feat": {"percentage": 0, "issued_at": 1000, "ttl_seconds": 100000}}
        )
        d = evaluate("feat", config, make_entitlement(), make_context(cohort="nobody"))
        self.assertIs(d.reason, Reason.COHORT_EXCLUDED)
        self.assertFalse(d.allowed)
        self.assertEqual(d.rollout_percentage, 0)

    def test_cohort_zero_allowlist_still_enables(self):
        config = ReleaseConfig(
            {
                "feat": {
                    "percentage": 0,
                    "issued_at": 1000,
                    "ttl_seconds": 100000,
                    "allowlist": ["vip"],
                }
            }
        )
        d = evaluate("feat", config, make_entitlement(), make_context(cohort="vip"))
        self.assertIs(d.reason, Reason.ALLOWLISTED)
        self.assertTrue(d.allowed)

    def test_cohort_hundred_enables(self):
        config = ReleaseConfig(
            {"feat": {"percentage": 100, "issued_at": 1000, "ttl_seconds": 100000}}
        )
        d = evaluate("feat", config, make_entitlement(), make_context(cohort="anyone"))
        self.assertTrue(d.allowed)
        self.assertIs(d.reason, Reason.ROLLOUT)
        self.assertEqual(d.rollout_percentage, 100)

    def test_partial_percentage_is_deterministic(self):
        config = ReleaseConfig(
            {"feat": {"percentage": 50, "issued_at": 1000, "ttl_seconds": 100000}}
        )
        first = evaluate("feat", config, make_entitlement(), make_context(cohort="stable"))
        second = evaluate("feat", config, make_entitlement(), make_context(cohort="stable"))
        self.assertEqual(first.to_dict(), second.to_dict())

    def test_out_of_range_percentage_drops_rule(self):
        for pct in (-1, 101, 1000):
            with self.subTest(pct=pct):
                config = ReleaseConfig(
                    {"feat": {"percentage": pct, "issued_at": 1000, "ttl_seconds": 100000}}
                )
                d = evaluate("feat", config, make_entitlement(), make_context())
                self.assertIs(d.reason, Reason.UNKNOWN_FLAG)

    def test_malformed_config_is_empty(self):
        for bad in (None, [], "config", 42):
            with self.subTest(cfg=repr(bad)):
                config = ReleaseConfig(bad)
                d = evaluate("feat", config, make_entitlement(), make_context())
                self.assertIs(d.reason, Reason.UNKNOWN_FLAG)


if __name__ == "__main__":
    unittest.main()
