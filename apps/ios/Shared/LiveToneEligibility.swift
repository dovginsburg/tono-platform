// LiveToneEligibility.swift
// Pure, Foundation-only eligibility/exclusion logic for Tono "Live Tone"
// (build-90 experiment). Given a content description of the current text
// field, it decides whether Live Tone's on-device check is even *allowed*
// to run. It never reaches for the network, never inspects the host bundle,
// and holds no state — every decision is a pure function of its inputs so
// it can be exhaustively unit-tested without UIKit or a simulator.
//
// Design rules (see /tmp/OPUS48_TONO_LIVE_PRIVACY.md):
//   * Fail closed: any uncertainty resolves to *ineligible*.
//   * No host fingerprinting: host identity only ever arrives as a
//     user-declared `LiveToneHostCategory`; this file never derives it.
//   * The keyboard integration builds `LiveToneFieldContext` from the
//     proxy traits it already has; this module stays UIKit-free.

import Foundation

// MARK: - Keyboard type mirror

/// Mirror of `UIKeyboardType` raw values so the pure module can reason about
/// field types without importing UIKit. The keyboard integration maps
/// `textDocumentProxy.keyboardType?.rawValue` through
/// `LiveToneKeyboardType(uiKeyboardTypeRawValue:)`.
public enum LiveToneKeyboardType: Int, CaseIterable, Equatable {
    case `default`             = 0
    case asciiCapable          = 1
    case numbersAndPunctuation = 2
    case url                   = 3
    case numberPad             = 4
    case phonePad              = 5
    case namePhonePad          = 6
    case emailAddress          = 7
    case decimalPad            = 8
    case twitter               = 9
    case webSearch             = 10
    case asciiCapableNumberPad = 11

    /// Maps a raw `UIKeyboardType` value (or nil, meaning `.default`) to a
    /// case. An unrecognized raw value collapses to `.default`, which is still
    /// subject to every other exclusion — it never bypasses a check.
    public init(uiKeyboardTypeRawValue raw: Int?) {
        guard let raw, let mapped = LiveToneKeyboardType(rawValue: raw) else {
            self = .default
            return
        }
        self = mapped
    }

    /// Field kinds Live Tone must never engage: address/identifier/number
    /// entry, where the "draft" is not free-form prose and is likely to hold
    /// credentials, contact details, or structured data.
    public var isExcludedFromLiveTone: Bool {
        switch self {
        case .emailAddress, .url, .numberPad, .decimalPad, .phonePad,
             .namePhonePad, .asciiCapableNumberPad, .numbersAndPunctuation:
            return true
        case .default, .asciiCapable, .twitter, .webSearch:
            return false
        }
    }
}

// MARK: - Host category (user-declared allowlist)

/// Coarse, user-declared host categories. These are the ONLY way host
/// context enters the eligibility decision — the module never infers them
/// from bundle IDs, URLs, or any private API. `nil` (unknown) is a
/// first-class, fail-closed state.
public enum LiveToneHostCategory: String, CaseIterable, Equatable, Codable {
    case messaging
    case email
    case social
    case notes
    case work
    case other
}

// MARK: - Field context

/// Content description of the current field, assembled by the integration
/// from proxy traits it already reads. Text is included only so the numeric-
/// sensitivity heuristic can run locally; it is never persisted or sent.
public struct LiveToneFieldContext: Equatable {
    /// iOS declines to load custom keyboards in secure fields, so this is a
    /// defense-in-depth belt to go with that suspenders.
    public var isSecureTextEntry: Bool
    public var keyboardType: LiveToneKeyboardType
    /// User-declared category for this field/host, or nil when unknown.
    public var hostCategory: LiveToneHostCategory?
    public var before: String
    public var selected: String?
    public var after: String
    /// True when the most recent edit was a paste / bulk insertion rather than
    /// per-keystroke typing. Set by the integration; a bulk edit is treated as
    /// untrusted content and suppresses Live Tone.
    public var lastInsertionWasBulk: Bool

    public init(
        isSecureTextEntry: Bool = false,
        keyboardType: LiveToneKeyboardType = .default,
        hostCategory: LiveToneHostCategory? = nil,
        before: String = "",
        selected: String? = nil,
        after: String = "",
        lastInsertionWasBulk: Bool = false
    ) {
        self.isSecureTextEntry = isSecureTextEntry
        self.keyboardType = keyboardType
        self.hostCategory = hostCategory
        self.before = before
        self.selected = selected
        self.after = after
        self.lastInsertionWasBulk = lastInsertionWasBulk
    }

    /// The visible draft the exclusion heuristics inspect.
    public var composedDraft: String {
        before + (selected ?? "") + after
    }
}

// MARK: - Decision

public enum LiveToneIneligibilityReason: Equatable {
    /// The user/remote master gate is off (opt-out, kill switch, or remote
    /// disable). Distinct from the field exclusions so callers can tell
    /// "you turned it off" apart from "this field isn't eligible".
    case disabled
    case secureField
    case excludedKeyboardType(LiveToneKeyboardType)
    case unknownHostCategory
    case hostCategoryNotAllowed(LiveToneHostCategory)
    case bulkInsertion
    case sensitiveNumericDraft
}

public enum LiveToneEligibilityDecision: Equatable {
    case eligible
    case ineligible(LiveToneIneligibilityReason)

    public var isEligible: Bool { self == .eligible }

    /// nil when eligible, otherwise the first tripped exclusion.
    public var reason: LiveToneIneligibilityReason? {
        if case let .ineligible(reason) = self { return reason }
        return nil
    }
}

// MARK: - Numeric sensitivity

/// Detects drafts shaped like credentials/OTPs/card numbers/SSNs — content
/// where sending text to Coach would be especially harmful. Deliberately
/// conservative about *prose*: a message that merely mentions a number stays
/// eligible; a field whose whole content is digits (grouped or not) does not.
public enum LiveToneSensitivity {

    /// Separators that commonly group digits in credentials.
    private static let separators: Set<Character> = [
        " ", "\t", "\n", "-", ".", "(", ")", "+", "/",
    ]

    public static func isSensitiveNumericDraft(_ draft: String) -> Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let digitCount = trimmed.reduce(0) { $0 + ($1.isNumber ? 1 : 0) }
        // Fewer than 4 digits can't be a card/SSN/OTP/PIN of interest.
        guard digitCount >= 4 else { return false }

        let nonSeparatorCount = trimmed.reduce(0) { $0 + (separators.contains($1) ? 0 : 1) }
        guard nonSeparatorCount > 0 else { return false }

        // Pure digit strings (optionally grouped by separators) are the classic
        // credential/OTP/card/SSN shape.
        let allDigitsOrSeparators = trimmed.allSatisfy { $0.isNumber || separators.contains($0) }
        if allDigitsOrSeparators { return true }

        // Otherwise require the field to be *digit-dense* (e.g. "otp 492013",
        // "pin4821") so ordinary prose containing a stray number stays eligible.
        let ratio = Double(digitCount) / Double(nonSeparatorCount)
        return ratio >= 0.6
    }
}

// MARK: - Eligibility

public enum LiveToneEligibility {

    /// Pure eligibility decision. Evaluated in fail-closed order so the first
    /// tripped exclusion wins and an eligible verdict requires clearing every
    /// gate.
    ///
    /// - Parameters:
    ///   - context: content description of the current field.
    ///   - allowedHostCategories: the user's declared allowlist of categories.
    ///   - masterEnabled: resolved user+remote master gate
    ///     (see `LiveTonePreference.masterEnabled`).
    public static func evaluate(
        context: LiveToneFieldContext,
        allowedHostCategories: Set<LiveToneHostCategory>,
        masterEnabled: Bool
    ) -> LiveToneEligibilityDecision {
        guard masterEnabled else { return .ineligible(.disabled) }

        if context.isSecureTextEntry {
            return .ineligible(.secureField)
        }
        if context.keyboardType.isExcludedFromLiveTone {
            return .ineligible(.excludedKeyboardType(context.keyboardType))
        }
        guard let category = context.hostCategory else {
            return .ineligible(.unknownHostCategory)
        }
        guard allowedHostCategories.contains(category) else {
            return .ineligible(.hostCategoryNotAllowed(category))
        }
        if context.lastInsertionWasBulk {
            return .ineligible(.bulkInsertion)
        }
        if LiveToneSensitivity.isSensitiveNumericDraft(context.composedDraft) {
            return .ineligible(.sensitiveNumericDraft)
        }
        return .eligible
    }
}
