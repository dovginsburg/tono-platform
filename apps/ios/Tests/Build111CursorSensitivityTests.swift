// Build111CursorSensitivityTests.swift
// Build 111 — the space-cursor slowdown, pinned numerically.
//
// PHYSICAL FINDING (signed TestFlight Build 110, 110f5dff, on device):
//
//     "I think the Cursor speed on space bar needs to be slowed down."
//
// This is a tuning defect, not a logic defect. Every Build-110 invariant —
// monotonicity, reversal symmetry, clamping, grapheme/UTF-16 correctness, the
// structural no-delete guarantee, host reconciliation — was correct and is
// unchanged. What was wrong was the RATE: at 8pt/character the caret outran
// the finger and overshot the character the user was aiming at.
//
// WHY A SEPARATE FILE. `SpaceCursorGestureTests` pins the CONTRACT (what the
// engine does). Its numeric expectations had to be re-baselined for the new
// rate, which means those assertions can no longer prove the rate went DOWN —
// they were edited in the same commit that changed it. This file proves the
// direction of the change independently, by comparing the shipping default
// against a literal Build-110 config that is reconstructed here. It is red
// against Build 110 and green against Build 111.
//
// The exhaustive sweeps (≈5,000 checks across the whole curve) live in
// `Scripts/verify_build111_cursor_sensitivity.swift`, which compiles the same
// production source with no simulator. This file carries the load-bearing
// subset so a plain `xcodebuild test` still fails if the rate regresses.

import XCTest
@testable import Tono

final class Build111CursorSensitivityTests: XCTestCase {

    private let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private func at(_ dt: TimeInterval) -> Date { base.addingTimeInterval(dt) }

    /// The EXACT horizontal tuning Build 110 shipped. Every other field stays
    /// at the current default, so this isolates the three values that changed.
    private func build110Config() -> SpaceCursorConfig {
        var c = SpaceCursorConfig()
        c.finePointsPerCharacter = 8.0
        c.precisionZonePoints = 24.0
        c.accelerationScalePoints = 120.0
        return c
    }

    private var shipping: SpaceCursorEngine { SpaceCursorEngine() }
    private var build110: SpaceCursorEngine { SpaceCursorEngine(config: build110Config()) }

    // MARK: - 1. The slowdown itself

    /// Short, precise drags — the "fix one typo" case. Build 110 moved 2
    /// characters for a 16pt nudge; Build 111 moves 1.
    func testShortPrecisionDragsMoveFewerCharactersThanBuild110() {
        let now = shipping, then = build110
        for pt in [16.0, 24.0, 30.0, 36.0, 48.0] {
            XCTAssertLessThan(
                now.horizontalCharacters(forTranslation: pt),
                then.horizontalCharacters(forTranslation: pt),
                "\(pt)pt must move fewer characters than Build 110"
            )
        }
        XCTAssertEqual(now.horizontalCharacters(forTranslation: 16), 1)
        XCTAssertEqual(then.horizontalCharacters(forTranslation: 16), 2)
        XCTAssertEqual(now.horizontalCharacters(forTranslation: 24), 2)
        XCTAssertEqual(then.horizontalCharacters(forTranslation: 24), 3)
    }

    /// Long accelerated travel — the "cross a sentence" case. The acceleration
    /// term is quadratic in travel, so past the precision zone the gap widens
    /// beyond a flat third. That is intended: the overshoot the device report
    /// described happened on the long sweeps.
    func testLongAcceleratedDragsMoveFewerCharactersThanBuild110() {
        let now = shipping, then = build110
        for pt in [100.0, 200.0, 300.0, 450.0, 600.0] {
            let a = now.horizontalCharacters(forTranslation: pt)
            let b = then.horizontalCharacters(forTranslation: pt)
            XCTAssertLessThan(a, b, "\(pt)pt: build111=\(a) must be < build110=\(b)")
            XCTAssertLessThanOrEqual(
                Double(a), Double(b) * 0.75,
                "\(pt)pt: build111=\(a) should be well under build110=\(b)"
            )
        }
        // The exact shipping value at a full sweep, so a silent retune is loud.
        XCTAssertEqual(now.horizontalCharacters(forTranslation: 300), 57)
        XCTAssertEqual(then.horizontalCharacters(forTranslation: 300), 116)
    }

    /// The structural claim behind the tuning: Build 111 is not a NEW curve, it
    /// is Build 110's curve dilated 1.5× along the finger-travel axis. Proving
    ///
    ///     chars_build111(1.5 · t) == chars_build110(t)
    ///
    /// is what makes "one third slower EVERYWHERE" a fact about the whole
    /// curve rather than a claim about sample points. (1.5 · t is exact in
    /// binary floating point for t on a 0.25 grid.)
    func testTheCurveIsAPureDilationOfBuild110() {
        let now = shipping, then = build110
        var t = 0.0
        while t <= 400.0 {
            XCTAssertEqual(
                now.horizontalCharacters(forTranslation: 1.5 * t),
                then.horizontalCharacters(forTranslation: t),
                "dilation identity broken at t=\(t)"
            )
            t += 0.25
        }
    }

    /// No region of the curve may be FASTER than Build 110. A reshaped (rather
    /// than dilated) curve could easily be slower near the origin and faster
    /// far from it — fixing the complaint for typo nudges while making the long
    /// sweep worse.
    func testNoTravelDistanceIsFasterThanBuild110() {
        let now = shipping, then = build110
        var pt = 0.0
        while pt <= 900.0 {
            XCTAssertLessThanOrEqual(
                now.horizontalCharacters(forTranslation: pt),
                then.horizontalCharacters(forTranslation: pt),
                "Build 111 is faster than Build 110 at \(pt)pt"
            )
            pt += 1.0
        }
    }

    // MARK: - 2. What must NOT have changed

    /// Slower must not mean coarser or jumpier: still monotonic
    /// non-decreasing, still exactly antisymmetric so a drag back retraces.
    func testCurveStaysMonotonicAndSymmetric() {
        let e = shipping
        var last = -1
        var pt = 0.0
        while pt <= 900.0 {
            let n = e.horizontalCharacters(forTranslation: pt)
            XCTAssertGreaterThanOrEqual(n, last, "monotonic at \(pt)pt")
            XCTAssertEqual(e.horizontalCharacters(forTranslation: -pt), -n, "symmetric at \(pt)pt")
            last = n
            pt += 2.0
        }
    }

    /// Enough practical range must survive the slowdown, or the caret becomes
    /// useless for anything but single-character nudges.
    func testPracticalRangeIsRetained() {
        let e = shipping
        // ~edge-to-edge on an iPhone 15 (393pt wide).
        XCTAssertGreaterThanOrEqual(
            e.horizontalCharacters(forTranslation: 350), 60,
            "a 350pt sweep must still cross ≥60 characters"
        )
        XCTAssertGreaterThanOrEqual(
            e.horizontalCharacters(forTranslation: 600), 150,
            "a 600pt sweep must still cross ≥150 characters"
        )
        // Still beats the fixed 10pt/char rate Build 103 was rejected for.
        XCTAssertGreaterThan(e.horizontalCharacters(forTranslation: 300), 30)
        // The smallest deliberate nudge still moves exactly one character.
        XCTAssertEqual(e.horizontalCharacters(forTranslation: 12), 1)
    }

    /// Only the three horizontal knobs moved. Activation timing, tap slop, the
    /// vertical dead zone, the per-line rate and the safety cap are Build-110
    /// identical — the report was about horizontal speed and nothing else.
    func testOnlyTheHorizontalKnobsChanged() {
        let now = SpaceCursorConfig(), then = build110Config()
        XCTAssertEqual(now.activationDelay, then.activationDelay)
        XCTAssertEqual(now.tapCancelSlop, then.tapCancelSlop)
        XCTAssertEqual(now.verticalDeadZonePoints, then.verticalDeadZonePoints)
        XCTAssertEqual(now.pointsPerLine, then.pointsPerLine)
        XCTAssertEqual(now.maximumCharactersPerGesture, then.maximumCharactersPerGesture)

        XCTAssertEqual(now.finePointsPerCharacter, 12.0)
        XCTAssertEqual(now.precisionZonePoints, 36.0)
        XCTAssertEqual(now.accelerationScalePoints, 180.0)
        // Uniform dilation — the property the whole tuning rests on.
        XCTAssertEqual(now.finePointsPerCharacter, then.finePointsPerCharacter * 1.5)
        XCTAssertEqual(now.precisionZonePoints, then.precisionZonePoints * 1.5)
        XCTAssertEqual(now.accelerationScalePoints, then.accelerationScalePoints * 1.5)
    }

    /// Vertical row travel is byte-identical to Build 110 across the range.
    func testVerticalTravelIsUntouched() {
        let now = shipping, then = build110
        var pt = -300.0
        while pt <= 300.0 {
            XCTAssertEqual(
                now.verticalLines(forTranslation: pt),
                then.verticalLines(forTranslation: pt),
                "vertical travel changed at \(pt)pt"
            )
            pt += 1.0
        }
    }

    // MARK: - 3. Through the real gesture path

    /// The full session path shows the same slowdown the pure curve does, and
    /// still never mutates text. Both documents are long enough on both sides
    /// that neither rate clamps at a boundary — a clamp would make the two
    /// builds tie and hide the difference.
    func testRealGestureSessionMovesLessAndNeverMutates() throws {
        let sentence = String(
            repeating: "The quick brown fox jumps over the lazy dog while the river runs on. ",
            count: 12
        )
        for pt in [24.0, 60.0, 150.0, 300.0] {
            let nowProxy = RecordingHost(before: sentence, after: sentence)
            let nowSession = SpaceCursorSession(engine: SpaceCursorEngine(), proxy: nowProxy)
            nowSession.press(at: at(0))
            _ = nowSession.tick(at: at(0.30))
            _ = nowSession.drag(translationX: pt, translationY: 0, at: at(0.4))

            let thenProxy = RecordingHost(before: sentence, after: sentence)
            let thenSession = SpaceCursorSession(
                engine: SpaceCursorEngine(config: build110Config()), proxy: thenProxy
            )
            thenSession.press(at: at(0))
            _ = thenSession.tick(at: at(0.30))
            _ = thenSession.drag(translationX: pt, translationY: 0, at: at(0.4))

            XCTAssertLessThan(
                nowProxy.caret, thenProxy.caret,
                "\(pt)pt through the session: build111 must trail build110"
            )
            XCTAssertFalse(nowProxy.textEverChanged, "\(pt)pt drag mutated text")
            XCTAssertEqual(nowSession.end(at: at(1.0)), .endedCursorMode,
                           "\(pt)pt release must not insert a space")
        }
    }

    /// Reversal still retraces exactly at the new rate: no ratchet, no
    /// hysteresis, and the structural no-delete guarantee is untouched.
    func testReversalStillRetracesExactlyAtTheNewRate() {
        var e = SpaceCursorEngine()
        e.press(at: at(0))
        _ = e.tick(at: at(0.30), document: SpaceCursorDocument(
            before: String(repeating: "a", count: 400),
            after: String(repeating: "b", count: 400)
        ))
        _ = e.drag(translationX: 300, translationY: 0, at: at(0.4))
        let forward = e.appliedOffset ?? 0
        XCTAssertEqual(forward, 57, "300pt ⇒ 57 characters at the Build-111 rate")
        _ = e.drag(translationX: 0, translationY: 0, at: at(0.5))
        XCTAssertEqual(e.appliedOffset, 0, "returning to the origin restores the caret exactly")
        _ = e.drag(translationX: -300, translationY: 0, at: at(0.6))
        XCTAssertEqual(e.appliedOffset, -forward, "left mirrors right at the new rate")
    }

    /// A quick tap is still a space, and a slower curve must not make an
    /// aborted swipe start typing.
    func testTapAndSlopBehaviourIsUnchanged() {
        var tap = SpaceCursorEngine()
        tap.press(at: at(0))
        XCTAssertEqual(tap.end(at: at(0.05)), .insertSpace)

        var swipe = SpaceCursorEngine()
        swipe.press(at: at(0))
        _ = swipe.drag(translationX: 30, translationY: 0, at: at(0.05))
        XCTAssertEqual(swipe.end(at: at(0.1)), .none, "aborted swipe still types nothing")

        var held = SpaceCursorEngine()
        held.press(at: at(0))
        _ = held.tick(at: at(0.30), document: SpaceCursorDocument(before: "ab", after: "cd"))
        XCTAssertEqual(held.end(at: at(0.9)), .endedCursorMode, "hold+release inserts no space")
    }

    /// Grapheme/UTF-16 correctness at the new rate: one step is still one
    /// user-visible character, and the host is asked to cross the right number
    /// of UTF-16 units.
    func testGraphemeAndUTF16CorrectnessAtTheNewRate() throws {
        var e = SpaceCursorEngine()
        e.press(at: at(0))
        _ = e.tick(at: at(0.30), document: SpaceCursorDocument(before: "😀😀😀", after: "😀😀😀"))
        let effect = e.drag(translationX: 36, translationY: 0, at: at(0.4))
        guard case .moveCaret(let graphemes, let utf16) = effect else {
            return XCTFail("expected a move")
        }
        XCTAssertEqual(graphemes, 3, "36pt ⇒ 3 graphemes at the Build-111 rate")
        XCTAssertEqual(utf16, 6, "3 non-BMP emoji = 6 UTF-16 units")
    }

    // MARK: - Host double

    /// Applies UTF-16 caret offsets to real text and records every call.
    /// `SpaceCursorTextProxy` has no insert or delete member, so this double
    /// cannot even be asked to mutate text.
    private final class RecordingHost: SpaceCursorTextProxy {
        private(set) var text: [Character]
        private(set) var caret: Int
        private(set) var adjustCalls: [Int] = []
        private let original: [Character]

        init(before: String, after: String) {
            text = Array(before + after)
            original = text
            caret = Array(before).count
        }
        var textEverChanged: Bool { text != original }
        var documentContextBeforeInput: String? { String(text[0..<caret]) }
        var documentContextAfterInput: String? { String(text[caret...]) }
        func adjustTextPosition(byCharacterOffset offset: Int) {
            adjustCalls.append(offset)
            var idx = caret
            var remaining = abs(offset)
            let step = offset < 0 ? -1 : 1
            while remaining > 0 {
                let next = idx + step
                guard next >= 0, next <= text.count else { break }
                remaining -= (step > 0 ? text[idx] : text[next]).utf16.count
                idx = next
            }
            caret = max(0, min(idx, text.count))
        }
    }
}
