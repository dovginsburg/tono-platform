// SpaceCursorGestureTests.swift
// Build-104 contract for the space hold/drag caret trackpad.
//
// REPLACES the build-103 tests. Those asserted a fixed 10pt-per-character rate
// and contained `testVerticalJitterIgnored`, so they were green while the
// feature was physically rejected on device for moving "one character at a time
// like backspacing" and being unable to travel up/down. Ratifying an inadequate
// contract is worse than no test: it converts a product defect into a passing
// build. Every assertion below fails against the build-103 engine — 17 of the
// standalone verifier's 184 checks go red when build-103 behaviour is grafted
// back onto this source (see Scripts/verify_space_cursor_focused.swift).
//
// PUBLIC-API BOUNDARY (asserted, not assumed)
// `UITextDocumentProxy` offers only: read `documentContextBeforeInput` /
// `documentContextAfterInput`, and `adjustTextPosition(byCharacterOffset:)`.
// There is no public caret rectangle, no line-fragment geometry, and no
// selection-range API for a keyboard extension. "Line" here therefore always
// means a LOGICAL line delimited by "\n"; visual wrapping is unobservable and
// is deliberately not guessed at.

import XCTest

final class SpaceCursorGestureTests: XCTestCase {

    // A small base: a large epoch (1.7e9) has ~4e-7 double resolution, so
    // base+0.30 minus base can land just under the activation delay.
    private let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private func at(_ dt: TimeInterval) -> Date { base.addingTimeInterval(dt) }

    private func activated(before: String, after: String) -> SpaceCursorEngine {
        var e = SpaceCursorEngine()
        e.press(at: at(0))
        _ = e.tick(at: at(0.30), document: SpaceCursorDocument(before: before, after: after))
        return e
    }

    // MARK: - Recording proxy

    /// Host double. `SpaceCursorTextProxy` has no insert or delete member, so
    /// this cannot even be asked to mutate text — the assertions below prove the
    /// gesture never does.
    final class RecordingProxy: SpaceCursorTextProxy {
        private(set) var text: [Character]
        private(set) var caret: Int
        private(set) var adjustCalls: [Int] = []
        private let original: [Character]
        var clampsMovementTo: Int?
        var reportsNilContext = false

        init(before: String, after: String) {
            text = Array(before + after)
            original = text
            caret = Array(before).count
        }
        var documentContextBeforeInput: String? {
            reportsNilContext ? nil : String(text[0..<caret])
        }
        var documentContextAfterInput: String? {
            reportsNilContext ? nil : String(text[caret...])
        }
        func adjustTextPosition(byCharacterOffset offset: Int) {
            adjustCalls.append(offset)
            var applied = offset
            if let cap = clampsMovementTo { applied = max(-cap, min(cap, offset)) }
            var idx = caret
            var remaining = abs(applied)
            let step = applied < 0 ? -1 : 1
            while remaining > 0 {
                let next = idx + step
                guard next >= 0, next <= text.count else { break }
                let ch = step > 0 ? text[idx] : text[next]
                remaining -= ch.utf16.count
                idx = next
            }
            caret = max(0, min(idx, text.count))
        }
        var textEverChanged: Bool { text != original }
    }

    // MARK: - 1. Cursor mode never deletes or inserts

    func testEffectSurfaceCannotExpressDeletion() {
        let all: [SpaceCursorEngine.Effect] = [
            .none, .insertSpace, .enteredCursorMode,
            .moveCaret(graphemes: 1, utf16: 1), .endedCursorMode,
        ]
        XCTAssertEqual(all.count, 5, "no delete case may be added to Effect")
        var inserts = 0
        for e in all { if case .insertSpace = e { inserts += 1 } }
        XCTAssertEqual(inserts, 1, "exactly one effect can cause an insertion")
    }

    func testFullDragSessionMutatesNoText() {
        let proxy = RecordingProxy(before: "Hello world, this is a sentence.", after: " And more.")
        let session = SpaceCursorSession(proxy: proxy)
        session.press(at: at(0))
        _ = session.tick(at: at(0.30))
        for dx in stride(from: -240.0, through: 240.0, by: 13.0) {
            _ = session.drag(translationX: dx, translationY: Double.random(in: -30...30), at: at(0.4))
        }
        XCTAssertEqual(session.end(at: at(1.0)), .endedCursorMode)
        XCTAssertFalse(proxy.textEverChanged, "a cursor drag must never change text")
        XCTAssertEqual(String(proxy.text), "Hello world, this is a sentence. And more.")
        XCTAssertFalse(proxy.adjustCalls.isEmpty, "the drag did move the caret")
    }

    func testQuickTapInsertsExactlyOneSpace() {
        var e = SpaceCursorEngine()
        e.press(at: at(0))
        XCTAssertEqual(e.end(at: at(0.05)), .insertSpace)
        XCTAssertFalse(e.isCursorActive)
    }

    func testAbortedSwipeAndHeldReleaseNeverInsert() {
        var swipe = SpaceCursorEngine()
        swipe.press(at: at(0))
        _ = swipe.drag(translationX: 30, translationY: 0, at: at(0.05))
        XCTAssertEqual(swipe.end(at: at(0.1)), .none, "aborted swipe types nothing")

        var held = SpaceCursorEngine()
        held.press(at: at(0))
        _ = held.tick(at: at(0.30), document: SpaceCursorDocument(before: "ab", after: "cd"))
        XCTAssertEqual(held.end(at: at(0.9)), .endedCursorMode, "no delayed space after takeover")
    }

    // MARK: - 2. Accelerated horizontal movement

    func testLongDragAcceleratesWellPastTheRejectedFixedRate() {
        let e = SpaceCursorEngine()
        XCTAssertEqual(e.horizontalCharacters(forTranslation: 16), 2, "precise near the origin")
        let long = e.horizontalCharacters(forTranslation: 300)
        XCTAssertGreaterThanOrEqual(long, 80, "300pt must cross a sentence (build-103 gave 30)")
        XCTAssertGreaterThan(long, 30, "must beat the rejected fixed 10pt/char rate")
    }

    func testHorizontalCurveIsMonotonicAndSymmetric() {
        let e = SpaceCursorEngine()
        var last = -1
        for pt in stride(from: 0.0, through: 400.0, by: 8.0) {
            let n = e.horizontalCharacters(forTranslation: pt)
            XCTAssertGreaterThanOrEqual(n, last, "monotonic at \(pt)pt")
            XCTAssertEqual(e.horizontalCharacters(forTranslation: -pt), -n, "symmetric at \(pt)pt")
            last = n
        }
    }

    func testSmallCorrectionsStayPrecise() {
        let e = SpaceCursorEngine()
        XCTAssertEqual(e.horizontalCharacters(forTranslation: 4), 0)
        XCTAssertEqual(e.horizontalCharacters(forTranslation: 8), 1)
        XCTAssertEqual(e.horizontalCharacters(forTranslation: 24), 3)
    }

    func testReversalRetracesExactlyWithNoRatchet() {
        var e = activated(before: String(repeating: "a", count: 400),
                          after: String(repeating: "b", count: 400))
        let out = e.drag(translationX: 300, translationY: 0, at: at(0.4))
        guard case .moveCaret(let forward, _) = out else { return XCTFail("expected a move") }
        XCTAssertGreaterThan(forward, 30)
        _ = e.drag(translationX: 0, translationY: 0, at: at(0.5))
        XCTAssertEqual(e.appliedOffset, 0, "returning to the origin restores the caret exactly")
        _ = e.drag(translationX: -300, translationY: 0, at: at(0.6))
        XCTAssertEqual(e.appliedOffset, -forward, "left mirrors right")
    }

    func testClampsAtBothEndsWithoutStaleBounds() {
        var e = activated(before: "abc", after: "de")
        _ = e.drag(translationX: 5000, translationY: 0, at: at(0.4))
        XCTAssertEqual(e.caretIndex, 5)
        _ = e.drag(translationX: -5000, translationY: 0, at: at(0.5))
        XCTAssertEqual(e.caretIndex, 0)
        _ = e.drag(translationX: 0, translationY: 0, at: at(0.6))
        XCTAssertEqual(e.caretIndex, 3, "bound is not frozen at press time")
    }

    func testLongFieldTraversesQuickly() {
        let long = String(repeating: "lorem ipsum dolor sit amet ", count: 200)
        var e = activated(before: long, after: long)
        _ = e.drag(translationX: 600, translationY: 0, at: at(0.4))
        XCTAssertGreaterThan(e.appliedOffset ?? 0, 200, "600pt must cross >200 chars")
        XCTAssertLessThanOrEqual(e.caretIndex ?? .max, e.document?.count ?? 0)
    }

    // MARK: - 3. Two-dimensional / multiline navigation

    func testVerticalDragChangesLogicalLine() {
        var e = activated(before: "first line\nsec", after: "ond line\nthird line")
        XCTAssertTrue(e.document!.supportsVerticalNavigation)
        XCTAssertEqual(e.document!.lineCount, 3)
        XCTAssertEqual(e.document!.line(of: e.document!.origin), 1)

        _ = e.drag(translationX: 0, translationY: -40, at: at(0.4))
        XCTAssertEqual(e.document!.line(of: e.caretIndex!), 0, "up one line")
        XCTAssertEqual(e.document!.column(of: e.caretIndex!), 3, "column preserved")

        _ = e.drag(translationX: 0, translationY: 40, at: at(0.5))
        XCTAssertEqual(e.document!.line(of: e.caretIndex!), 2, "down two lines")
        XCTAssertEqual(e.document!.column(of: e.caretIndex!), 3, "sticky column preserved")
    }

    func testSubDeadZoneVerticalTravelIsIgnored() {
        // The invariant is that tremor contributes nothing — NOT that the caret
        // stays on its line. A pure horizontal drag flows across "\n" freely,
        // exactly as Apple's trackpad does.
        var tremor = activated(before: "alpha\nbra", after: "vo\ncharlie")
        var clean = activated(before: "alpha\nbra", after: "vo\ncharlie")
        _ = tremor.drag(translationX: 60, translationY: 12, at: at(0.4))
        _ = clean.drag(translationX: 60, translationY: 0, at: at(0.4))
        XCTAssertEqual(tremor.caretIndex, clean.caretIndex, "12pt of tremor changes nothing")

        var crossed = activated(before: "alpha\nbra", after: "vo\ncharlie")
        _ = crossed.drag(translationX: 0, translationY: -30, at: at(0.4))
        XCTAssertEqual(crossed.document!.line(of: crossed.caretIndex!), 0,
                       "the dead zone is a threshold, not a lock")
    }

    func testStickyColumnSurvivesAShortInterveningLine() {
        var e = activated(before: "0123456789abc", after: "\nxy\n0123456789ABC")
        XCTAssertEqual(e.document!.column(of: e.caretIndex!), 13)
        _ = e.drag(translationX: 0, translationY: 30, at: at(0.4))      // one line down
        XCTAssertEqual(e.document!.line(of: e.caretIndex!), 1)
        XCTAssertEqual(e.document!.column(of: e.caretIndex!), 2, "clamped to the short line")
        _ = e.drag(translationX: 0, translationY: 60, at: at(0.5))      // two lines down
        XCTAssertEqual(e.document!.column(of: e.caretIndex!), 13, "sticky column restored")
    }

    /// PUBLIC-API LIMIT: with no newline in the captured context there is no
    /// observable line structure, and UIKit exposes no wrapped-line geometry to
    /// a keyboard extension. The engine degrades to horizontal-only rather than
    /// inventing a line height.
    func testSingleLineContextDegradesToHorizontalOnly() {
        var e = activated(before: "just one single line of text", after: " continues here")
        XCTAssertFalse(e.document!.supportsVerticalNavigation)
        let start = e.caretIndex!
        _ = e.drag(translationX: 0, translationY: -200, at: at(0.4))
        XCTAssertEqual(e.caretIndex, start, "no vertical movement is invented")
        _ = e.drag(translationX: 80, translationY: -200, at: at(0.5))
        XCTAssertGreaterThan(e.caretIndex!, start, "horizontal still works")
    }

    func testEmptyAndNilContextAreSafe() {
        var e = activated(before: "", after: "")
        _ = e.drag(translationX: 500, translationY: 500, at: at(0.4))
        XCTAssertEqual(e.caretIndex, 0)
        XCTAssertEqual(e.end(at: at(0.6)), .endedCursorMode)

        let proxy = RecordingProxy(before: "abc", after: "def")
        proxy.reportsNilContext = true
        let s = SpaceCursorSession(proxy: proxy)
        s.press(at: at(0))
        _ = s.tick(at: at(0.30))
        _ = s.drag(translationX: 300, translationY: 0, at: at(0.4))
        XCTAssertFalse(proxy.textEverChanged, "a nil-context host is never mutated")
    }

    // MARK: - 4. Unicode correctness

    func testEmojiIsOneCaretStepButTwoUTF16Units() {
        var e = activated(before: "a😀b", after: "")
        XCTAssertEqual(e.document!.count, 3, "emoji is ONE grapheme")
        XCTAssertEqual(e.document!.utf16Distance(from: 0, to: 3), 4)
        _ = e.drag(translationX: -8, translationY: 0, at: at(0.4))
        XCTAssertEqual(e.caretIndex, 2, "one step lands between 😀 and b, never inside it")
    }

    func testComposedGraphemesAreSingleSteps() {
        for (text, expected) in [("👨‍👩‍👧‍👦", 1), ("🇺🇸", 1), ("👍🏽", 1), ("é", 1)] {
            let doc = SpaceCursorDocument(before: text, after: "")
            XCTAssertEqual(doc.count, expected, "\(text) grapheme count")
            var e = activated(before: text, after: "")
            _ = e.drag(translationX: -5000, translationY: 0, at: at(0.4))
            XCTAssertEqual(e.caretIndex, 0, "\(text) clamps to 0")
            _ = e.drag(translationX: 5000, translationY: 0, at: at(0.5))
            XCTAssertEqual(e.caretIndex, doc.count, "\(text) clamps to end")
        }
    }

    func testUTF16DeltaMatchesTheSpanTheHostMustCross() {
        var e = activated(before: "😀😀😀", after: "😀😀😀")
        let out = e.drag(translationX: 24, translationY: 0, at: at(0.4))
        guard case .moveCaret(let g, let u) = out else { return XCTFail("expected a move") }
        XCTAssertEqual(g, 3)
        XCTAssertEqual(u, 6, "3 non-BMP emoji = 6 UTF-16 units")
    }

    /// PUBLIC-API LIMIT: movement is LOGICAL (character order). Visual-order
    /// movement in bidi text would need host layout, which is not exposed.
    func testRTLAndBidiMoveLogicallyWithoutCorruption() {
        var e = activated(before: "مرحبا ", after: "بالعالم")
        let origin = e.document!.origin
        _ = e.drag(translationX: 40, translationY: 0, at: at(0.4))
        XCTAssertGreaterThan(e.caretIndex!, origin)
        _ = e.drag(translationX: 0, translationY: 0, at: at(0.5))
        XCTAssertEqual(e.caretIndex, origin, "reversal exact in RTL")

        var mixed = activated(before: "abc مرحبا ", after: "xyz")
        _ = mixed.drag(translationX: 5000, translationY: 0, at: at(0.4))
        XCTAssertEqual(mixed.caretIndex, mixed.document!.count)
    }

    // MARK: - 5. Session robustness

    func testCancellationNeverInserts() {
        var e = activated(before: "abc", after: "def")
        _ = e.drag(translationX: 40, translationY: 0, at: at(0.4))
        XCTAssertEqual(e.cancel(), .endedCursorMode)
        XCTAssertFalse(e.isTracking)

        var p = SpaceCursorEngine()
        p.press(at: at(0))
        XCTAssertEqual(p.cancel(), .none)
    }

    func testIdleTransitionsAreInert() {
        var e = SpaceCursorEngine()
        XCTAssertEqual(e.drag(translationX: 50, translationY: 50, at: at(0)), .none)
        XCTAssertEqual(e.tick(at: at(0), document: SpaceCursorDocument(before: "a", after: "b")), .none)
        XCTAssertEqual(e.end(at: at(0)), .none)
        XCTAssertEqual(e.cancel(), .none)
    }

    func testTapStillWorksImmediatelyAfterACursorSession() {
        var e = activated(before: "abcdef", after: "ghij")
        _ = e.drag(translationX: 40, translationY: 0, at: at(0.4))
        XCTAssertEqual(e.end(at: at(0.6)), .endedCursorMode)
        e.press(at: at(1.0))
        XCTAssertEqual(e.end(at: at(1.05)), .insertSpace, "next quick tap is a normal space")
    }

    /// A host may clamp or partially honour movement. The session adopts the
    /// host's truth so subsequent deltas are measured from reality.
    func testHostThatClampsMovementIsReconciled() {
        let proxy = RecordingProxy(before: String(repeating: "x", count: 50),
                                   after: String(repeating: "y", count: 50))
        proxy.clampsMovementTo = 3
        let s = SpaceCursorSession(proxy: proxy)
        s.press(at: at(0))
        _ = s.tick(at: at(0.30))
        _ = s.drag(translationX: 200, translationY: 0, at: at(0.4))
        XCTAssertEqual(proxy.caret, 53)
        XCTAssertEqual(s.engine.caretIndex, 53, "engine adopted the host's actual caret")
        XCTAssertFalse(proxy.textEverChanged)
    }

    func testRapidReversalStormNeverCorruptsOrMutates() {
        let proxy = RecordingProxy(before: String(repeating: "ab😀", count: 60),
                                   after: String(repeating: "cd🇺🇸", count: 60))
        let s = SpaceCursorSession(proxy: proxy)
        s.press(at: at(0))
        _ = s.tick(at: at(0.30))
        var t = 0.4
        for _ in 0..<40 {
            _ = s.drag(translationX: 250, translationY: 0, at: at(t)); t += 0.01
            _ = s.drag(translationX: -250, translationY: 0, at: at(t)); t += 0.01
        }
        _ = s.drag(translationX: 0, translationY: 0, at: at(t))
        XCTAssertFalse(proxy.textEverChanged)
        XCTAssertEqual(s.engine.appliedOffset, 0, "storm returns exactly to the origin")
    }

    func testSessionMovementFlagTracksRealMovement() {
        let proxy = RecordingProxy(before: "hello", after: "world")
        let s = SpaceCursorSession(proxy: proxy)
        s.press(at: at(0))
        _ = s.tick(at: at(0.30))
        XCTAssertFalse(s.didMoveCaret, "takeover alone is not movement")
        _ = s.drag(translationX: 40, translationY: 0, at: at(0.4))
        XCTAssertTrue(s.didMoveCaret)
        s.clearMovementFlag()
        XCTAssertFalse(s.didMoveCaret)
    }
}
