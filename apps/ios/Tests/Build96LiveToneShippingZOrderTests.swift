// Build96LiveToneShippingZOrderTests.swift
// Build 96 — Live Tone shipping-runtime z-order and visibility regression.
//
// ROOT CAUSE (parent Sherlock diagnosis t_08d08e43): the keyboard's
// `installLiveTone()` adds the indicator to `bodyContainer` once at
// viewDidLoad. `installKeyboardLayout()` is invoked on every layout
// rebuild (rotation, width change, trait change, coach return) and
// always appends a fresh full-edge keyboard stack to the same
// container. Because `addSubview` places the new view last in the
// subview array, every layout rebuild demotes the indicator one slot
// in z-order. The stack covers all four edges of `bodyContainer`, so
// the indicator ends up visually swallowed. This is the physical
// no-show despite classifier/engine tests passing.
//
// FIX (this card t_b4d5cede): after `installKeyboardLayout()` installs
// its full-edge stack, the keyboard view controller brings the Live
// Tone indicator back to the front of `bodyContainer`. This preserves
// the manager-owned indicator contract and adds exactly one line per
// rebuild site.
//
// This file is a red regression. It exercises the SHIPPING keyboard
// path (mutation → manager/engine/classifier → visible indicator),
// not the standalone classifier. It must fail before the fix and pass
// after.

import XCTest
import UIKit
@testable import Tono

@MainActor
final class Build96LiveToneShippingZOrderTests: XCTestCase {

    // MARK: - RED → GREEN: indicator must be topmost after a layout rebuild

    /// When the keyboard is laid out a second time (the same path that
    /// fires on rotation, width change, trait change, coach return, or
    /// any `installKeyboardLayout()` re-entry), the Live Tone indicator
    /// must still be the topmost child of `bodyContainer`. Without the
    /// z-order fix the new full-edge keyboard stack is appended last
    /// and visually covers the indicator; the physical no-show.
    func testIndicatorRemainsTopmostAfterLayoutRebuild() throws {
        if let shared = UserDefaults(suiteName: LiveToneKeys.appGroupSuite) {
            LiveToneMasterToggle(defaults: shared).setEnabled(true)
        }

        let controller = KeyboardViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 320)
        controller.view.layoutIfNeeded()

        let manager = try XCTUnwrap(
            controller.integrationDriveLiveTone(context: ""),
            "the shipping keyboard must install a Live Tone manager"
        )
        let indicator = manager.indicator
        let container = try XCTUnwrap(
            indicator.superview,
            "the indicator must be installed into bodyContainer by installLiveTone()"
        )

        // The act of setting a frame + layoutIfNeeded triggers
        // viewDidLayoutSubviews, which calls installKeyboardLayout()
        // again on the first layout pass — exactly the same code
        // path that fires on rotation and trait change in
        // production. This re-adds the full-edge keyboard stack
        // AFTER the indicator and demotes the indicator in z-order.

        // Trigger a second layout rebuild at a different width. This
        // is the exact same re-entry path that fires on rotation and
        // trait change in production.
        controller.view.frame = CGRect(x: 0, y: 0, width: 844, height: 390)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        // RED ASSERTION: after the rebuild, the indicator must be
        // the topmost child of bodyContainer. Without the fix the
        // new full-edge keyboard stack is appended after the
        // indicator and becomes the topmost subview, occluding the
        // indicator — the physical no-show.
        XCTAssertEqual(
            container.subviews.last, indicator,
            "after a layout rebuild the indicator must be re-promoted to the top of bodyContainer, otherwise the new full-edge keyboard stack occludes the warning"
        )
    }

    /// End-to-end physical contract: after a layout rebuild, a known
    /// recipient-directed severe-risk fixture visibly fires the L2
    /// indicator at the top of the z-order. Without the fix the
    /// indicator becomes `isHidden == false` but is occluded by the
    /// new keyboard stack — exactly the production no-show. The
    /// harmlessness control and the self-directed crisis control both
    /// remain completely silent.
    func testVisibleIndicatorSurvivesLayoutRebuildOnMajorRisk() throws {
        if let shared = UserDefaults(suiteName: LiveToneKeys.appGroupSuite) {
            LiveToneMasterToggle(defaults: shared).setEnabled(true)
        }

        let controller = KeyboardViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 320)
        controller.view.layoutIfNeeded()
        // Force a second layout rebuild at a different width so
        // installKeyboardLayout() re-runs (the exact same code path
        // that fires on rotation and trait change in production).
        controller.view.frame = CGRect(x: 0, y: 0, width: 844, height: 390)
        controller.view.layoutIfNeeded()

        // Recipient-directed severe risk — must visibly fire.
        let manager = try XCTUnwrap(
            controller.integrationDriveLiveTone(context: "I'll kill you."),
            "the shipping keyboard must install a Live Tone manager"
        )
        drainShippingPath(manager: manager)

        XCTAssertEqual(
            manager.debugEngine.currentWarning,
            .l2(.classBHyperbolicViolence),
            "the shipping path must fire an L2 warning on a major-risk fixture after a layout rebuild"
        )
        XCTAssertFalse(
            manager.indicator.isHidden,
            "the warning must visibly surface on the shipping indicator"
        )
        let indicator = manager.indicator
        let container = try XCTUnwrap(indicator.superview)
        XCTAssertEqual(
            container.subviews.last, indicator,
            "after the rebuild the indicator must be topmost so the warning is actually visible"
        )

        // Harmless control — must stay completely silent.
        manager.fieldDidReset()
        _ = controller.integrationDriveLiveTone(context: "Let's grab lunch tomorrow.")
        drainShippingPath(manager: manager)
        XCTAssertEqual(
            manager.debugEngine.currentWarning,
            LiveToneVisibleWarning.none,
            "a harmless control must leave the shipping engine silent after a layout rebuild"
        )
        XCTAssertTrue(
            manager.indicator.isHidden,
            "a harmless control must keep the indicator silent after a layout rebuild"
        )

        // Pure self-directed crisis — must stay completely silent.
        manager.fieldDidReset()
        _ = controller.integrationDriveLiveTone(context: "I want to kill myself.")
        drainShippingPath(manager: manager)
        XCTAssertEqual(
            manager.debugEngine.currentWarning,
            LiveToneVisibleWarning.none,
            "pure self-directed crisis must leave the shipping engine silent (no L1/L2 indicator by contract)"
        )
        XCTAssertTrue(
            manager.indicator.isHidden,
            "pure self-directed crisis must keep the indicator silent by contract"
        )
    }

    // MARK: - Helpers

    /// Deterministically flush the main queue: the engine publishes
    /// indicator updates via `DispatchQueue.main.async` from its own
    /// serial queue, so a FIFO fence enqueued after the (already-
    /// drained) evaluation guarantees the indicator update has run
    /// once `wait(for:)` returns.
    func drainMainQueue(timeout: TimeInterval = 2.0) {
        let fence = expectation(description: "main queue fence")
        DispatchQueue.main.async { fence.fulfill() }
        wait(for: [fence], timeout: timeout)
    }

    /// Hard-drain both queues. The Live Tone engine publishes
    /// indicator updates via `DispatchQueue.main.async` from its own
    /// serial queue. After a layout rebuild the keyboard's main-
    /// queue work (constraint pass, next-run-loop tick) can race the
    /// cross-queue dispatch and a single main-queue fence can return
    /// before the indicator's `apply(_:)` runs. We first force the
    /// engine's serial queue to drain via `queue.sync` (a real
    /// synchronous wait, not a fence), then run two main fences so
    /// the published `apply(_:)` is guaranteed to have processed.
    func drainShippingPath(manager: LiveToneManager? = nil, timeout: TimeInterval = 2.0) {
        _ = manager?.debugEngine.currentWarning
        drainMainQueue(timeout: timeout)
        drainMainQueue(timeout: timeout)
    }
}