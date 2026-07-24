// LiveToneOpportunitySession.swift
// Tono Live Tone — positive-opportunity session state machine (build 97).
//
// Pure, Foundation-only host-app-session lifecycle for the opportunity
// lane. Enforces the contract's "Alert discipline":
//
//   * Maximum one fire per family per host-app session.
//   * Dismissal suppresses that family for the rest of the session.
//   * Never re-fire on the same sentence after an edit unless a new
//     distinct signal appears.
//   * Families are independent — dismissing O1 never silences O2.
//
// This is deliberately SEPARATE from the red-lane `LiveToneSession`
// (which is per-draft and drives L1/L2 chips/banners). The opportunity
// lane is softer, lower priority, and session-scoped rather than
// draft-scoped, so it gets its own state machine and never perturbs the
// shipping red/crisis behavior.
//
// All state is in memory for the life of the host-app session and is
// never persisted or transmitted. `sentenceSignature` is a content-free
// hash; `signals` are content-free lexeme keys — the persisted counters
// (see `LiveToneOpportunityCounters`) hold integers only.
//
// Pure Foundation. No UIKit, no timers, no networking, no persistence.

import Foundation

public struct LiveToneOpportunitySession: Equatable {

    /// The single allowed fire for a family this session: the sentence it
    /// fired on and the distinct signals it fired with. The same-sentence
    /// refire guard compares against `signals`.
    private struct Fire: Equatable {
        var sentenceSignature: Int
        var signals: Set<String>
    }

    private var fires: [LiveToneOpportunityFamily: Fire]

    /// Families the user dismissed this session. Suppressed for the rest of
    /// the session.
    public private(set) var dismissedFamilies: Set<LiveToneOpportunityFamily>

    public init() {
        self.fires = [:]
        self.dismissedFamilies = []
    }

    // MARK: - Queries

    /// True once a family has taken its single session fire.
    public func hasFired(_ family: LiveToneOpportunityFamily) -> Bool {
        fires[family] != nil
    }

    /// True once a family has been dismissed this session.
    public func hasDismissed(_ family: LiveToneOpportunityFamily) -> Bool {
        dismissedFamilies.contains(family)
    }

    /// Families that have surfaced at least once this session.
    public var firedFamilies: Set<LiveToneOpportunityFamily> {
        Set(fires.keys)
    }

    // MARK: - Transitions

    /// Decide whether `verdict` should surface as an opportunity nudge.
    /// Returns the family to show, or `nil` to stay silent. Mutates the
    /// session to record the fire so the one-fire / same-sentence rules
    /// hold on subsequent evaluations.
    ///
    /// Precedence of the discipline rules:
    ///   1. Dismissed families are suppressed for the whole session.
    ///   2. A family that already fired this session stays silent UNLESS
    ///      it is the SAME sentence AND a NEW distinct signal has appeared
    ///      (the contract's sole re-fire carve-out).
    ///   3. Otherwise the family takes its one session fire and surfaces.
    @discardableResult
    public mutating func consider(
        _ verdict: LiveToneOpportunityVerdict?
    ) -> LiveToneOpportunityFamily? {
        guard let verdict else { return nil }
        let family = verdict.family

        // 1. Dismissal suppresses the family for the rest of the session.
        if dismissedFamilies.contains(family) { return nil }

        // 2. One fire per family per host-app session.
        if let prior = fires[family] {
            let sameSentence = prior.sentenceSignature == verdict.sentenceSignature
            let hasNewDistinctSignal = !verdict.signals.isSubset(of: prior.signals)
            guard sameSentence, hasNewDistinctSignal else {
                // Different sentence, or the same sentence with no new
                // distinct signal → do not re-fire.
                return nil
            }
            // Same sentence with a genuinely new distinct signal → allowed
            // to re-surface; fold the new signal into the recorded fire.
            fires[family] = Fire(
                sentenceSignature: verdict.sentenceSignature,
                signals: prior.signals.union(verdict.signals)
            )
            return family
        }

        // 3. First fire for this family this session.
        fires[family] = Fire(
            sentenceSignature: verdict.sentenceSignature,
            signals: verdict.signals
        )
        return family
    }

    /// The user dismissed the currently shown opportunity nudge. Suppresses
    /// that family for the remainder of the host-app session.
    public mutating func dismiss(_ family: LiveToneOpportunityFamily) {
        dismissedFamilies.insert(family)
    }

    /// A new host-app session began (keyboard reloaded into a new host
    /// app). Clears every one-fire mark and dismissal so a fresh session
    /// may nudge again.
    public mutating func hostSessionReset() {
        fires = [:]
        dismissedFamilies = []
    }
}
