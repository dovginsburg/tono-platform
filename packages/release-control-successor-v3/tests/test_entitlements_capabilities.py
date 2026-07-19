"""Entitlement non-grant and protected-capability preservation."""

from __future__ import annotations

import unittest

import tonoit_release_control as rc

from _hostile import RaisingEqKey


PROTECTED = ("safety", "help", "export", "delete", "recovery")
NOW = 1_000_000.0
FUTURE = 2_000_000.0


class EntitlementTests(unittest.TestCase):
    def test_release_never_grants_entitlements(self):
        self.assertFalse(rc.release_grants_entitlements())

    def test_decision_carries_no_entitlement(self):
        cfg = rc.ReleaseConfig(rules=(rc.ReleaseRule("f", cohort=100, expires_at=FUTURE),))
        dec = rc.evaluate(cfg, "f", rc.EvaluationContext("s", now=NOW))
        self.assertFalse(hasattr(dec, "entitlement"))
        self.assertFalse(hasattr(dec, "grant"))
        self.assertFalse(hasattr(dec, "authority"))

    def test_no_public_grant_api(self):
        for name in ("grant", "grant_entitlement", "grant_authority", "elevate"):
            self.assertFalse(hasattr(rc, name))

    def test_authority_in_context_does_not_produce_entitlement(self):
        # Even a fully-authorised context only passes the gate; it grants nothing.
        rule = rc.ReleaseRule("f", cohort=100, requires_authority=True, expires_at=FUTURE)
        cfg = rc.ReleaseConfig(rules=(rule,))
        ctx = rc.EvaluationContext("s", now=NOW, has_authority=True)
        dec = rc.evaluate(cfg, "f", ctx)
        self.assertTrue(dec.released)
        self.assertNotIsInstance(dec, rc.Entitlement)

    def test_entitlement_is_immutable_and_not_elevated(self):
        ent = rc.Entitlement("pro", granted=False)
        self.assertFalse(ent.granted)
        with self.assertRaises((AttributeError, TypeError)):
            ent.granted = True  # noqa: B010


class ProtectedCapabilityTests(unittest.TestCase):
    def test_protected_capabilities_listed(self):
        caps = rc.protected_capabilities()
        for name in PROTECTED:
            self.assertIn(name, caps)

    def test_protected_always_available_even_when_killed(self):
        cfg = rc.ReleaseConfig(flags={}, killed=True, ready=False)
        ctx = rc.EvaluationContext("s", now=NOW)
        for name in PROTECTED:
            with self.subTest(cap=name):
                self.assertTrue(rc.is_capability_available(cfg, name, ctx))

    def test_protected_available_with_invalid_config_and_context(self):
        for name in PROTECTED:
            with self.subTest(cap=name):
                self.assertTrue(rc.is_capability_available("not-a-config", name, None))

    def test_non_protected_capability_is_default_off(self):
        cfg = rc.ReleaseConfig(flags={})
        ctx = rc.EvaluationContext("s", now=NOW)
        self.assertFalse(rc.is_capability_available(cfg, "premium_theme", ctx))

    def test_non_protected_capability_follows_release_rules(self):
        rule = rc.ReleaseRule("premium_theme", cohort=100, expires_at=FUTURE)
        cfg = rc.ReleaseConfig(rules=(rule,))
        ctx = rc.EvaluationContext("s", now=NOW)
        self.assertTrue(rc.is_capability_available(cfg, "premium_theme", ctx))

    def test_hostile_capability_input_fails_closed(self):
        cfg = rc.ReleaseConfig(flags={})
        ctx = rc.EvaluationContext("s", now=NOW)
        for bad in (None, 123, object(), RaisingEqKey()):
            with self.subTest(cap=type(bad)):
                self.assertFalse(rc.is_capability_available(cfg, bad, ctx))


if __name__ == "__main__":
    unittest.main()
