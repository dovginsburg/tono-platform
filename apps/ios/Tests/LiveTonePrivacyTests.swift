// LiveTonePrivacyTests.swift
// XCTest coverage for the Live Tone privacy/control lane (build-90).
//
// Proves: default OFF, every field exclusion, no host fingerprinting, no
// networking/polling/timers in the sources, and immediate kill-switch /
// remote-disable behavior. The pure logic is additionally exercised by the
// standalone Scripts/verify_live_tone_privacy.swift runner, which compiles
// these same production sources without a simulator.

import XCTest
@testable import Tono

final class LiveTonePrivacyTests: XCTestCase {

    // MARK: Helpers

    /// Isolated defaults so nothing leaks between tests or into the real suite.
    private func makeDefaults() -> UserDefaults {
        let suite = "com.tono.livetone.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private let allowed: Set<LiveToneHostCategory> = [.messaging, .social, .notes]

    private func eligibleBase() -> LiveToneFieldContext {
        LiveToneFieldContext(
            isSecureTextEntry: false,
            keyboardType: .default,
            hostCategory: .messaging,
            before: "Hey, are we still on for tonight",
            after: "?"
        )
    }

    private func decision(
        _ context: LiveToneFieldContext,
        masterEnabled: Bool = true
    ) -> LiveToneEligibilityDecision {
        LiveToneEligibility.evaluate(
            context: context,
            allowedHostCategories: allowed,
            masterEnabled: masterEnabled
        )
    }

    // MARK: 1 — Default OFF

    func testDefaultsAreOff() {
        let pref = LiveTonePreference(defaults: makeDefaults())
        XCTAssertFalse(pref.isOptedIn)
        XCTAssertFalse(pref.isUserPaused)
        XCTAssertFalse(pref.isRemoteDisabled)
        XCTAssertFalse(pref.masterEnabled)
        XCTAssertTrue(pref.allowedHostCategories.isEmpty)
    }

    func testMasterGateOffIsIneligibleEvenForCleanDraft() {
        XCTAssertEqual(decision(eligibleBase(), masterEnabled: false), .ineligible(.disabled))
    }

    // MARK: 2 — Immediate kill switch (no cache)

    func testKillSwitchIsObservedByAFreshReaderImmediately() {
        let defaults = makeDefaults()
        let writer = LiveTonePreference(defaults: defaults)
        writer.isOptedIn = true
        writer.allowedHostCategories = [.messaging]
        XCTAssertTrue(writer.masterEnabled)

        writer.kill()
        let freshReader = LiveTonePreference(defaults: defaults)
        XCTAssertTrue(freshReader.isUserPaused)
        XCTAssertFalse(freshReader.masterEnabled)

        writer.resume()
        XCTAssertTrue(LiveTonePreference(defaults: defaults).masterEnabled)
    }

    // MARK: 5 — Remote-disable directive via existing Coach round-trip

    func testRemoteDirectiveParsesExistingCoachFlags() {
        XCTAssertTrue(LiveTonePreference.directive(fromCoachFlags: [LiveTonePreference.disableFlag]).isDisabled)
        XCTAssertFalse(LiveTonePreference.directive(fromCoachFlags: ["warmer_ok", "other"]).isDisabled)
    }

    func testAppliedRemoteDirectivePersistsAndGatesOff() {
        let defaults = makeDefaults()
        let pref = LiveTonePreference(defaults: defaults)
        pref.isOptedIn = true
        pref.allowedHostCategories = [.messaging]
        XCTAssertTrue(pref.masterEnabled)

        pref.refreshRemoteDirective(fromCoachFlags: [LiveTonePreference.disableFlag])
        let freshReader = LiveTonePreference(defaults: defaults)
        XCTAssertTrue(freshReader.isRemoteDisabled)
        XCTAssertFalse(freshReader.masterEnabled)
    }

    func testRemoteDirectiveRoundTripsThroughCodableWithSchema() throws {
        let data = try JSONEncoder().encode(LiveToneRemoteDirective(disabled: true, reasonCode: "rollback"))
        let decoded = try JSONDecoder().decode(LiveToneRemoteDirective.self, from: data)
        XCTAssertTrue(decoded.isDisabled)
        XCTAssertEqual(decoded.reasonCode, "rollback")
        XCTAssertEqual(decoded.schema, LiveToneRemoteDirective.currentSchema)
    }

    // MARK: 3 — Field exclusions

    func testCleanMessagingDraftIsEligible() {
        XCTAssertTrue(decision(eligibleBase()).isEligible)
    }

    func testSecureFieldIsSuppressed() {
        var context = eligibleBase()
        context.isSecureTextEntry = true
        XCTAssertEqual(decision(context), .ineligible(.secureField))
    }

    func testExcludedKeyboardTypesAreSuppressed() {
        let excluded: [LiveToneKeyboardType] = [
            .emailAddress, .url, .numberPad, .decimalPad, .phonePad,
            .namePhonePad, .asciiCapableNumberPad, .numbersAndPunctuation,
        ]
        for keyboardType in excluded {
            var context = eligibleBase()
            context.keyboardType = keyboardType
            XCTAssertEqual(decision(context), .ineligible(.excludedKeyboardType(keyboardType)),
                           "\(keyboardType) should be excluded")
        }
    }

    func testTextKeyboardTypesRemainEligible() {
        for keyboardType in [LiveToneKeyboardType.default, .asciiCapable, .twitter, .webSearch] {
            var context = eligibleBase()
            context.keyboardType = keyboardType
            XCTAssertTrue(decision(context).isEligible, "\(keyboardType) should remain eligible")
        }
    }

    func testUnknownAndDisallowedHostCategoriesAreSuppressed() {
        var unknown = eligibleBase()
        unknown.hostCategory = nil
        XCTAssertEqual(decision(unknown), .ineligible(.unknownHostCategory))

        var disallowed = eligibleBase()
        disallowed.hostCategory = .email
        XCTAssertEqual(decision(disallowed), .ineligible(.hostCategoryNotAllowed(.email)))
    }

    func testKeyboardTypeMirrorMapsRawUIKeyboardTypeValues() {
        XCTAssertEqual(LiveToneKeyboardType(uiKeyboardTypeRawValue: 7), .emailAddress)
        XCTAssertEqual(LiveToneKeyboardType(uiKeyboardTypeRawValue: nil), .default)
        XCTAssertEqual(LiveToneKeyboardType(uiKeyboardTypeRawValue: 999), .default)
    }

    func testBulkInsertionIsSuppressed() {
        var context = eligibleBase()
        context.lastInsertionWasBulk = true
        XCTAssertEqual(decision(context), .ineligible(.bulkInsertion))
    }

    func testSensitiveNumericDraftsAreSuppressed() {
        for draft in ["1234", "492013", "4111 1111 1111 1111", "4111-1111-1111-1111",
                      "123-45-6789", "OTP: 492013", "code 8461 92"] {
            var context = eligibleBase()
            context.before = draft
            context.after = ""
            XCTAssertEqual(decision(context), .ineligible(.sensitiveNumericDraft),
                           "should suppress: \(draft)")
        }
    }

    func testBenignDraftsWithNumbersStayEligible() {
        for draft in ["Hey, are we still on for tonight?", "See you at 3pm",
                      "Room 12 works for me", "Let's meet at 5:30 or 6 tomorrow"] {
            var context = eligibleBase()
            context.before = draft
            context.after = ""
            XCTAssertTrue(decision(context).isEligible, "should stay eligible: \(draft)")
        }
    }

    func testStackedExclusionsNeverResolveEligible() {
        var context = eligibleBase()
        context.isSecureTextEntry = true
        context.keyboardType = .numberPad
        context.hostCategory = nil
        context.before = "492013"
        XCTAssertFalse(decision(context).isEligible)
    }

    // MARK: 6 — Static source guards (no fingerprinting / networking / timers)

    func testPrivacyLaneSourcesHaveNoNetworkingFingerprintingOrTimers() throws {
        let forbidden = [
            "URLSession", "URLRequest", "dataTask", "URLConnection",
            "import Network", "NWConnection", "NWPathMonitor",
            "Timer", "scheduledTimer", "asyncAfter", "DispatchSource",
            "CADisplayLink", "RunLoop",
            "bundleIdentifier", "Bundle.main", "hostBundleID",
            "openURL", "canOpenURL", "UIPasteboard", "generalPasteboard",
            "MobileGestalt", "sysctl", "proc_", "import UIKit",
        ]
        // Resolve the two sources relative to this test file so the guard runs
        // regardless of the checkout location.
        let sharedDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // apps/ios/
            .appendingPathComponent("Shared")
        for name in ["LiveToneEligibility.swift", "LiveTonePrivacy.swift"] {
            let url = sharedDir.appendingPathComponent(name)
            let text = try String(contentsOf: url, encoding: .utf8)
            for token in forbidden {
                XCTAssertFalse(text.contains(token), "\(name) must not reference '\(token)'")
            }
        }
    }
}
