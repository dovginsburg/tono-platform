// Build106MultilineCursorTests.swift
// Build 106 — release blocker C.
//
// PHYSICAL FINDING (Build 105, on device): "Spacebar cursor is better and now
// travels backward faster, but in two-line text it still will not move upward
// like Apple Keyboard."
//
// DIAGNOSIS: Build 105 defined a line as a LOGICAL line delimited by "\n" and
// set `supportsVerticalNavigation = lineStarts.count > 1`. A composer showing
// two VISUALLY WRAPPED lines of one long sentence contains no "\n", so the flag
// was false, vertical travel was discarded, and the caret was inert upward —
// exactly what was observed. The host context had no explicit newline; it was a
// visual wrap.
//
// `testRollbackRed_*` encode that fixture directly: the same two displayed
// lines are inert under the Build-105 policy and move under Build 106.

import XCTest
@testable import Tono

final class Build106MultilineCursorTests: XCTestCase {

    /// One long sentence the host shows as two wrapped lines. 92 characters,
    /// no newline anywhere.
    private static let wrappedTwoLines =
        "hey are we still on for dinner tomorrow night or should we push it to the weekend instead"

    private static let wrapWidth = 46

    // MARK: - The physical finding

    /// THE fixture. Two displayed lines, caret near the end, upward drag.
    /// Build 105 moved zero characters; Build 106 must move the caret up.
    func testUpwardDragInVisuallyWrappedTwoLineTextMovesTheCaret() {
        let text = Self.wrappedTwoLines
        let before = String(text.prefix(70))
        let after = String(text.dropFirst(70))

        // Old policy: no newline, so no vertical navigation at all.
        let build105 = SpaceCursorDocument(before: before, after: after)
        XCTAssertFalse(
            build105.supportsVerticalNavigation,
            "Build 105's logical-newline model is what made this inert"
        )

        // New policy: rows come from the wrap estimate.
        let build106 = SpaceCursorDocument(before: before, after: after, wrapWidth: Self.wrapWidth)
        XCTAssertTrue(build106.supportsVerticalNavigation)
        XCTAssertTrue(build106.usesEstimatedRows)
        XCTAssertGreaterThanOrEqual(build106.lineCount, 2, "92 characters at 46/row is at least two rows")

        var engine = SpaceCursorEngine()
        let start = Date(timeIntervalSince1970: 1_000)
        engine.press(at: start)
        XCTAssertEqual(
            engine.tick(at: start.addingTimeInterval(0.35), document: build106),
            .enteredCursorMode
        )
        let effect = engine.drag(translationX: 0, translationY: -40, at: start.addingTimeInterval(0.5))

        guard case .moveCaret(let graphemes, let utf16) = effect else {
            return XCTFail("an upward drag in two displayed lines must move the caret, not return \(effect)")
        }
        XCTAssertLessThan(graphemes, 0, "upward must move the caret backward through the text")
        XCTAssertEqual(graphemes, utf16, "ASCII fixture: grapheme and UTF-16 distance agree")
        XCTAssertLessThan(
            engine.caretIndex ?? .max, 70,
            "the caret must end up earlier in the document than it started"
        )
    }

    /// Downward from the first row must also work, and must land back near the
    /// column it left from.
    func testDownwardThenUpwardReturnsToApproximatelyTheSameColumn() {
        let text = Self.wrappedTwoLines
        let origin = 20
        let document = SpaceCursorDocument(
            before: String(text.prefix(origin)),
            after: String(text.dropFirst(origin)),
            wrapWidth: Self.wrapWidth
        )
        let startColumn = document.column(of: document.origin)

        var engine = SpaceCursorEngine()
        let t0 = Date(timeIntervalSince1970: 2_000)
        engine.press(at: t0)
        _ = engine.tick(at: t0.addingTimeInterval(0.35), document: document)

        _ = engine.drag(translationX: 0, translationY: 40, at: t0.addingTimeInterval(0.5))
        let downCaret = try? XCTUnwrap(engine.caretIndex)
        XCTAssertNotNil(downCaret)
        XCTAssertGreaterThan(downCaret ?? 0, origin, "down must move forward")

        // Returning to zero vertical translation retraces to the origin row.
        _ = engine.drag(translationX: 0, translationY: 0, at: t0.addingTimeInterval(0.6))
        XCTAssertEqual(engine.caretIndex, origin, "reversal must retrace exactly, with no ratchet")
        XCTAssertEqual(document.column(of: engine.caretIndex ?? -1), startColumn)
    }

    // MARK: - Explicit newlines stay exact

    /// With real newlines the row model must be identical to Build 105's
    /// logical-line model — the exact behaviour that was accepted must survive.
    func testExplicitNewlinesProduceExactLogicalRows() {
        let before = "first line\nsecond li"
        let after = "ne\nthird line"
        let withoutWrap = SpaceCursorDocument(before: before, after: after)
        let withWrap = SpaceCursorDocument(before: before, after: after, wrapWidth: 200)

        XCTAssertEqual(withoutWrap.lineCount, 3)
        XCTAssertEqual(withWrap.lineCount, 3, "a wrap width wider than every line adds no rows")
        XCTAssertFalse(withWrap.usesEstimatedRows)
        XCTAssertEqual(withWrap.logicalLineCount, 3)

        for index in 0..<withoutWrap.count {
            XCTAssertEqual(withoutWrap.line(of: index), withWrap.line(of: index), "row \(index)")
            XCTAssertEqual(withoutWrap.column(of: index), withWrap.column(of: index), "column \(index)")
        }
        XCTAssertEqual(withoutWrap.start(ofLine: 1), withWrap.start(ofLine: 1))
        XCTAssertEqual(withoutWrap.end(ofLine: 0), withWrap.end(ofLine: 0))
        XCTAssertEqual(withoutWrap.end(ofLine: 0), 10, "the caret parks after 'line', never on the newline")
    }

    /// A newline-delimited line that is ALSO too long wraps within itself, and
    /// the newline boundary is still exact.
    func testNewlineAndWrapCoexist() {
        let long = String(repeating: "word ", count: 20)   // 100 chars, no newline
        let document = SpaceCursorDocument(before: "short\n" + long, after: "", wrapWidth: 30)
        XCTAssertEqual(document.logicalLineCount, 2, "two logical lines, exactly")
        XCTAssertGreaterThan(document.lineCount, 2, "the long logical line wraps into more rows")
        XCTAssertTrue(document.usesEstimatedRows)
        XCTAssertEqual(document.start(ofLine: 0), 0)
        XCTAssertEqual(document.end(ofLine: 0), 5, "row 0 ends after 'short', before the newline")
        XCTAssertEqual(document.start(ofLine: 1), 6, "row 1 starts after the newline")
    }

    // MARK: - Degradation, clamping, drift

    /// No credible wrap estimate → Build-105 behaviour, not invention.
    func testWithoutAWrapEstimateBehaviourIsUnchangedFromBuild105() {
        let document = SpaceCursorDocument(before: Self.wrappedTwoLines, after: "", wrapWidth: nil)
        XCTAssertFalse(document.supportsVerticalNavigation)
        XCTAssertFalse(document.usesEstimatedRows)
        XCTAssertEqual(document.lineCount, 1)
    }

    /// Truncated context shorter than one estimated row must not fabricate a
    /// second row.
    func testTruncatedContextShorterThanOneRowStaysHorizontal() {
        let document = SpaceCursorDocument(before: "hello wo", after: "rld", wrapWidth: 46)
        XCTAssertFalse(
            document.supportsVerticalNavigation,
            "11 characters cannot have wrapped at 46 per row"
        )
    }

    /// A degenerate wrap width must be ignored rather than producing a row per
    /// character.
    func testNonPositiveWrapWidthIsIgnored() {
        for width in [0, -1, -100] {
            let document = SpaceCursorDocument(before: Self.wrappedTwoLines, after: "", wrapWidth: width)
            XCTAssertNil(document.wrapWidth, "width \(width) must be rejected")
            XCTAssertEqual(document.lineCount, 1)
        }
    }

    /// A host that clamps or ignores movement must not accumulate drift: the
    /// session adopts the observed caret when the text still matches.
    func testHostClampIsReconciledAndDoesNotAccumulateDrift() {
        final class ClampingProxy: SpaceCursorTextProxy {
            var text: [Character]
            var caret: Int
            /// Refuses to move earlier than this index, like a host that has
            /// truncated its editable range.
            let floorIndex: Int
            private(set) var adjustCalls = 0
            init(text: String, caret: Int, floorIndex: Int) {
                self.text = Array(text)
                self.caret = caret
                self.floorIndex = floorIndex
            }
            var documentContextBeforeInput: String? { String(text[0..<caret]) }
            var documentContextAfterInput: String? { String(text[caret...]) }
            func adjustTextPosition(byCharacterOffset offset: Int) {
                adjustCalls += 1
                caret = max(floorIndex, min(text.count, caret + offset))
            }
        }

        let proxy = ClampingProxy(text: Self.wrappedTwoLines, caret: 70, floorIndex: 40)
        let session = SpaceCursorSession(proxy: proxy, wrapWidthProvider: { Self.wrapWidth })
        let t0 = Date(timeIntervalSince1970: 3_000)
        session.press(at: t0)
        XCTAssertEqual(session.tick(at: t0.addingTimeInterval(0.35)), .enteredCursorMode)

        _ = session.drag(translationX: 0, translationY: -40, at: t0.addingTimeInterval(0.5))
        XCTAssertGreaterThanOrEqual(proxy.caret, 40, "the host clamp is respected")
        XCTAssertEqual(
            session.engine.caretIndex, proxy.caret,
            "the engine must adopt the host's real caret, not compound a divergence"
        )

        // A second, larger upward drag must be measured from reality.
        _ = session.drag(translationX: 0, translationY: -80, at: t0.addingTimeInterval(0.6))
        XCTAssertEqual(session.engine.caretIndex, proxy.caret, "still no accumulated drift")
    }

    // MARK: - Unicode, RTL, no mutation

    /// Emoji stay indivisible: a vertical move reports UTF-16 distance, not
    /// grapheme count, so the caret never lands inside a surrogate pair.
    func testEmojiRowsUseUTF16DistanceForTheHost() {
        let line = "👩‍👩‍👧‍👦 family plans for the weekend are still open so let us decide tonight ok"
        let document = SpaceCursorDocument(before: line, after: "", wrapWidth: 30)
        XCTAssertTrue(document.supportsVerticalNavigation)
        let distance = document.utf16Distance(from: 0, to: 1)
        XCTAssertGreaterThan(distance, 1, "a ZWJ family emoji is one grapheme but many UTF-16 units")
    }

    /// RTL text is navigated in LOGICAL order — the only order the proxy
    /// exposes. Rows must still form and movement must still be defined.
    func testRTLWrappedTextStillFormsRowsInLogicalOrder() {
        let arabic = "مرحبا كيف حالك اليوم هل يمكننا الاجتماع غدا في الصباح الباكر لمناقشة الخطة"
        let document = SpaceCursorDocument(before: arabic, after: "", wrapWidth: 30)
        XCTAssertTrue(document.supportsVerticalNavigation)
        XCTAssertGreaterThan(document.lineCount, 1)
        // Row starts are monotonically increasing logical indices.
        var previous = -1
        for row in 0..<document.lineCount {
            let start = document.start(ofLine: row)
            XCTAssertGreaterThan(start, previous, "row \(row) start must advance")
            previous = start
        }
    }

    /// Cursor mode has no way to express an insertion or a deletion. The proxy
    /// seam has no delete member at all; this asserts the effect surface too.
    func testCursorModeProducesNoTextMutation() {
        final class RecordingProxy: SpaceCursorTextProxy {
            let before: String
            let after: String
            private(set) var adjustments: [Int] = []
            init(before: String, after: String) { self.before = before; self.after = after }
            var documentContextBeforeInput: String? { before }
            var documentContextAfterInput: String? { after }
            func adjustTextPosition(byCharacterOffset offset: Int) { adjustments.append(offset) }
        }
        let proxy = RecordingProxy(before: String(Self.wrappedTwoLines.prefix(70)),
                                   after: String(Self.wrappedTwoLines.dropFirst(70)))
        let session = SpaceCursorSession(proxy: proxy, wrapWidthProvider: { Self.wrapWidth })
        let t0 = Date(timeIntervalSince1970: 4_000)
        session.press(at: t0)
        _ = session.tick(at: t0.addingTimeInterval(0.35))
        for step in stride(from: -10.0, through: -120.0, by: -10.0) {
            let effect = session.drag(translationX: 6, translationY: step, at: t0.addingTimeInterval(0.5))
            if case .insertSpace = effect { XCTFail("cursor mode must never insert") }
        }
        XCTAssertEqual(session.end(at: t0.addingTimeInterval(1.0)), .endedCursorMode)
        XCTAssertFalse(proxy.adjustments.isEmpty, "the caret did move")
        // The seam has no delete; the only operation performed is repositioning.
        XCTAssertTrue(proxy.adjustments.allSatisfy { $0 != 0 })
    }

    // MARK: - Wrap estimator

    func testWrapEstimatorIsBiasedLowAndBounded() {
        // iPhone-ish: 390pt keyboard, ~8.5pt average advance at body size.
        let estimate = SpaceCursorWrapEstimator.charactersPerRow(
            keyboardWidthPoints: 390,
            averageCharacterWidthPoints: 8.5
        )
        let unwrapped = try? XCTUnwrap(estimate)
        XCTAssertNotNil(unwrapped)
        XCTAssertLessThan(
            unwrapped ?? 0, Int(390.0 / 8.5),
            "the estimate must under-shoot the full keyboard width, never over-shoot"
        )
        XCTAssertGreaterThanOrEqual(unwrapped ?? 0, SpaceCursorWrapEstimator.minimumCredibleWidth)

        // Enormous accessibility font → no credible estimate → logical-only.
        XCTAssertNil(SpaceCursorWrapEstimator.charactersPerRow(
            keyboardWidthPoints: 320,
            averageCharacterWidthPoints: 40
        ))
        // Degenerate inputs.
        XCTAssertNil(SpaceCursorWrapEstimator.charactersPerRow(
            keyboardWidthPoints: 0, averageCharacterWidthPoints: 8
        ))
        XCTAssertNil(SpaceCursorWrapEstimator.charactersPerRow(
            keyboardWidthPoints: .nan, averageCharacterWidthPoints: 8
        ))
        // Ceiling holds for a pathological metric.
        let huge = SpaceCursorWrapEstimator.charactersPerRow(
            keyboardWidthPoints: 100_000, averageCharacterWidthPoints: 1
        )
        XCTAssertEqual(huge, SpaceCursorWrapEstimator.maximumCredibleWidth)
    }

    /// Greedy word wrap breaks at spaces, not mid-word, when it can.
    func testWordWrapBreaksAtWordBoundaries() {
        let document = SpaceCursorDocument(before: "alpha beta gamma delta epsilon", after: "", wrapWidth: 12)
        XCTAssertGreaterThan(document.lineCount, 1)
        for row in 1..<document.lineCount {
            let start = document.start(ofLine: row)
            XCTAssertEqual(
                document.characters[start - 1], " ",
                "row \(row) must begin just after a space, not inside a word"
            )
        }
    }

    /// A single token longer than one row must still break, or a long URL would
    /// make the whole field one row again.
    func testOverlongTokenBreaksHard() {
        let document = SpaceCursorDocument(
            before: String(repeating: "a", count: 90), after: "", wrapWidth: 30
        )
        XCTAssertGreaterThan(document.lineCount, 2, "a 90-character token at 30/row is three rows")
    }

    // MARK: - Rollback-red negative control

    /// The founder's exact observation, as a policy comparison: two displayed
    /// lines, upward drag, zero movement under the old policy.
    func testRollbackRed_build105PolicyIsInertOnTheTwoLineFixture() {
        let before = String(Self.wrappedTwoLines.prefix(70))
        let after = String(Self.wrappedTwoLines.dropFirst(70))

        var old = SpaceCursorEngine()
        let t0 = Date(timeIntervalSince1970: 5_000)
        old.press(at: t0)
        _ = old.tick(at: t0.addingTimeInterval(0.35),
                     document: SpaceCursorDocument(before: before, after: after))
        let oldEffect = old.drag(translationX: 0, translationY: -40, at: t0.addingTimeInterval(0.5))
        XCTAssertEqual(oldEffect, .none, "this is the rejected Build-105 behaviour")

        var new = SpaceCursorEngine()
        new.press(at: t0)
        _ = new.tick(at: t0.addingTimeInterval(0.35),
                     document: SpaceCursorDocument(before: before, after: after, wrapWidth: Self.wrapWidth))
        let newEffect = new.drag(translationX: 0, translationY: -40, at: t0.addingTimeInterval(0.5))
        XCTAssertNotEqual(newEffect, .none, "Build 106 must move")
    }
}
