// Build106SuggestionRoutingTests.swift
// Build 106 — release blocker A.
//
// PHYSICAL FINDING (Build 105, on device): "Tapping an autocorrect suggestion
// incorrectly ran Tono Coach instead of accepting/replacing the word."
//
// ROOT CAUSE: the top strip time-shared three buttons between spelling
// candidates and Coach tone chips. `setToneChipsEnabled(true)` swapped their
// target/action from `candidateTapped(_:)` to `toneChipTapped(_:)`;
// `setToneChipsEnabled(false)` repainted the titles but never swapped back. One
// toggle of TONO welded the strip to Coach for the rest of the session.
//
// These tests drive the REAL `KeyboardViewController` UIKit hierarchy — real
// buttons, real target/action tables, real constraints, real hit testing. There
// is no source-regex escape hatch, because a source regex is exactly what
// missed this in Build 105.
//
// `testRollbackRed_*` are the negative controls: they assert the Build-105
// shape is now REFUSED, and that the same fixture would have dispatched under
// the old ungated policy.

import XCTest
import UIKit
@testable import Tono

final class Build106SuggestionRoutingTests: XCTestCase {

    // MARK: - The physical finding, reproduced against the real hierarchy

    /// The exact rejected sequence: toggle TONO on, toggle it off, then tap a
    /// spelling suggestion. Build 105 started a Coach rewrite here.
    @MainActor
    func testSuggestionTapAfterToneChipToggleNeverStartsCoach() throws {
        let controller = Self.makeController()
        let coach = try XCTUnwrap(Self.control(Const.coachButton, in: controller.view) as? UIButton)

        // Toggle on, then off — the Build-105 state corruption window.
        coach.sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()
        coach.sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()

        controller.updateCandidateStrip(values: ["teh", "the", "ten"])
        controller.view.layoutIfNeeded()

        for button in Self.suggestionButtons(in: controller.view) {
            button.sendActions(for: .touchUpInside)
        }

        XCTAssertEqual(
            controller.coachRequestsStarted, 0,
            "a spelling suggestion tap must invoke Coach zero times — this is the Build-105 defect"
        )
        XCTAssertNil(
            Self.view(Const.coachLoading, in: controller.view),
            "a suggestion tap must open no Coach surface"
        )
        XCTAssertNil(Self.view(Const.coachResults, in: controller.view))
        XCTAssertEqual(
            controller.stripRefusals[.roleMismatch, default: 0], 0,
            "no dispatch may arrive at the wrong handler at all"
        )
    }

    /// Repeated rerenders and repeated toggles must not accumulate targets.
    /// Build 105's `addTarget` was cumulative, so this is where the damage grew.
    @MainActor
    func testRepeatedTogglesAndRerendersLeaveTargetsStatic() throws {
        let controller = Self.makeController()
        let coach = try XCTUnwrap(Self.control(Const.coachButton, in: controller.view) as? UIButton)

        for cycle in 0..<8 {
            coach.sendActions(for: .touchUpInside)
            controller.view.layoutIfNeeded()
            controller.updateCandidateStrip(values: ["alpha", "beta", "gamma"])
            coach.sendActions(for: .touchUpInside)
            controller.view.layoutIfNeeded()
            controller.updateCandidateStrip(values: ["alpha", "beta", "gamma"])

            for button in Self.suggestionButtons(in: controller.view) {
                let actions = button.actions(forTarget: controller, forControlEvent: .touchUpInside) ?? []
                XCTAssertEqual(
                    actions, ["candidateTapped:"],
                    "cycle \(cycle): a suggestion button must carry exactly one action, forever"
                )
                XCTAssertFalse(
                    actions.contains("toneChipTapped:"),
                    "cycle \(cycle): the Build-105 welded-to-Coach state must be unreachable"
                )
                button.sendActions(for: .touchUpInside)
            }
            for chip in Self.toneChipButtons(in: controller.view) {
                let actions = chip.actions(forTarget: controller, forControlEvent: .touchUpInside) ?? []
                XCTAssertEqual(actions, ["toneChipTapped:"], "cycle \(cycle): chip actions must be static too")
            }
        }

        XCTAssertEqual(
            controller.coachRequestsStarted, 0,
            "eight toggle cycles and 24 suggestion taps must still invoke Coach zero times"
        )
    }

    /// Suggestions and chips are separate view hierarchies, and only one of
    /// them is ever live.
    @MainActor
    func testExactlyOneStripRowIsLiveAtATime() throws {
        let controller = Self.makeController()
        let coach = try XCTUnwrap(Self.control(Const.coachButton, in: controller.view) as? UIButton)

        let suggestions = try XCTUnwrap(Self.view(Const.candidates, in: controller.view))
        let chips = try XCTUnwrap(Self.view(Const.toneChips, in: controller.view))
        XCTAssertFalse(suggestions === chips, "the two roles must not share one view")

        XCTAssertFalse(suggestions.isHidden)
        XCTAssertTrue(suggestions.isUserInteractionEnabled)
        XCTAssertTrue(chips.isHidden, "the chip row must be hidden while suggestions are live")
        XCTAssertFalse(chips.isUserInteractionEnabled, "and non-interactive, so z-order cannot decide a tap")

        coach.sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()
        XCTAssertTrue(suggestions.isHidden)
        XCTAssertFalse(suggestions.isUserInteractionEnabled)
        XCTAssertFalse(chips.isHidden)
        XCTAssertTrue(chips.isUserInteractionEnabled)
    }

    /// Every strip button carries a stable, physically inspectable identifier,
    /// so an on-device inspector can tell the two roles apart.
    @MainActor
    func testStripButtonsCarryDistinctInspectableIdentifiers() throws {
        let controller = Self.makeController()
        let suggestionIDs = Self.suggestionButtons(in: controller.view).map(\.accessibilityIdentifier)
        let chipIDs = Self.toneChipButtons(in: controller.view).map(\.accessibilityIdentifier)
        XCTAssertEqual(suggestionIDs, ["TonoKB.suggestion.0", "TonoKB.suggestion.1", "TonoKB.suggestion.2"])
        XCTAssertEqual(chipIDs, ["TonoKB.toneChip.0", "TonoKB.toneChip.1", "TonoKB.toneChip.2"])
        XCTAssertTrue(Set(suggestionIDs).isDisjoint(with: Set(chipIDs)))
    }

    // MARK: - Spatial isolation

    /// The Coach control and the strip must not overlap where touches are
    /// actually resolved — `TonoMinimumHitTargetButton` expands hit rects to
    /// 44pt, so drawn separation is not sufficient evidence.
    @MainActor
    func testExpandedHitRegionsOfCoachAndSuggestionsAreDisjoint() throws {
        for width in [320.0, 375.0, 390.0, 430.0] as [CGFloat] {
            let controller = Self.makeController(width: width)
            controller.updateCandidateStrip(values: ["one", "two", "three"])
            controller.view.layoutIfNeeded()

            let bar = try XCTUnwrap(Self.view(Const.topBar, in: controller.view))
            let coach = try XCTUnwrap(Self.control(Const.coachButton, in: controller.view) as? UIButton)
            let minimum = TonoKeyboardMetrics.ControlGeometry.minimumTouchTarget

            var frames = [coach.convert(coach.bounds, to: bar)]
            frames += Self.suggestionButtons(in: controller.view).map { $0.convert($0.bounds, to: bar) }

            XCTAssertTrue(
                TonoStripGeometry.hitRectsAreDisjoint(frames, minimumTouchTarget: minimum),
                "at \(width)pt the Coach and suggestion hit regions overlap; a near-miss could reach Coach"
            )
            for frame in frames.dropFirst() {
                let expanded = TonoStripGeometry.expandedHitRect(for: frame, minimumTouchTarget: minimum)
                XCTAssertGreaterThanOrEqual(expanded.width, minimum - 0.5, "suggestion targets stay >= 44pt at \(width)pt")
                XCTAssertGreaterThanOrEqual(expanded.height, minimum - 0.5)
            }
        }
    }

    /// The same must hold in both interface styles, since style changes trigger
    /// a repaint and Build 105's damage was introduced by a repaint path.
    @MainActor
    func testIsolationHoldsInDarkAndLightAcrossRerender() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let controller = Self.makeController()
            controller.overrideUserInterfaceStyle = style
            controller.updateCandidateStrip(values: ["one", "two", "three"])
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()

            for button in Self.suggestionButtons(in: controller.view) {
                XCTAssertEqual(
                    button.actions(forTarget: controller, forControlEvent: .touchUpInside) ?? [],
                    ["candidateTapped:"],
                    "style \(style.rawValue) repaint must not re-target a suggestion"
                )
                button.sendActions(for: .touchUpInside)
            }
            XCTAssertEqual(controller.coachRequestsStarted, 0)
        }
    }

    // MARK: - Candidate content edge cases

    /// Empty, very long, RTL and emoji candidate values must all stay on the
    /// suggestion lane, never fall through to Coach, and never crash the strip.
    @MainActor
    func testUnusualCandidateValuesStayLocal() throws {
        let fixtures: [[String]] = [
            [],
            [""],
            ["a"],
            [String(repeating: "n", count: 240)],
            ["مرحبا", "مرحبًا", "أهلا"],
            ["🙂", "🙃‍", "👩‍👩‍👧‍👦"],
            ["can't", "cant", "can’t"],
        ]
        let controller = Self.makeController()
        for values in fixtures {
            controller.updateCandidateStrip(values: values)
            controller.view.layoutIfNeeded()
            for button in Self.suggestionButtons(in: controller.view) {
                button.sendActions(for: .touchUpInside)
                button.sendActions(for: .touchUpInside)   // rapid double tap
            }
        }
        XCTAssertEqual(
            controller.coachRequestsStarted, 0,
            "no candidate shape may route to Coach"
        )
    }

    /// A tap on a button whose index no longer has a value (a stale strip that
    /// shrank between render and touch) must be refused, not misread.
    @MainActor
    func testStaleCandidateTapIsRefusedNotMisrouted() throws {
        let controller = Self.makeController()
        controller.updateCandidateStrip(values: ["alpha", "beta", "gamma"])
        controller.view.layoutIfNeeded()
        let buttons = Self.suggestionButtons(in: controller.view)

        // The strip shrinks to one value; buttons 1 and 2 are now stale.
        controller.updateCandidateStrip(values: ["alpha"])
        buttons[1].sendActions(for: .touchUpInside)
        buttons[2].sendActions(for: .touchUpInside)

        XCTAssertEqual(controller.stripRefusals[.indexOutOfRange, default: 0], 2)
        XCTAssertEqual(controller.coachRequestsStarted, 0)
    }

    /// VoiceOver activation goes through the same control event, so it must be
    /// gated identically.
    @MainActor
    func testAccessibilityActivationAcceptsSuggestionAndNeverCoach() throws {
        let controller = Self.makeController()
        controller.updateCandidateStrip(values: ["teh", "the"])
        controller.view.layoutIfNeeded()

        for button in Self.suggestionButtons(in: controller.view) where !button.isHidden {
            XCTAssertTrue(button.isAccessibilityElement)
            XCTAssertEqual(
                button.accessibilityValue,
                LocalIntelligenceCopy.candidateProvenance,
                "VoiceOver must state that the suggestion came from this device"
            )
            _ = button.accessibilityActivate()
        }
        XCTAssertEqual(controller.coachRequestsStarted, 0)
    }

    // MARK: - Pure routing policy

    func testRoutingPolicyPerformsOnlyMatchingRoleInMatchingMode() {
        XCTAssertEqual(
            TonoStripRoutingPolicy.decide(
                senderRole: .suggestion, handlerRole: .suggestion,
                mode: .suggestions, index: 1, valueCount: 3, isBusy: false
            ),
            .perform(role: .suggestion, index: 1)
        )
        XCTAssertEqual(
            TonoStripRoutingPolicy.decide(
                senderRole: .toneChip, handlerRole: .toneChip,
                mode: .toneChips, index: 0, valueCount: 3, isBusy: false
            ),
            .perform(role: .toneChip, index: 0)
        )
    }

    func testRoutingPolicyRefusesInactiveModeBusyAndOutOfRange() {
        XCTAssertEqual(
            TonoStripRoutingPolicy.decide(
                senderRole: .toneChip, handlerRole: .toneChip,
                mode: .suggestions, index: 0, valueCount: 3, isBusy: false
            ),
            .refuse(reason: .inactiveMode)
        )
        XCTAssertEqual(
            TonoStripRoutingPolicy.decide(
                senderRole: .toneChip, handlerRole: .toneChip,
                mode: .toneChips, index: 0, valueCount: 3, isBusy: true
            ),
            .refuse(reason: .busy)
        )
        XCTAssertEqual(
            TonoStripRoutingPolicy.decide(
                senderRole: .suggestion, handlerRole: .suggestion,
                mode: .suggestions, index: 3, valueCount: 3, isBusy: false
            ),
            .refuse(reason: .indexOutOfRange)
        )
    }

    // MARK: - Rollback-red negative controls

    /// The Build-105 shape, stated directly: a suggestion-role control arriving
    /// at the Coach handler. Under Build 106 it is refused.
    func testRollbackRed_suggestionArrivingAtCoachHandlerIsRefused() {
        let decision = TonoStripRoutingPolicy.decide(
            senderRole: .suggestion,
            handlerRole: .toneChip,
            mode: .suggestions,
            index: 0,
            valueCount: 3,
            isBusy: false
        )
        XCTAssertEqual(decision, .refuse(reason: .roleMismatch))
    }

    /// The same fixture under the Build-105 policy — no role gate, index read
    /// straight from `tag` — WOULD have dispatched to Coach. This is what makes
    /// the test above a real control rather than a tautology.
    func testRollbackRed_build105PolicyWouldHaveDispatchedToCoach() {
        // Build 105, transcribed: the only guards were "not busy" and "the axis
        // index exists". Neither can tell a spelling tap from a chip tap.
        func build105Decision(tag: Int, axisCount: Int, isBusy: Bool) -> Bool {
            !isBusy && (0..<axisCount).contains(tag)
        }
        XCTAssertTrue(
            build105Decision(tag: 0, axisCount: 3, isBusy: false),
            "Build 105 would have started a Coach rewrite from a suggestion tap"
        )
        XCTAssertNotEqual(
            TonoStripRoutingPolicy.decide(
                senderRole: .suggestion, handlerRole: .toneChip,
                mode: .suggestions, index: 0, valueCount: 3, isBusy: false
            ),
            .perform(role: .toneChip, index: 0),
            "Build 106 must not"
        )
    }

    // MARK: - Build 115 — the strip after the on-device dot was deleted

    /// Build 115 removed the six-point dot that sat between TONO and the row,
    /// and the row moved left onto TONO's own `coachSeparation`. That is a
    /// genuinely smaller gap — 10pt where 26pt used to be — so the touch
    /// contract has to be re-proved at the narrowest widths rather than assumed
    /// to have survived the deletion.
    ///
    /// The gap is pinned from BOTH sides: at least `coachSeparation`, so the
    /// hit regions stay apart, and at most `coachSeparation`, so the dot's 16pt
    /// goes back to the candidates instead of staying behind as a dead gutter.
    @MainActor
    func testStripGeometrySurvivesTheDotRemovalAtNarrowWidths() throws {
        let minimum = TonoKeyboardMetrics.ControlGeometry.minimumTouchTarget
        for width in [320.0, 375.0, 390.0] as [CGFloat] {
            let controller = Self.makeController(width: width)
            controller.updateCandidateStrip(values: ["one", "two", "three"])
            controller.view.layoutIfNeeded()

            let bar = try XCTUnwrap(Self.view(Const.topBar, in: controller.view))
            let coach = try XCTUnwrap(Self.control(Const.coachButton, in: controller.view) as? UIButton)
            let coachFrame = coach.convert(coach.bounds, to: bar)

            XCTAssertGreaterThanOrEqual(
                coachFrame.width, minimum - 0.5,
                "TONO must stay a full 44pt-wide target at \(width)pt"
            )
            XCTAssertGreaterThanOrEqual(
                coachFrame.height, minimum - 0.5,
                "TONO must stay a full 44pt-tall target at \(width)pt"
            )

            // Both rows are constrained identically and both must follow TONO
            // directly — the hidden one too, since toggling TONO makes it live
            // without re-running layout from scratch.
            for identifier in [Const.candidates, Const.toneChips] {
                let stack = try XCTUnwrap(Self.view(identifier, in: controller.view))
                let gap = stack.convert(stack.bounds, to: bar).minX - coachFrame.maxX
                XCTAssertEqual(
                    gap, TonoStripGeometry.coachSeparation, accuracy: 0.5,
                    """
                    \(identifier) at \(width)pt must sit exactly one reviewed \
                    separation from TONO — a larger gap means the deleted dot's \
                    space was never given back
                    """
                )
            }

            // The reclaimed width lands on the candidates, and they still clear
            // the minimum target once expanded.
            var frames = [coachFrame]
            frames += Self.suggestionButtons(in: controller.view).map { $0.convert($0.bounds, to: bar) }
            XCTAssertTrue(
                TonoStripGeometry.hitRectsAreDisjoint(frames, minimumTouchTarget: minimum),
                "at \(width)pt the tightened gap must still keep TONO and the candidates apart"
            )
            for frame in frames.dropFirst() {
                let expanded = TonoStripGeometry.expandedHitRect(for: frame, minimumTouchTarget: minimum)
                XCTAssertGreaterThanOrEqual(expanded.width, minimum - 0.5)
                XCTAssertGreaterThanOrEqual(expanded.height, minimum - 0.5)
            }
        }
    }

    /// The two roles were kept apart by separate hierarchies, not by the dot
    /// that used to sit between them — so removing it must change nothing about
    /// which handler a tap reaches, including at the narrowest width where the
    /// controls are now closest together.
    @MainActor
    func testRoleIsolationIsUnaffectedByTheDotRemovalAtTheNarrowestWidth() throws {
        let controller = Self.makeController(width: 320)
        let coach = try XCTUnwrap(Self.control(Const.coachButton, in: controller.view) as? UIButton)

        controller.updateCandidateStrip(values: ["teh", "the", "ten"])
        controller.view.layoutIfNeeded()
        for button in Self.suggestionButtons(in: controller.view) {
            XCTAssertEqual(
                button.actions(forTarget: controller, forControlEvent: .touchUpInside) ?? [],
                ["candidateTapped:"]
            )
            button.sendActions(for: .touchUpInside)
        }
        XCTAssertEqual(
            controller.coachRequestsStarted, 0,
            "a candidate tap must still never reach Coach at 320pt"
        )

        coach.sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()
        for chip in Self.toneChipButtons(in: controller.view) {
            XCTAssertEqual(
                chip.actions(forTarget: controller, forControlEvent: .touchUpInside) ?? [],
                ["toneChipTapped:"]
            )
        }
        XCTAssertEqual(
            controller.stripRefusals[.roleMismatch, default: 0], 0,
            "no dispatch may be refused for a role mismatch after the deletion"
        )
    }

    /// A deliberately overlapping layout must be caught by the geometry gate,
    /// proving the disjointness assertion can actually fail.
    func testRollbackRed_overlappingHitRegionsAreDetected() {
        let minimum = TonoKeyboardMetrics.ControlGeometry.minimumTouchTarget
        let coach = CGRect(x: 0, y: 0, width: 68, height: 34)
        let touching = CGRect(x: 69, y: 0, width: 30, height: 34)   // 1pt gap, 30pt wide
        XCTAssertFalse(
            TonoStripGeometry.hitRectsAreDisjoint([coach, touching], minimumTouchTarget: minimum),
            "a 1pt drawn gap between a 30pt-wide control and Coach must be reported as overlapping"
        )
        let separated = CGRect(x: 68 + TonoStripGeometry.coachSeparation * 2 + 7, y: 0, width: 30, height: 34)
        XCTAssertTrue(TonoStripGeometry.hitRectsAreDisjoint([coach, separated], minimumTouchTarget: minimum))
    }

    /// A coder-instantiated strip button would have no role, so the type
    /// refuses to exist that way rather than defaulting to one.
    func testStripButtonRoleIsImmutableIdentity() {
        let button = TonoStripButton(role: .suggestion, index: 2)
        XCTAssertEqual(button.stripRole, .suggestion)
        XCTAssertEqual(button.stripIndex, 2)
        XCTAssertEqual(button.accessibilityIdentifier, "TonoKB.suggestion.2")
        XCTAssertEqual(TonoStripRole.suggestion.accessibilityIdentifier(index: 0), "TonoKB.suggestion.0")
        XCTAssertEqual(TonoStripRole.toneChip.accessibilityIdentifier(index: 1), "TonoKB.toneChip.1")
    }

    // MARK: - Helpers

    private enum Const {
        static let topBar = "TonoKB.topBar"
        static let coachButton = "TonoKB.coachButton"
        static let candidates = "TonoKB.candidates"
        static let toneChips = "TonoKB.toneChips"
        static let coachLoading = "TonoKB.coachLoading"
        static let coachResults = "TonoKB.coachResults"
    }

    @MainActor
    private static func makeController(width: CGFloat = 390) -> KeyboardViewController {
        let controller = KeyboardViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 320)
        controller.view.layoutIfNeeded()
        return controller
    }

    @MainActor
    private static func suggestionButtons(in root: UIView) -> [TonoStripButton] {
        descendants(of: root)
            .compactMap { $0 as? TonoStripButton }
            .filter { $0.stripRole == .suggestion }
            .sorted { $0.stripIndex < $1.stripIndex }
    }

    @MainActor
    private static func toneChipButtons(in root: UIView) -> [TonoStripButton] {
        descendants(of: root)
            .compactMap { $0 as? TonoStripButton }
            .filter { $0.stripRole == .toneChip }
            .sorted { $0.stripIndex < $1.stripIndex }
    }

    private static func control(_ identifier: String, in root: UIView) -> UIControl? {
        descendants(of: root).compactMap { $0 as? UIControl }.first { $0.accessibilityIdentifier == identifier }
    }

    private static func view(_ identifier: String, in root: UIView) -> UIView? {
        ([root] + descendants(of: root)).first { $0.accessibilityIdentifier == identifier }
    }

    private static func descendants(of root: UIView) -> [UIView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
