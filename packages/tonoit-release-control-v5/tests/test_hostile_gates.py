"""Hostile gates: no callable/descriptor backdoor, no rehash of caller keys,
BaseException propagation, entitlement non-grant, protected capabilities."""

from __future__ import annotations

import unittest

import tonoit_release_control_v5 as rc

from ._helpers import CallTrap, HashTrap, forged_instance


def _rc_len():
    return len(rc.ReleaseConfig._fields)


class TestNoBackdoor(unittest.TestCase):
    def test_callable_field_never_invoked(self):
        trap = CallTrap()
        forged = forged_instance(rc.ReleaseConfig, [trap] * _rc_len())
        self.assertIs(rc.is_valid_release_config(forged), False)
        rc.evaluate(forged, rc.EvaluationContext(1, 1, True, 1.0, 0.0, "c"))
        rc.serialize_config(forged)
        self.assertEqual(trap.calls, 0)
        self.assertEqual(trap.gets, 0)

    def test_hostile_keys_never_hashed_or_compared(self):
        trap = HashTrap()
        # Place the hash-trap where a capabilities frozenset should be.
        vals = ["n", True, False, 1, 1, 1.0, 500, trap]
        forged = forged_instance(rc.ReleaseConfig, vals[:_rc_len()])
        self.assertIs(rc.is_valid_release_config(forged), False)
        rc.serialize_config(forged)
        rc.evaluate(forged, rc.EvaluationContext(1, 1, True, 1.0, 0.0, "c"))
        self.assertEqual(trap.hashed, 0)
        self.assertEqual(trap.eq_calls, 0)

    def test_hostile_key_in_every_position_never_executes(self):
        # A hash-trap dropped into each field slot must never be hashed by any
        # validator, and each such config must be rejected.
        length = _rc_len()
        for pos in range(length):
            trap = HashTrap()
            vals = ["n", True, False, 1, 1, 1.0, 500, frozenset()]
            vals[pos] = trap
            forged = forged_instance(rc.ReleaseConfig, vals[:length])
            self.assertIs(rc.is_valid_release_config(forged), False)
            rc.serialize_config(forged)
            self.assertEqual(trap.hashed, 0, f"hashed at position {pos}")
            self.assertEqual(trap.eq_calls, 0, f"compared at position {pos}")


class TestBaseExceptionPropagates(unittest.TestCase):
    def test_keyboardinterrupt_not_swallowed(self):
        def raiser():
            raise KeyboardInterrupt

        with self.assertRaises(KeyboardInterrupt):
            rc._guard(raiser, default="X")  # internal guard used by public API

    def test_systemexit_not_swallowed(self):
        def raiser():
            raise SystemExit(2)

        with self.assertRaises(SystemExit):
            rc._guard(raiser, default="X")

    def test_ordinary_exception_is_swallowed(self):
        def raiser():
            raise ValueError("ordinary")

        self.assertEqual(rc._guard(raiser, default="fallback"), "fallback")

    def test_base_exception_not_swallowed_generic(self):
        class MyBase(BaseException):
            pass

        def raiser():
            raise MyBase

        with self.assertRaises(MyBase):
            rc._guard(raiser, default=None)


class TestEntitlementNonGrant(unittest.TestCase):
    def test_no_grant_api_exposed(self):
        for name in dir(rc):
            low = name.lower()
            self.assertNotIn("grant", low)
            # No entitlement *authority* API (issuing/mutating entitlements).
            if "entitle" in low:
                self.assertNotIn("issue", low)
                self.assertNotIn("set", low)

    def test_protected_capabilities_readonly_frozenset(self):
        caps = rc.protected_capabilities()
        self.assertIsInstance(caps, frozenset)
        self.assertEqual(caps, rc.PROTECTED_CAPABILITIES)
        self.assertGreater(len(caps), 0)

    def test_no_membership_probe_api_exists(self):
        # There is intentionally no membership-probe API that would hash a
        # caller key; assert none exists.
        self.assertFalse(hasattr(rc, "is_protected"))
        self.assertFalse(hasattr(rc, "check_capability"))
        self.assertFalse(hasattr(rc, "has_capability"))
        self.assertFalse(hasattr(rc, "grant"))


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
