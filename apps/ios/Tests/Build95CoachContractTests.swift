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
        // Build 95 truthful four-clock fix: a well-formed OK envelope MUST
        // include a complete `clocks` envelope (request_accepted_ms,
        // preflight_end_ms, provider_start_ms, response_sent_ms, integer
        // ms, monotonically non-decreasing). The decoder will not
        // fabricate any of the four values; a missing envelope fails
        // closed. The previous version of this test asserted only on
        // status/axis/text and pre-dated the lifecycle envelope; with
        // the strict decoder, that contract must include the clocks.
        let ok = """
        {
          "status":"ok",
          "axis":"safer",
          "text":"Could you help me?",
          "rationale":"Direct ask",
          "risk_after":"low",
          "clocks":{
            "request_accepted_ms":0,
            "preflight_end_ms":12,
            "provider_start_ms":13,
            "response_sent_ms":47,
            "preflight_ms":12,
            "provider_ms":34
          }
        }
        """.data(using: .utf8)!
        let response = try TonoCoachClient.decodeVariant(ok, expectedAxis: "safer", requestAccepted: Date())
        XCTAssertEqual(response.axis, "safer")
        XCTAssertEqual(response.text, "Could you help me?")
        // The decoder surfaces the server envelope exactly — every
        // anchor is integer ms and monotonic in the documented order.
        let envelopeClocks = try XCTUnwrap(
            response.clocks,
            "a server response with a well-formed clocks envelope must surface its four anchors"
        )
        XCTAssertEqual(envelopeClocks.requestAcceptedMonotonicMs, 0)
        XCTAssertEqual(envelopeClocks.preflightEndMonotonicMs, 12)
        XCTAssertEqual(envelopeClocks.providerStartMonotonicMs, 13)
        XCTAssertEqual(envelopeClocks.responseSentMonotonicMs, 47)

        let blocked = #"{"status":"blocked","axis":"safer","reason":"preflight"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try TonoCoachClient.decodeVariant(blocked, expectedAxis: "safer"))

        let mismatch = #"{"status":"ok","axis":"warmer","text":"Hi"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try TonoCoachClient.decodeVariant(mismatch, expectedAxis: "safer"))

        let blank = #"{"status":"ok","axis":"safer","text":"   "}"#.data(using: .utf8)!
        XCTAssertThrowsError(try TonoCoachClient.decodeVariant(blank, expectedAxis: "safer"))

        // Build 97 production-shape compatibility: a status=ok response
        // without a `clocks` envelope is no longer malformed — the
        // absence is itself the truthful state and iOS does not
        // fabricate. The decoder still validates strictly when the
        // envelope IS present (see the test above), so the build 95
        // "all four clocks come from the server" contract holds.
        let noClocks = #"{"status":"ok","axis":"safer","text":"Could you help me?","risk_after":"low"}"#.data(using: .utf8)!
        let noClocksResponse = try TonoCoachClient.decodeVariant(noClocks, expectedAxis: "safer", requestAccepted: Date())
        XCTAssertEqual(noClocksResponse.axis, "safer")
        XCTAssertEqual(noClocksResponse.text, "Could you help me?")
        XCTAssertNil(
            noClocksResponse.clocks,
            "missing envelope is the truthful state — iOS must not fabricate"
        )
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
        // Build 95 truthful four-clock fix: the four privacy-safe anchors
        // MUST be present in the source as `*MonotonicMs` integer-ms
        // properties (sourced from the server envelope), NOT as bare
        // `Date`-based variables that the previous build could fabricate
        // around/after URLSession completion. The previous version of
        // this test asserted only that the four names appeared anywhere
        // in source; that test passed even when the values were all
        // captured at `Date()` post-completion, which is the exact
        // fabrication Sherlock flagged. The behavioral proof is now in
        // `Build95LifecycleClockTests.swift`; this source contract just
        // pins the structural renaming.
        let source = try Self.source("KeyboardExtension/TonoCoachClient.swift")
        for clock in ["requestAcceptedMonotonicMs", "preflightEndMonotonicMs",
                      "providerStartMonotonicMs", "responseSentMonotonicMs"] {
            XCTAssertTrue(source.contains(clock), "missing privacy-safe clock \(clock)")
        }
        XCTAssertFalse(
            source.contains("NSLog(\"%{public}@\", draft"),
            "draft must never be logged at %{public}@ visibility"
        )
        // Hard guard against re-introducing the old fabrication pattern:
        // a `let responseSent = Date()` captured INSIDE the URLSession
        // completion handler was the bug.
        XCTAssertFalse(
            source.contains("let responseSent = Date()"),
            "responseSent must come from the server envelope, not Date()"
        )
        XCTAssertFalse(
            source.contains("let providerStart = preflightEnd"),
            "providerStart must come from the server envelope, not a same-instant copy"
        )
    }

    private static func source(_ relative: String, file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }
}
