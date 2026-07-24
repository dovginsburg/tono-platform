// verify_live_tone_opportunity.swift
// Standalone red/green verifier for the Live Tone positive-opportunity
// lane (build 97). Pure Swift on macOS — no iOS Simulator, no Xcode, no
// UIKit, no XCTest.
//
// Compiles the REAL production sources (LiveToneOpportunity.swift,
// LiveToneOpportunitySession.swift, LiveToneOpportunityCounters.swift,
// LiveToneOpportunityFixtures.swift, LiveToneCopy.swift) alongside the
// shipping red-lane classifier (LiveToneClassifier.swift) so it exercises
// the shipping logic and the red/opportunity precedence directly.
//
// Mirrors the XCTest `Tests/Build97LiveTonePositiveOpportunityTests.swift`
// in a deterministic, runnable harness.
//
// Usage (from apps/ios):
//   swiftc -o /tmp/lt_opp \
//     Shared/LiveToneClassifier.swift \
//     Shared/LiveToneCopy.swift \
//     Shared/LiveToneOpportunity.swift \
//     Shared/LiveToneOpportunitySession.swift \
//     Shared/LiveToneOpportunityCounters.swift \
//     Shared/LiveToneOpportunityFixtures.swift \
//     Scripts/verify_live_tone_opportunity.swift && /tmp/lt_opp
//
// Exits 0 on success, non-zero on the first failure.

import Foundation

// MARK: - Tiny assert harness

var failures = 0
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() {
        failures += 1
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    }
}

// MARK: - Fixture expectation helper

func expect(
    _ actual: LiveToneOpportunityVerdict?,
    _ expected: LiveToneOpportunityFixture.Expectation,
    _ label: String
) {
    switch expected {
    case .silent:
        check(actual == nil,
              "\(label): expected SILENT, got \(actual?.family.code ?? "nil")")
    case .fires(let family):
        check(actual?.family == family,
              "\(label): expected \(family.code), got \(actual?.family.code ?? "SILENT")")
    }
}

// MARK: - Section 1: the 40-fixture matrix

func testMatrixIsComplete() {
    check(LiveToneOpportunityMatrix.all.count == 40,
          "matrix must contain exactly 40 fixtures")
    check(LiveToneOpportunityMatrix.positives.count == 20,
          "matrix must contain exactly 20 positive fixtures")
    check(LiveToneOpportunityMatrix.controls.count == 20,
          "matrix must contain exactly 20 near-miss control fixtures")
    for family in LiveToneOpportunityFamily.allCases {
        let pos = LiveToneOpportunityMatrix.all.filter { $0.family == family && $0.kind == .positive }
        let ctl = LiveToneOpportunityMatrix.all.filter { $0.family == family && $0.kind == .control }
        check(pos.count == 4, "\(family.code) must have 4 positive fixtures (got \(pos.count))")
        check(ctl.count == 4, "\(family.code) must have 4 control fixtures (got \(ctl.count))")
    }
}

func testMatrixUnderBuild97() {
    // Default classifier == build-97 active set (O1–O3).
    let classifier = LiveToneOpportunityClassifier()
    for fixture in LiveToneOpportunityMatrix.all {
        let verdict = classifier.classify(fixture.text)
        expect(verdict, fixture.build97, "build97 \(fixture.family.code) \(fixture.kind.rawValue): \"\(fixture.text)\"")
    }
}

func testMatrixUnderBuild96IsTotallySilent() {
    // Build-96 gate: no family active. Every fixture must be silent.
    let classifier = LiveToneOpportunityClassifier(activeFamilies: [])
    for fixture in LiveToneOpportunityMatrix.all {
        let verdict = classifier.classify(fixture.text)
        expect(verdict, fixture.build96, "build96 \(fixture.family.code) \(fixture.kind.rawValue): \"\(fixture.text)\"")
    }
}

func testDeferredFamiliesNeverFireInBuild97() {
    let classifier = LiveToneOpportunityClassifier()
    for fixture in LiveToneOpportunityMatrix.all where fixture.family == .briskRequest || fixture.family == .flatRefusal {
        check(classifier.classify(fixture.text) == nil,
              "O4/O5 must stay silent in build 97: \"\(fixture.text)\"")
    }
}

// MARK: - Section 2: O1 hedge rule boundaries

func testO1Thresholds() {
    let c = LiveToneOpportunityClassifier()
    // Two distinct hedges in one sentence at >= 5 words -> fires.
    check(c.classify("I think maybe we could possibly revisit this later")?.family == .hedge,
          "O1: two distinct hedges in a sentence must fire")
    // Three distinct hedges spread across the message -> fires.
    check(c.classify("I maybe missed it. Perhaps later. Possibly tomorrow works better.")?.family == .hedge,
          "O1: three distinct hedges across the message must fire")
    // A single hedge -> silent.
    check(c.classify("maybe we can grab lunch sometime this week") == nil,
          "O1: a single hedge must stay silent")
    // Two distinct hedges but under the five-word floor -> silent.
    check(c.classify("maybe perhaps though") == nil,
          "O1: two hedges below the five-word floor must stay silent")
}

func testO1JustGate() {
    let c = LiveToneOpportunityClassifier()
    // "just" before a cognition/request verb counts (pairs with "maybe").
    check(c.classify("just wondering if maybe you had a chance to look")?.family == .hedge,
          "O1: 'just' + cognition verb counts toward the stack")
    // "just landed" does not count; no other hedge -> silent.
    check(c.classify("just landed at the airport and heading over now") == nil,
          "O1: 'just landed' must not count")
}

func testO1IThinkGate() {
    let c = LiveToneOpportunityClassifier()
    // A lone "I think X" (X not a cognition/request verb) stays silent.
    check(c.classify("I think you should reconsider the whole plan tomorrow") == nil,
          "O1: a lone 'I think X' must stay silent")
}

func testO1ThresholdIsParameterizable() {
    // Raising the per-sentence threshold to 3 (the contract's escalation)
    // must silence a two-hit sentence that fires at the default of 2.
    let strict = LiveToneOpportunityClassifier(hedgeSentenceThreshold: 3, hedgeMessageThreshold: 4)
    check(strict.classify("I think maybe we could possibly revisit this later") == nil,
          "O1: raising the threshold to 3 must silence a two-hit sentence")
}

// MARK: - Section 3: O2 apology rule boundaries

func testO2Thresholds() {
    let c = LiveToneOpportunityClassifier()
    check(c.classify("Sorry, sorry, I didn't mean to bother you again")?.family == .apology,
          "O2: two sorry tokens must fire")
    check(c.classify("I'm so sorry, I apologize for the delay again")?.family == .apology,
          "O2: sorry + apolog* must fire")
    check(c.classify("Sorry I'm late, traffic was brutal this morning") == nil,
          "O2: a single apology must stay silent")
}

func testO2CondolenceSuppression() {
    let c = LiveToneOpportunityClassifier()
    check(c.classify("I'm so sorry for your loss, my heart goes out to you") == nil,
          "O2: 'sorry for your loss' must not count")
    check(c.classify("So sorry to hear about the news, thinking of you") == nil,
          "O2: 'sorry to hear' must not count")
    check(c.classify("sorry for your loss and sorry to hear about everything") == nil,
          "O2: two condolence phrases must both be excluded -> silent")
    // A condolence sorry plus a single genuine self-apology is only one
    // counting token -> silent (proves the condolence is excluded even when
    // mixed with a real apology).
    check(c.classify("sorry to hear that, and sorry to interrupt again") == nil,
          "O2: one condolence + one genuine apology is a single counting token -> silent")
    // Two genuine 'sorry to ...' apologies (not condolences) do fire.
    check(c.classify("sorry to interrupt, sorry to ask, but could you help")?.family == .apology,
          "O2: two genuine 'sorry to ...' apologies must fire")
}

// MARK: - Section 4: O3 caps rule boundaries

func testO3Thresholds() {
    let c = LiveToneOpportunityClassifier()
    check(c.classify("please STOP doing that right now")?.family == .caps,
          "O3: a four-letter all-caps token must fire")
    check(c.classify("please stop doing that right now") == nil,
          "O3: the lower-cased control must stay silent")
    check(c.classify("running LATE") == nil,
          "O3: a caps token below the three-word floor must stay silent")
}

func testO3AllowlistAndFloor() {
    let c = LiveToneOpportunityClassifier()
    check(c.classify("just booked the ASAP delivery for tomorrow") == nil,
          "O3: an allow-listed acronym (ASAP) must not fire")
    check(c.classify("OMG that is so funny lol") == nil,
          "O3: a sub-four-letter/allow-listed token must not fire")
    // A three-letter all-caps token is under the four-letter floor.
    check(c.classify("the CAR is fast") == nil,
          "O3: a three-letter caps token must stay silent")
    // Allowlist is updatable: shipping an allowlist that includes STOP
    // silences the flagship O3 positive.
    let updated = LiveToneOpportunityClassifier(capsAllowlist: LiveToneCapsAllowlist.bundled.union(["STOP"]))
    check(updated.classify("please STOP doing that right now") == nil,
          "O3: an updated allowlist including STOP must silence it")
}

// MARK: - Section 5: session discipline

func testSessionOneFirePerFamilyPerSession() {
    var s = LiveToneOpportunitySession()
    let c = LiveToneOpportunityClassifier()
    let v1 = c.classify("I think maybe we could possibly revisit this later")
    check(s.consider(v1) == .hedge, "first O1 fire must surface")
    let v2 = c.classify("perhaps we could kind of revisit this if that makes sense")
    check(s.consider(v2) == nil,
          "a second O1 on a different sentence must be capped (one fire per family per session)")
}

func testSessionDismissalSuppressesForSession() {
    var s = LiveToneOpportunitySession()
    let c = LiveToneOpportunityClassifier()
    let v1 = c.classify("I think maybe we could possibly revisit this later")
    check(s.consider(v1) == .hedge, "first O1 fire must surface")
    s.dismiss(.hedge)
    check(s.consider(v1) == nil, "a dismissed family must stay silent for the session")
    // Independence: O2 still fires after O1 is dismissed.
    let a = c.classify("Sorry, sorry, I didn't mean to bother you again")
    check(s.consider(a) == .apology, "dismissing O1 must not suppress O2")
}

func testSessionSameSentenceRefireOnlyWithNewSignal() {
    var s = LiveToneOpportunitySession()
    let sigA = 0xA11CE
    let first = LiveToneOpportunityVerdict(family: .hedge, signals: ["maybe", "perhaps"], sentenceSignature: sigA)
    check(s.consider(first) == .hedge, "first fire on the sentence must surface")
    let sameSubset = LiveToneOpportunityVerdict(family: .hedge, signals: ["maybe"], sentenceSignature: sigA)
    check(s.consider(sameSubset) == nil, "same sentence, no new distinct signal must not re-fire")
    let sameNew = LiveToneOpportunityVerdict(family: .hedge, signals: ["maybe", "perhaps", "possibly"], sentenceSignature: sigA)
    check(s.consider(sameNew) == .hedge, "same sentence with a NEW distinct signal may re-fire")
    let sameNewAgain = LiveToneOpportunityVerdict(family: .hedge, signals: ["maybe", "perhaps", "possibly"], sentenceSignature: sigA)
    check(s.consider(sameNewAgain) == nil, "no further new distinct signal must not re-fire")
    let otherSentence = LiveToneOpportunityVerdict(family: .hedge, signals: ["kind of"], sentenceSignature: 0xB0B)
    check(s.consider(otherSentence) == nil, "a different sentence after the one fire stays capped")
    s.hostSessionReset()
    check(s.consider(otherSentence) == .hedge, "after a host-session reset the family may fire again")
}

// MARK: - Section 6: content-free counters

func testCountersIncrementAndAreContentFree() {
    let suite = "com.tono.opp.verify.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let store = LiveToneOpportunityCounterStore(defaults: defaults)
    let coordinator = LiveToneOpportunityCoordinator(store: store)

    check(coordinator.observe(draft: "I think maybe we could possibly revisit this later") == .hedge,
          "coordinator must surface O1 on a hedge stack")
    check(store.load().bucket(for: .hedge).shown == 1, "shown counter must increment once")
    // One fire per session -> a second O1 draft must not bump shown.
    _ = coordinator.observe(draft: "perhaps we could kind of revisit this if that makes sense")
    check(store.load().bucket(for: .hedge).shown == 1, "one fire per session -> shown stays 1")

    coordinator.dismissCurrent()
    check(store.load().bucket(for: .hedge).dismissed == 1, "dismissed counter must increment")

    // Content-free: the persisted store must not contain any triggering text.
    if let blob = defaults.data(forKey: LiveToneOpportunityCounterStore.storageKey),
       let asString = String(data: blob, encoding: .utf8) {
        check(!asString.contains("revisit") && !asString.contains("maybe") && !asString.contains("perhaps"),
              "counters must contain no message content")
    } else {
        check(false, "counter store must persist a decodable blob")
    }
    defaults.removePersistentDomain(forName: suite)
}

// MARK: - Section 7: exact copy

func testExactMicrocopy() {
    check(LiveToneCopy.opportunityHedge == "Reads more tentative than it may need to.",
          "O1 microcopy must match the contract verbatim")
    check(LiveToneCopy.opportunityApology == "Reads more apologetic than it may need to.",
          "O2 microcopy must match the contract verbatim")
    check(LiveToneCopy.opportunityCaps == "All caps can read as shouting.",
          "O3 microcopy must match the contract verbatim")
    check(LiveToneOpportunityFamily.hedge.microcopy == LiveToneCopy.opportunityHedge,
          "O1 family microcopy must resolve to the contract copy")
    check(LiveToneOpportunityFamily.apology.microcopy == LiveToneCopy.opportunityApology,
          "O2 family microcopy must resolve to the contract copy")
    check(LiveToneOpportunityFamily.caps.microcopy == LiveToneCopy.opportunityCaps,
          "O3 family microcopy must resolve to the contract copy")
    // Microcopy describes the text, never the person.
    for family in [LiveToneOpportunityFamily.hedge, .apology, .caps] {
        let lower = family.microcopy.lowercased()
        check(!lower.contains("you seem") && !lower.contains("you sound") && !lower.contains("are you"),
              "\(family.code) microcopy must describe the text, not the person")
    }
}

// MARK: - Section 8: red/crisis precedence preserved

func testRedAndCrisisPrecedence() {
    let red = LiveToneClassifier()
    let opportunity = LiveToneOpportunityClassifier()

    // Integrated precedence: the opportunity lane is consulted ONLY when the
    // red lane is fully silent. Crisis silence stays total silence.
    func lane(_ draft: String) -> String {
        let verdict = red.classify(draft)
        if verdict != .silent {
            return verdict.category == .crisis ? "crisis-silence" : "red"
        }
        return opportunity.classify(draft) == nil ? "silent" : "opportunity"
    }

    // Crisis + a hedge stack -> total silence, never an opportunity nudge.
    check(lane("I want to kill myself, maybe perhaps possibly we could talk") == "crisis-silence",
          "crisis must stay totally silent, never surfacing an opportunity nudge")
    // Red hostility + a hedge stack -> red wins, opportunity never consulted.
    check(lane("you never listen, maybe perhaps possibly reconsider this") == "red",
          "a red warning must win over an opportunity signal")
    // Benign hedge stack with no red signal -> opportunity surfaces.
    check(lane("I think maybe we could possibly revisit this later") == "opportunity",
          "a benign hedge stack with no red signal surfaces the opportunity nudge")
    // Pure benign text -> silent on both lanes.
    check(lane("Sounds good, see you at 7!") == "silent",
          "benign text stays silent on both lanes")
}

// MARK: - Run

@main
enum LiveToneOpportunityVerifier {
    static func main() {
        testMatrixIsComplete()
        testMatrixUnderBuild97()
        testMatrixUnderBuild96IsTotallySilent()
        testDeferredFamiliesNeverFireInBuild97()
        testO1Thresholds()
        testO1JustGate()
        testO1IThinkGate()
        testO1ThresholdIsParameterizable()
        testO2Thresholds()
        testO2CondolenceSuppression()
        testO3Thresholds()
        testO3AllowlistAndFloor()
        testSessionOneFirePerFamilyPerSession()
        testSessionDismissalSuppressesForSession()
        testSessionSameSentenceRefireOnlyWithNewSignal()
        testCountersIncrementAndAreContentFree()
        testExactMicrocopy()
        testRedAndCrisisPrecedence()

        if failures == 0 {
            print("ok — \(checks) checks passed")
            exit(0)
        } else {
            FileHandle.standardError.write(Data("\(failures)/\(checks) checks FAILED\n".utf8))
            exit(1)
        }
    }
}
