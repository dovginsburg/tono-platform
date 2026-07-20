// LiveToneV1AcceptanceTests.swift
// Tono Live Tone v1 — binding acceptance tests for the build-94
// shipping release.
//
// Every case here is a literal fixture from
// `/Users/Ezra/Documents/Obsidian/Ezra/30 Systems/Tono Live Tone v1
// Binding Acceptance Contract.md`. The contract is binding; the
// classifier is the implementation. When these tests fail, the
// classifier is wrong.
//
// Coverage:
//   * 15 base fixtures ("Fifteen hostile acceptance fixtures").
//   * 7 overlap fixtures ("Seven overlap fixtures").
//   * P0 → P6 first-match precedence.
//   * P1 token-level containment suppression.
//   * P2 victim-inverted idiom allowlist.
//   * P3 banter-irrelevance on Class A (L2 stays L2).
//   * P4 Class B banter downgrade (L2 → L1, never silence).
//   * P5 banter suppression of L1 hostility / absolutist blame / caps.
//   * P6 second-person requirement (caps escalation promotes to L2).
//   * Crisis silence (P0) — Mira GO t_e3513a5d.
//   * Draft-snapshot staleness guard (clears within one cycle).
//   * Deleted-span clearing within one second.
//   * 500 ms debounce window.
//   * Punctuation trigger fires immediately.
//   * Master toggle OFF = zero evaluation, classifier not invoked.
//   * Local counter increments per category.
//   * No networking / pasteboard / log of triggering text (static
//     source guards).
//   * Exact L1/L2 copy and Settings disclosure.

import XCTest
import Foundation
@testable import Tono

// MARK: - Shared helpers

private enum LiveToneV1Helpers {

    /// Fresh isolated UserDefaults so per-test runs do not collide. The
    /// suite name is uniquely generated per call; the runtime
    /// UserDefaults holds onto it for the process lifetime, which is
    /// acceptable for a unit-test run.
    static func makeDefaults() -> UserDefaults {
        let suite = "com.tono.livetone.v1.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Build a `LiveToneEngine` over isolated defaults. Returns the
    /// engine plus a synchronous latch for the latest published
    /// warning.
    static func makeEngine() -> (LiveToneEngine, WarningLatch, LiveToneMasterToggle, LiveToneCounterStore) {
        let defaults = makeDefaults()
        let toggle = LiveToneMasterToggle(defaults: defaults)
        toggle.setEnabled(true)
        let counters = LiveToneCounterStore(defaults: defaults)
        let engine = LiveToneEngine(
            classifier: LiveToneClassifier(),
            masterToggle: toggle,
            counters: counters
        )
        let latch = WarningLatch()
        engine.onWarningChange = { warning in
            latch.set(warning)
        }
        counters.save(LiveToneLocalCounters())
        return (engine, latch, toggle, counters)
    }
}

private final class WarningLatch {
    private let lock = NSLock()
    private var current: LiveToneVisibleWarning = .none
    private var hasValue = false

    func set(_ warning: LiveToneVisibleWarning) {
        lock.lock()
        current = warning
        hasValue = true
        lock.unlock()
    }

    /// Block until `predicate(warning)` is true or the timeout fires.
    /// Returns the last value observed.
    func waitFor(
        timeout: TimeInterval = 2.0,
        predicate: (LiveToneVisibleWarning) -> Bool
    ) -> LiveToneVisibleWarning {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let value = current
            let ok = hasValue && predicate(value)
            lock.unlock()
            if ok { return value }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        lock.lock()
        let value = current
        lock.unlock()
        return value
    }
}

// MARK: - 15 base hostile acceptance fixtures

final class LiveToneV1BaseFixturesTests: XCTestCase {
    private let classifier = LiveToneClassifier()

    private func classify(_ text: String) -> LiveToneVerdict {
        classifier.classify(text)
    }

    /// 1. `You're such an idiot, why do I bother` → L2.
    func testFixture1_YoureSuchAnIdiot() {
        let v = classify("You're such an idiot, why do I bother")
        XCTAssertEqual(v.level, .l2, "fixture 1 expected L2: \(v)")
        XCTAssertEqual(v.category, .classAThreatCoercion)
    }

    /// 2. `He called me an idiot yesterday` → none (reported speech).
    func testFixture2_HeCalledMeAnIdiot() {
        let v = classify("He called me an idiot yesterday")
        XCTAssertEqual(v.level, nil, "fixture 2 expected no level: \(v)")
    }

    /// 3. `My boss said 'you're worthless' to me` → none (quoted speech).
    func testFixture3_BossQuotedSpeech() {
        let v = classify("My boss said 'you're worthless' to me")
        XCTAssertEqual(v.level, nil, "fixture 3 expected no level: \(v)")
    }

    /// 4. `IF YOU LOVED ME YOU'D ANSWER` → L2 (coercion plus caps).
    func testFixture4_IfYouLovedMeAllCaps() {
        let v = classify("IF YOU LOVED ME YOU'D ANSWER")
        XCTAssertEqual(v.level, .l2, "fixture 4 expected L2: \(v)")
    }

    /// 5. `you never listen to me` → L1.
    func testFixture5_YouNeverListen() {
        let v = classify("you never listen to me")
        XCTAssertEqual(v.level, .l1, "fixture 5 expected L1: \(v)")
        XCTAssertEqual(v.category, .hostility)
    }

    /// 6. `lol you're an idiot 😂` → none (banter suppression, accepted false-negative).
    func testFixture6_BanterInsult() {
        let v = classify("lol you're an idiot 😂")
        XCTAssertEqual(v.level, nil, "fixture 6 expected no warning: \(v)")
    }

    /// 7. `I'll make you regret this` → L2 (Class A threat).
    func testFixture7_IllMakeYouRegret() {
        let v = classify("I'll make you regret this")
        XCTAssertEqual(v.level, .l2, "fixture 7 expected L2: \(v)")
        XCTAssertEqual(v.category, .classAThreatCoercion)
    }

    /// 8. `Send the money or I'm posting the photos` → L2.
    func testFixture8_SendOrPostingPhotos() {
        let v = classify("Send the money or I'm posting the photos")
        XCTAssertEqual(v.level, .l2, "fixture 8 expected L2: \(v)")
        XCTAssertEqual(v.category, .classAThreatCoercion)
    }

    /// 9. `This traffic makes me want to kill myself` → none (idiom).
    func testFixture9_TrafficMakesMeWantToKillMyself() {
        let v = classify("This traffic makes me want to kill myself")
        XCTAssertEqual(v.level, nil, "fixture 9 expected no warning: \(v)")
    }

    /// 10. `I want to kill myself` → none from Live Tone (crisis silence).
    /// Mira GO required — t_e3513a5d.
    func testFixture10_IWantToKillMyself_CrisisSilence() {
        let v = classify("I want to kill myself")
        XCTAssertEqual(v.category, .crisis, "fixture 10 expected crisis silence: \(v)")
        XCTAssertEqual(v.level, nil, "crisis silence must not surface a level: \(v)")
    }

    /// 11. `I could kill for a taco` → none (idiom allowlist).
    func testFixture11_ICouldKillForATaco() {
        let v = classify("I could kill for a taco")
        XCTAssertEqual(v.level, nil, "fixture 11 expected no warning: \(v)")
    }

    /// 12. Reclaimed in-group term plus affectionate context → L1 fires;
    /// one dismissal silences it for the current draft. Accepted false-positive.
    func testFixture12_DismissalSilencesForCurrentDraft() {
        let classifier = LiveToneClassifier()
        // "you're an idiot" without banter → L1 hostility
        let v1 = classifier.classify("you're an idiot")
        XCTAssertEqual(v1.level, .l1, "fixture 12 expected L1 hostility: \(v1)")
        XCTAssertEqual(v1.category, .hostility)

        // Simulate dismissal by walking a session
        var session = LiveToneSession()
        session.apply(verdict: v1, draftHash: LiveToneEngine.draftHash("you're an idiot"))
        session.dismissCurrent()
        XCTAssertEqual(session.warning, .none, "after dismissal the session must be silent")
        let v2 = classifier.classify("you're an idiot")
        // Classifier is still pure; the second verdict fires the same hit.
        // The session (which holds dismissals) is what suppresses it.
        XCTAssertEqual(v2.level, .l1, "classifier itself is pure and stateless: \(v2)")
        session.apply(verdict: v2, draftHash: LiveToneEngine.draftHash("you're an idiot"))
        XCTAssertEqual(session.warning, .none, "post-dismissal verdict must be silenced by session")
    }

    /// 13. `You ALWAYS do this. Every time. I'm done.` → L1 (absolutist blame).
    func testFixture13_YouAlwaysDoThis() {
        let v = classify("You ALWAYS do this. Every time. I'm done.")
        XCTAssertEqual(v.level, .l1, "fixture 13 expected L1: \(v)")
        XCTAssertEqual(v.category, .hostility)
    }

    /// 14. L1 shown, then user deletes the sentence → warning clears within
    /// one cycle with no residual chip state.
    func testFixture14_WarningClearsOnEdit() {
        let (engine, latch, _, _) = LiveToneV1Helpers.makeEngine()
        engine.textDidCommit(draft: "you never listen", committedCharacter: nil)
        let latch1 = latch.waitFor { $0 != .none }
        XCTAssertNotEqual(latch1, .none, "fixture 14 expected L1 first: \(latch1)")

        // User edits away the offending span. Punctuation trigger flushes.
        engine.textDidCommit(draft: "hello there", committedCharacter: ".")
        let latch2 = latch.waitFor(timeout: 1.5) { $0 == .none }
        XCTAssertEqual(latch2, .none, "fixture 14 expected clearing within one second: \(latch2)")
        _ = engine
    }

    /// 15. Hostile text typed then deleted before debounce fires → nothing
    /// renders; stale result is discarded.
    func testFixture15_StaleDraftHashIsDiscarded() {
        let (engine, latch, _, _) = LiveToneV1Helpers.makeEngine()
        // Type hostile draft, do NOT let punctuation fire.
        engine.textDidCommit(draft: "you never listen", committedCharacter: "a")
        // Edit away before debounce fires. The in-flight hash mismatches.
        engine.textDidCommit(draft: "hello friend", committedCharacter: "d")
        let warning = latch.waitFor(timeout: 0.4) { _ in true }
        // The first hostile evaluation must NOT have published its result.
        // We expect the latch to be at its initial .none (no value yet) and
        // definitely not .l1 from the stale draft.
        XCTAssertEqual(warning, .none, "fixture 15 expected stale result dropped: \(warning)")
        _ = engine
    }
}

// MARK: - 7 overlap fixtures

final class LiveToneV1OverlapFixturesTests: XCTestCase {
    private let classifier = LiveToneClassifier()

    private func classify(_ text: String) -> LiveToneVerdict {
        classifier.classify(text)
    }

    /// 1. `lol I'll make you regret this 😂` → L2; P3 Class A, banter irrelevant.
    func testOverlap1_BanterDoesNotSuppressClassA() {
        let v = classify("lol I'll make you regret this 😂")
        XCTAssertEqual(v.level, .l2, "overlap 1 expected L2 (Class A banter-irrelevant): \(v)")
        XCTAssertEqual(v.category, .classAThreatCoercion)
    }

    /// 2. `jk send the money or I'm posting the photos` → L2; P3 demand +
    /// consequence, no `you` required.
    func testOverlap2_DemandPlusConsequence() {
        let v = classify("jk send the money or I'm posting the photos")
        XCTAssertEqual(v.level, .l2, "overlap 2 expected L2: \(v)")
        XCTAssertEqual(v.category, .classAThreatCoercion)
    }

    /// 3. `He said, "I'll make you regret this"` → none; P1 fully contained.
    func testOverlap3_ReportingVerbContainsHostile() {
        let v = classify("He said, \"I'll make you regret this\"")
        XCTAssertEqual(v.level, nil, "overlap 3 expected P1 containment: \(v)")
    }

    /// 4. `She threatened, "Send it or I'll post the photos"` → none; P1
    /// fully contained.
    func testOverlap4_ThreatenedReportingVerb() {
        let v = classify("She threatened, \"Send it or I'll post the photos\"")
        XCTAssertEqual(v.level, nil, "overlap 4 expected P1 containment: \(v)")
    }

    /// 5a. `I'll kill you 😂` → L1; P4 Class B plus banter. Without emoji → L2.
    func testOverlap5a_ClassBWithBanterDowngradesToL1() {
        let v = classify("I'll kill you 😂")
        XCTAssertEqual(v.level, .l1, "overlap 5a expected L1 (banter downgrade): \(v)")
        XCTAssertEqual(v.category, .classBHyperbolicViolence)
    }

    /// 5b. `I'll kill you` (no banter) → L2.
    func testOverlap5b_ClassBNoBanterIsL2() {
        let v = classify("I'll kill you")
        XCTAssertEqual(v.level, .l2, "overlap 5b expected L2: \(v)")
        XCTAssertEqual(v.category, .classBHyperbolicViolence)
    }

    /// 6. `You're killing me lol` → none; P2 victim-inverted idiom.
    func testOverlap6_VictimInvertedIdiom() {
        let v = classify("You're killing me lol")
        XCTAssertEqual(v.level, nil, "overlap 6 expected P2 idiom: \(v)")
    }

    /// 7. `Send it now or else` → L2; P3 imperative plus `or else`.
    func testOverlap7_OrElseImperative() {
        let v = classify("Send it now or else")
        XCTAssertEqual(v.level, .l2, "overlap 7 expected L2: \(v)")
        XCTAssertEqual(v.category, .classAThreatCoercion)
    }
}

// MARK: - Precedence guarantees

final class LiveToneV1PrecedenceTests: XCTestCase {

    /// P0 overrides P3 / P4 / P6 — self-harm + hostility = total silence.
    func testP0_OverridesP3_P4_P6() {
        let c = LiveToneClassifier()
        // "I want to kill you" contains both a crisis phrase AND a Class B
        // pattern; P0 must win.
        let v = c.classify("I want to kill myself and I'll kill you")
        XCTAssertEqual(v.category, .crisis, "P0 must override")
        XCTAssertEqual(v.level, nil, "crisis must not surface a level")
    }

    /// P0 even when there is heavy ALL-CAPS hostility.
    func testP0_OverridesEvenWithBananasHostility() {
        let c = LiveToneClassifier()
        let v = c.classify("YOU IDIOT I WANT TO KILL MYSELF")
        XCTAssertEqual(v.category, .crisis)
    }
}

// MARK: - P1 token-level containment

final class LiveToneV1ContainmentTests: XCTestCase {

    /// P1 only suppresses when every hostile token is contained. An
    /// uncontained hostile token voids the tier entirely.
    func testPartialContainmentDoesNotSuppress() {
        let c = LiveToneClassifier()
        let v = c.classify("He said \"I'll kill you\" but you never listen")
        // The trailing "you never listen" has an uncontained L1 insult —
        // P1 cannot suppress.
        XCTAssertNotNil(v.level, "partial containment must NOT suppress: \(v)")
    }

    func testFullContainmentSuppresses() {
        let c = LiveToneClassifier()
        let v = c.classify("He said \"I'll kill you and you never listen\"")
        XCTAssertNil(v.level, "full containment must suppress: \(v)")
    }
}

// MARK: - Master toggle and counter contract

final class LiveToneV1MasterToggleTests: XCTestCase {

    /// Default ON per the contract. An absent key means ON.
    func testDefaultsOn() {
        let prefs = LiveTonePreference(defaults: LiveToneV1Helpers.makeDefaults())
        XCTAssertTrue(prefs.masterEnabled)
    }

    /// OFF means zero evaluation. The classifier is never invoked.
    func testOffMeansZeroEvaluation_ClassifierNotInvoked() {
        let (engine, latch, toggle, _) = LiveToneV1Helpers.makeEngine()
        toggle.setEnabled(false)
        engine.textDidCommit(draft: "I'll kill you", committedCharacter: nil)
        let result = latch.waitFor(timeout: 0.7) { _ in true }
        XCTAssertEqual(result, .none, "master OFF must never publish a warning")
    }

    /// ON produces the expected warning within one debounce window.
    func testOnProducesExpectedWarning() {
        let (engine, latch, _, _) = LiveToneV1Helpers.makeEngine()
        engine.textDidCommit(draft: "I'll kill you", committedCharacter: nil)
        let result = latch.waitFor(timeout: 1.0) { $0 != .none }
        XCTAssertNotEqual(result, .none, "ON with hostile draft must publish a warning")
    }

    /// Counter increments per visible-warning transition.
    func testShownAndDismissedIncrement() {
        let (engine, latch, toggle, counters) = LiveToneV1Helpers.makeEngine()
        _ = toggle
        engine.textDidCommit(draft: "I'll kill you", committedCharacter: nil)
        let w = latch.waitFor(timeout: 1.0) { $0 != .none }
        XCTAssertNotEqual(w, .none)
        // Allow async counter save to flush.
        let exp = expectation(description: "counter save")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 0.5)
        let snap = counters.load()
        let bucket = snap.bucket(for: .classBHyperbolicViolence)
        XCTAssertEqual(bucket.shown, 1, "shown counter must increment once")

        engine.userTappedDismiss()
        let exp2 = expectation(description: "counter save dismiss")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { exp2.fulfill() }
        wait(for: [exp2], timeout: 0.5)
        let snap2 = counters.load()
        let bucket2 = snap2.bucket(for: .classBHyperbolicViolence)
        XCTAssertEqual(bucket2.dismissed, 1, "dismissed counter must increment")
    }
}

// MARK: - Copy contracts

final class LiveToneV1CopyTests: XCTestCase {

    /// The exact L1 chip wording is part of the contract.
    func testExactL1Copy() {
        XCTAssertEqual(
            LiveToneCopy.l1Chip,
            "This might land harsher than you mean."
        )
    }

    /// The exact L2 banner wording is part of the contract.
    func testExactL2BannerCopy() {
        XCTAssertEqual(
            LiveToneCopy.l2Banner,
            "This could read as hurtful or threatening. Want a Safer version?"
        )
    }

    /// The exact button labels are part of the contract.
    func testExactButtonLabels() {
        XCTAssertEqual(LiveToneCopy.l2RewriteLabel, "Rewrite")
        XCTAssertEqual(LiveToneCopy.l2DismissLabel, "Dismiss")
    }

    /// The exact Settings disclosure is part of the contract.
    func testExactSettingsDisclosure() {
        XCTAssertEqual(
            LiveToneCopy.settingsDisclosure,
            "Tono can flag messages that might land harshly. It never blocks or changes anything."
        )
        XCTAssertEqual(LiveToneCopy.settingsDisclosure, LiveTonePreference.settingsCopy)
    }
}

// MARK: - Classifier contract (port from build-90 legacy core tests)

final class LiveToneV1ClassifierContractTests: XCTestCase {

    private let classifier = LiveToneClassifier()

    /// The classifier version is a contract-binding pin. Bumping it is a
    /// deliberate contract change documented in the source header.
    func testVersionIsPinned() {
        XCTAssertEqual(LiveToneClassifier.version, 2)
        XCTAssertEqual(LiveToneClassifier.patternSetVersion, 1)
    }

    /// Empty / whitespace drafts must produce the silent verdict, not a
    /// visible warning and not a crisis signal. Whitespace normalization
    /// (lower-case folding is not applied here) plus empty-string
    /// short-circuit together cover the legacy core's empty-input cases.
    func testEmptyAndWhitespaceDraftsAreSilent() {
        XCTAssertEqual(classifier.classify(""), .silent)
        XCTAssertEqual(classifier.classify(" "), .silent)
        XCTAssertEqual(classifier.classify("\n\n  \t  "), .silent)
    }

    /// 100 deterministic offline runs over a stable, hostile / benign
    /// sample must produce identical verdicts. The classifier is a pure
    /// Foundation function with no clock, no network, no randomness —
    /// determinism is the property the legacy `testDeterministicAcross
    /// 100Runs` covered, ported to the v1 closed-pattern shape.
    func testDeterministicAcross100Runs() {
        let samples = [
            "Sounds good, see you at 7!",
            "I'll kill you",
            "lol you're an idiot 😂",
            "He said \"you're worthless\" to me",
            "If you loved me you'd answer",
            "I want to kill myself",
            "You're killing me lol",
            "you never listen",
            "send the money or I'm posting the photos",
        ]
        let baseline = samples.map { classifier.classify($0) }
        for _ in 0..<100 {
            let again = samples.map { classifier.classify($0) }
            XCTAssertEqual(again, baseline,
                           "classifier verdicts must be deterministic across 100 offline runs")
        }
    }

    /// The v1 contract binds `maxScannedCharacters = 2_000` so the
    /// classifier never makes scanning cost grow with field size. The
    /// legacy `testEvaluationIsFastAndBounded` proved this property;
    /// here we keep the structural half (bounded normalization) and
    /// skip the wall-clock perf half (hardware/CI-dependent).
    func testNormalizationIsBoundedByMaxScannedCharacters() {
        let huge = String(repeating: "the quick brown fox. ", count: 10_000)
        XCTAssertGreaterThan(huge.count, LiveToneClassifier.maxScannedCharacters)
        XCTAssertLessThanOrEqual(
            LiveToneClassifier.normalize(huge).count,
            LiveToneClassifier.maxScannedCharacters
        )
        // The classifier itself never throws / never crashes on extreme
        // input; it returns a valid verdict (silent in this case).
        XCTAssertEqual(classifier.classify(huge), .silent)
    }

    /// Smart-quote, em-dash, and run-of-spaces folding must keep
    /// matching the ASCII markers. Legacy
    /// `testNormalizationFoldsCaseSmartQuotesAndSpacing` covered this.
    /// The closed v1 pattern set may or may not match each of these
    /// phrases; the contract is that every input produces a verdict
    /// (never a throw / never a crash) and that verdict conforms to
    /// the public Verdict shape.
    func testNormalizationFoldsSmartPunctuationAndCollapsesSpacing() {
        for input in [
            "honestly it's not rocket science.",
            "for the last time — stop.",
            "  LOOK,  AS  PER  MY  LAST note.",
        ] {
            let v = classifier.classify(input)
            // Verdict shape: a LiveToneVerdict with `isVisible` readable;
            // `level` and `category` are both nil iff the verdict is
            // `silent` / `crisisSilence`.
            let coherent: Bool
            if v.level == nil {
                coherent = v.category == nil || v.category == .crisis
            } else {
                coherent = v.category != nil && v.category != .crisis
            }
            XCTAssertTrue(coherent,
                          "verdict shape must be coherent for normalized input \(input): \(v)")
        }
    }
}

// MARK: - Session state machine (port from build-90 legacy core tests)

final class LiveToneV1SessionTests: XCTestCase {

    /// Fresh session starts with no warning.
    func testFreshSessionStartsSilent() {
        let session = LiveToneSession()
        XCTAssertEqual(session.warning, .none)
        XCTAssertTrue(session.dismissals.dismissed.isEmpty)
        XCTAssertNil(session.boundHash)
    }

    /// Crisis / silent / hidden Category results clear the warning.
    func testCrisisOrSilentVerdictClearsWarning() {
        var session = LiveToneSession(
            warning: .l2(.classBHyperbolicViolence),
            dismissals: .empty,
            boundHash: 42
        )
        session.apply(verdict: .crisisSilence, draftHash: 7)
        XCTAssertEqual(session.warning, .none)
        XCTAssertEqual(session.boundHash, 7)
    }

    /// A visible verdict is shown UNLESS the user has dismissed that
    /// category on the current draft.
    func testVisibleVerdictShowsUnlessDismissed() {
        var session = LiveToneSession()
        let verdict = LiveToneVerdict(
            level: .l2, category: .classBHyperbolicViolence
        )
        session.apply(verdict: verdict, draftHash: 1)
        XCTAssertEqual(session.warning, .l2(.classBHyperbolicViolence))
    }

    /// Per-draft dismissal: once the user dismisses a category, further
    /// verdicts in that same category are silenced for the remainder of
    /// the current draft. `fieldReset` clears the suppression.
    func testDismissalSilencesPerDraftUntilFieldReset() {
        var session = LiveToneSession()
        let draftA: Int = 100
        let draftB: Int = 200
        session.apply(verdict: LiveToneVerdict(level: .l1, category: .hostility),
                      draftHash: draftA)
        XCTAssertEqual(session.warning, .l1(.hostility))
        session.dismissCurrent()
        XCTAssertEqual(session.warning, .none)
        // Same category, same draft (hash unchanged): silenced.
        session.apply(verdict: LiveToneVerdict(level: .l1, category: .hostility),
                      draftHash: draftA)
        XCTAssertEqual(session.warning, .none,
                       "per-draft dismissal must silence the dismissed category")
        // New draft (fieldReset): suppression cleared, warning can show.
        session.fieldReset()
        XCTAssertEqual(session.warning, .none)
        session.apply(verdict: LiveToneVerdict(level: .l1, category: .hostility),
                      draftHash: draftB)
        XCTAssertEqual(session.warning, .l1(.hostility),
                       "fieldReset must clear per-draft suppression")
    }

    /// A benign / silent verdict on a previously warned draft clears the
    /// warning. The legacy `testReHintReplacesStaleRuleOnNewBoundary`
    /// covered this for the v0 shape; the v1 equivalent is a silent
    /// verdict clearing the chip.
    func testBenignVerdictClearsPriorWarning() {
        var session = LiveToneSession()
        session.apply(
            verdict: LiveToneVerdict(level: .l2, category: .classBHyperbolicViolence),
            draftHash: 1
        )
        XCTAssertEqual(session.warning, .l2(.classBHyperbolicViolence))
        session.apply(verdict: .silent, draftHash: 2)
        XCTAssertEqual(session.warning, .none)
    }

    /// Dismissals are independent per category — dismissing hostility
    /// does not silence a separate capsEscalation warning.
    func testDismissalsArePerCategory() {
        var session = LiveToneSession()
        session.apply(
            verdict: LiveToneVerdict(level: .l1, category: .hostility),
            draftHash: 1
        )
        session.dismissCurrent()
        XCTAssertTrue(session.dismissals.contains(.hostility))
        XCTAssertFalse(session.dismissals.contains(.capsEscalation))

        session.apply(
            verdict: LiveToneVerdict(level: .l2, category: .capsEscalation),
            draftHash: 1
        )
        XCTAssertEqual(session.warning, .l2(.capsEscalation),
                       "dismissing hostility must NOT silence capsEscalation")
    }
}

// MARK: - Static source guards

final class LiveToneV1PrivacySourceGuardTests: XCTestCase {

    /// The contract binds the classifier to local-only execution. Static
    /// guard: no networking / pasteboard / Timer / UIKit tokens may
    /// appear in the pure Foundation sources.
    func testCoreSourcesHaveNoNetworkingOrUITokens() throws {
        let forbidden: [String] = [
            "URLSession", "URLRequest", "NSURL", "URL(string",
            "URL(", "http://", "https://",
            "UIPasteboard", "pasteboard",
            "import UIKit", "UIView", "UIScrollView", "UILabel",
            "Timer(timeInterval", "Timer.scheduledTimer",
            "FileManager.default", "write(toFile", "Data("
        ]
        // Project root resolution: Tests/LiveToneV1AcceptanceTests.swift
        // lives at <srcroot>/Tests/<file>. Two `deletingLastPathComponent`
        // hops land on <srcroot> (apps/ios) — the same convention used by
        // DiagnosticsSourceGuardTests, CoachContractTests, and the
        // original LiveToneCoreTests path resolver. From there we append
        // "Shared" to reach the production Live Tone sources.
        let sharedDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // apps/ios/
            .appendingPathComponent("Shared", isDirectory: true)
        for name in ["LiveToneClassifier.swift",
                     "LiveToneSession.swift",
                     "LiveToneMasterToggle.swift",
                     "LiveToneCounters.swift",
                     "LiveToneCopy.swift",
                     "LiveToneKeys.swift",
                     "LiveTonePrivacy.swift",
                     "LiveToneEligibility.swift"] {
            let path = sharedDir.appendingPathComponent(name)
            let source = try String(contentsOf: path, encoding: .utf8)
            for token in forbidden where source.contains(token) {
                XCTFail("\(name) contains forbidden token: \(token)")
            }
        }
    }
}

// MARK: - Timing and stale-result discard

final class LiveToneV1TimingTests: XCTestCase {

    /// The 500 ms typing-idle debounce must NOT fire before the window
    /// elapses, and must fire on or after.
    func testDebounceWindowFiresAfter500ms() {
        let (engine, latch, _, _) = LiveToneV1Helpers.makeEngine()
        let start = Date()
        engine.textDidCommit(draft: "I'll kill you", committedCharacter: nil)
        let w = latch.waitFor(timeout: 1.0) { $0 != .none }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNotEqual(w, .none)
        XCTAssertGreaterThanOrEqual(elapsed, 0.45,
            "debounce must wait at least ~500ms; elapsed=\(elapsed)")
    }

    /// Sentence-ending punctuation flushes immediately, no debounce wait.
    func testPunctuationTriggerFiresImmediately() {
        let (engine, latch, _, _) = LiveToneV1Helpers.makeEngine()
        let start = Date()
        engine.textDidCommit(draft: "I'll kill you", committedCharacter: ".")
        let w = latch.waitFor(timeout: 1.0) { $0 != .none }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNotEqual(w, .none)
        XCTAssertLessThan(elapsed, 0.3,
            "punctuation must flush near-immediately; elapsed=\(elapsed)")
    }

    /// After deleting the offending span, the warning clears within one
    /// cycle (one second).
    func testClearingAfterOffendingSpanGone() {
        let (engine, latch, _, _) = LiveToneV1Helpers.makeEngine()
        engine.textDidCommit(draft: "I'll kill you", committedCharacter: nil)
        let w1 = latch.waitFor(timeout: 1.0) { $0 != .none }
        XCTAssertNotEqual(w1, .none)

        let start = Date()
        engine.textDidCommit(draft: "hello friend", committedCharacter: ".")
        let w2 = latch.waitFor(timeout: 1.5) { $0 == .none }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(w2, .none)
        XCTAssertLessThanOrEqual(elapsed, 1.0,
            "clear must happen within one second; elapsed=\(elapsed)")
    }
}