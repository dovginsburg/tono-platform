// Build96ToneChipStripTests.swift
// Build 96 — website-token tone-chip strip.
//
// When TONO is tapped the suggestion strip shows exactly three color-coded
// chips: the fixed Safer token plus exactly two configured optional tokens,
// each painted with its canonical tonoit.com semantic accent (no hidden
// generation). The TONO control stays anchored to the leading edge and the
// strip keeps its standard height.
//
// This exercises the real `KeyboardViewController` UIKit hierarchy — there
// is no source-regex escape hatch.

import XCTest
import UIKit
@testable import Tono

final class Build96ToneChipStripTests: XCTestCase {

    @MainActor
    func testToneStripShowsThreeColorCodedTokensWithTonoAnchoredLeft() throws {
        // Deterministic configuration: Safer is fixed, two optional tokens.
        CoachVariantSettingsStore().save(CoachVariantSettings(enabled: [.clearer, .funnier]))

        let controller = KeyboardViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 320)
        controller.view.layoutIfNeeded()

        let coach = try XCTUnwrap(
            Self.control("TonoKB.coachButton", in: controller.view) as? UIButton,
            "the TONO control must exist"
        )
        // One tap on TONO reveals the tone chips (it must NOT issue a request).
        coach.sendActions(for: .touchUpInside)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let strip = try XCTUnwrap(
            Self.view("TonoKB.candidates", in: controller.view) as? UIStackView
        )
        let chips = strip.arrangedSubviews
            .compactMap { $0 as? UIButton }
            .filter { !$0.isHidden }
        XCTAssertEqual(chips.count, 3, "Safer fixed + exactly two configured tokens = three chips")

        // Each chip is color-coded with its canonical tonoit.com accent token.
        let expected = ["safer", "clearer", "funnier"]
        for (index, chip) in chips.enumerated() {
            let token = try XCTUnwrap(TonoCoachPalette.axis(expected[index]))
            let background = try XCTUnwrap(chip.backgroundColor, "chip \(expected[index]) must have a background")
            Self.assertColorsClose(
                background,
                token.accent.withAlphaComponent(Self.chipAccentAlpha),
                message: "chip \(expected[index]) must be color-coded with its tonoit.com accent token, not a neutral fill"
            )
        }

        // TONO stays anchored to the leading edge, left of the tone chips.
        let bar = try XCTUnwrap(Self.view("TonoKB.topBar", in: controller.view))
        let coachFrame = coach.convert(coach.bounds, to: bar)
        let stripFrame = strip.convert(strip.bounds, to: bar)
        XCTAssertLessThanOrEqual(coachFrame.minX, 10, "TONO must be anchored to the leading edge")
        XCTAssertLessThan(coachFrame.minX, stripFrame.minX, "TONO must sit left of the tone chips")

        // Standard height is preserved.
        XCTAssertEqual(bar.bounds.height, 46, accuracy: 0.5, "the strip must keep its standard height")
    }

    /// One tap on TONO must reveal the chips without issuing any request:
    /// the request is deferred until a specific tone chip is tapped
    /// (one tap → one request → one provider call → selected tone).
    @MainActor
    func testTonoToggleRevealsChipsWithoutStartingCoach() throws {
        let controller = KeyboardViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 320)
        controller.view.layoutIfNeeded()

        let coach = try XCTUnwrap(Self.control("TonoKB.coachButton", in: controller.view) as? UIButton)
        coach.sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()

        // The Coach loading/results panels only exist once a request fires.
        XCTAssertNil(Self.view("TonoKB.coachLoading", in: controller.view), "toggling TONO must not begin a request")
        XCTAssertNil(Self.view("TonoKB.coachResults", in: controller.view), "toggling TONO must not present results")
    }

    // MARK: - Helpers

    private static let chipAccentAlpha: CGFloat = 0.18

    private static func control(_ identifier: String, in root: UIView) -> UIControl? {
        descendants(of: root).compactMap { $0 as? UIControl }.first { $0.accessibilityIdentifier == identifier }
    }

    private static func view(_ identifier: String, in root: UIView) -> UIView? {
        ([root] + descendants(of: root)).first { $0.accessibilityIdentifier == identifier }
    }

    private static func descendants(of root: UIView) -> [UIView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private static func assertColorsClose(
        _ lhs: UIColor,
        _ rhs: UIColor,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var lr: CGFloat = 0, lg: CGFloat = 0, lb: CGFloat = 0, la: CGFloat = 0
        var rr: CGFloat = 0, rg: CGFloat = 0, rb: CGFloat = 0, ra: CGFloat = 0
        let resolved = UITraitCollection(userInterfaceStyle: .light)
        lhs.resolvedColor(with: resolved).getRed(&lr, green: &lg, blue: &lb, alpha: &la)
        rhs.resolvedColor(with: resolved).getRed(&rr, green: &rg, blue: &rb, alpha: &ra)
        XCTAssertEqual(lr, rr, accuracy: 0.03, message, file: file, line: line)
        XCTAssertEqual(lg, rg, accuracy: 0.03, message, file: file, line: line)
        XCTAssertEqual(lb, rb, accuracy: 0.03, message, file: file, line: line)
        XCTAssertEqual(la, ra, accuracy: 0.03, message, file: file, line: line)
    }
}
