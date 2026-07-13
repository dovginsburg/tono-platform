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
        XCTAssertEqual(regular.rowSpacing, 8)
        XCTAssertEqual(regular.keyFontSize, 22)
        XCTAssertEqual(regular.keyCornerRadius, 5)
    }

    func testCoachFitsWithoutShrinkingTypingRows() {
        let metrics = TonoKeyboardMetrics.portrait(availableWidth: 402)
        let typingRowsHeight = metrics.keyMinHeight * 4 + metrics.rowSpacing * 3

        XCTAssertEqual(typingRowsHeight, 200)
        XCTAssertGreaterThanOrEqual(metrics.topBarHeight, 44)
        XCTAssertGreaterThanOrEqual(metrics.coachControlHeight, 36)
        XCTAssertGreaterThanOrEqual(
            metrics.preferredContentHeight,
            metrics.topBarHeight + typingRowsHeight
        )
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

    private static func sameColor(_ lhs: UIColor?, _ rhs: UIColor) -> Bool {
        guard let lhs else { return false }
        return lhs.resolvedColor(with: .init(userInterfaceStyle: .light))
            == rhs.resolvedColor(with: .init(userInterfaceStyle: .light))
    }
}
