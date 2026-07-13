#!/usr/bin/env python3
"""Export the backend OpenAPI document and fail on checked-contract drift."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "apps"))

from backend.server import app  # noqa: E402


def rendered() -> str:
    return json.dumps(app.openapi(), indent=2, sort_keys=True) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    destination = ROOT / "packages/contracts/openapi.json"
    current = rendered()
    if args.check:
        if not destination.exists() or destination.read_text() != current:
            print("OpenAPI contract drift: run scripts/ci/export_openapi.py and review the diff")
            return 1
        print("OpenAPI contract matches checked source")
        return 0
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(current)
    print(destination)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
