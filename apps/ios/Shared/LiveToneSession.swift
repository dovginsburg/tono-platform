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

public enum LiveToneVisibleWarning: Equatable, Codable {
    case none
    case l1(LiveToneCategory)
    case l2(LiveToneCategory)
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

    /// Apply a fresh verdict to the session. Crisis silence and benign
    /// drafts clear the warning; a visible warning is shown unless the
    /// user has dismissed this category for the current draft.
    public mutating func apply(verdict: LiveToneVerdict, draftHash: Int) {
        boundHash = draftHash

        guard let level = verdict.level, let category = verdict.category else {
            // .silent or .crisisSilence — clear the visible warning but
            // preserve per-draft dismissals for the remainder of the draft.
            warning = .none
            return
        }
        if dismissals.contains(category) {
            warning = .none
            return
        }
        switch level {
        case .l1: warning = .l1(category)
        case .l2: warning = .l2(category)
        }
    }

    /// Dismiss the currently visible warning. One dismissal silences the
    /// dismissed category for the remainder of the current draft.
    public mutating func dismissCurrent() {
        switch warning {
        case .l1(let category), .l2(let category):
            dismissals = dismissals.adding(category)
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