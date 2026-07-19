"""Runnable safety demonstration.

Run with::

    python -m tonoit_release_control_v5.safety_demo

It exercises the hardened surface against adversarial, exact-type-but-malformed
tuple-backed instances and asserts every safety invariant holds.  It performs no
network, storage, or schema I/O -- only assertions and stdout printing -- and
exits non-zero if any invariant is violated.
"""

from __future__ import annotations

import sys

from . import (
    CANONICAL_CONFIG,
    AuditReceipt,
    EvaluationContext,
    ReleaseConfig,
    evaluate,
    is_released,
    is_valid_audit_receipt,
    is_valid_evaluation_context,
    is_valid_release_config,
    protected_capabilities,
    serialize_config,
    telemetry_of,
)


class _HashTrap:
    def __hash__(self):
        raise AssertionError("hostile __hash__ executed")

    def __eq__(self, other):
        raise AssertionError("hostile __eq__ executed")


class _CallTrap:
    def __call__(self, *a, **k):
        raise AssertionError("callable backdoor invoked")


def _forge(model, values):
    return tuple.__new__(model, tuple(values))


def main() -> int:
    checks = []

    def ok(label, cond):
        checks.append((label, bool(cond)))

    # 1. Malformed exact-type instances are rejected by every validator.
    empty_cfg = _forge(ReleaseConfig, ())
    short_ctx = _forge(EvaluationContext, [1, 2])
    forged_receipt = _forge(AuditReceipt, [object()] * len(AuditReceipt._fields))
    ok("empty config rejected", is_valid_release_config(empty_cfg) is False)
    ok("short context rejected", is_valid_evaluation_context(short_ctx) is False)
    ok("forged receipt rejected", is_valid_audit_receipt(forged_receipt) is False)

    # 2. Engine stays total & default-off on malformed input (no IndexError).
    receipt = evaluate(empty_cfg, short_ctx)
    ok("evaluate returns valid receipt", is_valid_audit_receipt(receipt))
    ok("malformed -> not released", receipt.released is False)
    ok("is_released default-off", is_released(empty_cfg, short_ctx) is False)

    # 3. Hostile keys / callables are never executed.
    hostile_cfg = _forge(
        ReleaseConfig, ["n", True, False, 1, 1, 1.0, 1, _HashTrap()]
    )
    ok("hostile-key config rejected", is_valid_release_config(hostile_cfg) is False)
    ok("serialize hostile config safe", serialize_config(hostile_cfg)["valid"] == 0)
    call_cfg = _forge(ReleaseConfig, [_CallTrap()] * len(ReleaseConfig._fields))
    ok("callable-field config rejected", is_valid_release_config(call_cfg) is False)

    # 4. Telemetry is finite scalar-only and echo-free.
    good = evaluate(
        CANONICAL_CONFIG,
        EvaluationContext(1, 1, True, 100.0, 0.0, "stable"),
    )
    tel = telemetry_of(good)
    ok("released on canonical", good.released is True)
    ok("telemetry scalar-only", all(isinstance(v, (int, float)) for v in tel.values()))
    ok("telemetry has no strings", all(not isinstance(v, str) for v in tel.values()))

    # 5. Protected capabilities are read-only; no grant authority.
    caps = protected_capabilities()
    ok("protected capabilities frozen", isinstance(caps, frozenset) and len(caps) > 0)

    passed = sum(1 for _, c in checks if c)
    for label, cond in checks:
        print(f"[{'PASS' if cond else 'FAIL'}] {label}")
    print(f"\n{passed}/{len(checks)} invariants held")
    return 0 if passed == len(checks) else 1


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
