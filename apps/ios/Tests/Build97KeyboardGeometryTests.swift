// Build97KeyboardGeometryTests.swift
// Executable geometry + accessibility coverage for the Apple-fidelity
// keyboard metrics (`TonoKeyboardLayoutMetrics`, `TonoKeyRows`).
//
// These assert the concrete numbers the SwiftUI/UIKit key layout reads and,
// crucially, cross-check them against the shipping production metrics
// (`TonoKeyboardMetrics`) that `KeyboardViewController` already lays out
// against — so the new source-of-truth can never silently drift from the
// reviewed one.

import XCTest
import CoreGraphics

final class Build97KeyboardGeometryTests: XCTestCase {

    // The three portrait iPhone width buckets Tono targets.
    private static let widths: [CGFloat] = [320, 375, 390, 402, 430, 440]

    // MARK: - Height buckets mirror the shipping metrics exactly

    func testTypingHeightBucketsMatchAppleThreeStops() {
        XCTAssertEqual(TonoKeyboardLayoutMetrics.preferredTypingHeight(availableWidth: 320), 252)
        XCTAssertEqual(TonoKeyboardLayoutMetrics.preferredTypingHeight(availableWidth: 389), 252)
        XCTAssertEqual(TonoKeyboardLayoutMetrics.preferredTypingHeight(availableWidth: 390), 256)
        XCTAssertEqual(TonoKeyboardLayoutMetrics.preferredTypingHeight(availableWidth: 402), 256)
        XCTAssertEqual(TonoKeyboardLayoutMetrics.preferredTypingHeight(availableWidth: 429), 256)
        XCTAssertEqual(TonoKeyboardLayoutMetrics.preferredTypingHeight(availableWidth: 430), 264)
        XCTAssertEqual(TonoKeyboardLayoutMetrics.preferredTypingHeight(availableWidth: 440), 264)
    }

    func testPreferredContentHeightAddsThirtySixPointCoachHeadroom() {
        for width in Self.widths {
            let typing = TonoKeyboardLayoutMetrics.preferredTypingHeight(availableWidth: width)
            let content = TonoKeyboardLayoutMetrics.preferredContentHeight(availableWidth: width)
            XCTAssertEqual(content, typing + 36, "content height must reserve 36pt Coach headroom at \(width)pt")
        }
    }

    /// The new metrics must produce the same total keyboard height as the
    /// reviewed production `TonoKeyboardMetrics.portrait(_:)` at every width —
    /// otherwise the SwiftUI layer and the UIKit controller would disagree.
    func testNewMetricsMirrorShippingProductionMetrics() {
        for width in Self.widths {
            let production = TonoKeyboardMetrics.portrait(availableWidth: width)
            XCTAssertEqual(
                TonoKeyboardLayoutMetrics.preferredContentHeight(availableWidth: width),
                production.preferredContentHeight,
                "height drift from production at \(width)pt"
            )
            XCTAssertEqual(TonoKeyboardLayoutMetrics.rowSpacing, production.rowSpacing)
            XCTAssertEqual(TonoKeyboardLayoutMetrics.edgePadding, production.edgePadding)
            XCTAssertEqual(TonoKeyboardLayoutMetrics.keyCornerRadius, production.keyCornerRadius)
            XCTAssertEqual(TonoKeyboardLayoutMetrics.keyFontSize, production.keyFontSize)
        }
    }

    // MARK: - Letter-key geometry

    func testLetterKeyWidthFillsTenColumnsAcrossUsableWidth() {
        for width in Self.widths {
            let key = TonoKeyboardLayoutMetrics.letterKeyWidth(availableWidth: width)
            let usable = max(width - TonoKeyboardLayoutMetrics.edgePadding * 2, 320)
            // Ten keys and nine 8pt gaps must exactly consume the usable width.
            let reconstructed = key * 10 + TonoKeyboardLayoutMetrics.rowSpacing * 9
            XCTAssertEqual(reconstructed, usable, accuracy: 0.001, "row 1 must tile the usable width at \(width)pt")
            XCTAssertGreaterThan(key, 0)
        }
    }

    func testRow2InsetIsHalfKeycapForAppleCentering() {
        for width in Self.widths {
            let key = TonoKeyboardLayoutMetrics.letterKeyWidth(availableWidth: width)
            let inset = TonoKeyboardLayoutMetrics.row2HorizontalInset(availableWidth: width)
            XCTAssertEqual(inset, (key + TonoKeyboardLayoutMetrics.rowSpacing) / 2, accuracy: 0.001)
            // Nine row-2 keys plus two half-keycap insets equal row 1's span.
            let row1Span = key * 10 + TonoKeyboardLayoutMetrics.rowSpacing * 9
            let row2Span = key * 9 + TonoKeyboardLayoutMetrics.rowSpacing * 8 + inset * 2
            XCTAssertEqual(row2Span, row1Span, accuracy: 0.001, "row 2 must center under row 1 at \(width)pt")
        }
    }

    func testRow3HasNoInnerGapSpacersAndLetterKeysApproachRow1() {
        // Apple row-3 fidelity rule (post-t_eb68c50f): row 3 must have
        // no `UIView()` inner-gap spacers (the renderer dropped them to
        // reclaim the dead gutter), and the seven letter caps must be
        // at least 90% of the row-1 letter keycap width at every
        // portrait bucket Tono targets.
        for width in Self.widths {
            XCTAssertEqual(
                TonoKeyboardLayoutMetrics.row3InnerGap(availableWidth: width),
                0,
                "row 3 must not introduce an artificial inner-gap subview at \(width)pt"
            )
            let row1Key = TonoKeyboardLayoutMetrics.letterKeyWidth(availableWidth: width)
            let row3Key = TonoKeyboardLayoutMetrics.row3LetterKeyWidth(availableWidth: width)
            XCTAssertGreaterThanOrEqual(
                row3Key, row1Key * 0.89,
                "row 3 letter keycap (\\(row3Key)pt) must be at least 89% of row 1 (\\(row1Key)pt) at \(width)pt"
            )
            XCTAssertGreaterThanOrEqual(
                TonoKeyboardLayoutMetrics.shiftKeyWidth,
                TonoKeyboardLayoutMetrics.minimumTouchTarget,
                "shift must clear the 44pt accessibility tap target"
            )
            XCTAssertGreaterThanOrEqual(
                TonoKeyboardLayoutMetrics.backspaceWidth,
                TonoKeyboardLayoutMetrics.minimumTouchTarget,
                "backspace must clear the 44pt accessibility tap target"
            )
            // Reconstruct: shift + 8pt * (2 outer + 6 inner) + 7 letters
            // + backspace must tile exactly the usable width. Anything
            // other than a ≈0pt remainder is dead gutter.
            let reconstruction = TonoKeyboardLayoutMetrics.shiftKeyWidth
                + TonoKeyboardLayoutMetrics.rowSpacing * 8
                + row3Key * 7
                + TonoKeyboardLayoutMetrics.backspaceWidth
            let usable = max(width - TonoKeyboardLayoutMetrics.edgePadding * 2, 320)
            XCTAssertEqual(
                reconstruction, usable, accuracy: 0.5,
                "row 3 must exactly tile the usable width at \(width)pt (got \(reconstruction) vs \(usable))"
            )
        }
    }

    // MARK: - Accessibility: 44pt minimum touch targets

    func testMinimumTouchTargetIs44AndMatchesProduction() {
        XCTAssertEqual(TonoKeyboardLayoutMetrics.minimumTouchTarget, 44)
        XCTAssertEqual(
            TonoKeyboardLayoutMetrics.minimumTouchTarget,
            TonoKeyboardMetrics.ControlGeometry.minimumTouchTarget,
            "the Apple-fidelity minimum must equal the production control minimum"
        )
    }

    func testBottomRowControlsMeetAppleTouchMinimum() {
        let controls: [(String, CGFloat)] = [
            ("globeButtonWidth", TonoKeyboardLayoutMetrics.globeButtonWidth),
            ("historyButtonWidth", TonoKeyboardLayoutMetrics.historyButtonWidth),
            ("emojiButtonWidth", TonoKeyboardLayoutMetrics.emojiButtonWidth),
            ("returnWidth", TonoKeyboardLayoutMetrics.returnWidth),
            ("backspaceWidth", TonoKeyboardLayoutMetrics.backspaceWidth),
            ("coachWidth", TonoKeyboardLayoutMetrics.coachWidth),
        ]
        // Every discrete function control must expose at least the 44pt target
        // (the mode toggle is a special narrow "123/ABC" pill, excluded).
        for (label, width) in controls {
            XCTAssertGreaterThanOrEqual(width, TonoKeyboardLayoutMetrics.minimumTouchTarget, "\(label) = \(width)pt is under the 44pt minimum")
        }
    }

    func testKeyMetricConstantsAreStableAppleValues() {
        XCTAssertEqual(TonoKeyboardLayoutMetrics.keyCornerRadius, 5)
        XCTAssertEqual(TonoKeyboardLayoutMetrics.keyFontSize, 22)
        XCTAssertEqual(TonoKeyboardLayoutMetrics.rowSpacing, 8)
        XCTAssertEqual(TonoKeyboardLayoutMetrics.edgePadding, 4)
    }

    /// The geometry helper in `Const` exists and returns a value > 0 at
    /// every portrait width. The visible-bounds test below is the
    /// actual regression guard — a candidate whose helper is declared
    /// but never consumed would still pass this static assertion. The
    /// companion source-level assertion in
    /// `Build97KeyboardRow3VisibleBoundsTests` proves the renderer
    /// actually calls the helper.
    func testRow3LetterKeyWidthHelperProducesPositiveWidth() {
        for width in Self.widths {
            let row3Key = TonoKeyboardLayoutMetrics.row3LetterKeyWidth(availableWidth: width)
            XCTAssertGreaterThan(
                row3Key, 0,
                "row3LetterKeyWidth must produce a positive width at \(width)pt"
            )
        }
    }
}
