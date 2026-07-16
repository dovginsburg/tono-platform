#!/usr/bin/env python3
"""Fail CI on gitlinks, nested repositories, secrets-by-name, or generated source."""
from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FORBIDDEN = [
    re.compile(r"(^|/)\.gradle/"),
    re.compile(r"(^|/)build/"),
    re.compile(r"(^|/)DerivedData/"),
    re.compile(r"(^|/)\.env($|\.)"),
    re.compile(r"(^|/).*credentials.*\.json$", re.I),
    re.compile(r"(^|/)keystore\.properties$", re.I),
    re.compile(r"\.(?:keystore|jks|p8|p12|mobileprovision|key|csr)$", re.I),
    re.compile(r"\.(?:db|db-wal|db-shm)$", re.I),
]


def git(*args: str) -> str:
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True)


def main() -> int:
    failures: list[str] = []
    stage = git("ls-files", "-s").splitlines()
    for line in stage:
        mode, _, _, path = line.split(maxsplit=3)
        if mode == "160000":
            failures.append(f"gitlink: {path}")
        if any(pattern.search(path) for pattern in FORBIDDEN):
            failures.append(f"forbidden tracked path: {path}")

    for directory, names, _ in os.walk(ROOT):
        here = Path(directory)
        if here == ROOT and ".git" in names:
            names.remove(".git")
        if ".git" in names:
            failures.append(f"nested Git directory: {(here / '.git').relative_to(ROOT)}")
            names.remove(".git")

    mapping = json.loads((ROOT / "docs/provenance/history-map.json").read_text())
    for item in mapping["imports"]:
        commit = item["imported_head"]
        exists = subprocess.run(
            ["git", "cat-file", "-e", f"{commit}^{{commit}}"], cwd=ROOT, capture_output=True
        )
        if exists.returncode:
            failures.append(f"missing imported commit: {item['component']} {commit}")
        tree = git("ls-tree", "-r", "--name-only", commit)
        if not any(path == item["root"] or path.startswith(item["root"] + "/") for path in tree.splitlines()):
            failures.append(f"imported root absent: {item['component']} {item['root']}")

    for verifier in (
        "apps/ios/Scripts/verify_messages_extension.py",
        "apps/ios/Scripts/verify_imessage_appintent_contract.py",
    ):
        check = subprocess.run(
            ["python3", str(ROOT / verifier)],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        if check.returncode:
            failures.append(check.stdout.strip() or check.stderr.strip())

    if failures:
        print("\n".join(failures))
        return 1
    print(f"source hygiene ok: {len(stage)} tracked entries; {len(mapping['imports'])} imports verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
