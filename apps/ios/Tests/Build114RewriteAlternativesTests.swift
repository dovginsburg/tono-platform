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

    func testInitialPlusTwoAlternativesAndNoFourth() {
        var seq = sequence()
        XCTAssertEqual(seq.displayedVersion, 0)
        XCTAssertTrue(seq.canRequestAnother)

        XCTAssertTrue(seq.recordDisplayed("first wording"))
        XCTAssertEqual(seq.displayedVersion, 1)
        XCTAssertTrue(seq.canRequestAnother)

        XCTAssertTrue(seq.recordDisplayed("second wording"))
        XCTAssertEqual(seq.displayedVersion, 2)
        XCTAssertTrue(seq.canRequestAnother)

        XCTAssertTrue(seq.recordDisplayed("third wording"))
        XCTAssertEqual(seq.displayedVersion, 3)
        XCTAssertFalse(seq.canRequestAnother, "three successful versions is the cap")

        // A fourth is impossible — not merely discouraged.
        XCTAssertFalse(seq.recordDisplayed("fourth wording"))
        XCTAssertEqual(seq.displayedVersion, 3)
        XCTAssertEqual(seq.versionLimit, 3)
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
        XCTAssertEqual(seq.priorVersions.count, 3)
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
    func testFirstResultBecomesVersionOneOfThree() {
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
        XCTAssertEqual(state.limit, 3)
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
    func testThirdVersionRemovesTheAbilityToRequestAFourth() {
        let controller = Self.makeController()
        Self.deliverFirstVersion(controller, text: "version one")

        for text in ["version two", "version three"] {
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
        XCTAssertEqual(state.displayed, 3)
        XCTAssertFalse(state.canRequestAnother)

        // A further tap issues nothing at all.
        controller.tryAnotherTapped()
        XCTAssertNil(
            controller.alternativeRequestIDForTesting,
            "at 3 of 3 a tap must issue no request"
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
        XCTAssertEqual(state.displayed, 1, "a new tone starts its own sequence at 1 of 3")
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
}
