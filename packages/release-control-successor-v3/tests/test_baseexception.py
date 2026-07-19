"""Totality for ordinary Exception hostility; BaseException is not swallowed."""

from __future__ import annotations

import unittest

import tonoit_release_control as rc

from _hostile import ExplodingIter


class TotalityTests(unittest.TestCase):
    def test_ordinary_exception_in_rules_iterable_fails_closed(self):
        cfg = rc.ReleaseConfig(rules=ExplodingIter(ValueError("boom")))
        self.assertTrue(rc.is_valid_config(cfg))
        ctx = rc.EvaluationContext("s", now=1000.0)
        self.assertFalse(rc.is_released(cfg, "anything", ctx))

    def test_keyboardinterrupt_in_rules_iterable_propagates(self):
        with self.assertRaises(KeyboardInterrupt):
            rc.ReleaseConfig(rules=ExplodingIter(KeyboardInterrupt()))

    def test_systemexit_in_rules_iterable_propagates(self):
        with self.assertRaises(SystemExit):
            rc.ReleaseConfig(rules=ExplodingIter(SystemExit(2)))

    def test_ordinary_exception_hostile_values_never_raise(self):
        # Constructors stay total for Exception-derived hostility.
        rule = rc.ReleaseRule.from_mapping({"cohort": ValueError, "flag": object()})
        self.assertFalse(rule.valid)


if __name__ == "__main__":
    unittest.main()
