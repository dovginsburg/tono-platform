// SpaceCursorGestureTests.swift
// State-machine coverage for the Apple-fidelity space hold/drag caret
// trackpad (`SpaceCursorEngine`).
//
// The engine is a pure value type driven by wall-clock ticks, so every case
// here is deterministic — no sleeps, no timers, no UIKit. A fixed base `Date`
// is advanced with `addingTimeInterval` to model exactly what the host
// gesture recognizer + activation work item would deliver. This mirrors the
// runnable macOS spine in `Scripts/verify_space_cursor_focused.swift`.

import XCTest

final class SpaceCursorGestureTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// A fresh engine already in trackpad mode with generous context.
    private func activated(left: Int = 20, right: Int = 20) -> SpaceCursorEngine {
        var e = SpaceCursorEngine()
        e.press(at: at(0), availableLeft: left, availableRight: right)
        XCTAssertEqual(e.tick(at: at(0.30)), .enteredCursorMode)
        return e
    }

    // MARK: - Tap once

    func testTapOnceInsertsExactlyOneSpace() {
        var e = SpaceCursorEngine()
        e.press(at: at(0), availableLeft: 5, availableRight: 5)
        XCTAssertTrue(e.isTracking)
        XCTAssertEqual(e.end(at: at(0.05)), .insertSpace)
        XCTAssertEqual(e.phase, .idle)
        XCTAssertFalse(e.isTracking)
    }

    func testTapToleratesSmallWobble() {
        var e = SpaceCursorEngine()
        e.press(at: at(0), availableLeft: 5, availableRight: 5)
        _ = e.drag(translationX: 3, translationY: -4, at: at(0.02))
        XCTAssertEqual(e.end(at: at(0.06)), .insertSpace)
    }

    func testSwipeBeyondSlopBeforeActivationIsNotASpace() {
        var e = SpaceCursorEngine()
        e.press(at: at(0), availableLeft: 5, availableRight: 5)
        _ = e.drag(translationX: 40, translationY: 0, at: at(0.05))
        XCTAssertEqual(e.end(at: at(0.10)), .none)
        XCTAssertEqual(e.phase, .idle)
    }

    // MARK: - Hold, no drag

    func testHoldNoDragEntersCursorAndInsertsZeroSpaces() {
        var e = SpaceCursorEngine()
        e.press(at: at(0), availableLeft: 5, availableRight: 5)
        XCTAssertEqual(e.tick(at: at(0.30)), .enteredCursorMode)
        XCTAssertTrue(e.isCursorActive)
        let effect = e.end(at: at(0.5))
        XCTAssertEqual(effect, .endedCursorMode)
        XCTAssertNotEqual(effect, .insertSpace)
        XCTAssertEqual(e.phase, .idle)
    }

    func testActivationFiresExactlyOnceAtDelay() {
        var e = SpaceCursorEngine()
        e.press(at: at(0), availableLeft: 5, availableRight: 5)
        XCTAssertEqual(e.tick(at: at(0.10)), .none)
        XCTAssertEqual(e.tick(at: at(0.299)), .none)
        XCTAssertFalse(e.isCursorActive)
        XCTAssertEqual(e.tick(at: at(0.30)), .enteredCursorMode)
        XCTAssertEqual(e.tick(at: at(0.40)), .none)
    }

    func testHeldPastDelayButNeverTickedIsNotASpace() {
        var e = SpaceCursorEngine()
        e.press(at: at(0), availableLeft: 5, availableRight: 5)
        XCTAssertEqual(e.end(at: at(0.40)), .none)
    }

    // MARK: - Left / right drag

    func testRightDragMovesCaretRight() {
        var e = activated()
        XCTAssertEqual(e.drag(translationX: 25, translationY: 0, at: at(0.35)), .moveCaret(offset: 2))
        XCTAssertEqual(e.appliedOffset, 2)
    }

    func testLeftDragMovesCaretLeft() {
        var e = activated()
        XCTAssertEqual(e.drag(translationX: -14, translationY: 0, at: at(0.35)), .moveCaret(offset: -1))
        XCTAssertEqual(e.appliedOffset, -1)
    }

    // MARK: - Accumulation

    func testRepeatedDragAccumulates() {
        var e = activated(left: 20, right: 20)
        XCTAssertEqual(e.drag(translationX: 11, translationY: 0, at: at(0.31)), .moveCaret(offset: 1))
        XCTAssertEqual(e.drag(translationX: 23, translationY: 0, at: at(0.32)), .moveCaret(offset: 1))
        XCTAssertEqual(e.drag(translationX: 35, translationY: 0, at: at(0.33)), .moveCaret(offset: 1))
        XCTAssertEqual(e.appliedOffset, 3)
        XCTAssertEqual(e.drag(translationX: 12, translationY: 0, at: at(0.34)), .moveCaret(offset: -2))
        XCTAssertEqual(e.appliedOffset, 1)
    }

    func testSubCharacterAccumulation() {
        var e = activated(left: 20, right: 20)
        XCTAssertEqual(e.drag(translationX: 9, translationY: 0, at: at(0.31)), .none)
        XCTAssertEqual(e.appliedOffset, 0)
        XCTAssertEqual(e.drag(translationX: 10, translationY: 0, at: at(0.32)), .moveCaret(offset: 1))
        XCTAssertEqual(e.drag(translationX: 19, translationY: 0, at: at(0.33)), .none)
        XCTAssertEqual(e.drag(translationX: 20, translationY: 0, at: at(0.34)), .moveCaret(offset: 1))
        XCTAssertEqual(e.appliedOffset, 2)
    }

    func testCustomPointsPerCharacter() {
        var cfg = SpaceCursorConfig()
        cfg.pointsPerCharacter = 20
        var e = SpaceCursorEngine(config: cfg)
        e.press(at: at(0), availableLeft: 10, availableRight: 10)
        _ = e.tick(at: at(0.30))
        XCTAssertEqual(e.drag(translationX: 19, translationY: 0, at: at(0.31)), .none)
        XCTAssertEqual(e.drag(translationX: 20, translationY: 0, at: at(0.32)), .moveCaret(offset: 1))
    }

    // MARK: - Vertical jitter

    func testVerticalJitterIgnored() {
        var e = activated()
        XCTAssertEqual(e.drag(translationX: 0, translationY: 50, at: at(0.31)), .none)
        XCTAssertEqual(e.drag(translationX: 0, translationY: -80, at: at(0.32)), .none)
        XCTAssertEqual(e.appliedOffset, 0)
        XCTAssertEqual(e.drag(translationX: 22, translationY: 100, at: at(0.33)), .moveCaret(offset: 2))
    }

    // MARK: - Context bounds

    func testBeyondContextClampsToBounds() {
        var e = SpaceCursorEngine()
        e.press(at: at(0), availableLeft: 3, availableRight: 2)
        _ = e.tick(at: at(0.30))
        XCTAssertEqual(e.drag(translationX: 1000, translationY: 0, at: at(0.31)), .moveCaret(offset: 2))
        XCTAssertEqual(e.appliedOffset, 2)
        XCTAssertEqual(e.drag(translationX: -1000, translationY: 0, at: at(0.32)), .moveCaret(offset: -5))
        XCTAssertEqual(e.appliedOffset, -3)
        XCTAssertEqual(e.drag(translationX: -2000, translationY: 0, at: at(0.33)), .none)
    }

    func testZeroContextNeverMoves() {
        var e = SpaceCursorEngine()
        e.press(at: at(0), availableLeft: 0, availableRight: 0)
        _ = e.tick(at: at(0.30))
        XCTAssertEqual(e.drag(translationX: 100, translationY: 0, at: at(0.31)), .none)
        XCTAssertEqual(e.drag(translationX: -100, translationY: 0, at: at(0.32)), .none)
        XCTAssertEqual(e.appliedOffset, 0)
    }

    // MARK: - Cancel

    func testCancelBeforeActivationInsertsNoSpace() {
        var e = SpaceCursorEngine()
        e.press(at: at(0), availableLeft: 5, availableRight: 5)
        XCTAssertEqual(e.cancel(), .none)
        XCTAssertEqual(e.phase, .idle)
        XCTAssertEqual(e.tick(at: at(1)), .none)
    }

    func testCancelAfterActivationEndsCursorNoSpace() {
        var e = activated()
        _ = e.drag(translationX: 30, translationY: 0, at: at(0.35))
        let effect = e.cancel()
        XCTAssertEqual(effect, .endedCursorMode)
        XCTAssertNotEqual(effect, .insertSpace)
        XCTAssertEqual(e.phase, .idle)
    }

    // MARK: - No post-takeover space / clean teardown

    func testNoPostTakeoverSpace() {
        var e = activated()
        _ = e.drag(translationX: 20, translationY: 0, at: at(0.35))
        let effect = e.end(at: at(0.6))
        XCTAssertEqual(effect, .endedCursorMode)
        XCTAssertNotEqual(effect, .insertSpace)
    }

    func testIdleAfterEndAndCancel() {
        var a = activated()
        _ = a.drag(translationX: 15, translationY: 0, at: at(0.35))
        _ = a.end(at: at(0.6))
        XCTAssertEqual(a.phase, .idle)
        XCTAssertFalse(a.isTracking)

        var b = activated()
        _ = b.cancel()
        XCTAssertEqual(b.phase, .idle)
        XCTAssertFalse(b.isTracking)
    }

    func testTapWorksAfterCursorSession() {
        var e = SpaceCursorEngine()
        e.press(at: at(0), availableLeft: 5, availableRight: 5)
        _ = e.tick(at: at(0.30))
        _ = e.drag(translationX: 30, translationY: 0, at: at(0.35))
        XCTAssertEqual(e.end(at: at(0.6)), .endedCursorMode)
        XCTAssertEqual(e.phase, .idle)
        e.press(at: at(1.0), availableLeft: 8, availableRight: 0)
        XCTAssertEqual(e.end(at: at(1.05)), .insertSpace)
    }

    func testIdleTransitionsAreNoOps() {
        var e = SpaceCursorEngine()
        XCTAssertEqual(e.drag(translationX: 10, translationY: 0, at: at(0)), .none)
        XCTAssertEqual(e.tick(at: at(0)), .none)
        XCTAssertEqual(e.end(at: at(0)), .none)
        XCTAssertEqual(e.cancel(), .none)
        XCTAssertEqual(e.phase, .idle)
    }
}
