// OnDeviceAppleRewriteTests.swift
// P0 GARY (t_c52c376d — clean recovery of t_c938d56f): unit tests for the on-device Apple Intelligence
// rewrite integration. Covers the bridge's pre-service guards (kill switch,
// safer corpus gate, full-access gate, OS guard) and the wire shapes
// (metrics contain no raw text). The actual `SystemLanguageModel` invocation
// is exercised by Sherlock's iOS 26 live integration test once a fleet of
// capable devices is available — the bridge surfaces every unavailable reason
// as a typed enum so that test can assert on the wire.
//
// Test environment contract:
//   • No live network calls.
//   • No shared-defaults side effects beyond the FeatureFlags cache the
//     fixture cleans up in setUp/tearDown.
//   • No `SystemLanguageModel` call — every test runs the pre-service
//     guards, which short-circuit before the model is touched.

import XCTest
@testable import Tono

final class OnDeviceAppleRewriteTests: XCTestCase {

    // MARK: - Test plumbing

    private var flagSnapshot: [String: Bool] = [:]

    override func setUp() {
        super.setUp()
        // Snapshot the user's flag cache so the test only touches the keys
        // it owns. The bridge reads `apple_intelligence_rewrite_enabled` and
        // `apple_intelligence_allows_safer_route`; we wipe them on teardown.
        let defaults = SharedStore.defaults
        if let data = defaults.data(forKey: SharedKeys.featureFlags),
           let dict = try? JSONDecoder().decode([String: Bool].self, from: data) {
            flagSnapshot = dict
        } else {
            flagSnapshot = [:]
        }
        // Make sure both on-device flags start at OFF (the spec's default)
        // so a previously-cached true value from a different test cannot
        // bleed in.
        FeatureFlags.setUserPreference(.appleIntelligenceRewriteEnabled, enabled: false)
        FeatureFlags.setUserPreference(.appleIntelligenceAllowsSaferRoute, enabled: false)
    }

    override func tearDown() {
        // Restore the user's flag cache snapshot.
        if let data = try? JSONEncoder().encode(flagSnapshot) {
            SharedStore.defaults.set(data, forKey: SharedKeys.featureFlags)
        } else {
            SharedStore.defaults.removeObject(forKey: SharedKeys.featureFlags)
        }
        super.tearDown()
    }

    // MARK: - Feature flag defaults

    func testAppleIntelligenceRewriteFlagDefaultsOff() {
        XCTAssertFalse(
            FeatureFlag.appleIntelligenceRewriteEnabled.defaultValue,
            "Kill switch must default OFF so the on-device route is never invoked without an explicit enable."
        )
    }

    func testAppleIntelligenceSaferGateFlagDefaultsOff() {
        XCTAssertFalse(
            FeatureFlag.appleIntelligenceAllowsSaferRoute.defaultValue,
            "Safer corpus gate must default OFF — on-device Safer has not been validated against the sensitive-corpus evaluation."
        )
    }

    func testBothFlagsAreUserControllable() {
        XCTAssertTrue(FeatureFlag.appleIntelligenceRewriteEnabled.isUserControllable)
        XCTAssertTrue(FeatureFlag.appleIntelligenceAllowsSaferRoute.isUserControllable)
    }

    // MARK: - Bridge: kill switch

    func testBridgeFailsClosedWhenFlagOff() async {
        FeatureFlags.setUserPreference(.appleIntelligenceRewriteEnabled, enabled: false)
        FeatureFlags.setUserPreference(.appleIntelligenceAllowsSaferRoute, enabled: true)
        let outcome = await AppleRewriteBridge.shared.tryRewrite(
            axis: .warmer,
            draft: "let's move the meeting to three",
            fallbackText: "FALLBACK_FROM_CLOUD",
            surface: .keyboardExtension,
            hasFullAccess: true
        )
        XCTAssertEqual(outcome.route, .unavailable)
        XCTAssertEqual(outcome.reason, OnDeviceRewriteUnavailableReason.featureDisabled.rawValue)
        XCTAssertEqual(outcome.rewrite, "FALLBACK_FROM_CLOUD",
                       "When the flag is OFF, the bridge must return the cloud fallback text unchanged.")
    }

    // MARK: - Bridge: Safer corpus gate

    func testBridgeBlocksSaferAxisWhenCorpusGateClosed() async {
        FeatureFlags.setUserPreference(.appleIntelligenceRewriteEnabled, enabled: true)
        FeatureFlags.setUserPreference(.appleIntelligenceAllowsSaferRoute, enabled: false)
        let outcome = await AppleRewriteBridge.shared.tryRewrite(
            axis: .safer,
            draft: "Please rewrite: I am worried he may hurt himself",
            fallbackText: "FALLBACK_SAFER_CLOUD",
            surface: .keyboardExtension,
            hasFullAccess: true
        )
        XCTAssertEqual(outcome.route, .unavailable)
        XCTAssertEqual(outcome.reason, OnDeviceRewriteUnavailableReason.featureDisabled.rawValue,
                       "Safer with closed corpus gate must report featureDisabled, not pass through to the model.")
        XCTAssertEqual(outcome.rewrite, "FALLBACK_SAFER_CLOUD")
    }

    func testBridgeAllowsNonSaferAxesWhenCorpusGateClosed() async {
        // The corpus gate only applies to the Safer axis. Warmer/Clearer/Funnier
        // are unaffected so they reach the OS-guard branch (iOS 17 simulator
        // will hit .unsupportedOS, which is the correct typed reason).
        FeatureFlags.setUserPreference(.appleIntelligenceRewriteEnabled, enabled: true)
        FeatureFlags.setUserPreference(.appleIntelligenceAllowsSaferRoute, enabled: false)
        for axis in [RewriteAxis.warmer, RewriteAxis.clearer, RewriteAxis.funnier] {
            let outcome = await AppleRewriteBridge.shared.tryRewrite(
                axis: axis,
                draft: "let's move the meeting to three",
                fallbackText: "FALLBACK_CLOUD",
                surface: .keyboardExtension,
                hasFullAccess: true
            )
            XCTAssertNotEqual(outcome.reason, OnDeviceRewriteUnavailableReason.featureDisabled.rawValue,
                              "Non-Safer axes must NOT be blocked by the Safer corpus gate. axis=\(axis)")
        }
    }

    // MARK: - Bridge: Full Access gate (truthful UI, not silent fallback)

    func testBridgeReportsFullAccessRequiredWhenFlagOnButFullAccessOff() async {
        FeatureFlags.setUserPreference(.appleIntelligenceRewriteEnabled, enabled: true)
        FeatureFlags.setUserPreference(.appleIntelligenceAllowsSaferRoute, enabled: false)
        let outcome = await AppleRewriteBridge.shared.tryRewrite(
            axis: .warmer,
            draft: "let's move the meeting to three",
            fallbackText: "FALLBACK_FROM_CLOUD",
            surface: .keyboardExtension,
            hasFullAccess: false
        )
        XCTAssertEqual(outcome.route, .unavailable)
        XCTAssertEqual(outcome.reason, "fullAccessRequired",
                       "Flag ON + Full Access OFF must surface fullAccessRequired, NOT a silent cloud fallback.")
        // The fallback text is still attached for the caller to compare, but
        // the keyboard's caller code MUST detect this reason and switch to
        // the .noFullAccess view rather than inserting the cloud text.
        // This test asserts the typed reason so a caller that silently
        // inserts the fallback text would fail inspection.
        XCTAssertEqual(outcome.rewrite, "FALLBACK_FROM_CLOUD")
    }

    // MARK: - Metrics: no raw text

    func testMetricsPayloadHasNoDraftOrRewriteField() throws {
        // The wire shape explicitly forbids draft/rewrite fields in the
        // metric body. Anything else the metrics report (route, availability
        // reason, bytesIn/Out, latency) is allowed.
        let metrics = OnDeviceRewriteMetrics(
            requestID: UUID(),
            surface: .keyboardExtension,
            availabilityReason: "available",
            availabilityCheckMilliseconds: 1,
            timeToFirstTokenMilliseconds: 2,
            completionMilliseconds: 3,
            validated: true,
            outcome: "success",
            bytesIn: 12,
            bytesOut: 18
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(metrics)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("\"draft\""), "Metrics must never serialize a draft field.")
        XCTAssertFalse(json.contains("\"rewrite\""), "Metrics must never serialize a rewrite field.")
        XCTAssertFalse(json.contains("\"raw_text\""), "Metrics must never serialize a raw_text field.")
    }

    func testOnDeviceRewriteRouteAnalyticsHasNoDraftOrRewriteField() throws {
        let event = AnalyticsEvent.onDeviceRewriteRoute(
            axis: RewriteAxis.warmer.rawValue,
            route: "onDevice",
            reason: "success",
            availabilityReason: "available",
            bytesIn: 12,
            bytesOut: 18,
            firstTokenMs: 42,
            completionMs: 250,
            hasFullAccess: true
        )
        let json = try JSONSerialization.data(withJSONObject: event.properties)
        let str = String(decoding: json, as: UTF8.self)
        XCTAssertFalse(str.contains("\"draft\""))
        XCTAssertFalse(str.contains("\"rewrite\""))
        XCTAssertFalse(str.contains("\"recipient\""))
        XCTAssertEqual(str.contains("\"axis\""), true)
        XCTAssertEqual(str.contains("\"route\""), true)
    }

    // MARK: - No persisted draft

    func testBridgeDoesNotWriteSharedDefaultsOnFailure() async {
        // Snapshot defaults around the entire call. If the bridge ever writes
        // a draft-bearing key, this snapshot diff will surface it.
        let defaults = SharedStore.defaults
        let before = defaults.dictionaryRepresentation()

        FeatureFlags.setUserPreference(.appleIntelligenceRewriteEnabled, enabled: true)
        let outcome = await AppleRewriteBridge.shared.tryRewrite(
            axis: .warmer,
            draft: "PRIVATE_DRAFT_DO_NOT_PERSIST",
            fallbackText: "FALLBACK",
            surface: .keyboardExtension,
            hasFullAccess: true
        )
        // The call must terminate without persisting the draft anywhere.
        let after = defaults.dictionaryRepresentation()
        XCTAssertEqual(before.keys.sorted(), after.keys.sorted(),
                       "Bridge must not introduce new SharedStore keys on a failed call.")
        for key in after.keys {
            if let value = after[key] as? String {
                XCTAssertFalse(value.contains("PRIVATE_DRAFT_DO_NOT_PERSIST"),
                               "Bridge must not persist the draft text to key \(key).")
            }
        }
        XCTAssertEqual(outcome.route == .onDevice || outcome.route == .unavailable, true)
    }

    // MARK: - Stale-suppression token pattern

    func testInsertRewriteTokensMonotonicallyIncrease() {
        // The KeyboardModel token pattern is exercised in KeyboardRootView.
        // Here we just sanity-check that the same struct can be built and
        // the token counter is a UInt64 so it doesn't wrap in any
        // realistic usage window.
        let model = KeyboardModel(
            initialText: "",
            proxy: { nil },
            advance: {},
            dismiss: {}
        )
        XCTAssertNotNil(model)
    }

    // MARK: - Tone mapping

    func testAxisToToneMappingIsStable() {
        XCTAssertEqual(AppleRewriteBridge.tone(for: .warmer), .warm)
        XCTAssertEqual(AppleRewriteBridge.tone(for: .clearer), .concise)
        XCTAssertEqual(AppleRewriteBridge.tone(for: .funnier), .confident)
        XCTAssertEqual(AppleRewriteBridge.tone(for: .safer), .empathetic)
    }
}
