#!/usr/bin/env python3
"""verify_build111_coach_reconnect.py

Source-level contract gate for the Build-111 Coach connectivity recovery.

WHY THIS EXISTS
Build 110 issued Coach requests on `URLSession.shared`, whose configuration has
`waitsForConnectivity == false`. An absent route was therefore a TERMINAL
outcome, and the physical report was:

    "I turned off internet connection and then turned it back on and I think
     the Tono coach didn't reconnect automatically to server."

The behavioural proof lives in `Tests/Build111CoachReconnectTests.swift`, which
needs a simulator. This script is the no-simulator gate for the properties that
are structural rather than behavioural — the ones a future refactor could
quietly undo without failing a behavioural test:

  1. WAITS, BOUNDED       the keyboard wires a connectivity-aware transport with
                          both a request and a resource timeout.
  2. DEADLINE ORDERING    connected deadline < resource budget < offline
                          deadline, so the transport's truthful error lands
                          before the watchdog, and the wait is bounded.
  3. NO SINGLETON         no global reachability object and no free-running
                          timer/observer in the keyboard extension.
  4. NO REPLAY            exactly two `task.resume()` sites in the client — one
                          per public entry point — and no retry construct
                          anywhere. An ambiguous midflight failure must never be
                          replayed: that POST may already have billed a provider
                          call and generated a rewrite.
  5. NO SHARED SESSION    the Coach client must not fall back to
                          `URLSession.shared`, whose configuration cannot wait.

Usage (from apps/ios):  python3 Scripts/verify_build111_coach_reconnect.py
Exits 0 on success, non-zero on any failure. No network, no simulator, no
Xcode project, no signing.
"""

from __future__ import annotations

import pathlib
import re
import sys

IOS_ROOT = pathlib.Path(__file__).resolve().parent.parent
CLIENT = IOS_ROOT / "KeyboardExtension" / "TonoCoachClient.swift"
CONTROLLER = IOS_ROOT / "KeyboardExtension" / "KeyboardViewController.swift"

failures: list[str] = []
checks = 0


def check(condition: bool, message: str) -> None:
    global checks
    checks += 1
    if not condition:
        failures.append(message)


def strip_comments(source: str) -> str:
    """Drop // line comments so a doc comment that DESCRIBES a forbidden symbol
    is never mistaken for the symbol being used. These files legitimately
    document what Build 110 did wrong."""
    out = []
    for line in source.splitlines():
        idx = line.find("//")
        out.append(line if idx < 0 else line[:idx])
    return "\n".join(out)


def constant(name: str, source: str) -> float | None:
    match = re.search(rf"let\s+{re.escape(name)}\s*:\s*TimeInterval\s*=\s*([0-9.]+)", source)
    return float(match.group(1)) if match else None


def main() -> int:
    for path in (CLIENT, CONTROLLER):
        if not path.is_file():
            print(f"FATAL: missing source file: {path}", file=sys.stderr)
            return 2

    client_raw = CLIENT.read_text(encoding="utf-8")
    controller_raw = CONTROLLER.read_text(encoding="utf-8")
    client = strip_comments(client_raw)
    controller = strip_comments(controller_raw)

    # ── 1. Waits for connectivity, within a bounded budget ──────────────────
    check(
        "waitsForConnectivity" in client,
        "1. the Coach client must configure waitsForConnectivity",
    )
    check(
        "configuration.waitsForConnectivity = waitsForConnectivity" in client,
        "1. the transport policy must apply waitsForConnectivity to its configuration",
    )
    check(
        "configuration.timeoutIntervalForResource = resourceTimeout" in client,
        "1. the connectivity wait must be bounded by a resource timeout",
    )
    check(
        "configuration.timeoutIntervalForRequest = requestTimeout" in client,
        "1. the per-request idle timeout must be set explicitly",
    )
    check(
        "waitsForConnectivity: true" in controller,
        "1. the keyboard must wire the connectivity-aware transport",
    )
    check(
        "resourceTimeout: Const.coachResourceTimeout" in controller,
        "1. the keyboard must pass a bounded resource budget",
    )

    # ── 2. Deadline ordering ────────────────────────────────────────────────
    visible = constant("coachVisibleDeadline", controller_raw)
    resource = constant("coachResourceTimeout", controller_raw)
    offline = constant("coachOfflineVisibleDeadline", controller_raw)
    check(visible is not None, "2. coachVisibleDeadline must exist")
    check(resource is not None, "2. coachResourceTimeout must exist")
    check(offline is not None, "2. coachOfflineVisibleDeadline must exist")
    if None not in (visible, resource, offline):
        check(
            visible < resource,
            f"2. the connected deadline ({visible}s) must be shorter than the "
            f"resource budget ({resource}s)",
        )
        check(
            resource < offline,
            f"2. the transport must fail ({resource}s) before the offline "
            f"watchdog fires ({offline}s)",
        )
        check(
            offline <= 60,
            f"2. a keyboard must not wait {offline}s for one rewrite",
        )

    # ── 3. No reachability singleton, no unbounded observer ─────────────────
    forbidden_globals = [
        "NWPathMonitor",
        "SCNetworkReachability",
        "Reachability(",
        "Timer.scheduledTimer",
        "CFRunLoopTimer",
        "NotificationCenter.default.addObserver",
    ]
    for symbol in forbidden_globals:
        for name, source in (("client", client), ("controller", controller)):
            check(
                symbol not in source,
                f"3. {symbol} in the {name} would be a global/unbounded "
                f"observer in a keyboard extension",
            )
    # The connectivity table must be per-request and explicitly detached.
    check(
        "func detach(" in client and "entries.removeAll" in client,
        "3. connectivity registrations must be detachable so nothing accumulates",
    )
    check(
        "releaseTransportState(transportState)" in client,
        "3. every terminal completion path must release its transport state",
    )
    check(
        client.count("releaseTransportState(transportState)") == 2,
        "3. both entry points (coach + variant) must release their transport state",
    )

    # ── 4. No application-level replay ──────────────────────────────────────
    resumes = client.count("task.resume()")
    check(
        resumes == 2,
        f"4. expected exactly 2 task.resume() sites (coach + variant), found {resumes} "
        f"— a retry loop would duplicate a provider call",
    )
    for symbol in ["retryCount", "recursiveRetry", "while retries", "for attempt in"]:
        check(symbol not in client, f"4. no replay construct may exist: {symbol}")
    # One tap must still bump the 1:1 counter exactly once per entry point.
    check(
        client.count("providerCallCount += 1") == 2,
        "4. the 1 tap → 1 provider call counter must be bumped once per entry point",
    )

    # ── 5. No fallback to the session that cannot wait ──────────────────────
    check(
        "URLSession.shared" not in client,
        "5. the Coach client must not use URLSession.shared — its configuration "
        "cannot wait for connectivity, which is the Build-110 defect",
    )
    check(
        "session: URLSession? = nil" in client,
        "5. the session parameter must default to nil so the client builds its own "
        "connectivity-aware session",
    )
    check(
        "finishTasksAndInvalidate" in client,
        "5. a client-owned session must be invalidated so its delegate is released",
    )

    # ── Report ──────────────────────────────────────────────────────────────
    if failures:
        for message in failures:
            print(f"FAIL: {message}", file=sys.stderr)
        print(
            f"FAILED: {len(failures)} of {checks} checks",
            file=sys.stderr,
        )
        return 1
    print(f"PASS: {checks} checks")
    return 0


if __name__ == "__main__":
    sys.exit(main())
