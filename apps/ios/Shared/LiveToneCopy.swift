// LiveToneCopy.swift
// Tono Live Tone v1 — contract-exact user-facing copy.
//
// Every visible string in Live Tone lives here so a single edit keeps the
// shipping UI in lockstep with the binding Live Tone v1 Acceptance
// Contract. The acceptance tests assert these literals verbatim —
// paraphrasing breaks the contract.

import Foundation

public enum LiveToneCopy {

    // MARK: - L1 — Notice chip body. Subtle tint, no banner.

    public static let l1Chip = "This might land harsher than you mean."

    // MARK: - L2 — Strong banner body above the keyboard.

    public static let l2Banner =
        "This could read as hurtful or threatening. Want a Safer version?"

    // MARK: - L2 banner actions.

    public static let l2RewriteLabel = "Rewrite"
    public static let l2DismissLabel = "Dismiss"

    // MARK: - Settings row disclosure — exact wording per the contract.

    public static let settingsDisclosure =
        "Tono can flag messages that might land harshly. It never blocks or changes anything."

    // MARK: - Accessibility identifiers — stable for QA / screenshot diffs.

    public static let axBanner = "liveTone.v1.banner"
    public static let axChip = "liveTone.v1.chip"
    public static let axRewriteButton = "liveTone.v1.rewriteButton"
    public static let axDismissButton = "liveTone.v1.dismissButton"
}