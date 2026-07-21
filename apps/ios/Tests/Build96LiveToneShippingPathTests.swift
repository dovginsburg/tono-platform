// Build96LiveToneShippingPathTests.swift
// Build 96 — Live Tone shipping-runtime integration.
//
// The Live Tone integration that SHIPS in the keyboard extension was gated
// behind `#if !TONO_BUILD92_HOSTSESSION`. That flag is (correctly) defined
// on the TonoTests target to activate the host/session cross-identity
// suite — so every test build compiled a Live-Tone-stripped keyboard and
// the shipping integration had zero coverage. Build 96 decouples the two:
// Live Tone is wired unconditionally, so the test build and the shipping
// build run the identical path.
//
// These tests prove, in the shipping path, that a known major-risk fixture
// visibly fires the passive indicator and a harmless control stays silent.

import XCTest
import UIKit
@testable import Tono

final class Build96LiveToneShippingPathTests: XCTestCase {

    // MARK: - RED → GREEN: the wiring must not be gated by the test flag

    func testLiveToneWiringIsNotGatedByHostSessionTestFlag() throws {
        let src = try Build96CoachAuthTests.source("KeyboardExtension/KeyboardViewController.swift")
        XCTAssertTrue(src.contains("installLiveTone()"), "the shipping keyboard must wire Live Tone")
        XCTAssertTrue(
            src.contains("liveToneDidMutate(context: effectiveContext)"),
            "the shipping keyboard must forward mutations to Live Tone"
        )
        XCTAssertFalse(
            src.contains("#if !TONO_BUILD92_HOSTSESSION\n        installLiveTone()"),
            "Live Tone install must not be gated by TONO_BUILD92_HOSTSESSION (that flag is defined on the test target and stripped Live Tone from every test build)"
        )
        XCTAssertFalse(
            src.contains("#if !TONO_BUILD92_HOSTSESSION\n        liveToneDidMutate(context: effectiveContext)"),
            "the Live Tone observer must not be gated by the host/session test flag"
        )
    }

    // MARK: - GREEN: the manager shipping glue fires and stays silent

    /// The `LiveToneManager` is the shipping-runtime glue the keyboard view
    /// controller installs. Driven exactly as `liveToneDidMutate` drives it,
    /// a known major-risk fixture must fire the shipping engine and visibly
    /// surface on the passive indicator, and a harmless control must leave it
    /// silent.
    func testManagerFiresOnMajorRiskAndStaysSilentOnControl() throws {
        let manager = LiveToneManager(appGroupDefaults: Self.enabledDefaults())

        // Major-risk fixture (Class B). The sentence terminator flushes the
        // debounce immediately. `currentWarning` is a `queue.sync` read that
        // drains the engine's evaluation deterministically.
        manager.observe(character: ".", draft: "I'll kill you.")
        XCTAssertEqual(
            manager.debugEngine.currentWarning, .l2(.classBHyperbolicViolence),
            "a known major-risk fixture must fire an L2 warning in the shipping engine"
        )
        drainMainQueue()
        XCTAssertFalse(
            manager.indicator.isHidden,
            "the fired warning must visibly surface on the shipping indicator"
        )
        XCTAssertEqual(
            Self.bannerText(in: manager.indicator),
            LiveToneCopy.l2Banner,
            "the fired indicator must carry the contract L2 banner copy"
        )

        // Harmless control on a fresh field must stay silent.
        manager.fieldDidReset()
        manager.observe(character: ".", draft: "Let's grab lunch tomorrow.")
        XCTAssertEqual(
            manager.debugEngine.currentWarning, LiveToneVisibleWarning.none,
            "a harmless control must leave the shipping engine silent"
        )
        drainMainQueue()
        XCTAssertTrue(
            manager.indicator.isHidden,
            "a harmless control must stay silent on the shipping indicator"
        )
    }

    // MARK: - GREEN: the installed controller drives the same path

    /// The keyboard view controller installs Live Tone unconditionally and
    /// forwards mutations to it. Driving the real observer seam, a major-risk
    /// fixture fires and visibly surfaces on the controller's own indicator;
    /// a harmless control stays silent. Before build 96 the wiring was
    /// compiled out of the test build entirely, so `integrationDriveLiveTone`
    /// returned nil.
    @MainActor
    func testInstalledControllerFiresOnMajorRiskAndStaysSilentOnControl() throws {
        // The controller's manager reads the shared App Group suite; make the
        // master toggle explicitly ON against pollution from other tests.
        if let shared = UserDefaults(suiteName: LiveToneKeys.appGroupSuite) {
            LiveToneMasterToggle(defaults: shared).setEnabled(true)
        }

        let controller = KeyboardViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 320)
        controller.view.layoutIfNeeded()

        // Major-risk fixture, through the real shipping observer path.
        let manager = try XCTUnwrap(
            controller.integrationDriveLiveTone(context: "I'll kill you."),
            "the shipping keyboard must install a Live Tone manager (was stripped from the test build before build 96)"
        )
        XCTAssertEqual(
            manager.debugEngine.currentWarning, .l2(.classBHyperbolicViolence),
            "the controller's shipping path must fire an L2 warning on a major-risk fixture"
        )
        drainMainQueue()
        XCTAssertFalse(
            manager.indicator.isHidden,
            "the fired warning must visibly surface on the keyboard's own indicator"
        )
        XCTAssertEqual(Self.bannerText(in: manager.indicator), LiveToneCopy.l2Banner)

        // Harmless control on a fresh field stays silent.
        manager.fieldDidReset()
        _ = controller.integrationDriveLiveTone(context: "Let's grab lunch tomorrow.")
        XCTAssertEqual(
            manager.debugEngine.currentWarning, LiveToneVisibleWarning.none,
            "a harmless control must leave the controller's shipping path silent"
        )
        drainMainQueue()
        XCTAssertTrue(manager.indicator.isHidden, "the control must leave the indicator silent")
    }

    // MARK: - Helpers

    /// Fresh isolated App Group defaults with the master toggle explicitly ON.
    static func enabledDefaults() -> UserDefaults {
        let suite = "com.tono.build96.livetone.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        LiveToneMasterToggle(defaults: defaults).setEnabled(true)
        return defaults
    }

    /// Deterministically flush the main queue: the engine publishes indicator
    /// updates via `DispatchQueue.main.async`, so a FIFO fence enqueued after
    /// the (already-drained) evaluation guarantees the indicator update has
    /// run once `wait(for:)` returns.
    func drainMainQueue(timeout: TimeInterval = 2.0) {
        let fence = expectation(description: "main queue fence")
        DispatchQueue.main.async { fence.fulfill() }
        wait(for: [fence], timeout: timeout)
    }

    static func bannerText(in indicator: UIView) -> String? {
        let all = [indicator] + descendants(of: indicator)
        let banner = all.first { $0.accessibilityIdentifier == LiveToneCopy.axBanner } as? UILabel
        return banner?.text
    }

    static func descendants(of root: UIView) -> [UIView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
