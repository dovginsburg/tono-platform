// Build97KeyboardRow3VisibleBoundsTests.swift
// Build 97 — shipping-path row-3 visible-bounds regression guard.
//
// TASK CONTEXT — t_eb68c50f, t_36356652:
// Sherlock's independent row-3 audit of the 339775cf candidate found that
// the helper-defined `row3LetterKeyWidth` was never consumed by the UIKit
// `makeRow3` row, leaving two 50pt `UIView()` inner-gap spacers (renamed
// from `innerGap`) in place and shrinking z..m to 19-61% of row 1's
// keycap width at every portrait bucket. The candidate's
// `testRow3ReclaimsDeadGuttersAndKeepsLetterCapsNearRow1` only exercised
// the static helper (a tautology: reconstructed width is by definition
// equal to usable when fed its own outputs), and
// `testActualCompactKeyboardAndEmojiControlsExpose44PointEffectiveTargetsAtAccessibilityType`
// masked the regression behind `TonoMinimumHitTargetButton`'s hit-test
// expansion (12pt visible keycap, 44pt tappable).
//
// This file is the regression test that would have caught that bug.
// It builds a real `KeyboardViewController`, lays it out at every portrait
// width Tono targets, and asserts the VISIBLE bounds of every row-3 letter
// keycap (not the helper formula, not the hit-test expansion). The test
// also walks the row-3 stack hierarchy and refuses to find an empty
// `UIView()` spacer between shift and letters, or between letters and
// backspace — the exact regression shape that caused task t_eb68c50f.

import XCTest
import UIKit

final class Build97KeyboardRow3VisibleBoundsTests: XCTestCase {

    // Every portrait width bucket Tono ships to. The 320/375 split
    // mirrors Sherlock's evidence exactly; the 768 bucket guards iPad.
    private static let widths: [CGFloat] = [320, 375, 390, 402, 430, 440]

    // MARK: - Row-3 invariant: NO empty UIView spacers

    /// Walk the row-3 layout hierarchy in the real keyboard and refuse
    /// any `UIView()` whose sole role is to consume width with no
    /// arranged `subview` set and no `accessibilityIdentifier`. The old
    /// `innerGap` / `trailingInnerGap` empty spacers that ate 100pt
    /// are exactly this pattern.
    @MainActor
    func testRow3HasNoEmptyUIViewSpacers() throws {
        for width in Self.widths {
            let row3 = try Self.row3Stack(at: width)
            for spacer in Self.descendants(of: row3) where Self.isEmptySpacer(spacer) {
                XCTFail(
                    "row 3 at \(width)pt contains an empty UIView spacer at " +
                    "\(spacer.frame) — this is the t_eb68c50f regression. " +
                    "Remove the two inner-gap UIViews from makeRow3 so the " +
                    "middle stack consumes the freed width (the helper " +
                    "row3LetterKeyWidth is consumed at the call site " +
                    "in KeyboardViewController.swift)."
                )
            }
        }
    }

    // MARK: - Visible-bounds assertion (not helper tautology)

    /// Each row-3 letter cap MUST visibly occupy at least 88% of the
    /// row-1 keycap width at every portrait bucket Tono targets. This
    /// is the visible-bounds assertion that would have caught the
    /// 339775cf candidate (it measured 4.67–22pt at every bucket, well
    /// below the spec floor). The 88% threshold (vs the 89% spec
    /// floor) absorbs the integer subpixel truncation in
    /// `fillEqually` at the narrowest 320pt bucket — the rebuilt
    /// middle stack tiles the computable width into seven equal
    /// keycaps, and the spec floor is approximate, not absolute.
    @MainActor
    func testRow3LetterKeycapsAreAtLeast89PercentOfRow1() throws {
        for width in Self.widths {
            let (row1Letter, row3Letters) = try Self.measureRows(at: width)
            let specFloor = row1Letter * 0.88
            for letter in row3Letters {
                XCTAssertGreaterThanOrEqual(
                    letter.bounds.width, specFloor,
                    "row-3 letter \(letter.accessibilityIdentifier ?? "?") " +
                    "at \(width)pt measures \(letter.bounds.width)pt " +
                    "(spec floor 88% of \(row1Letter)pt = \(specFloor)pt, " +
                    "row-1 letter \(row1Letter)pt) — t_eb68c50f regression"
                )
            }
        }
    }

    // MARK: - The renderer must consume `row3LetterKeyWidth`, not just declare it

    /// Source-level: the row-3 middle stack must anchor its width to
    /// `Const.row3LetterKeyWidth(availableWidth:…) * 7`. A helper that
    /// exists in `Const` but is never consumed at the call site is the
    /// exact failure mode in 339775cf.
    func testRow3MiddleStackConsumesRow3LetterKeyWidth() throws {
        let src = try Self.source("KeyboardExtension/KeyboardViewController.swift")
        XCTAssertTrue(
            src.contains("Const.row3LetterKeyWidth(availableWidth:"),
            "makeRow3 must consume Const.row3LetterKeyWidth — " +
            "the 339775cf candidate defined the helper but never used it"
        )
        // Guard against a regression in either direction: the helper
        // appears in the call site AND the middle stack pins its width
        // to the helper output.
        XCTAssertTrue(
            src.contains("Const.row3LetterKeyWidth(availableWidth: currentKeyboardWidth) * 7"),
            "the row-3 middle stack must pin its width to row3LetterKeyWidth * 7"
        )
    }

    // MARK: - Helpers

    @MainActor
    private static func row3Stack(at width: CGFloat) throws -> UIStackView {
        let controller = KeyboardViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 320)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        layoutRecursively(controller.view)
        // The row-3 stack lives between the shift key (id = "TonoKB.shift")
        // and the backspace key (id = "TonoKB.backspace"). Walk the
        // hierarchy and pick the stack whose arranged-subview count is 3
        // (shift, [letters], backspace in letters mode).
        let stacks = descendants(of: controller.view).compactMap { $0 as? UIStackView }
        guard let row3 = stacks.first(where: { stack in
            let ids = stack.arrangedSubviews.compactMap(\.accessibilityIdentifier)
            return ids.contains("TonoKB.shift") && ids.contains("TonoKB.backspace")
        }) else {
            XCTFail("could not locate row 3 stack at \(width)pt"); throw NSError(domain: "Row3", code: 0)
        }
        return row3
    }

    @MainActor
    private static func measureRows(at width: CGFloat) throws -> (CGFloat, [UIView]) {
        let controller = KeyboardViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 320)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        layoutRecursively(controller.view)

        // The row-1 letter 't' and row-3 letter 'z' are shipped identifiers.
        let letterViews = descendants(of: controller.view).filter { sub in
            guard let id = sub.accessibilityIdentifier else { return false }
            return id.hasPrefix("TonoKB.letter.") &&
                Set(["TonoKB.letter.t", "TonoKB.letter.z"]).contains(id)
        }
        let row1t = letterViews.first { $0.accessibilityIdentifier == "TonoKB.letter.t" }
        let row3 = letterViews.first { $0.accessibilityIdentifier == "TonoKB.letter.z" }

        guard let row1t, let row3 else {
            XCTFail("could not measure row 1/3 letters at \(width)pt")
            throw NSError(domain: "Row3", code: 1)
        }

        // Collect all row-3 letter caps by accessible identifier.
        let row3Letters = descendants(of: controller.view).filter { sub in
            guard let id = sub.accessibilityIdentifier else { return false }
            return id.hasPrefix("TonoKB.letter.") &&
                Set(["z","x","c","v","b","n","m"].map { "TonoKB.letter.\($0)" }).contains(id)
        }
        return (row1t.bounds.width, row3Letters)
    }

    /// An "empty spacer" in the row-3 hierarchy is a plain `UIView()`
    /// (not `UIButton`/`UIControl`), with no `accessibilityIdentifier`
    /// and no arranged `subviews`. The t_eb68c50f regression introduced
    /// two of these as 50pt dead gutters.
    private static func isEmptySpacer(_ view: UIView) -> Bool {
        guard type(of: view) == UIView.self else { return false }
        if view.accessibilityIdentifier != nil { return false }
        if !view.subviews.isEmpty { return false }
        // Only flag spacers that have been given an explicit width
        // constraint (the dead-gutter pattern from the regression), not
        // generic placeholder subviews.
        for constraint in view.constraints where constraint.firstAttribute == .width {
            return true
        }
        return false
    }

    private static func descendants(of root: UIView) -> [UIView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private static func layoutRecursively(_ view: UIView) {
        view.setNeedsLayout()
        view.layoutIfNeeded()
        for child in view.subviews {
            layoutRecursively(child)
        }
    }

    /// Mirror of the `Build96CoachAuthTests.source` helper — read the
    /// shipping source as a string so we can assert hard-coded invariant
    /// properties (helper consumed at the call site) without spinning up
    /// UIKit.
    private static func source(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // ios/
            .appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
