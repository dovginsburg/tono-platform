"""Deterministic cohort 0..100 and strict finite TTL."""

from __future__ import annotations

import hashlib
import math
import unittest

import tonoit_release_control as rc


NOW = 1_000_000.0
FUTURE = 2_000_000.0


def ctx(subject="s", **kw):
    return rc.EvaluationContext(subject, now=NOW, **kw)


class CohortTests(unittest.TestCase):
    def test_bucket_in_range(self):
        for i in range(500):
            b = rc.cohort_bucket("flag", "subject-%d" % i)
            self.assertTrue(0 <= b <= 99, b)

    def test_bucket_deterministic(self):
        a = rc.cohort_bucket("flag", "subject-7")
        b = rc.cohort_bucket("flag", "subject-7")
        self.assertEqual(a, b)

    def test_bucket_matches_reference_algorithm(self):
        # Locks the algorithm to a stable, process-independent hash so the
        # cohort assignment is reproducible across runs.
        flag, subject = "checkout-v2", "user-42"
        digest = hashlib.sha256((flag + "\x00" + subject).encode("utf-8")).digest()
        expected = int.from_bytes(digest[:8], "big") % 100
        self.assertEqual(rc.cohort_bucket(flag, subject), expected)

    def test_bucket_rejects_non_str(self):
        self.assertEqual(rc.cohort_bucket("flag", 123), -1)
        self.assertEqual(rc.cohort_bucket(None, "s"), -1)

    def test_cohort_zero_releases_to_nobody(self):
        rule = rc.ReleaseRule("f", cohort=0, expires_at=FUTURE)
        cfg = rc.ReleaseConfig(rules=(rule,))
        released = sum(
            rc.is_released(cfg, "f", ctx("subject-%d" % i)) for i in range(200)
        )
        self.assertEqual(released, 0)

    def test_cohort_hundred_releases_to_everybody(self):
        rule = rc.ReleaseRule("f", cohort=100, expires_at=FUTURE)
        cfg = rc.ReleaseConfig(rules=(rule,))
        released = sum(
            rc.is_released(cfg, "f", ctx("subject-%d" % i)) for i in range(200)
        )
        self.assertEqual(released, 200)

    def test_allowlist_overrides_zero_cohort(self):
        rule = rc.ReleaseRule("f", cohort=0, allowlist=("vip",), expires_at=FUTURE)
        cfg = rc.ReleaseConfig(rules=(rule,))
        self.assertTrue(rc.is_released(cfg, "f", ctx("vip")))
        self.assertFalse(rc.is_released(cfg, "f", ctx("nobody")))

    def test_cohort_partial_rollout_is_a_stable_subset(self):
        rule = rc.ReleaseRule("f", cohort=30, expires_at=FUTURE)
        cfg = rc.ReleaseConfig(rules=(rule,))
        subjects = ["subject-%d" % i for i in range(400)]
        first = {s for s in subjects if rc.is_released(cfg, "f", ctx(s))}
        second = {s for s in subjects if rc.is_released(cfg, "f", ctx(s))}
        self.assertEqual(first, second)
        self.assertTrue(0 < len(first) < len(subjects))


class TtlTests(unittest.TestCase):
    def test_future_ttl_is_live(self):
        self.assertTrue(rc.is_valid_ttl(FUTURE, NOW))

    def test_expired_ttl_is_dead(self):
        self.assertFalse(rc.is_valid_ttl(NOW - 1.0, NOW))

    def test_now_equal_expiry_is_dead(self):
        self.assertFalse(rc.is_valid_ttl(NOW, NOW))

    def test_zero_and_negative_ttl_fail(self):
        self.assertFalse(rc.is_valid_ttl(0, NOW))
        self.assertFalse(rc.is_valid_ttl(-5.0, NOW))

    def test_nonfinite_ttl_fails(self):
        self.assertFalse(rc.is_valid_ttl(math.inf, NOW))
        self.assertFalse(rc.is_valid_ttl(math.nan, NOW))
        self.assertFalse(rc.is_valid_ttl(FUTURE, math.inf))

    def test_bool_ttl_fails(self):
        self.assertFalse(rc.is_valid_ttl(True, NOW))
        self.assertFalse(rc.is_valid_ttl(FUTURE, True))

    def test_huge_ttl_fails(self):
        self.assertFalse(rc.is_valid_ttl(1e18, NOW))

    def test_wrong_type_ttl_fails(self):
        for bad in ("2000000", None, object(), [FUTURE]):
            self.assertFalse(rc.is_valid_ttl(bad, NOW))
            self.assertFalse(rc.is_valid_ttl(FUTURE, bad))

    def test_rule_with_expired_ttl_never_releases(self):
        rule = rc.ReleaseRule("f", cohort=100, expires_at=NOW - 1.0)
        cfg = rc.ReleaseConfig(rules=(rule,))
        self.assertFalse(rc.is_released(cfg, "f", ctx("anyone")))

    def test_rule_with_bad_ttl_fails_closed(self):
        for bad in (math.inf, math.nan, True, 1e18, "soon", -1.0, 0):
            rule = rc.ReleaseRule("f", cohort=100, expires_at=bad)
            cfg = rc.ReleaseConfig(rules=(rule,))
            with self.subTest(ttl=repr(bad)):
                self.assertFalse(rc.is_released(cfg, "f", ctx("anyone")))

    def test_rule_with_future_ttl_can_release(self):
        rule = rc.ReleaseRule("f", cohort=100, expires_at=FUTURE)
        cfg = rc.ReleaseConfig(rules=(rule,))
        self.assertTrue(rc.is_released(cfg, "f", ctx("anyone")))


if __name__ == "__main__":
    unittest.main()
