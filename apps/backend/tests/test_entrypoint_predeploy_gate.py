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
    # `chmod` joins the shim set because the entrypoint now normalises the
    # /data/backups directory mode. Stubbing it keeps this test daemon-free and
    # host-safe (no real chown/chmod ever touches the machine).
    for name in ("mkdir", "chown", "chmod", "python", "uvicorn", "pytest"):
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


# ---------------------------------------------------------------------------
# /data/backups permission prep — the fix for the exact Render deploy blocker
# `predeploy backup: aborting deploy — unable to open database file` on a warm
# volume carrying a pre-existing ROOT-OWNED /data/backups. The real ownership
# proof is the opt-in Docker smoke (scripts/ci/docker_backups_permission_smoke.sh);
# these are the fast, daemon-free contract guarantees that the entrypoint issues
# the narrow, ordered, non-recursive fix so a regression is caught in the normal
# suite.
# ---------------------------------------------------------------------------

def _backups_calls(calls):
    """Index every recorded command that targets the /data/backups directory
    itself (never a file underneath it)."""
    mkdir = [i for i, c in enumerate(calls) if c.startswith("mkdir ") and c.rstrip().endswith("/data/backups")]
    chown = [
        i for i, c in enumerate(calls)
        if c.startswith("chown ") and c.rstrip().endswith("/data/backups") and "tono:tono" in c
    ]
    chmod = [
        i for i, c in enumerate(calls)
        if c.startswith("chmod ") and c.rstrip().endswith("/data/backups") and "0700" in c
    ]
    return mkdir, chown, chmod


def test_backups_dir_created_owned_and_moded_before_predeploy():
    """On the uvicorn boot path the entrypoint must, as root, create
    /data/backups and set its ownership (tono:tono) + mode (0700) BEFORE it
    drops to `tono` and runs the predeploy backup. Otherwise a warm, root-owned
    /data/backups makes the tono-run backup fail with 'unable to open database
    file' and aborts the deploy."""
    import tempfile

    with tempfile.TemporaryDirectory() as d:
        proc, calls = _run_entrypoint(
            Path(d),
            ["uvicorn", "backend.server:app", "--host", "0.0.0.0", "--workers", "1"],
        )

    assert proc.returncode == 0, proc.stderr
    mkdir, chown, chmod = _backups_calls(calls)
    predeploy = [i for i, c in enumerate(calls) if c.startswith("python ") and "predeploy_backup" in c]

    assert mkdir, f"entrypoint never created /data/backups: {calls}"
    assert chown, f"entrypoint never chowned /data/backups to tono:tono: {calls}"
    assert chmod, f"entrypoint never set /data/backups mode to 0700: {calls}"
    assert predeploy, f"predeploy never ran: {calls}"

    # The whole point: the ownership+mode fix must precede the tono-run predeploy
    # that writes the snapshot into that directory.
    assert max(mkdir[0], chown[0], chmod[0]) < predeploy[0], (
        f"/data/backups must be prepared BEFORE predeploy runs: {calls}"
    )


def test_backups_fix_is_never_recursive():
    """The repair must target the single /data/backups directory, never a
    recursive `chown -R`/`chmod -R` across the volume — that could rewrite
    ownership of unrelated large trees or the snapshot files' own metadata."""
    import tempfile

    with tempfile.TemporaryDirectory() as d:
        proc, calls = _run_entrypoint(
            Path(d),
            ["uvicorn", "backend.server:app", "--host", "0.0.0.0", "--workers", "1"],
        )

    assert proc.returncode == 0, proc.stderr
    for c in calls:
        if c.startswith(("chown ", "chmod ")):
            assert "-R" not in c and "--recursive" not in c, f"recursive ownership change is forbidden: {c!r}"


def test_backups_prep_runs_even_on_non_uvicorn_path():
    """Volume ownership normalisation (including /data/backups) is unconditional
    — it runs for any command — while the predeploy GATE stays uvicorn-only. A
    maintenance/one-off invocation of the image must not be able to leave a
    root-owned /data/backups behind for the next boot to trip over."""
    import tempfile

    with tempfile.TemporaryDirectory() as d:
        proc, calls = _run_entrypoint(Path(d), ["pytest", "-q"])

    assert proc.returncode == 0, proc.stderr
    _, chown, chmod = _backups_calls(calls)
    assert chown and chmod, f"/data/backups ownership+mode fix should run on any command: {calls}"
    assert not any("predeploy_backup" in c for c in calls), (
        f"predeploy gate must remain uvicorn-only: {calls}"
    )
