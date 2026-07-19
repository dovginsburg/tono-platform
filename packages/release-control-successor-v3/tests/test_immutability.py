"""Hostile regression 1: no mutation backdoor.

No inherited or public callable ``_set`` / ``_replace`` / ``update`` / item
assignment / direct assignment / descriptor bypass may mutate any model,
config, rule, entitlement, context, decision, or audit receipt after
construction. Every reachable path must fail closed.
"""

from __future__ import annotations

import unittest

import tonoit_release_control as rc


def _sample_instances():
    rule = rc.ReleaseRule("beta", cohort=50, allowlist=("u1",), expires_at=2_000_000.0)
    cfg = rc.ReleaseConfig(flags={"beta": True}, rules=(rule,), killed=False, ready=True)
    ctx = rc.EvaluationContext("subject-1", build=42, schema=3, now=1_000_000.0)
    ent = rc.Entitlement("pro", granted=True)
    dec = rc.evaluate(cfg, "beta", ctx)
    rcpt = rc.audit_receipt(dec)
    return {
        "ReleaseRule": rule,
        "ReleaseConfig": cfg,
        "EvaluationContext": ctx,
        "Entitlement": ent,
        "Decision": dec,
        "AuditReceipt": rcpt,
    }


class ImmutabilityTests(unittest.TestCase):
    def setUp(self):
        self.instances = _sample_instances()

    def test_direct_attribute_assignment_fails(self):
        for name, obj in self.instances.items():
            with self.subTest(model=name):
                with self.assertRaises((AttributeError, TypeError)):
                    obj.flag = "evil"  # noqa: B010
                with self.assertRaises((AttributeError, TypeError)):
                    obj.valid = True  # noqa: B010
                with self.assertRaises((AttributeError, TypeError)):
                    obj.brand_new_attr = 1  # noqa: B010

    def test_object_setattr_bypass_fails(self):
        for name, obj in self.instances.items():
            with self.subTest(model=name):
                with self.assertRaises((AttributeError, TypeError)):
                    object.__setattr__(obj, "flag", "evil")

    def test_delattr_fails(self):
        for name, obj in self.instances.items():
            with self.subTest(model=name):
                with self.assertRaises((AttributeError, TypeError)):
                    delattr(obj, "valid")

    def test_no_instance_dict(self):
        for name, obj in self.instances.items():
            with self.subTest(model=name):
                self.assertFalse(hasattr(obj, "__dict__"))

    def test_no_mutation_helpers(self):
        for name, obj in self.instances.items():
            for helper in ("_set", "_replace", "_make", "update", "setdefault",
                           "clear", "pop", "popitem", "append", "extend", "add"):
                with self.subTest(model=name, helper=helper):
                    self.assertFalse(hasattr(obj, helper))

    def test_item_assignment_fails(self):
        for name, obj in self.instances.items():
            with self.subTest(model=name):
                with self.assertRaises((TypeError, AttributeError)):
                    obj[0] = "evil"

    def test_property_descriptor_set_bypass_fails(self):
        # Reaching the class-level property descriptor and calling __set__
        # directly must still fail (properties are read-only, no setter).
        rule = self.instances["ReleaseRule"]
        desc = type(rule).__dict__["flag"]
        with self.assertRaises(AttributeError):
            desc.__set__(rule, "evil")

    def test_state_unchanged_after_attack(self):
        rule = self.instances["ReleaseRule"]
        before = rule.flag
        for attempt in (
            lambda: setattr(rule, "flag", "evil"),
            lambda: object.__setattr__(rule, "flag", "evil"),
            lambda: rule.__dict__.__setitem__("flag", "evil"),
        ):
            try:
                attempt()
            except Exception:
                pass
        self.assertEqual(rule.flag, before)


if __name__ == "__main__":
    unittest.main()
