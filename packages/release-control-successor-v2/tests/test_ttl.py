"""Strict TTL: reject future-issued, zero, negative, expired, bool, non-finite,
huge, and wrong-type timestamps/durations with no implicit coercion."""
import unittest

from release_control_successor_v2 import (
    Reason,
    ReleaseConfig,
    ReleaseRule,
    evaluate,
)
from tests.support import make_context, make_entitlement


def _rule(**overrides):
    base = {"percentage": 100, "issued_at": 1000, "ttl_seconds": 100}
    base.update(overrides)
    return base


def _config(**overrides):
    return ReleaseConfig({"feat": _rule(**overrides)})


class TtlTest(unittest.TestCase):
    def test_live_window_is_allowed(self):
        for now in (1000, 1050, 1099):
            with self.subTest(now=now):
                d = evaluate("feat", _config(), make_entitlement(), make_context(now=now))
                self.assertTrue(d.allowed)

    def test_future_issued_is_invalid(self):
        d = evaluate("feat", _config(), make_entitlement(), make_context(now=999))
        self.assertIs(d.reason, Reason.TTL_INVALID)

    def test_expiry_is_exclusive(self):
        d = evaluate("feat", _config(), make_entitlement(), make_context(now=1100))
        self.assertIs(d.reason, Reason.TTL_EXPIRED)

    def test_expired_after_window(self):
        d = evaluate("feat", _config(), make_entitlement(), make_context(now=5000))
        self.assertIs(d.reason, Reason.TTL_EXPIRED)

    def test_zero_ttl_drops_rule(self):
        self.assertIsNone(ReleaseRule.from_mapping("feat", _rule(ttl_seconds=0)))
        d = evaluate("feat", _config(ttl_seconds=0), make_entitlement(), make_context())
        self.assertIs(d.reason, Reason.UNKNOWN_FLAG)

    def test_negative_ttl_drops_rule(self):
        self.assertIsNone(ReleaseRule.from_mapping("feat", _rule(ttl_seconds=-5)))

    def test_bool_ttl_drops_rule(self):
        self.assertIsNone(ReleaseRule.from_mapping("feat", _rule(ttl_seconds=True)))

    def test_nonfinite_ttl_drops_rule(self):
        for bad in (float("inf"), float("nan"), float("-inf")):
            with self.subTest(ttl=repr(bad)):
                self.assertIsNone(ReleaseRule.from_mapping("feat", _rule(ttl_seconds=bad)))

    def test_huge_ttl_drops_rule(self):
        self.assertIsNone(ReleaseRule.from_mapping("feat", _rule(ttl_seconds=10 ** 40)))

    def test_wrong_type_ttl_drops_rule(self):
        for bad in ("100", None, [100], {"ttl": 100}):
            with self.subTest(ttl=repr(bad)):
                self.assertIsNone(ReleaseRule.from_mapping("feat", _rule(ttl_seconds=bad)))

    def test_bad_issued_at_drops_rule(self):
        for bad in (True, -1, float("inf"), 10 ** 40, "1000", None):
            with self.subTest(issued=repr(bad)):
                self.assertIsNone(ReleaseRule.from_mapping("feat", _rule(issued_at=bad)))

    def test_missing_ttl_fields_drop_rule(self):
        self.assertIsNone(ReleaseRule.from_mapping("feat", {"percentage": 100}))
        self.assertIsNone(
            ReleaseRule.from_mapping("feat", {"percentage": 100, "issued_at": 1000})
        )


if __name__ == "__main__":
    unittest.main()
