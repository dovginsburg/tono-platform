"""Import isolation, stdlib-only imports, and no I/O at import or runtime."""

from __future__ import annotations

import ast
import os
import sys
import unittest
from unittest import mock


_PKG = "tonoit_release_control"
_SRC_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "src", _PKG)

# Modules the package is permitted to import (pure stdlib, no I/O at import).
_ALLOWED_IMPORT_ROOTS = frozenset({"__future__", "hashlib", "math", "re"})


def _purge_package():
    for name in list(sys.modules):
        if name == _PKG or name.startswith(_PKG + "."):
            del sys.modules[name]


class ImportIsolationTests(unittest.TestCase):
    def test_source_imports_are_stdlib_only(self):
        roots = set()
        for fname in os.listdir(_SRC_DIR):
            if not fname.endswith(".py"):
                continue
            with open(os.path.join(_SRC_DIR, fname), "r", encoding="utf-8") as fh:
                tree = ast.parse(fh.read(), filename=fname)
            for node in ast.walk(tree):
                if isinstance(node, ast.Import):
                    for alias in node.names:
                        roots.add(alias.name.split(".")[0])
                elif isinstance(node, ast.ImportFrom):
                    if node.level == 0 and node.module:
                        roots.add(node.module.split(".")[0])
        external = roots - _ALLOWED_IMPORT_ROOTS
        # relative imports (level>0) resolve within the package; ignore them
        external = {r for r in external if r and r != _PKG}
        self.assertEqual(external, set(), "unexpected imports: %r" % external)

    def test_import_performs_no_io(self):
        _purge_package()

        def boom_open(*a, **k):
            raise AssertionError("open() called during import")

        def boom_socket(*a, **k):
            raise AssertionError("socket() called during import")

        with mock.patch("builtins.open", boom_open), \
                mock.patch("socket.socket", boom_socket), \
                mock.patch("os.system", lambda *a, **k: (_ for _ in ()).throw(
                    AssertionError("os.system called during import"))):
            import importlib
            mod = importlib.import_module(_PKG)
            self.assertTrue(hasattr(mod, "evaluate"))

    def test_runtime_performs_no_io(self):
        cfg = rc_reload()
        rule = cfg.ReleaseRule("f", cohort=100, expires_at=2_000_000.0)
        config = cfg.ReleaseConfig(rules=(rule,))
        ctx = cfg.EvaluationContext("s", now=1_000_000.0)

        def boom_open(*a, **k):
            raise AssertionError("open() called at runtime")

        with mock.patch("builtins.open", boom_open), \
                mock.patch("socket.socket", lambda *a, **k: (_ for _ in ()).throw(
                    AssertionError("socket at runtime"))):
            dec = cfg.evaluate(config, "f", ctx)
            cfg.telemetry_of(dec)
            cfg.serialize_config(config)
            cfg.scan_credentials(["clean line", "another"])
            self.assertTrue(dec.released)

    def test_package_has_no_dunder_all_leakage(self):
        import importlib
        mod = importlib.import_module(_PKG)
        # Public API is intentionally curated via __all__.
        self.assertTrue(hasattr(mod, "__all__"))
        for name in mod.__all__:
            self.assertTrue(hasattr(mod, name), name)


def rc_reload():
    import importlib
    _purge_package()
    return importlib.import_module(_PKG)


if __name__ == "__main__":
    unittest.main()
