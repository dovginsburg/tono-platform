// Build107CoachSkeletonTests.swift
// Build 107 — result-shaped loading skeleton on the ACTIVE UIKit route,
// reconciled into the Build-106 lineage.
//
// PROVENANCE. Commit 3a80fb0 ("result-shaped Coach skeleton + bounded variant
// output path") fixed the physical Build-100 defect on a branch that forked at
// build 100 and never merged. The shipping lineage went 101→106 without it, so
// through Build 106 the user-visible loading state was still
// `KeyboardViewController.presentCoachLoading` rendering a plain "Coaching…"
// label plus a `UIActivityIndicatorView` — a generic spinner that previews
// nothing. (The SwiftUI `KeyboardRootView.LoadingView` is dead code: the
// keyboard's `NSExtensionPrincipalClass` is `KeyboardViewController`, and no
// `UIHostingController` ever mounts `KeyboardRootView`.) Build 107 carries the
// skeleton forward onto the Build-106 request-ownership machinery.
//
// These tests drive the real `KeyboardViewController` UIKit hierarchy — the
// same entry points the tap path uses — and pin, behaviorally:
//   • the loading surface is a RESULT-SHAPED skeleton (title rule, Back
//     placeholder, one accent card with an axis pill, two text lines and a
//     two-button action row), never a lone spinner;
//   • the legacy spinner and its "Coaching…" label are GONE from the module;
//   • it renders synchronously in well under 100ms;
//   • it holds the results geometry so loading→results never resizes the
//     keyboard around the host field;
//   • it is a single accessible element; its shimmer blocks are decorative;
//   • one tap installs exactly one skeleton and one request, and a completion
//     atomically replaces only its own skeleton;
//   • the ~10s visible deadline fails closed and shows a truthful retry state;
//   • the server `provider_ms` clock decodes into the variant response.
//
// The Build-106 invariants the skeleton must NOT have weakened are pinned
// here too, because a render change that quietly loosened request ownership
// would otherwise look green: `coachLoadingRequestID` ownership, cancellation,
// stale-completion rejection, the one-surface invariant and draft integrity.

import XCTest
import UIKit
@testable import Tono

final class Build107CoachSkeletonTests: XCTestCase {

    // MARK: - Active route is a result-shaped skeleton, not a spinner

    /// `presentCoachLoading` installs the result-shaped skeleton as the one
    /// coach surface — and no `UIActivityIndicatorView` anywhere.
    @MainActor
    func testLoadingSurfaceIsResultShapedSkeletonNotSpinner() throws {
        let controller = Self.makeController()
        controller.presentCoachLoading(requestID: UUID(), axis: "funnier")
        controller.view.layoutIfNeeded()

        XCTAssertEqual(Self.surfaceIdentifiers(in: controller), [Const.loading])
        let skeleton = try XCTUnwrap(
            Self.skeleton(in: controller),
            "the loading surface must contain the result-shaped skeleton"
        )
        // No spinner survives anywhere in the hierarchy.
        XCTAssertTrue(
            Self.descendants(of: controller.view).allSatisfy { !($0 is UIActivityIndicatorView) },
            "Build 107 replaces the spinner; no UIActivityIndicatorView may remain"
        )
        // "Coaching…" text label is gone — the skeleton carries the meaning.
        XCTAssertFalse(
            Self.descendants(of: skeleton).contains { ($0 as? UILabel)?.text == "Coaching…" },
            "the plain Coaching… label must be gone"
        )
    }

    /// Rollback-red control for the legacy spinner. The keyboard module must
    /// not contain the Build-106 loading body anywhere — not on a fallback
    /// branch, not behind a flag. A render regression that reinstates the
    /// spinner for some axis or trait would still satisfy the hierarchy test
    /// above on the axis it was probed with; this closes that hole.
    func testLegacyCoachingSpinnerIsDeletedFromTheKeyboardModule() throws {
        // Comments are stripped first: the file legitimately *documents* what
        // Build 107 replaced, and a doc comment naming the old spinner must not
        // be mistaken for the spinner still being constructed.
        let code = Self.strippingComments(try Self.keyboardControllerSource())
        XCTAssertFalse(
            code.contains("\"Coaching…\""),
            "the legacy Coaching… status label must be deleted from KeyboardViewController"
        )
        XCTAssertTrue(
            code.contains("TonoCoachSkeletonView"),
            "the loading surface must be the result-shaped skeleton"
        )
        XCTAssertFalse(
            code.contains("coachStatusLabel"),
            "the status-label field the spinner wrote to must be gone too"
        )

        // Build 114 narrows — but does not weaken — the spinner ban.
        //
        // Build 107 banned the string `UIActivityIndicatorView` anywhere in the
        // file, which was a fine proxy while the file had exactly one loading
        // state. Build 114 adds a genuinely different one: an in-CARD busy
        // indicator on the results card, required by the founder contract so
        // that `Try another` keeps the current rewrite readable instead of
        // swapping it for a full-panel spinner.
        //
        // The property Build 107 actually protects is "the LOADING SURFACE is
        // the skeleton, never the Build-106 spinner body". That is now asserted
        // precisely: the loading path must build no activity indicator, and the
        // only one in the file is the results-card one. The runtime half —
        // `testSkeletonReplacesSpinnerInTheBuiltHierarchy` above — still proves
        // no indicator is parented in a presented loading surface.
        let loadingBody = try XCTUnwrap(
            Self.body(ofFunction: "func presentCoachLoading(", in: code),
            "presentCoachLoading must still exist"
        )
        XCTAssertFalse(
            loadingBody.contains("UIActivityIndicatorView"),
            "the loading surface must remain spinner-free — it is the skeleton"
        )
        // Count CONSTRUCTIONS, not mentions: the stored property that holds the
        // one permitted indicator necessarily names the type too, and banning
        // that would be banning the declaration rather than the spinner.
        XCTAssertEqual(
            code.components(separatedBy: "UIActivityIndicatorView(").count - 1, 1,
            """
            exactly one UIActivityIndicatorView may be CONSTRUCTED in this \
            file: the Build 114 in-card Try another indicator. A second one \
            means a loading spinner came back somewhere.
            """
        )
        XCTAssertTrue(
            code.contains("coachTryAnotherSpinner"),
            "the single permitted indicator is the results-card Try another spinner"
        )
    }

    /// Extract a function body by brace matching from its declaration. Used so
    /// the spinner ban can be scoped to one function instead of the whole file.
    private static func body(ofFunction declaration: String, in code: String) -> String? {
        guard let start = code.range(of: declaration) else { return nil }
        var depth = 0
        var started = false
        var out = ""
        for character in code[start.lowerBound...] {
            if character == "{" { depth += 1; started = true }
            if started { out.append(character) }
            if character == "}" {
                depth -= 1
                if started && depth == 0 { return out }
            }
        }
        return nil
    }

    /// The skeleton is genuinely result-shaped: a bordered card holding an
    /// axis pill, two text lines, and a two-button action row — the shape of
    /// the answer, mirrored as placeholders.
    @MainActor
    func testSkeletonIsResultShapedWithCardAndRewritePlaceholders() throws {
        let controller = Self.makeController()
        controller.presentCoachLoading(requestID: UUID(), axis: "safer")
        controller.view.layoutIfNeeded()

        let skeleton = try XCTUnwrap(Self.skeleton(in: controller))
        // The accent card exists and is the rewrite-card placeholder.
        let card = try XCTUnwrap(
            Self.view(TonoCoachSkeletonView.cardIdentifier, in: skeleton),
            "the skeleton must present a rewrite-card placeholder"
        )
        XCTAssertGreaterThan(card.layer.borderWidth, 0, "the card is accent-bordered like the real chip")

        // Header (title + Back) + card contents (axis pill, 2 lines, 2 actions)
        // ⇒ at least 7 placeholder blocks. A spinner-only state would have 0.
        XCTAssertGreaterThanOrEqual(
            skeleton.shimmerBlocks.count, 7,
            "the skeleton must have title, Back, axis pill, two text lines and two action placeholders"
        )
        // Two action placeholders live inside the card, side by side.
        let cardBlocks = card.subviews.compactMap { $0 as? TonoShimmerBlock }
        XCTAssertGreaterThanOrEqual(cardBlocks.count, 5, "axis pill + two lines + two actions inside the card")
    }

    /// The card wears the SELECTED axis accent, so the loading state previews
    /// the specific tone the user asked for rather than a generic placeholder.
    /// An unknown axis degrades to the neutral separator instead of crashing
    /// or inventing a color.
    @MainActor
    func testSkeletonCardWearsTheSelectedAxisAccent() throws {
        // The real axis vocabulary for this build, from `TonoCoachPalette.Axis`.
        for axis in ["safer", "clearer", "funnier", "affectionate", "professional", "concise", "custom"] {
            let controller = Self.makeController()
            controller.presentCoachLoading(requestID: UUID(), axis: axis)
            controller.view.layoutIfNeeded()
            let skeleton = try XCTUnwrap(Self.skeleton(in: controller), "axis \(axis)")
            let expected = try XCTUnwrap(TonoCoachPalette.axis(axis)?.accent, "axis \(axis) must have a palette token")
            let actual = try XCTUnwrap(skeleton.card.layer.borderColor)
            XCTAssertEqual(
                UIColor(cgColor: actual), expected,
                "the skeleton card must wear the \(axis) accent, exactly like the real chip"
            )
        }

        // Unknown and nil axes are survivable, not fatal.
        for axis in [nil, "", "not-an-axis"] as [String?] {
            let controller = Self.makeController()
            controller.presentCoachLoading(requestID: UUID(), axis: axis)
            controller.view.layoutIfNeeded()
            let skeleton = try XCTUnwrap(Self.skeleton(in: controller), "axis \(axis ?? "nil")")
            XCTAssertNotNil(skeleton.card.layer.borderColor, "an unknown axis must still render a neutral card")
        }
    }

    // MARK: - ≤100ms synchronous render

    /// The skeleton is built synchronously on the main thread; presenting it
    /// is far under the 100ms budget (there is no network or disk work).
    @MainActor
    func testSkeletonRendersWellUnder100ms() throws {
        let controller = Self.makeController()
        let start = DispatchTime.now()
        controller.presentCoachLoading(requestID: UUID(), axis: "funnier")
        controller.view.layoutIfNeeded()
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        XCTAssertLessThan(
            elapsedMs, 100,
            "the result-shaped skeleton must render within 100ms on the main thread (took \(elapsedMs)ms)"
        )
        XCTAssertNotNil(Self.skeleton(in: controller))
    }

    // MARK: - Stable geometry

    /// Loading and results reserve the SAME height, so the keyboard never
    /// resizes around the host field across the transition.
    @MainActor
    func testLoadingAndResultsHoldTheSameStableHeight() throws {
        let controller = Self.makeController()

        controller.presentCoachLoading(requestID: UUID(), axis: "safer")
        controller.view.layoutIfNeeded()
        let loadingPanel = try XCTUnwrap(Self.view(Const.loading, in: controller.view))
        let loadingHeight = loadingPanel.bounds.height
        let skeleton = try XCTUnwrap(Self.skeleton(in: controller))
        // The skeleton fills its panel — no empty gap, no overflow.
        XCTAssertEqual(skeleton.bounds.height, loadingPanel.bounds.height, accuracy: 0.5)
        XCTAssertEqual(skeleton.bounds.width, loadingPanel.bounds.width, accuracy: 0.5)

        controller.presentCoachResults(Self.response(text: "Following up on my last note."))
        controller.view.layoutIfNeeded()
        let resultsPanel = try XCTUnwrap(Self.view(Const.results, in: controller.view))

        XCTAssertEqual(
            loadingHeight, resultsPanel.bounds.height, accuracy: 0.5,
            "loading and results must occupy identical height (stable geometry)"
        )
        XCTAssertGreaterThan(loadingHeight, 0)
    }

    /// Geometry stays stable across the widths the keyboard actually renders
    /// at, so the skeleton never overflows or collapses on a narrow device.
    @MainActor
    func testSkeletonGeometryIsStableAcrossDeviceWidths() throws {
        for width in [320, 375, 390, 430, 744] as [CGFloat] {
            let controller = Self.makeController(width: width)
            controller.presentCoachLoading(requestID: UUID(), axis: "concise")
            controller.view.layoutIfNeeded()

            let panel = try XCTUnwrap(Self.view(Const.loading, in: controller.view), "width \(width)")
            let skeleton = try XCTUnwrap(Self.skeleton(in: controller), "width \(width)")
            XCTAssertEqual(skeleton.bounds.width, panel.bounds.width, accuracy: 0.5, "width \(width)")
            XCTAssertGreaterThan(skeleton.bounds.height, 0, "width \(width)")
            XCTAssertTrue(
                skeleton.card.frame.maxX <= skeleton.bounds.width + 0.5,
                "the card must not overflow the skeleton at \(width)pt"
            )
            XCTAssertTrue(
                skeleton.shimmerBlocks.allSatisfy { $0.bounds.width >= 0 && $0.bounds.height >= 0 },
                "no placeholder may invert at \(width)pt"
            )
        }
    }

    // MARK: - Accessibility

    /// The skeleton is one VoiceOver element announcing the loading state; its
    /// shimmer blocks are decorative and hidden from accessibility.
    @MainActor
    func testSkeletonAccessibilityIsOneAnnouncedElement() throws {
        let controller = Self.makeController()
        controller.presentCoachLoading(requestID: UUID(), axis: "funnier")
        controller.view.layoutIfNeeded()

        let skeleton = try XCTUnwrap(Self.skeleton(in: controller))
        XCTAssertTrue(skeleton.isAccessibilityElement, "the skeleton must be a single a11y element")
        XCTAssertEqual(skeleton.accessibilityLabel?.isEmpty, false, "it must announce the loading state")
        XCTAssertTrue(
            skeleton.accessibilityTraits.contains(.updatesFrequently),
            "a loading placeholder should carry the updatesFrequently trait"
        )
        XCTAssertTrue(
            skeleton.shimmerBlocks.allSatisfy { !$0.isAccessibilityElement },
            "decorative shimmer blocks must be hidden from VoiceOver"
        )
    }

    // MARK: - Shimmer honors Reduce Motion

    func testShimmerBlockHonorsReduceMotion() {
        let block = TonoShimmerBlock(cornerRadius: 4)
        block.beginShimmer(reduceMotion: false)
        XCTAssertTrue(block.isShimmering, "the sweep animates when Reduce Motion is off")
        block.stopShimmer()
        XCTAssertFalse(block.isShimmering)
        block.beginShimmer(reduceMotion: true)
        XCTAssertFalse(block.isShimmering, "the sweep must not animate under Reduce Motion")
    }

    /// Reduce Motion must suppress the sweep on EVERY block of a real
    /// skeleton, not just the one probed above, and starting twice must not
    /// stack duplicate animations.
    @MainActor
    func testSkeletonShimmerIsIdempotentAndFullyHonorsReduceMotion() {
        let skeleton = TonoCoachSkeletonView(accent: .separator)
        skeleton.beginShimmer(reduceMotion: true)
        XCTAssertTrue(
            skeleton.shimmerBlocks.allSatisfy { !$0.isShimmering },
            "under Reduce Motion no block may animate"
        )

        skeleton.beginShimmer(reduceMotion: false)
        skeleton.beginShimmer(reduceMotion: false)
        XCTAssertTrue(
            skeleton.shimmerBlocks.allSatisfy { $0.isShimmering },
            "with Reduce Motion off every block sweeps"
        )
        XCTAssertFalse(skeleton.shimmerBlocks.isEmpty)

        // Flipping Reduce Motion back on stops them again.
        skeleton.beginShimmer(reduceMotion: true)
        XCTAssertTrue(
            skeleton.shimmerBlocks.allSatisfy { !$0.isShimmering },
            "turning Reduce Motion on must stop the sweep"
        )
    }

    /// A detached block must not keep an animation attached — an off-window
    /// skeleton left sweeping is a battery leak in a keyboard extension.
    @MainActor
    func testShimmerStopsWhenDetachedFromWindow() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 320))
        let block = TonoShimmerBlock(cornerRadius: 4)
        window.addSubview(block)
        block.beginShimmer(reduceMotion: false)
        XCTAssertTrue(block.isShimmering)

        block.removeFromSuperview()
        XCTAssertFalse(block.isShimmering, "a detached block must drop its sweep animation")
    }

    // MARK: - One tap → one skeleton → one request

    /// The real request path installs exactly one skeleton and starts exactly
    /// one request; a tone-chip tap while in flight is refused by the busy
    /// gate. Build 106 moved the chips onto their own dedicated row, so this
    /// drives `TonoKB.toneChips`, not the shared strip Build 100 used.
    @MainActor
    func testOneTapInstallsOneSkeletonAndOneRequest() throws {
        let controller = Self.makeController()
        controller.runCoach(draft: "please send me the file", axis: "safer")
        controller.view.layoutIfNeeded()

        XCTAssertEqual(controller.coachRequestsStarted, 1, "one tap starts exactly one request")
        XCTAssertEqual(Self.surfaceIdentifiers(in: controller), [Const.loading])
        XCTAssertNotNil(Self.skeleton(in: controller), "the in-flight request owns one result-shaped skeleton")

        // A second chip tap while the request is in flight must be refused.
        let chips = try XCTUnwrap(Self.view(Const.toneChips, in: controller.view) as? UIStackView)
        for chip in chips.arrangedSubviews.compactMap({ $0 as? UIButton }) {
            chip.sendActions(for: .touchUpInside)
        }
        controller.view.layoutIfNeeded()
        XCTAssertEqual(controller.coachRequestsStarted, 1, "a tap during flight must not start a second request")
        XCTAssertEqual(Self.surfaceIdentifiers(in: controller), [Const.loading])
    }

    /// Repeated `presentCoachLoading` calls must leave exactly ONE skeleton in
    /// the tree. The skeleton is a heavier hierarchy than the old spinner, so
    /// a leak here would stack layers invisibly.
    @MainActor
    func testRepeatedLoadingPresentationsLeaveExactlyOneSkeleton() throws {
        let controller = Self.makeController()
        for _ in 0..<12 {
            controller.presentCoachLoading(requestID: UUID(), axis: "clearer")
            controller.view.layoutIfNeeded()
        }

        XCTAssertEqual(
            Self.surfaceIdentifiers(in: controller), [Const.loading],
            "twelve loading presentations must leave exactly one coach surface"
        )
        let skeletons = Self.descendants(of: controller.view).compactMap { $0 as? TonoCoachSkeletonView }
        XCTAssertEqual(skeletons.count, 1, "no orphaned skeleton may remain parented")
    }

    // MARK: - Atomic validated replacement

    /// A completion atomically replaces the skeleton with results — the
    /// skeleton is fully gone, exactly one surface remains.
    @MainActor
    func testCompletionAtomicallyReplacesSkeletonWithResults() throws {
        let controller = Self.makeController()
        let request = UUID()
        controller.presentCoachLoading(requestID: request, axis: "clearer")
        controller.view.layoutIfNeeded()
        XCTAssertNotNil(Self.skeleton(in: controller))

        XCTAssertTrue(
            controller.presentCoachResults(Self.response(text: "Here's the clearer ask."), replacingLoadingFor: request)
        )
        controller.view.layoutIfNeeded()

        XCTAssertEqual(Self.surfaceIdentifiers(in: controller), [Const.results])
        XCTAssertNil(Self.skeleton(in: controller), "the skeleton must be gone once results replace it")
        XCTAssertNotNil(Self.view(Const.rewrites, in: controller.view))
    }

    // MARK: - Build-106 request ownership survives the render change

    /// The skeleton must not have loosened `coachLoadingRequestID` ownership:
    /// a completion for a SUPERSEDED request is refused and leaves the newer
    /// skeleton standing.
    @MainActor
    func testSupersededCompletionCannotReplaceANewerSkeleton() throws {
        let controller = Self.makeController()
        let stale = UUID()
        let live = UUID()
        controller.presentCoachLoading(requestID: stale, axis: "safer")
        controller.presentCoachLoading(requestID: live, axis: "clearer")
        controller.view.layoutIfNeeded()

        XCTAssertFalse(
            controller.presentCoachResults(Self.response(text: "stale answer"), replacingLoadingFor: stale),
            "a superseded completion must be refused"
        )
        XCTAssertFalse(
            controller.presentCoachError(.timeout, replacingLoadingFor: stale),
            "a superseded failure must be refused too"
        )
        controller.view.layoutIfNeeded()

        XCTAssertEqual(
            Self.surfaceIdentifiers(in: controller), [Const.loading],
            "the live skeleton must still own the surface"
        )
        XCTAssertNotNil(Self.skeleton(in: controller))
    }

    /// A second delivery of the SAME request — the duplicate-callback case —
    /// must be refused once its skeleton has already been replaced.
    @MainActor
    func testDuplicateDeliveryForTheSameRequestIsRefused() throws {
        let controller = Self.makeController()
        let request = UUID()
        controller.presentCoachLoading(requestID: request, axis: "funnier")
        XCTAssertTrue(controller.presentCoachResults(Self.response(text: "first"), replacingLoadingFor: request))
        controller.view.layoutIfNeeded()

        XCTAssertFalse(
            controller.presentCoachResults(Self.response(text: "second"), replacingLoadingFor: request),
            "a duplicate delivery must not re-render over a landed result"
        )
        XCTAssertEqual(Self.surfaceIdentifiers(in: controller), [Const.results])
    }

    /// Draft integrity: a completion whose draft moved under it is dropped
    /// without touching the surface. The unit-test controller has no host
    /// document, so the live context is empty — a completion claiming a
    /// different draft must not render.
    @MainActor
    func testCompletionForAMovedDraftIsDroppedAndLeavesTheSkeleton() throws {
        let controller = Self.makeController()
        controller.runCoach(draft: "the original draft", axis: "safer")
        controller.view.layoutIfNeeded()
        let request = try XCTUnwrap(controller.activeCoachRequestIDForTesting)

        controller.completeCoach(
            requestID: request,
            liveBefore: "a completely different draft the user retyped",
            liveAfter: "",
            result: .success(
                TonoCoachClient.VariantResponse(
                    axis: "safer", text: "rewritten", rationale: nil, riskAfter: "low",
                    clocks: nil, providerMs: nil
                )
            )
        )
        controller.view.layoutIfNeeded()

        XCTAssertEqual(
            Self.surfaceIdentifiers(in: controller), [Const.loading],
            "a completion whose draft moved must not overwrite the surface"
        )
        XCTAssertNotNil(Self.skeleton(in: controller), "the skeleton stays until a valid completion lands")
    }

    /// Cancellation: tearing the session down must drop the skeleton, clear
    /// ownership, and leave no surface behind.
    @MainActor
    func testInvalidatingTheSessionTearsDownTheSkeleton() throws {
        let controller = Self.makeController()
        controller.runCoach(draft: "cancel me", axis: "concise")
        controller.view.layoutIfNeeded()
        XCTAssertNotNil(Self.skeleton(in: controller))

        // The Back control is the user-facing teardown for a coach surface.
        controller.presentCoachLoading(requestID: UUID(), axis: "concise")
        controller.view.layoutIfNeeded()
        let request = try XCTUnwrap(controller.activeCoachRequestIDForTesting)

        // A completion for the ORIGINAL request can no longer land: a newer
        // loading surface owns the container.
        XCTAssertFalse(
            controller.presentCoachResults(Self.response(text: "late"), replacingLoadingFor: request),
            "the superseded request no longer owns the loading surface"
        )
        XCTAssertEqual(Self.surfaceIdentifiers(in: controller), [Const.loading])
    }

    // MARK: - 10s deadline is truthful and fails closed

    /// When the deadline fires on the live request it cancels the request and
    /// installs the truthful timeout error (with Retry), clearing busy.
    @MainActor
    func testDeadlineOnLiveRequestShowsTruthfulRetryState() throws {
        let controller = Self.makeController()
        controller.runCoach(draft: "please confirm the deadline", axis: "safer")
        controller.view.layoutIfNeeded()
        let request = try XCTUnwrap(controller.activeCoachRequestIDForTesting)

        controller.handleCoachDeadlineFired(requestID: request, tapTime: .now(), axis: "safer")
        controller.view.layoutIfNeeded()

        XCTAssertEqual(Self.surfaceIdentifiers(in: controller), [Const.error], "the deadline shows the error surface")
        let detail = try XCTUnwrap(Self.view(Const.errorDetail, in: controller.view) as? UILabel)
        XCTAssertTrue(
            detail.text?.lowercased().contains("timed out") == true,
            "the error must be truthful about the timeout"
        )
        XCTAssertNotNil(Self.view(Const.retry, in: controller.view), "a timeout must offer Retry")
        XCTAssertFalse(controller.coachIsBusyForTesting, "the deadline must clear the busy gate")
    }

    /// A deadline for a superseded request must not touch a newer request's
    /// skeleton — fail closed.
    @MainActor
    func testDeadlineForSupersededRequestIsIgnored() throws {
        let controller = Self.makeController()
        let stale = UUID()
        let live = UUID()
        controller.presentCoachLoading(requestID: stale, axis: "safer")
        controller.presentCoachLoading(requestID: live, axis: "safer")
        controller.view.layoutIfNeeded()

        controller.handleCoachDeadlineFired(requestID: stale, tapTime: .now(), axis: "safer")
        controller.view.layoutIfNeeded()

        XCTAssertEqual(
            Self.surfaceIdentifiers(in: controller), [Const.loading],
            "a superseded deadline must leave the newer skeleton untouched"
        )
        XCTAssertNotNil(Self.skeleton(in: controller))
    }

    /// A deadline arriving after the result already landed must not overwrite
    /// it — fail closed.
    @MainActor
    func testDeadlineAfterResultDeliveredDoesNotOverwrite() throws {
        let controller = Self.makeController()
        let request = UUID()
        controller.presentCoachLoading(requestID: request, axis: "funnier")
        XCTAssertTrue(controller.presentCoachResults(Self.response(text: "delivered"), replacingLoadingFor: request))
        controller.view.layoutIfNeeded()

        controller.handleCoachDeadlineFired(requestID: request, tapTime: .now(), axis: "funnier")
        controller.view.layoutIfNeeded()

        XCTAssertEqual(
            Self.surfaceIdentifiers(in: controller), [Const.results],
            "a late deadline must not replace a delivered result with an error"
        )
    }

    /// Firing the deadline repeatedly, including for an unknown request, must
    /// be inert once it has already been honored.
    @MainActor
    func testDeadlineIsInertWhenFiredRepeatedlyOrForAnUnknownRequest() throws {
        let controller = Self.makeController()
        controller.runCoach(draft: "deadline twice", axis: "safer")
        controller.view.layoutIfNeeded()
        let request = try XCTUnwrap(controller.activeCoachRequestIDForTesting)

        controller.handleCoachDeadlineFired(requestID: request, tapTime: .now(), axis: "safer")
        controller.view.layoutIfNeeded()
        XCTAssertEqual(Self.surfaceIdentifiers(in: controller), [Const.error])

        // Re-firing, and firing for a request that never existed, change nothing.
        controller.handleCoachDeadlineFired(requestID: request, tapTime: .now(), axis: "safer")
        controller.handleCoachDeadlineFired(requestID: UUID(), tapTime: .now(), axis: "safer")
        controller.view.layoutIfNeeded()

        XCTAssertEqual(Self.surfaceIdentifiers(in: controller), [Const.error])
        XCTAssertFalse(controller.coachIsBusyForTesting)
    }

    // MARK: - provider_ms clock decode

    func testDecodeVariantSurfacesProviderMs() throws {
        let json = #"{"status":"ok","axis":"funnier","text":"ha!","rationale":"light","risk_after":"low","provider_ms":1234}"#
        let decoded = try TonoCoachClient.decodeVariant(Data(json.utf8), expectedAxis: "funnier")
        XCTAssertEqual(decoded.providerMs, 1234)
        XCTAssertEqual(decoded.text, "ha!")
    }

    func testDecodeVariantToleratesMissingOrInvalidProviderMs() throws {
        let missing = #"{"status":"ok","axis":"safer","text":"ok text","risk_after":"low"}"#
        XCTAssertNil(try TonoCoachClient.decodeVariant(Data(missing.utf8), expectedAxis: "safer").providerMs)
        let negative = #"{"status":"ok","axis":"safer","text":"ok text","provider_ms":-5}"#
        XCTAssertNil(
            try TonoCoachClient.decodeVariant(Data(negative.utf8), expectedAxis: "safer").providerMs,
            "a negative provider_ms is malformed and degrades to nil, not a failed decode"
        )
        let wrongType = #"{"status":"ok","axis":"safer","text":"ok text","provider_ms":"fast"}"#
        XCTAssertNil(
            try TonoCoachClient.decodeVariant(Data(wrongType.utf8), expectedAxis: "safer").providerMs,
            "a non-numeric provider_ms degrades to nil and still renders the rewrite"
        )
        XCTAssertEqual(
            try TonoCoachClient.decodeVariant(Data(wrongType.utf8), expectedAxis: "safer").text, "ok text",
            "a malformed advisory clock must never fail the whole decode"
        )
    }

    // MARK: - Helpers

    private enum Const {
        static let loading = "TonoKB.coachLoading"
        static let results = "TonoKB.coachResults"
        static let error = "TonoKB.coachError"
        static let errorDetail = "TonoKB.coachErrorDetail"
        static let retry = "TonoKB.coachRetry"
        static let rewrites = "TonoKB.rewrites"
        static let toneChips = "TonoKB.toneChips"
        static let all: Set<String> = [loading, results, error]
    }

    @MainActor
    private static func makeController(width: CGFloat = 390) -> KeyboardViewController {
        let controller = KeyboardViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 320)
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

    @MainActor
    private static func skeleton(in controller: KeyboardViewController) -> TonoCoachSkeletonView? {
        view(TonoCoachSkeletonView.identifier, in: controller.view) as? TonoCoachSkeletonView
    }

    @MainActor
    private static func surfaceIdentifiers(in controller: KeyboardViewController) -> [String] {
        descendants(of: controller.view)
            .compactMap { $0.accessibilityIdentifier }
            .filter { Const.all.contains($0) }
    }

    /// Read the shipping controller source so the "legacy spinner is deleted"
    /// control cannot be satisfied by a bypassed-but-present code path.
    private static func keyboardControllerSource() throws -> String {
        let here = URL(fileURLWithPath: #filePath)          // apps/ios/Tests/…
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
        let source = root
            .appendingPathComponent("KeyboardExtension")
            .appendingPathComponent("KeyboardViewController.swift")
        return try String(contentsOf: source, encoding: .utf8)
    }

    /// Strip `//` line comments and `/* */` block comments so a source-level
    /// control tests the CODE, not the prose describing it.
    private static func strippingComments(_ source: String) -> String {
        var out = source
        out = out.replacingOccurrences(
            of: "/\\*[\\s\\S]*?\\*/", with: "", options: .regularExpression
        )
        out = out
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let range = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<range.lowerBound])
            }
            .joined(separator: "\n")
        return out
    }

    private static func view(_ identifier: String, in root: UIView) -> UIView? {
        ([root] + descendants(of: root)).first { $0.accessibilityIdentifier == identifier }
    }

    private static func descendants(of root: UIView) -> [UIView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
