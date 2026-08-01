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
    "App/ReadTheAskView.swift",
]

# Copy that ships with the paywall and the keyboard's consumer strings but
# lives outside App/.
SUPPORTING_COPY = [
    "Shared/StoreKitManager.swift",
    "Shared/ConsumerErrorCopy.swift",
]

# ── Build 112 repair: whole-surface raw-error contract ──────────────────
#
# The first Build 112 contract claimed whole-surface coverage and did not
# have it. It banned implementation VOCABULARY inside string literals, which
# says nothing about `errorMessage = error.localizedDescription` — there is
# no literal there to judge. Five shipped surfaces passed it while routing
# raw failures onto the screen: This Week, the paywall, the keyboard strip,
# Share, and Messages.
#
# Everything below judges EXPRESSIONS, not vocabulary, and derives the list
# of surfaces from the Xcode project rather than trusting a hand-written one.

# Every native target whose product ships to a user.
SHIPPED_TARGETS = ["Tono", "TonoKeyboard", "TonoShare", "TonoMessagesExtension"]

# Files that put pixels in front of a user, plus the two files that supply
# the copy those pixels show. `discover_consumer_surfaces` proves this list
# is complete against the Xcode project, so a new screen cannot ship
# unjudged.
RENDERING_SURFACES = [
    # Build 115 — the shared adaptive-layout primitive. It declares a
    # `ViewModifier`, so `discover_consumer_surfaces` sees it as a surface; it
    # renders no copy of its own, which is what the contract requires of it.
    "App/AdaptiveLayout.swift",
    "App/CoachView.swift",
    "App/DigestView.swift",
    "App/HomeView.swift",
    "App/MemoryView.swift",
    "App/OnboardingCalibrationView.swift",
    "App/OnboardingEntryPointsView.swift",
    "App/ReadTheAskView.swift",
    "App/RecipientsManagerView.swift",
    "App/SettingsView.swift",
    "App/SetupDoctorView.swift",
    "App/TonoApp.swift",
    "KeyboardExtension/KeyboardRootView.swift",
    "KeyboardExtension/KeyboardViewController.swift",
    "KeyboardExtension/LiveToneIndicatorView.swift",
    "KeyboardExtension/TonoKeyboardVisualStyle.swift",
    "ShareExtension/ShareRootView.swift",
    "ShareExtension/ShareViewController.swift",
    "Shared/ContactsSync.swift",
    "Shared/ConsumerErrorCopy.swift",
    "Shared/StoreKitManager.swift",
    "TonoMessagesExtension/MessagesViewController.swift",
]

# How a shipped source is recognised as a consumer surface. Deliberately
# generous: a false positive costs one line in RENDERING_SURFACES, a false
# negative is exactly the hole this contract exists to close.
SURFACE_MARKERS = [
    r":\s*View\s*\{",
    r":\s*(?:UIViewController|UIInputViewController|MSMessagesAppViewController"
    r"|UIView|UILabel|UIButton|UIStackView|ViewModifier)\b",
    r"\bUIHostingController\b",
    r"\bText\(",
    r"\bLabel\(",
]

# Expressions that turn a raw failure into something a user can read. None
# of them may appear anywhere in a consumer surface — not in a catch block,
# not in a log line that a later edit might render, not at all.
RAW_ERROR_EXPRESSIONS = [
    (r"\.localizedDescription\b", "renders a failure's own description"),
    (r"\.errorDescription\b", "renders a failure's own description"),
    (r"\bString\(describing:", "renders a value's debug description"),
    (r"\bString\(reflecting:", "renders a value's debug description"),
    (r"\.debugDescription\b", "renders a debug description"),
    (r"\.userInfo\b", "renders a failure's underlying detail"),
    (
        r"\\\(\s*(?:error|err|e|failure|nsError|urlError|underlyingError)\b",
        "interpolates a raw failure into consumer copy",
    ),
    (r"\bstatusCode\b", "puts a status code on a consumer surface"),
    (r"\bresponseBody\b", "puts a response body on a consumer surface"),
    (r"\bhttpResponse\b", "puts response detail on a consumer surface"),
    # Build 113. `localizedDescription` is one of several ways a Foundation
    # error will hand you its text, and the ban list only knew about that one.
    # An independent probe rendered `(error as NSError).localizedFailureReason`
    # and another rendered `ns.domain` — both passed the Build 112 contract.
    (r"\.localizedFailureReason\b", "renders a failure's own description"),
    (r"\.localizedRecoverySuggestion\b", "renders a failure's own description"),
    (r"\.localizedRecoveryOptions\b", "renders a failure's own description"),
    (r"\.failureReason\b", "renders a failure's own description"),
    (r"\.recoverySuggestion\b", "renders a failure's own description"),
    (r"\bNSError\b", "reaches for a failure's Foundation representation"),
    (r"\.domain\b", "puts a failure's error domain on a consumer surface"),
]

# State that is rendered to the user when a request fails. Anything assigned
# here must be fixed copy or the output of an approved mapper.
FAILURE_STATE_SINKS = [
    r"\berrorMessage\s*=\s*(?P<rhs>[^\n]+)",
    r"\breadAskFailure\s*=\s*(?P<rhs>[^\n]+)",
    r"\bpurchaseError\s*=\s*(?P<rhs>[^\n]+)",
    r"\bmode\s*=\s*\.error\((?P<rhs>[^\n]*)\)",
    r"\bcompletion\((?P<rhs>[^\n]*)\)",
]

# The only functions allowed to produce a failure sentence. Each one maps a
# failure's CASE — never its message payload — onto an action.
APPROVED_ERROR_MAPPERS = [
    "ConsumerErrorCopy.message(",
    "prettyError(",
    "requestErrorMessage(",
    "verificationErrorMessage(",
    "userFacingMessage",
    "ReadTheAskFailure.message(",
    "ReadTheAskNotice.forFailure(",
]

# Identifiers that name a failure. Assigning one straight into rendered
# state is the leak, whatever it is later formatted with.
ERROR_IDENTIFIERS = ["error", "err", "e", "failure", "nsError", "urlError", "underlyingError"]

# ── Build 113: 429 is not 402 ───────────────────────────────────────────
#
# The two surfaces that map an HTTP status onto a Coach sentence, and the
# declaration whose body owns that mapping. Everything else routes through
# `ConsumerErrorCopy`, which already keeps the two apart.
RATE_LIMIT_SURFACES = [
    ("App/CoachView.swift", "private func prettyError(_ e: TonoBackendError) -> String"),
    ("KeyboardExtension/TonoCoachClient.swift", "public var userFacingMessage: String"),
]

# Words that mean "you must pay". True for 402, false for 429.
PAYWALL_VOCAB = ["subscription", "subscribe", "trial"]

# The surfaces that consume `TonoBackend.analyzeStream` directly. Both take
# the streaming path in production, so both used to lose the status.
STREAMING_CONSUMERS = [
    "KeyboardExtension/KeyboardRootView.swift",
    "ShareExtension/ShareRootView.swift",
]

# The mapper is the one file allowed to author failure copy, so its copy is
# pinned exactly. A sentence that is not on this list is a sentence nobody
# reviewed.
CONSUMER_ERROR_COPY = "Shared/ConsumerErrorCopy.swift"

CONSUMER_ERROR_SENTENCES = {
    " ",
    "This email is already on \\(current) devices (max \\(max)). Contact support if you need more.",
    "Couldn't coach this draft.",
    "Couldn't read this message.",
    "Couldn't load your weekly summary.",
    "Purchase couldn't be completed.",
    "Restore couldn't be completed.",
    "Couldn't add the rewrite to your message.",
    "Try again.",
    "Check your connection and try again.",
    "Open Tono and sign in again.",
    "Open Tono once to finish setting up, then try again.",
    "An active trial or subscription is required. Open Tono to continue.",
    "Wait a minute and try again.",
    "Sign in with your email first so your subscription follows you if you reinstall.",
    "Try again, and contact support@tonoit.com if it keeps happening.",
}

# The four sentences the repair brief names verbatim. They are the proof the
# mapper preserves the distinction between actions instead of flattening
# every failure into one apology.
REQUIRED_ACTION_SENTENCES = [
    ("weeklySummary", "Couldn't load your weekly summary.", "Try again."),
    ("purchase", "Purchase couldn't be completed.", "Try again."),
    ("restore", "Restore couldn't be completed.", "Try again."),
    ("coachDraft", "Couldn't coach this draft.", "Check your connection and try again."),
]

# Calls whose string arguments are read by a user. Used to judge consumer
# vocabulary on surfaces whose non-rendered strings legitimately name a
# request (the keyboard builds one).
RENDER_CALLS = [
    "Text(", "Label(", "Button(", "TextField(", "SecureField(", "Toggle(",
    "Picker(", "Section(", "NavigationLink(", "ProgressView(", "Stepper(",
    "Menu(", "Link(", "Alert(", "TextEditor(",
    ".navigationTitle(", ".accessibilityLabel(", ".accessibilityHint(",
    ".accessibilityValue(", ".alert(", ".confirmationDialog(", ".help(",
    ".searchable(", ".setTitle(",
    "mode = .error(", "ErrorView(", "completion(",
]

RENDER_ASSIGNMENTS = [
    ".accessibilityLabel =", ".accessibilityHint =", ".accessibilityValue =",
    ".text =", ".title =", ".placeholder =",
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

def _expected_build() -> str:
    """Read the shipped build number from `Scripts/bump-build.sh`.

    That script is the SINGLE reviewed authority for the number, and every
    other consumer (Tests/BuildNumberGuardTests.swift,
    Tests/Build112UISurfaceContractTests.swift,
    Scripts/verify_messages_extension.py) already derives from it rather than
    keeping a copy. This verifier did keep one — pinned at "113" — so cutting
    Build 114 turned a green UI-consolidation gate red on a change that had
    nothing to do with the UI. Deriving keeps the real invariant (all four
    shipped bundles agree with the release authority) while removing the drift.
    """
    script = (ROOT / "Scripts" / "bump-build.sh").read_text(encoding="utf-8")
    for line in script.splitlines():
        stripped = line.strip()
        if stripped.startswith("EXPECTED_BUILD="):
            return stripped.split("=", 1)[1].strip().strip("\"'")
    raise SystemExit(
        "verify_build112: Scripts/bump-build.sh must pin EXPECTED_BUILD — "
        "it is the release authority"
    )


EXPECTED_BUILD = _expected_build()
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


def split_literals(source: str) -> tuple[str, list[str]]:
    """Separate Swift code from literal text, keeping interpolations as code.

    Build 113. The contract used to judge a right-hand side by its first
    token and to skip anything starting with a quote. Both were bypassable in
    one line: `"Couldn't load. \\(cause)"` starts with a quote, and every
    character that matters is inside it. Literal *text* is copy and is judged
    as vocabulary elsewhere; an interpolation is executable code that gets
    rendered, so it belongs on the code side of this split.
    """
    code: list[str] = []
    interpolations: list[str] = []
    index = 0
    length = len(source)
    in_string = False
    while index < length:
        char = source[index]
        if in_string:
            if char == "\\" and index + 1 < length:
                if source[index + 1] == "(":
                    depth = 0
                    scan = index + 1
                    while scan < length:
                        if source[scan] == "(":
                            depth += 1
                        elif source[scan] == ")":
                            depth -= 1
                            if depth == 0:
                                break
                        scan += 1
                    interpolations.append(source[index + 2 : scan])
                    index = scan + 1
                    continue
                index += 2  # an ordinary escape: \" \\ \n …
                continue
            if char == '"':
                in_string = False
            index += 1
            continue
        if char == '"':
            in_string = True
            index += 1
            continue
        code.append(char)
        index += 1
    return "".join(code), interpolations


def mentions(names: set[str], expression: str) -> list[str]:
    """Every name in `names` that appears in `expression` as a whole word."""
    return sorted(
        name for name in names if re.search(rf"\b{re.escape(name)}\b", expression)
    )


def tainted_identifiers(source: str) -> set[str]:
    """Names that hold a failure — including ones laundered through a binding.

    Build 113. A fixed list of identifiers is defeated by one `let`:
    `let cause = error` renames the failure, and
    `{ let ns = error as NSError; … }()` renames it inside a closure the old
    head-anchored rule never looked into. Anything bound from something
    already tainted is tainted too, computed to a fixed point so a chain of
    renames does not launder a failure either.
    """
    tainted = set(ERROR_IDENTIFIERS)
    code, interpolated = split_literals(source)
    haystack = code + "\n" + "\n".join(interpolated)

    for match in re.finditer(r"\bcatch\s+let\s+([A-Za-z_][A-Za-z0-9_]*)", haystack):
        tainted.add(match.group(1))

    binding = re.compile(
        r"\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::\s*[^=\n]+?)?=\s*([^\n]+)"
    )
    for _ in range(4):  # a fixed point; four renames is far past any real chain
        grew = False
        for match in binding.finditer(haystack):
            name, bound = match.group(1), match.group(2)
            if name in tainted:
                continue
            if mentions(tainted, bound) or "NSError" in bound:
                tainted.add(name)
                grew = True
        if not grew:
            break
    return tainted


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


def scan_rate_limit_is_not_a_paywall(contract: Contract) -> None:
    """429 is the rate limit. 402 is the entitlement gate. Never one sentence.

    `TonoBackend.swift` states the invariant in its own words — "Keep them
    distinct — 429 is NOT 'subscription required'" — and both Coach surfaces
    broke it anyway: the host app folded `402, 429` into one branch and the
    keyboard answered 429 with the paywall sentence outright. A subscriber who
    trips the per-IP limit was told to buy the subscription they already pay
    for. That is not a wording preference; it is a false statement on the
    surface people use most, and it is what App Review reads.

    401 is checked alongside them because both surfaces used to drop it into a
    bare retry, which names no next step for an expired sign-in.
    """
    for relative, signature in RATE_LIMIT_SURFACES:
        source = strip_comments(contract.read(relative))
        body = body_of(source, signature)
        if not contract.check(bool(body), f"{relative} still declares {signature}"):
            continue

        # A shared `case 402, 429:` is the exact shape of the defect: one
        # sentence answering two unrelated facts about the user's account.
        contract.check(
            not re.search(r"case\s+(?:402\s*,\s*429|429\s*,\s*402)\s*:", body),
            f"{relative} does not answer 402 and 429 with one branch",
        )

        answers: dict[int, str] = {}
        for match in re.finditer(r"case\s+(401|402|429)\s*:\s*return\s+(\"[^\"]*\")", body):
            answers[int(match.group(1))] = match.group(2)

        missing = [code for code in (401, 402, 429) if code not in answers]
        if not contract.check(
            not missing,
            f"{relative} answers 401, 402 and 429 each on its own (missing {missing})",
        ):
            continue

        contract.check(
            len({answers[401], answers[402], answers[429]}) == 3,
            f"{relative} gives 401, 402 and 429 three different sentences",
        )

        # The truthfulness test, in both directions: only the entitlement gate
        # may talk about paying, and the rate limit must not.
        rate_limited = answers[429].lower()
        contract.check(
            not any(word in rate_limited for word in PAYWALL_VOCAB),
            f"{relative} does not tell a rate-limited user to subscribe — {answers[429]}",
        )
        contract.check(
            any(word in answers[402].lower() for word in PAYWALL_VOCAB),
            f"{relative} still tells a gated user what they actually need — {answers[402]}",
        )
        contract.check(
            "wait" in rate_limited,
            f"{relative} tells a rate-limited user to wait — {answers[429]}",
        )


def scan_streaming_preserves_status(contract: Contract) -> None:
    """A streamed failure reaches the mapper as a status, never as a sentence.

    The non-streaming path throws `TonoBackendError.http(code, …)` and keeps
    401, 402 and 429 apart. The streaming path — which is the path the
    keyboard strip and the Share sheet actually take — used to yield
    `.error("Server error (\\(code))")`, and the consumers wrapped that string
    into `ToneEngineError.backend`, which the mapper can only answer with
    "Try again." The code existed at the yield site and was destroyed one line
    later, so an expired sign-in, a missing subscription and a rate limit all
    rendered the same sentence.

    Build 112 removed the leak on this path but did not recover the
    distinction. This keeps both properties: structure travels, prose does not.
    """
    backend = strip_comments(contract.read("Shared/TonoBackend.swift"))

    contract.check(
        "case failure(status: Int)" in backend,
        "the analysis stream can carry a status code",
    )
    contract.check(
        not re.search(r"yield\(\s*\.error\(\s*\"Server error", backend),
        "the stream no longer stringifies a status into a sentence",
    )
    contract.check(
        bool(re.search(r"continuation\.yield\(\s*\.failure\(status:\s*code\s*\)\s*\)", backend)),
        "a non-2xx response yields its status rather than a sentence about it",
    )

    declaration = "public enum StreamedFailure: Error, Equatable"
    if contract.check(declaration in backend, "the streamed failure is a typed error"):
        payload = body_of(backend, declaration)
        # A body is where a host name or a stack trace would ride along. The
        # type is useless to a leak if it cannot hold text at all.
        contract.check(
            "String" not in payload,
            f"the streamed failure carries no message payload — {payload.strip()[:60]!r}",
        )

    for relative in STREAMING_CONSUMERS:
        source = strip_comments(contract.read(relative))
        # One stream loop per `.perception` arm. Every one of them has to hand
        # the status on, or the surface it feeds silently loses the
        # distinction again.
        loops = len(re.findall(r"case\s+\.perception\(", source))
        handled = len(re.findall(r"case\s+\.failure\(let status\)", source))
        forwarded = len(re.findall(r"StreamedFailure\.http\(status:\s*status\)", source))
        contract.check(
            loops > 0 and handled >= loops and forwarded >= loops,
            f"{relative} hands every streamed status to the mapper "
            f"({handled}/{loops} handled, {forwarded} forwarded)",
        )


def balanced_call(source: str, open_paren: int) -> str:
    """The argument list of the call whose `(` is at `open_paren`."""
    depth = 0
    for index in range(open_paren, len(source)):
        if source[index] == "(":
            depth += 1
        elif source[index] == ")":
            depth -= 1
            if depth == 0:
                return source[open_paren : index + 1]
    return source[open_paren:]


def rendered_literals(source: str) -> list[str]:
    """String literals that a user actually reads.

    A keyboard legitimately names a request it builds; that is not copy. Only
    arguments of rendering calls and assignments to rendered UIKit properties
    are judged as consumer vocabulary.
    """
    source = strip_comments(source)
    literals: list[str] = []
    for call in RENDER_CALLS:
        start = 0
        while True:
            found = source.find(call, start)
            if found < 0:
                break
            literals += string_literals(balanced_call(source, found + len(call) - 1))
            start = found + len(call)
    for assignment in RENDER_ASSIGNMENTS:
        start = 0
        while True:
            found = source.find(assignment, start)
            if found < 0:
                break
            end = source.find("\n", found)
            literals += string_literals(source[found : end if end > 0 else len(source)])
            start = found + len(assignment)
    return literals


def without_interpolation(literal: str) -> str:
    """Drop `\\(…)` segments — those are code, not copy.

    Raw failures reaching copy through interpolation are caught structurally
    by `scan_no_raw_error_reaches_a_surface`, which is strictly stronger than
    matching vocabulary against an expression.
    """
    return re.sub(r"\\\([^()]*(?:\([^()]*\)[^()]*)*\)", "", literal)


def discover_consumer_surfaces(contract: Contract) -> None:
    """The surface list is derived from the project, not trusted.

    Build 112's first contract asserted whole-surface coverage over a
    hand-written list that omitted the keyboard, Share, and Messages. This
    reads the Sources phase of every shipped target and fails if any file
    that renders UI is missing from `RENDERING_SURFACES`.
    """
    project = contract.read("Tono.xcodeproj/project.pbxproj")
    shipped: set[str] = set()
    for target in SHIPPED_TARGETS:
        shipped |= pbx_source_files(project, target)

    declared = set(RENDERING_SURFACES)
    discovered: list[str] = []
    for directory in PRODUCTION_DIRS:
        for swift in sorted((ROOT / directory).rglob("*.swift")):
            if swift.name not in shipped:
                continue
            source = strip_comments(swift.read_text())
            if any(re.search(marker, source) for marker in SURFACE_MARKERS):
                discovered.append(str(swift.relative_to(ROOT)))

    missing = sorted(set(discovered) - declared)
    contract.check(
        not missing,
        f"every shipped source that renders UI is under contract (unjudged: {missing})",
    )
    absent = sorted(relative for relative in declared if not (ROOT / relative).exists())
    contract.check(not absent, f"every contracted surface exists on disk {absent}")


def scan_no_raw_error_reaches_a_surface(contract: Contract) -> None:
    """No consumer surface may contain a raw-failure expression at all.

    This is the assertion the first Build 112 contract lacked. It judges
    expressions, so `errorMessage = error.localizedDescription` fails without
    any string literal being involved.
    """
    for relative in RENDERING_SURFACES:
        path = ROOT / relative
        if not path.exists():
            contract.check(False, f"{relative} exists")
            continue
        source = strip_comments(path.read_text())
        offenders: list[str] = []
        for pattern, why in RAW_ERROR_EXPRESSIONS:
            for match in re.finditer(pattern, source):
                line = source.count("\n", 0, match.start()) + 1
                offenders.append(f"line {line}: {match.group(0)!r} {why}")
        contract.check(
            not offenders,
            f"{relative} never turns a raw failure into consumer text"
            + ("" if not offenders else f" — {offenders[:4]}"),
        )


def scan_failure_state_is_mapped(contract: Contract) -> None:
    """Rendered failure state is fixed copy or an approved mapper's output.

    The raw-expression ban says a failure cannot be *formatted* onto a
    surface. This says it cannot be *assigned* to one either — the two
    together leave no path from an `Error` to a screen that skips the mapper.
    """
    for relative in RENDERING_SURFACES:
        path = ROOT / relative
        if not path.exists():
            continue
        source = strip_comments(path.read_text())
        # Build 113: the identifiers that hold a failure *in this file*, not a
        # fixed list. `let cause = error` is one line of laundering and the
        # old head-anchored rule could not see through it.
        tainted = tainted_identifiers(source)
        offenders: list[str] = []
        for sink in FAILURE_STATE_SINKS:
            for match in re.finditer(sink, source):
                rhs = match.group("rhs").strip()
                if not rhs or rhs.startswith("nil"):
                    continue
                if any(mapper in rhs for mapper in APPROVED_ERROR_MAPPERS):
                    continue
                # Judge the whole right-hand side, not just its first token.
                # A failure reached the screen through `(error as NSError)…`
                # and through `{ let ns = error … }()` because both begin with
                # punctuation. Literal text drops out; interpolations do not,
                # because an interpolation is code that gets rendered.
                code, interpolated = split_literals(rhs)
                named = mentions(tainted, code + " " + " ".join(interpolated))
                if named:
                    line = source.count("\n", 0, match.start()) + 1
                    offenders.append(f"line {line}: {named} in {rhs[:70]!r}")
        contract.check(
            not offenders,
            f"{relative} shows only fixed copy or mapped failures"
            + ("" if not offenders else f" — {offenders[:4]}"),
        )


def scan_consumer_error_mapper(contract: Contract) -> None:
    """The one file allowed to author failure copy is pinned exactly."""
    path = ROOT / CONSUMER_ERROR_COPY
    if not contract.check(path.exists(), f"{CONSUMER_ERROR_COPY} exists"):
        return
    source = strip_comments(path.read_text())

    unknown = sorted(set(string_literals(source)) - CONSUMER_ERROR_SENTENCES)
    contract.check(
        not unknown,
        f"the failure mapper authors only reviewed sentences (unreviewed: {unknown[:4]})",
    )

    for action, headline, next_step in REQUIRED_ACTION_SENTENCES:
        contract.check(
            headline in source and next_step in source,
            f"the mapper keeps {action} distinct: {headline!r} + {next_step!r}",
        )

    # Case shape only. A mapper that reads the payload is a mapper that will
    # print a status line the first time a transport puts one there.
    body = body_of(source, "private static func classify(_ error: Error) -> Recovery")
    contract.check(
        "localizedDescription" not in body and "String(describing:" not in body,
        "the mapper classifies a failure by case, never by its message",
    )
    for family in [
        "TonoBackendError",
        "ToneEngineError",
        "StoreKitManager.StoreError",
        "URLError",
        "StreamedFailure",
    ]:
        contract.check(family in body, f"the mapper classifies {family}")

    project = contract.read("Tono.xcodeproj/project.pbxproj")
    missing = [
        target
        for target in SHIPPED_TARGETS
        if "ConsumerErrorCopy.swift" not in pbx_source_files(project, target)
    ]
    contract.check(
        not missing,
        f"the failure mapper compiles into every shipped target (missing from {missing})",
    )
    build_files = re.findall(
        r"^\s*([A-F0-9]{24}) /\* ConsumerErrorCopy\.swift in Sources \*/ = "
        r"\{isa = PBXBuildFile; fileRef = ([A-F0-9]{24}) ",
        project,
        re.MULTILINE,
    )
    file_refs = re.findall(
        r"^\s*([A-F0-9]{24}) /\* ConsumerErrorCopy\.swift \*/ = \{isa = PBXFileReference;",
        project,
        re.MULTILINE,
    )
    contract.check(
        len(file_refs) == 1
        and len(build_files) == len(SHIPPED_TARGETS)
        and all(ref == file_refs[0] for _, ref in build_files),
        "the failure mapper has exactly one file reference and one build file per shipped target",
    )


def scan_rendered_copy(contract: Contract) -> None:
    """Consumer vocabulary, judged on what is rendered rather than on a file.

    The whole-file scan stays in force for `App/` and the copy files. This
    adds the surfaces that also build requests — a keyboard names a host and
    a status code because that is the request, not the copy.
    """
    for relative in RENDERING_SURFACES:
        path = ROOT / relative
        if not path.exists():
            continue
        raw = path.read_text()
        offenders: list[str] = []
        for debug in (False, True):
            mode = "DEBUG" if debug else "Release"
            for literal in rendered_literals(preprocess(raw, debug=debug)):
                haystack = without_interpolation(literal).lower()
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
            f"{relative} renders no implementation detail"
            + ("" if not offenders else f" — {offenders[:4]}"),
        )


def scan_live_tone_timer_confinement(contract: Contract) -> None:
    """The debounce timer's lifecycle stays on one queue each.

    Build 112's full test run trapped in `CFRelease` because the main queue
    re-read `pendingTimer` while the engine's serial queue was writing it.
    The fix is structural: the main queue only ever sees a captured instance.
    """
    engine = contract.read("KeyboardExtension/LiveToneEngine.swift")
    schedule = body_of(strip_comments(engine), "private func scheduleTimer(draft: String, boundHash: Int)")
    cancel = body_of(strip_comments(engine), "private func cancelTimer()")

    contract.check(
        "self.pendingTimer" not in schedule,
        "the debounce scheduler never re-reads pendingTimer from the main queue",
    )
    contract.check(
        "RunLoop.main.add(timer, forMode: .common)" in schedule,
        "the debounce timer is still installed on the main run loop",
    )
    contract.check(
        "DispatchQueue.main.async" in cancel and "timer.invalidate()" in cancel,
        "the debounce timer is invalidated on the run loop it was added to",
    )
    contract.check(
        "deinit" not in strip_comments(engine),
        "the engine does not touch queue-confined timer state from deinit",
    )
    contract.check(
        "public static let debounceInterval: TimeInterval = 0.500" in engine,
        "the 500 ms debounce window is unchanged",
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
    scan_rate_limit_is_not_a_paywall(contract)
    scan_streaming_preserves_status(contract)
    discover_consumer_surfaces(contract)
    scan_no_raw_error_reaches_a_surface(contract)
    scan_failure_state_is_mapped(contract)
    scan_consumer_error_mapper(contract)
    scan_rendered_copy(contract)
    scan_live_tone_timer_confinement(contract)
    scan_build111_preservation(contract)
    scan_release_identity(contract)

    print(f"\nBuild 112 UI consolidation contract: {len(contract.failures)} failure(s)")
    for failure in contract.failures:
        print(f" - {failure}")
    return 1 if contract.failures else 0


if __name__ == "__main__":
    sys.exit(main())
