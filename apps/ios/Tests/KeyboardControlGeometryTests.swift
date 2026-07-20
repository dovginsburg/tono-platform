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
        var capturedError: Error?
        traits.performAsCurrent {
            do {
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
            } catch {
                capturedError = error
            }
        }
        if let capturedError { throw capturedError }
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

    private static func view(identifier: String, in root: UIView) -> UIView? {
        ([root] + descendants(of: root)).first { $0.accessibilityIdentifier == identifier }
    }

    private static func descendants(of root: UIView) -> [UIView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    func testCoachGeometryIsInvariantAcrossEveryStateAndApprovedWidthBucket() {
        for width in [CGFloat(320), 375, 390, 430, 768] {
            let metrics = TonoKeyboardMetrics.portrait(availableWidth: width)
            XCTAssertEqual(
                metrics.preferredContentHeight,
                metrics.coachResultsContentHeight,
                "idle/loading/error/results/Back must reserve one stable height at \(width)pt"
            )
            XCTAssertEqual(metrics.topBarHeight, 46)
            XCTAssertEqual(metrics.coachControlHeight, Self.minimum)
        }
    }

    @MainActor
    func testCoachButtonKeepsOneFrameAcrossNormalPressedDisabledAndAccessibilityType() throws {
        let traits = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        var capturedError: Error?
        traits.performAsCurrent {
            do {
                let controller = KeyboardViewController()
                controller.loadViewIfNeeded()
                controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: 288)
                controller.view.layoutIfNeeded()
                let button = try XCTUnwrap(Self.control(identifier: "TonoKB.coachButton", in: controller.view) as? UIButton)
                let frame = button.frame
                button.isHighlighted = true
                controller.view.layoutIfNeeded()
                XCTAssertEqual(button.frame, frame)
                button.isHighlighted = false
                button.isEnabled = false
                controller.view.layoutIfNeeded()
                XCTAssertEqual(button.frame, frame)
                XCTAssertEqual(frame.height, Self.minimum)
            } catch {
                capturedError = error
            }
        }
        if let capturedError { throw capturedError }
    }

    @MainActor
    func testAXXXLCoachResultsHaveDeterministicScrollableContentHeight() throws {
        let traits = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        var capturedError: Error?
        traits.performAsCurrent {
            do {
                let controller = KeyboardViewController()
                controller.loadViewIfNeeded()
                controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: 288)
                controller.presentCoachResults(TonoCoachClient.CoachResponse(
                    riskLevel: "medium",
                    perception: "The message may read as abrupt.",
                    subtext: "The recipient may need a clearer request.",
                    reason: "The ask is terse.",
                    suggestions: TonoCoachPalette.orderedAxes.prefix(4).map { axis in
                        TonoCoachClient.CoachRewrite(
                            axis: axis.rawValue,
                            text: "A deliberately long \(axis.label.lowercased()) rewrite that wraps to two lines at compact width without clipping accessibility text.",
                            rationale: nil,
                            riskAfter: "low"
                        )
                    },
                    flags: []
                ))

                for _ in 0..<3 {
                    controller.view.setNeedsLayout()
                    controller.view.layoutIfNeeded()
                    Self.layoutRecursively(controller.view)
                }

                let results = try XCTUnwrap(Self.view(identifier: "TonoKB.coachResults", in: controller.view))
                let scroll = try XCTUnwrap(Self.view(identifier: "TonoKB.rewrites.scroll", in: results) as? UIScrollView)
                let stack = try XCTUnwrap(Self.view(identifier: "TonoKB.rewrites", in: scroll) as? UIStackView)
                let visibleHierarchy = [results] + Self.descendants(of: results).filter { !$0.isHidden }

                for view in visibleHierarchy {
                    XCTAssertFalse(
                        view.hasAmbiguousLayout,
                        "AXXXL results layout is ambiguous for \(view.accessibilityIdentifier ?? String(describing: type(of: view))) frame=\(view.frame)"
                    )
                }
                XCTAssertEqual(stack.arrangedSubviews.count, 4)
                XCTAssertGreaterThan(scroll.bounds.height, 0)
                XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height, "AXXXL cards must scroll instead of compressing or clipping")
                XCTAssertEqual(scroll.contentSize.height, stack.frame.height, accuracy: 0.5)
                XCTAssertGreaterThan(stack.frame.height, 0)
                XCTAssertTrue(stack.arrangedSubviews.allSatisfy { $0.frame.height >= Self.minimum })
            } catch {
                capturedError = error
            }
        }
        if let capturedError { throw capturedError }
    }

    func testSemanticCoachAxisOrderAndExactTonoitTokens() {
        XCTAssertEqual(
            TonoCoachPalette.orderedAxes.map(\.rawValue),
            ["safer", "clearer", "funnier", "affectionate", "professional", "concise", "custom"]
        )
        XCTAssertEqual(Self.hex(TonoCoachPalette.Axis.safer.accent), "34D399")
        XCTAssertEqual(Self.hex(TonoCoachPalette.Axis.clearer.accent), "38BDF8")
        XCTAssertEqual(Self.hex(TonoCoachPalette.Axis.funnier.accent), "FBBF24")
        XCTAssertEqual(Self.hex(TonoCoachPalette.Axis.affectionate.accent), "F472B6")
    }

    func testOneShotShiftConsumesSynchronouslyAndRejectsStaleRearm() {
        var machine = TonoShiftStateMachine()
        var generation: UInt64 = 0
        machine.tapShift()
        XCTAssertEqual(machine.state, .oneShotUppercase)
        var output = machine.display("a")
        machine.consumeEligibleCapital(output)
        generation += 1
        XCTAssertEqual(machine.state, .lowercase, "Shift+a must lowercase labels before b")
        XCTAssertFalse(machine.applyAutomaticCapitalization(
            recommended: true,
            callbackGeneration: generation - 1,
            documentGeneration: generation
        ))
        XCTAssertEqual(machine.state, .lowercase, "stale proxy callback must not re-arm one-shot Shift")
        output += machine.display("b")
        machine.consumeEligibleCapital("b")
        XCTAssertEqual(output, "Ab")
        XCTAssertEqual(machine.state, .lowercase)
    }

    func testCapsLockAndSentenceAutoCapitalizationTransitions() {
        var machine = TonoShiftStateMachine()
        machine.doubleTapShift()
        let capsOutput = machine.display("a") + machine.display("b")
        machine.consumeEligibleCapital("A")
        machine.consumeEligibleCapital("B")
        XCTAssertEqual(capsOutput, "AB")
        XCTAssertEqual(machine.state, .capsLock, "double Shift+a+b must remain AB")
        machine.tapShift()
        machine.consumeEligibleCapital("c")
        XCTAssertEqual(machine.state, .lowercase, "Caps Lock then Shift+c must produce lowercase c")

        XCTAssertTrue(machine.applyAutomaticCapitalization(
            recommended: true,
            callbackGeneration: 4,
            documentGeneration: 4
        ))
        XCTAssertEqual(machine.state, .oneShotUppercase)
        machine.consumeEligibleCapital("S")
        XCTAssertEqual(machine.state, .lowercase, "sentence auto-cap must be one-shot")
    }

    func testRapidInputBoundariesAndAutocorrectCallbacksCannotRearmConsumedShift() {
        var machine = TonoShiftStateMachine()
        var generation: UInt64 = 40

        machine.tapShift()
        XCTAssertEqual(machine.display("a"), "A")
        machine.consumeEligibleCapital("A")
        generation += 1

        // Rapid b, space, Return and a host autocorrect mutation each advance
        // the document generation. Every callback captured before that mutation
        // must be rejected, even if stale proxy context recommended caps.
        for mutation in ["b", " ", "return", "autocorrect"] {
            let staleGeneration = generation
            generation += 1
            XCTAssertFalse(machine.applyAutomaticCapitalization(
                recommended: true,
                callbackGeneration: staleGeneration,
                documentGeneration: generation
            ), "stale callback after \(mutation) must be ignored")
            XCTAssertEqual(machine.state, .lowercase)
        }

        // Effective post-Return context is current-generation evidence and may
        // legitimately arm exactly one automatic capital.
        XCTAssertTrue(machine.applyAutomaticCapitalization(
            recommended: true,
            callbackGeneration: generation,
            documentGeneration: generation
        ))
        XCTAssertEqual(machine.display("c"), "C")
        machine.consumeEligibleCapital("C")
        XCTAssertEqual(machine.display("d"), "d")
    }

    func testPendingLocalMutationRejectsUnrelatedHostAutocorrectContext() {
        let pending = TonoPendingDocumentMutation(
            generation: 9,
            contextBefore: "Shift+A",
            contextAfter: "Shift+A "
        )
        XCTAssertTrue(pending.canExplain(notificationContext: "Shift+A"))
        XCTAssertTrue(pending.canExplain(notificationContext: "Shift+A "))
        XCTAssertFalse(
            pending.canExplain(notificationContext: "Shift+An "),
            "host autocorrect must not be mistaken for the pending local mutation"
        )
    }

    func testEffectiveContextModelsBoundaryReplacementAndFullAutocorrectionUndo() {
        let corrected = TonoDocumentContextMutation.applying(
            deleteCount: 3,
            insertion: "the ",
            to: "send teh"
        )
        XCTAssertEqual(corrected, "send the ")
        XCTAssertEqual(
            TonoDocumentContextMutation.restoring(
                correctedSuffix: "the ",
                restoredText: "teh",
                in: corrected
            ),
            "send teh"
        )
        XCTAssertNil(
            TonoDocumentContextMutation.restoring(
                correctedSuffix: "the ",
                restoredText: "teh",
                in: "host changed the document"
            )
        )
    }

    @MainActor
    func testHostileCompactRotationKeepsCoachResultsDeterministicAndUnambiguous() throws {
        let traits = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        var capturedError: Error?
        traits.performAsCurrent {
            do {
                let controller = KeyboardViewController()
                controller.loadViewIfNeeded()
                controller.view.frame = CGRect(x: 0, y: 0, width: 768, height: 300)
                controller.viewDidLayoutSubviews()
                controller.presentCoachResults(TonoCoachClient.CoachResponse(
                    riskLevel: "medium",
                    perception: "The message may read as abrupt.",
                    subtext: "The recipient may need a clearer request.",
                    reason: "The ask is terse.",
                    suggestions: TonoCoachPalette.orderedAxes.prefix(4).map { axis in
                        TonoCoachClient.CoachRewrite(
                            axis: axis.rawValue,
                            text: "A deliberately long hostile QA \(axis.label.lowercased()) rewrite that must remain deterministic after compact-width rotation.",
                            rationale: nil,
                            riskAfter: "low"
                        )
                    },
                    flags: []
                ))

                func snapshot(_ width: CGFloat, _ height: CGFloat) throws -> (CGFloat, CGFloat, CGFloat) {
                    controller.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
                    controller.viewDidLayoutSubviews()
                    for _ in 0..<4 {
                        controller.view.setNeedsLayout()
                        controller.view.layoutIfNeeded()
                        Self.layoutRecursively(controller.view)
                    }
                    let results = try XCTUnwrap(Self.view(identifier: "TonoKB.coachResults", in: controller.view))
                    let scroll = try XCTUnwrap(Self.view(identifier: "TonoKB.rewrites.scroll", in: results) as? UIScrollView)
                    let stack = try XCTUnwrap(Self.view(identifier: "TonoKB.rewrites", in: scroll) as? UIStackView)
                    for view in [results] + Self.descendants(of: results).filter({ !$0.isHidden }) {
                        XCTAssertFalse(view.hasAmbiguousLayout, "rotation made \(view.accessibilityIdentifier ?? String(describing: type(of: view))) ambiguous at \(width)x\(height)")
                    }
                    XCTAssertEqual(scroll.contentSize.height, stack.frame.height, accuracy: 0.5)
                    XCTAssertEqual(stack.frame.width, scroll.bounds.width, accuracy: 0.5)
                    XCTAssertGreaterThan(scroll.bounds.height, 0)
                    return (scroll.contentSize.height, stack.frame.height, scroll.bounds.height)
                }

                let wideInitial = try snapshot(768, 300)
                let wideInitialAgain = try snapshot(768, 300)
                XCTAssertEqual(wideInitial.0, wideInitialAgain.0, accuracy: 0.5)
                XCTAssertEqual(wideInitial.1, wideInitialAgain.1, accuracy: 0.5)

                let compactA = try snapshot(320, 288)
                let compactB = try snapshot(320, 288)
                XCTAssertEqual(compactA.0, compactB.0, accuracy: 0.5)
                XCTAssertEqual(compactA.1, compactB.1, accuracy: 0.5)

                let rotatedA = try snapshot(768, 300)
                let rotatedB = try snapshot(768, 300)
                XCTAssertEqual(rotatedA.0, rotatedB.0, accuracy: 0.5)
                XCTAssertEqual(rotatedA.1, rotatedB.1, accuracy: 0.5)

                let compactAgain = try snapshot(320, 288)
                XCTAssertEqual(compactA.0, compactAgain.0, accuracy: 0.5)
                XCTAssertEqual(compactA.1, compactAgain.1, accuracy: 0.5)
            } catch {
                capturedError = error
            }
        }
        if let capturedError { throw capturedError }
    }

    private static func hex(_ color: UIColor) -> String? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return String(format: "%02X%02X%02X", Int(round(red * 255)), Int(round(green * 255)), Int(round(blue * 255)))
    }

    private static func layoutRecursively(_ root: UIView) {
        root.layoutIfNeeded()
        root.subviews.forEach(layoutRecursively)
    }
}

// The production controller is compiled into TonoTests so this suite exercises
// its real UIKit hierarchy. It only needs the emoji-recents slice of the shared
// defaults surface; these test-module definitions avoid pulling unrelated app
// settings and Keychain dependencies into the unit-test binary.
enum SharedKeys {
    static let recipients = "tc.recipients"
    static let emojiRecents = "tc.emojiRecents"
}

enum SharedStore {
    static let defaults = UserDefaults.standard
}
