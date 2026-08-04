"""Opt-in pytest entry point for the Docker warm-volume backups-permission smoke.

Reproduces the exact Render deploy blocker — a warm persistent volume carrying a
ROOT-OWNED ``/data/backups`` that aborts the unprivileged ``tono`` predeploy
backup with ``unable to open database file`` — proves the entrypoint repair
(directory made tono-writable without a recursive chown or any content change),
and proves the integrity gate still fails closed on a corrupt DB.

Building an image and cold/warm-starting containers is too heavy (and needs a
Docker daemon) for the default unit suite, so this is OPT-IN:

    TONO_RUN_DOCKER_SMOKE=1 python -m pytest tests/test_docker_backups_permission.py

Without the opt-in (or without a Docker daemon) it skips cleanly. The actual
scenario lives in the auditable, standalone script
``scripts/ci/docker_backups_permission_smoke.sh`` so it can also run directly in
CI.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
SMOKE = REPO_ROOT / "scripts" / "ci" / "docker_backups_permission_smoke.sh"


def _docker_available() -> bool:
    if not shutil.which("docker"):
        return False
    try:
        return subprocess.run(
            ["docker", "info"], capture_output=True, timeout=15
        ).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


@pytest.mark.skipif(
    os.environ.get("TONO_RUN_DOCKER_SMOKE") != "1",
    reason="opt-in only: set TONO_RUN_DOCKER_SMOKE=1 to run the Docker backups-permission smoke",
)
def test_docker_backups_permission_smoke():
    assert SMOKE.exists(), f"smoke script missing: {SMOKE}"
    if not _docker_available():
        pytest.skip("docker daemon not available")
    proc = subprocess.run(
        ["bash", str(SMOKE)], cwd=REPO_ROOT, capture_output=True, text=True, timeout=900
    )
    assert proc.returncode == 0, (
        "docker backups-permission smoke failed:\n"
        + proc.stdout[-4000:] + "\n--- stderr ---\n" + proc.stderr[-2000:]
    )
    assert "SMOKE PASS" in proc.stdout
