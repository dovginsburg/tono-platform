import XCTest
import UIKit

final class KeyboardVisualStyleTests: XCTestCase {
    func testPortraitMetricsKeepAppleSizedTypingRowsAcrossPhoneWidths() {
        let compact = TonoKeyboardMetrics.portrait(availableWidth: 375)
        let regular = TonoKeyboardMetrics.portrait(availableWidth: 402)
        let large = TonoKeyboardMetrics.portrait(availableWidth: 440)

        XCTAssertEqual(compact.preferredContentHeight, 252)
        XCTAssertEqual(regular.preferredContentHeight, 256)
        XCTAssertEqual(large.preferredContentHeight, 264)
        XCTAssertGreaterThanOrEqual(compact.keyMinHeight, 44)
        XCTAssertGreaterThanOrEqual(regular.keyMinHeight, 44)
        XCTAssertGreaterThanOrEqual(large.keyMinHeight, 44)
        XCTAssertEqual(regular.rowSpacing, 6)
        XCTAssertEqual(regular.keyFontSize, 22)
        XCTAssertEqual(regular.keyCornerRadius, 5)
    }

    func testCoachFitsWithoutShrinkingTypingRows() {
        let metrics = TonoKeyboardMetrics.portrait(availableWidth: 402)
        let typingRowsHeight = metrics.keyMinHeight * 4 + metrics.rowSpacing * 3

        XCTAssertEqual(typingRowsHeight, 194)
        XCTAssertGreaterThanOrEqual(metrics.topBarHeight, 44)
        XCTAssertGreaterThanOrEqual(metrics.coachControlHeight, 36)
        XCTAssertGreaterThanOrEqual(
            metrics.preferredContentHeight,
            metrics.topBarHeight + typingRowsHeight
        )
    }

    func testApprovedBuild77KeyGeometryKeepsCompactKeysUsable() {
        let compact = TonoKeyboardMetrics.portrait(availableWidth: 320)
        let regular = TonoKeyboardMetrics.portrait(availableWidth: 402)

        XCTAssertEqual(compact.keyMinHeight, 44)
        XCTAssertEqual(compact.rowSpacing, 6)
        XCTAssertEqual(compact.edgePadding, 4)
        XCTAssertGreaterThanOrEqual(compact.letterKeyWidth(availableWidth: 320), 25)
        XCTAssertGreaterThanOrEqual(regular.letterKeyWidth(availableWidth: 402), 34)
    }

    func testHalfGapHitExpansionHasNoDeadZoneOrOverlap() {
        let spacing: CGFloat = 6
        let left = CGRect(x: 0, y: 0, width: 34, height: 44)
        let right = CGRect(x: 40, y: 0, width: 34, height: 44)
        let leftHit = TonoKeyHitGeometry.expandedFrame(left, spacing: spacing)
        let rightHit = TonoKeyHitGeometry.expandedFrame(right, spacing: spacing)

        XCTAssertEqual(leftHit.maxX, rightHit.minX)
        XCTAssertEqual(leftHit.intersection(rightHit).width, 0)
        XCTAssertTrue(leftHit.contains(CGPoint(x: 36.9, y: 22)))
        XCTAssertTrue(rightHit.contains(CGPoint(x: 37.1, y: 22)))
    }

    func testRapidRepeatedKeyActionsAreNotCoalesced() {
        let button = TonoKeyboardButton(frame: CGRect(x: 0, y: 0, width: 34, height: 44))
        var eventCount = 0
        button.addAction(UIAction { _ in eventCount += 1 }, for: .touchUpInside)

        for _ in 0..<100 {
            button.sendActions(for: .touchUpInside)
        }

        XCTAssertEqual(eventCount, 100)
        XCTAssertTrue(button.point(inside: CGPoint(x: -2.9, y: 22), with: nil))
    }

    func testCapsLockRequiresIntentionalBoundedDoubleTap() {
        var shift = TonoShiftStateMachine()
        shift.manualTap(at: 10)
        XCTAssertEqual(shift.state, .oneShotUppercase)
        shift.manualTap(at: 10.2)
        XCTAssertEqual(shift.state, .capsLock)

        shift.manualTap(at: 11)
        XCTAssertEqual(shift.state, .lowercase)
        shift.manualTap(at: 12)
        shift.manualTap(at: 12 + TonoShiftStateMachine.doubleTapInterval + 0.01)
        XCTAssertEqual(shift.state, .lowercase, "slow repeated taps must not enable Caps Lock")
    }

    func testAutoCapitalizationAndLifecycleCannotPromoteCapsLock() {
        var shift = TonoShiftStateMachine()
        shift.applyAutoCapitalization(true)
        XCTAssertEqual(shift.state, .oneShotUppercase)
        XCTAssertTrue(shift.isAutomaticOneShot)

        shift.manualTap(at: 20)
        XCTAssertEqual(shift.state, .lowercase, "manual tap cancels auto-shift; it is not tap one of Caps Lock")
        shift.manualTap(at: 20.1)
        XCTAssertEqual(shift.state, .oneShotUppercase)
        shift.invalidatePendingDoubleTap()
        shift.manualTap(at: 20.2)
        XCTAssertEqual(shift.state, .lowercase, "layout rebuild invalidates a stale first tap")

        shift.applyAutoCapitalization(true)
        shift.consumeEligibleLetter()
        XCTAssertEqual(shift.state, .lowercase)
        shift.resetForExtensionLifecycle()
        XCTAssertEqual(shift.state, .lowercase)
        XCTAssertFalse(shift.isAutomaticOneShot)
    }

    func testCoachGeometryIsFixedAcrossWidthsTitlesAndControlStates() {
        let expectedSize = CGSize(width: 96, height: 44)
        for width in [320.0, 375.0, 402.0, 812.0] {
            let metrics = TonoKeyboardMetrics.portrait(availableWidth: width)
            XCTAssertEqual(metrics.coachControlWidth, expectedSize.width)
            XCTAssertEqual(metrics.coachControlHeight, expectedSize.height)
        }

        let button = TonoCoachButton(type: .custom)
        XCTAssertEqual(button.intrinsicContentSize, expectedSize)
        button.setTitle("Coach", for: .normal)
        button.isHighlighted = true
        XCTAssertEqual(button.intrinsicContentSize, expectedSize)
        button.isHighlighted = false
        button.isEnabled = false
        button.setTitle("Retrying…", for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 34, weight: .semibold)
        XCTAssertEqual(button.intrinsicContentSize, expectedSize)
        XCTAssertTrue(button.titleLabel?.adjustsFontSizeToFitWidth == true)
        XCTAssertLessThanOrEqual(button.titleLabel?.minimumScaleFactor ?? 1, 0.75)
    }

    func testDefaultHostAppearanceUsesSystemDarkWhenExtensionTraitsStayLight() {
        let resolved = TonoKeyboardAppearanceResolver.resolve(
            hostAppearance: .default,
            extensionStyle: .light,
            systemStyle: .dark
        )

        XCTAssertEqual(resolved, .dark)
    }

    func testDefaultHostAppearanceKeepsSystemLightUnchanged() {
        let resolved = TonoKeyboardAppearanceResolver.resolve(
            hostAppearance: .default,
            extensionStyle: .light,
            systemStyle: .light
        )

        XCTAssertEqual(resolved, .light)
    }

    func testExplicitHostAppearanceWinsOverSystemAppearance() {
        XCTAssertEqual(
            TonoKeyboardAppearanceResolver.resolve(
                hostAppearance: .light,
                extensionStyle: .dark,
                systemStyle: .dark
            ),
            .light
        )
        XCTAssertEqual(
            TonoKeyboardAppearanceResolver.resolve(
                hostAppearance: .dark,
                extensionStyle: .light,
                systemStyle: .light
            ),
            .dark
        )
    }

    func testCoachPaletteKeepsWhiteTextAtAccessibleContrastInEveryStateAndAppearance() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            for color in [
                TonoCoachPalette.normal,
                TonoCoachPalette.pressed,
                TonoCoachPalette.disabledBackground,
            ] {
                let resolved = color.resolvedColor(with: traits)
                XCTAssertGreaterThanOrEqual(
                    Self.contrastRatio(foreground: .white, background: resolved),
                    4.5
                )
            }
        }
    }

    func testCoachButtonUsesSemanticStateColors() {
        let button = TonoCoachButton(type: .custom)
        button.isEnabled = true
        button.isHighlighted = false
        XCTAssertTrue(Self.sameColor(button.backgroundColor, TonoCoachPalette.normal))

        button.isHighlighted = true
        XCTAssertTrue(Self.sameColor(button.backgroundColor, TonoCoachPalette.pressed))

        button.isEnabled = false
        XCTAssertTrue(Self.sameColor(button.backgroundColor, TonoCoachPalette.disabledBackground))
        XCTAssertEqual(button.titleColor(for: .disabled), .white)
    }

    func testCoachChoiceUsesReusableNormalPressedSelectedAndDisabledStates() {
        let choice = TonoCoachChoiceControl(frame: .zero)
        XCTAssertTrue(Self.sameColor(choice.backgroundColor, TonoCoachPalette.normal))
        choice.isHighlighted = true
        XCTAssertTrue(Self.sameColor(choice.backgroundColor, TonoCoachPalette.pressed))
        choice.isHighlighted = false
        choice.isSelected = true
        XCTAssertTrue(Self.sameColor(choice.backgroundColor, TonoCoachPalette.pressed))
        choice.isEnabled = false
        XCTAssertTrue(Self.sameColor(choice.backgroundColor, TonoCoachPalette.disabledBackground))
    }

    func testApprovedCoachAxisPaletteKeepsFourDistinctHistoricalColors() {
        let expected: [String: (light: String, dark: String)] = [
            "warmer": ("B4234D", "FF6B8A"),
            "clearer": ("006A8E", "49C7F2"),
            "funnier": ("7A5100", "FFC247"),
            "safer": ("147A36", "4CD471"),
        ]

        for (axis, colors) in expected {
            XCTAssertTrue(Self.sameColor(
                TonoCoachPalette.axisAccent(for: axis),
                UIColor(hexRGB: colors.light),
                style: .light
            ))
            XCTAssertTrue(Self.sameColor(
                TonoCoachPalette.axisAccent(for: axis),
                UIColor(hexRGB: colors.dark),
                style: .dark
            ))
        }

        let lightColors = Set(expected.keys.map {
            Self.rgba(TonoCoachPalette.axisAccent(for: $0), style: .light)
        })
        let darkColors = Set(expected.keys.map {
            Self.rgba(TonoCoachPalette.axisAccent(for: $0), style: .dark)
        })
        XCTAssertEqual(lightColors.count, 4, "light Coach axes must not collapse to one color")
        XCTAssertEqual(darkColors.count, 4, "dark Coach axes must not collapse to one color")
    }

    private static func contrastRatio(foreground: UIColor, background: UIColor) -> CGFloat {
        let bright = max(luminance(foreground), luminance(background))
        let dark = min(luminance(foreground), luminance(background))
        return (bright + 0.05) / (dark + 0.05)
    }

    private static func luminance(_ color: UIColor) -> CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    private static func sameColor(
        _ lhs: UIColor?,
        _ rhs: UIColor,
        style: UIUserInterfaceStyle = .light
    ) -> Bool {
        guard let lhs else { return false }
        let traits = UITraitCollection(userInterfaceStyle: style)
        return lhs.resolvedColor(with: traits) == rhs.resolvedColor(with: traits)
    }

    private static func rgba(_ color: UIColor, style: UIUserInterfaceStyle) -> String {
        let resolved = color.resolvedColor(with: .init(userInterfaceStyle: style))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        return [red, green, blue, alpha]
            .map { String(format: "%.4f", $0) }
            .joined(separator: ":")
    }
}
