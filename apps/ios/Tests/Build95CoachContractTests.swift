import XCTest

final class Build95CoachContractTests: XCTestCase {
    func testToneStripStartsWithTonoAndKeepsThreeLocalCandidates() throws {
        let source = try Self.source("KeyboardExtension/KeyboardViewController.swift")
        XCTAssertTrue(source.contains("coach.setTitle(\"TONO\""))
        XCTAssertTrue(source.contains("for index in 0..<3"))
        XCTAssertTrue(source.contains("coach.translatesAutoresizingMaskIntoConstraints = false"))
    }

    func testTonoOnlyTogglesToneChipsAndChipTapStartsNetwork() throws {
        let source = try Self.source("KeyboardExtension/KeyboardViewController.swift")
        XCTAssertTrue(source.contains("@objc private func coachTapped()"))
        XCTAssertTrue(source.contains("setToneChipsEnabled(!toneChipsEnabled)"))
        XCTAssertTrue(source.contains("@objc private func toneChipTapped"))
        XCTAssertTrue(source.contains("runCoach(draft: target.draft, axis:"))
        XCTAssertFalse(source.contains("runCoach(draft: target.draft)"), "TONO toggle must not issue a request")
    }

    func testVariantClientUsesSelectedVariantEndpointAndOneAxisBody() throws {
        let source = try Self.source("KeyboardExtension/TonoCoachClient.swift")
        XCTAssertTrue(source.contains("body has no model or"))
        XCTAssertTrue(source.contains("[\"text\": draft, \"axis\": axis]"))
        XCTAssertFalse(source.contains("body[\"model\"]"))
        XCTAssertFalse(source.contains("body[\"provider\"]"))
    }

    func testVariantDecoderRequiresExactlyMatchingSafeOkEnvelope() throws {
        let ok = """
        {"status":"ok","axis":"safer","text":"Could you help me?","rationale":"Direct ask","risk_after":"low"}
        """.data(using: .utf8)!
        let response = try TonoCoachClient.decodeVariant(ok, expectedAxis: "safer")
        XCTAssertEqual(response.axis, "safer")
        XCTAssertEqual(response.text, "Could you help me?")

        let blocked = #"{"status":"blocked","axis":"safer","reason":"preflight"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try TonoCoachClient.decodeVariant(blocked, expectedAxis: "safer"))

        let mismatch = #"{"status":"ok","axis":"warmer","text":"Hi"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try TonoCoachClient.decodeVariant(mismatch, expectedAxis: "safer"))

        let blank = #"{"status":"ok","axis":"safer","text":"   "}"#.data(using: .utf8)!
        XCTAssertThrowsError(try TonoCoachClient.decodeVariant(blank, expectedAxis: "safer"))
    }

    func testTextChangePreservesUnchangedSameHostRequestAndCancelsMutation() {
        let host = HostSessionIdentity(host: "document:A", session: 1)
        let guardState = CoachRequestLifecycleGuard(
            before: "Please help me",
            after: "",
            host: host
        )
        XCTAssertEqual(guardState.action(liveBefore: "Please help me", liveAfter: "", host: host), .preserve)
        XCTAssertEqual(guardState.action(liveBefore: "Please help us", liveAfter: "", host: host), .cancel)
        XCTAssertEqual(
            guardState.action(
                liveBefore: "Please help me",
                liveAfter: "",
                host: HostSessionIdentity(host: "document:B", session: 2)
            ),
            .cancel
        )
    }

    func testResultsRequireExplicitReplaceAndDismiss() throws {
        let source = try Self.source("KeyboardExtension/KeyboardViewController.swift")
        XCTAssertTrue(source.contains("setTitle(\"Replace\""))
        XCTAssertTrue(source.contains("setTitle(\"Dismiss\""))
        XCTAssertFalse(source.contains("chip.addAction(UIAction { [weak self] _ in\n            self?.applyRewrite(rewriteText)"), "the card itself must not auto-replace")
    }

    func testBuild95FourPrivacySafeClocksExistWithoutDraftLogging() throws {
        let source = try Self.source("KeyboardExtension/TonoCoachClient.swift")
        for clock in ["requestAccepted", "preflightEnd", "providerStart", "responseSent"] {
            XCTAssertTrue(source.contains(clock), "missing privacy-safe clock \(clock)")
        }
        XCTAssertFalse(source.contains("NSLog(\"%{public}@\", draft"))
    }

    private static func source(_ relative: String, file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }
}
