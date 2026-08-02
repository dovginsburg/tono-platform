// Build118AppleIntelligenceTests.swift
// Apple Intelligence readiness — the XCTest half of the contract.
//
// These assertions mirror the runnable `swiftc` verifiers
// (Scripts/verify_apple_intelligence_routing.swift,
//  Scripts/verify_tone_variant_config.swift) inside the Xcode test target, so
// the provider abstraction, the PCC seam, the tone-variant intent policy and the
// App-Intent navigation signal are exercised by `xcodebuild test` as well.
//
// Everything here is pure: no device, no FoundationModels, no PCC runtime, no
// network. The types under test are all compiled into the TonoTests target.

import XCTest

final class Build118AppleIntelligenceTests: XCTestCase {

    private let router = RewriteProviderRouter() // default spike: [.funnier]

    private func decide(
        _ axis: String,
        kill: Bool = true,
        pref: LocalRewritePreference = .unset,
        onDevice: LocalRewriteAvailability = .available,
        pcc: PCCAvailability = .unknown,
        saferGate: Bool = false,
        offline: Bool = false
    ) -> RewriteRoutingDecision {
        router.decide(
            requestedAxis: axis,
            remoteKillSwitchAllows: kill,
            preference: pref,
            onDeviceAvailability: onDevice,
            pccAvailability: pcc,
            saferCorpusGateOpen: saferGate,
            connectivityKnownAbsent: offline
        )
    }

    // MARK: Provider privacy properties

    func testProviderLeavesDeviceIsPrivacyCorrect() {
        XCTAssertFalse(RewriteProviderKind.appleOnDevice.leavesDevice)
        // PCC is private, but still off-device.
        XCTAssertTrue(RewriteProviderKind.applePrivateCloudCompute.leavesDevice)
        XCTAssertTrue(RewriteProviderKind.tonoBackend.leavesDevice)
        XCTAssertTrue(RewriteProviderKind.appleOnDevice.isAppleIntelligence)
        XCTAssertTrue(RewriteProviderKind.applePrivateCloudCompute.isAppleIntelligence)
        XCTAssertFalse(RewriteProviderKind.tonoBackend.isAppleIntelligence)
    }

    func testRoutePlanCannotEncodeFanOutOrDuplicates() {
        let plan = RewriteRoutePlan(primary: .appleOnDevice,
                                    fallbacks: [.appleOnDevice, .tonoBackend, .tonoBackend])
        XCTAssertEqual(plan.ordered, [.appleOnDevice, .tonoBackend])
    }

    // MARK: PCC availability is fail-closed

    func testPCCAvailabilityIsFailClosed() {
        for a in PCCAvailability.allCases where a != .available {
            XCTAssertFalse(a.isAvailable, "\(a) must not be available")
        }
        XCTAssertTrue(PCCAvailability.available.isAvailable)
        XCTAssertEqual(DefaultPCCAvailabilityProbe().probe(), .unsupportedOS,
                       "the default PCC probe fails closed on Xcode 26.5")
        XCTAssertFalse(PCCEntitlement.isGrantedInThisBuild)
    }

    // MARK: Safer stays on the backend unless the corpus gate is open

    func testSaferStaysOnBackendUnlessGateOpen() {
        let closed = decide("safer", onDevice: .available, saferGate: false)
        XCTAssertEqual(closed.primaryProvider, .tonoBackend)
        XCTAssertFalse(closed.orderedProviders.contains(.appleOnDevice))
        XCTAssertFalse(closed.orderedProviders.contains(.applePrivateCloudCompute))

        let open = decide("safer", onDevice: .available, saferGate: true)
        XCTAssertEqual(open.primaryProvider, .appleOnDevice)
    }

    // MARK: Funnier is the on-device spike

    func testFunnierIsTheOnDeviceSpike() {
        let funnier = decide("funnier", onDevice: .available)
        XCTAssertEqual(funnier.orderedProviders, [.appleOnDevice, .tonoBackend])

        // Warmer is not in the default spike.
        let warmer = decide("warmer", onDevice: .available)
        XCTAssertEqual(warmer.primaryProvider, .tonoBackend)
        XCTAssertFalse(warmer.orderedProviders.contains(.appleOnDevice))
    }

    // MARK: No fan-out / ordering

    func testNoFanOutAndMostPrivateFirst() {
        for axis in ["safer", "warmer", "clearer", "funnier", "custom"] {
            for pcc in PCCAvailability.allCases {
                for onDevice in [LocalRewriteAvailability.available, .deviceNotEligible] {
                    let d = decide(axis, onDevice: onDevice, pcc: pcc, saferGate: true)
                    guard case .route = d else { continue }
                    let ordered = d.orderedProviders
                    XCTAssertEqual(Set(ordered).count, ordered.count, "no dup in \(axis)/\(pcc)/\(onDevice)")
                    XCTAssertFalse(ordered.isEmpty)
                    if let apple = ordered.firstIndex(of: .appleOnDevice) {
                        XCTAssertEqual(apple, 0, "on-device is first for \(axis)/\(pcc)/\(onDevice)")
                    }
                    if let backend = ordered.firstIndex(of: .tonoBackend) {
                        XCTAssertEqual(backend, ordered.count - 1, "backend is last for \(axis)/\(pcc)/\(onDevice)")
                    }
                }
            }
        }
    }

    // MARK: The on-device-only promise forbids PCC and the backend

    func testOnDeviceOnlyForbidsOffDeviceEngines() {
        let ok = decide("funnier", pref: .onlyOnDevice, onDevice: .available)
        XCTAssertEqual(ok.orderedProviders, [.appleOnDevice])

        // PCC 'available' must still be forbidden — it leaves the device.
        let pcc = decide("funnier", pref: .onlyOnDevice, onDevice: .deviceNotEligible, pcc: .available)
        if case .terminal = pcc {} else { XCTFail("on-device-only must be terminal when only off-device remain") }

        let unavailable = decide("funnier", pref: .onlyOnDevice, onDevice: .appleIntelligenceNotEnabled)
        if case .terminal(let reason) = unavailable {
            XCTAssertEqual(reason, .appleIntelligenceNotEnabled)
        } else {
            XCTFail("on-device-only + unavailable model must be terminal")
        }
    }

    // MARK: Fail-closed fallbacks

    func testFailClosedFallbacks() {
        XCTAssertEqual(decide("funnier", kill: false, onDevice: .available).primaryProvider, .tonoBackend)
        XCTAssertEqual(decide("funnier", pref: .off, onDevice: .available).primaryProvider, .tonoBackend)
        XCTAssertEqual(decide("funnier", onDevice: .deviceNotEligible).primaryProvider, .tonoBackend)

        let pccPath = decide("funnier", onDevice: .deviceNotEligible, pcc: .available)
        XCTAssertEqual(pccPath.orderedProviders, [.applePrivateCloudCompute, .tonoBackend])
        for pcc in PCCAvailability.allCases where pcc != .available {
            let d = decide("funnier", onDevice: .deviceNotEligible, pcc: pcc)
            XCTAssertFalse(d.orderedProviders.contains(.applePrivateCloudCompute), "PCC \(pcc) never chosen")
        }
    }

    func testOfflineOnlyOnDeviceCanRun() {
        let funnier = decide("funnier", onDevice: .available, offline: true)
        XCTAssertEqual(funnier.orderedProviders, [.appleOnDevice])
        if case .terminal(let r) = decide("warmer", onDevice: .available, offline: true) {
            XCTAssertEqual(r, .toneNeedsConnection)
        } else { XCTFail("offline + non-spike axis should be terminal") }
    }

    // MARK: Tone-variant configuration intent policy

    func testToneVariantConfigurationPolicy() {
        let base = CoachVariantSettings(enabled: [.clearer, .funnier])

        XCTAssertEqual(ToneVariantConfiguration.apply(enable: false, variantAxis: "safer", to: base).outcome,
                       .saferIsAlwaysOn)

        let oneTone = CoachVariantSettings(enabled: [.clearer])
        let enabled = ToneVariantConfiguration.apply(enable: true, variantAxis: "funnier", to: oneTone)
        XCTAssertEqual(enabled.outcome, .enabled(.funnier))
        XCTAssertTrue(enabled.outcome.didChange)
        XCTAssertTrue(enabled.settings.enabled.contains(.funnier))

        XCTAssertEqual(ToneVariantConfiguration.apply(enable: true, variantAxis: "clearer", to: base).outcome,
                       .alreadyEnabled(.clearer))
        XCTAssertEqual(ToneVariantConfiguration.apply(enable: true, variantAxis: "professional", to: base).outcome,
                       .capReached(max: CoachVariantSettings.maximumOptionalCount))
        XCTAssertEqual(ToneVariantConfiguration.apply(enable: true, variantAxis: "warmer", to: base).outcome,
                       .unknownVariant("warmer"))

        let noCustom = CoachVariantSettings(enabled: [.clearer], customInstruction: "")
        XCTAssertEqual(ToneVariantConfiguration.apply(enable: true, variantAxis: "custom", to: noCustom).outcome,
                       .customNeedsInstruction)
    }

    // MARK: The App-Intent navigation signal (one-shot, read-and-clear)

    func testAppIntentRouteSignalIsOneShot() throws {
        let suite = "test.appIntentRoute.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let signal = AppIntentRouteSignal(defaults: defaults)
        XCTAssertNil(signal.peekPending(), "nothing pending initially")
        signal.request(.keyboardSetup)
        XCTAssertEqual(signal.peekPending(), .keyboardSetup, "peek does not clear")
        XCTAssertEqual(signal.consumePending(), .keyboardSetup, "consume returns the route")
        XCTAssertNil(signal.consumePending(), "consume cleared it — a route presents once")
    }
}
