"""Telemetry/serialized outputs: finite scalar-only, fresh, no caller echoes."""

from __future__ import annotations

import math
import unittest

import tonoit_release_control as rc


_SCALARS = (bool, int, float, str)


def _assert_finite_scalar(test, value):
    test.assertIn(type(value), _SCALARS)
    if type(value) is float:
        test.assertTrue(math.isfinite(value))


class TelemetryTests(unittest.TestCase):
    def setUp(self):
        self.cfg = rc.ReleaseConfig(
            flags={"beta": True},
            rules=(rc.ReleaseRule("gamma", cohort=100, expires_at=2_000_000.0),),
        )
        self.ctx = rc.EvaluationContext("secret-subject-id", now=1_000_000.0)

    def test_telemetry_is_finite_scalar_only(self):
        dec = rc.evaluate(self.cfg, "gamma", self.ctx)
        tel = rc.telemetry_of(dec)
        self.assertIs(type(tel), dict)
        for key, value in tel.items():
            self.assertIs(type(key), str)  # our own fixed keys
            _assert_finite_scalar(self, value)

    def test_telemetry_has_no_caller_string_echoes(self):
        dec = rc.evaluate(self.cfg, "gamma", self.ctx)
        tel = rc.telemetry_of(dec)
        string_values = [v for v in tel.values() if type(v) is str]
        for s in string_values:
            self.assertNotIn("secret-subject-id", s)
            self.assertNotIn("gamma", s)
            self.assertNotIn("beta", s)

    def test_telemetry_is_fresh_each_call(self):
        dec = rc.evaluate(self.cfg, "gamma", self.ctx)
        a = rc.telemetry_of(dec)
        b = rc.telemetry_of(dec)
        self.assertIsNot(a, b)
        self.assertEqual(a, b)

    def test_telemetry_of_forged_decision_does_not_raise(self):
        forged = tuple.__new__(rc.Decision, (object(), object(), object(), object()))
        tel = rc.telemetry_of(forged)  # must not raise
        for value in tel.values():
            _assert_finite_scalar(self, value)
        self.assertFalse(tel["released"])

    def test_serialize_config_is_scalar_only_no_flag_names(self):
        ser = rc.serialize_config(self.cfg)
        self.assertIs(type(ser), dict)
        for key, value in ser.items():
            self.assertIs(type(key), str)
            _assert_finite_scalar(self, value)
        for value in ser.values():
            if type(value) is str:
                self.assertNotIn("beta", value)
                self.assertNotIn("gamma", value)

    def test_serialize_config_rejects_non_config(self):
        ser = rc.serialize_config({"beta": True})
        self.assertFalse(ser["valid"])
        self.assertEqual(ser["rule_count"], 0)

    def test_audit_receipt_telemetry_scalar_only(self):
        dec = rc.evaluate(self.cfg, "gamma", self.ctx)
        rcpt = rc.audit_receipt(dec)
        tel = rc.telemetry_of(rcpt) if hasattr(rc, "telemetry_of") else None
        # AuditReceipt exposes its own scalar telemetry method too.
        rtel = rcpt.telemetry()
        for value in rtel.values():
            _assert_finite_scalar(self, value)

    def test_no_object_retention(self):
        # Nothing the caller passed should be reachable by identity in outputs.
        dec = rc.evaluate(self.cfg, "gamma", self.ctx)
        tel = rc.telemetry_of(dec)
        for value in tel.values():
            self.assertNotIsInstance(value, rc.EvaluationContext)
            self.assertNotIsInstance(value, rc.ReleaseConfig)


if __name__ == "__main__":
    unittest.main()
