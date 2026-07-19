"""Deep immutability of models and public constants; no runtime wiring."""

from __future__ import annotations

import sys
import unittest

import tonoit_release_control_v5 as rc


class TestImmutability(unittest.TestCase):
    def test_models_have_no_instance_dict(self):
        for model in (rc.ReleaseConfig, rc.EvaluationContext, rc.AuditReceipt):
            self.assertEqual(model.__slots__, ())

    def test_cannot_set_attribute_on_instance(self):
        c = rc.CANONICAL_CONFIG
        with self.assertRaises(AttributeError):
            c.enabled = False  # type: ignore[misc]

    def test_cannot_mutate_tuple_slots(self):
        c = rc.CANONICAL_CONFIG
        with self.assertRaises(TypeError):
            c[0] = "x"  # type: ignore[index]

    def test_public_constants_are_immutable_types(self):
        self.assertIsInstance(rc.PROTECTED_CAPABILITIES, frozenset)
        self.assertIsInstance(rc.CANONICAL_CONFIG, rc.ReleaseConfig)
        self.assertIsInstance(rc.VERSION, str)
        with self.assertRaises(AttributeError):
            rc.PROTECTED_CAPABILITIES.add("x")  # type: ignore[attr-defined]

    def test_capabilities_field_is_frozenset(self):
        self.assertIsInstance(rc.CANONICAL_CONFIG.capabilities, frozenset)

    def test_canonical_config_is_valid_and_releasable(self):
        self.assertIs(rc.is_valid_release_config(rc.CANONICAL_CONFIG), True)


class TestNoRuntimeWiring(unittest.TestCase):
    def test_package_imports_no_network_or_storage_module(self):
        pkg_mods = [
            m for m, mod in sys.modules.items()
            if m.startswith("tonoit_release_control_v5") and mod is not None
        ]
        forbidden = {
            "socket", "ssl", "sqlite3", "http", "http.client",
            "urllib.request", "asyncio", "subprocess",
        }
        for name in pkg_mods:
            mod = sys.modules[name]
            imported = set(getattr(mod, "__dict__", {}).keys())
            for f in forbidden:
                top = f.split(".")[0]
                self.assertNotIn(
                    top, imported,
                    f"{name} imported forbidden module {f}",
                )

    def test_no_dunder_all_leaks_private(self):
        for name in rc.__all__:
            self.assertFalse(name.startswith("_"))


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
