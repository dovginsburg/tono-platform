// LiveToneOpportunityFixtures.swift
// Tono Live Tone — the positive-opportunity fixture matrix (build 97).
//
// The binding "Tono Live Tone Positive Opportunity Version Contract —
// 2026-07-21" defines a matrix of 20 positive fixtures and 20 minimally
// mutated near-miss controls across the five families O1–O5, and requires
// all 40 to be executable now with per-build expectations:
//
//   * Build 96 — O1–O5 all silent.
//   * Build 97 — O1–O3 follow their positive/control expectations; O4–O5
//     remain silent.
//   * Build 98 — O4–O5 may activate, only after the evidence gate.
//
// This file is the single source of truth for that matrix, referenced by
// both the XCTest acceptance suite and the standalone swiftc verifier so
// they exercise byte-identical fixtures. Each control is a minimal
// mutation of its paired positive that drops it just under the family's
// firing rule (a removed hedge, a condolence sorry, a lower-cased or
// allow-listed caps token, a sub-floor length), demonstrating the exact
// boundary the contract draws.
//
// Provenance note: the canonical pasted Fable matrix document was
// inaccessible (hard file-lock held by a concurrent build lane) when this
// implementation lane ran, so every fixture below is authored directly to
// the canonical contract's exact firing rules and exercises each rule's
// positive case and its near-miss boundary. The expectations are derived
// mechanically from the contract, not from any mutable candidate.
//
// Pure Foundation. No UIKit, no networking.

import Foundation

// MARK: - Fixture model

public struct LiveToneOpportunityFixture: Equatable {

    public enum Kind: String, Equatable {
        case positive
        case control
    }

    /// What the classifier must do for this fixture under a given build.
    public enum Expectation: Equatable {
        case fires(LiveToneOpportunityFamily)
        case silent
    }

    /// The family this fixture belongs to in the matrix.
    public let family: LiveToneOpportunityFamily
    public let kind: Kind
    public let text: String

    public init(_ family: LiveToneOpportunityFamily, _ kind: Kind, _ text: String) {
        self.family = family
        self.kind = kind
        self.text = text
    }

    /// Build-96 expectation: every family silent.
    public var build96: Expectation { .silent }

    /// Build-97 expectation: O1–O3 follow positive/control; O4–O5 silent.
    public var build97: Expectation {
        guard family.isActiveInBuild97 else { return .silent }
        switch kind {
        case .positive: return .fires(family)
        case .control: return .silent
        }
    }

    /// Build-98 expectation: O1–O5 follow positive/control (post-gate).
    public var build98: Expectation {
        switch kind {
        case .positive: return .fires(family)
        case .control: return .silent
        }
    }
}

// MARK: - The 40-fixture matrix

public enum LiveToneOpportunityMatrix {

    /// 20 positive fixtures + 20 near-miss controls, four of each per
    /// family, ordered O1 → O5.
    public static let all: [LiveToneOpportunityFixture] = o1 + o2 + o3 + o4 + o5

    public static var positives: [LiveToneOpportunityFixture] { all.filter { $0.kind == .positive } }
    public static var controls: [LiveToneOpportunityFixture] { all.filter { $0.kind == .control } }

    // O1 — Hedge stack / confidence opportunity (flagship).
    // Positive: >= 2 distinct hedges in one sentence, or >= 3 across the
    // message, at >= 5 words. Control: minimal mutation under the rule
    // (single hedge, gated "just"/"I think" that does not count, or a
    // two-hit sentence below the five-word floor).
    static let o1: [LiveToneOpportunityFixture] = [
        .init(.hedge, .positive, "I think maybe we could possibly revisit this later"),
        .init(.hedge, .positive, "just wondering if maybe you had a chance to look"),
        .init(.hedge, .positive, "perhaps we could kind of revisit this if that makes sense"),
        .init(.hedge, .positive, "I maybe missed it. Perhaps later. Possibly tomorrow works better."),
        .init(.hedge, .control, "just landed at the airport and heading over now"),
        .init(.hedge, .control, "I think you should reconsider the whole plan tomorrow"),
        .init(.hedge, .control, "maybe we can grab lunch sometime this week"),
        .init(.hedge, .control, "maybe perhaps though"),
    ]

    // O2 — Apology stack.
    // Positive: >= 2 sorry/apolog* tokens. Control: minimal mutation
    // (single apology, or the sorry(s) are condolence phrases that do not
    // count).
    static let o2: [LiveToneOpportunityFixture] = [
        .init(.apology, .positive, "Sorry, sorry, I didn't mean to bother you again"),
        .init(.apology, .positive, "I'm so sorry, I apologize for the delay again"),
        .init(.apology, .positive, "Apologies for the confusion, and sorry again for everything"),
        .init(.apology, .positive, "sorry to interrupt, sorry to ask, but could you help"),
        .init(.apology, .control, "I'm so sorry for your loss, my heart goes out to you"),
        .init(.apology, .control, "So sorry to hear about the news, thinking of you"),
        .init(.apology, .control, "Sorry I'm late, traffic was brutal this morning"),
        .init(.apology, .control, "sorry for your loss and sorry to hear about everything"),
    ]

    // O3 — Caps emphasis.
    // Positive: >= 1 all-caps alphabetic token of >= 4 letters at >= 3
    // words. Control: minimal mutation (lower-cased token, an allow-listed
    // acronym/abbreviation, or a real caps token below the three-word
    // floor).
    static let o3: [LiveToneOpportunityFixture] = [
        .init(.caps, .positive, "please STOP doing that right now"),
        .init(.caps, .positive, "this is REALLY important okay"),
        .init(.caps, .positive, "I need it DONE today"),
        .init(.caps, .positive, "we NEED to talk about this"),
        .init(.caps, .control, "please stop doing that right now"),
        .init(.caps, .control, "OMG that is so funny lol"),
        .init(.caps, .control, "running LATE"),
        .init(.caps, .control, "just booked the ASAP delivery for tomorrow"),
    ]

    // O4 — Brisk request. Deferred: silent in build 97. Positives are the
    // intended build-98 targets; controls are polite near-misses. All silent
    // now.
    static let o4: [LiveToneOpportunityFixture] = [
        .init(.briskRequest, .positive, "Send it now."),
        .init(.briskRequest, .positive, "Call me back immediately."),
        .init(.briskRequest, .positive, "Do this today, no excuses."),
        .init(.briskRequest, .positive, "Get it done before noon."),
        .init(.briskRequest, .control, "Could you send it when you get a chance?"),
        .init(.briskRequest, .control, "Whenever works for you is fine."),
        .init(.briskRequest, .control, "Let me know if that works for you."),
        .init(.briskRequest, .control, "Happy to wait until you are free."),
    ]

    // O5 — Flat refusal. Deferred: silent in build 97. Positives are the
    // intended build-98 targets; controls are softened near-misses. All
    // silent now.
    static let o5: [LiveToneOpportunityFixture] = [
        .init(.flatRefusal, .positive, "No."),
        .init(.flatRefusal, .positive, "Not happening."),
        .init(.flatRefusal, .positive, "I said no."),
        .init(.flatRefusal, .positive, "Absolutely not."),
        .init(.flatRefusal, .control, "I don't think that will work for me."),
        .init(.flatRefusal, .control, "Unfortunately I can't make it this time."),
        .init(.flatRefusal, .control, "That won't be possible, but thank you for asking."),
        .init(.flatRefusal, .control, "I'd love to but I can't right now."),
    ]
}
