#!/usr/bin/env python3
"""Safety demonstration for tonoit release-control (successor-v3).

Self-contained and I/O-free. Run with the package on the path::

    PYTHONPATH=src python3 safety_demo.py

Exits 0 iff every safety invariant holds. Prints a scalar-only summary; it
never echoes caller strings/ids and performs no I/O or network access.
"""

from __future__ import annotations

import sys

import tonoit_release_control as rc

NOW = 1_000_000.0
FUTURE = 2_000_000.0
PROTECTED = ("safety", "help", "export", "delete", "recovery")


class _HostileKey:
    def __hash__(self):
        return 0x5EED

    def __eq__(self, other):
        raise RuntimeError("hostile __eq__")


def _ctx(subject="demo-subject", **kw):
    return rc.EvaluationContext(subject, now=NOW, **kw)


def main():
    checks = []

    def check(label, cond):
        checks.append((label, bool(cond)))

    # 1. Default-off: unknown flags never release.
    empty = rc.ReleaseConfig()
    check("unknown flag default-off", not rc.is_released(empty, "ghost", _ctx()))

    # 2. Explicitly enabled flag releases within a valid TTL.
    enabled = rc.ReleaseConfig(
        rules=(rc.ReleaseRule("beta", cohort=100, expires_at=FUTURE),)
    )
    check("enabled flag releases", rc.is_released(enabled, "beta", _ctx()))

    # 3. Kill switch overrides everything.
    killed = rc.ReleaseConfig(
        rules=(rc.ReleaseRule("beta", cohort=100, expires_at=FUTURE),), killed=True
    )
    check("kill switch blocks", not rc.is_released(killed, "beta", _ctx()))

    # 4. Expired TTL fails closed.
    stale = rc.ReleaseConfig(
        rules=(rc.ReleaseRule("beta", cohort=100, expires_at=NOW - 1.0),)
    )
    check("expired TTL blocks", not rc.is_released(stale, "beta", _ctx()))

    # 5. Protected capabilities always available, even with kill + invalid ctx.
    protected_ok = all(
        rc.is_capability_available(killed, cap, None) for cap in PROTECTED
    )
    check("protected capabilities preserved", protected_ok)

    # 6. Release control never grants entitlements.
    check("no entitlement grant", rc.release_grants_entitlements() is False)

    # 7. Hostile-keyed dict never raises and enables nothing.
    raised = False
    try:
        hostile_cfg = rc.ReleaseConfig(flags={_HostileKey(): True, "beta": True})
    except Exception:
        raised = True
        hostile_cfg = rc.ReleaseConfig()
    check("hostile dict does not raise", not raised)
    check("hostile dict enables nothing", not rc.is_released(hostile_cfg, "beta", _ctx()))

    # 8. Validators fail closed on hostile dicts without raising.
    validators_ok = True
    try:
        validators_ok = (
            not rc.is_valid_config({_HostileKey(): 1})
            and not rc.is_valid_rule({_HostileKey(): 1})
        )
    except Exception:
        validators_ok = False
    check("validators fail closed", validators_ok)

    # 9. Immutability: direct assignment fails.
    rule = rc.ReleaseRule("beta", cohort=50)
    immutable = False
    try:
        rule.cohort = 100  # noqa: B010
    except (AttributeError, TypeError):
        immutable = True
    check("models are immutable", immutable)

    # 10. Bounded credential scan: clean in-memory input -> zero findings.
    clean = rc.scan_credentials(["def evaluate(cfg, flag, ctx): return True"])
    check("credential scan clean", clean["findings"] == 0)

    # 11. Telemetry is finite scalar-only with no caller echoes.
    dec = rc.evaluate(enabled, "beta", _ctx())
    tel = rc.telemetry_of(dec)
    scalar_only = all(type(v) in (bool, int, float, str) for v in tel.values())
    no_echo = all(
        ("beta" not in v and "demo-subject" not in v)
        for v in tel.values()
        if type(v) is str
    )
    check("telemetry scalar-only, no echo", scalar_only and no_echo)

    passed = sum(1 for _, ok in checks if ok)
    total = len(checks)
    for label, ok in checks:
        print("  [%s] %s" % ("PASS" if ok else "FAIL", label))
    print("SAFETY DEMO: %d/%d checks passed" % (passed, total))
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
