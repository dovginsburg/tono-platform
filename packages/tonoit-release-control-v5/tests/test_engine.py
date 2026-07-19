"""evaluate / is_released: totality, default-off, and gate precedence."""

from __future__ import annotations

import unittest

import tonoit_release_control_v5 as rc

from ._helpers import empty_instance, forged_instance, short_instance


def cfg(**kw):
    base = dict(
        name="feature",
        enabled=True,
        kill_switch=False,
        min_build=100,
        schema_version=3,
        ttl_seconds=3600.0,
        rollout_permille=1000,
        capabilities=frozenset({"read"}),
    )
    base.update(kw)
    return rc.ReleaseConfig(**base)


def ctx(**kw):
    base = dict(
        build_number=100,
        schema_version=3,
        ready=True,
        now=1000.0,
        issued_at=500.0,
        channel="stable",
    )
    base.update(kw)
    return rc.EvaluationContext(**base)


class TestEngineTotality(unittest.TestCase):
    def test_malformed_config_does_not_propagate_indexerror(self):
        for bad in (
            empty_instance(rc.ReleaseConfig),
            short_instance(rc.ReleaseConfig, [1, 2]),
            forged_instance(rc.ReleaseConfig, [object()] * len(rc.ReleaseConfig._fields)),
        ):
            receipt = rc.evaluate(bad, ctx())
            self.assertIs(rc.is_valid_audit_receipt(receipt), True)
            self.assertIs(receipt.released, False)
            self.assertIs(rc.is_released(bad, ctx()), False)

    def test_malformed_context_does_not_propagate_indexerror(self):
        for bad in (
            empty_instance(rc.EvaluationContext),
            short_instance(rc.EvaluationContext, [1]),
            forged_instance(rc.EvaluationContext, [object()] * len(rc.EvaluationContext._fields)),
        ):
            receipt = rc.evaluate(cfg(), bad)
            self.assertIs(receipt.released, False)
            self.assertIs(rc.is_released(cfg(), bad), False)

    def test_both_malformed_default_off(self):
        receipt = rc.evaluate(empty_instance(rc.ReleaseConfig), empty_instance(rc.EvaluationContext))
        self.assertIs(receipt.released, False)


class TestGatePrecedence(unittest.TestCase):
    def test_happy_path_released(self):
        self.assertIs(rc.is_released(cfg(), ctx()), True)

    def test_kill_switch_beats_everything(self):
        # kill switch on but also not-ready, low build, etc -> KILLED wins.
        r = rc.evaluate(cfg(kill_switch=True), ctx(ready=False, build_number=0))
        self.assertIs(r.released, False)
        self.assertEqual(r.reason_code, rc.REASON_KILLED)

    def test_readiness_before_build(self):
        r = rc.evaluate(cfg(), ctx(ready=False, build_number=0))
        self.assertEqual(r.reason_code, rc.REASON_NOT_READY)

    def test_build_before_schema(self):
        r = rc.evaluate(cfg(), ctx(build_number=1, schema_version=999))
        self.assertEqual(r.reason_code, rc.REASON_BUILD_TOO_LOW)

    def test_schema_before_ttl(self):
        r = rc.evaluate(cfg(), ctx(schema_version=999, now=10 ** 9))
        self.assertEqual(r.reason_code, rc.REASON_SCHEMA_MISMATCH)

    def test_ttl_expiry(self):
        r = rc.evaluate(cfg(ttl_seconds=10.0), ctx(now=1000.0, issued_at=0.0))
        self.assertIs(r.released, False)
        self.assertEqual(r.reason_code, rc.REASON_EXPIRED)

    def test_future_issued_context_defaults_off(self):
        r = rc.evaluate(cfg(ttl_seconds=10.0), ctx(now=100.0, issued_at=101.0))
        self.assertIs(r.released, False)
        self.assertEqual(r.reason_code, rc.REASON_EXPIRED)
        self.assertIs(rc.is_released(cfg(ttl_seconds=10.0), ctx(now=100.0, issued_at=101.0)), False)

    def test_exact_ttl_boundary_defaults_off(self):
        r = rc.evaluate(cfg(ttl_seconds=10.0), ctx(now=105.0, issued_at=95.0))
        self.assertIs(r.released, False)
        self.assertEqual(r.reason_code, rc.REASON_EXPIRED)
        self.assertIs(rc.is_released(cfg(ttl_seconds=10.0), ctx(now=105.0, issued_at=95.0)), False)

    def test_disabled_default_off(self):
        r = rc.evaluate(cfg(enabled=False), ctx())
        self.assertIs(r.released, False)
        self.assertEqual(r.reason_code, rc.REASON_DISABLED)

    def test_zero_rollout_default_off(self):
        r = rc.evaluate(cfg(rollout_permille=0), ctx())
        self.assertIs(r.released, False)
        self.assertEqual(r.reason_code, rc.REASON_ROLLOUT_ZERO)

    def test_is_released_returns_exact_bool(self):
        self.assertIs(rc.is_released(cfg(enabled=False), ctx()), False)
        self.assertIs(rc.is_released(cfg(), ctx()), True)


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
