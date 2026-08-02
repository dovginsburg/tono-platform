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
  4. `startLocalCoach` builds a `LocalCoachSetRequest` and dispatches
     `rewriteSet` through a `LocalCoachRewriteEngine` existential's protocol
     witness table — i.e. the live controller really does hand a request to the
     on-device engine. Proved by dataflow, not by a symbol name; see the long
     comment at the check itself for why the name-matching version was wrong.
  5. The controller's DEFAULT engine is `AppleRewriteBridge`: its stored-property
     initialiser branches to that class's metadata accessor.
  6. The engine protocol is witnessed by exactly two types — the shipped
     `AppleRewriteBridge` and the declared `UnavailableLocalCoachEngine` null
     object — and by no unreviewed third, so (4) can only land on (5). This
     used to claim the bridge was the ONLY witness; it never was, and the check
     was green because it could not see the other one. See the comment there.
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


def run(*args: str, stdin: str = "") -> str:
    return subprocess.run(args, capture_output=True, text=True, check=True,
                          input=stdin).stdout


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


# ── reading the protocol witness table out of the binary ────────────────────
#
# The engine call is register-indirect, so the only way to say WHICH protocol
# requirement `startLocalCoach` dispatches is to know the byte offset of that
# requirement inside the witness table — and the only honest source for that
# offset is this binary. Hard-coding it would go stale the moment a requirement
# is added to `LocalCoachRewriteEngine`, and would silently start proving the
# wrong thing rather than failing.

def rebase_targets(binary: Path) -> dict[int, int]:
    """address -> rebase target, for every fixup in the binary's data segments.

    A linked witness table is a run of rebased pointers, so its slots are not
    readable as literal bytes; `dyld_info` is what resolves them."""
    out: dict[int, int] = {}
    try:
        raw = run("dyld_info", "-fixups", str(binary))
    except (OSError, subprocess.CalledProcessError):
        return out
    for line in raw.splitlines():
        match = re.match(r"\s*\S+\s+\S+\s+(0x[0-9A-Fa-f]+)\s+rebase\s+(0x[0-9A-Fa-f]+)", line)
        if match:
            out[int(match.group(1), 16)] = int(match.group(2), 16)
    return out


def symbol_addresses(binary: Path) -> tuple[dict[int, list[str]], dict[str, int]]:
    by_address: dict[int, list[str]] = {}
    by_name: dict[str, int] = {}
    for line in run("nm", "-n", str(binary)).splitlines():
        parts = line.split()
        if len(parts) >= 3 and re.fullmatch(r"[0-9a-f]+", parts[0]):
            address = int(parts[0], 16)
            by_address.setdefault(address, []).append(parts[2])
            by_name.setdefault(parts[2], address)
    return by_address, by_name


def witness_types(binary: Path, protocol: str) -> set[str]:
    """Every type in this binary that witnesses `protocol`, found by DEMANGLING.

    Matching mangled substrings does not work here and the failure is silent.
    `AppleRewriteBridge`'s conformance mangles the protocol as
    `LocalCoachD6EngineA2aDP`, but `UnavailableLocalCoachEngine`'s mangles the
    SAME protocol as `0de7RewriteF0A2aDP`, because the conforming type's own
    name changes which substitutions are available. Any needle spelled for one
    conformer is blind to the other — the same trap the F2 needles fell into.
    `WP` (protocol witness table) is a structural suffix, not a substitution, so
    collecting those and asking the demangler is the instrument that cannot go
    quietly blind."""
    tables = [symbol for symbol in run("nm", str(binary)).split()
              if symbol.startswith("_$s") and symbol.endswith("WP")]
    if not tables:
        return set()
    demangled = run("xcrun", "swift-demangle", "--compact", stdin="\n".join(tables))
    found: set[str] = set()
    for line in demangled.splitlines():
        match = re.match(r"protocol witness table for (\S+) : (\S+) in ", line)
        if match and match.group(2).split(".")[-1] == protocol:
            found.add(match.group(1).split(".")[-1])
    return found


def witness_requirements(binary: Path) -> dict[int, str]:
    """Byte offset -> requirement witness, for AppleRewriteBridge's conformance
    to `LocalCoachRewriteEngine`.

    Slot 0 of a witness table is the protocol conformance descriptor and the
    requirements follow it in declaration order. Walking stops at the first slot
    that does not belong to this conformance, which is where the table ends."""
    by_address, by_name = symbol_addresses(binary)
    table = next((address for name, address in by_name.items()
                  if "AppleRewriteBridgeC" in name and "LocalCoachD6EngineAAWP" in name), None)
    if table is None:
        return {}
    fixups = rebase_targets(binary)
    found: dict[int, str] = {}
    for index in range(1, 32):
        target = fixups.get(table + 8 * index)
        if target is None:
            break
        witness = next((symbol for symbol in by_address.get(target, [])
                        if "LocalCoachD6EngineA2aDP" in symbol), None)
        if witness is None:
            break
        found[8 * index] = witness
    return found


# ── a very small symbolic interpreter over the arm64 text ───────────────────
#
# Enough of one to follow a value from a memory load to the branch that calls
# it. Every instruction the interpreter does not model turns its destination
# into a fresh unknown, so the analysis can lose a chain but can never invent
# one — it fails closed.

REGISTER = re.compile(r"^(?:[xw](?:[12]?\d|3[01])|sp|[xw]zr)$")
Value = tuple


def canonical(register: str) -> str:
    if register in ("wzr", "xzr"):
        return "zr"
    if register.startswith("w"):
        return "x" + register[1:]
    return register


class Frame:
    """What each register and stack slot holds, symbolically."""

    def __init__(self) -> None:
        self.reg: dict[str, Value] = {}
        self.stack: dict[int, Value] = {}
        self.sp = 0
        self.counter = 0

    def fresh(self) -> Value:
        self.counter += 1
        return ("?", self.counter)

    def get(self, register: str) -> Value:
        name = canonical(register)
        if name == "sp":
            return ("sp", self.sp)
        if name == "zr":
            return ("zero",)
        if name not in self.reg:
            self.reg[name] = self.fresh()
        return self.reg[name]

    def set(self, register: str, value: Value) -> None:
        name = canonical(register)
        if name not in ("sp", "zr"):
            self.reg[name] = value

    def kill(self, register: str) -> None:
        self.set(register, self.fresh())


def load(base: Value, offset: int) -> Value:
    return ("mem", base, offset)


def memory_operand(text: str) -> tuple[str | None, int, str | None]:
    """`[x0, #0x18]`, `[sp]`, `[sp, #-0x20]!`, `[x0], #16` -> base, offset, writeback."""
    match = re.match(r"^\[(\w+)(?:,\s*#(-?0x[0-9a-f]+|-?\d+))?\](!)?$", text)
    if match:
        return match.group(1), int(match.group(2), 0) if match.group(2) else 0, \
            ("pre" if match.group(3) else None)
    match = re.match(r"^\[(\w+)\],\s*#(-?0x[0-9a-f]+|-?\d+)$", text)
    if match:
        return match.group(1), int(match.group(2), 0), "post"
    return None, 0, None


def instructions(body: list[str]):
    for line in body:
        text = re.sub(r"^[0-9a-f]{16}\t", "", line).split(";")[0].strip()
        if not text:
            continue
        parts = re.split(r"[\t ]+", text, 1)
        operands: list[str] = []
        for operand in (o.strip() for o in parts[1].split(",")) if len(parts) > 1 else []:
            # a comma split breaks `[x0, #8]` in half; put it back together
            if operands and operands[-1].count("[") > operands[-1].count("]"):
                operands[-1] += ", " + operand
            else:
                operands.append(operand)
        yield parts[0], operands


def derives_from(value: Value, root: Value, depth: int = 0) -> bool:
    """Is `value` data-dependent on `root`?"""
    if value == root:
        return True
    if depth > 8 or not isinstance(value, tuple):
        return False
    return any(derives_from(operand, root, depth + 1) for operand in value[1:]
               if isinstance(operand, tuple))


def prove_witness_dispatch(body: list[str], slot: int) -> str | None:
    """Prove that this symbol calls the requirement at `slot` on an opaque
    existential, and return the evidence.

    The shape the Swift calling convention forces, and which no amount of ARC
    outlining or inlining can remove, is:

        ldp  xM, xW, [xE, #k]   ; the existential's type metadata and its
                                ; protocol witness table, side by side
        bl   __swift_project_boxed_opaque_existential_N(xE, xM)
        ldr  xC, [xW, #slot]    ; THE requirement's entry in THAT witness table
        …                       ; resolve the async function pointer
        br   xF                 ; and call it

    Both halves matter: the witness table has to come out of the very
    existential that was projected, and the branch has to be data-dependent on
    the slot that was loaded from it."""
    frame = Frame()
    projections: list[tuple[Value, Value]] = []
    branches: list[tuple[str, Value]] = []

    for mnemonic, operands in instructions(body):
        if mnemonic in ("bl", "b") and operands:
            if "project_boxed_opaque_existential" in operands[0]:
                projections.append((frame.get("x0"), frame.get("x1")))
            if mnemonic == "bl":
                for index in range(19):          # x0-x18 are caller-saved
                    frame.kill("x%d" % index)
            continue

        if mnemonic.rstrip("az") in ("blr", "br") and operands and REGISTER.match(operands[0]):
            branches.append((mnemonic, frame.get(operands[0])))
            continue

        if mnemonic in ("ldr", "ldur", "ldrsw") and len(operands) == 2:
            base, offset, writeback = memory_operand(operands[1])
            if base is None:
                frame.kill(operands[0])
                continue
            if canonical(base) == "sp":
                value = frame.stack.get(frame.sp + (0 if writeback == "post" else offset),
                                        frame.fresh())
            else:
                value = load(frame.get(base), offset)
            frame.set(operands[0], ("sxtw", value) if mnemonic == "ldrsw" else value)
            if writeback and canonical(base) == "sp":
                frame.sp += offset
            continue

        if mnemonic == "ldp" and len(operands) == 3:
            base, offset, writeback = memory_operand(operands[2])
            width = 4 if operands[0].startswith("w") else 8
            if base is None:
                frame.kill(operands[0])
                frame.kill(operands[1])
                continue
            for index, register in enumerate(operands[:2]):
                if canonical(base) == "sp":
                    value = frame.stack.get(frame.sp + offset + index * width, frame.fresh())
                else:
                    value = load(frame.get(base), offset + index * width)
                frame.set(register, value)
            if writeback == "pre" and canonical(base) == "sp":
                frame.sp += offset
            continue

        if mnemonic in ("str", "stur", "stp") and len(operands) in (2, 3):
            base, offset, writeback = memory_operand(operands[-1])
            if base is None:
                frame.stack.clear()
                continue
            if canonical(base) != "sp":
                continue
            if writeback == "pre":
                frame.sp += offset
                offset = 0
            width = 4 if operands[0].startswith("w") else 8
            for index, register in enumerate(operands[:-1]):
                frame.stack[frame.sp + offset + index * width] = frame.get(register)
            continue

        if mnemonic == "mov" and len(operands) == 2:
            if REGISTER.match(operands[1]):
                frame.set(operands[0], frame.get(operands[1]))
            else:
                frame.kill(operands[0])
            continue

        if mnemonic in ("sxtw", "uxtw") and len(operands) == 2:
            frame.set(operands[0], ("sxtw", frame.get(operands[1])))
            continue

        if mnemonic in ("add", "sub") and len(operands) == 3:
            immediate = re.match(r"^#(-?0x[0-9a-f]+|-?\d+)$", operands[2])
            if canonical(operands[0]) == canonical(operands[1]) == "sp":
                if immediate:
                    frame.sp += int(immediate.group(1), 0) * (1 if mnemonic == "add" else -1)
                continue
            if mnemonic == "add" and REGISTER.match(operands[1]) and REGISTER.match(operands[2]):
                frame.set(operands[0], ("add", frame.get(operands[1]), frame.get(operands[2])))
            else:
                frame.kill(operands[0])
            continue

        if operands and REGISTER.match(operands[0]):
            frame.kill(operands[0])
            if mnemonic.startswith("st"):
                frame.stack.clear()

    for existential, metadata in projections:
        # the witness table sits one word above the metadata in the box
        if not (len(metadata) == 3 and metadata[0] == "mem" and metadata[1] == existential):
            continue
        entry = load(load(existential, metadata[2] + 8), slot)
        for mnemonic, target in branches:
            if derives_from(target, entry):
                return (f"existential metadata +{metadata[2]:#x} / witness table "
                        f"+{metadata[2] + 8:#x}, slot +{slot:#x}, called by `{mnemonic}`")
    return None


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
    calls, bodies = disassemble(binary)

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

    # The engine call is `try await engine.rewriteSet(request)` on an
    # `any LocalCoachRewriteEngine`, so it is register-indirect through the
    # protocol witness table and carries NO name in the instruction stream.
    #
    # WHAT USED TO BE HERE, AND WHY IT WAS WRONG. This check looked for a `bl`
    # out of `startLocalCoach` whose target contained `LocalCoachRewriteEngine_p`.
    # It was wrong twice over:
    #
    #   * It could never have seen the dispatch. `rewriteSet` is not a `bl`
    #     target in ANY build of this binary — witness dispatch is `blr`/`br`
    #     through a register — so the check never proved the thing it named.
    #   * What it actually matched was `…LocalCoachRewriteEngine_pWOb`, the
    #     OUTLINED INIT-WITH-TAKE of the existential: an ARC helper. Whether
    #     that helper is outlined or inlined is the optimiser's choice, and it
    #     differs between two commits whose Swift source for this function is
    #     byte-identical. 1dca05d outlines it, so the check went green; 7631f2d
    #     inlines it and outlines the DESTROY instead, under the protocol-
    #     agnostic name `__swift_destroy_boxed_opaque_existential_1`, so the
    #     check went red on a candidate with 33 identical indirect calls and an
    #     unchanged call graph. Build 114's lesson was that a check can be true
    #     and worthless as evidence; this one was worthless in both directions,
    #     and a gate that flips on the optimiser's mood is a gate that gets
    #     waived.
    #
    # So prove the dispatch itself, by dataflow: the witness table is taken out
    # of the same existential that gets projected, the `rewriteSet` slot is read
    # from that table, and the branch target is data-dependent on what that slot
    # held. None of those three steps is an ARC artifact, and none of them can be
    # optimised away without removing the call.
    requirements = witness_requirements(binary)
    rewrite_slots = [offset for offset, witness in requirements.items()
                     if "10rewriteSet" in witness]
    other_slots = sorted(offset for offset in requirements if offset not in rewrite_slots)
    # Non-vacuity, in front of the proof exactly as the F2 needles carry theirs:
    # without a slot offset read out of THIS binary there is nothing to match on,
    # and unless the table holds another requirement too, matching a slot would
    # not discriminate between `rewriteSet` and anything else on the protocol.
    check(len(rewrite_slots) == 1 and bool(other_slots),
          f"the rewriteSet witness slot is derivable from this binary "
          f"(rewriteSet at {[hex(o) for o in rewrite_slots] or 'none'}, "
          f"{len(other_slots)} other requirement(s) at {[hex(o) for o in other_slots]})")

    evidence = None
    if len(rewrite_slots) == 1:
        for symbol in symbols_matching(calls, "ViewControllerC15startLocalCoach"):
            evidence = evidence or prove_witness_dispatch(bodies[symbol], rewrite_slots[0])
    check(evidence is not None,
          "startLocalCoach dispatches rewriteSet through a LocalCoachRewriteEngine "
          f"existential's witness table ({evidence or 'NO SUCH DATAFLOW'})")

    # Which type the dispatched-through existential actually IS. The default is
    # produced in exactly one place, so this is the whole story for shipped code.
    engines = witness_types(binary, "LocalCoachRewriteEngine")
    initialiser = branches_from(calls, "localCoachEngine") | branches_from(
        calls, "ViewControllerC16localCoachEngine")
    check(any("AppleRewriteBridge" in target for target in initialiser),
          "the controller's default localCoachEngine is AppleRewriteBridge")

    # WHAT THIS USED TO CLAIM, AND WHY IT WAS FALSE. This asserted that
    # AppleRewriteBridge is the ONLY `LocalCoachRewriteEngine` witness in the
    # binary. It is not, and never was: `UnavailableLocalCoachEngine`, the null
    # object, is compiled into the extension too and witnesses the same
    # protocol. The check passed anyway, for two independent reasons — its
    # needle was spelled with AppleRewriteBridge's substitutions (see
    # `witness_types`), and its regex ended in `C`, so it could only ever count
    # CLASS conformers and the null object is a struct. It was a check that was
    # green because it could not see, which is precisely the Build 114 failure
    # mode it was written to prevent.
    #
    # The truthful invariant is a closed world: these two conformers and no
    # third. A new engine type appearing — the way a second, unreviewed
    # implementation would — flips this, and so does the bridge disappearing.
    check(engines == {"AppleRewriteBridge", "UnavailableLocalCoachEngine"},
          f"the engine protocol is witnessed by exactly the shipped bridge and the "
          f"declared null object (found {engines or 'none'})")

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
