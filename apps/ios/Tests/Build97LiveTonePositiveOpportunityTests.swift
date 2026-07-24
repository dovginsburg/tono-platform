// Build97LiveTonePositiveOpportunityTests.swift
// Build 97 — Live Tone positive-opportunity acceptance suite.
//
// Every case here binds the "Tono Live Tone Positive Opportunity Version
// Contract — 2026-07-21". The contract is binding; the opportunity
// classifier + session + counters are the implementation. When these
// tests fail, the implementation is wrong.
//
// Coverage:
//   * The complete 40-fixture Fable matrix (20 positive + 20 near-miss
//     controls across O1–O5), asserted under the build-97 gate (O1–O3
//     active, O4–O5 silent) and under the build-96 gate (all silent).
//   * O1 hedge thresholds, "just" / "I think" cognition-verb gate, five-
//     word floor, and the parameterizable release threshold.
//   * O2 apology stack with condolence suppression.
//   * O3 caps token rule with the bundled, updatable allowlist and the
//     three-word / four-letter floors.
//   * Session discipline: one fire per family per host-app session,
//     dismissal suppresses the family for the session, same-sentence
//     re-fire only with a new distinct signal, family independence.
//   * Content-free per-family counters and increments.
//   * Exact microcopy (describes the text, never the person).
//   * Red / crisis precedence preserved (opportunity lane consulted only
//     when the red lane is fully silent; crisis stays total silence).

import XCTest
import Foundation
@testable import Tono

// MARK: - The 40-fixture matrix

final class Build97OpportunityMatrixTests: XCTestCase {

    func testMatrixShape() {
        XCTAssertEqual(LiveToneOpportunityMatrix.all.count, 40, "matrix must have 40 fixtures")
        XCTAssertEqual(LiveToneOpportunityMatrix.positives.count, 20, "20 positive fixtures")
        XCTAssertEqual(LiveToneOpportunityMatrix.controls.count, 20, "20 near-miss controls")
        for family in LiveToneOpportunityFamily.allCases {
            let pos = LiveToneOpportunityMatrix.all.filter { $0.family == family && $0.kind == .positive }
            let ctl = LiveToneOpportunityMatrix.all.filter { $0.family == family && $0.kind == .control }
            XCTAssertEqual(pos.count, 4, "\(family.code) needs 4 positives")
            XCTAssertEqual(ctl.count, 4, "\(family.code) needs 4 controls")
        }
    }

    /// Build 97: O1–O3 follow their positive/control expectations; O4–O5
    /// remain silent.
    func testMatrixUnderBuild97() {
        let classifier = LiveToneOpportunityClassifier()
        for fixture in LiveToneOpportunityMatrix.all {
            assertExpectation(classifier.classify(fixture.text), fixture.build97,
                              label: "build97 \(fixture.family.code) \(fixture.kind.rawValue): \(fixture.text)")
        }
    }

    /// Build 96: every family silent (the release gate that shipped before
    /// the positive-opportunity launch).
    func testMatrixUnderBuild96IsSilent() {
        let classifier = LiveToneOpportunityClassifier(activeFamilies: [])
        for fixture in LiveToneOpportunityMatrix.all {
            XCTAssertNil(classifier.classify(fixture.text),
                         "build96 must be silent: \(fixture.text)")
        }
    }

    /// O4/O5 are deferred: they never fire in build 97, positive or control.
    func testDeferredFamiliesSilent() {
        let classifier = LiveToneOpportunityClassifier()
        for fixture in LiveToneOpportunityMatrix.all
        where fixture.family == .briskRequest || fixture.family == .flatRefusal {
            XCTAssertNil(classifier.classify(fixture.text),
                         "O4/O5 must stay silent in build 97: \(fixture.text)")
        }
    }

    private func assertExpectation(
        _ actual: LiveToneOpportunityVerdict?,
        _ expected: LiveToneOpportunityFixture.Expectation,
        label: String
    ) {
        switch expected {
        case .silent:
            XCTAssertNil(actual, "\(label): expected SILENT, got \(actual?.family.code ?? "nil")")
        case .fires(let family):
            XCTAssertEqual(actual?.family, family,
                           "\(label): expected \(family.code), got \(actual?.family.code ?? "SILENT")")
        }
    }
}

// MARK: - O1 / O2 / O3 rule boundaries

final class Build97OpportunityRuleTests: XCTestCase {

    private let c = LiveToneOpportunityClassifier()

    // O1 — flagship hedge stack.

    func testO1FiresOnTwoDistinctHedgesInASentence() {
        XCTAssertEqual(c.classify("I think maybe we could possibly revisit this later")?.family, .hedge)
    }

    func testO1FiresOnThreeDistinctHedgesAcrossTheMessage() {
        XCTAssertEqual(c.classify("I maybe missed it. Perhaps later. Possibly tomorrow works better.")?.family, .hedge)
    }

    func testO1SilentOnSingleHedge() {
        XCTAssertNil(c.classify("maybe we can grab lunch sometime this week"))
    }

    func testO1SilentBelowFiveWordFloor() {
        XCTAssertNil(c.classify("maybe perhaps though"))
    }

    func testO1JustCountsOnlyBeforeCognitionVerb() {
        XCTAssertEqual(c.classify("just wondering if maybe you had a chance to look")?.family, .hedge)
        XCTAssertNil(c.classify("just landed at the airport and heading over now"))
    }

    func testO1LoneIThinkStaysSilent() {
        XCTAssertNil(c.classify("I think you should reconsider the whole plan tomorrow"))
    }

    func testO1ReleaseThresholdIsParameterizable() {
        let strict = LiveToneOpportunityClassifier(hedgeSentenceThreshold: 3, hedgeMessageThreshold: 4)
        XCTAssertNil(strict.classify("I think maybe we could possibly revisit this later"),
                     "raising the threshold to 3 hits must silence a two-hit sentence")
    }

    // O2 — apology stack + condolence suppression.

    func testO2FiresOnTwoApologyTokens() {
        XCTAssertEqual(c.classify("Sorry, sorry, I didn't mean to bother you again")?.family, .apology)
        XCTAssertEqual(c.classify("I'm so sorry, I apologize for the delay again")?.family, .apology)
    }

    func testO2SilentOnSingleApology() {
        XCTAssertNil(c.classify("Sorry I'm late, traffic was brutal this morning"))
    }

    func testO2CondolenceDoesNotCount() {
        XCTAssertNil(c.classify("I'm so sorry for your loss, my heart goes out to you"))
        XCTAssertNil(c.classify("So sorry to hear about the news, thinking of you"))
        XCTAssertNil(c.classify("sorry for your loss and sorry to hear about everything"))
    }

    func testO2CondolencePlusOneGenuineIsStillSilent() {
        XCTAssertNil(c.classify("sorry to hear that, and sorry to interrupt again"),
                     "one condolence + one genuine apology is a single counting token")
        XCTAssertEqual(c.classify("sorry to interrupt, sorry to ask, but could you help")?.family, .apology)
    }

    // O3 — caps emphasis + bundled allowlist.

    func testO3FiresOnAllCapsAlphaTokenOfFourLetters() {
        XCTAssertEqual(c.classify("please STOP doing that right now")?.family, .caps)
        XCTAssertEqual(c.classify("this is REALLY important okay")?.family, .caps)
    }

    func testO3SilentOnLowerCaseControl() {
        XCTAssertNil(c.classify("please stop doing that right now"))
    }

    func testO3SilentBelowThreeWordFloor() {
        XCTAssertNil(c.classify("running LATE"))
    }

    func testO3AllowlistExemptsAcronyms() {
        XCTAssertNil(c.classify("just booked the ASAP delivery for tomorrow"))
        XCTAssertNil(c.classify("OMG that is so funny lol"))
        XCTAssertNil(c.classify("the CAR is fast"), "three-letter caps is under the four-letter floor")
    }

    func testO3AllowlistIsUpdatable() {
        let updated = LiveToneOpportunityClassifier(
            capsAllowlist: LiveToneCapsAllowlist.bundled.union(["STOP"])
        )
        XCTAssertNil(updated.classify("please STOP doing that right now"),
                     "an updated bundled allowlist including STOP must silence it")
    }
}

// MARK: - Session discipline

final class Build97OpportunitySessionTests: XCTestCase {

    private let c = LiveToneOpportunityClassifier()

    func testOneFirePerFamilyPerSession() {
        var session = LiveToneOpportunitySession()
        XCTAssertEqual(session.consider(c.classify("I think maybe we could possibly revisit this later")), .hedge)
        XCTAssertNil(session.consider(c.classify("perhaps we could kind of revisit this if that makes sense")),
                     "a second O1 on a different sentence must be capped for the session")
    }

    func testDismissalSuppressesFamilyForSession() {
        var session = LiveToneOpportunitySession()
        let v = c.classify("I think maybe we could possibly revisit this later")
        XCTAssertEqual(session.consider(v), .hedge)
        session.dismiss(.hedge)
        XCTAssertNil(session.consider(v), "a dismissed family stays silent for the session")
        XCTAssertEqual(session.consider(c.classify("Sorry, sorry, I didn't mean to bother you again")), .apology,
                       "families are independent — dismissing O1 must not suppress O2")
    }

    func testSameSentenceRefireOnlyWithNewDistinctSignal() {
        var session = LiveToneOpportunitySession()
        let sig = 0xA11CE
        XCTAssertEqual(
            session.consider(LiveToneOpportunityVerdict(family: .hedge, signals: ["maybe", "perhaps"], sentenceSignature: sig)),
            .hedge, "first fire surfaces")
        XCTAssertNil(
            session.consider(LiveToneOpportunityVerdict(family: .hedge, signals: ["maybe"], sentenceSignature: sig)),
            "same sentence, no new distinct signal must not re-fire")
        XCTAssertEqual(
            session.consider(LiveToneOpportunityVerdict(family: .hedge, signals: ["maybe", "perhaps", "possibly"], sentenceSignature: sig)),
            .hedge, "same sentence with a NEW distinct signal may re-fire")
        XCTAssertNil(
            session.consider(LiveToneOpportunityVerdict(family: .hedge, signals: ["maybe", "perhaps", "possibly"], sentenceSignature: sig)),
            "no further new distinct signal must not re-fire")
    }

    func testHostSessionResetRearmsFamilies() {
        var session = LiveToneOpportunitySession()
        let v = c.classify("I think maybe we could possibly revisit this later")
        XCTAssertEqual(session.consider(v), .hedge)
        XCTAssertNil(session.consider(v), "same sentence, same signals must not re-fire")
        session.hostSessionReset()
        XCTAssertEqual(session.consider(v), .hedge, "after a host-session reset the family may fire again")
        XCTAssertTrue(LiveToneOpportunitySession().dismissedFamilies.isEmpty)
    }
}

// MARK: - Content-free counters

final class Build97OpportunityCounterTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "com.tono.opp.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testShownAndDismissedIncrementPerFamily() {
        let defaults = makeDefaults()
        let store = LiveToneOpportunityCounterStore(defaults: defaults)
        let coordinator = LiveToneOpportunityCoordinator(store: store)

        XCTAssertEqual(coordinator.observe(draft: "I think maybe we could possibly revisit this later"), .hedge)
        XCTAssertEqual(store.load().bucket(for: .hedge).shown, 1)

        // One fire per session — a second hedge draft must not bump shown.
        _ = coordinator.observe(draft: "perhaps we could kind of revisit this if that makes sense")
        XCTAssertEqual(store.load().bucket(for: .hedge).shown, 1, "one fire per session keeps shown at 1")

        coordinator.dismissCurrent()
        XCTAssertEqual(store.load().bucket(for: .hedge).dismissed, 1)
        XCTAssertEqual(store.load().bucket(for: .apology).shown, 0, "counters are per-family")
    }

    func testCountersAreContentFree() {
        let defaults = makeDefaults()
        let store = LiveToneOpportunityCounterStore(defaults: defaults)
        let coordinator = LiveToneOpportunityCoordinator(store: store)
        _ = coordinator.observe(draft: "I think maybe we could possibly revisit this later")

        let blob = try? XCTUnwrap(defaults.data(forKey: LiveToneOpportunityCounterStore.storageKey))
        let asString = blob.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertFalse(asString.contains("revisit"), "counters must not persist triggering text")
        XCTAssertFalse(asString.contains("maybe"), "counters must not persist triggering text")
    }
}

// MARK: - Exact copy

final class Build97OpportunityCopyTests: XCTestCase {

    func testExactMicrocopy() {
        XCTAssertEqual(LiveToneCopy.opportunityHedge, "Reads more tentative than it may need to.")
        XCTAssertEqual(LiveToneCopy.opportunityApology, "Reads more apologetic than it may need to.")
        XCTAssertEqual(LiveToneCopy.opportunityCaps, "All caps can read as shouting.")
    }

    func testFamilyMicrocopyResolvesToContractCopy() {
        XCTAssertEqual(LiveToneOpportunityFamily.hedge.microcopy, LiveToneCopy.opportunityHedge)
        XCTAssertEqual(LiveToneOpportunityFamily.apology.microcopy, LiveToneCopy.opportunityApology)
        XCTAssertEqual(LiveToneOpportunityFamily.caps.microcopy, LiveToneCopy.opportunityCaps)
    }

    func testMicrocopyDescribesTextNotPerson() {
        for family in [LiveToneOpportunityFamily.hedge, .apology, .caps] {
            let lower = family.microcopy.lowercased()
            XCTAssertFalse(lower.contains("you seem"), "\(family.code) must not say 'you seem'")
            XCTAssertFalse(lower.contains("you sound"), "\(family.code) must not say 'you sound'")
            XCTAssertFalse(lower.contains("are you"), "\(family.code) must not say 'are you'")
        }
    }

    func testFamilyCodes() {
        XCTAssertEqual(LiveToneOpportunityFamily.hedge.code, "O1")
        XCTAssertEqual(LiveToneOpportunityFamily.apology.code, "O2")
        XCTAssertEqual(LiveToneOpportunityFamily.caps.code, "O3")
        XCTAssertEqual(LiveToneOpportunityFamily.briskRequest.code, "O4")
        XCTAssertEqual(LiveToneOpportunityFamily.flatRefusal.code, "O5")
    }
}

// MARK: - Red / crisis precedence preserved

final class Build97OpportunityPrecedenceTests: XCTestCase {

    private let red = LiveToneClassifier()
    private let opportunity = LiveToneOpportunityClassifier()

    /// Integrated lane: the opportunity classifier is consulted ONLY when
    /// the red classifier is fully silent. Crisis stays total silence.
    private func lane(_ draft: String) -> String {
        let verdict = red.classify(draft)
        if verdict != .silent {
            return verdict.category == .crisis ? "crisis-silence" : "red"
        }
        return opportunity.classify(draft) == nil ? "silent" : "opportunity"
    }

    func testCrisisStaysTotallySilent() {
        XCTAssertEqual(lane("I want to kill myself, maybe perhaps possibly we could talk"), "crisis-silence",
                       "crisis must never surface an opportunity nudge")
    }

    func testRedWarningWinsOverOpportunity() {
        XCTAssertEqual(lane("you never listen, maybe perhaps possibly reconsider this"), "red",
                       "a red warning must win over an opportunity signal")
    }

    func testBenignHedgeStackSurfacesOpportunity() {
        XCTAssertEqual(lane("I think maybe we could possibly revisit this later"), "opportunity")
    }

    func testBenignTextStaysSilentOnBothLanes() {
        XCTAssertEqual(lane("Sounds good, see you at 7!"), "silent")
    }
}
