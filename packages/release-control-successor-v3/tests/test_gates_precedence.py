"""Gate precedence: kill > readiness > authority > build > schema > ttl."""

from __future__ import annotations

import unittest

import tonoit_release_control as rc


NOW = 1_000_000.0
FUTURE = 2_000_000.0


def ctx(**kw):
    base = dict(subject="s", build=100, schema=5, now=NOW,
                has_authority=True, ready=True)
    base.update(kw)
    return rc.EvaluationContext(base.pop("subject"), **base)


class GateTests(unittest.TestCase):
    def _cfg(self, rule, **cfgkw):
        return rc.ReleaseConfig(rules=(rule,), **cfgkw)

    def test_kill_switch_global(self):
        rule = rc.ReleaseRule("f", cohort=100, expires_at=FUTURE)
        cfg = self._cfg(rule, killed=True)
        dec = rc.evaluate(cfg, "f", ctx())
        self.assertFalse(dec.released)
        self.assertEqual(dec.reason_code, rc.REASON_KILLED)

    def test_kill_switch_per_rule(self):
        rule = rc.ReleaseRule("f", cohort=100, killed=True, expires_at=FUTURE)
        dec = rc.evaluate(self._cfg(rule), "f", ctx())
        self.assertEqual(dec.reason_code, rc.REASON_KILLED)

    def test_readiness_gate(self):
        rule = rc.ReleaseRule("f", cohort=100, requires_ready=True, expires_at=FUTURE)
        dec = rc.evaluate(self._cfg(rule), "f", ctx(ready=False))
        self.assertEqual(dec.reason_code, rc.REASON_NOT_READY)

    def test_authority_gate(self):
        rule = rc.ReleaseRule("f", cohort=100, requires_authority=True, expires_at=FUTURE)
        dec = rc.evaluate(self._cfg(rule), "f", ctx(has_authority=False))
        self.assertEqual(dec.reason_code, rc.REASON_NO_AUTHORITY)

    def test_build_gate(self):
        rule = rc.ReleaseRule("f", cohort=100, min_build=200, expires_at=FUTURE)
        dec = rc.evaluate(self._cfg(rule), "f", ctx(build=100))
        self.assertEqual(dec.reason_code, rc.REASON_BUILD_GATE)

    def test_schema_gate(self):
        rule = rc.ReleaseRule("f", cohort=100, required_schema=9, expires_at=FUTURE)
        dec = rc.evaluate(self._cfg(rule), "f", ctx(schema=5))
        self.assertEqual(dec.reason_code, rc.REASON_SCHEMA_GATE)

    def test_ttl_gate(self):
        rule = rc.ReleaseRule("f", cohort=100, expires_at=NOW - 1.0)  # expired
        dec = rc.evaluate(self._cfg(rule), "f", ctx())
        self.assertEqual(dec.reason_code, rc.REASON_TTL_EXPIRED)

    def test_kill_beats_all_other_failures(self):
        # A rule failing readiness, authority, build, schema, and ttl at once,
        # plus a global kill: kill must win.
        rule = rc.ReleaseRule(
            "f", cohort=100, requires_ready=True, requires_authority=True,
            min_build=999, required_schema=9, expires_at=NOW - 1.0, killed=True,
        )
        cfg = self._cfg(rule, killed=True)
        bad = ctx(ready=False, has_authority=False, build=1, schema=1)
        dec = rc.evaluate(cfg, "f", bad)
        self.assertEqual(dec.reason_code, rc.REASON_KILLED)

    def test_readiness_beats_authority(self):
        rule = rc.ReleaseRule(
            "f", cohort=100, requires_ready=True, requires_authority=True,
            expires_at=FUTURE,
        )
        dec = rc.evaluate(self._cfg(rule), "f", ctx(ready=False, has_authority=False))
        self.assertEqual(dec.reason_code, rc.REASON_NOT_READY)

    def test_authority_beats_build(self):
        rule = rc.ReleaseRule(
            "f", cohort=100, requires_authority=True, min_build=999, expires_at=FUTURE,
        )
        dec = rc.evaluate(self._cfg(rule), "f", ctx(has_authority=False, build=1))
        self.assertEqual(dec.reason_code, rc.REASON_NO_AUTHORITY)

    def test_build_beats_schema(self):
        rule = rc.ReleaseRule(
            "f", cohort=100, min_build=999, required_schema=9, expires_at=FUTURE,
        )
        dec = rc.evaluate(self._cfg(rule), "f", ctx(build=1, schema=1))
        self.assertEqual(dec.reason_code, rc.REASON_BUILD_GATE)

    def test_schema_beats_ttl(self):
        rule = rc.ReleaseRule(
            "f", cohort=100, required_schema=9, expires_at=NOW - 1.0,
        )
        dec = rc.evaluate(self._cfg(rule), "f", ctx(schema=1))
        self.assertEqual(dec.reason_code, rc.REASON_SCHEMA_GATE)

    def test_all_gates_pass_releases(self):
        rule = rc.ReleaseRule(
            "f", cohort=100, requires_ready=True, requires_authority=True,
            min_build=50, required_schema=5, expires_at=FUTURE,
        )
        dec = rc.evaluate(self._cfg(rule), "f", ctx())
        self.assertTrue(dec.released)
        self.assertEqual(dec.reason_code, rc.REASON_OK)


if __name__ == "__main__":
    unittest.main()
