#!/usr/bin/env python3
"""Behavioral source-contract gate for the build-90 iMessage extension and the
Apple Shortcuts / App Intent lane.

verify_messages_extension.py proves the *structural* contract (embed phase,
signing attributes, icon set, bundle metadata). This file proves the
*behavioral* contract the reviewer cares about and which a project-file check
cannot see:

  iMessage:  compact -> expanded -> draft -> authenticated Coach -> select ->
             insert PLAIN TEXT into MSConversation, with visible safe errors,
             and NEVER an auto-sent MSMessage bubble.

  App Intent: auto-discoverable AppShortcutsProvider running Draft Message ->
              deliberate authenticated Coach -> returned String + dialog, with
              NO fake URL, clipboard, or auto-request behavior.

These are conservative substring/absence checks over the shipping source, so
the gate fails closed the moment someone regresses the flow (e.g. swaps
insertText back to a staged MSMessage, drops the auth gate, or bolts a
pasteboard/URL side effect onto the intent).
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MESSAGES_VC = ROOT / "TonoMessagesExtension/MessagesViewController.swift"
APP_INTENT = ROOT / "App/CoachDraftIntent.swift"


def check_messages(errors: list[str]) -> None:
    src = MESSAGES_VC.read_text()

    # Plain-text insertion into MSConversation (the contract's insert step).
    if "conversation.insertText(" not in src:
        errors.append("Messages: rewrite is not inserted via MSConversation.insertText(_:)")

    # Must NOT fabricate/stage an MSMessage bubble for the rewrite — that would
    # be a rich payload, not the plain draft text the contract requires.
    if "MSMessage(" in src or "conversation.insert(message" in src:
        errors.append("Messages: rewrite path stages an MSMessage bubble instead of plain text")

    # Authenticated Coach gate: the UI must fail closed when the account is not
    # set up, mirroring the App Intent, rather than firing an anonymous call.
    if "isRegistered" not in src:
        errors.append("Messages: Coach is not gated on TonoBackend registration")

    # Deliberate, user-driven Coach — not an automatic call on appear.
    if "analyzeStream" not in src:
        errors.append("Messages: Coach does not route through the shared ToneEngine backend")

    # Visible, safe errors rather than silent failure / raw print-only handling.
    if "errorMessage" not in src:
        errors.append("Messages: no visible error surface for failure paths")

    # Compact and expanded presentation states both exist.
    for token in (".compact", ".expanded"):
        if token not in src:
            errors.append(f"Messages: missing presentation state {token}")

    # No pasteboard side effects.
    if "UIPasteboard" in src:
        errors.append("Messages: touches UIPasteboard (forbidden clipboard behavior)")


def check_app_intent(errors: list[str]) -> None:
    src = APP_INTENT.read_text()

    # Auto-discoverable: an AppShortcutsProvider is what makes the intent
    # appear in Shortcuts/Spotlight automatically after install + first launch.
    if "AppShortcutsProvider" not in src:
        errors.append("App Intent: no AppShortcutsProvider (not auto-discoverable)")
    if ": AppIntent" not in src:
        errors.append("App Intent: no AppIntent conformance")

    # Draft Message parameter + returned String value + spoken/asked dialog.
    if "Draft Message" not in src:
        errors.append("App Intent: missing 'Draft Message' parameter")
    if "ReturnsValue<String>" not in src:
        errors.append("App Intent: does not return a String value")
    if "ProvidesDialog" not in src and "dialog:" not in src:
        errors.append("App Intent: does not return a dialog")

    # Deliberate authenticated Coach: gates on registration, runs in-process.
    if "isRegistered" not in src:
        errors.append("App Intent: Coach is not gated on registration (not authenticated)")
    if "analyzeStream" not in src:
        errors.append("App Intent: does not route through the shared ToneEngine backend")

    # Forbidden behaviors: no fake URL, clipboard, or auto-request side effects.
    forbidden = {
        "UIPasteboard": "clipboard",
        "shortcuts://": "fake shortcut-import URL",
        "import-workflow": "fake shortcut-import URL",
        "openURL": "URL side effect",
        "UIApplication": "app-level side effect",
        "registerIfNeeded": "auto-request of registration",
    }
    for token, label in forbidden.items():
        if token in src:
            errors.append(f"App Intent: forbidden {label} behavior ({token})")

    # Background intent (does not yank the user out of context).
    if "openAppWhenRun" in src and "openAppWhenRun: Bool = false" not in src and "openAppWhenRun = false" not in src:
        errors.append("App Intent: openAppWhenRun is not false")


def main() -> int:
    errors: list[str] = []
    for path in (MESSAGES_VC, APP_INTENT):
        if not path.is_file():
            errors.append(f"missing source file: {path.relative_to(ROOT)}")
    if not errors:
        check_messages(errors)
        check_app_intent(errors)
    if errors:
        print("\n".join(f"FAIL: {e}" for e in errors))
        return 1
    print("PASS: iMessage + App Intent behavioral contract (source)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
