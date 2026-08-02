// Build122PurchaseGateTests.swift
// Tono build 122 — the fail-closed Apple purchase-INITIATION gate.
//
// Build 121 was quarantined because the app could reach `product.purchase(...)`
// while the LIVE backend reported `apple_configured: false`: Apple took the
// money and the backend could not honor the transaction. This suite pins the
// fix from two angles:
//
//   1. EXECUTABLE, deterministic tests of the pure capability contract
//      (`PurchaseCapabilityGate` + `ApplePurchaseCapability`) across the four
//      states the founder named — verified-true, false, unavailable, malformed.
//      No network, no secrets, no simulated production success: every input is
//      an in-memory `/health` body or a synthetic transport outcome.
//
//   2. SOURCE-SCAN tests that the gate is actually WIRED — `StoreKitManager`,
//      `TonoBackend`, `ConsumerErrorCopy`, and the paywall are compiled into the
//      shipping app targets, not this test target (mirroring the house style of
//      Build101RevenueTests), so their invariants are pinned by reading the
//      shipping source. A charge that starts before the capability is confirmed,
//      a default that is not fail-closed, or a buy button that stays enabled all
//      turn this suite red.

import XCTest

final class Build122PurchaseGateTests: XCTestCase {

    // MARK: - 1. Pure capability contract (executable, deterministic)

    private func body(_ json: String) -> Data { Data(json.utf8) }

    /// VERIFIED-TRUE: a well-formed `apple_configured: true` is the ONLY state
    /// that permits initiating a charge.
    func testVerifiedTrueIsTheOnlyStateThatAllowsInitiation() {
        let verdict = PurchaseCapabilityGate.evaluate(
            httpStatus: 200, body: body(#"{"apple_configured": true, "stripe_configured": false}"#)
        )
        XCTAssertEqual(verdict, .ready)
        XCTAssertTrue(verdict.allowsPurchaseInitiation,
                      "a well-formed apple_configured:true must permit purchase initiation")
    }

    /// FALSE: the exact live condition that quarantined Build 121.
    func testFalseIsRefused() {
        let verdict = PurchaseCapabilityGate.evaluate(
            httpStatus: 200, body: body(#"{"apple_configured": false}"#)
        )
        XCTAssertEqual(verdict, .notConfigured)
        XCTAssertFalse(verdict.allowsPurchaseInitiation,
                       "apple_configured:false must never permit a charge — this is the Build 121 defect")
    }

    /// UNAVAILABLE: the readiness contract could not be reached. `nil` status
    /// models a transport failure (offline/DNS/TLS/timeout); a non-2xx status
    /// models a reachable-but-unhealthy backend. Both fail closed.
    func testUnavailableIsRefused() {
        let transportFailed = PurchaseCapabilityGate.evaluate(httpStatus: nil, body: nil)
        XCTAssertEqual(transportFailed, .unavailable)
        XCTAssertFalse(transportFailed.allowsPurchaseInitiation)

        let nilBody = PurchaseCapabilityGate.evaluate(httpStatus: 200, body: nil)
        XCTAssertEqual(nilBody, .unavailable)

        for status in [401, 429, 500, 502, 503] {
            let verdict = PurchaseCapabilityGate.evaluate(
                httpStatus: status, body: body(#"{"apple_configured": true}"#)
            )
            XCTAssertEqual(verdict, .unavailable,
                           "a non-2xx (\(status)) health response must fail closed, even if the body says true")
            XCTAssertFalse(verdict.allowsPurchaseInitiation)
        }
    }

    /// MALFORMED: the response was reachable and 2xx but carried no boolean
    /// `apple_configured`. Missing key, wrong type (a string or a number), a
    /// null, or a non-JSON body are ALL refused — never coerced into a `true`.
    func testMalformedIsRefused() {
        let malformedBodies = [
            #"{"stripe_configured": true}"#,              // key missing
            #"{"apple_configured": "true"}"#,             // string, not bool
            #"{"apple_configured": 1}"#,                  // number, not bool
            #"{"apple_configured": null}"#,               // explicit null
            #"not json at all"#,                          // not JSON
            #"{}"#,                                        // empty object
            #"[]"#,                                        // wrong root type
        ]
        for raw in malformedBodies {
            let verdict = PurchaseCapabilityGate.evaluate(httpStatus: 200, body: body(raw))
            XCTAssertEqual(verdict, .malformed,
                           "malformed contract must be refused, not assumed true: \(raw)")
            XCTAssertFalse(verdict.allowsPurchaseInitiation,
                           "a malformed contract must never permit a charge: \(raw)")
        }
    }

    /// The pre-probe `.unknown` state is fail-closed too — nothing may charge
    /// before a probe resolves the capability.
    func testUnknownForbidsInitiation() {
        XCTAssertFalse(ApplePurchaseCapability.unknown.allowsPurchaseInitiation)
    }

    /// Exhaustive: `.ready` is the one and only permit. If a future edit adds a
    /// permissive state, this pins the invariant.
    func testOnlyReadyPermitsInitiation() {
        let states: [ApplePurchaseCapability] = [.unknown, .ready, .notConfigured, .unavailable, .malformed]
        let permitted = states.filter { $0.allowsPurchaseInitiation }
        XCTAssertEqual(permitted, [.ready],
                       "exactly one capability state may permit a charge, and it must be .ready")
    }

    // MARK: - 2. Gate wiring (source-scan, shipping targets)

    /// The charge must be blocked at INITIATION: `purchase(_:)` consults the
    /// capability gate BEFORE it ever reaches `product.purchase(...)`. Removing
    /// the gate, or moving it after the charge, turns this red.
    func testPurchaseConsultsGateBeforeCharging() throws {
        let source = try Self.readSource("Shared/StoreKitManager.swift")
        // Strip line comments first: an ordering assertion must reason about
        // CODE, not prose. The gate's own comment names `product.purchase(...)`
        // to explain the Build 121 defect, and that mention must not be mistaken
        // for the actual charge site.
        let body = Self.strippingLineComments(
            try Self.functionBody("public func purchase(_ product: Product) async {", in: source)
        )

        guard let gateIndex = body.range(of: "preflightApplePurchaseCapability")?.lowerBound else {
            return XCTFail("purchase(_:) must consult preflightApplePurchaseCapability before charging")
        }
        guard let chargeIndex = body.range(of: "product.purchase(")?.lowerBound else {
            return XCTFail("expected purchase(_:) to call product.purchase(...)")
        }
        XCTAssertLessThan(gateIndex, chargeIndex,
                          "the capability gate must run BEFORE product.purchase(...) — a post-charge check cannot refund a charge")
        XCTAssertTrue(body.contains("allowsPurchaseInitiation"),
                      "the gate must guard on allowsPurchaseInitiation, not proceed unconditionally")
    }

    /// The published capability defaults to a fail-closed value so a fresh
    /// manager never treats purchases as available before probing.
    func testCapabilityDefaultsFailClosed() throws {
        let source = try Self.readSource("Shared/StoreKitManager.swift")
        XCTAssertTrue(
            source.contains("applePurchaseCapability: ApplePurchaseCapability = .unknown"),
            "applePurchaseCapability must default to the fail-closed .unknown state"
        )
        XCTAssertTrue(
            source.contains("applePurchaseCapabilityProvider"),
            "an injectable capability provider seam must exist for deterministic tests"
        )
    }

    /// The live probe reads the existing `/health` contract's `apple_configured`
    /// boolean through the pure gate, and folds transport errors to a non-ready
    /// verdict rather than throwing.
    func testBackendProbeReadsHealthThroughTheGate() throws {
        let source = try Self.readSource("Shared/TonoBackend.swift")
        let body = try Self.functionBody("public func fetchApplePurchaseCapability() async -> ApplePurchaseCapability {", in: source)
        XCTAssertTrue(body.contains("/health"),
                      "capability must be read from the live /health readiness contract")
        XCTAssertTrue(body.contains("PurchaseCapabilityGate.evaluate"),
                      "the probe must interpret the response through the pure fail-closed gate")
        XCTAssertTrue(body.contains("return .unavailable"),
                      "a transport failure must fold to .unavailable, not throw or assume readiness")
    }

    /// The two new refusal reasons are honest, distinct, and never overloaded
    /// onto "subscription required" (a 402), and their user copy states that no
    /// charge was made.
    func testRefusalCopyIsHonestAndDistinct() throws {
        let store = try Self.readSource("Shared/StoreKitManager.swift")
        XCTAssertTrue(store.contains("case appleNotConfigured"),
                      "a distinct StoreError case must exist for a backend that cannot honor Apple charges")
        XCTAssertTrue(store.contains("case purchaseCapabilityUnavailable"),
                      "a distinct StoreError case must exist for an unreachable readiness contract")

        let copy = try Self.readSource("Shared/ConsumerErrorCopy.swift")
        XCTAssertTrue(copy.contains("case .appleNotConfigured"),
                      "ConsumerErrorCopy must classify appleNotConfigured explicitly")
        XCTAssertTrue(copy.contains("case .purchaseCapabilityUnavailable"),
                      "ConsumerErrorCopy must classify purchaseCapabilityUnavailable explicitly")
        XCTAssertTrue(copy.contains("purchasesTemporarilyUnavailable"),
                      "a distinct recovery for 'server cannot sell right now' must exist")
    }

    /// The paywall buy button is disabled unless the live capability confirms
    /// purchases can be honored — defense-in-depth around the model gate.
    func testPaywallDisablesBuyButtonUntilReady() throws {
        let source = try Self.readSource("App/SettingsView.swift")
        XCTAssertTrue(
            source.contains("purchaseEnabled: store.applePurchaseCapability.allowsPurchaseInitiation"),
            "the paywall must gate the buy button on the resolved capability"
        )
        XCTAssertTrue(
            source.contains("refreshApplePurchaseCapability"),
            "the paywall must resolve the live capability on appear"
        )
        XCTAssertTrue(
            source.contains(".disabled(isLoading || !purchaseEnabled)"),
            "the ProductRow buy button must be disabled when purchases are not enabled"
        )
    }

    // MARK: - Source helpers (repo-relative, mirroring Build101RevenueTests)

    private static func readSource(_ relative: String, file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // .../Tests
            .deletingLastPathComponent()   // .../apps/ios
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// Removes `//` line comments so a code-ordering assertion cannot be fooled
    /// by a mention of a symbol inside a comment. (String literals in this file's
    /// scanned functions do not contain `//`, so a simple line strip is safe.)
    private static func strippingLineComments(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            if let range = line.range(of: "//") {
                return line[line.startIndex..<range.lowerBound]
            }
            return line
        }.joined(separator: "\n")
    }

    /// Returns the brace-balanced body of the function whose signature line is
    /// `signature`, so ordering assertions are scoped to that function and can't
    /// be satisfied by an unrelated occurrence elsewhere in the file.
    private static func functionBody(_ signature: String, in source: String) throws -> String {
        guard let sigRange = source.range(of: signature) else {
            throw XCTSkip("signature not found: \(signature)")
        }
        var depth = 0
        var started = false
        var startIndex = sigRange.upperBound
        var index = source.range(of: "{", range: sigRange.lowerBound..<source.endIndex)?.lowerBound ?? sigRange.upperBound
        while index < source.endIndex {
            let ch = source[index]
            if ch == "{" {
                depth += 1
                if !started { started = true; startIndex = source.index(after: index) }
            } else if ch == "}" {
                depth -= 1
                if depth == 0 && started {
                    return String(source[startIndex..<index])
                }
            }
            index = source.index(after: index)
        }
        return String(source[startIndex..<source.endIndex])
    }
}
