#!/usr/bin/env python3
"""Build 112 whole-surface UI consolidation contract.

The founder rejected the Build 111 host app on two counts:

  1. "We were combining Playground and Coach on the app — don't need both."
  2. "Backend details still showing."

This verifier is the deterministic version of that correction. Unlike
`verify_build111_settings_release.py` — which scanned only the `SettingsView`
struct body and, per the superseded contract, REQUIRED the DEBUG endpoint
diagnostics to be retained — this one scans every production SwiftUI surface a
user can reach, under BOTH compilation modes, plus the top-level tab bar and
Xcode target membership.

Run from apps/ios:  python3 Scripts/verify_build112_ui_consolidation.py
Optional first argument: an alternate source root (used for mutation probes and
rollback-red runs against a scratch copy, so the worktree is never mutated).
"""

from __future__ import annotations

import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]

# Every production SwiftUI surface the host app can put in front of a user:
# the tab bar, the single Coach experience, Settings and everything reachable
# from it (recipient manager, Setup Doctor, memory, digest, paywall + its
# sign-in sheet, account deletion), and the onboarding covers.
CONSUMER_SURFACES = [
    "App/TonoApp.swift",
    "App/CoachView.swift",
    "App/SettingsView.swift",
    "App/RecipientsManagerView.swift",
    "App/SetupDoctorView.swift",
    "App/MemoryView.swift",
    "App/DigestView.swift",
    "App/HomeView.swift",
    "App/OnboardingEntryPointsView.swift",
    "App/OnboardingCalibrationView.swift",
]

# Copy that ships with the paywall and the keyboard's consumer strings but
# lives outside App/.
SUPPORTING_COPY = [
    "Shared/StoreKitManager.swift",
]

# Directories whose Swift sources ship in a target. Used for the "no Playground
# production code anywhere" sweep.
PRODUCTION_DIRS = [
    "App",
    "Shared",
    "KeyboardExtension",
    "ShareExtension",
    "TonoMessagesExtension",
    "Widget",
]

SHIPPED_PLISTS = [
    "App/Info.plist",
    "KeyboardExtension/Info.plist",
    "ShareExtension/Info.plist",
    "TonoMessagesExtension/Info.plist",
]

EXPECTED_BUILD = "112"
EXPECTED_VERSION = "1.1"

EXPECTED_TABS = ["Coach", "This Week", "Settings"]

# Implementation vocabulary that must never reach a consumer string. Matched
# case-insensitively against string literals only, so a comment or a type name
# (`TonoBackendError`, `TonoShortcutsProvider`) cannot trip it — what the user
# reads is what is judged.
FORBIDDEN_TERMS = [
    "backend",
    "server",
    "endpoint",
    "api key",
    "apikey",
    "bearer",
    "auth token",
    "api token",
    "access key",
    "provider",
    "proxy",
    "llm",
    "transport",
    "non-2xx",
    "staging",
    "userdefaults",
    "app group",
    "api.tonoit.com",
    "://",
    "http",
]

# Whole-word bans (substring matching would fire on ordinary prose).
FORBIDDEN_WORDS = ["url", "urls", "token", "tokens", "endpoint", "endpoints"]

# Generic infrastructure phrasing the founder called out by name.
FORBIDDEN_PHRASES = [
    "runs on tono's service",
    "runs on tono’s service",
    "reach its service",
    "reach our service",
    "sign-in service",
    "temporarily unavailable",
    "on our side",
    "tono's servers",
    "tono’s servers",
    "local app group",
]

# Settings must not carry endpoint diagnostics under ANY compilation mode.
SETTINGS_DIAGNOSTIC_MARKERS = [
    "Endpoint",
    "Custom backend URL",
    "Test Connection",
    "api.tonoit.com",
    "tc.backendURL",
    "developerDiagnostics",
    "diagnosticHealthText",
    "resolvedBackendLabel",
    "runDiagnosticHealthCheck",
    "Developer diagnostics",
    ".health()",
]


# ───────────────────────── source lexing ─────────────────────────

def strip_comments(source: str) -> str:
    """Remove // and /* */ comments without touching string literals."""
    out: list[str] = []
    i = 0
    string = False
    block = 0
    while i < len(source):
        pair = source[i : i + 2]
        if block:
            if pair == "/*":
                block += 1
                i += 2
            elif pair == "*/":
                block -= 1
                i += 2
            else:
                if source[i] == "\n":
                    out.append("\n")
                i += 1
        elif string:
            out.append(source[i])
            if source[i] == "\\" and i + 1 < len(source):
                out.append(source[i + 1])
                i += 2
            else:
                if source[i] == '"':
                    string = False
                i += 1
        elif pair == "//":
            newline = source.find("\n", i)
            if newline < 0:
                break
            out.append("\n")
            i = newline + 1
        elif pair == "/*":
            block = 1
            i += 2
        else:
            out.append(source[i])
            if source[i] == '"':
                string = True
            i += 1
    return "".join(out)


def preprocess(source: str, debug: bool) -> str:
    """Evaluate `#if DEBUG` / `#else` / `#endif` so both modes can be scanned."""
    output: list[str] = []
    active = True
    stack: list[tuple[bool, bool]] = []
    for line in strip_comments(source).splitlines(keepends=True):
        directive = line.strip()
        if directive.startswith("#if "):
            condition = directive[4:].strip()
            value = debug if condition == "DEBUG" else True
            stack.append((active, value))
            active = active and value
        elif directive == "#else":
            parent, condition = stack[-1]
            active = parent and not condition
        elif directive == "#endif":
            active, _ = stack.pop()
        elif active:
            output.append(line)
    if stack:
        raise AssertionError("unbalanced conditional compilation")
    return "".join(output)


def string_literals(source: str) -> list[str]:
    """Consumer-visible copy: ordinary AND multi-line Swift string literals."""
    literals: list[str] = []
    without_blocks = source
    for match in re.finditer(r'"""(.*?)"""', source, re.DOTALL):
        literals.append(match.group(1))
    without_blocks = re.sub(r'""".*?"""', '""', source, flags=re.DOTALL)
    for match in re.finditer(r'"(?:\\.|[^"\\\n])*"', without_blocks):
        literals.append(match.group(0)[1:-1])
    return literals


def body_of(source: str, marker: str) -> str:
    start = source.find(marker)
    if start < 0:
        raise AssertionError(f"missing {marker}")
    opening = source.find("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1 : index]
    raise AssertionError(f"unterminated {marker}")


def pbx_source_files(project: str, target_name: str) -> set[str]:
    """Every Swift file compiled into `target_name`, by basename."""
    target = re.search(
        rf"^\s*[A-F0-9]{{24}} /\* {re.escape(target_name)} \*/ = \{{"
        rf"\s*isa = PBXNativeTarget;(.*?)^\s*\}};",
        project,
        re.MULTILINE | re.DOTALL,
    )
    if not target:
        raise AssertionError(f"missing native target {target_name}")
    phase = re.search(r"([A-F0-9]{24}) /\* Sources \*/", target.group(1))
    if not phase:
        raise AssertionError(f"target {target_name} has no Sources phase")
    body = re.search(
        rf"^\s*{phase.group(1)} /\* Sources \*/ = \{{(.*?)^\s*\}};",
        project,
        re.MULTILINE | re.DOTALL,
    )
    if not body:
        raise AssertionError(f"unreadable Sources phase for {target_name}")
    return set(re.findall(r"/\* (\S+\.swift) in Sources \*/", body.group(1)))


# ───────────────────────── assertions ─────────────────────────

class Contract:
    def __init__(self) -> None:
        self.failures: list[str] = []

    def check(self, condition: bool, message: str) -> bool:
        if condition:
            print(f"PASS: {message}")
        else:
            self.failures.append(message)
            print(f"FAIL: {message}")
        return bool(condition)

    def read(self, relative: str) -> str:
        return (ROOT / relative).read_text()


def scan_consumer_copy(contract: Contract) -> None:
    """No implementation vocabulary in any user-readable string, either mode."""
    for relative in CONSUMER_SURFACES + SUPPORTING_COPY:
        path = ROOT / relative
        if not path.exists():
            contract.check(False, f"{relative} exists")
            continue
        raw = path.read_text()
        offenders: list[str] = []
        for debug in (False, True):
            for literal in string_literals(preprocess(raw, debug=debug)):
                haystack = literal.lower()
                mode = "DEBUG" if debug else "Release"
                for term in FORBIDDEN_TERMS:
                    if term in haystack:
                        offenders.append(f"[{mode}] {term!r} in {literal!r}")
                for word in FORBIDDEN_WORDS:
                    if re.search(rf"\b{re.escape(word)}\b", haystack):
                        offenders.append(f"[{mode}] word {word!r} in {literal!r}")
                for phrase in FORBIDDEN_PHRASES:
                    if phrase in haystack:
                        offenders.append(f"[{mode}] phrase {phrase!r} in {literal!r}")
        contract.check(
            not offenders,
            f"{relative} consumer copy names no implementation detail"
            + ("" if not offenders else f" — {offenders[:4]}"),
        )


def scan_one_coach_experience(contract: Contract) -> None:
    app = contract.read("App/TonoApp.swift")
    body = body_of(strip_comments(app), "struct RootView")
    tabs = re.findall(r'\.tabItem \{ Label\("([^"]+)"', body)
    contract.check(tabs == EXPECTED_TABS, f"top-level tabs are exactly {EXPECTED_TABS} (found {tabs})")
    contract.check(
        body.count("CoachView()") == 1,
        "exactly one Coach destination in the tab bar",
    )
    contract.check(
        "Playground" not in app,
        "TonoApp has no Playground tab, label, or navigation",
    )

    contract.check(
        not (ROOT / "App/PlaygroundView.swift").exists(),
        "App/PlaygroundView.swift is deleted",
    )

    leaks: list[str] = []
    for directory in PRODUCTION_DIRS:
        for swift in sorted((ROOT / directory).rglob("*.swift")):
            if "Playground" in swift.read_text() or "Playground" in swift.name:
                leaks.append(str(swift.relative_to(ROOT)))
    contract.check(not leaks, f"no Playground production code in any shipped target {leaks}")

    project = contract.read("Tono.xcodeproj/project.pbxproj")
    contract.check(
        "PlaygroundView" not in project,
        "PlaygroundView has no Xcode file reference, build file, or group entry",
    )

    host_sources = pbx_source_files(project, "Tono")
    on_disk = {path.name for path in (ROOT / "App").glob("*.swift")}
    contract.check(
        "PlaygroundView.swift" not in host_sources,
        "Playground is absent from the host app target's Sources phase",
    )
    contract.check(
        on_disk.issubset(host_sources),
        f"every App/*.swift on disk is compiled into the host target "
        f"(orphans: {sorted(on_disk - host_sources)})",
    )
    contract.check(
        "CoachView.swift" in host_sources and "SettingsView.swift" in host_sources,
        "Coach and Settings remain members of the host app target",
    )

    coach = contract.read("App/CoachView.swift")
    contract.check(
        coach.count("TextEditor(text: $draft)") == 1,
        "the single Coach experience has exactly one draft editor",
    )
    contract.check(
        coach.count("await runCoach()") == 1
        and coach.count("private func runCoach()") == 1,
        "exactly one Coach action path",
    )
    contract.check(
        coach.count("TonoBackend.shared.analyze(") == 1,
        "exactly one coaching request owner in the host app",
    )
    contract.check(
        coach.count("private func resultsCard(") == 1,
        "exactly one result presentation",
    )
    for banned_mode in ["selectedMode", "isPlaygroundMode", "rehearsal", "Rehearse"]:
        contract.check(
            banned_mode not in coach,
            f"Coach carries no second mode ({banned_mode})",
        )


def scan_settings_surface(contract: Contract) -> None:
    raw = contract.read("App/SettingsView.swift")
    contract.check(
        "#if DEBUG" not in raw,
        "Settings compiles one surface — no build-mode-only UI at all",
    )
    for mode, debug in (("Release", False), ("DEBUG", True)):
        source = preprocess(raw, debug=debug)
        for marker in SETTINGS_DIAGNOSTIC_MARKERS:
            contract.check(
                marker not in source,
                f"{mode} Settings excludes diagnostic {marker!r}",
            )

    release = preprocess(raw, debug=False)
    settings_body = body_of(release, "struct SettingsView")
    recipients_body = body_of(release, "private var recipientsSection")

    for term in [
        "ForEach(recipients",
        ".swipeActions",
        'Button("Add manually")',
        'Label("Contacts Access & Import"',
        ".sheet(isPresented: $showAddRecipient)",
    ]:
        contract.check(
            term not in recipients_body,
            f"Settings recipient section excludes direct roster UI {term!r}",
        )
    contract.check(
        recipients_body.count("NavigationLink") == 1
        and "RecipientsManagerView()" in recipients_body
        and "RecipientsSettingsSummary(" in recipients_body,
        "Settings has exactly one compact recipient manager row",
    )
    contract.check(
        "SetupDoctorView()" in settings_body,
        "Setup Doctor remains reachable from Settings",
    )
    contract.check(
        "AccountDeletionView" in raw and "showPaywall" in raw,
        "subscription and account management remain in Settings",
    )
    contract.check(
        "LiveTonePreference.settingsCopy" in raw
        and "CoachOptionalVariant.allCases" in raw
        and "LocalIntelligenceSelfTest.run(" in raw,
        "Live Tone, Coach variants and the local self-test are preserved",
    )
    contract.check(
        "localizedDescription" not in raw,
        "Settings never renders a raw error description",
    )

    manager = contract.read("App/RecipientsManagerView.swift")
    contract.check(
        "struct RecipientsManagerView" in manager
        and ".searchable(" in manager
        and "ForEach(filtered)" in manager
        and "ContactsAccessView(model: contacts)" in manager,
        "the dedicated manager is reachable, searchable, lazy, and owns access management",
    )

    project = contract.read("Tono.xcodeproj/project.pbxproj")
    file_refs = re.findall(
        r"^\s*([A-F0-9]{24}) /\* RecipientsManagerView\.swift \*/ = \{isa = PBXFileReference;",
        project,
        re.MULTILINE,
    )
    build_files = re.findall(
        r"^\s*([A-F0-9]{24}) /\* RecipientsManagerView\.swift in Sources \*/ = "
        r"\{isa = PBXBuildFile; fileRef = ([A-F0-9]{24}) ",
        project,
        re.MULTILINE,
    )
    exact = len(file_refs) == 1 and len(build_files) == 1
    if exact:
        exact = build_files[0][1] == file_refs[0] and "RecipientsManagerView.swift" in pbx_source_files(
            project, "Tono"
        )
    contract.check(exact, "recipient manager has exact host app target membership")


def scan_keyboard_consumer_copy(contract: Contract) -> None:
    """The keyboard's error strip is a consumer surface too.

    Only `userFacingMessage` is judged: the rest of the client legitimately
    names URLs and headers because that is the request it builds, not the copy
    a user reads.
    """
    client = contract.read("KeyboardExtension/TonoCoachClient.swift")
    body = body_of(strip_comments(client), "public var userFacingMessage: String")
    offenders = []
    for literal in string_literals(body):
        haystack = literal.lower()
        for term in FORBIDDEN_TERMS:
            if term in haystack:
                offenders.append(f"{term!r} in {literal!r}")
        for phrase in FORBIDDEN_PHRASES:
            if phrase in haystack:
                offenders.append(f"{phrase!r} in {literal!r}")
    contract.check(
        not offenders,
        f"keyboard Coach errors name no implementation detail {offenders[:3]}",
    )
    contract.check(
        "LocalIntelligenceCopy.coachRequiresInternet" in body
        and "Request timed out. Check your connection and tap Retry." in body,
        "Build 111 offline and timeout copy is unchanged",
    )


def scan_build111_preservation(contract: Contract) -> None:
    engine = contract.read("KeyboardExtension/AppleFidelity/SpaceCursorEngine.swift")
    for symbol, value in [
        ("finePointsPerCharacter", "12.0"),
        ("precisionZonePoints", "36.0"),
        ("accelerationScalePoints", "180.0"),
    ]:
        contract.check(
            f"public var {symbol}: Double = {value}" in engine,
            f"Build 111 cursor knob {symbol} is unchanged at {value}",
        )

    client = contract.read("KeyboardExtension/TonoCoachClient.swift")
    contract.check(
        "waitsForConnectivity: Bool = true" in client
        and "configuration.waitsForConnectivity = waitsForConnectivity" in client,
        "Build 111 connectivity-aware transport is unchanged",
    )
    intelligence = contract.read("KeyboardExtension/LocalIntelligence.swift")
    contract.check(
        '"Waiting for connection… Coach resumes on its own"' in intelligence,
        "Build 111 offline→online recovery copy is unchanged",
    )

    cursor_tests = contract.read("Tests/Build111CursorSensitivityTests.swift")
    contract.check(
        "XCTAssertEqual(now.finePointsPerCharacter, then.finePointsPerCharacter * 1.5)" in cursor_tests
        and "testTheCurveIsAPureDilationOfBuild110" in cursor_tests,
        "Build 111 cursor tests are unchanged",
    )
    reconnect_tests = contract.read("Tests/Build111CoachReconnectTests.swift")
    contract.check(
        "testParkedRequestCompletesExactlyOnceWhenConnectivityReturns" in reconnect_tests
        and "testNoApplicationLevelReplayAfterATransportFailure" in reconnect_tests,
        "Build 111 reconnect tests are unchanged",
    )


def scan_release_identity(contract: Contract) -> None:
    guard = contract.read("Scripts/bump-build.sh")
    pinned = re.search(r'^EXPECTED_BUILD="([^"]+)"', guard, re.MULTILINE)
    contract.check(
        bool(pinned) and pinned.group(1) == EXPECTED_BUILD,
        f"the single build guard authority pins {EXPECTED_BUILD}",
    )
    for relative in SHIPPED_PLISTS:
        plist = plistlib.loads((ROOT / relative).read_bytes())
        contract.check(
            plist.get("CFBundleVersion") == EXPECTED_BUILD,
            f"{relative} declares CFBundleVersion {EXPECTED_BUILD}",
        )
        contract.check(
            plist.get("CFBundleShortVersionString") == EXPECTED_VERSION,
            f"{relative} stays at version {EXPECTED_VERSION}",
        )
        contract.check(
            relative in guard,
            f"the build guard still covers {relative}",
        )


def main() -> int:
    contract = Contract()
    scan_one_coach_experience(contract)
    scan_settings_surface(contract)
    scan_consumer_copy(contract)
    scan_keyboard_consumer_copy(contract)
    scan_build111_preservation(contract)
    scan_release_identity(contract)

    print(f"\nBuild 112 UI consolidation contract: {len(contract.failures)} failure(s)")
    for failure in contract.failures:
        print(f" - {failure}")
    return 1 if contract.failures else 0


if __name__ == "__main__":
    sys.exit(main())
