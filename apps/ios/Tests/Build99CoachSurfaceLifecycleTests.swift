// Build99CoachSurfaceLifecycleTests.swift
// Build 99 — exactly one coach surface, always.
//
// Loading, results, and error are three presentations of one logical
// surface. The physical-device build-98 defect: `presentCoachLoading()`
// tore down the keys, the emoji panel, and the error panel, but never the
// panel `coachContainer` pointed at — so a rewrite issued from the results
// state left the previous results panel parented in the body container
// *underneath* the new loading panel, and every further rewrite added
// another orphan. The container grew without bound and the stale rewrite
// stayed on screen behind the spinner.
//
// These tests drive the real `KeyboardViewController` UIKit hierarchy and
// assert the invariant behaviorally: at most one coach surface is parented
// at any instant, a completion replaces only the loading surface its own
// request installed, and every exit path (back, retry, emoji, keyboard
// reinstall) leaves zero coach surfaces behind.

import XCTest
import UIKit
@testable import Tono

final class Build99CoachSurfaceLifecycleTests: XCTestCase {

    // MARK: - results → new loading

    /// A rewrite issued while results are on screen must remove the results
    /// surface before installing the new loading surface — never stack one
    /// on top of the other.
    @MainActor
    func testRewriteFromResultsReplacesResultsWithExactlyOneLoadingSurface() throws {
        let controller = Self.makeController()

        controller.presentCoachResults(Self.response(text: "Could you help me?"))
        controller.view.layoutIfNeeded()
        XCTAssertEqual(Self.surfaceIdentifiers(in: controller), [Const.results])

        controller.presentCoachLoading(requestID: UUID())
        controller.view.layoutIfNeeded()

        XCTAssertEqual(
            Self.surfaceIdentifiers(in: controller),
            [Const.loading],
            "a new rewrite must leave exactly one coach surface — the new loading panel — with the prior results panel removed, not merely dereferenced"
        )
        XCTAssertNil(
            Self.view(Const.results, in: controller.view),
            "the stale results panel must be gone from the hierarchy entirely"
        )
    }

    /// Every ordered transition between the three presentations leaves
    /// exactly one surface parented — including loading→loading, the
    /// back-to-back rewrite the device hit.
    @MainActor
    func testEverySurfaceTransitionLeavesExactlyOneSurface() throws {
        let states: [(id: String, present: (KeyboardViewController) -> Void)] = [
            (Const.loading, { $0.presentCoachLoading(requestID: UUID()) }),
            (Const.results, { $0.presentCoachResults(Self.response(text: "Could you help me?")) }),
            (Const.error, { $0.presentCoachError(.timeout) }),
        ]
        for from in states {
            for to in states {
                let controller = Self.makeController()
                from.present(controller)
                controller.view.layoutIfNeeded()
                XCTAssertEqual(Self.surfaceIdentifiers(in: controller), [from.id])

                to.present(controller)
                controller.view.layoutIfNeeded()

                XCTAssertEqual(
                    Self.surfaceIdentifiers(in: controller),
                    [to.id],
                    "\(from.id) → \(to.id) must leave exactly one coach surface"
                )
            }
        }
    }

    // MARK: - completion → one results surface

    /// The completion replaces its own loading surface with exactly one
    /// results surface, through the entry point the shipping request path
    /// calls.
    @MainActor
    func testCompletionInstallsExactlyOneResultsSurface() throws {
        let controller = Self.makeController()
        let request = UUID()

        controller.presentCoachLoading(requestID: request)
        controller.view.layoutIfNeeded()
        XCTAssertEqual(Self.surfaceIdentifiers(in: controller), [Const.loading])

        XCTAssertTrue(
            controller.presentCoachResults(
                Self.response(text: "Could you help me?"),
                replacingLoadingFor: request
            ),
            "the live request's completion must be honored"
        )
        controller.view.layoutIfNeeded()

        XCTAssertEqual(
            Self.surfaceIdentifiers(in: controller),
            [Const.results],
            "completion must install exactly one results surface and remove the loading surface"
        )
        XCTAssertNotNil(Self.view("TonoKB.rewrites", in: controller.view), "the results content must be present")
    }

    // MARK: - repeated rewrites: no subview growth

    /// Ten loading→results round trips must not grow the body container by a
    /// single subview. This is the direct regression for the on-device
    /// accumulation.
    @MainActor
    func testRepeatedRewriteCyclesDoNotGrowTheBodyContainer() throws {
        let controller = Self.makeController()
        let body = try XCTUnwrap(Self.view(Const.body, in: controller.view))

        var baseline: Int?
        for cycle in 0..<10 {
            let request = UUID()
            controller.presentCoachLoading(requestID: request)
            controller.view.layoutIfNeeded()
            XCTAssertEqual(
                Self.surfaceIdentifiers(in: controller),
                [Const.loading],
                "cycle \(cycle): exactly one coach surface while loading"
            )

            controller.presentCoachResults(
                Self.response(text: "Rewrite \(cycle)"),
                replacingLoadingFor: request
            )
            controller.view.layoutIfNeeded()
            XCTAssertEqual(
                Self.surfaceIdentifiers(in: controller),
                [Const.results],
                "cycle \(cycle): exactly one coach surface after completion"
            )

            let count = body.subviews.count
            if let baseline {
                XCTAssertEqual(
                    count, baseline,
                    "cycle \(cycle): repeated rewrites must not grow the body container (orphaned coach panels)"
                )
            } else {
                baseline = count
            }
        }
    }

    // MARK: - stale completions cannot reattach

    /// A completion whose request was superseded by a newer rewrite must not
    /// touch the newer request's surface. The newer request's own completion
    /// still lands — the guard is ownership, not paralysis.
    @MainActor
    func testSupersededCompletionCannotReplaceANewerRequestsSurface() throws {
        let controller = Self.makeController()
        let superseded = UUID()
        let live = UUID()

        controller.presentCoachLoading(requestID: superseded)
        controller.presentCoachLoading(requestID: live)
        controller.view.layoutIfNeeded()

        XCTAssertFalse(
            controller.presentCoachResults(Self.response(text: "stale"), replacingLoadingFor: superseded),
            "a superseded request must not take over the surface a newer rewrite installed"
        )
        XCTAssertFalse(
            controller.presentCoachError(.timeout, replacingLoadingFor: superseded),
            "a superseded request's failure must not take over the newer rewrite's surface either"
        )
        controller.view.layoutIfNeeded()
        XCTAssertEqual(
            Self.surfaceIdentifiers(in: controller),
            [Const.loading],
            "the newer request's loading surface must survive its predecessor's completion untouched"
        )

        XCTAssertTrue(
            controller.presentCoachResults(Self.response(text: "fresh"), replacingLoadingFor: live),
            "the live request's completion must still be honored"
        )
        controller.view.layoutIfNeeded()
        XCTAssertEqual(Self.surfaceIdentifiers(in: controller), [Const.results])
    }

    /// A second delivery of the same request — after its loading surface was
    /// already replaced — must change nothing, not install a second results
    /// panel.
    @MainActor
    func testDuplicateCompletionDeliveryCannotReattach() throws {
        let controller = Self.makeController()
        let request = UUID()

        controller.presentCoachLoading(requestID: request)
        XCTAssertTrue(controller.presentCoachResults(Self.response(text: "first"), replacingLoadingFor: request))
        controller.view.layoutIfNeeded()
        let installed = try XCTUnwrap(Self.view(Const.results, in: controller.view))

        XCTAssertFalse(
            controller.presentCoachResults(Self.response(text: "duplicate"), replacingLoadingFor: request),
            "a duplicate delivery has no loading surface left to own — it must be refused"
        )
        controller.view.layoutIfNeeded()

        XCTAssertEqual(Self.surfaceIdentifiers(in: controller), [Const.results])
        XCTAssertTrue(
            Self.view(Const.results, in: controller.view) === installed,
            "the duplicate must not rebuild or replace the surface the first delivery installed"
        )
    }

    /// A completion arriving after the editing session was invalidated (the
    /// keyboard left the host) must fail closed: nothing reattaches.
    @MainActor
    func testCompletionAfterSessionInvalidationCannotReattach() throws {
        let controller = Self.makeController()
        let request = UUID()
        controller.presentCoachLoading(requestID: request)

        // The lifecycle boundary that cancels in-flight coach work.
        controller.viewWillDisappear(false)
        controller.viewDidDisappear(false)

        XCTAssertFalse(
            controller.presentCoachResults(Self.response(text: "late"), replacingLoadingFor: request),
            "a completion delivered after cancellation must not reattach"
        )
        XCTAssertFalse(
            controller.presentCoachError(.timeout, replacingLoadingFor: request),
            "a failure delivered after cancellation must not reattach"
        )
        controller.view.layoutIfNeeded()
        XCTAssertNil(
            Self.view(Const.results, in: controller.view),
            "no results surface may appear for an invalidated session"
        )
    }

    /// The shipped completion gate. A completion is honored only when its
    /// request is still the active one *and* the installed loading surface
    /// is the one that request installed.
    func testCompletionGateHonorsOnlyTheOwningRequest() {
        let mine = UUID()
        let other = UUID()
        typealias Gate = KeyboardViewController.CoachCompletionGate

        XCTAssertTrue(
            Gate.accepts(completion: mine, activeRequestID: mine, loadingSurfaceRequestID: mine),
            "the live request owning the installed loading surface must be honored"
        )
        XCTAssertFalse(
            Gate.accepts(completion: mine, activeRequestID: other, loadingSurfaceRequestID: other),
            "a superseded request must never take over the surface a newer request installed"
        )
        XCTAssertFalse(
            Gate.accepts(completion: mine, activeRequestID: nil, loadingSurfaceRequestID: mine),
            "a completion arriving after cancellation/invalidation must fail closed"
        )
        XCTAssertFalse(
            Gate.accepts(completion: mine, activeRequestID: mine, loadingSurfaceRequestID: nil),
            "a second delivery, after this request's loading surface was already replaced, must not reattach"
        )
        XCTAssertFalse(
            Gate.accepts(completion: mine, activeRequestID: mine, loadingSurfaceRequestID: other),
            "a completion must replace only its own loading surface"
        )
    }

    // MARK: - error / retry / back cleanup

    /// An error replaces the loading surface, and Back leaves no coach
    /// surface behind while restoring the keys.
    @MainActor
    func testErrorReplacesLoadingAndBackLeavesNoCoachSurface() throws {
        let controller = Self.makeController()

        controller.presentCoachLoading(requestID: UUID())
        controller.presentCoachError(.timeout)
        controller.view.layoutIfNeeded()

        XCTAssertEqual(
            Self.surfaceIdentifiers(in: controller),
            [Const.error],
            "the error surface must replace the loading surface, not stack on it"
        )
        XCTAssertNotNil(Self.view("TonoKB.coachErrorDetail", in: controller.view))

        let errorPanel = try XCTUnwrap(Self.view(Const.error, in: controller.view))
        let back = try XCTUnwrap(
            Self.descendants(of: errorPanel).compactMap { $0 as? UIButton }
                .first { $0.currentTitle == "Back" },
            "the error surface must offer Back"
        )
        back.sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()

        XCTAssertTrue(
            Self.surfaceIdentifiers(in: controller).isEmpty,
            "Back must leave zero coach surfaces parented"
        )
        XCTAssertNotNil(
            Self.view("TonoKB.letter.a", in: controller.view),
            "Back must restore the keyboard layout"
        )
    }

    /// Back from the results surface is the same contract: nothing coach-side
    /// survives it.
    @MainActor
    func testBackFromResultsLeavesNoCoachSurface() throws {
        let controller = Self.makeController()
        controller.presentCoachLoading(requestID: UUID())
        controller.presentCoachResults(Self.response(text: "Could you help me?"))
        controller.view.layoutIfNeeded()

        let back = try XCTUnwrap(
            Self.view("TonoKB.coachBack", in: controller.view) as? UIButton,
            "the results surface must offer Back"
        )
        back.sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()

        XCTAssertTrue(Self.surfaceIdentifiers(in: controller).isEmpty)
        XCTAssertNotNil(Self.view("TonoKB.letter.a", in: controller.view))
    }

    /// Retry tears the error surface down before it starts anything new: no
    /// orphan error panel survives the retry, in either outcome.
    @MainActor
    func testRetryLeavesNoOrphanErrorSurface() throws {
        let controller = Self.makeController()

        controller.presentCoachLoading(requestID: UUID())
        controller.presentCoachError(.timeout)
        controller.view.layoutIfNeeded()

        let retry = try XCTUnwrap(
            Self.view("TonoKB.coachRetry", in: controller.view) as? UIButton,
            "the error surface must offer Retry"
        )
        retry.sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()

        XCTAssertNil(
            Self.view(Const.error, in: controller.view),
            "Retry must remove the error surface before beginning any new work"
        )
        XCTAssertLessThanOrEqual(
            Self.surfaceIdentifiers(in: controller).count, 1,
            "Retry must never leave more than one coach surface parented"
        )
        // With no host document there is nothing to rewrite, so retry lands on
        // the empty state rather than issuing a request.
        XCTAssertNotNil(
            Self.view("TonoKB.emptyBanner", in: controller.view),
            "retry with no draft must surface the empty state, not a request"
        )
        XCTAssertEqual(
            controller.coachRequestsStarted, 0,
            "retry without a capturable draft must start zero requests"
        )
    }

    /// A leftover surface from any state is swept when another body-container
    /// panel takes over — here, the emoji panel.
    @MainActor
    func testEmojiPanelSweepsCoachSurfaces() throws {
        let controller = Self.makeController()

        controller.presentCoachResults(Self.response(text: "hello"))
        controller.view.layoutIfNeeded()

        let emoji = try XCTUnwrap(Self.view("TonoKB.emojiToggle", in: controller.view) as? UIButton)
        emoji.sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()

        XCTAssertTrue(
            Self.surfaceIdentifiers(in: controller).isEmpty,
            "opening the emoji panel must sweep every coach surface"
        )
        XCTAssertNotNil(Self.view("TonoKB.emojiPanel", in: controller.view))
    }

    // MARK: - one request per tap

    /// One tap → one request → one loading surface. A tap arriving while a
    /// request is in flight is refused by the busy gate, so a rewrite can
    /// never fan out into two provider calls.
    @MainActor
    func testTapWhileRequestInFlightDoesNotStartASecondRequest() throws {
        let controller = Self.makeController()

        // Reveal the tone chips (this alone must not start a request).
        let tono = try XCTUnwrap(Self.view("TonoKB.coachButton", in: controller.view) as? UIButton)
        tono.sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()
        XCTAssertEqual(controller.coachRequestsStarted, 0, "revealing the chips must not start a request")

        controller.runCoach(draft: "please send me the file", axis: "safer")
        controller.view.layoutIfNeeded()
        XCTAssertEqual(controller.coachRequestsStarted, 1, "one tap starts exactly one request")
        XCTAssertEqual(
            Self.surfaceIdentifiers(in: controller),
            [Const.loading],
            "the in-flight request owns exactly one loading surface"
        )

        let chips = try XCTUnwrap(Self.view("TonoKB.candidates", in: controller.view) as? UIStackView)
        for chip in chips.arrangedSubviews.compactMap({ $0 as? UIButton }) where !chip.isHidden {
            chip.sendActions(for: .touchUpInside)
        }
        controller.view.layoutIfNeeded()

        XCTAssertEqual(
            controller.coachRequestsStarted, 1,
            "taps arriving while a request is in flight must be refused — one tap, one request"
        )
        XCTAssertEqual(
            Self.surfaceIdentifiers(in: controller),
            [Const.loading],
            "a refused tap must not install a second loading surface"
        )
    }

    /// Surface churn is not a request trigger: re-presenting loading, results
    /// and error never issues coach work of its own.
    @MainActor
    func testSurfaceChurnStartsNoRequests() throws {
        let controller = Self.makeController()
        for _ in 0..<5 {
            controller.presentCoachLoading(requestID: UUID())
            controller.presentCoachResults(Self.response(text: "x"))
            controller.presentCoachError(.timeout)
        }
        controller.view.layoutIfNeeded()

        XCTAssertEqual(
            controller.coachRequestsStarted, 0,
            "installing surfaces must never start a coach request"
        )
        XCTAssertEqual(Self.surfaceIdentifiers(in: controller), [Const.error])
    }

    // MARK: - Build 115: the Apple route is now the LIVE route

    /// Build 99 pinned "neither staged Apple route is reachable from the coach
    /// surface", and that was the right contract while the on-device path was
    /// dark. Build 115 is the change that turns it on, because the dark path was
    /// the defect: with no connection the keyboard produced no rewrite at all.
    ///
    /// What replaces it is the contract that now matters — the two flags mean
    /// DIFFERENT things and only one of them may default open:
    ///
    ///   * `appleIntelligenceRewriteEnabled` is a REMOTE KILL SWITCH and defaults
    ///     ON, because on-device rewriting is the default behaviour wherever the
    ///     model is actually available. The person's own opt-out is not this flag
    ///     — see `LocalRewritePreferenceStore`.
    ///   * `appleIntelligenceAllowsSaferRoute` is the Safer corpus-quality gate
    ///     and still defaults OFF. Fail-closed, exactly as before.
    func testTheSaferCorpusGateStillDefaultsClosedAndTheKillSwitchDoesNot() throws {
        let flags = try Self.source("Shared/FeatureFlags.swift")
        let defaultOffBranch = try XCTUnwrap(
            flags.components(separatedBy: "public var defaultValue: Bool {").last?
                .components(separatedBy: "return false").first,
            "FeatureFlag.defaultValue must keep an explicit default-OFF branch"
        )
        XCTAssertTrue(
            defaultOffBranch.contains("appleIntelligenceAllowsSaferRoute"),
            "the Safer-axis corpus gate must stay OFF by default"
        )
        XCTAssertFalse(
            defaultOffBranch.contains("appleIntelligenceRewriteEnabled"),
            "the on-device kill switch defaults ON in Build 115 — it is not the user's switch"
        )
    }

    /// And the coach path now DOES reach it. This is the exact inversion of the
    /// Build 99 assertion, kept as a test rather than deleted so the change is
    /// visible in the suite rather than silent.
    func testTheCoachPathNowReachesTheOnDeviceRoute() throws {
        let controller = try Self.source("KeyboardExtension/KeyboardViewController.swift")
        XCTAssertTrue(
            controller.contains("AppleRewriteBridge"),
            "the live keyboard must reach the on-device engine — its absence was the defect"
        )
        XCTAssertTrue(
            controller.contains("appleIntelligenceAllowsSaferRoute"),
            "the Safer corpus gate must still be consulted on the live path"
        )
    }

    // MARK: - Helpers

    private enum Const {
        static let body = "TonoKB.body"
        static let loading = "TonoKB.coachLoading"
        static let results = "TonoKB.coachResults"
        static let error = "TonoKB.coachError"
        static let all: Set<String> = [loading, results, error]
    }

    @MainActor
    private static func makeController() -> KeyboardViewController {
        let controller = KeyboardViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 320)
        controller.view.layoutIfNeeded()
        return controller
    }

    private static func response(text: String) -> TonoCoachClient.CoachResponse {
        TonoCoachClient.CoachResponse(
            riskLevel: "medium",
            perception: "",
            subtext: "",
            reason: nil,
            suggestions: [
                TonoCoachClient.CoachRewrite(axis: "safer", text: text, rationale: nil, riskAfter: "low")
            ],
            flags: []
        )
    }

    /// Coach surfaces parented anywhere in the controller's hierarchy, in
    /// hierarchy order. The invariant is that this is never longer than one.
    @MainActor
    private static func surfaceIdentifiers(in controller: KeyboardViewController) -> [String] {
        descendants(of: controller.view)
            .compactMap { $0.accessibilityIdentifier }
            .filter { Const.all.contains($0) }
    }

    private static func view(_ identifier: String, in root: UIView) -> UIView? {
        ([root] + descendants(of: root)).first { $0.accessibilityIdentifier == identifier }
    }

    private static func descendants(of root: UIView) -> [UIView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private static func source(_ relative: String, file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // <srcroot>/Tests
            .deletingLastPathComponent()   // <srcroot>
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }
}
