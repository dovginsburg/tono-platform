#!/usr/bin/env python3
"""verify_build115_binary_reachability.py — prove Foundation Models is REACHABLE
from the live keyboard controller in a BUILT TonoKeyboard.appex.

Why this is not "is the framework linked".

Build 114's appex already linked `FoundationModels.framework`, and already
contained 80 FoundationModels symbol stubs, because `OnDeviceAppleRewrite.swift`
and `AppleRewriteBridge.swift` compiled into the target. What it did not have was
a call graph. `KeyboardViewController` — the class `Info.plist` names as
`NSExtensionPrincipalClass` — never called any of it; the only caller was
`KeyboardRootView`, a SwiftUI surface the extension compiles and never mounts. So
with the radio off there was no on-device rewrite, and "the framework is linked"
was true and worthless as evidence.

What this checks instead, entirely against the binary:

  1. `FoundationModels.framework` is linked, and linked WEAKLY. The deployment
     target is iOS 17.2; a hard link would stop the extension launching on every
     OS below 26.
  2. Its symbols are imported `weak external`, including `SystemLanguageModel`
     and `LanguageModelSession`, so an older OS resolves them to null.
  3. `KeyboardViewController` DEFINES the Build 115 route functions.
  4. `startLocalCoach` builds a `LocalCoachSetRequest` and dispatches it through
     a `LocalCoachRewriteEngine` existential — i.e. the live controller really
     does hand a request to the on-device engine.
  5. The controller's DEFAULT engine is `AppleRewriteBridge`: its stored-property
     initialiser branches to that class's metadata accessor.
  6. `AppleRewriteBridge` is the only type in the binary that witnesses
     `LocalCoachRewriteEngine`, so (4) can only land on (5).
  7. `OnDeviceAppleRewriteService.probeAvailability` branches to
     `SystemLanguageModel.availability`, and `performRewriteSet` branches to
     `LanguageModelSession.init` — the last link in the chain.

And, since the Build 115 NO-GO repair, the three findings that are visible in a
binary rather than only in source:

  8. F1 — the response-token budget is the DERIVED
     `LocalCoachRoutePolicy.maximumResponseTokens`, and the service's own fixed
     `min(1_024, 180 × axisCount)` helper is gone. That constant was 540 tokens
     for the three-tone set and threw `decodingFailure` on any draft past ~500
     characters.
  9. F4 — the minimum-useful-draft gate is compiled in AND reachable from the
     engine, so a caller that bypassed the route policy still cannot hand the
     model a two-word draft it will answer rather than rewrite.
 10. F2 — no `KeyboardViewController` symbol branches to `TonoAnalytics`, and
     `completeLocalCoach` reaches no analytics or `URLSession` symbol.
     `TonoAnalytics.track` ends in `URLSession.shared.dataTask(…).resume()`, and
     43628d3 called it from both arms of the on-device delivery path.

Run against a Release build. Point it at the .appex or its executable:

    Scripts/verify_build115_binary_reachability.py <TonoKeyboard.appex>
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

FAILURES: list[str] = []


def run(*args: str) -> str:
    return subprocess.run(args, capture_output=True, text=True, check=True).stdout


def check(condition: bool, message: str) -> None:
    if condition:
        print(f"ok    {message}")
    else:
        print(f"FAIL  {message}")
        FAILURES.append(message)


def resolve_binary(raw: str) -> Path:
    path = Path(raw)
    if path.is_dir():
        candidate = path / path.stem
        if not candidate.exists():
            sys.exit(f"{path} has no executable named {path.stem}")
        return candidate
    if not path.exists():
        sys.exit(f"{path} does not exist")
    return path


def disassemble(binary: Path) -> tuple[dict[str, set[str]], dict[str, list[str]]]:
    """Return per-symbol branch targets (stubs resolved) and per-symbol bodies."""
    text = run("otool", "-tV", str(binary)).splitlines()

    # otool annotates a stub branch with "; symbol stub for: <name>" only at some
    # sites. Harvest every annotation in the file first, then resolve the bare
    # `bl 0x…` forms through that map.
    stubs: dict[str, str] = {}
    for line in text:
        match = re.search(r"\b(?:bl|b)\s+(0x[0-9a-f]+)\s*;\s*symbol stub for:\s*(\S+)", line)
        if match:
            stubs[match.group(1)] = match.group(2)

    calls: dict[str, set[str]] = {}
    bodies: dict[str, list[str]] = {}
    current: str | None = None
    for line in text:
        if line.startswith("_$s") and line.rstrip().endswith(":"):
            current = line.rstrip()[:-1]
            calls.setdefault(current, set())
            bodies.setdefault(current, [])
            continue
        if current is None:
            continue
        bodies[current].append(line)
        match = re.search(r"\bbl\s+(0x[0-9a-f]+|\S+)", line)
        if match:
            target = match.group(1)
            calls[current].add(stubs.get(target, target))
    return calls, bodies


def symbols_matching(calls: dict[str, set[str]], needle: str) -> list[str]:
    return [symbol for symbol in calls if needle in symbol]


def branches_from(calls: dict[str, set[str]], needle: str) -> set[str]:
    """Union of branch targets across every symbol whose name contains `needle`
    — Swift splits an async function into `TY0_`/`TQ1_` continuation partials
    and specialises hot paths into `…T` twins, so a single logical function is
    several symbols and the union is the honest view of what it calls."""
    out: set[str] = set()
    for symbol in symbols_matching(calls, needle):
        out |= calls[symbol]
    return out


def main() -> None:
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    binary = resolve_binary(sys.argv[1])
    print(f"binary: {binary}\n")

    # 1. Linked, weakly.
    linked = [line for line in run("otool", "-L", str(binary)).splitlines()
              if "FoundationModels" in line]
    check(bool(linked), "FoundationModels.framework is linked into the extension")
    check(any("weak" in line for line in linked),
          "FoundationModels.framework is WEAK-linked (iOS 17.2 deployment target must still launch)")

    # 2. Weakly imported symbols.
    imported = [line for line in run("nm", "-mu", str(binary)).splitlines()
                if "(from FoundationModels)" in line]
    check(bool(imported), "FoundationModels symbols are imported")
    check(all("weak external" in line for line in imported),
          f"all {len(imported)} FoundationModels imports are weak external")
    for required in ("SystemLanguageModel", "LanguageModelSession"):
        check(any(required in line for line in imported),
              f"{required} is imported by the extension binary")

    # 2b. The class under test is the one the extension actually loads.
    if binary.parent.suffix == ".appex":
        plist = run("/usr/bin/plutil", "-extract",
                    "NSExtension.NSExtensionPrincipalClass", "raw",
                    "-o", "-", str(binary.parent / "Info.plist")).strip()
        check(plist.endswith("KeyboardViewController"),
              f"NSExtensionPrincipalClass is KeyboardViewController (got {plist})")

    # 3-7. Call graph.
    calls, _bodies = disassemble(binary)

    # Only the functions that survive optimisation are asserted by symbol.
    # `startCoachRoute` and `LocalCoachRoutePolicy.decide` are private and small,
    # so Release inlines them into their callers and leaves no `__text` symbol —
    # asserting on their names would be asserting on the optimiser's mood. The
    # routing decision is covered instead by (a) the policy's own static data
    # below and (b) the behavioural tests in Build115LocalCoachTests.
    for name in ("resolveLocalAvailability", "startLocalCoach", "completeLocalCoach"):
        check(bool(symbols_matching(calls, f"ViewControllerC{len(name)}{name}")),
              f"KeyboardViewController defines {name}")
    check(any("LocalCoachRoutePolicy" in symbol for symbol in run("nm", str(binary)).splitlines()),
          "LocalCoachRoutePolicy is compiled into the extension")

    local_request = branches_from(calls, "ViewControllerC15startLocalCoach")
    check(any("LocalCoachSetRequest" in target for target in local_request),
          "startLocalCoach builds a LocalCoachSetRequest")
    check(any("LocalCoachRewriteEngine_p" in target for target in local_request),
          "startLocalCoach dispatches through a LocalCoachRewriteEngine existential")

    initialiser = branches_from(calls, "localCoachEngine") | branches_from(
        calls, "ViewControllerC16localCoachEngine")
    check(any("AppleRewriteBridge" in target for target in initialiser),
          "the controller's default localCoachEngine is AppleRewriteBridge")

    # Only one type may witness the engine protocol, so the existential above
    # can only be the bridge.
    witnesses = {
        re.match(r"_\$s12TonoKeyboard(\d+)([A-Za-z]+)C", symbol).group(2)
        for symbol in calls
        if "LocalCoachD6EngineA2aDP" in symbol
        and re.match(r"_\$s12TonoKeyboard(\d+)([A-Za-z]+)C", symbol)
    }
    check(witnesses == {"AppleRewriteBridge"},
          f"AppleRewriteBridge is the only LocalCoachRewriteEngine witness (found {witnesses or 'none'})")

    probe = branches_from(calls, "OnDeviceAppleRewriteServiceC17probeAvailability")
    check(any("SystemLanguageModelC12availability" in target for target in probe),
          "OnDeviceAppleRewriteService.probeAvailability reads SystemLanguageModel.availability")
    check(any("SystemLanguageModelC14supportsLocale" in target for target in probe),
          "…and checks SystemLanguageModel.supportsLocale")

    generate = branches_from(calls, "OnDeviceAppleRewriteServiceC07performF3Set")
    check(any("LanguageModelSessionC5model" in target for target in generate),
          "OnDeviceAppleRewriteService.performRewriteSet constructs a LanguageModelSession")

    # ── Build 115 NO-GO repair: the three findings that are visible in a binary ──
    all_symbols = run("nm", str(binary)).splitlines()

    # F1. The response-token budget is the DERIVED one, not the constant that
    #     shipped in 43628d3. `min(1_024, 180 × axisCount)` = 540 tokens for the
    #     trio threw `decodingFailure` on any draft past ~500 characters; the
    #     budget now comes from the same option cap the validator enforces.
    check(not any("OnDeviceAppleRewriteServiceC21maximumResponseTokens" in symbol
                  for symbol in all_symbols),
          "the service's own fixed maximumResponseTokens(for:) is gone")
    check(any("LocalCoachRoutePolicyO21maximumResponseTokens" in symbol
              for symbol in all_symbols),
          "the derived LocalCoachRoutePolicy.maximumResponseTokens is compiled in")

    # F4. The minimum-useful-draft gate is compiled in and is reachable from the
    #     engine, not only from the route policy — so a caller that skipped the
    #     policy still cannot hand the model a draft it will answer rather than
    #     rewrite.
    check(any("draftIsLongEnoughToRewrite" in symbol for symbol in all_symbols),
          "the minimum-useful-draft gate is compiled into the extension")
    rewrite_set = branches_from(calls, "OnDeviceAppleRewriteServiceC10rewriteSet")
    check(any("draftIsLongEnoughToRewrite" in target for target in rewrite_set),
          "OnDeviceAppleRewriteService.rewriteSet applies the minimum-useful-draft gate")

    # F2. The on-device DELIVERY path reaches no analytics beacon.
    #     `TonoAnalytics.track` ends in `URLSession.shared.dataTask(…).resume()`,
    #     and 43628d3 called it from both arms of `completeLocalCoach` — so the
    #     route whose whole claim is "this makes no request" made two. Scoped to
    #     `KeyboardViewController`, because `KeyboardRootView` (compiled, never
    #     mounted) legitimately carries analytics call sites.
    #     NOTE ON THE NEEDLE. `TonoAnalytics.track` does NOT mangle to anything
    #     containing the literal "TonoAnalytics": the module prefix is reused by
    #     the substitution `0A`, so the symbol is
    #     `_$s12TonoKeyboard0A9AnalyticsO5trackyy…`. Matching on "TonoAnalytics"
    #     silently found nothing and passed on a binary that DID call the
    #     beacon — caught by re-running this script against a deliberately
    #     mutated build, which is the only reason it is right now.
    beacon = "AnalyticsO5track"
    check(any(beacon in symbol for symbol in all_symbols),
          "the analytics beacon symbol is present to be searched for "
          "(otherwise the two checks below are vacuous)")
    # `KeyboardViewController` mangles to `0B14ViewControllerC` — "Keyboard" is
    # the `0B` substitution, so the literal class name is not in the symbol
    # either. `0B14ViewControllerC` is the ONLY prefix matching
    # `…ViewControllerC` in this binary, so this scopes to exactly that class.
    controller_prefix = "0B14ViewControllerC"
    controller_symbols = [symbol for symbol in calls if controller_prefix in symbol]
    check(bool(controller_symbols),
          f"KeyboardViewController symbols are matchable as {controller_prefix} "
          f"(found {len(controller_symbols)})")
    beacons = sorted({
        target
        for symbol in controller_symbols
        for target in calls[symbol]
        if beacon in target
    })
    check(not beacons,
          f"KeyboardViewController reaches no analytics beacon (found {beacons or 'none'})")
    delivery = branches_from(calls, "ViewControllerC18completeLocalCoach")
    check(bool(delivery), "completeLocalCoach survives optimisation as its own symbol")
    leaks = sorted(target for target in delivery
                   if beacon in target or "URLSession" in target)
    check(not leaks,
          f"completeLocalCoach reaches no analytics or URLSession symbol (found {leaks or 'none'})")

    print()
    if FAILURES:
        print(f"FAIL: {len(FAILURES)} reachability check(s) failed.")
        sys.exit(1)
    print("PASS: the live KeyboardViewController reaches Foundation Models in this binary.")


if __name__ == "__main__":
    main()
