import XCTest
import UIKit

/// Every laid-out keyboard control must expose an effective 44×44pt target.
/// These tests exercise the runtime geometry helpers, the real hit-test subclass,
/// and the actual `KeyboardViewController` hierarchy at compact width and
/// accessibility Dynamic Type. There is no source-regex escape hatch.
final class KeyboardControlGeometryTests: XCTestCase {
    private static let minimum: CGFloat = 44

    func testExportedControlGeometryMeetsTouchTarget() {
        typealias G = TonoKeyboardMetrics.ControlGeometry
        let sizes: [(String, CGFloat)] = [
            ("minimumTouchTarget", G.minimumTouchTarget),
            ("emojiToggleWidth", G.emojiToggleWidth),
            ("quickCharacterWidth", G.quickCharacterWidth),
            ("emojiCategoryTabWidth", G.emojiCategoryTabWidth),
            ("emojiCategoryTabHeight", G.emojiCategoryTabHeight),
            ("emojiPanelFooterHeight", G.emojiPanelFooterHeight),
            ("emojiResultCellWidth", G.emojiResultCellWidth),
            ("emojiResultCellHeight", G.emojiResultCellHeight),
            ("coachBackControlWidth", G.coachBackControlWidth),
            ("coachBackControlHeight", G.coachBackControlHeight),
        ]
        for (label, value) in sizes {
            XCTAssertGreaterThanOrEqual(value, Self.minimum, "\(label) = \(value)pt")
        }
    }

    func testEmojiGridUsesFewerColumnsRatherThanSub44Cells() {
        typealias G = TonoKeyboardMetrics.ControlGeometry
        for width in [CGFloat(320), 375, 402, 440] {
            let columns = G.emojiGridColumns(availableWidth: width)
            let cellWidth = G.emojiGridCellWidth(availableWidth: width)
            XCTAssertGreaterThanOrEqual(cellWidth, Self.minimum, "\(columns) columns at \(width)pt produced \(cellWidth)pt cells")
            XCTAssertLessThanOrEqual(columns, 8)
        }
    }

    func testMinimumHitTargetButtonExpandsBothAxes() {
        let button = TonoMinimumHitTargetButton(frame: CGRect(x: 0, y: 0, width: 22, height: 30))
        XCTAssertTrue(button.point(inside: CGPoint(x: -10.5, y: 15), with: nil))
        XCTAssertTrue(button.point(inside: CGPoint(x: 32.5, y: 15), with: nil))
        XCTAssertTrue(button.point(inside: CGPoint(x: 11, y: -6.5), with: nil))
        XCTAssertTrue(button.point(inside: CGPoint(x: 11, y: 36.5), with: nil))
        XCTAssertFalse(button.point(inside: CGPoint(x: -12, y: 15), with: nil))
    }

    @MainActor
    func testActualCompactKeyboardAndEmojiControlsExpose44PointEffectiveTargetsAtAccessibilityType() throws {
        let traits = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        try traits.performAsCurrent {
            let controller = KeyboardViewController()
            controller.loadViewIfNeeded()
            controller.view.frame = CGRect(x: 0, y: 0, width: 375, height: 320)
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()

            try Self.assertEffectiveTargets(in: controller.view, state: "typing")

            let emoji = try XCTUnwrap(Self.control(identifier: "TonoKB.emojiToggle", in: controller.view) as? UIButton)
            emoji.sendActions(for: .touchUpInside)
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            Self.layoutRecursively(controller.view)

            try Self.assertEffectiveTargets(in: controller.view, state: "emoji")
            let cells = Self.descendants(of: controller.view).compactMap { $0 as? UICollectionViewCell }
            XCTAssertFalse(cells.isEmpty, "the real emoji collection must lay out visible runtime cells")
            for cell in cells where !cell.isHidden {
                XCTAssertGreaterThanOrEqual(cell.bounds.width, Self.minimum)
                XCTAssertGreaterThanOrEqual(cell.bounds.height, Self.minimum)
            }

            let tabs = Self.descendants(of: controller.view)
                .compactMap { $0 as? UIControl }
                .filter { $0.accessibilityIdentifier?.hasPrefix("TonoKB.emojiCategory.") == true }
            XCTAssertEqual(tabs.count, 10, "all ten real category controls must be present in the scroll strip")
            for tab in tabs {
                XCTAssertGreaterThanOrEqual(tab.bounds.width, Self.minimum)
                XCTAssertGreaterThanOrEqual(tab.bounds.height, Self.minimum)
            }
        }
    }

    @MainActor
    private static func assertEffectiveTargets(in root: UIView, state: String) throws {
        let controls = descendants(of: root).compactMap { $0 as? UIControl }.filter {
            !$0.isHidden && $0.alpha > 0.01 && $0.isUserInteractionEnabled && $0.window != nil || (!$0.isHidden && $0.alpha > 0.01 && $0.isUserInteractionEnabled)
        }
        XCTAssertFalse(controls.isEmpty, "\(state) must lay out interactive controls")
        for control in controls {
            let dx = max(0, (minimum - control.bounds.width) / 2)
            let dy = max(0, (minimum - control.bounds.height) / 2)
            let points = [
                CGPoint(x: control.bounds.minX - dx + 0.25, y: control.bounds.midY),
                CGPoint(x: control.bounds.maxX + dx - 0.25, y: control.bounds.midY),
                CGPoint(x: control.bounds.midX, y: control.bounds.minY - dy + 0.25),
                CGPoint(x: control.bounds.midX, y: control.bounds.maxY + dy - 0.25),
            ]
            for point in points {
                XCTAssertTrue(
                    control.point(inside: point, with: nil),
                    "\(state) \(control.accessibilityIdentifier ?? String(describing: type(of: control))) frame=\(control.bounds) does not expose a 44×44 effective target"
                )
            }
        }
    }

    private static func control(identifier: String, in root: UIView) -> UIControl? {
        descendants(of: root).compactMap { $0 as? UIControl }.first { $0.accessibilityIdentifier == identifier }
    }

    private static func descendants(of root: UIView) -> [UIView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private static func layoutRecursively(_ root: UIView) {
        root.layoutIfNeeded()
        root.subviews.forEach(layoutRecursively)
    }
}
