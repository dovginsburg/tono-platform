#!/usr/bin/env python3
"""Build 106 — structural gate for the three physically-rejected Build-105 defects.

This is a SOURCE-SHAPE gate, deliberately narrow. It cannot prove behaviour —
that is what Tests/Build106*.swift do against the real UIKit hierarchy and the
real engine. What it does prove is that the specific shapes that produced the
Build-105 rejections cannot come back by accident, which is the failure mode
that actually happened: the suggestion/Coach collision was invisible to review
because the strip *looked* correct and only the dispatch was wrong.

Run: python3 Scripts/verify_build106_contract.py
Exit 0 = every contract holds.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]

controller = (root / "KeyboardExtension/KeyboardViewController.swift").read_text()
routing = (root / "KeyboardExtension/TonoStripRouting.swift").read_text()
cursor = (root / "KeyboardExtension/AppleFidelity/SpaceCursorEngine.swift").read_text()
local = (root / "KeyboardExtension/LocalIntelligence.swift").read_text()
spelling = (root / "KeyboardExtension/SpellingCorrection.swift").read_text()
settings = (root / "App/SettingsView.swift").read_text()
project = (root / "Tono.xcodeproj/project.pbxproj").read_text()

routing_tests = (root / "Tests/Build106SuggestionRoutingTests.swift").read_text()
cursor_tests = (root / "Tests/Build106MultilineCursorTests.swift").read_text()
local_tests = (root / "Tests/Build106LocalIntelligenceTests.swift").read_text()

errors: list[str] = []


def check(condition: bool, message: str) -> None:
    if not condition:
        errors.append(message)


# ── A. A suggestion tap can never route to Coach ────────────────────────────
# The Build-105 defect in one line: `setToneChipsEnabled` mutated the live
# target/action table of shared buttons and never restored it.

check("removeTarget" not in controller,
      "A: the strip must never mutate a target/action table after construction "
      "(a removeTarget/addTarget pair is exactly how Build 105 welded suggestions to Coach)")

check(controller.count("#selector(candidateTapped(_:))") == 1,
      "A: candidateTapped must be bound exactly once, at construction")
check(controller.count("#selector(toneChipTapped(_:))") == 1,
      "A: toneChipTapped must be bound exactly once, at construction")

check("idToneChips" in controller and "idCandidates" in controller,
      "A: suggestions and tone chips must have separate accessibility identifiers")
check("makeStripStack(" in controller,
      "A: the two roles must be built as two separate stacks")
check("private func applyStripMode(" in controller,
      "A: exactly one row may be live at a time, under a single authority")
for guard in ("candidateStack?.isUserInteractionEnabled = showSuggestions",
              "toneChipStack?.isUserInteractionEnabled = !showSuggestions"):
    check(guard in controller,
          f"A: the inactive row must also be non-interactive, not merely hidden ({guard})")

check("TonoStripRoutingPolicy.decide(" in controller
      and controller.count("TonoStripRoutingPolicy.decide(") == 2,
      "A: BOTH handlers must pass through the routing gate")
for handler_marker in ("handlerRole: .suggestion", "handlerRole: .toneChip"):
    check(handler_marker in controller, f"A: routing gate missing for {handler_marker}")
check("case roleMismatch" in routing,
      "A: the Build-105 signature must be a named, countable refusal reason")
check("let stripRole: TonoStripRole" in routing and "let stripIndex: Int" in routing,
      "A: a strip button's role must be immutable identity, not mutable state")

# The Coach handler must not be reachable via `tag`, which any view can set.
chip_handler = re.search(r"@objc private func toneChipTapped\(_ sender: UIButton\) \{.*?\n    \}",
                         controller, re.S)
check(chip_handler is not None, "A: toneChipTapped not found")
if chip_handler:
    check("sender.tag" not in chip_handler.group(0),
          "A: Coach dispatch must not index off `tag` — Build 105 did, and tag is not identity")

check("hitRectsAreDisjoint" in routing,
      "A: expanded (44pt) hit regions must be checkable, not just drawn frames")
check("coachSeparation" in routing and "coachSeparation" in controller,
      "A: Coach/strip separation must be a reviewed constant applied in the layout")

# ── B. Offline local intelligence is real and visible ───────────────────────
check("SpellingLanguageResolver" in local and "SpellingLanguageResolver.resolve(" in spelling,
      "B: language must resolve against installed dictionaries, not an English-only prefix test")
check('prefix == "en"' not in spelling.replace("`prefix == \"en\"`", ""),
      "B: the Build-105 English-only gate must be gone from live code")
check("LocalLexicon" in local and "expansions" in local,
      "B: the user's own keyboard vocabulary and shortcut expansions must be modelled")
check("LocalCandidateRanker" in local and "isAdjacentKeySlip" in local and "isTransposition" in local,
      "B: contextual ranking signals missing")
check("LocalNextWordModel" in local,
      "B: continuation support missing")
check("LocalIntelligenceSelfTest" in local and "case disabled(reason:" in local,
      "B: the self-test must be able to report disabled truthfully, not only pass/fail")
check("URLSession" not in local and "URLRequest" not in local,
      "B: the local lane must contain no network I/O")

# Visibility: the keyboard states it, and the host app states it.
check("idLocalBadge" in controller and "badgeAccessibilityLabel" in controller,
      "B: the keyboard must carry an accessible on-device indicator")
check("candidateProvenance" in controller,
      "B: each suggestion must state its on-device provenance to VoiceOver")
check("localIntelligenceSection" in settings
      and "LocalIntelligenceSelfTest.run(" in settings
      and "SystemSpellingChecker()" in settings,
      "B: the host app must run the REAL shipping checker in its self-test")
check("localModelDisclosure" in settings,
      "B: the host app must state the on-device limits")

# No Apple Intelligence / QuickType claim anywhere in shipping copy.
disclosure = re.search(r'localModelDisclosure\s*=\s*\n?\s*"(.*?)"', local, re.S)
check(disclosure is not None, "B: localModelDisclosure not found")
if disclosure:
    text = disclosure.group(1).lower()
    check("not apple intelligence" in text,
          "B: the disclosure must explicitly deny Apple Intelligence parity")
check("coachRequiresInternet" in local and "case offline" in
      (root / "KeyboardExtension/TonoCoachClient.swift").read_text(),
      "B: Coach must fail with an honest internet-required state when offline")

# ── C. Multiline up/down ────────────────────────────────────────────────────
check("wrapWidth" in cursor and "wrappedRowStarts(" in cursor,
      "C: wrapped-row navigation missing")
check("usesEstimatedRows" in cursor,
      "C: estimated rows must be distinguishable from observed newlines")
check("SpaceCursorWrapEstimator" in cursor and "hostFieldWidthFraction" in cursor,
      "C: the wrap estimate must be a named, reviewable quantity")
check("supportsVerticalNavigation: Bool { rowStarts.count > 1 }" in cursor,
      "C: vertical navigation must be gated on rows, not on logical lines alone")
check("logicalLineStarts" in cursor,
      "C: exact logical-newline positions must still be tracked separately")
check("wrapWidthProvider" in cursor and "estimatedWrapWidth()" in controller,
      "C: the controller must supply the estimate, re-read per takeover")
# No parity claim.
check("parity" in cursor.lower() and "no claim of parity" in cursor.lower(),
      "C: the file must state plainly that this is not Apple wrapped-line parity")
# The engine still cannot delete. Checked against CODE, not prose: the file
# legitimately discusses the absence of `deleteBackward` in its proxy-seam
# comment, and a naive substring test would be satisfied by that comment.
cursor_code = "\n".join(
    line for line in cursor.splitlines()
    if not line.lstrip().startswith("//") and not line.lstrip().startswith("///")
)
check("case moveCaret" in cursor_code, "C: moveCaret effect missing")
check("deleteBackward" not in cursor_code,
      "C: the cursor engine must remain incapable of deleting text")
effect_enum = re.search(r"public enum Effect: Equatable \{.*?\n    \}", cursor, re.S)
check(effect_enum is not None, "C: Effect enum not found")
if effect_enum:
    effect_cases = re.findall(r"^\s*case (\w+)", effect_enum.group(0), re.M)
    check(sorted(effect_cases) == ["endedCursorMode", "enteredCursorMode",
                                   "insertSpace", "moveCaret", "none"],
          f"C: the Effect surface changed shape: {sorted(effect_cases)}")

# ── Tests exist, are wired, and include rollback-red controls ───────────────
for name, body in (("routing", routing_tests), ("cursor", cursor_tests), ("local", local_tests)):
    check("testRollbackRed_" in body,
          f"{name}: a rollback-red negative control is required")
for test_file in ("Build106SuggestionRoutingTests.swift",
                  "Build106MultilineCursorTests.swift",
                  "Build106LocalIntelligenceTests.swift"):
    check(project.count(f"{test_file} in Sources") == 2,
          f"{test_file} must be a member of the test target")
for source_file in ("TonoStripRouting.swift",):
    check(project.count(f"{source_file} in Sources") == 4,
          f"{source_file} must belong to the keyboard and test targets")
check(project.count("LocalIntelligence.swift in Sources") == 6,
      "LocalIntelligence.swift must belong to the keyboard, test and host-app targets")

# The physical fixture must be literally present, so the founder's exact
# observation stays represented in the suite.
check("two displayed lines" in cursor_tests.lower()
      or "wrappedTwoLines" in cursor_tests,
      "C: the two-displayed-line physical fixture must be present")

if errors:
    print('\n'.join('FAIL: ' + error for error in errors))
    sys.exit(1)

print("build106-contract: PASS — suggestion routing, local intelligence, multiline rows")
