"""Contract test for `apps/backend/docker-entrypoint.sh`'s predeploy gate.

The heavy, real-container proof is `scripts/ci/docker_cold_volume_smoke.sh`
(opt-in, Docker required). This test is the fast, daemon-free guarantee that the
ORDERING contract holds, so a regression that dropped or reordered the gate is
caught in the normal suite:

  1. On the uvicorn boot path the entrypoint runs the predeploy backup BEFORE it
     execs uvicorn.
  2. If the predeploy backup exits nonzero (corrupt DB / integrity failure), the
     entrypoint FAILS CLOSED — uvicorn is never started and the script exits
     nonzero, so a platform health check fails the deploy.
  3. For any non-uvicorn command (e.g. running the test suite in the image) the
     predeploy gate does NOT run.

It works by putting recording stubs for `mkdir`, `chown`, `gosu`, `python`, and
`uvicorn` on PATH, so the entrypoint executes verbatim without root, a real
`/data`, or the app's dependencies.
"""

from __future__ import annotations

import os
import shutil
import stat
import subprocess
from pathlib import Path

import pytest

ENTRYPOINT = Path(__file__).resolve().parents[1] / "docker-entrypoint.sh"

# A single recording shim, symlinked/copied to each command name. It appends
# "<name> <args>" to $ENTRY_CALLLOG. `python` (the predeploy invocation) honours
# $PREDEPLOY_EXIT so the fail-closed branch can be forced; everything else is a
# no-op success (mkdir/chown must not touch the host).
_SHIM = """#!/bin/sh
name=$(basename "$0")
printf '%s %s\\n' "$name" "$*" >> "$ENTRY_CALLLOG"
if [ "$name" = "python" ]; then
    exit "${PREDEPLOY_EXIT:-0}"
fi
exit 0
"""

# gosu drops the username arg and execs the rest, mirroring the real gosu so the
# command it wraps (python / uvicorn / pytest) is what actually runs.
_GOSU = """#!/bin/sh
shift
exec "$@"
"""


def _make_stub(path: Path, body: str) -> None:
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


def _run_entrypoint(tmp_path: Path, argv: list[str], *, predeploy_exit: int = 0):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for name in ("mkdir", "chown", "python", "uvicorn", "pytest"):
        _make_stub(bin_dir / name, _SHIM)
    _make_stub(bin_dir / "gosu", _GOSU)

    calllog = tmp_path / "calls.log"
    env = {
        "PATH": f"{bin_dir}:/usr/bin:/bin",
        "ENTRY_CALLLOG": str(calllog),
        "PREDEPLOY_EXIT": str(predeploy_exit),
        "PORT": "8765",
    }
    proc = subprocess.run(
        ["/bin/sh", str(ENTRYPOINT), *argv],
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )
    calls = calllog.read_text().splitlines() if calllog.exists() else []
    return proc, calls


pytestmark = pytest.mark.skipif(
    os.name == "nt" or shutil.which("sh") is None,
    reason="entrypoint is a POSIX sh script",
)


def test_predeploy_runs_before_uvicorn():
    import tempfile

    with tempfile.TemporaryDirectory() as d:
        proc, calls = _run_entrypoint(
            Path(d),
            ["uvicorn", "backend.server:app", "--host", "0.0.0.0", "--workers", "1"],
        )

    assert proc.returncode == 0, proc.stderr
    predeploy = [i for i, c in enumerate(calls) if c.startswith("python ") and "predeploy_backup" in c]
    uvicorn = [i for i, c in enumerate(calls) if c.startswith("uvicorn ")]
    assert predeploy, f"predeploy backup never ran: {calls}"
    assert uvicorn, f"uvicorn never started: {calls}"
    assert predeploy[0] < uvicorn[0], f"predeploy must precede uvicorn: {calls}"
    # The port the entrypoint appends is exactly ${PORT} expanded once.
    assert any("--port 8765" in c for c in calls), calls


def test_fail_closed_when_predeploy_errors():
    import tempfile

    with tempfile.TemporaryDirectory() as d:
        proc, calls = _run_entrypoint(
            Path(d),
            ["uvicorn", "backend.server:app", "--host", "0.0.0.0", "--workers", "1"],
            predeploy_exit=1,
        )

    assert proc.returncode != 0, "a failed predeploy backup must abort boot"
    assert any("predeploy_backup" in c for c in calls), calls
    assert not any(c.startswith("uvicorn ") for c in calls), (
        f"uvicorn must NOT start after a failed predeploy: {calls}"
    )


def test_non_uvicorn_command_skips_predeploy():
    import tempfile

    with tempfile.TemporaryDirectory() as d:
        proc, calls = _run_entrypoint(Path(d), ["pytest", "-q"])

    assert proc.returncode == 0, proc.stderr
    assert any(c.startswith("pytest ") for c in calls), calls
    assert not any("predeploy_backup" in c for c in calls), (
        f"predeploy gate must only run on the uvicorn boot path: {calls}"
    )
