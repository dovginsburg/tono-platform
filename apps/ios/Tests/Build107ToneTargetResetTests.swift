// Build107ToneTargetResetTests.swift
// Build 107 — the target-switch reset contract for the top strip.
//
// THE CARD'S CLAIM. "After Coach is turned off, candidate buttons must remove
// `toneChipTapped`, restore `candidateTapped`, and clear stale tone axes."
//
// WHAT WAS ACTUALLY TRUE AT f692bfa (Build 106), measured not assumed:
//
//   • The target/action half was ALREADY satisfied, structurally. Build 106
//     (`TonoStripRouting.swift`) retired the time-shared strip: suggestions and
//     tone chips now own separate rows of `TonoStripButton`s whose `stripRole`
//     is `let` and whose selector is bound once in `makeStripStack` and never
//     mutated. There is no `removeTarget`/`addTarget` on the strip after
//     construction, so a candidate button cannot be wired to `toneChipTapped`
//     in the first place, and therefore has nothing to "restore".
//     `Build106SuggestionRoutingTests` already pins this and is green.
//
//   • The "clear stale tone axes" half was NOT satisfied. `setToneChipsEnabled`
//     recomputed `selectedToneAxes` from the persisted settings on EVERY call —
//     including the disable call — and then returned early without touching the
//     chip row. So after Coach was switched off the controller still carried a
//     populated tone-axis model and a fully painted, titled, accessibility-
//     labelled chip row behind the hidden stack. The only thing standing
//     between that stale row and a network rewrite was the single
//     `mode.activeRole == senderRole` check in `TonoStripRoutingPolicy`.
//
// WHAT BUILD 107 CHANGES. Turning Coach off now clears the axis model and
// repaints the chip row empty, so the refusal is over-determined: a tap that
// somehow reached `toneChipTapped` with the mode check broken would still be
// refused by `indexOutOfRange` against an empty `valueCount`. Defence in depth
// for the exact defect that shipped in Build 105 and was rejected on device.
//
// `testRollbackRed_*` is the negative control: it fails against the Build-106
// source and passes only against the Build-107 fix.

import XCTest
import UIKit
@testable import Tono

final class Build107ToneTargetResetTests: XCTestCase {

    // MARK: - The red case: stale tone axes survive Coach being turned off

    /// ROLLBACK-RED. Turning Coach off must leave no tone-axis state behind.
    /// Against Build 106 `selectedToneAxes` is still `["safer", …]` here.
    @MainActor
    func testRollbackRed_TurningCoachOffClearsTheToneAxisModel() throws {
        let controller = Self.makeController()
        let coach = try XCTUnwrap(Self.control(Const.coachButton, in: controller.view) as? UIButton)

        coach.sendActions(for: .touchUpInside)          // Coach on
        controller.view.layoutIfNeeded()
        XCTAssertFalse(
            controller.selectedToneAxesForTesting.isEmpty,
            "precondition: turning Coach on must populate the axis model"
        )
        XCTAssertEqual(controller.stripModeForTesting, .toneChips, "precondition: chips are the live row")

        coach.sendActions(for: .touchUpInside)          // Coach off
        controller.view.layoutIfNeeded()

        XCTAssertEqual(
            controller.stripModeForTesting, .suggestions,
            "turning Coach off must return the strip to the suggestion role"
        )
        XCTAssertTrue(
            controller.selectedToneAxesForTesting.isEmpty,
            """
            turning Coach off must clear the tone-axis model. Build 106 left it \
            populated, so a chip dispatch that slipped past the mode check would \
            have found a live axis to spend a network request on.
            """
        )
    }

    /// ROLLBACK-RED. The chip row itself must be repainted empty, not merely
    /// hidden — a hidden-but-titled row is the Build-105 shape that survived
    /// source review because the titles looked right.
    @MainActor
    func testRollbackRed_TurningCoachOffEmptiesTheChipRow() throws {
        let controller = Self.makeController()
        let coach = try XCTUnwrap(Self.control(Const.coachButton, in: controller.view) as? UIButton)

        coach.sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()
        XCTAssertTrue(
            Self.toneChipButtons(in: controller.view).contains { !($0.currentTitle ?? "").isEmpty },
            "precondition: Coach on paints chip titles"
        )

        coach.sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()

        for chip in Self.toneChipButtons(in: controller.view) {
            XCTAssertTrue(
                (chip.currentTitle ?? "").isEmpty,
                "chip \(chip.stripIndex) must carry no stale title once Coach is off"
            )
            XCTAssertTrue(chip.isHidden, "chip \(chip.stripIndex) must be hidden once Coach is off")
            XCTAssertNil(
                chip.accessibilityValue,
                "chip \(chip.stripIndex) must not announce a stale tone axis to VoiceOver"
            )
        }
    }

    // MARK: - The half Build 106 already fixed — pinned against regression

    /// The target/action table on the suggestion row is static across a full
    /// Coach on→off cycle. This was already true at Build 106; it is pinned
    /// here so the Build-107 reset cannot reintroduce dynamic targeting while
    /// "fixing" the axis model.
    @MainActor
    func testSuggestionButtonsKeepCandidateTappedAndNeverGainToneChipTapped() throws {
        let controller = Self.makeController()
        let coach = try XCTUnwrap(Self.control(Const.coachButton, in: controller.view) as? UIButton)

        for cycle in 0..<6 {
            coach.sendActions(for: .touchUpInside)      // on
            controller.view.layoutIfNeeded()
            coach.sendActions(for: .touchUpInside)      // off
            controller.view.layoutIfNeeded()
            controller.updateCandidateStrip(values: ["teh", "the", "ten"])
            controller.view.layoutIfNeeded()

            for button in Self.suggestionButtons(in: controller.view) {
                let actions = button.actions(forTarget: controller, forControlEvent: .touchUpInside) ?? []
                XCTAssertEqual(
                    actions, ["candidateTapped:"],
                    "cycle \(cycle): a suggestion button must carry exactly candidateTapped, forever"
                )
                XCTAssertFalse(
                    actions.contains("toneChipTapped:"),
                    "cycle \(cycle): the Build-105 welded-to-Coach state must stay unrepresentable"
                )
            }
        }
    }

    /// No `removeTarget`/`addTarget` may reappear on the strip. The Build-105
    /// defect was a live mutation of the target/action table; the Build-106
    /// structure forbids it and Build 107 must not walk that back.
    func testStripTargetsAreNeverMutatedAfterConstruction() throws {
        let source = try Self.keyboardControllerSource()
        XCTAssertFalse(
            source.contains("removeTarget"),
            "no strip button may have its target removed — roles are fixed at construction"
        )
        // The only addTarget calls permitted are the one-time bindings.
        let addTargets = source.components(separatedBy: "addTarget").count - 1
        XCTAssertGreaterThan(addTargets, 0, "sanity: the controller does bind targets once")
        XCTAssertFalse(
            source.contains("#selector(toneChipTapped(_:)), for: .touchUpInside)\n        }"),
            "tone-chip selectors must be bound only in makeStripStack"
        )
    }

    // MARK: - Behavioral consequence: no rewrite can start once Coach is off

    /// The whole point of the reset. After Coach is turned off, driving EVERY
    /// button on both rows — including the now-inert chip row — must start
    /// exactly zero Coach requests and open exactly zero Coach surfaces.
    @MainActor
    func testAfterCoachIsOffNoStripTapCanStartARewrite() throws {
        let controller = Self.makeController()
        let coach = try XCTUnwrap(Self.control(Const.coachButton, in: controller.view) as? UIButton)

        coach.sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()
        coach.sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()
        controller.updateCandidateStrip(values: ["alpha", "beta", "gamma"])
        controller.view.layoutIfNeeded()

        for button in Self.suggestionButtons(in: controller.view) {
            button.sendActions(for: .touchUpInside)
        }
        // Force the stale row to dispatch anyway — this is the hostile part.
        for chip in Self.toneChipButtons(in: controller.view) {
            chip.sendActions(for: .touchUpInside)
        }
        controller.view.layoutIfNeeded()

        XCTAssertEqual(
            controller.coachRequestsStarted, 0,
            "with Coach off, no strip tap on either row may start a rewrite"
        )
        XCTAssertNil(Self.view(Const.coachLoading, in: controller.view))
        XCTAssertNil(Self.view(Const.coachResults, in: controller.view))
        XCTAssertEqual(
            controller.stripRefusals[.roleMismatch, default: 0], 0,
            "no dispatch may arrive at the wrong handler at all"
        )
    }

    /// Re-enabling Coach after the reset must fully repopulate the row — the
    /// clear must not be sticky. Eight cycles, because a one-shot clear that
    /// broke re-entry would still pass a single round trip.
    @MainActor
    func testCoachStillReopensCleanlyAfterRepeatedResets() throws {
        let controller = Self.makeController()
        let coach = try XCTUnwrap(Self.control(Const.coachButton, in: controller.view) as? UIButton)

        for cycle in 0..<8 {
            coach.sendActions(for: .touchUpInside)      // on
            controller.view.layoutIfNeeded()
            XCTAssertEqual(
                controller.selectedToneAxesForTesting.first, "safer",
                "cycle \(cycle): Safer is the fixed first token on every reopen"
            )
            XCTAssertEqual(
                controller.selectedToneAxesForTesting.count, 3,
                "cycle \(cycle): Safer + exactly two configured tones"
            )
            let titled = Self.toneChipButtons(in: controller.view).filter { !($0.currentTitle ?? "").isEmpty }
            XCTAssertEqual(titled.count, 3, "cycle \(cycle): all three chips repaint on reopen")

            coach.sendActions(for: .touchUpInside)      // off
            controller.view.layoutIfNeeded()
            XCTAssertTrue(
                controller.selectedToneAxesForTesting.isEmpty,
                "cycle \(cycle): the reset must hold on every cycle, not just the first"
            )
        }
        XCTAssertEqual(controller.coachRequestsStarted, 0, "sixteen toggles start zero requests")
    }

    // MARK: - Helpers

    private enum Const {
        static let coachButton = "TonoKB.coachButton"
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

    private static func keyboardControllerSource() throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root
                .appendingPathComponent("KeyboardExtension")
                .appendingPathComponent("KeyboardViewController.swift"),
            encoding: .utf8
        )
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
