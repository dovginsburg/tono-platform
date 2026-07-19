"""Caller mutation after construction cannot alter outputs; models are immutable."""
import unittest

from release_control_successor_v2 import (
    CapabilityClass,
    Decision,
    Entitlement,
    EvaluationContext,
    Outcome,
    Reason,
    ReleaseConfig,
    ReleaseRule,
    RollbackMode,
    RollbackReceipt,
    evaluate,
)


class MutationResistanceTest(unittest.TestCase):
    def test_config_ignores_later_mutation_of_source_mapping(self):
        source = {"feat": {"percentage": 100, "issued_at": 1000, "ttl_seconds": 100000}}
        config = ReleaseConfig(source)
        # Mutate the caller's dict after construction.
        source["feat"]["percentage"] = 0
        source["injected"] = {"percentage": 100, "issued_at": 1000, "ttl_seconds": 100000}
        rule = config.get("feat")
        self.assertEqual(rule.percentage, 100)
        self.assertIsNone(config.get("injected"))

    def test_rule_allowlist_ignores_later_mutation_of_source_list(self):
        allow = ["vip"]
        rule = ReleaseRule.from_mapping(
            "feat",
            {"percentage": 0, "issued_at": 1000, "ttl_seconds": 100000, "allowlist": allow},
        )
        allow.append("intruder")
        self.assertEqual(rule.allowlist, ("vip",))

    def test_entitlement_ignores_later_mutation_of_source_list(self):
        caps = ["feat"]
        entitlement = Entitlement(caps)
        caps.append("intruder")
        self.assertEqual(entitlement.authorized, frozenset({"feat"}))

    def test_config_store_is_read_only(self):
        config = ReleaseConfig(
            {"feat": {"percentage": 100, "issued_at": 1000, "ttl_seconds": 100000}}
        )
        with self.assertRaises((TypeError, AttributeError)):
            config._rules["injected"] = object()

    def test_models_are_immutable(self):
        decision = Decision(Outcome.ALLOW, Reason.ROLLOUT, CapabilityClass.STANDARD, True, 50)
        receipt = RollbackReceipt(RollbackMode.HALT, CapabilityClass.STANDARD, Reason.ROLLOUT)
        for target in (decision, receipt):
            with self.subTest(model=type(target).__name__):
                with self.assertRaises(AttributeError):
                    target._reason = Reason.KILL_SWITCH
                with self.assertRaises(AttributeError):
                    target.new_attribute = 1

    def test_context_is_immutable(self):
        context = EvaluationContext(
            build=1, schema=1, now=1, cohort="c", ready=True, kill_switch=False
        )
        with self.assertRaises(AttributeError):
            context._kill_switch = True

    def test_decision_output_stable_across_repeated_serialization(self):
        decision = evaluate(
            "feat",
            ReleaseConfig(
                {"feat": {"percentage": 100, "issued_at": 1000, "ttl_seconds": 100000}}
            ),
            Entitlement(["feat"]),
            EvaluationContext(
                build=1, schema=1, now=1500, cohort="c", ready=True, kill_switch=False
            ),
        )
        first = decision.to_dict()
        first["outcome"] = "TAMPERED"
        self.assertEqual(decision.to_dict()["outcome"], "allow")


if __name__ == "__main__":
    unittest.main()
