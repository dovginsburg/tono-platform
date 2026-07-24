// LiveToneSession.swift
// Tono Live Tone v1 — shipping release session state machine.
//
// Pure, Foundation-only session lifecycle that maps each evaluation
// verdict onto a visible warning for the integration lane:
//
//   * .silent verdict          → .none
//   * .crisisSilence verdict   → .none (Mira GO)
//   * verdict(level: L1)       → .l1(category) — until dismissed
//   * verdict(level: L2)       → .l2(category) — until dismissed
//
// Per-draft suppression: one dismissal silences the dismissed category
// for the remainder of the current draft. `fieldReset` (driven by the
// integration lane when a new text field / editing session begins)
// clears every per-draft suppression.
//
// Pure Foundation. No UIKit, no timers, no networking, no persistence.

import Foundation

// MARK: - Visible warning

/// Visible state surfaced by the integration lane. Precedence (high→low):
/// `.l2 > .l1 > .opportunity > .none`. O4/O5 are deliberately absent —
/// they stay silent under the release-gated `activeFamilies` set.
public enum LiveToneVisibleWarning: Equatable, Codable {
    case none
    case l1(LiveToneCategory)
    case l2(LiveToneCategory)
    /// Build 97 positive-opportunity surface. Distinct from the red
    /// lane so an opportunity chip never renders red, never coexists
    /// with a red warning, and never surfaces for pure self-directed
    /// crisis text.
    case opportunity(LiveToneOpportunityFamily)
}

// MARK: - Dismissals

public struct LiveToneDismissals: Equatable, Codable {
    public private(set) var dismissed: Set<LiveToneCategory>

    public init(dismissed: Set<LiveToneCategory> = []) {
        self.dismissed = dismissed
    }

    public static let empty = LiveToneDismissals()

    public func contains(_ category: LiveToneCategory) -> Bool {
        dismissed.contains(category)
    }

    public func adding(_ category: LiveToneCategory) -> LiveToneDismissals {
        var copy = self
        copy.dismissed.insert(category)
        return copy
    }
}

// MARK: - Session

public struct LiveToneSession: Equatable {

    public private(set) var warning: LiveToneVisibleWarning
    public private(set) var dismissals: LiveToneDismissals

    /// Snapshot hash bound to the last applied verdict. The engine
    /// compares this against the in-flight hash to discard stale
    /// results.
    public private(set) var boundHash: Int?

    public init(
        warning: LiveToneVisibleWarning = .none,
        dismissals: LiveToneDismissals = .empty,
        boundHash: Int? = nil
    ) {
        self.warning = warning
        self.dismissals = dismissals
        self.boundHash = boundHash
    }

    public static func == (lhs: LiveToneSession, rhs: LiveToneSession) -> Bool {
        lhs.warning == rhs.warning &&
        lhs.dismissals == rhs.dismissals &&
        lhs.boundHash == rhs.boundHash
    }

    /// Apply a fresh verdict to the session. Precedence (high→low):
    /// crisis silence / red lane wins over the opportunity lane — the
    /// opportunity lane never coexists with an active red warning and
    /// never surfaces for pure self-directed crisis. Per-draft
    /// dismissals are honored for red only; opportunity chips are
    /// one-shot, one-fire-per-family, dismissed by the manager's
    /// per-family session store.
    public mutating func apply(
        verdict: LiveToneVerdict,
        opportunity: LiveToneOpportunityVerdict?,
        draftHash: Int
    ) {
        boundHash = draftHash

        // 1. Red lane wins. A visible warning or a non-trivial verdict
        //    drives the surface; the opportunity lane stays silent.
        if let level = verdict.level, let category = verdict.category {
            if dismissals.contains(category) {
                warning = .none
                return
            }
            switch level {
            case .l1: warning = .l1(category)
            case .l2: warning = .l2(category)
            }
            return
        }

        // 2. .silent or .crisisSilence: clear the red surface, then
        //    surface the opportunity chip if the classifier fired.
        //    Crisis silence keeps the surface fully silent — the
        //    opportunity lane is also suppressed under crisis per the
        //    contract (crisis = total silence, never an amber chip).
        if verdict.category == .crisis {
            warning = .none
            return
        }

        if let opportunity {
            warning = .opportunity(opportunity.family)
        } else {
            warning = .none
        }
    }

    /// Apply a fresh verdict to the session, keeping the legacy
    /// signature for callers that do not yet expose the opportunity
    /// lane. Internally forwards `nil` for the opportunity verdict.
    public mutating func apply(verdict: LiveToneVerdict, draftHash: Int) {
        apply(verdict: verdict, opportunity: nil, draftHash: draftHash)
    }

    /// Dismiss the currently visible warning. One dismissal silences the
    /// dismissed category for the remainder of the current draft.
    /// Opportunity dismissals are reported via `didDismissOpportunity`
    /// so the manager can update the per-family session store.
    public mutating func dismissCurrent() {
        switch warning {
        case .l1(let category), .l2(let category):
            dismissals = dismissals.adding(category)
            warning = .none
        case .opportunity:
            warning = .none
        case .none:
            break
        }
    }

    /// Field / editing-session boundary. Clears every per-draft
    /// suppression and any pending warning.
    public mutating func fieldReset() {
        dismissals = .empty
        warning = .none
        boundHash = nil
    }
}