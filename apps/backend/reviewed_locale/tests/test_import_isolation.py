"""The package is inert: importing it pulls in no heavy/product modules and runs
no side effects. Verified in a fresh interpreter so the check is not polluted by
whatever the test runner already imported."""

from __future__ import annotations

import pathlib
import subprocess
import sys
import unittest

_APPS = pathlib.Path(__file__).resolve().parents[3]

_PROBE = r"""
import sys
import backend.reviewed_locale as m
from backend.reviewed_locale import evaluate_candidate, Decision

banned = {
    "httpx", "fastapi", "pydantic", "stripe", "jwt", "starlette",
    "backend.server", "backend.analyze", "backend.store", "backend.payments",
    "backend.slack", "backend.rate_limit",
}
leaked = sorted(banned & set(sys.modules))
assert not leaked, "reviewed_locale import leaked heavy modules: %s" % leaked
assert m.__version__.endswith("inert")
print("ISOLATED_OK")
"""


class ImportIsolation(unittest.TestCase):
    def test_import_is_inert_and_pulls_no_heavy_modules(self):
        proc = subprocess.run(
            [sys.executable, "-c", _PROBE],
            cwd=str(_APPS.parent),
            env={"PYTHONPATH": str(_APPS), "PATH": "/usr/bin:/bin"},
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("ISOLATED_OK", proc.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
