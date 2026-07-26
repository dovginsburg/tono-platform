// verify_build111_cursor_sensitivity.swift
// Standalone red/green verifier for the Build-111 space-cursor slowdown.
//
// WHY THIS FILE EXISTS
// Build 110 shipped 8pt/character, a 24pt precision zone and a 120pt
// acceleration scale. Physically tested on device, the report was:
//
//     "I think the Cursor speed on space bar needs to be slowed down."
//
// That is a product-tuning defect, not a logic defect: every Build-110
// invariant (monotonicity, reversal symmetry, clamping, no-delete, grapheme
// correctness) was and remains correct. What was wrong was the RATE.
//
// Build 111 dilates the response curve 1.5× along the finger-travel axis —
// 12 / 36 / 180 — so every character costs 1.5× the travel it used to, at
// every point on the curve. Sensitivity (characters per point) is therefore
// exactly 2/3 of Build 110's: the one-third reduction the report asked for.
//
// This verifier compares the SHIPPING default against a literal Build-110
// config, so it is red against Build 110 and green against Build 111. It
// deliberately does not re-prove the Build-104/105/106 contracts — those live
// in verify_space_cursor_focused.swift and must stay green unchanged.
//
// Pure Swift on macOS — no iOS Simulator, no Xcode, no UIKit, no XCTest.
// Compiles the REAL production source alongside this runner.
//
// Usage (from apps/ios):
//   swiftc -o /tmp/build111_cursor \
//     KeyboardExtension/AppleFidelity/SpaceCursorEngine.swift \
//     Scripts/verify_build111_cursor_sensitivity.swift && /tmp/build111_cursor
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
        FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
    }
}

let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
func at(_ dt: TimeInterval) -> Date { base.addingTimeInterval(dt) }

/// The EXACT horizontal tuning Build 110 shipped (commit 110f5dff). Every
/// other field is left at the current default, so this isolates the three
/// values Build 111 changed and nothing else.
func build110Config() -> SpaceCursorConfig {
    var c = SpaceCursorConfig()
    c.finePointsPerCharacter = 8.0
    c.precisionZonePoints = 24.0
    c.accelerationScalePoints = 120.0
    return c
}

let shipping = SpaceCursorEngine()                              // Build 111
let build110 = SpaceCursorEngine(config: build110Config())      // Build 110

/// Travel distances a thumb actually produces on an iPhone space bar: a typo
/// nudge, a word, a clause, a sentence, and an edge-to-edge sweep.
let representativeTravel: [Double] = [
    6, 8, 12, 16, 24, 30, 36, 48, 60, 80,
    100, 140, 180, 220, 260, 300, 350, 400, 500, 600,
]

// ───────────────────────────────────────────────────────────────────────────
// 1. The slowdown itself
// ───────────────────────────────────────────────────────────────────────────

/// The headline claim: for every drag a thumb can actually make, Build 111
/// moves fewer characters than Build 110 did. Not "on average", not "for long
/// drags" — for each representative distance, individually.
///
/// Below 16pt the two rates round to the same integer (12pt and 8pt both floor
/// to one character at 12pt of travel), so a strict inequality is not
/// representable there and is not asserted. Every distance at or above 16pt —
/// which is every distance a deliberate drag actually covers — is strictly
/// slower, and no distance anywhere is faster.
func verify_every_representative_drag_moves_fewer_characters_than_build_110() {
    for pt in representativeTravel {
        let now = shipping.horizontalCharacters(forTranslation: pt)
        let then = build110.horizontalCharacters(forTranslation: pt)
        check(now <= then,
              "\(pt)pt must never move more chars than Build 110: build111=\(now) build110=\(then)")
        if pt >= 16 {
            check(now < then,
                  "\(pt)pt must move fewer chars than Build 110: build111=\(now) build110=\(then)")
        }
    }
}

/// Short, precise drags — the "fix one typo" case. Build 110 moved 2 chars
/// for a 16pt nudge; Build 111 moves 1. Build 110 moved 3 at the 24pt zone
/// edge; Build 111 moves 2.
func verify_short_precision_drags_are_two_thirds_of_build_110() {
    let cases: [(Double, Int, Int)] = [   // (travel, build111, build110)
        (8,   0, 1),
        (12,  1, 1),
        (16,  1, 2),
        (24,  2, 3),
        (36,  3, 4),
    ]
    for (pt, expectedNow, expectedThen) in cases {
        let now = shipping.horizontalCharacters(forTranslation: pt)
        let then = build110.horizontalCharacters(forTranslation: pt)
        check(now == expectedNow, "\(pt)pt ⇒ \(expectedNow) chars in Build 111, got \(now)")
        check(then == expectedThen, "\(pt)pt ⇒ \(expectedThen) chars in Build 110, got \(then)")
    }
    // Inside the precision zone the rate is exactly linear, so the reduction
    // is exactly one third — 12pt per character instead of 8pt.
    check(shipping.config.finePointsPerCharacter
          == build110.config.finePointsPerCharacter * 1.5,
          "fine rate must be exactly 1.5× Build 110's")
}

/// Long accelerated travel — the "cross a sentence" case.
func verify_long_accelerated_drags_move_fewer_characters() {
    let cases: [Double] = [100, 200, 300, 450, 600]
    for pt in cases {
        let now = shipping.horizontalCharacters(forTranslation: pt)
        let then = build110.horizontalCharacters(forTranslation: pt)
        check(now < then, "\(pt)pt: build111=\(now) must be < build110=\(then)")
        // The acceleration term is quadratic in travel, so past the zone the
        // gap widens beyond a flat third. That is the intended behaviour: the
        // overshoot the report described happened on the long sweeps.
        check(Double(now) <= Double(then) * 0.75,
              "\(pt)pt: build111=\(now) should be well under build110=\(then)")
    }
}

/// The structural claim behind the tuning: Build 111 is not a NEW curve, it is
/// Build 110's curve dilated 1.5× along the travel axis. Proving the identity
///
///     chars_build111(1.5 · t) == chars_build110(t)
///
/// over a dense sweep is what makes "one third slower everywhere" a fact about
/// the whole curve rather than a claim about the sample points above.
/// (1.5 · t is exact in binary floating point for t on a 0.25 grid.)
func verify_the_curve_is_a_pure_dilation_of_build_110() {
    var t = 0.0
    while t <= 400.0 {
        let dilated = shipping.horizontalCharacters(forTranslation: 1.5 * t)
        let original = build110.horizontalCharacters(forTranslation: t)
        check(dilated == original,
              "dilation identity broken at t=\(t): build111(\(1.5 * t))=\(dilated) vs build110(\(t))=\(original)")
        t += 0.25
    }
}

/// No region of the curve may be FASTER than Build 110 — a reshaped (rather
/// than dilated) curve could easily be slower near the origin and faster far
/// from it, which would fix the complaint in the precision zone and make the
/// long sweep worse.
func verify_no_travel_distance_is_faster_than_build_110() {
    var pt = 0.0
    while pt <= 900.0 {
        let now = shipping.horizontalCharacters(forTranslation: pt)
        let then = build110.horizontalCharacters(forTranslation: pt)
        check(now <= then, "Build 111 is FASTER than Build 110 at \(pt)pt: \(now) > \(then)")
        pt += 0.5
    }
}

// ───────────────────────────────────────────────────────────────────────────
// 2. What must NOT have changed
// ───────────────────────────────────────────────────────────────────────────

/// Slower must not mean coarser or jumpier. The curve is still monotonic
/// non-decreasing and exactly antisymmetric, so a drag back retraces.
func verify_curve_stays_monotonic_and_symmetric() {
    var last = -1
    var pt = 0.0
    while pt <= 900.0 {
        let n = shipping.horizontalCharacters(forTranslation: pt)
        check(n >= last, "monotonic at \(pt)pt")
        check(shipping.horizontalCharacters(forTranslation: -pt) == -n, "symmetric at \(pt)pt")
        last = n
        pt += 2.0
    }
}

/// Enough practical range must survive the slowdown: an ordinary sweep still
/// has to cross a real sentence, or the caret becomes useless for anything but
/// single-character nudges.
func verify_practical_range_is_retained() {
    // ~edge-to-edge on an iPhone 15 (393pt wide).
    let sweep = shipping.horizontalCharacters(forTranslation: 350)
    check(sweep >= 60, "a 350pt sweep must still cross ≥60 chars, got \(sweep)")
    // A finger can keep travelling past the keyboard's own bounds.
    let long = shipping.horizontalCharacters(forTranslation: 600)
    check(long >= 150, "a 600pt sweep must still cross ≥150 chars, got \(long)")
    // And it still beats the fixed 10pt/char rate Build 103 was rejected for.
    check(shipping.horizontalCharacters(forTranslation: 300) > 30,
          "300pt must beat the rejected fixed 10pt/char rate")
    // The smallest deliberate nudge still moves exactly one character.
    check(shipping.horizontalCharacters(forTranslation: 12) == 1,
          "12pt must move exactly one character")
}

/// Only the three horizontal knobs moved. Activation timing, tap slop, the
/// vertical dead zone, the per-line rate and the safety cap are Build-110
/// identical — the report was about horizontal speed and nothing else.
func verify_only_the_horizontal_knobs_changed() {
    let now = SpaceCursorConfig()
    let then = build110Config()
    check(now.activationDelay == then.activationDelay, "activation delay unchanged")
    check(now.tapCancelSlop == then.tapCancelSlop, "tap-cancel slop unchanged")
    check(now.verticalDeadZonePoints == then.verticalDeadZonePoints, "vertical dead zone unchanged")
    check(now.pointsPerLine == then.pointsPerLine, "points-per-line unchanged")
    check(now.maximumCharactersPerGesture == then.maximumCharactersPerGesture, "cap unchanged")

    check(now.finePointsPerCharacter == 12.0, "Build 111 fine rate is 12pt/char")
    check(now.precisionZonePoints == 36.0, "Build 111 precision zone is 36pt")
    check(now.accelerationScalePoints == 180.0, "Build 111 acceleration scale is 180pt")
}

/// Vertical row travel is byte-identical to Build 110 across the whole range.
func verify_vertical_travel_is_untouched() {
    var pt = -300.0
    while pt <= 300.0 {
        check(shipping.verticalLines(forTranslation: pt) == build110.verticalLines(forTranslation: pt),
              "vertical travel changed at \(pt)pt")
        pt += 1.0
    }
}

// ───────────────────────────────────────────────────────────────────────────
// 3. End-to-end through the real gesture path
// ───────────────────────────────────────────────────────────────────────────

/// Simulates a host: applies UTF-16 caret offsets to real text and records
/// every call. `SpaceCursorTextProxy` has no insert or delete member, so this
/// double cannot even be asked to mutate text.
final class RecordingProxy: SpaceCursorTextProxy {
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

/// The full session path — press, hold, drag, release — must show the same
/// slowdown the pure curve does, and must still never mutate text.
func verify_real_gesture_session_moves_less_and_never_mutates() {
    // Long enough on BOTH sides that neither rate clamps at a boundary — a
    // clamp would make the two builds tie and hide the difference.
    let sentence = String(
        repeating: "The quick brown fox jumps over the lazy dog while the river runs on. ",
        count: 12
    )
    for pt in [24.0, 60.0, 150.0, 300.0] {
        let nowProxy = RecordingProxy(before: sentence, after: sentence)
        let nowSession = SpaceCursorSession(engine: SpaceCursorEngine(), proxy: nowProxy)
        nowSession.press(at: at(0))
        _ = nowSession.tick(at: at(0.30))
        _ = nowSession.drag(translationX: pt, translationY: 0, at: at(0.4))

        let thenProxy = RecordingProxy(before: sentence, after: sentence)
        let thenSession = SpaceCursorSession(
            engine: SpaceCursorEngine(config: build110Config()), proxy: thenProxy
        )
        thenSession.press(at: at(0))
        _ = thenSession.tick(at: at(0.30))
        _ = thenSession.drag(translationX: pt, translationY: 0, at: at(0.4))

        check(nowProxy.caret < thenProxy.caret,
              "\(pt)pt through the session: build111 caret \(nowProxy.caret) must trail build110 \(thenProxy.caret)")
        check(!nowProxy.textEverChanged, "\(pt)pt drag mutated text")
        check(nowSession.end(at: at(1.0)) == .endedCursorMode, "\(pt)pt release must not insert a space")
    }
}

/// Reversal still retraces exactly at the new rate: no ratchet, no hysteresis.
func verify_reversal_still_retraces_exactly_at_the_new_rate() {
    var e = SpaceCursorEngine()
    e.press(at: at(0))
    _ = e.tick(at: at(0.30), document: SpaceCursorDocument(
        before: String(repeating: "a", count: 400),
        after: String(repeating: "b", count: 400)
    ))
    _ = e.drag(translationX: 300, translationY: 0, at: at(0.4))
    let forward = e.appliedOffset ?? 0
    check(forward == 57, "300pt ⇒ 57 chars at the Build-111 rate, got \(forward)")
    _ = e.drag(translationX: 0, translationY: 0, at: at(0.5))
    check(e.appliedOffset == 0, "returning to the origin restores the caret exactly")
    _ = e.drag(translationX: -300, translationY: 0, at: at(0.6))
    check(e.appliedOffset == -forward, "left mirrors right at the new rate")
}

/// A quick tap is still a space, and a slower curve must not make an aborted
/// swipe start typing.
func verify_tap_and_slop_behaviour_is_unchanged() {
    var tap = SpaceCursorEngine()
    tap.press(at: at(0))
    check(tap.end(at: at(0.05)) == .insertSpace, "quick tap still inserts one space")

    var swipe = SpaceCursorEngine()
    swipe.press(at: at(0))
    _ = swipe.drag(translationX: 30, translationY: 0, at: at(0.05))
    check(swipe.end(at: at(0.1)) == .none, "aborted swipe still types nothing")

    var held = SpaceCursorEngine()
    held.press(at: at(0))
    _ = held.tick(at: at(0.30), document: SpaceCursorDocument(before: "ab", after: "cd"))
    check(held.end(at: at(0.9)) == .endedCursorMode, "hold+release still inserts no space")
}

// ───────────────────────────────────────────────────────────────────────────
// Runner
// ───────────────────────────────────────────────────────────────────────────

let suite: [(String, () -> Void)] = [
    ("every representative drag moves fewer characters than Build 110",
     verify_every_representative_drag_moves_fewer_characters_than_build_110),
    ("short precision drags are two thirds of Build 110",
     verify_short_precision_drags_are_two_thirds_of_build_110),
    ("long accelerated drags move fewer characters",
     verify_long_accelerated_drags_move_fewer_characters),
    ("the curve is a pure dilation of Build 110",
     verify_the_curve_is_a_pure_dilation_of_build_110),
    ("no travel distance is faster than Build 110",
     verify_no_travel_distance_is_faster_than_build_110),
    ("curve stays monotonic and symmetric",
     verify_curve_stays_monotonic_and_symmetric),
    ("practical range is retained", verify_practical_range_is_retained),
    ("only the horizontal knobs changed", verify_only_the_horizontal_knobs_changed),
    ("vertical travel is untouched", verify_vertical_travel_is_untouched),
    ("real gesture session moves less and never mutates",
     verify_real_gesture_session_moves_less_and_never_mutates),
    ("reversal still retraces exactly at the new rate",
     verify_reversal_still_retraces_exactly_at_the_new_rate),
    ("tap and slop behaviour is unchanged", verify_tap_and_slop_behaviour_is_unchanged),
]

@main
enum Build111CursorSensitivityVerifier {
    static func main() {
        for (name, body) in suite {
            tests += 1
            let before = failures
            body()
            if failures > before {
                FileHandle.standardError.write(Data("  ✗ \(name)\n".utf8))
            }
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
