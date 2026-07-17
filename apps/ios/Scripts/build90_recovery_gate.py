#!/usr/bin/env python3
"""Build-90 charged-before-upgrade release prerequisite gate (fail closed).

Build 91's server can only claim a build-90 StoreKit purchase AFTER the user
upgrades and the client uploads its signed transaction. It cannot protect an
immutable build-90 client that was charged but never upgrades / never uploads
proof. Closing that prior P0 therefore requires an EXTERNAL fact that build-91
code cannot itself prove (contract §5 / hostile 20):

  (a) checkout-disabled evidence — provider/TestFlight proof that build 90 can no
      longer initiate checkout, OR
  (b) an owner-approved, explicitly bounded charged-before-upgrade recovery
      policy.

This module is the executable gate wired into the build-91 verification path
(`verify_build91_entitlement_contract.py`). It reads a versioned release-
readiness artifact plus an optional operator-supplied evidence file and returns
READY only when one of the two evidence forms is present AND complete. With
neither supplied it FAILS CLOSED. It deliberately cannot fabricate evidence: a
`supplied: true` flag without the corroborating fields is rejected.

Zero third-party dependencies so it runs in the same zero-install lane as the
other verifiers.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any, Optional

ROOT = Path(__file__).resolve().parents[1]  # apps/ios
DEFAULT_ARTIFACT = ROOT / "AppStore" / "build91_release_readiness.json"
EVIDENCE_ENV = "TONO_BUILD90_RECOVERY_EVIDENCE"


class ReadinessResult:
    def __init__(self, ready: bool, reasons: list[str], evidence_source: Optional[str]):
        self.ready = ready
        self.reasons = reasons
        self.evidence_source = evidence_source

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return f"ReadinessResult(ready={self.ready}, source={self.evidence_source!r}, reasons={self.reasons})"


def _nonempty_str(value: Any) -> bool:
    return isinstance(value, str) and value.strip() != ""


def _checkout_disabled_valid(block: Any) -> tuple[bool, list[str]]:
    """Provider/TestFlight evidence that build 90 can no longer start checkout."""
    if not isinstance(block, dict) or not block.get("supplied"):
        return False, []
    missing = [
        field
        for field in ("source", "verified_by", "verified_at", "reference")
        if not _nonempty_str(block.get(field))
    ]
    if missing:
        return False, [f"checkout_disabled evidence marked supplied but missing: {', '.join(missing)}"]
    return True, []


def _charged_policy_valid(block: Any) -> tuple[bool, list[str]]:
    """Owner-approved, explicitly bounded charged-before-upgrade recovery policy."""
    if not isinstance(block, dict) or not block.get("supplied"):
        return False, []
    reasons: list[str] = []
    missing = [
        field
        for field in ("approved_by", "approved_at", "policy_reference")
        if not _nonempty_str(block.get(field))
    ]
    if not block.get("owner_approved"):
        reasons.append("charged_before_upgrade_policy is not owner_approved")
    window = block.get("bounded_window_days")
    if not isinstance(window, int) or isinstance(window, bool) or window <= 0:
        reasons.append("charged_before_upgrade_policy needs a positive integer bounded_window_days")
    if missing:
        reasons.append(
            f"charged_before_upgrade_policy marked supplied but missing: {', '.join(missing)}"
        )
    return (not reasons), reasons


def _evaluate_evidence(evidence: Any, origin: str) -> tuple[bool, list[str]]:
    if not isinstance(evidence, dict):
        return False, [f"{origin}: no evidence object"]
    reasons: list[str] = []
    ok_checkout, checkout_reasons = _checkout_disabled_valid(evidence.get("checkout_disabled"))
    ok_policy, policy_reasons = _charged_policy_valid(evidence.get("charged_before_upgrade_policy"))
    reasons.extend(f"{origin}: {r}" for r in checkout_reasons + policy_reasons)
    return (ok_checkout or ok_policy), reasons


def evaluate(artifact: dict, env: Optional[dict] = None) -> ReadinessResult:
    """Return READY only if the artifact OR an operator-supplied evidence file
    carries one complete evidence form. Fails closed otherwise."""
    env = os.environ if env is None else env
    reasons: list[str] = []

    # 1. Operator-supplied out-of-band evidence file (so real evidence need not
    #    be committed to the tracked artifact). If the env var is set it MUST
    #    resolve to a readable, valid evidence file — a broken pointer fails
    #    closed rather than being silently ignored.
    evidence_path = env.get(EVIDENCE_ENV, "").strip()
    if evidence_path:
        try:
            supplied = json.loads(Path(evidence_path).read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            return ReadinessResult(False, [f"{EVIDENCE_ENV} set but unreadable: {exc}"], None)
        ok, why = _evaluate_evidence(supplied.get("evidence", supplied), EVIDENCE_ENV)
        reasons.extend(why)
        if ok:
            return ReadinessResult(True, reasons, EVIDENCE_ENV)

    # 2. Evidence embedded in the tracked artifact.
    ok, why = _evaluate_evidence(artifact.get("evidence"), "artifact")
    reasons.extend(why)
    if ok:
        return ReadinessResult(True, reasons, "artifact")

    reasons.append(
        "build-90 charged-before-upgrade prerequisite UNRESOLVED: supply either "
        "checkout-disabled provider/TestFlight evidence or an owner-approved bounded "
        f"recovery policy (in {DEFAULT_ARTIFACT.name} or via {EVIDENCE_ENV})"
    )
    return ReadinessResult(False, reasons, None)


def load_artifact(path: Optional[Path] = None) -> dict:
    path = path or DEFAULT_ARTIFACT
    return json.loads(Path(path).read_text(encoding="utf-8"))


def main() -> int:
    try:
        artifact = load_artifact()
    except (OSError, ValueError) as exc:
        print(f"build90-recovery-gate: FAIL: cannot read readiness artifact: {exc}")
        return 1
    result = evaluate(artifact, os.environ)
    if result.ready:
        print(f"build90-recovery-gate: READY (evidence via {result.evidence_source})")
        return 0
    print("build90-recovery-gate: NOT READY (fail closed)")
    for reason in result.reasons:
        print(f"  - {reason}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
