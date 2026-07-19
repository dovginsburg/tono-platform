"""Hostile regression 3: validators fail closed without probing caller keys.

Every public validator returns False for anything that is not a genuine,
package-constructed instance, and does so without ``set(payload.keys())``,
membership probes, lookups, comparisons, or any operation that rehashes or
executes arbitrary caller keys. Hostile exact dict keys must never raise.
"""

from __future__ import annotations

import unittest

import tonoit_release_control as rc

from _hostile import CountingKey, HashRaisesLaterKey, RaisingEqKey, StrSubclassKey


VALIDATORS = (
    "is_valid_config",
    "is_valid_rule",
    "is_valid_context",
    "is_valid_entitlement",
)


class ValidatorFailClosedTests(unittest.TestCase):
    def test_validators_reject_hostile_dicts_without_raising(self):
        payloads = (
            {RaisingEqKey(): True},
            {HashRaisesLaterKey(): True},
            {StrSubclassKey("x"): 1},
            {"looks": "valid", "cohort": 100},
            {},
        )
        for name in VALIDATORS:
            fn = getattr(rc, name)
            for payload in payloads:
                with self.subTest(validator=name, payload=type(payload)):
                    self.assertFalse(fn(payload))

    def test_validators_reject_arbitrary_objects(self):
        for name in VALIDATORS:
            fn = getattr(rc, name)
            for obj in (None, 0, "s", [1], (1,), object(), RaisingEqKey()):
                with self.subTest(validator=name, obj=type(obj)):
                    self.assertFalse(fn(obj))

    def test_validators_do_not_touch_caller_keys(self):
        # If a validator probed the dict, CountingKey's hash/eq would fire.
        for name in VALIDATORS:
            fn = getattr(rc, name)
            payload = {CountingKey(): True}
            CountingKey.reset()
            self.assertFalse(fn(payload))
            with self.subTest(validator=name):
                self.assertEqual(CountingKey.hashes, 0)
                self.assertEqual(CountingKey.eqs, 0)

    def test_validators_accept_genuine_instances(self):
        rule = rc.ReleaseRule("beta", cohort=10)
        cfg = rc.ReleaseConfig(rules=(rule,))
        ctx = rc.EvaluationContext("s", now=1000.0)
        ent = rc.Entitlement("pro", granted=False)
        self.assertTrue(rc.is_valid_rule(rule))
        self.assertTrue(rc.is_valid_config(cfg))
        self.assertTrue(rc.is_valid_context(ctx))
        self.assertTrue(rc.is_valid_entitlement(ent))
        # cross-type must fail closed
        self.assertFalse(rc.is_valid_rule(cfg))
        self.assertFalse(rc.is_valid_config(rule))
        self.assertFalse(rc.is_valid_context(ent))

    def test_is_valid_flag_name(self):
        self.assertTrue(rc.is_valid_flag_name("beta"))
        self.assertFalse(rc.is_valid_flag_name(StrSubclassKey("beta")))
        self.assertFalse(rc.is_valid_flag_name(""))
        self.assertFalse(rc.is_valid_flag_name(None))
        self.assertFalse(rc.is_valid_flag_name(123))


if __name__ == "__main__":
    unittest.main()
