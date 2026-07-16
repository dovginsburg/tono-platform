import XCTest

final class CoachContractTests: XCTestCase {
    private func payload(_ suggestions: String) -> Data {
        """
        {
          "risk_level": "low",
          "perception": "Clear request.",
          "subtext": "asking for help",
          "suggestions": [\(suggestions)],
          "flags": []
        }
        """.data(using: .utf8)!
    }

    func testCoachDecoderReturnsExactlyFourAxesInCanonicalOrder() throws {
        let response = try TonoCoachClient.decode(payload("""
          {"axis":"safer","text":"Could you help me with something?"},
          {"axis":"funnier","text":"Plot twist: I could use some help with something."},
          {"axis":"warmer","text":"Hey, I’d really appreciate your help with something!"},
          {"axis":"clearer","text":"Hey, I need your help with something."}
        """))

        XCTAssertEqual(response.suggestions.map(\.axis), ["warmer", "clearer", "funnier", "safer"])
    }

    func testCoachDecoderRejectsMissingAxisInsteadOfHidingCard() {
        XCTAssertThrowsError(try TonoCoachClient.decode(payload("""
          {"axis":"warmer","text":"Hey, I’d appreciate your help."},
          {"axis":"clearer","text":"Hey, I need your help."},
          {"axis":"safer","text":"Could you help me?"}
        """)))
    }

    func testCoachDecoderCleansExactAxisLabels() throws {
        let response = try TonoCoachClient.decode(payload("""
          {"axis":"warmer","text":"Warmer: One"},
          {"axis":"clearer","text":"Clearer: Two"},
          {"axis":"funnier","text":"Funnier: Three"},
          {"axis":"safer","text":"Safer: Four"}
        """))
        XCTAssertEqual(response.suggestions.map(\.text), ["One", "Two", "Three", "Four"])
    }

    func testCoachDecoderRejectsUnsupportedOrDuplicateAxis() {
        XCTAssertThrowsError(try TonoCoachClient.decode(payload("""
          {"axis":"warmer","text":"One"},
          {"axis":"clearer","text":"Two"},
          {"axis":"funnier","text":"Three"},
          {"axis":"funnier","text":"Four"},
          {"axis":"formal","text":"Five"}
        """)))
    }

    func testCoachLatencyTraceSeparatesFourUserVisibleClocks() throws {
        var trace = CoachLatencyTrace(tapAt: 100)
        trace.markAcknowledged(at: 100.040)
        trace.markDispatched(at: 100.055)
        trace.markFirstByte(at: 107.723)
        trace.markResponse(at: 107.825)
        trace.markRendered(at: 107.835)

        let snapshot = try XCTUnwrap(trace.snapshot)
        XCTAssertEqual(snapshot.tapToAcknowledgementMilliseconds, 40, accuracy: 0.01)
        XCTAssertEqual(snapshot.tapToDispatchMilliseconds, 55, accuracy: 0.01)
        XCTAssertEqual(snapshot.dispatchToFirstByteMilliseconds, 7_668, accuracy: 0.01)
        XCTAssertEqual(snapshot.responseToRenderMilliseconds, 10, accuracy: 0.01)
        XCTAssertEqual(snapshot.totalMilliseconds, 7_835, accuracy: 0.01)
        XCTAssertTrue(snapshot.logLine.contains("tap_to_ack_ms=40"))
        XCTAssertFalse(snapshot.logLine.contains("Please"), "latency logs must never include draft text")
    }

    func testRewriteTargetReplacesCapturedDraftAfterCaretOnlyMove() throws {
        let target = try XCTUnwrap(CoachRewriteTarget.capture(
            before: "  Please help me  ",
            after: "Next sentence"
        ))

        XCTAssertEqual(target.draft, "Please help me")
        XCTAssertEqual(target.mutationPlan(
            liveBefore: "  Please",
            liveAfter: " help me  Next sentence",
            replacement: "Could you help me?"
        ), .init(
            initialCursorOffset: 8,
            deleteCount: 14,
            insertion: "Could you help me?",
            finalCursorOffset: 2
        ))
    }

    func testRewriteTargetRejectsAnyEditInsteadOfReplacingUnrelatedText() throws {
        let target = try XCTUnwrap(CoachRewriteTarget.capture(
            before: "Please help me",
            after: " with this"
        ))

        XCTAssertNil(target.mutationPlan(
            liveBefore: "Unrelated",
            liveAfter: " text",
            replacement: "Could you help me?"
        ))
        XCTAssertNil(target.mutationPlan(
            liveBefore: "Please help us",
            liveAfter: " with this",
            replacement: "Could you help me?"
        ))
        XCTAssertFalse(target.matches(liveBefore: "Please help us", liveAfter: " with this"))
        XCTAssertTrue(target.matches(liveBefore: "Please help me", liveAfter: " with this"))
    }

    func testRewriteTargetRequiresExactPostAdjustmentCaretPosition() throws {
        let target = try XCTUnwrap(CoachRewriteTarget.capture(
            before: "  Please help me  ",
            after: "Next sentence"
        ))

        XCTAssertTrue(target.isAtMutationPosition(
            liveBefore: "  Please help me",
            liveAfter: "  Next sentence"
        ))
        XCTAssertFalse(target.isAtMutationPosition(
            liveBefore: "  Please",
            liveAfter: " help me  Next sentence"
        ), "an ignored caret move must not authorize deletion")
        XCTAssertFalse(target.isAtMutationPosition(
            liveBefore: "  Please help me ",
            liveAfter: " Next sentence"
        ), "a clamped caret move must not authorize deletion")
    }
}
