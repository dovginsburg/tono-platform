// Build114RewriteAlternativesTests.swift
// Build 114 — `Use rewrite` / `Try another` / `Dismiss` on the Coach card.
//
// Build 113 shipped `Replace` and `Dismiss`, which told the user nothing about
// what "Replace" would replace, and offered no way to ask for a different
// wording short of re-running Coach. The founder contract replaces those with
// three capability-accurate actions and a bounded three-version sequence.
//
// These tests drive the REAL production types: the sequence value type that
// owns the counting rules, and the real `KeyboardViewController` request path
// (`tryAnotherTapped`, `completeCoachAlternative`, the watchdog). Nothing here
// re-implements the logic it checks, so a mutation to any bound turns a test
// red rather than passing against a copy.
//
// HONEST LIMIT: a unit test has no host document, so the tests that need one
// drive the internal entry points that take the document context explicitly —
// the same seams Build 109/111 established for exactly this reason. VoiceOver
// and Dynamic Type are asserted at the level a unit test can genuinely prove
// (labels, traits, scaled fonts, hit-target policy); visual layout at every
// accessibility size on a physical device remains an unearned claim.

import XCTest
import UIKit
@testable import Tono

final class Build114RewriteAlternativesTests: XCTestCase {

    // ───────────────────────────────────────────────────────────────────
    // The sequence rules (pure, exhaustively checkable)
    // ───────────────────────────────────────────────────────────────────

    private func sequence(axis: String = "warmer", draft: String = "can you look at this")
        -> CoachAlternativeSequence
    {
        CoachAlternativeSequence(axis: axis, sourceDraft: draft, host: .unbound)
    }

    /// The literal acceptance cap: a first rewrite plus exactly ONE additional
    /// generation. Two preserved choices, never a third generation.
    func testFirstRewritePlusExactlyOneAdditionalGeneration() {
        var seq = sequence()
        XCTAssertEqual(seq.displayedVersion, 0)
        XCTAssertTrue(seq.canRequestAnother)

        XCTAssertTrue(seq.recordDisplayed("first wording"))
        XCTAssertEqual(seq.displayedVersion, 1)
        XCTAssertTrue(seq.canRequestAnother, "one additional generation is allowed")

        XCTAssertTrue(seq.recordDisplayed("second wording"))
        XCTAssertEqual(seq.displayedVersion, 2)
        XCTAssertFalse(
            seq.canRequestAnother,
            "the first rewrite plus one additional generation is the whole budget"
        )

        // A third is impossible — not merely discouraged.
        XCTAssertFalse(seq.recordDisplayed("third wording"))
        XCTAssertEqual(seq.displayedVersion, 2)
        XCTAssertEqual(seq.versionLimit, 2)
        XCTAssertEqual(CoachAlternativeSequence.maxVersions, 2)

        // And both remain preserved, so "either" is a real choice between two.
        XCTAssertEqual(seq.priorVersions, ["first wording", "second wording"])
        XCTAssertTrue(seq.canGoBack)
    }

    func testDuplicateOutputConsumesNoSlot() {
        var seq = sequence()
        XCTAssertTrue(seq.recordDisplayed("Sure, happy to take a look."))
        // Same answer, different spacing/case — not a new version.
        XCTAssertFalse(seq.recordDisplayed("sure,   happy to take a look."))
        XCTAssertEqual(seq.displayedVersion, 1, "a duplicate must not consume a slot")
        XCTAssertTrue(seq.isDuplicate("SURE, HAPPY TO TAKE A LOOK."))
        XCTAssertFalse(seq.isDuplicate("Something genuinely different."))
    }

    func testEmptyOutputIsNeverAVersion() {
        var seq = sequence()
        XCTAssertFalse(seq.recordDisplayed("   \n  "))
        XCTAssertEqual(seq.displayedVersion, 0)
    }

    func testSequenceIsBoundToExactSourceAndAxis() {
        let seq = sequence(axis: "warmer", draft: "hello there")
        XCTAssertTrue(seq.matches(axis: "warmer", sourceDraft: "hello there", host: .unbound))
        // A changed message is a different sequence.
        XCTAssertFalse(seq.matches(axis: "warmer", sourceDraft: "hello there!", host: .unbound))
        // A changed tone is a different sequence.
        XCTAssertFalse(seq.matches(axis: "clearer", sourceDraft: "hello there", host: .unbound))
        // A same-content host switch is a different sequence.
        let otherHost = HostSessionIdentity(host: "traits:other", session: 2)
        XCTAssertFalse(seq.matches(axis: "warmer", sourceDraft: "hello there", host: otherHost))
    }

    func testPriorVersionsAreBoundedByTheCap() {
        var seq = sequence()
        seq.recordDisplayed("one")
        seq.recordDisplayed("two")
        seq.recordDisplayed("three")
        XCTAssertEqual(seq.priorVersions.count, 2, "the third was never recorded")
        XCTAssertLessThanOrEqual(
            seq.priorVersions.count, CoachAlternativeSequence.maxVersions,
            "prior-output context must stay bounded"
        )
    }

    // ───────────────────────────────────────────────────────────────────
    // Customer-visible copy
    // ───────────────────────────────────────────────────────────────────

    func testExactActionLabelsAndNoReplaceRemains() throws {
        let source = try Self.source("KeyboardExtension/KeyboardViewController.swift")

        XCTAssertTrue(source.contains(#"useRewriteLabel    = "Use rewrite""#))
        XCTAssertTrue(source.contains(#"tryAnotherLabel    = "Try another""#))
        XCTAssertTrue(source.contains(#"dismissLabel       = "Dismiss""#))

        // The rejected vocabulary must be gone from the rewrite card.
        XCTAssertFalse(
            source.contains(#"setTitle("Replace""#),
            "no customer-visible Replace may remain on a Coach rewrite card"
        )
        XCTAssertFalse(
            source.contains(#"setTitle("Keep""#),
            #""Keep" is ambiguous about what is kept and is not accepted copy"#
        )
        XCTAssertFalse(
            source.contains(#"setTitle("Redo""#),
            #"bare "Redo" is not the accepted copy; "Try another" is"#
        )
    }

    func testNoBackendVocabularyInTheAlternativeCopy() throws {
        let source = try Self.source("KeyboardExtension/KeyboardViewController.swift")
        // The strings this change introduces, isolated from the whole file.
        let introduced = [
            "That's the same wording. Try a different tone, or use this one.",
            "Replaces your message with this rewrite",
            "Closes Coach and leaves your message unchanged",
            "Asks for a different version of this rewrite",
        ]
        let forbidden = [
            "backend", "server", "endpoint", "provider", "api key", "token",
            "transport", "status code", "payload", "localizedDescription",
            "http", "request body", "error:",
        ]
        for phrase in introduced {
            XCTAssertTrue(source.contains(phrase), "expected copy is missing: \(phrase)")
            let lowered = phrase.lowercased()
            for term in forbidden {
                XCTAssertFalse(
                    lowered.contains(term),
                    "consumer copy must not expose \(term): \(phrase)"
                )
            }
            XCTAssertFalse(
                lowered.contains("error"),
                "no consumer string may say Error: \(phrase)"
            )
        }
    }

    // ───────────────────────────────────────────────────────────────────
    // Controller behaviour — the real request path
    // ───────────────────────────────────────────────────────────────────

    @MainActor
    func testFirstResultBecomesVersionOneOfTwo() {
        let controller = Self.makeController()
        controller.beginCoachRewrite(before: "please review this ", after: "", axis: "warmer")
        let requestID = try! XCTUnwrap(controller.activeCoachRequestIDForTesting)

        controller.completeCoach(
            requestID: requestID,
            liveBefore: "please review this ",
            liveAfter: "",
            result: .success(Self.variant(text: "Could you take a look at this?"))
        )

        let state = try! XCTUnwrap(controller.coachSequenceStateForTesting)
        XCTAssertEqual(state.displayed, 1)
        XCTAssertEqual(state.limit, 2)
        XCTAssertTrue(state.canRequestAnother)
        XCTAssertFalse(controller.coachIsBusyForTesting, "the first result releases the busy gate")
    }

    @MainActor
    func testFailedAlternativeConsumesNoSlotAndKeepsThePriorVersion() {
        let controller = Self.makeController()
        Self.deliverFirstVersion(controller, text: "Could you take a look?")

        controller.tryAnotherTapped()
        XCTAssertTrue(controller.coachAlternativeInFlightForTesting)
        let altID = try! XCTUnwrap(controller.alternativeRequestIDForTesting)

        controller.completeCoachAlternative(
            requestID: altID,
            liveBefore: "please review this ",
            liveAfter: "",
            result: .failure(.timeout)
        )

        let state = try! XCTUnwrap(controller.coachSequenceStateForTesting)
        XCTAssertEqual(state.displayed, 1, "a failure must not consume a successful-version slot")
        XCTAssertTrue(state.canRequestAnother)
        XCTAssertFalse(controller.coachIsBusyForTesting, "a failed alternative must release busy")
        XCTAssertFalse(controller.coachAlternativeInFlightForTesting)
    }

    @MainActor
    func testDeadlineOnAnAlternativeConsumesNoSlotAndReleasesBusy() {
        let controller = Self.makeController()
        Self.deliverFirstVersion(controller, text: "Could you take a look?")

        controller.tryAnotherTapped()
        let altID = try! XCTUnwrap(controller.alternativeRequestIDForTesting)
        controller.handleAlternativeDeadlineFired(requestID: altID, tapTime: .now())

        let state = try! XCTUnwrap(controller.coachSequenceStateForTesting)
        XCTAssertEqual(state.displayed, 1)
        XCTAssertFalse(controller.coachIsBusyForTesting, "the watchdog must never latch Coach busy")
        XCTAssertFalse(controller.coachAlternativeInFlightForTesting)
    }

    @MainActor
    func testSupersededAlternativeCannotOverwriteNewerState() {
        let controller = Self.makeController()
        Self.deliverFirstVersion(controller, text: "Could you take a look?")

        controller.tryAnotherTapped()
        let staleID = try! XCTUnwrap(controller.alternativeRequestIDForTesting)

        // The person tears Coach down; the stale response lands afterwards.
        controller.invalidateCoachWorkForTesting()
        controller.completeCoachAlternative(
            requestID: staleID,
            liveBefore: "please review this ",
            liveAfter: "",
            result: .success(Self.variant(text: "A late answer nobody asked for."))
        )

        XCTAssertNil(
            controller.coachSequenceStateForTesting,
            "a superseded alternative must not resurrect a torn-down sequence"
        )
        XCTAssertFalse(controller.coachIsBusyForTesting)
    }

    @MainActor
    func testRapidRepeatedTapsProduceOneRequest() {
        let controller = Self.makeController()
        Self.deliverFirstVersion(controller, text: "Could you take a look?")

        controller.tryAnotherTapped()
        let first = try! XCTUnwrap(controller.alternativeRequestIDForTesting)
        // Four more taps in the same run loop turn.
        for _ in 0..<4 { controller.tryAnotherTapped() }
        XCTAssertEqual(
            controller.alternativeRequestIDForTesting, first,
            "one user action = one request; a second tap while in flight is dropped"
        )
    }

    @MainActor
    func testTheSecondVersionRemovesTheAbilityToRequestAThird() {
        let controller = Self.makeController()
        Self.deliverFirstVersion(controller, text: "version one")

        for text in ["version two"] {
            controller.tryAnotherTapped()
            let id = try! XCTUnwrap(controller.alternativeRequestIDForTesting)
            controller.completeCoachAlternative(
                requestID: id,
                liveBefore: "please review this ",
                liveAfter: "",
                result: .success(Self.variant(text: text))
            )
        }

        let state = try! XCTUnwrap(controller.coachSequenceStateForTesting)
        XCTAssertEqual(state.displayed, 2)
        XCTAssertFalse(state.canRequestAnother)

        // A further tap issues nothing at all.
        controller.tryAnotherTapped()
        XCTAssertNil(
            controller.alternativeRequestIDForTesting,
            "at 2 of 2 a tap must issue no request — there is no third generation"
        )
        XCTAssertFalse(controller.coachIsBusyForTesting)
    }

    @MainActor
    func testDuplicateAlternativeDoesNotLoopOrConsumeASlot() {
        let controller = Self.makeController()
        Self.deliverFirstVersion(controller, text: "Could you take a look?")

        controller.tryAnotherTapped()
        let id = try! XCTUnwrap(controller.alternativeRequestIDForTesting)
        // The provider returns the SAME wording it already gave.
        controller.completeCoachAlternative(
            requestID: id,
            liveBefore: "please review this ",
            liveAfter: "",
            result: .success(Self.variant(text: "could you take a look?"))
        )

        let state = try! XCTUnwrap(controller.coachSequenceStateForTesting)
        XCTAssertEqual(state.displayed, 1, "a duplicate answer is not a new version")
        XCTAssertFalse(
            controller.coachAlternativeInFlightForTesting,
            "a duplicate must terminate, not trigger another request — no retry storm"
        )
        XCTAssertFalse(controller.coachIsBusyForTesting)
    }

    @MainActor
    func testChangingToneStartsASeparateSequence() {
        let controller = Self.makeController()
        Self.deliverFirstVersion(controller, text: "warmer wording")

        controller.tryAnotherTapped()
        let id = try! XCTUnwrap(controller.alternativeRequestIDForTesting)
        controller.completeCoachAlternative(
            requestID: id,
            liveBefore: "please review this ",
            liveAfter: "",
            result: .success(Self.variant(text: "second warmer wording"))
        )
        XCTAssertEqual(controller.coachSequenceStateForTesting?.displayed, 2)

        // Switching tone must NOT inherit the previous tone's budget.
        controller.beginCoachRewrite(before: "please review this ", after: "", axis: "clearer")
        let clearerID = try! XCTUnwrap(controller.activeCoachRequestIDForTesting)
        controller.completeCoach(
            requestID: clearerID,
            liveBefore: "please review this ",
            liveAfter: "",
            result: .success(Self.variant(text: "clearer wording", axis: "clearer"))
        )
        let state = try! XCTUnwrap(controller.coachSequenceStateForTesting)
        XCTAssertEqual(state.displayed, 1, "a new tone starts its own sequence at 1 of 2")
        XCTAssertTrue(state.canRequestAnother)
    }

    @MainActor
    func testANewCapturedMessageResetsTheSequence() {
        let controller = Self.makeController()
        Self.deliverFirstVersion(controller, text: "first message wording")
        XCTAssertEqual(controller.coachSequenceStateForTesting?.displayed, 1)

        controller.beginCoachRewrite(before: "a completely different draft ", after: "", axis: "warmer")
        let id = try! XCTUnwrap(controller.activeCoachRequestIDForTesting)
        controller.completeCoach(
            requestID: id,
            liveBefore: "a completely different draft ",
            liveAfter: "",
            result: .success(Self.variant(text: "new message wording"))
        )
        let state = try! XCTUnwrap(controller.coachSequenceStateForTesting)
        XCTAssertEqual(state.displayed, 1, "a new source message resets the sequence")
    }

    @MainActor
    func testAlternativeForAChangedDraftIsRefused() {
        let controller = Self.makeController()
        Self.deliverFirstVersion(controller, text: "Could you take a look?")

        controller.tryAnotherTapped()
        let id = try! XCTUnwrap(controller.alternativeRequestIDForTesting)
        // The host draft moved under the request.
        controller.completeCoachAlternative(
            requestID: id,
            liveBefore: "please review this NOW ",
            liveAfter: "",
            result: .success(Self.variant(text: "an answer for the wrong text"))
        )
        XCTAssertEqual(
            controller.coachSequenceStateForTesting?.displayed, 1,
            "an alternative for a changed draft must not become a version"
        )
        XCTAssertFalse(controller.coachIsBusyForTesting)
    }

    @MainActor
    func testTeardownDuringAnAlternativeCannotLeaveCoachBusy() {
        let controller = Self.makeController()
        Self.deliverFirstVersion(controller, text: "Could you take a look?")
        controller.tryAnotherTapped()
        XCTAssertTrue(controller.coachIsBusyForTesting)

        controller.invalidateCoachWorkForTesting()
        XCTAssertFalse(
            controller.coachIsBusyForTesting,
            "teardown must release the busy gate or Coach is dead for the session"
        )
        XCTAssertFalse(controller.coachAlternativeInFlightForTesting)
    }

    // ───────────────────────────────────────────────────────────────────
    // Accessibility
    // ───────────────────────────────────────────────────────────────────

    func testEveryActionCarriesAnAccessibilityLabelAndHitTarget() throws {
        let source = try Self.source("KeyboardExtension/KeyboardViewController.swift")
        // All three actions are minimum-hit-target buttons, so a narrower drawn
        // box still accepts a 44pt touch.
        let actionBlock = try XCTUnwrap(
            source.range(of: "let use = TonoMinimumHitTargetButton").map { range in
                String(source[range.lowerBound...].prefix(4000))
            }
        )
        for identifier in ["idUseRewrite", "idTryAnother", "idDismissRewrite"] {
            XCTAssertTrue(actionBlock.contains(identifier), "missing identifier \(identifier)")
        }
        XCTAssertEqual(
            actionBlock.components(separatedBy: "TonoMinimumHitTargetButton").count - 1, 3,
            "all three actions must be minimum-hit-target buttons"
        )
        // Dynamic Type: scaled fonts, and a bounded shrink rather than
        // truncation to nonsense.
        XCTAssertTrue(actionBlock.contains("adjustsFontForContentSizeCategory = true"))
        XCTAssertTrue(actionBlock.contains("minimumScaleFactor = 0.75"))
        // The disabled state must explain itself rather than silently vanish.
        XCTAssertTrue(source.contains("You've seen all \\(limit) versions"))
        XCTAssertTrue(source.contains(".notEnabled"))
    }

    func testVersionCueIsRenderedFromTheSequenceNotAGuess() throws {
        let source = try Self.source("KeyboardExtension/KeyboardViewController.swift")
        XCTAssertTrue(source.contains(#"cue.text = "\(shown) of \(limit)""#))
        XCTAssertTrue(source.contains(#"cue.accessibilityLabel = "Version \(shown) of \(limit)""#))
        XCTAssertTrue(
            source.contains("let shown = sequence.displayedVersion"),
            "the cue must read successfully-displayed count, never a request counter"
        )
    }

    // ───────────────────────────────────────────────────────────────────
    // Request contract
    // ───────────────────────────────────────────────────────────────────

    func testPriorVersionsTravelOnTheEstablishedRequestContract() throws {
        let client = try Self.source("KeyboardExtension/TonoCoachClient.swift")
        XCTAssertTrue(client.contains("priorVersions: [String] = []"))
        XCTAssertTrue(client.contains(#"body["prior_versions"] = Array(bounded)"#))
        XCTAssertTrue(
            client.contains("priorVersions.suffix(CoachAlternativeSequence.maxVersions)"),
            "the field must be bounded before it leaves the device"
        )
        // No second endpoint and no second identity path: Build 114 adds a
        // FIELD to the existing request, not a new request. The two builders
        // here are the pre-existing `coach` and `variant` paths; a third would
        // mean a parallel route was introduced.
        let builders = client.components(separatedBy: "var req = URLRequest(url: endpoint)").count - 1
        XCTAssertEqual(
            builders, 2,
            "Build 114 must add no new request builder — only a field on the existing variant request"
        )
        // The prior-output context is attached in exactly one place.
        XCTAssertEqual(
            client.components(separatedBy: #"body["prior_versions"]"#).count - 1, 1,
            "prior_versions must be attached once, on the established variant request"
        )
        // And the bearer still comes from the one resolver.
        XCTAssertEqual(
            client.components(separatedBy: "resolvedBearerToken()").count - 1,
            client.components(separatedBy: "func resolvedBearerToken").count - 1 + 2,
            "Build 114 must not introduce another credential path"
        )
    }

    func testAnInitialRequestWireShapeIsUnchanged() throws {
        let client = try Self.source("KeyboardExtension/TonoCoachClient.swift")
        XCTAssertTrue(
            client.contains("if !bounded.isEmpty {"),
            "prior_versions must be omitted entirely when there is nothing to send"
        )
    }

    // ───────────────────────────────────────────────────────────────────
    // Helpers
    // ───────────────────────────────────────────────────────────────────

    @MainActor
    private static func makeController() -> KeyboardViewController {
        let controller = KeyboardViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 320)
        controller.view.layoutIfNeeded()
        return controller
    }

    /// Drive a real first rewrite to a delivered version-1 state.
    @MainActor
    private static func deliverFirstVersion(_ controller: KeyboardViewController, text: String) {
        controller.beginCoachRewrite(before: "please review this ", after: "", axis: "warmer")
        guard let id = controller.activeCoachRequestIDForTesting else {
            XCTFail("expected an active coach request")
            return
        }
        controller.completeCoach(
            requestID: id,
            liveBefore: "please review this ",
            liveAfter: "",
            result: .success(variant(text: text))
        )
    }

    private static func variant(
        text: String, axis: String = "warmer"
    ) -> TonoCoachClient.VariantResponse {
        TonoCoachClient.VariantResponse(
            axis: axis,
            text: text,
            rationale: "",
            riskAfter: "low",
            clocks: nil,
            providerMs: 42
        )
    }

    private static func source(_ relative: String, file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }
    // ───────────────────────────────────────────────────────────────────
    // Build 114 approved contract — rejection context, same tone, rollback
    // ───────────────────────────────────────────────────────────────────

    /// The FIRST request must carry no rejection context, and the second must.
    ///
    /// This is the client half of the contract the backend enforces: an
    /// initial rewrite has nothing to reject, so sending an empty rejected set
    /// would be a lie about what the person did. Asserted on the real
    /// sequence, which is what actually feeds the request.
    func testTheFirstRequestCarriesNoRejectedContextAndTheSecondDoes() {
        var seq = sequence(axis: "warmer")
        XCTAssertTrue(
            seq.priorVersions.isEmpty,
            "an initial request must carry no rejected versions"
        )

        XCTAssertTrue(seq.recordDisplayed("Could you take a look at this?"))
        XCTAssertEqual(
            seq.priorVersions, ["Could you take a look at this?"],
            "the second request must carry the rewrite the person just rejected"
        )

        XCTAssertTrue(seq.recordDisplayed("Mind giving this a look?"))
        XCTAssertFalse(
            seq.canRequestAnother,
            "there is no third request: the budget is one additional generation"
        )
    }

    /// The tone the person selected is the tone that is asked for again.
    /// Nothing chooses a tone on their behalf, and none drifts across a retry.
    func testTheAlternativeRequestReusesTheUserSelectedTone() {
        for tone in ["warmer", "clearer", "funnier", "safer"] {
            var seq = sequence(axis: tone)
            XCTAssertTrue(seq.recordDisplayed("first"))
            XCTAssertEqual(seq.axis, tone, "the sequence must keep the selected tone")
            XCTAssertTrue(
                seq.matches(axis: tone, sourceDraft: "can you look at this", host: .unbound),
                "the retry must address the same tone and the same original draft"
            )
        }
    }

    /// The request builder sends the rejected set only when there is one, and
    /// sends the same tone it was given.
    func testTheRequestBuilderSendsRejectedContextOnlyOnARetry() throws {
        let client = try Self.source("KeyboardExtension/TonoCoachClient.swift")
        // The key is attached only when non-empty, so an initial request's
        // wire shape is byte-identical to Build 113's.
        XCTAssertTrue(client.contains("if !bounded.isEmpty {"))
        XCTAssertTrue(client.contains(#"body["prior_versions"] = Array(bounded)"#))
        // The axis travels unchanged — there is no client-side tone selection.
        XCTAssertTrue(
            client.contains(#"var body: [String: Any] = ["text": draft, "axis": axis]"#),
            "the request must send the axis it was handed, unmodified"
        )
        let controller = try Self.source("KeyboardExtension/KeyboardViewController.swift")
        XCTAssertTrue(
            controller.contains("priorVersions: sequence.priorVersions"),
            "the retry must pass the rejected versions the sequence holds"
        )
        XCTAssertTrue(
            controller.contains("let axis = sequence.axis"),
            "the retry must reuse the sequence's own tone, never pick one"
        )
    }

    // ── Rollback: the person is never trapped on a worse second attempt ──

    func testSteppingBackReturnsTheEarlierVersionWithoutSpendingAGeneration() {
        var seq = sequence()
        XCTAssertTrue(seq.recordDisplayed("first wording"))
        XCTAssertTrue(seq.recordDisplayed("second wording"))

        XCTAssertEqual(seq.displayedVersion, 2)
        XCTAssertEqual(seq.currentVersion, "second wording")
        XCTAssertTrue(seq.canGoBack)

        XCTAssertEqual(seq.stepBack(), "first wording")
        XCTAssertEqual(seq.currentVersion, "first wording", "the first rewrite is still there")
        XCTAssertEqual(seq.displayedVersion, 1)
        XCTAssertFalse(seq.canGoBack, "there is nothing before the first")
        XCTAssertTrue(seq.canGoForward)

        // Stepping back does NOT refund a generation — the provider call really
        // happened — and does not un-reject anything.
        XCTAssertEqual(seq.generatedCount, 2)
        XCTAssertEqual(
            seq.priorVersions, ["first wording", "second wording"],
            "looking at an earlier version again does not un-reject it"
        )

        XCTAssertEqual(seq.stepForward(), "second wording")
        XCTAssertEqual(seq.displayedVersion, 2)
    }

    func testTheFirstRewriteSurvivesAWorseSecondAttempt() {
        var seq = sequence()
        XCTAssertTrue(seq.recordDisplayed("the one they liked"))
        XCTAssertTrue(seq.recordDisplayed("a worse attempt"))
        seq.stepBack()
        XCTAssertEqual(
            seq.currentVersion, "the one they liked",
            "asking for another must never be a one-way door"
        )
        // The generation budget really is spent — stepping back is a choice
        // between what already exists, not a refund. Both remain usable, which
        // is the whole point of "either".
        XCTAssertFalse(seq.canRequestAnother)
        XCTAssertEqual(seq.generatedCount, 2)
        XCTAssertTrue(seq.canGoForward)
        XCTAssertEqual(seq.stepForward(), "a worse attempt")
    }

    @MainActor
    func testSteppingBackRePresentsTheEarlierRewriteOnTheCard() {
        let controller = Self.makeController()
        Self.deliverFirstVersion(controller, text: "Could you take a look?")

        controller.tryAnotherTapped()
        let altID = try! XCTUnwrap(controller.alternativeRequestIDForTesting)
        controller.completeCoachAlternative(
            requestID: altID,
            liveBefore: "please review this ",
            liveAfter: "",
            result: .success(Self.variant(text: "Mind giving this a look?"))
        )
        XCTAssertEqual(controller.coachDisplayedVersionForTesting, "Mind giving this a look?")

        controller.showPreviousVersionTapped()

        let cursor = try! XCTUnwrap(controller.coachVersionCursorForTesting)
        XCTAssertEqual(cursor.displayed, 1)
        XCTAssertEqual(cursor.generated, 2, "the generation is still spent")
        XCTAssertFalse(cursor.canGoBack)
        XCTAssertEqual(
            controller.coachDisplayedVersionForTesting, "Could you take a look?",
            "the card must show the rewrite the person came back for"
        )
    }

    @MainActor
    func testTheCardIsNotSwappedUnderAnInFlightAlternative() {
        // The step-back control must not race a completion that is about to
        // land. Under the cap of two this is only reachable while the single
        // permitted alternative is still in flight — at which point there is
        // exactly one version, so the correct outcome is that nothing moves.
        let controller = Self.makeController()
        Self.deliverFirstVersion(controller, text: "Could you take a look?")

        controller.tryAnotherTapped()
        XCTAssertTrue(controller.coachAlternativeInFlightForTesting)

        controller.showPreviousVersionTapped()
        XCTAssertEqual(
            controller.coachDisplayedVersionForTesting, "Could you take a look?",
            "an in-flight request must not have the card swapped under it"
        )
        XCTAssertTrue(
            controller.coachAlternativeInFlightForTesting,
            "and the request itself must be undisturbed"
        )
    }

    func testTheInFlightGuardIsPresentEvenThoughTheCapMakesItHardToReach() throws {
        // Defence in depth: the cap means a second alternative can never be in
        // flight while two versions exist, so this guard is unreachable today.
        // It stays because the cap is a product decision that could widen, and
        // a card swapped under a live completion is a race, not a preference.
        let source = try Self.source("KeyboardExtension/KeyboardViewController.swift")
        XCTAssertTrue(
            source.contains("guard coachAlternativeRequestID == nil, !coachBusy else { return }"),
            "stepping back must refuse while a request is in flight"
        )
    }

    func testTheRollbackControlSaysWhatItDoesForVoiceOver() throws {
        let source = try Self.source("KeyboardExtension/KeyboardViewController.swift")
        XCTAssertTrue(source.contains("Show previous version"))
        XCTAssertTrue(
            source.contains("back.isHidden = !sequence.canGoBack"),
            "the control must appear only when there is something to go back to"
        )
    }

    // ───────────────────────────────────────────────────────────────────
    // RENDERED contract — both directions exist on the real card
    //
    // These drive the built view hierarchy, not the value type. The defect
    // they exist for was invisible to a model test: `CoachAlternativeSequence`
    // already had `canGoForward`/`stepForward` and they behaved correctly —
    // the shipping card simply never rendered a control that called them, so
    // version 2 became unreachable after stepping back.
    //
    // NOTE on the axis. `TonoCoachPalette.Axis` has no `warmer` case, and
    // `presentCoachResults` renders only suggestions whose axis is in
    // `orderedAxes` — so a card built with "warmer" silently collapses to
    // "No rewrites available" and NOTHING is rendered. These tests therefore
    // use a real axis, and assert the card actually rendered before asserting
    // anything about it, so they can never pass vacuously.
    // ───────────────────────────────────────────────────────────────────

    private static func findView(
        _ root: UIView, identifier: String
    ) -> UIView? {
        if root.accessibilityIdentifier == identifier { return root }
        for child in root.subviews {
            if let hit = findView(child, identifier: identifier) { return hit }
        }
        return nil
    }

    /// Drive a real two-version sequence on a RENDERED card, using an axis the
    /// palette actually knows.
    @MainActor
    private static func renderTwoVersions(
        _ controller: KeyboardViewController, first: String, second: String
    ) {
        controller.beginCoachRewrite(before: "please review this ", after: "", axis: "clearer")
        let id = try! XCTUnwrap(controller.activeCoachRequestIDForTesting)
        controller.completeCoach(
            requestID: id,
            liveBefore: "please review this ",
            liveAfter: "",
            result: .success(Self.variant(text: first, axis: "clearer"))
        )
        controller.tryAnotherTapped()
        let altID = try! XCTUnwrap(controller.alternativeRequestIDForTesting)
        controller.completeCoachAlternative(
            requestID: altID,
            liveBefore: "please review this ",
            liveAfter: "",
            result: .success(Self.variant(text: second, axis: "clearer"))
        )
        controller.view.layoutIfNeeded()
    }

    @MainActor
    func testTheRenderedCardOffersBothDirectionsSoEitherRewriteCanBeUsed() throws {
        let controller = Self.makeController()
        Self.renderTwoVersions(controller, first: "version one text", second: "version two text")

        // Guard against a vacuous pass: the card must genuinely have rendered.
        XCTAssertNotNil(
            Self.findView(controller.view, identifier: "TonoKB.versionCue"),
            "the results card did not render — this test would prove nothing"
        )

        let back = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.versionBack"),
            "the rendered card must carry a step-back control"
        )
        // THE REGRESSION: before this fix no view with this identifier existed
        // anywhere in the hierarchy, so this unwrap failed.
        let forward = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.versionForward"),
            "the rendered card must carry a step-forward control, or version 2 "
                + "becomes unreachable once the person steps back to compare"
        )

        // At version 2 of 2: back is offered, forward has nowhere to go.
        XCTAssertFalse(back.isHidden)
        XCTAssertTrue(forward.isHidden)
        XCTAssertEqual(controller.coachDisplayedVersionForTesting, "version two text")

        // Step back to compare version 1.
        controller.showPreviousVersionTapped()
        controller.view.layoutIfNeeded()
        XCTAssertEqual(controller.coachDisplayedVersionForTesting, "version one text")

        let backAfter = try XCTUnwrap(Self.findView(controller.view, identifier: "TonoKB.versionBack"))
        let forwardAfter = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.versionForward")
        )
        XCTAssertTrue(backAfter.isHidden, "nothing is further back than version 1")
        XCTAssertFalse(
            forwardAfter.isHidden,
            "version 2 must be reachable again — otherwise stepping back is a trap "
                + "and only one of the two rewrites can ever be used"
        )

        // And it actually works: return to version 2.
        controller.showNextVersionTapped()
        controller.view.layoutIfNeeded()
        XCTAssertEqual(
            controller.coachDisplayedVersionForTesting, "version two text",
            "the forward control must return the person to the rewrite they left"
        )
    }

    @MainActor
    func testTheRenderedForwardControlIsWiredToATouchAction() throws {
        // A control that renders but does nothing is the same defect wearing a
        // different hat, so the button must carry a touch-up action.
        let controller = Self.makeController()
        Self.renderTwoVersions(controller, first: "one", second: "two")
        controller.showPreviousVersionTapped()
        controller.view.layoutIfNeeded()

        let forward = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.versionForward") as? UIControl
        )
        XCTAssertFalse(forward.isHidden)
        XCTAssertTrue(forward.isEnabled)
        // Firing the real control event moves the card, which is the only
        // wiring assertion worth making: it proves the action exists AND that
        // it does the right thing.
        forward.sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()
        XCTAssertEqual(controller.coachDisplayedVersionForTesting, "two")
    }

    func testBothStepControlsAreRegisteredSurfaceIdentifiers() throws {
        // The identifier registry is what the UI-surface contract enumerates;
        // a control missing from it is invisible to those assertions. `Const`
        // is private to the controller, so this reads the reviewed source the
        // same way the rest of this file's contract checks do.
        let source = try Self.source("KeyboardExtension/KeyboardViewController.swift")
        XCTAssertTrue(source.contains(#"static let idVersionForward   = "TonoKB.versionForward""#))
        XCTAssertTrue(
            source.contains("idAlternativeNotice, idVersionBack, idVersionForward,"),
            "both step controls must be in the identifier registry"
        )
    }

}
