"""Import isolation: in a clean subprocess the package performs no I/O and pulls
in no networking / subprocess / database modules."""
import os
import subprocess
import sys
import unittest

_PKG_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

_PROBE_HOOKS = r"""
import builtins
def _blocked(*args, **kwargs):
    raise AssertionError("release-control attempted I/O")
builtins.open = _blocked
import socket, subprocess
socket.socket = _blocked
socket.create_connection = _blocked
subprocess.Popen = _blocked

import release_control_successor_v2 as rc

config = rc.ReleaseConfig({"f": {"percentage": 100, "issued_at": 0, "ttl_seconds": 1000}})
context = rc.EvaluationContext(build=1, schema=1, now=1, cohort="c", ready=True, kill_switch=False)
decision = rc.evaluate("f", config, rc.Entitlement(["f"]), context)
assert decision.allowed
assert rc.validate_decision(decision.to_dict())
assert rc.validate_telemetry(decision.to_telemetry().to_dict())
assert rc.validate_audit_receipt(decision.to_audit_receipt().to_dict())
receipt = rc.RollbackReceipt(rc.RollbackMode.HALT, rc.CapabilityClass.STANDARD, rc.Reason.ROLLOUT)
assert rc.validate_rollback_receipt(receipt.to_dict())
print("PROBE_HOOKS_OK")
"""

_PROBE_MODULES = r"""
import sys
before = set(sys.modules)
import release_control_successor_v2  # noqa: F401
delta = set(sys.modules) - before
FORBIDDEN = {
    "socket", "ssl", "subprocess", "asyncio", "selectors", "select",
    "http", "urllib", "ftplib", "smtplib", "poplib", "imaplib",
    "telnetlib", "sqlite3", "socketserver", "xmlrpc", "ctypes",
    "multiprocessing", "webbrowser", "logging",
}
bad = sorted(m for m in delta if m.split(".")[0] in FORBIDDEN)
assert not bad, "package imported I/O modules: %r" % (bad,)
print("PROBE_MODULES_OK")
"""


class ImportNoIoTest(unittest.TestCase):
    def _run(self, probe):
        env = dict(os.environ)
        env["PYTHONPATH"] = _PKG_ROOT + os.pathsep + env.get("PYTHONPATH", "")
        return subprocess.run(
            [sys.executable, "-c", probe],
            cwd=_PKG_ROOT,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
        )

    def test_no_io_on_import_and_evaluation(self):
        result = self._run(_PROBE_HOOKS)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PROBE_HOOKS_OK", result.stdout)

    def test_no_io_modules_imported(self):
        result = self._run(_PROBE_MODULES)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PROBE_MODULES_OK", result.stdout)


if __name__ == "__main__":
    unittest.main()
