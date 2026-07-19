"""telemetry_of / serialize_config: totality + finite scalar-only + no echo."""

from __future__ import annotations

import math
import numbers
import unittest

import tonoit_release_control_v5 as rc

from ._helpers import empty_instance, forged_instance, short_instance


SECRET = "TOP-SECRET-CALLER-STRING-do-not-echo"


def cfg():
    return rc.ReleaseConfig(
        name=SECRET,
        enabled=True,
        kill_switch=False,
        min_build=100,
        schema_version=3,
        ttl_seconds=3600.0,
        rollout_permille=1000,
        capabilities=frozenset({SECRET, "read"}),
    )


def ctx():
    return rc.EvaluationContext(
        build_number=100,
        schema_version=3,
        ready=True,
        now=1000.0,
        issued_at=500.0,
        channel=SECRET,
    )


def _assert_finite_scalar_only(test, mapping):
    test.assertIsInstance(mapping, dict)
    for key, value in mapping.items():
        test.assertIsInstance(key, str)  # our own constant keys
        # scalar-only: bool/int/float, and every float must be finite.
        test.assertIsInstance(value, numbers.Number)
        test.assertNotIsInstance(value, complex)
        if isinstance(value, float):
            test.assertTrue(math.isfinite(value))


class TestTelemetry(unittest.TestCase):
    def test_telemetry_of_valid_receipt_is_finite_scalar_only(self):
        receipt = rc.evaluate(cfg(), ctx())
        tel = rc.telemetry_of(receipt)
        _assert_finite_scalar_only(self, tel)

    def test_telemetry_does_not_echo_caller_strings(self):
        receipt = rc.evaluate(cfg(), ctx())
        tel = rc.telemetry_of(receipt)
        blob = repr(tel)
        self.assertNotIn(SECRET, blob)
        for value in tel.values():
            self.assertNotIsInstance(value, str)

    def test_telemetry_of_malformed_receipt_never_raises(self):
        for bad in (
            empty_instance(rc.AuditReceipt),
            short_instance(rc.AuditReceipt, [1]),
            forged_instance(rc.AuditReceipt, [object()] * len(rc.AuditReceipt._fields)),
            None,
            object(),
        ):
            try:
                tel = rc.telemetry_of(bad)
            except Exception as exc:  # noqa: BLE001
                self.fail(f"telemetry_of raised on {bad!r}: {exc!r}")
            _assert_finite_scalar_only(self, tel)

    def test_fresh_telemetry_each_call(self):
        receipt = rc.evaluate(cfg(), ctx())
        self.assertIsNot(rc.telemetry_of(receipt), rc.telemetry_of(receipt))


class TestSerializeConfig(unittest.TestCase):
    def test_serialize_valid_config_scalar_only_no_echo(self):
        out = rc.serialize_config(cfg())
        _assert_finite_scalar_only(self, out)
        self.assertNotIn(SECRET, repr(out))

    def test_serialize_malformed_config_never_raises(self):
        for bad in (
            empty_instance(rc.ReleaseConfig),
            short_instance(rc.ReleaseConfig, [1, 2, 3]),
            forged_instance(rc.ReleaseConfig, [object()] * len(rc.ReleaseConfig._fields)),
            None,
            object(),
        ):
            try:
                out = rc.serialize_config(bad)
            except Exception as exc:  # noqa: BLE001
                self.fail(f"serialize_config raised on {bad!r}: {exc!r}")
            _assert_finite_scalar_only(self, out)
            self.assertEqual(out["valid"], 0)


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
