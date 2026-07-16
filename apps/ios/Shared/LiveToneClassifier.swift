// LiveToneClassifier.swift
// Tono Live Tone v1.1 — build 90 experiment, Opus 4.8 core lane.
//
// A deterministic, versioned, fully local tone classifier. Its only input
// is the isolated current draft string; its only output is a binary
// hint / no-hint verdict plus the internal rule identifier that produced
// it. There is no ML, no networking, no I/O, no clock, and no state: the
// same draft always yields the same verdict.
//
// Design contract (see /tmp/OPUS48_TONO_LIVE_CORE.md):
//   * Bias hard for precision. The rules are a small allowlist of canonical
//     high-friction phrases that are almost never benign. False negatives
//     are acceptable because the manual Coach button remains available;
//     false positives erode trust in a passive, always-on decoration.
//   * Rules stay narrow. MockToneAnalyzer's heuristics are used only as
//     evidence for which phrases are load-bearing, not as licence to fold
//     in low-precision signals such as "message is short => cold".
//
// This file is pure Foundation. The static source guards in
// LiveToneCoreTests assert that it contains no networking, pasteboard,
// timer, persistence, or document-mutation tokens.

import Foundation

/// Internal identifier for the rule family that produced a verdict. Stable
/// raw values so verdicts can be logged as opaque tags without exposing any
/// draft text. `.none` means no rule matched (the no-hint verdict).
public enum LiveToneRule: String, CaseIterable, Equatable, Codable {
    /// No rule matched — the classifier is silent.
    case none
    /// Passive-aggressive "I already told you" / prior-message references.
    case priorMessageReference
    /// Hostile deflection of responsibility ("not my problem").
    case dismissiveDeflection
    /// Condescension and hedged insults ("no offense but", "calm down").
    case condescension
    /// Overtly sarcastic hostility ("thanks for nothing").
    case hostileSarcasm
}

/// The complete output of one classification. `shouldHint` is derived from
/// `rule` (any rule other than `.none` hints) so the two can never disagree.
public struct LiveToneVerdict: Equatable, Codable {
    public let shouldHint: Bool
    public let rule: LiveToneRule

    public init(rule: LiveToneRule) {
        self.rule = rule
        self.shouldHint = (rule != .none)
    }

    /// The silent verdict. Used for empty drafts and every fail-closed path.
    public static let silent = LiveToneVerdict(rule: .none)
}

/// Deterministic local classifier over an isolated draft string.
public struct LiveToneClassifier {
    /// Versioned so persisted or logged verdicts can be re-interpreted if the
    /// rule set ever changes. Bump on any change to the rules or matching.
    public static let version = 1

    /// Longest draft the classifier will scan. Drafts longer than this are
    /// truncated to a bounded prefix before matching so evaluation cost and
    /// allocation stay O(1) in the size of the field. A tonal marker that
    /// matters is essentially always near what the user is actively typing.
    public static let maxScannedCharacters = 2_000

    public init() {}

    /// Classify an isolated draft. Pure and total: never throws, never
    /// touches global state, and returns `.silent` for nil/empty input
    /// (fail closed).
    public func classify(_ draft: String?) -> LiveToneVerdict {
        guard let draft, !draft.isEmpty else { return .silent }
        let normalized = Self.normalize(draft)
        guard !normalized.isEmpty else { return .silent }
        // Rules are checked in a fixed order; the first family to match wins.
        // Order is deterministic and does not affect the binary verdict,
        // only which internal tag is reported.
        for rule in Self.orderedRules {
            if Self.markers(for: rule).contains(where: { normalized.contains($0) }) {
                return LiveToneVerdict(rule: rule)
            }
        }
        return .silent
    }

    // MARK: - Normalization

    /// Lower-case, fold smart punctuation to ASCII, and collapse runs of
    /// whitespace to single spaces so phrase markers match regardless of
    /// spacing or curly quotes. Locale-independent (`lowercased()` uses the
    /// Unicode default mapping) and therefore deterministic across devices.
    static func normalize(_ raw: String) -> String {
        // Take a bounded prefix directly. Advancing `prefix(_:)` stops after
        // `maxScannedCharacters` and never walks the whole field, so cost and
        // allocation stay O(maxScannedCharacters) — computing `raw.count`
        // first would be O(field size) and defeat the bound.
        let bounded = raw.prefix(maxScannedCharacters)
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(maxScannedCharacters)
        var lastWasSpace = false
        for scalar in bounded.lowercased().unicodeScalars {
            let folded = Self.fold(scalar)
            if folded == " " {
                if lastWasSpace { continue }
                lastWasSpace = true
                scalars.append(" ")
            } else {
                lastWasSpace = false
                scalars.append(folded)
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    /// Map curly quotes / dashes and any whitespace to canonical ASCII.
    private static func fold(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        switch scalar {
        case "\u{2018}", "\u{2019}", "\u{02BC}": return "'"   // ' ' ʼ
        case "\u{201C}", "\u{201D}": return "\""              // " "
        case "\u{2013}", "\u{2014}": return "-"               // – —
        default:
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return " " }
            return scalar
        }
    }

    // MARK: - Rule table

    /// Fixed evaluation order for reporting the matched rule id.
    static let orderedRules: [LiveToneRule] = [
        .priorMessageReference,
        .dismissiveDeflection,
        .condescension,
        .hostileSarcasm,
    ]

    /// The narrow, high-precision phrase allowlist per rule family. Every
    /// entry is already normalized (lower-case, ASCII quotes, single spaces)
    /// so it can be compared directly against `normalize(_:)` output.
    static func markers(for rule: LiveToneRule) -> [String] {
        switch rule {
        case .none:
            return []
        case .priorMessageReference:
            return [
                "as per my last",
                "per my last email",
                "per my last message",
                "per my previous email",
                "as previously discussed",
                "as previously stated",
                "as i already said",
                "as i already told you",
                "as i already mentioned",
                "as i said before",
                "as stated previously",
                "like i already said",
                "for the last time",
                "for the third time",
                "how many times do i have to",
            ]
        case .dismissiveDeflection:
            return [
                "not my problem",
                "not my job",
                "that's on you",
                "sounds like a you problem",
                "figure it out yourself",
                "do it yourself then",
                "not my responsibility",
            ]
        case .condescension:
            return [
                "you need to calm down",
                "would you calm down",
                "you need to relax",
                "with all due respect",
                "no offense but",
                "bless your heart",
                "are you even listening",
                "do i have to spell it out",
                "it's not rocket science",
            ]
        case .hostileSarcasm:
            return [
                "thanks for nothing",
                "cool story bro",
                "whatever you say",
                "if you say so",
                "wow, thanks",
                "k thanks bye",
            ]
        }
    }
}
