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

    func testCoachDecoderRejectsUnsupportedOrDuplicateAxis() {
        XCTAssertThrowsError(try TonoCoachClient.decode(payload("""
          {"axis":"warmer","text":"One"},
          {"axis":"clearer","text":"Two"},
          {"axis":"funnier","text":"Three"},
          {"axis":"funnier","text":"Four"},
          {"axis":"formal","text":"Five"}
        """)))
    }
}
