#!/usr/bin/env python3
"""Build 117 — prove Read the Ask is absent from the keyboard and the iMessage
extension, in the SHIPPED binaries rather than in the project file.

WHY THIS SCRIPT EXISTS
----------------------
`Shared/ReadTheAsk.swift` used to claim the exclusion was "asserted against the
Xcode project AND against the shipped Mach-O binaries by
`Build117ReadTheAskTests`". Only the first half was true: those tests read
`project.pbxproj` and the keyboard's `.swift` sources. No binary was ever
inspected by anything durable, and no `verify_build117_*` script existed. The
exclusion was real — but a claim of proof with no artefact behind it is exactly
how Build 115's lesson ("never match Swift mangled substrings, demangle") gets
un-learned. This is the missing artefact.

WHAT IT CHECKS, AND WHY EACH CHECK IS SHAPED THE WAY IT IS
----------------------------------------------------------
* **Symbols, demangled.** Swift mangles names, so grepping a mangled table for
  "ReadTheAsk" finds nothing whether or not the code is there. Every symbol is
  demangled through ONE `swift-demangle` process (one per symbol turns a
  5-second check into an hour) before matching.

* **Positive controls, mandatory.** A check that returns "0 hits" is worthless
  until something proves it *can* return a hit. This bit for real: a naive first
  pass reported 0 for every binary including the app, because a Debug build puts
  the code in a separate `*.debug.dylib` and `nm` on the thin main binary sees
  almost nothing. Every configuration therefore asserts the app and the Share
  extension DO contain the feature before believing that the keyboard does not.

* **Strings, case-sensitively, as whole shipped sentences.** An earlier pass
  matched the fragment "Read this message" and reported
  "Couldn't read this message." — a string that predates Build 117 — as a leak;
  and case-insensitive "The Ask" matched "Tightens the ask and removes
  ambiguity." A check that cries wolf is a check nobody believes the second
  time.

* **Packaging and target membership**, so the claim covers what ships rather
  than what compiled.

Usage:
    verify_build117_read_ask_exclusion.py <Build/Products dir> [<more dirs>...]

Each directory should contain `Tono.app`. Pass both the Debug and the Release
products directory to cover both configurations. Exit 0 = every check passed.
"""

from __future__ import annotations

import plistlib
import re
import subprocess
import sys
from pathlib import Path

# ── what "this feature" looks like ────────────────────────────────────────

#: Demangled-symbol needles. These are type and member names, so they appear in
#: demangled Swift symbols and nowhere else.
SYMBOL_NEEDLES = ("ReadTheAsk", "ReadAsk", "TonoRequestMode", "readAsk")

#: Whole shipped sentences and wire tokens, matched CASE-SENSITIVELY. Ordinary
#: English fragments are deliberately absent — see the module docstring.
STRING_NEEDLES = (
    "Read the Ask",
    "read_ask",
    "readTheAsk",
    "tc.readTheAsk.enabled",
    "Only text you choose is analyzed",
    "Off by default. Turn it off anytime",
    "Their message",
    "Could also mean",
    "Possibilities, not conclusions",
    "Draft my reply",
    "Ask for clarification",
    "No deadline stated",
    "Read this message",
    "sent to Tono to be read",
    "/api/read-ask",
)

#: Bundles that must NOT carry the feature. The binding contract is that the
#: keyboard stays rewrite-only; the iMessage extension is held to the same line.
EXCLUDED = ("TonoKeyboard", "TonoMessagesExtension")

#: Bundles that MUST carry it. An exclusion nobody depends on proves nothing:
#: if these ever go quiet, the whole check has gone vacuous and should fail.
REQUIRED = {
    "Tono": ("Read the Ask", "ReadTheAsk"),
    "TonoShare": ("read_ask", "ReadTheAsk"),
}

EXPECTED_SHIPPED_BUNDLES = {"TonoKeyboard", "TonoShare", "TonoMessagesExtension"}


class Checker:
    def __init__(self) -> None:
        self.ok = 0
        self.failures: list[str] = []

    def passed(self, message: str) -> None:
        self.ok += 1
        print(f"ok    {message}")

    def failed(self, message: str) -> None:
        self.failures.append(message)
        print(f"FAIL  {message}")

    def check(self, condition: bool, message: str) -> bool:
        (self.passed if condition else self.failed)(message)
        return condition


def demangled_symbols(binary: Path) -> str:
    """Every symbol in `binary`, demangled, as one searchable blob."""
    try:
        raw = subprocess.run(
            ["nm", "-a", str(binary)], capture_output=True, text=True, timeout=300
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return ""
    names = "\n".join(line.split()[-1] for line in raw.splitlines() if line.split())
    try:
        return subprocess.run(
            ["xcrun", "swift-demangle", "--compact"],
            input=names, capture_output=True, text=True, timeout=600,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return names


def binary_strings(binary: Path) -> str:
    try:
        return subprocess.run(
            ["strings", "-a", str(binary)], capture_output=True, text=True, timeout=300
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def executables_for(bundle: Path) -> list[Path]:
    """A bundle's main executable AND any sibling dylibs it ships.

    Debug builds put most Swift code in `<Name>.debug.dylib` next to the thin
    main executable. Reading only the main binary is precisely the vacuous check
    this script exists to prevent, so everything the bundle carries is read.
    """
    found = [p for p in bundle.glob("*.dylib") if p.is_file()]
    main = bundle / bundle.stem
    if main.is_file():
        found.append(main)
    found += [p for p in bundle.glob("Frameworks/*.framework/*") if p.is_file()]
    return found


def scan(bundle: Path) -> tuple[str, str]:
    symbols, strings = [], []
    for exe in executables_for(bundle):
        symbols.append(demangled_symbols(exe))
        strings.append(binary_strings(exe))
    return "\n".join(symbols), "\n".join(strings)


def verify_products(products: Path, checker: Checker) -> None:
    app = products / "Tono.app"
    label = products.name
    if not checker.check(app.is_dir(), f"[{label}] Tono.app exists at {app}"):
        return

    plugins = app / "PlugIns"
    shipped = {p.stem for p in plugins.glob("*.appex")} if plugins.is_dir() else set()
    checker.check(
        EXPECTED_SHIPPED_BUNDLES <= shipped,
        f"[{label}] every expected extension is packaged (found {sorted(shipped)})",
    )

    scans: dict[str, tuple[str, str]] = {"Tono": scan(app)}
    for name in sorted(shipped):
        scans[name] = scan(plugins / f"{name}.appex")

    # ── positive controls first. Nothing below means anything without them.
    for name, needles in REQUIRED.items():
        symbols, strings = scans.get(name, ("", ""))
        symbol_hits = sum(symbols.count(n) for n in needles)
        string_hits = sum(strings.count(n) for n in needles)
        checker.check(
            symbol_hits + string_hits > 0,
            f"[{label}] POSITIVE CONTROL — {name} carries the feature "
            f"({symbol_hits} symbol / {string_hits} string hits); a zero here "
            f"means the scan is blind and every exclusion below is vacuous",
        )

    # ── the exclusion itself.
    for name in EXCLUDED:
        symbols, strings = scans.get(name, ("", ""))
        if not symbols and not strings:
            checker.failed(
                f"[{label}] {name}: nothing could be read from the bundle — "
                f"an unreadable binary is not an empty one"
            )
            continue
        leaked_symbols = sorted({n for n in SYMBOL_NEEDLES if n in symbols})
        leaked_strings = sorted({n for n in STRING_NEEDLES if n in strings})
        checker.check(
            not leaked_symbols,
            f"[{label}] {name}: no Read the Ask symbols (demangled)"
            + (f" — LEAKED {leaked_symbols}" if leaked_symbols else ""),
        )
        checker.check(
            not leaked_strings,
            f"[{label}] {name}: no Read the Ask strings"
            + (f" — LEAKED {leaked_strings}" if leaked_strings else ""),
        )

    # ── build identity of everything that ships.
    for plist_path in [app / "Info.plist"] + sorted(plugins.glob("*.appex/Info.plist")):
        try:
            info = plistlib.loads(plist_path.read_bytes())
        except (OSError, plistlib.InvalidFileException):
            checker.failed(f"[{label}] unreadable Info.plist at {plist_path}")
            continue
        name = plist_path.parent.name
        checker.check(
            info.get("CFBundleVersion") == EXPECTED_BUILD,
            f"[{label}] {name}: CFBundleVersion {info.get('CFBundleVersion')} == {EXPECTED_BUILD}",
        )


def verify_target_membership(root: Path, checker: Checker) -> None:
    """Membership read from the project file, walking the object graph rather
    than matching on line proximity."""
    project = (root / "Tono.xcodeproj" / "project.pbxproj").read_text(encoding="utf-8")

    targets: dict[str, str] = {}
    for match in re.finditer(
        r"([0-9A-F]{24}) /\* (\w+) \*/ = \{\n\t\t\tisa = PBXNativeTarget;(.*?)\n\t\t\};",
        project, re.S,
    ):
        phases = re.findall(r"([0-9A-F]{24}) /\* Sources \*/", match.group(3))
        if phases:
            targets[match.group(2)] = phases[0]

    membership: dict[str, list[str]] = {}
    for name, phase_id in targets.items():
        phase = re.search(
            re.escape(phase_id) + r" /\* Sources \*/ = \{\n\t\t\tisa = PBXSourcesBuildPhase;.*?files = \((.*?)\n\t\t\t\);",
            project, re.S,
        )
        membership[name] = (
            re.findall(r"/\* (.+?) in Sources \*/", phase.group(1)) if phase else []
        )

    for target in EXCLUDED:
        files = membership.get(target)
        if files is None:
            checker.failed(f"membership: target {target} has no Sources phase")
            continue
        leaked = sorted(f for f in files if "ReadTheAsk" in f or "Build117" in f)
        checker.check(not leaked, f"membership: {target} compiles no Read the Ask source {leaked or ''}")

    checker.check(
        sorted(f for f in membership.get("Tono", []) if "ReadTheAsk" in f)
        == ["ReadTheAsk.swift", "ReadTheAskView.swift"],
        "membership: Tono compiles both Read the Ask sources",
    )
    checker.check(
        [f for f in membership.get("TonoShare", []) if "ReadTheAsk" in f] == ["ReadTheAsk.swift"],
        "membership: TonoShare compiles the shared Read the Ask source",
    )


def expected_build(root: Path) -> str:
    """The single reviewed authority, read from the guard script."""
    for line in (root / "Scripts" / "bump-build.sh").read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped.startswith("EXPECTED_BUILD="):
            return stripped.split("=", 1)[1].strip("\"' ")
    raise SystemExit("verify_build117: Scripts/bump-build.sh has no EXPECTED_BUILD")


ROOT = Path(__file__).resolve().parent.parent
EXPECTED_BUILD = expected_build(ROOT)


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2

    checker = Checker()
    verify_target_membership(ROOT, checker)
    for raw in argv[1:]:
        verify_products(Path(raw), checker)

    print()
    print(f"checks ok={checker.ok} fail={len(checker.failures)}")
    if checker.failures:
        print("\nfailures:")
        for failure in checker.failures:
            print(f"  - {failure}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
