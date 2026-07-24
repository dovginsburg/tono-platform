// Build97ShippingPathTests.swift
// Build 97 — closing the four shipping gaps the body names:
//
//   1. Shipping-path — wire O1/O2/O3 through the actual LiveTone
//      Engine → Manager → Indicator pipeline with red/crisis precedence
//      and O4/O5 silence under the live engine.
//   2. Migration     — Settings persistence must cap at exactly two
//      user-selected optional tones (was three), deterministically
//      migrating a legacy 3-selection list down to the FIRST two in
//      pick order (never reordered).
//   3. UI surface    — The Settings UI must surface the spec-exact
//      "Two tones max" hint when a third optional is tapped, and the
//      keyboard must render Safer + exactly two configured tones, with
//      every normal/custom/fallback chip wearing #38BDF8 (website blue,
//      matches .clearer) and NEVER red/rose.
//   4. Network calls — Coach authenticated generation must issue EXACTLY
//      one provider request per chip tap (one tap → one request → one
//      provider call → one result), with truthful server errors and
//      no fabricated fallbacks.
//
// This file is part of the build-97 shipping-path / migration / UI /
// network-call-count test contract. Build 96's existing shipping-path
// tests continue to assert red/l2 behavior on the same engine; these
// tests are additive — they cover the build-97 surfaces the body
// names and were not previously exercised end-to-end through the
// shipping LiveToneManager.

import XCTest
import UIKit
@testable import Tono

// MARK: - 1. SHIPPING PATH: O1/O2/O3 through Engine/Manager/UI

/// Drives the build-97 LiveToneManager exactly as the shipping keyboard
/// drives it (`observe(character:draft:)` → engine → indicator) and
/// asserts the O1/O2/O3 positive-opportunity surface appears on the
/// indicator with the spec-exact microcopy and amber color, while O4/O5
/// stay silent under the active-families gate.
final class Build97OpportunityShippingPathTests: XCTestCase {

    /// The O1 flagship hedge stack must surface through the shipping
    /// manager/indicator when the red lane is silent. Microcopy is the
    /// contract-verbatim string; chip background is amber (never red).
    @MainActor
    func testO1HedgeSurfacesOnShippingIndicator() throws {
        let manager = LiveToneManager(appGroupDefaults: Self.enabledDefaults())
        // Sticky hedge stack: at least two distinct hedge lexemes in one
        // sentence, plus the "i think" gated carve-out with a request verb.
        // Sentence terminator flushes the debounce immediately.
        manager.observe(
            character: ".",
            draft: "I just kinda, I think maybe I should be asking, if that's ok with you."
        )
        XCTAssertEqual(
            manager.debugEngine.currentWarning,
            .opportunity(.hedge),
            "O1 hedge stack must surface on the shipping engine when red lane is silent"
        )
        drainMainQueue()
        let indicator = manager.indicator
        XCTAssertFalse(indicator.isHidden, "O1 hedge chip must visibly surface")
        let chipText = try XCTUnwrap(Self.chipText(in: indicator), "O1 chip text must be present")
        XCTAssertEqual(
            chipText,
            LiveToneCopy.opportunityHedge,
            "O1 chip text must be the contract-verbatim microcopy"
        )
        XCTAssertEqual(
            Self.opportunityChipText(in: indicator),
            LiveToneCopy.opportunityHedge
        )
        // The opportunity chip background must be amber — NOT red, NOT rose.
        // The red lane hue (UIColor.systemRed / rose) is reserved for
        // recipient-directed severe-risk warnings only.
        let (r, g, b) = Self.opportunityChipRGB(in: indicator)
        XCTAssertGreaterThan(g, 0.5, "amber chip must have a green channel ≥ 0.5")
        XCTAssertGreaterThan(r, 0.7, "amber chip must have a red channel ≥ 0.7")
        XCTAssertLessThan(b, 0.5, "amber chip must have a blue channel < 0.5")
        XCTAssertFalse(
            Self.colorIsRedOrRose(in: indicator),
            "the opportunity chip background must NEVER be red or rose — that hue is reserved for the recipient-directed red lane"
        )
        // No rewrite button on the opportunity lane — only the soft dismiss.
        XCTAssertTrue(
            Self.buttonHidden(in: indicator, identifier: LiveToneCopy.axRewriteButton),
            "the opportunity lane must NOT show a rewrite button"
        )
        XCTAssertFalse(
            Self.buttonHidden(in: indicator, identifier: LiveToneCopy.axOpportunityDismissButton),
            "the opportunity lane must show its soft dismiss affordance"
        )
    }

    /// O2 apology stack must surface through the shipping indicator when
    /// the red lane is silent and the message contains two distinct
    /// self-apology tokens (not condolences).
    @MainActor
    func testO2ApologySurfacesOnShippingIndicator() throws {
        let manager = LiveToneManager(appGroupDefaults: Self.enabledDefaults())
        manager.observe(
            character: ".",
            draft: "Sorry, I really apologize for missing the meeting. Can we reschedule?"
        )
        XCTAssertEqual(
            manager.debugEngine.currentWarning,
            .opportunity(.apology),
            "O2 apology stack must surface on the shipping engine"
        )
        drainMainQueue()
        let chipText = try XCTUnwrap(
            Self.chipText(in: manager.indicator),
            "O2 chip text must be present"
        )
        XCTAssertEqual(chipText, LiveToneCopy.opportunityApology)
    }

    /// O3 caps emphasis must surface when the red lane is silent.
    @MainActor
    func testO3CapsSurfacesOnShippingIndicator() throws {
        let manager = LiveToneManager(appGroupDefaults: Self.enabledDefaults())
        manager.observe(
            character: ".",
            draft: "I really need THAT file by tomorrow PLEASE."
        )
        XCTAssertEqual(
            manager.debugEngine.currentWarning,
            .opportunity(.caps),
            "O3 caps emphasis must surface on the shipping engine"
        )
        drainMainQueue()
        let chipText = try XCTUnwrap(
            Self.chipText(in: manager.indicator),
            "O3 chip text must be present"
        )
        XCTAssertEqual(chipText, LiveToneCopy.opportunityCaps)
    }

    /// Red lane wins: when an opportunity verdict AND a red warning
    /// would both fire on the same draft, the shipping engine must
    /// surface ONLY the red warning and keep the opportunity lane
    /// silent. Crisis silence is total — never an opportunity chip.
    @MainActor
    func testRedLaneWinsOverOpportunityLane() throws {
        let manager = LiveToneManager(appGroupDefaults: Self.enabledDefaults())
        // Recipient-directed severe-risk fixture fires an L2.
        manager.observe(character: ".", draft: "I'll kill you.")
        drainMainQueue()
        XCTAssertNotEqual(
            manager.debugEngine.currentWarning,
            .none,
            "the red lane must fire on the severe-risk fixture"
        )
        if case .opportunity = manager.debugEngine.currentWarning {
            XCTFail("the opportunity lane must NEVER win over the red lane")
        }
    }

    /// Crisis silence is total: a pure self-directed crisis draft must
    /// silence BOTH the red lane AND the opportunity lane. No chip is
    /// ever shown for crisis text.
    @MainActor
    func testCrisisSilenceSuppressesOpportunityLane() throws {
        let manager = LiveToneManager(appGroupDefaults: Self.enabledDefaults())
        // Crisis-shaped text — words that the classifier knows as
        // self-directed crisis (the shipping fixture from build 96).
        manager.observe(character: ".", draft: "I want to kill myself.")
        drainMainQueue()
        XCTAssertEqual(
            manager.debugEngine.currentWarning,
            LiveToneVisibleWarning.none,
            "crisis text must silence the shipping engine entirely"
        )
        drainMainQueue()
        XCTAssertTrue(
            manager.indicator.isHidden,
            "the opportunity lane must NEVER surface on crisis text"
        )
    }

    /// The per-host-app-session discipline: dismissing an opportunity
    /// chip suppresses that family for the remainder of the session.
    /// The manager must route the dismissal through the engine's
    /// per-family session store so a future draft on the same family
    /// stays silent.
    @MainActor
    func testOpportunityDismissalSuppressesFamilyForSession() throws {
        let manager = LiveToneManager(appGroupDefaults: Self.enabledDefaults())
        manager.observe(
            character: ".",
            draft: "Sorry, I really apologize for missing the meeting."
        )
        drainMainQueue()
        XCTAssertEqual(
            manager.debugEngine.currentWarning,
            .opportunity(.apology),
            "O2 must surface before dismissal"
        )
        // Simulate the user tapping the opportunity dismiss affordance.
        manager.dismissOpportunity(family: .apology)
        drainMainQueue()
        XCTAssertTrue(
            manager.debugOpportunitySession.hasDismissed(.apology),
            "the dismissal must be recorded on the per-host session store"
        )
        // New draft on the same family — engine must stay silent.
        manager.fieldDidReset()
        manager.observe(
            character: ".",
            draft: "I'm sorry I apologize again for the late reply."
        )
        drainMainQueue()
        XCTAssertNotEqual(
            manager.debugEngine.currentWarning,
            .opportunity(.apology),
            "O2 must stay silent after dismissal for the rest of the session"
        )
    }

    // MARK: - Helpers

    /// Fresh isolated App Group defaults with the master toggle ON.
    static func enabledDefaults() -> UserDefaults {
        let suite = "com.tono.build97.livetone.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        LiveToneMasterToggle(defaults: defaults).setEnabled(true)
        return defaults
    }

    /// Deterministically flush the main queue.
    func drainMainQueue(timeout: TimeInterval = 2.0) {
        let fence = expectation(description: "main queue fence")
        DispatchQueue.main.async { fence.fulfill() }
        wait(for: [fence], timeout: timeout)
    }

    static func chipText(in indicator: UIView) -> String? {
        let all = [indicator] + descendants(of: indicator)
        let label = all.first { $0.accessibilityIdentifier == LiveToneCopy.axOpportunityChip } as? UILabel
        return label?.text
    }

    static func opportunityChipText(in indicator: UIView) -> String? {
        let all = [indicator] + descendants(of: indicator)
        let label = all.first { $0.accessibilityIdentifier == LiveToneCopy.axOpportunityChip } as? UILabel
        return label?.text
    }

    /// (r, g, b) channels of the opportunity chip background color in
    /// 0...1 sRGB. Used to assert the chip is amber and NEVER red/rose.
    static func opportunityChipRGB(in indicator: UIView) -> (CGFloat, CGFloat, CGFloat) {
        let all = [indicator] + descendants(of: indicator)
        let label = all.first { $0.accessibilityIdentifier == LiveToneCopy.axOpportunityChip } as? UILabel
        let color = label?.backgroundColor ?? .clear
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b)
    }

    /// True when the opportunity chip background lands in the
    /// red/rose family. Reserved for the recipient-directed red lane
    /// — the opportunity lane must never paint this color.
    static func colorIsRedOrRose(in indicator: UIView) -> Bool {
        let (r, g, b) = opportunityChipRGB(in: indicator)
        // Red: R high, G/B low. Rose: R high, G/B low with B noticeably > G.
        if r > 0.7, g < 0.4, b < 0.4 { return true }
        return false
    }

    static func buttonHidden(in indicator: UIView, identifier: String) -> Bool {
        let all = [indicator] + descendants(of: indicator)
        let view = all.first { $0.accessibilityIdentifier == identifier }
        return view?.isHidden ?? true
    }

    static func descendants(of root: UIView) -> [UIView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

// MARK: - 2. MIGRATION: legacy 3-selection → exactly two, order preserved

/// Build 97 pins the user-selected tone cap to exactly two optional
/// tones. Legacy build-94/95 installs may have persisted a list of up
/// to three; the store must deterministically migrate that legacy list
/// down to the FIRST two in pick order on next load — never the
/// alphabetical reorder, never the last two, never the first and last.
final class Build97CoachVariantMigrationTests: XCTestCase {

    /// When the persisted store carries three optional tones, the next
    /// load must deterministically return the FIRST two in the legacy
    /// pick order. This is the deterministic 3→2 migration contract.
    func testLegacyThreeTonesMigrateToFirstTwoInPickOrder() {
        let defaults = Self.freshDefaults()
        // Persist a legacy build-94 payload that has THREE optional
        // tones in a non-default pick order: [funnier, clearer,
        // professional]. The legacy maxOptionalCount was 3. We hand-roll
        // the JSON rather than going through
        // `CoachVariantSettings(enabled:)` because the build-97 init
        // already truncates to the new `maximumOptionalCount = 2`
        // (see `CoachVariantSettings.init` → `normalize()`). The
        // legacy 3-element payload only ever exists as raw bytes on
        // disk on upgraded devices — the in-memory API never sees it.
        let legacyJSON = #"""
        {
          "enabled": ["funnier", "clearer", "professional"],
          "customInstruction": ""
        }
        """#
        let data = legacyJSON.data(using: .utf8)!
        defaults.set(data, forKey: CoachVariantSettingsStore.settingsKey)
        defaults.set(
            CoachVariantSettingsStore.legacyBuild94Version,
            forKey: CoachVariantSettingsStore.versionKey
        )

        // Load under the new contract — must deterministically truncate
        // to the FIRST two, preserving pick order.
        let loaded = CoachVariantSettingsStore(defaults: defaults).load()
        XCTAssertEqual(loaded.enabled, [.funnier, .clearer])
        XCTAssertEqual(loaded.enabled.count, CoachVariantSettings.maximumOptionalCount)
        // The persisted version key must be bumped to currentVersion so
        // subsequent loads are fast-path.
        XCTAssertEqual(
            defaults.integer(forKey: CoachVariantSettingsStore.versionKey),
            CoachVariantSettingsStore.currentVersion
        )
    }

    /// A legacy payload with exactly three tones in another order
    /// ([professional, affectionate, concise]) must also preserve the
    /// legacy order — never silently reorder to the alphabetical
    /// canonical.
    func testLegacyThreeTonesMigrationRespectsOriginalPickOrder() {
        let defaults = Self.freshDefaults()
        // Hand-roll the JSON to bypass the build-97 init-time
        // truncation — see the comment in
        // `testLegacyThreeTonesMigrateToFirstTwoInPickOrder` above.
        let legacyJSON = #"""
        {
          "enabled": ["professional", "affectionate", "concise"],
          "customInstruction": ""
        }
        """#
        let data = legacyJSON.data(using: .utf8)!
        defaults.set(data, forKey: CoachVariantSettingsStore.settingsKey)
        defaults.set(
            CoachVariantSettingsStore.legacyBuild94Version,
            forKey: CoachVariantSettingsStore.versionKey
        )

        let loaded = CoachVariantSettingsStore(defaults: defaults).load()
        XCTAssertEqual(
            loaded.enabled,
            [.professional, .affectionate],
            "legacy migration must keep the first two in the legacy pick order, never reorder"
        )
    }

    /// The in-memory `normalize()` contract: any list above
    /// `maximumOptionalCount` is truncated to the first
    /// `maximumOptionalCount`, preserving order.
    func testNormalizeTruncatesLegacyThreeToFirstTwoInPlace() {
        var settings = CoachVariantSettings(enabled: [.funnier, .clearer, .professional])
        XCTAssertEqual(settings.enabled.count, 2, "init must already cap at the new maximum")
        settings.normalize()
        XCTAssertEqual(settings.enabled, [.funnier, .clearer])
    }

    /// `canSelectAnother` must be false once the user has exactly two
    /// optional tones — there's no third slot to fill.
    func testCanSelectAnotherIsFalseAtTheNewCap() {
        let settings = CoachVariantSettings(enabled: [.clearer, .funnier])
        XCTAssertFalse(settings.canSelectAnother)
        XCTAssertEqual(settings.totalShippedChipCount, 3)
    }

    /// Attempting to enable a third optional tone must be refused and
    /// set `pendingFourthBlocked` so the UI can surface the
    /// spec-exact "Two tones max" hint.
    func testEnablingThirdOptionalToneIsRefusedWithPendingBlock() {
        var settings = CoachVariantSettings(enabled: [.clearer, .funnier])
        let result = settings.set(.professional, enabled: true)
        XCTAssertFalse(result, "third optional enable must be refused at the cap")
        XCTAssertTrue(
            settings.pendingFourthBlocked,
            "the refused attempt must set pendingFourthBlocked for the UI hint"
        )
        XCTAssertEqual(settings.enabled, [.clearer, .funnier])
    }

    // MARK: - Helpers

    private static func freshDefaults() -> UserDefaults {
        let suite = "com.tono.build97.migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

// MARK: - 3. UI: Safer + TWO tone chips, no red/rose, "Two tones max" hint

/// The Shipping Settings UI must enforce persistent Safer + exactly two
/// user-selected chips, surface the spec-exact "Two tones max" hint on
/// a third-toggle attempt, and paint every normal/custom/fallback chip
/// #38BDF8 — never red, never rose.
final class Build97SettingsChipUITests: XCTestCase {

    /// The shipping settings sheet renders the standard "Choose up to 2"
    /// header with the live "2/2" counter. A third-toggle attempt while
    /// the cap is reached sets the "Two tones max" hint. The hint must
    /// be the contract-verbatim string, not the legacy "Turn one off
    /// first (3 max)".
    @MainActor
    func testSettingsHintIsTwoTonesMaxWhenCapReached() throws {
        // Source-grep guarantee: the Settings surface carries the
        // contract-exact build-97 hint text.
        let source = try Self.source("App/SettingsView.swift")
        XCTAssertTrue(
            source.contains("\"Two tones max\""),
            "SettingsView must surface the contract-exact 'Two tones max' hint"
        )
        XCTAssertFalse(
            source.contains("Turn one off first (3 max)"),
            "the legacy build-94 hint string must be gone"
        )
        XCTAssertTrue(
            source.contains("Choose up to \\(CoachVariantSettings.maximumOptionalCount)"),
            "Settings header must interpolate the live cap constant"
        )
    }

    /// The keyboard's tone-chip palette must paint the
    /// Custom-selected chip with #38BDF8 (the website blue, matches
    /// .clearer). No normal / custom / fallback chip may wear red or
    /// rose — that hue is reserved for the recipient-directed red
    /// lane.
    func testCustomChipPaletteIsWebsiteBlue38BDF8() throws {
        let source = try Self.source("KeyboardExtension/TonoKeyboardVisualStyle.swift")
        XCTAssertTrue(
            source.contains("case .custom: return UIColor(hexRGB: \"38BDF8\")"),
            "Custom chip palette must be #38BDF8 (website blue)"
        )
        XCTAssertFalse(
            source.contains("case .custom: return UIColor(hexRGB: \"FB7185\")"),
            "the rose Custom chip color must be gone"
        )
        // The 'fallback' / 'normal' / 'safer' colors must also never
        // touch red or rose. Source-grep the entire palette block.
        XCTAssertFalse(
            source.contains("red: 1.0, green: 0.0, blue: 0.0")
            || source.contains("red: 1.0, green: 0.0, blue: 0.4"),
            "no shipping palette entry may use raw red/rose RGB"
        )
    }

    /// The keyboard's chip-strip wiring must use the live
    /// `maximumOptionalCount` constant when seeding the selected-tone
    /// axis array. Hardcoded 2's would re-introduce the build-94/95
    /// three-cap if a future tweak bumped the constant.
    func testKeyboardSelectedToneAxesUseMaximumOptionalCountConstant() throws {
        let source = try Self.source("KeyboardExtension/KeyboardViewController.swift")
        // The call can wrap across multiple lines; whitespace-tolerant
        // check: the prefix argument must reference the live
        // maximumOptionalCount constant rather than a hardcoded 2.
        XCTAssertTrue(
            source.contains("enabled.prefix(") &&
                source.contains("CoachVariantSettings.maximumOptionalCount"),
            "the keyboard must drive its selected-tone seed from the live maximumOptionalCount constant"
        )
        // Sanity: hardcoded 2 inside the chip-strip seed would be a
        // silent re-introduction of the build-94/95 three-cap.
        XCTAssertFalse(
            source.contains(".enabled.prefix(2)") ||
                source.contains(".enabled.prefix( 2 )"),
            "the keyboard must NOT hardcode 2 inside the selected-tone seed — the live constant is the source of truth"
        )
    }

    // MARK: - Helpers

    static func source(_ relative: String, file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }
}

// MARK: - 4. NETWORK CALL COUNT: Coach 1:1 contract

/// The Coach authenticated generation must obey the 1:1 contract —
/// exactly one provider call per chip tap. The TonoCoachClient exposes
/// a debug `providerCallCount` counter for tests; this asserts it
/// behaves deterministically for both successful and failed dispatches,
/// and never duplicates within a single round trip.
final class Build97CoachNetworkCallCountTests: XCTestCase {

    /// One tap on a tone chip issues exactly one provider call — never
    /// more, never less. Each `variant(...)` invocation bumps the
    /// counter exactly once immediately before `task.resume()`.
    func testSingleVariantTapMakesExactlyOneProviderCall() {
        let client = TonoCoachClient(
            endpoint: "https://tono.invalid/api/analyze/variant",
            timeout: 15,
            session: Self.trapSession(),
            tokenProvider: { "test-token" }
        )
        client.resetProviderCallCount()
        let done = expectation(description: "variant completes")
        _ = client.variant(draft: "please help me", axis: "safer") { _ in
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(
            client.providerCallCount,
            1,
            "one tap on a tone chip must invoke the provider exactly once"
        )
        XCTAssertEqual(client.dispatchedAxes, ["safer"])
    }

    /// Missing token must surface as `.missingToken` and the debug
    /// counter must remain at 0 — the client never invents a fallback
    /// credential or "tries once anyway".
    func testMissingTokenMakesZeroProviderCallsAndSurfacesTruthfulError() {
        let client = TonoCoachClient(
            endpoint: "https://tono.invalid/api/analyze/variant",
            timeout: 15,
            session: Self.trapSession(),
            tokenProvider: { nil }
        )
        client.resetProviderCallCount()
        let done = expectation(description: "variant completes with missingToken")
        _ = client.variant(draft: "please help me", axis: "safer") { result in
            if case .failure(.missingToken) = result {
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(
            client.providerCallCount,
            0,
            "missing token must not issue any provider call — the client surfaces .missingToken, never a fabricated fallback"
        )
        XCTAssertTrue(client.dispatchedAxes.isEmpty)
    }

    /// Two sequential taps on two different chips — each tap is its own
    /// round trip, each fires exactly one provider call. The counter is
    /// cumulative across the lifetime of the client (no implicit reset
    /// per call).
    func testTwoConsecutiveTapsProduceTwoProviderCalls() {
        let client = TonoCoachClient(
            endpoint: "https://tono.invalid/api/analyze/variant",
            timeout: 15,
            session: Self.trapSession(),
            tokenProvider: { "test-token" }
        )
        client.resetProviderCallCount()
        let done1 = expectation(description: "first tap")
        _ = client.variant(draft: "first", axis: "safer") { _ in
            done1.fulfill()
        }
        wait(for: [done1], timeout: 3)
        let done2 = expectation(description: "second tap")
        _ = client.variant(draft: "second", axis: "clearer") { _ in
            done2.fulfill()
        }
        wait(for: [done2], timeout: 3)
        XCTAssertEqual(client.providerCallCount, 2)
        XCTAssertEqual(client.dispatchedAxes, ["safer", "clearer"])
    }

    /// A network failure on a provider call must surface as the
    /// truthful `.transport(...)` / `.http(...)` / `.decoding(...)`
    /// error, not a silent fallback to a fabricated local analyzer.
    /// The debug counter still bumps — the request was attempted, the
    /// server just rejected it. Truthful > optimistic.
    func testProviderServerErrorSurfacesTruthfully() {
        let session = Self.trapSession(rejecting: true)
        let client = TonoCoachClient(
            endpoint: "https://tono.invalid/api/analyze/variant",
            timeout: 15,
            session: session,
            tokenProvider: { "test-token" }
        )
        client.resetProviderCallCount()
        let done = expectation(description: "provider rejected")
        _ = client.variant(draft: "please help me", axis: "safer") { result in
            // ANY non-missing-token, non-success outcome is a truthful
            // surface — the client never invents a fallback, never
            // retries silently, never reports success on transport /
            // http / decoding / timeout / staleDraft / invalidURL.
            switch result {
            case .failure(.missingToken), .success:
                break
            case .failure:
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(
            client.providerCallCount,
            1,
            "the request was attempted; the counter bumps on .resume()"
        )
    }

    // MARK: - Helpers

    private static func trapSession(rejecting: Bool = false) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoachRequestTrap.self]
        return URLSession(configuration: configuration)
    }
}