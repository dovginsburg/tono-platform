// LiveToneEligibility.swift
// Tono Live Tone v1 — shipping release eligibility / exclusion logic.
//
// Pure, Foundation-only. Decides whether Live Tone v1's on-device
// heuristic is allowed to run at all on the current field. The v1
// contract collapses the build-90 experiment's host-category allowlist
// and remote-disable directive: the only remaining gates are the
// master toggle (default ON) and a small set of field-shape exclusions
// iOS already protects against.
//
// Pure, deterministic. No I/O beyond the supplied `LiveTonePreference`
// and the supplied field context. Safe to call from any thread.
//
// Reference: `/Users/Ezra/Documents/Obsidian/Ezra/30 Systems/Tono Live Tone
// v1 Binding Acceptance Contract.md`.

import Foundation

// MARK: - Field context

/// Content description of the current field, assembled by the keyboard
/// integration from proxy traits it already reads. Text is included only
/// so the numeric-sensitivity heuristic can run locally; it is never
/// persisted or sent.
public struct LiveToneFieldContext: Equatable {
    /// iOS declines to load custom keyboards in secure fields, so this
    /// is a defense-in-depth belt.
    public var isSecureTextEntry: Bool
    /// Free-form text typed so far. Used only by the numeric-sensitivity
    /// heuristic.
    public var before: String
    public var after: String
    /// True when the most recent edit was a paste / bulk insertion
    /// rather than per-keystroke typing.
    public var lastInsertionWasBulk: Bool

    public init(
        isSecureTextEntry: Bool = false,
        before: String = "",
        after: String = "",
        lastInsertionWasBulk: Bool = false
    ) {
        self.isSecureTextEntry = isSecureTextEntry
        self.before = before
        self.after = after
        self.lastInsertionWasBulk = lastInsertionWasBulk
    }

    /// The visible draft the numeric-sensitivity heuristic inspects.
    public var composedDraft: String { before + after }
}

// MARK: - Decision

public enum LiveToneIneligibilityReason: Equatable {
    /// The master toggle is OFF. The classifier is not even invoked.
    case disabled
    case secureField
    case bulkInsertion
    case sensitiveNumericDraft
}

public enum LiveToneEligibilityDecision: Equatable {
    case eligible
    case ineligible(LiveToneIneligibilityReason)

    public var isEligible: Bool {
        if case .eligible = self { return true }
        return false
    }
}

// MARK: - Numeric sensitivity

/// Detects drafts shaped like credentials / OTPs / card numbers / SSNs —
/// content where reading the text would be especially harmful.
/// Deliberately conservative about *prose*: a message that merely
/// mentions a number stays eligible; a field whose whole content is
/// digits (grouped or not) does not.
public enum LiveToneSensitivity {

    /// Separators that commonly group digits in credentials.
    public static let separators: Set<Character> = [
        " ", "-", "_", ".", "/", "\\"
    ]

    /// Pure-function detection.
    public static func looksLikeCredential(_ draft: String) -> Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }

        let digitCount = trimmed.reduce(0) { $0 + ($1.isNumber ? 1 : 0) }
        guard digitCount >= 4 else { return false }

        let nonSeparatorCount = trimmed.reduce(0) { $0 + (separators.contains($1) ? 0 : 1) }
        guard nonSeparatorCount > 0 else { return false }

        // Pure digit strings (optionally grouped by separators) are the
        // classic credential/OTP/card/SSN shape.
        let allDigitsOrSeparators = trimmed.allSatisfy { $0.isNumber || separators.contains($0) }
        if allDigitsOrSeparators { return true }

        // Otherwise require the field to be digit-dense (e.g. "otp 492013",
        // "pin4821") so ordinary prose containing a stray number stays eligible.
        let ratio = Double(digitCount) / Double(nonSeparatorCount)
        return ratio >= 0.6
    }
}

// MARK: - Eligibility

public enum LiveToneEligibility {

    /// Pure eligibility decision. Evaluated in fail-closed order so the
    /// first tripped exclusion wins and an eligible verdict requires
    /// clearing every gate.
    ///
    /// - Parameters:
    ///   - context: content description of the current field.
    ///   - masterEnabled: resolved user master gate (see
    ///     `LiveTonePreference.masterEnabled`). Default ON.
    public static func evaluate(
        context: LiveToneFieldContext,
        masterEnabled: Bool
    ) -> LiveToneEligibilityDecision {
        guard masterEnabled else { return .ineligible(.disabled) }

        if context.isSecureTextEntry {
            return .ineligible(.secureField)
        }
        if context.lastInsertionWasBulk {
            return .ineligible(.bulkInsertion)
        }
        if LiveToneSensitivity.looksLikeCredential(context.composedDraft) {
            return .ineligible(.sensitiveNumericDraft)
        }
        return .eligible
    }
}