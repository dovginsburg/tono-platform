// verify_space_cursor_focused.swift
// Standalone red/green verifier for the Apple-fidelity space hold/drag cursor
// engine. Pure Swift on macOS — no iOS Simulator, no Xcode, no UIKit, no
// XCTest.
//
// Compiles the REAL production source (SpaceCursorEngine.swift) alongside this
// runner, so it exercises the shipping logic directly. The engine is a pure
// value type driven by a fixed base `Date` advanced with `addingTimeInterval`,
// so every case is deterministic — no sleeps, no timers.
//
// The XCTest class `Tests/SpaceCursorGestureTests.swift` proves the same
// coverage against the proper TonoTests target; this macOS spine proves the
// coverage is wired right and is runnable without a simulator.
//
// Usage (from apps/ios):
//   swiftc -o /tmp/space_cursor \
//     KeyboardExtension/AppleFidelity/SpaceCursorEngine.swift \
//     Scripts/verify_space_cursor_focused.swift && /tmp/space_cursor
//
// Exits 0 on success, non-zero if any check fails.

import Foundation

// MARK: - Tiny assert harness

var failures = 0
var checks = 0
var tests = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() {
        failures += 1
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    }
}

let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

/// Fresh engine with default config (activationDelay 0.30, pointsPerCharacter
/// 10, tapCancelSlop 12) plus a caret with generous context on both sides.
func activated(left: Int = 20, right: Int = 20) -> SpaceCursorEngine {
    var e = SpaceCursorEngine()
    e.press(at: at(0), availableLeft: left, availableRight: right)
    let effect = e.tick(at: at(0.30))
    precondition(effect == .enteredCursorMode)
    return e
}

// MARK: - Tap once

func testTapOnceInsertsExactlyOneSpace() {
    tests += 1
    var e = SpaceCursorEngine()
    e.press(at: at(0), availableLeft: 5, availableRight: 5)
    check(e.isTracking, "press should begin tracking")
    let effect = e.end(at: at(0.05))
    check(effect == .insertSpace, "a quick tap must insert exactly one space")
    check(e.phase == .idle, "engine must be idle after a tap")
    check(!e.isTracking, "engine must not be tracking after a tap")
}

func testTapToleratesSmallWobble() {
    tests += 1
    var e = SpaceCursorEngine()
    e.press(at: at(0), availableLeft: 5, availableRight: 5)
    // Within the 12pt tap-cancel slop: still a tap.
    _ = e.drag(translationX: 3, translationY: -4, at: at(0.02))
    check(e.end(at: at(0.06)) == .insertSpace, "small wobble within slop is still a tap")
}

func testSwipeBeyondSlopBeforeActivationIsNotASpace() {
    tests += 1
    var e = SpaceCursorEngine()
    e.press(at: at(0), availableLeft: 5, availableRight: 5)
    _ = e.drag(translationX: 40, translationY: 0, at: at(0.05)) // beyond 12pt slop
    check(e.end(at: at(0.10)) == .none, "an aborted pre-activation swipe must not type a space")
    check(e.phase == .idle, "engine idle after aborted swipe")
}

// MARK: - Hold, no drag

func testHoldNoDragEntersCursorAndInsertsZeroSpaces() {
    tests += 1
    var e = SpaceCursorEngine()
    e.press(at: at(0), availableLeft: 5, availableRight: 5)
    check(e.tick(at: at(0.30)) == .enteredCursorMode, "hold past the delay enters cursor mode")
    check(e.isCursorActive, "cursor must be active after activation")
    let effect = e.end(at: at(0.5))
    check(effect == .endedCursorMode, "ending a no-drag hold reports endedCursorMode, not a space")
    check(effect != .insertSpace, "a hold must never insert a space")
    check(e.phase == .idle, "engine idle after a hold session")
}

func testActivationFiresExactlyOnceAtDelay() {
    tests += 1
    var e = SpaceCursorEngine()
    e.press(at: at(0), availableLeft: 5, availableRight: 5)
    check(e.tick(at: at(0.10)) == .none, "no activation before the delay")
    check(e.tick(at: at(0.299)) == .none, "no activation just before the delay")
    check(!e.isCursorActive, "not active before the delay")
    check(e.tick(at: at(0.30)) == .enteredCursorMode, "activation at the delay threshold")
    check(e.tick(at: at(0.40)) == .none, "activation fires only once")
}

func testHeldPastDelayButNeverTickedIsNotASpace() {
    tests += 1
    // Belt-and-suspenders: if the release is processed before the activation
    // work item, a hold longer than the delay must still not type a space.
    var e = SpaceCursorEngine()
    e.press(at: at(0), availableLeft: 5, availableRight: 5)
    check(e.end(at: at(0.40)) == .none, "a >delay hold with no tick must not insert a space")
}

// MARK: - Left / right drag

func testRightDragMovesCaretRight() {
    tests += 1
    var e = activated()
    let effect = e.drag(translationX: 25, translationY: 0, at: at(0.35)) // 2 chars
    check(effect == .moveCaret(offset: 2), "25pt right ⇒ +2 chars")
    check(e.appliedOffset == 2, "applied offset tracks the caret")
}

func testLeftDragMovesCaretLeft() {
    tests += 1
    var e = activated()
    let effect = e.drag(translationX: -14, translationY: 0, at: at(0.35)) // -1 char
    check(effect == .moveCaret(offset: -1), "14pt left ⇒ -1 char")
    check(e.appliedOffset == -1, "applied offset tracks the caret")
}

// MARK: - Repeated drag accumulation

func testRepeatedDragAccumulates() {
    tests += 1
    var e = activated(left: 20, right: 20)
    check(e.drag(translationX: 11, translationY: 0, at: at(0.31)) == .moveCaret(offset: 1), "→ offset 1")
    check(e.drag(translationX: 23, translationY: 0, at: at(0.32)) == .moveCaret(offset: 1), "→ offset 2 (delta +1)")
    check(e.drag(translationX: 35, translationY: 0, at: at(0.33)) == .moveCaret(offset: 1), "→ offset 3 (delta +1)")
    check(e.appliedOffset == 3, "cumulative right drag accumulates to 3")
    // Reverse direction: cumulative translation 12 ⇒ desired 1 ⇒ delta -2.
    check(e.drag(translationX: 12, translationY: 0, at: at(0.34)) == .moveCaret(offset: -2), "reverse ⇒ delta -2")
    check(e.appliedOffset == 1, "reversed back to offset 1")
}

func testSubCharacterAccumulation() {
    tests += 1
    var e = activated(left: 20, right: 20)
    check(e.drag(translationX: 9, translationY: 0, at: at(0.31)) == .none, "9pt < one char ⇒ no move")
    check(e.appliedOffset == 0, "sub-threshold drag does not move the caret")
    check(e.drag(translationX: 10, translationY: 0, at: at(0.32)) == .moveCaret(offset: 1), "crossing 10pt ⇒ +1")
    check(e.drag(translationX: 19, translationY: 0, at: at(0.33)) == .none, "still within the same char ⇒ no move")
    check(e.drag(translationX: 20, translationY: 0, at: at(0.34)) == .moveCaret(offset: 1), "crossing 20pt ⇒ +1")
    check(e.appliedOffset == 2, "accumulated two whole-character steps")
}

func testCustomPointsPerCharacter() {
    tests += 1
    var cfg = SpaceCursorConfig()
    cfg.pointsPerCharacter = 20
    var e = SpaceCursorEngine(config: cfg)
    e.press(at: at(0), availableLeft: 10, availableRight: 10)
    _ = e.tick(at: at(0.30))
    check(e.drag(translationX: 19, translationY: 0, at: at(0.31)) == .none, "19pt < 20pt/char ⇒ no move")
    check(e.drag(translationX: 20, translationY: 0, at: at(0.32)) == .moveCaret(offset: 1), "20pt ⇒ +1 char")
}

// MARK: - Vertical jitter

func testVerticalJitterIgnored() {
    tests += 1
    var e = activated()
    check(e.drag(translationX: 0, translationY: 50, at: at(0.31)) == .none, "pure vertical ⇒ no move")
    check(e.drag(translationX: 0, translationY: -80, at: at(0.32)) == .none, "pure vertical ⇒ no move")
    check(e.appliedOffset == 0, "vertical jitter never nudges the caret")
    check(e.drag(translationX: 22, translationY: 100, at: at(0.33)) == .moveCaret(offset: 2),
          "horizontal maps by X only, ignoring large vertical")
}

// MARK: - Context bounds

func testBeyondContextClampsToBounds() {
    tests += 1
    var e = SpaceCursorEngine()
    e.press(at: at(0), availableLeft: 3, availableRight: 2)
    _ = e.tick(at: at(0.30))
    check(e.drag(translationX: 1000, translationY: 0, at: at(0.31)) == .moveCaret(offset: 2),
          "far right clamps to +availableRight (2)")
    check(e.appliedOffset == 2, "clamped at right bound")
    check(e.drag(translationX: -1000, translationY: 0, at: at(0.32)) == .moveCaret(offset: -5),
          "far left clamps to -availableLeft (-3): delta from +2 is -5")
    check(e.appliedOffset == -3, "clamped at left bound")
    check(e.drag(translationX: -2000, translationY: 0, at: at(0.33)) == .none,
          "already at the left bound ⇒ no further move")
}

func testZeroContextNeverMoves() {
    tests += 1
    var e = SpaceCursorEngine()
    e.press(at: at(0), availableLeft: 0, availableRight: 0)
    _ = e.tick(at: at(0.30))
    check(e.drag(translationX: 100, translationY: 0, at: at(0.31)) == .none, "no right context ⇒ no move")
    check(e.drag(translationX: -100, translationY: 0, at: at(0.32)) == .none, "no left context ⇒ no move")
    check(e.appliedOffset == 0, "empty document keeps the caret put")
}

func testNegativeContextIsFlooredAtZero() {
    tests += 1
    var e = SpaceCursorEngine()
    e.press(at: at(0), availableLeft: -5, availableRight: -9)
    _ = e.tick(at: at(0.30))
    check(e.drag(translationX: 100, translationY: 0, at: at(0.31)) == .none, "negative bounds floored to 0")
}

// MARK: - Cancel

func testCancelBeforeActivationInsertsNoSpace() {
    tests += 1
    var e = SpaceCursorEngine()
    e.press(at: at(0), availableLeft: 5, availableRight: 5)
    check(e.cancel() == .none, "cancel before activation inserts no space")
    check(e.phase == .idle, "cancel resets to idle")
    check(e.tick(at: at(1)) == .none, "no activation after cancel")
}

func testCancelAfterActivationEndsCursorNoSpace() {
    tests += 1
    var e = activated()
    _ = e.drag(translationX: 30, translationY: 0, at: at(0.35)) // moved
    let effect = e.cancel()
    check(effect == .endedCursorMode, "cancel from cursor reports endedCursorMode for resync")
    check(effect != .insertSpace, "cancel never inserts a space")
    check(e.phase == .idle, "cancel resets to idle")
}

// MARK: - No post-takeover space / no leak

func testNoPostTakeoverSpace() {
    tests += 1
    var e = activated()
    _ = e.drag(translationX: 20, translationY: 0, at: at(0.35))
    let effect = e.end(at: at(0.6))
    check(effect == .endedCursorMode, "ending a drag reports endedCursorMode")
    check(effect != .insertSpace, "no delayed-tap leakage after takeover")
}

// MARK: - Teardown leaves no residue

func testIdleAfterEndAndCancel() {
    tests += 1
    var a = activated()
    _ = a.drag(translationX: 15, translationY: 0, at: at(0.35))
    _ = a.end(at: at(0.6))
    check(a.phase == .idle && !a.isTracking, "idle after end")

    var b = activated()
    _ = b.cancel()
    check(b.phase == .idle && !b.isTracking, "idle after cancel")
}

func testTapWorksAfterCursorSession() {
    tests += 1
    var e = SpaceCursorEngine()
    e.press(at: at(0), availableLeft: 5, availableRight: 5)
    _ = e.tick(at: at(0.30))
    _ = e.drag(translationX: 30, translationY: 0, at: at(0.35))
    check(e.end(at: at(0.6)) == .endedCursorMode, "cursor session ends cleanly")
    check(e.phase == .idle, "engine returns to idle")
    // A brand-new touch must behave as a fresh tap.
    e.press(at: at(1.0), availableLeft: 8, availableRight: 0)
    check(e.end(at: at(1.05)) == .insertSpace, "a tap after a cursor session still inserts a space")
}

// MARK: - Idle no-ops (mode/host switch land here after reset)

func testIdleTransitionsAreNoOps() {
    tests += 1
    var e = SpaceCursorEngine()
    check(e.drag(translationX: 10, translationY: 0, at: at(0)) == .none, "drag while idle is a no-op")
    check(e.tick(at: at(0)) == .none, "tick while idle is a no-op")
    check(e.end(at: at(0)) == .none, "end while idle is a no-op")
    check(e.cancel() == .none, "cancel while idle is a no-op")
    check(e.phase == .idle, "stays idle")
}

// MARK: - Runner

let allTests: [(String, () -> Void)] = [
    ("tapOnceInsertsExactlyOneSpace", testTapOnceInsertsExactlyOneSpace),
    ("tapToleratesSmallWobble", testTapToleratesSmallWobble),
    ("swipeBeyondSlopBeforeActivationIsNotASpace", testSwipeBeyondSlopBeforeActivationIsNotASpace),
    ("holdNoDragEntersCursorAndInsertsZeroSpaces", testHoldNoDragEntersCursorAndInsertsZeroSpaces),
    ("activationFiresExactlyOnceAtDelay", testActivationFiresExactlyOnceAtDelay),
    ("heldPastDelayButNeverTickedIsNotASpace", testHeldPastDelayButNeverTickedIsNotASpace),
    ("rightDragMovesCaretRight", testRightDragMovesCaretRight),
    ("leftDragMovesCaretLeft", testLeftDragMovesCaretLeft),
    ("repeatedDragAccumulates", testRepeatedDragAccumulates),
    ("subCharacterAccumulation", testSubCharacterAccumulation),
    ("customPointsPerCharacter", testCustomPointsPerCharacter),
    ("verticalJitterIgnored", testVerticalJitterIgnored),
    ("beyondContextClampsToBounds", testBeyondContextClampsToBounds),
    ("zeroContextNeverMoves", testZeroContextNeverMoves),
    ("negativeContextIsFlooredAtZero", testNegativeContextIsFlooredAtZero),
    ("cancelBeforeActivationInsertsNoSpace", testCancelBeforeActivationInsertsNoSpace),
    ("cancelAfterActivationEndsCursorNoSpace", testCancelAfterActivationEndsCursorNoSpace),
    ("noPostTakeoverSpace", testNoPostTakeoverSpace),
    ("idleAfterEndAndCancel", testIdleAfterEndAndCancel),
    ("tapWorksAfterCursorSession", testTapWorksAfterCursorSession),
    ("idleTransitionsAreNoOps", testIdleTransitionsAreNoOps),
]

@main
enum SpaceCursorFocusedVerifier {
    static func main() {
        for (name, fn) in allTests {
            fn()
            _ = name
        }
        if failures == 0 {
            print("PASS: \(checks) checks across \(tests) tests")
            exit(0)
        } else {
            FileHandle.standardError.write(
                Data("FAILED: \(failures) failed of \(checks) checks across \(tests) tests\n".utf8)
            )
            exit(1)
        }
    }
}
