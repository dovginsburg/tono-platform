"""Unknown flags default off; empty config releases nothing."""

from __future__ import annotations

import unittest

import tonoit_release_control as rc

from _hostile import StrSubclassKey


NOW = 1_000_000.0
FUTURE = 2_000_000.0


class DefaultOffTests(unittest.TestCase):
    def setUp(self):
        self.ctx = rc.EvaluationContext("s", now=NOW)

    def test_empty_config_releases_nothing(self):
        cfg = rc.ReleaseConfig()
        self.assertFalse(rc.is_released(cfg, "anything", self.ctx))
        dec = rc.evaluate(cfg, "anything", self.ctx)
        self.assertEqual(dec.reason_code, rc.REASON_UNKNOWN_FLAG)

    def test_unknown_flag_default_off(self):
        cfg = rc.ReleaseConfig(rules=(rc.ReleaseRule("known", cohort=100, expires_at=FUTURE),))
        self.assertFalse(rc.is_released(cfg, "unknown", self.ctx))
        self.assertTrue(rc.is_released(cfg, "known", self.ctx))

    def test_invalid_flag_argument_fails_closed(self):
        cfg = rc.ReleaseConfig(rules=(rc.ReleaseRule("known", cohort=100, expires_at=FUTURE),))
        for bad in (None, 123, object(), StrSubclassKey("known"), b"known"):
            with self.subTest(flag=type(bad)):
                self.assertFalse(rc.is_released(cfg, bad, self.ctx))

    def test_invalid_config_fails_closed(self):
        self.assertFalse(rc.is_released({"known": True}, "known", self.ctx))
        dec = rc.evaluate({"known": True}, "known", self.ctx)
        self.assertEqual(dec.reason_code, rc.REASON_INVALID)

    def test_invalid_context_fails_closed(self):
        cfg = rc.ReleaseConfig(rules=(rc.ReleaseRule("known", cohort=100, expires_at=FUTURE),))
        # context with no subject is invalid
        bad_ctx = rc.EvaluationContext(None, now=NOW)
        self.assertFalse(rc.is_valid_context(bad_ctx))
        self.assertFalse(rc.is_released(cfg, "known", bad_ctx))

    def test_explicit_false_flag_is_off(self):
        cfg = rc.ReleaseConfig(flags={"beta": False})
        self.assertFalse(rc.is_released(cfg, "beta", self.ctx))


if __name__ == "__main__":
    unittest.main()
