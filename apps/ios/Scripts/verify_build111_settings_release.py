#!/usr/bin/env python3
"""Build 111 Settings release-lineage regression contract."""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SETTINGS = ROOT / "App" / "SettingsView.swift"
MANAGER = ROOT / "App" / "RecipientsManagerView.swift"
PROJECT = ROOT / "Tono.xcodeproj" / "project.pbxproj"


def strip_comments(source: str) -> str:
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
    """Evaluate the DEBUG conditions used by this source, including #else."""
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


def string_literals(source: str) -> list[str]:
    """Return ordinary Swift string literals, which are the consumer-visible copy."""
    return [
        match.group(0)[1:-1]
        for match in re.finditer(r'"(?:\\.|[^"\\])*"', source)
    ]


def pbx_object(project: str, object_id: str) -> str:
    match = re.search(
        rf"^\s*{re.escape(object_id)}(?: /\*.*?\*/)? = \{{(.*?)^\s*\}};",
        project,
        re.MULTILINE | re.DOTALL,
    )
    if not match:
        raise AssertionError(f"missing project object {object_id}")
    return match.group(1)


def check(condition: bool, message: str, failures: list[str]) -> None:
    if condition:
        print(f"PASS: {message}")
    else:
        failures.append(message)
        print(f"FAIL: {message}")


def main() -> int:
    failures: list[str] = []
    settings_raw = SETTINGS.read_text()
    manager_raw = MANAGER.read_text() if MANAGER.exists() else ""
    project = PROJECT.read_text()
    release = preprocess(settings_raw, debug=False)
    debug = preprocess(settings_raw, debug=True)
    settings_body = body_of(release, "struct SettingsView")
    release_copy = "\n".join(string_literals(settings_body))
    recipients_body = body_of(release, "private var recipientsSection")

    forbidden_release = [
        "Endpoint",
        "Custom backend URL",
        "Test Connection",
        "api.tonoit.com",
        "staging",
        "non-2xx",
        "Server error",
        "Backend unreachable",
        "backend",
        "server",
        "API key",
        "bearer token",
        "UserDefaults",
        "proxy",
        "LLM",
    ]
    for term in forbidden_release:
        check(
            term.lower() not in release_copy.lower(),
            f"Release Settings excludes {term!r}",
            failures,
        )

    for term in [
        "ForEach(recipients",
        ".swipeActions",
        'Button("Add manually")',
        'Label("Contacts Access & Import"',
        ".sheet(isPresented: $showAddRecipient)",
    ]:
        check(
            term not in recipients_body,
            f"Settings recipient section excludes direct roster UI {term!r}",
            failures,
        )

    check(
        "RecipientsSettingsSummary(" in recipients_body
        and "NavigationLink" in recipients_body
        and "RecipientsManagerView()" in recipients_body,
        "Settings has one compact summary/navigation row",
        failures,
    )
    check(
        "SetupDoctorView()" in settings_body,
        "Setup Doctor remains reachable from Settings",
        failures,
    )

    # SUPERSEDED BY BUILD 112. This contract used to require the DEBUG endpoint
    # diagnostics to survive in an internal build. The founder's Build 112
    # correction — "backend details still showing" — removed that allowance:
    # no user-reachable app UI may carry them under ANY compilation mode.
    # `Scripts/verify_build112_ui_consolidation.py` owns the whole-surface scan;
    # the line below keeps this older lane honest about the same rule.
    for term in ["Endpoint", "Custom backend URL", "Test Connection", "api.tonoit.com"]:
        check(term not in debug, f"Debug build also excludes {term!r}", failures)

    check(
        "struct RecipientsManagerView" in manager_raw
        and ".searchable(" in manager_raw
        and "ForEach(filtered)" in manager_raw
        and "ContactsAccessView(model: contacts)" in manager_raw,
        "dedicated manager is reachable, searchable, lazy, and owns access management",
        failures,
    )
    file_refs = re.findall(
        r"^\s*([A-F0-9]{24}) /\* RecipientsManagerView\.swift \*/ = "
        r"\{isa = PBXFileReference;",
        project,
        re.MULTILINE,
    )
    build_files = re.findall(
        r"^\s*([A-F0-9]{24}) /\* RecipientsManagerView\.swift in Sources \*/ = "
        r"\{isa = PBXBuildFile; fileRef = ([A-F0-9]{24}) ",
        project,
        re.MULTILINE,
    )
    membership_is_exact = len(file_refs) == 1 and len(build_files) == 1
    if membership_is_exact:
        build_id, referenced_file_id = build_files[0]
        source_phases = re.findall(
            r"^\s*([A-F0-9]{24}) /\* Sources \*/ = \{"
            r"(.*?runOnlyForDeploymentPostprocessing = 0;\s*\};)",
            project,
            re.MULTILINE | re.DOTALL,
        )
        containing_phases = [
            phase_id for phase_id, body in source_phases if build_id in body
        ]
        tono_targets = re.findall(
            r"^\s*([A-F0-9]{24}) /\* Tono \*/ = \{"
            r"(.*?productType = \"com\.apple\.product-type\.application\";\s*\};)",
            project,
            re.MULTILINE | re.DOTALL,
        )
        membership_is_exact = (
            referenced_file_id == file_refs[0]
            and len(containing_phases) == 1
            and len(tono_targets) == 1
            and containing_phases[0] in tono_targets[0][1]
            and project.count(f"{file_refs[0]} /* RecipientsManagerView.swift */,") == 1
        )
    check(
        membership_is_exact,
        "recipient manager has exact app target membership",
        failures,
    )

    print(f"\nBuild 111 Settings contract: {len(failures)} failure(s)")
    if failures:
        for failure in failures:
            print(f" - {failure}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
