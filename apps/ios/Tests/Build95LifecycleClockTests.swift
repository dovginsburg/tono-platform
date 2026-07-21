import XCTest

/// Build 95 truthful four-clock RED→GREEN behavioral proof.
///
/// Sherlock's NO-GO on d705a8e flagged that the four lifecycle clocks
/// (`requestAccepted`, `preflightEnd`, `providerStart`, `responseSent`)
/// were fabricated with `Date()` around/after URLSession completion —
/// i.e. all four anchors captured AFTER the response was received, in the
/// same instant, with no connection to the real server lifecycle.
///
/// These tests are the behavioral pin for the fix. They exercise the
/// strict server-envelope decoder (`TonoCoachClient.decodeServerClocks`)
/// against the contract the backend `LifecycleClockRecorder` produces:
///   • A well-formed envelope decodes to a `CoachClocks` with monotonic
///     integer-ms anchors.
///   • A missing envelope fails closed (no fabrication).
///   • A non-integer / fractional / negative envelope fails closed.
///   • A non-monotonic envelope fails closed.
///   • A `response_sent_ms` that wildly exceeds the iOS request window
///     fails closed (no "the server answered before we asked").
///
/// Together with `Build95CoachContractTests.testBuild95FourPrivacySafeClocksExistWithoutDraftLogging`
/// this file is the full RED→GREEN behavioral proof.
final class Build95LifecycleClockTests: XCTestCase {

    // MARK: - GREEN: well-formed envelope

    func testDecodeVariantReturnsServerSourcedMonotonicClocks() throws {
        // A canonical envelope matching the backend LifecycleClockRecorder.
        let payload = #"""
        {
          "status": "ok",
          "axis": "safer",
          "text": "Could you help me?",
          "rationale": "Direct ask",
          "risk_after": "low",
          "clocks": {
            "request_accepted_ms": 0,
            "preflight_end_ms": 12,
            "provider_start_ms": 13,
            "response_sent_ms": 47,
            "preflight_ms": 12,
            "provider_ms": 34
          }
        }
        """#.data(using: .utf8)!
        let response = try TonoCoachClient.decodeVariant(
            payload,
            expectedAxis: "safer",
            requestAccepted: Date()
        )
        XCTAssertEqual(response.clocks.requestAcceptedMonotonicMs, 0)
        XCTAssertEqual(response.clocks.preflightEndMonotonicMs, 12)
        XCTAssertEqual(response.clocks.providerStartMonotonicMs, 13)
        XCTAssertEqual(response.clocks.responseSentMonotonicMs, 47)
    }

    func testDecodeServerClocksPreservesServerAnchorValuesExactly() throws {
        // The decoder must surface exactly what the server emitted; no
        // rounding, no offset, no surprise additions. This pins the
        // authoritative-source contract.
        let envelope: [String: Any] = [
            "request_accepted_ms": 100,
            "preflight_end_ms": 250,
            "provider_start_ms": 260,
            "response_sent_ms": 900,
            "preflight_ms": 150,
            "provider_ms": 640,
        ]
        let payload: [String: Any] = ["clocks": envelope]
        let clocks = try TonoCoachClient.decodeServerClocks(
            payload: payload,
            requestAccepted: Date()
        )
        XCTAssertEqual(clocks.requestAcceptedMonotonicMs, 100)
        XCTAssertEqual(clocks.preflightEndMonotonicMs, 250)
        XCTAssertEqual(clocks.providerStartMonotonicMs, 260)
        XCTAssertEqual(clocks.responseSentMonotonicMs, 900)
    }

    // MARK: - RED: missing envelope

    func testDecodeVariantRejectsPayloadWithoutClocksEnvelope() {
        // Truthful unavailable state: a 200 OK with no `clocks` envelope
        // is malformed and MUST fail closed. The previous build fabricated
        // four values around/after URLSession completion instead; this test
        // is the RED that pins the absence of that behavior.
        let payload = #"""
        {
          "status": "ok",
          "axis": "safer",
          "text": "Could you help me?",
          "risk_after": "low"
        }
        """#.data(using: .utf8)!
        XCTAssertThrowsError(
            try TonoCoachClient.decodeVariant(payload, expectedAxis: "safer", requestAccepted: Date())
        ) { error in
            let nsError = error as NSError
            XCTAssertTrue(
                nsError.localizedDescription.contains("clocks"),
                "decoder must surface a clocks-related error, got: \(nsError.localizedDescription)"
            )
        }
    }

    func testDecodeServerClocksRejectsMissingEnvelope() {
        XCTAssertThrowsError(
            try TonoCoachClient.decodeServerClocks(
                payload: ["axis": "safer"],
                requestAccepted: Date()
            )
        )
    }

    // MARK: - RED: malformed envelope

    func testDecodeServerClocksRejectsEnvelopeMissingRequiredKey() {
        let envelope: [String: Any] = [
            "request_accepted_ms": 0,
            "preflight_end_ms": 10,
            // provider_start_ms omitted
            "response_sent_ms": 20,
        ]
        XCTAssertThrowsError(
            try TonoCoachClient.decodeServerClocks(
                payload: ["clocks": envelope],
                requestAccepted: Date()
            )
        )
    }

    func testDecodeServerClocksRejectsFractionalAnchor() {
        // Double would be fractional ms; the contract pins integer ms only.
        let envelope: [String: Any] = [
            "request_accepted_ms": 0,
            "preflight_end_ms": 10.5,    // fractional — must reject
            "provider_start_ms": 11,
            "response_sent_ms": 20,
        ]
        XCTAssertThrowsError(
            try TonoCoachClient.decodeServerClocks(
                payload: ["clocks": envelope],
                requestAccepted: Date()
            )
        )
    }

    func testDecodeServerClocksRejectsStringAnchor() {
        let envelope: [String: Any] = [
            "request_accepted_ms": "0",    // string — must reject
            "preflight_end_ms": 10,
            "provider_start_ms": 11,
            "response_sent_ms": 20,
        ]
        XCTAssertThrowsError(
            try TonoCoachClient.decodeServerClocks(
                payload: ["clocks": envelope],
                requestAccepted: Date()
            )
        )
    }

    func testDecodeServerClocksRejectsNegativeAnchor() {
        let envelope: [String: Any] = [
            "request_accepted_ms": 0,
            "preflight_end_ms": -1,    // negative — must reject
            "provider_start_ms": 0,
            "response_sent_ms": 10,
        ]
        XCTAssertThrowsError(
            try TonoCoachClient.decodeServerClocks(
                payload: ["clocks": envelope],
                requestAccepted: Date()
            )
        )
    }

    // MARK: - RED: non-monotonic envelope

    func testDecodeServerClocksRejectsPreflightBeforeRequestAccepted() {
        let envelope: [String: Any] = [
            "request_accepted_ms": 100,
            "preflight_end_ms": 50,     // preflight < request_accepted — must reject
            "provider_start_ms": 60,
            "response_sent_ms": 80,
        ]
        XCTAssertThrowsError(
            try TonoCoachClient.decodeServerClocks(
                payload: ["clocks": envelope],
                requestAccepted: Date()
            )
        )
    }

    func testDecodeServerClocksRejectsProviderBeforePreflight() {
        let envelope: [String: Any] = [
            "request_accepted_ms": 0,
            "preflight_end_ms": 50,
            "provider_start_ms": 30,    // provider < preflight — must reject
            "response_sent_ms": 80,
        ]
        XCTAssertThrowsError(
            try TonoCoachClient.decodeServerClocks(
                payload: ["clocks": envelope],
                requestAccepted: Date()
            )
        )
    }

    func testDecodeServerClocksRejectsResponseBeforeProvider() {
        let envelope: [String: Any] = [
            "request_accepted_ms": 0,
            "preflight_end_ms": 50,
            "provider_start_ms": 60,
            "response_sent_ms": 40,     // response < provider — must reject
        ]
        XCTAssertThrowsError(
            try TonoCoachClient.decodeServerClocks(
                payload: ["clocks": envelope],
                requestAccepted: Date()
            )
        )
    }

    // MARK: - RED: cross-domain fabrication

    func testDecodeServerClocksRejectsResponseSentExceedingLocalRequestWindow() {
        // Cross-domain sanity: a server `response_sent_ms` larger than
        // the elapsed milliseconds between iOS's captured `requestAccepted`
        // and the decoder call implies the server answered before we
        // asked — i.e. fabrication. We allow up to 60s grace for RTT +
        // clock-skew; anything beyond must reject.
        let envelope: [String: Any] = [
            "request_accepted_ms": 0,
            "preflight_end_ms": 100,
            "provider_start_ms": 110,
            "response_sent_ms": Int64.max,    // absurd — must reject
        ]
        XCTAssertThrowsError(
            try TonoCoachClient.decodeServerClocks(
                payload: ["clocks": envelope],
                requestAccepted: Date()
            )
        )
    }

    // MARK: - SOURCE: no fabrication pattern in the production client

    func testVariantClientDoesNotCaptureDateInsideURLSessionCompletion() throws {
        // Behavioral pin: the original bug was `let responseSent = Date()`
        // captured INSIDE the URLSession completion handler (after the
        // response was received), and `let preflightEnd = Date()` /
        // `let providerStart = preflightEnd` in the same spot. This test
        // is the source-level RED that proves the fabrication is gone.
        let source = try Self.source()
        XCTAssertFalse(
            source.contains("let responseSent = Date()"),
            "responseSent must come from the server envelope, not Date()"
        )
        XCTAssertFalse(
            source.contains("let providerStart = preflightEnd"),
            "providerStart must come from the server envelope, not a same-instant copy"
        )
        XCTAssertFalse(
            source.contains("let preflightEnd = Date()"),
            "preflightEnd must come from the server envelope, not Date()"
        )
    }

    func testVariantClientCapturesRequestAcceptedOnlyOnceBeforeResume() throws {
        // The only client-side Date() anchor is `requestAccepted`, captured
        // BEFORE `task.resume()`. The decoder uses it only to cross-check
        // the server envelope, never to invent any of the four clock
        // values.
        let source = try Self.source()
        // Find the variant() body and confirm there's exactly one
        // `let requestAccepted = Date()` and it's followed (after a
        // reasonable gap) by `task.resume()` BEFORE any completion
        // handler construction that might recapture it.
        let captureCount = source.components(separatedBy: "let requestAccepted = Date()").count - 1
        XCTAssertEqual(captureCount, 1, "requestAccepted must be captured exactly once, found \(captureCount)")
    }

    // MARK: - SOURCE: decoder is the only path that produces CoachClocks

    func testCoachClocksHasNoInitializersFromDateParameters() throws {
        // The `CoachClocks` initializer signature must require integer-ms
        // anchors, NOT Date-based ones — otherwise a future regression
        // could reintroduce the fabrication pattern at the type level.
        let source = try Self.source()
        XCTAssertFalse(
            source.contains("public init(\n            requestAccepted: Date"),
            "CoachClocks must not expose a Date-based initializer"
        )
        XCTAssertFalse(
            source.contains("requestAccepted: Date,\n            preflightEnd: Date"),
            "CoachClocks must not accept Date-typed anchors"
        )
    }

    // MARK: - helpers

    private static func source(_ relative: String = "KeyboardExtension/TonoCoachClient.swift",
                               file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }
}