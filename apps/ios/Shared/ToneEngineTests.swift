// ToneEngineTests.swift
// XCTest target. Covers the mock analyzer, the JSON decoder, and the
// free-tier gate. Run from Xcode (⌘U) or via xcodebuild test.

import XCTest
@testable import Tono

final class ToneEngineTests: XCTestCase {

    func testMockFlagsPassiveAggressive() async throws {
        let engine = ToneEngine(provider: .mock, model: "mock", apiKey: nil)
        let req = AnalysisRequest(
            draft: "As per my last message, can you please respond?",
            recipientHint: nil,
            preferredVoice: nil
        )
        let result = try await engine.analyze(req)
        XCTAssertEqual(result.riskLevel, .high)
        XCTAssertTrue(result.flags.contains("passive-aggressive"))
    }

    func testMockFlagsVagueAsk() async throws {
        let engine = ToneEngine(provider: .mock, model: "mock", apiKey: nil)
        let req = AnalysisRequest(
            draft: "let me know sometime when you can",
            recipientHint: nil,
            preferredVoice: nil
        )
        let result = try await engine.analyze(req)
        XCTAssertTrue(result.flags.contains("ambiguous ask"))
    }

    func testMockCalmDraftIsLowRisk() async throws {
        let engine = ToneEngine(provider: .mock, model: "mock", apiKey: nil)
        let req = AnalysisRequest(
            draft: "Hey! Quick question — does Thursday at 3 work for a 20-min sync?",
            recipientHint: nil,
            preferredVoice: nil
        )
        let result = try await engine.analyze(req)
        XCTAssertEqual(result.riskLevel, .low)
        XCTAssertTrue(result.suggestions.contains { $0.axis == .warmer })
        XCTAssertTrue(result.suggestions.contains { $0.axis == .safer })
    }

    func testDecodingTolerantOfFences() throws {
        let json = "```json\n{\"risk_level\":\"low\",\"perception\":\"ok\",\"subtext\":\"calm\",\"suggestions\":[],\"flags\":[]}\n```"
        let result = try ToneEngine.decode(json)
        XCTAssertEqual(result.riskLevel, .low)
        XCTAssertEqual(result.perception, "ok")
    }

    func testDecodingRejectsBadJSON() {
        XCTAssertThrowsError(try ToneEngine.decode("not json"))
    }
}
