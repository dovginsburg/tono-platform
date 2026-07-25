// Build109StripRoleAndDocumentIntegrityTests.swift
// Build 109 — the four founder physical findings, made testable in BOTH
// directions through the real UIKit controller.
//
// ── What this file adds that the suite could not previously express ─────────
//
// Every existing strip test asserts only the NEGATIVE half of founder finding
// #2 — "a suggestion tap must not run Coach" — because a unit-test
// `UIInputViewController` has no connected host document. Its proxy reports nil
// context and silently discards `insertText` / `deleteBackward`, so a build in
// which `candidateTapped` did nothing whatsoever passed the entire suite. The
// guarantee rested on a measurement that could be true for the wrong reason.
//
// Build 109 routes every document read and mutation in the controller through
// one `documentProxy` accessor with a test injection point, so this file can
// pin the POSITIVE half as well:
//
//   • a candidate tap really does replace the word, exactly once;
//   • a wrapped caret move really does move the caret and really does leave the
//     text byte-identical;
//   • a tone chip really does start a rewrite in this harness — the
//     NON-VACUITY control that makes every "zero requests" assertion elsewhere
//     evidence rather than an artifact of an empty document.
//
// ── The role-binding correction ported here ─────────────────────────────────
//
// Commits 76bf869 / 834660b sit on an incompatible lineage (they descend from
// the rival build-107 `6fe9c7a`, not from this tree). Their central fix —
// retiring the time-shared candidate strip whose target/action table was
// mutated by one transition and never restored by its inverse — was ALREADY
// solved here, and solved more strongly: Build 106 gave each role its own row
// of `TonoStripButton`s whose `stripRole` is `let` and whose selector is bound
// once in `makeStripStack` and never removed. That half is pinned by
// `Build106SuggestionRoutingTests` and `Build107ToneTargetResetTests`, both
// green, and is deliberately NOT re-ported: doing so would reintroduce the
// shared-button architecture the defect lived in.
//
// One element of that correction was genuinely absent here, and is ported:
// `toneChipsEnabled` was still a STORED boolean running in parallel with
// `stripMode`. The two agreed only because `applyStripMode` happened to have
// three call sites; nothing enforced it, while `coachTapped` toggled against
// the flag and every dispatch gate decided against the mode. Build 109 derives
// the flag from the mode, so disagreement is unrepresentable and `stripMode` is
// the single authority.
//
// HONESTY NOTE. Unlike the incompatible lineage's finding, this one is a live
// *invariant* gap, not a reproduced user-visible failure: no path in this tree
// desynchronises the two. `testRollbackRed_stripRoleHasNoStoredMirror` is
// therefore a structural pin against the source, and is labelled as such rather
// than dressed up as a behavioural repro.

import XCTest
import UIKit
@testable import Tono

final class Build109StripRoleAndDocumentIntegrityTests: XCTestCase {

    // MARK: - A recording host document

    /// A real `UITextDocumentProxy` that maintains a document and records every
    /// mutation. Lets the tests below assert what the controller actually DID to
    /// the text, not merely what it refrained from doing.
    final class RecordingDocumentProxy: NSObject, UITextDocumentProxy {

        private(set) var before: String
        private(set) var after: String
        private(set) var insertions: [String] = []
        private(set) var deleteBackwardCount = 0
        private(set) var caretAdjustments: [Int] = []

        init(before: String, after: String = "") {
            self.before = before
            self.after = after
        }

        /// The whole document, caret position ignored.
        var text: String { before + after }
        /// Every call that could have altered the characters of the document.
        var textMutationCount: Int { insertions.count + deleteBackwardCount }

        // UITextInputTraits — the controller reads these to derive host policy.
        var keyboardType: UIKeyboardType = .default
        var returnKeyType: UIReturnKeyType = .default
        var keyboardAppearance: UIKeyboardAppearance = .light
        var autocapitalizationType: UITextAutocapitalizationType = .sentences
        var autocorrectionType: UITextAutocorrectionType = .default
        var spellCheckingType: UITextSpellCheckingType = .default

        // UITextDocumentProxy
        var documentContextBeforeInput: String? { before }
        var documentContextAfterInput: String? { after }
        var selectedText: String? { nil }
        var documentInputMode: UITextInputMode? { nil }
        let documentIdentifier = UUID()

        func adjustTextPosition(byCharacterOffset offset: Int) {
            caretAdjustments.append(offset)
            if offset < 0 {
                let n = min(-offset, before.count)
                let moved = String(before.suffix(n))
                before.removeLast(n)
                after = moved + after
            } else if offset > 0 {
                let n = min(offset, after.count)
                let moved = String(after.prefix(n))
                after.removeFirst(n)
                before += moved
            }
        }

        func setMarkedText(_ markedText: String, selectedRange: NSRange) {}
        func unmarkText() {}

        // UIKeyInput
        var hasText: Bool { !(before.isEmpty && after.isEmpty) }

        func insertText(_ text: String) {
            insertions.append(text)
            before += text
        }

        func deleteBackward() {
            deleteBackwardCount += 1
            if !before.isEmpty { before.removeLast() }
        }
    }

    /// Counts every request that reaches the URL loading system on
    /// `URLSession.shared`, and fails them all, so "local mode is local" is
    /// measured rather than assumed.
    final class CountingDeniedNetwork: URLProtocol {
        nonisolated(unsafe) static var requestCount = 0
        nonisolated(unsafe) static var requestedURLs: [String] = []
        override class func canInit(with request: URLRequest) -> Bool {
            requestCount += 1
            requestedURLs.append(request.url?.absoluteString ?? "<nil>")
            return true
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
        override func stopLoading() {}
    }

    // MARK: - Founder finding #1 — repeated Coach on/off/mode switches

    /// Twenty-four consecutive TONO taps must alternate the strip role strictly.
    /// This is the behavioural pin for the derived-role change: if the toggle
    /// ever consulted a flag that had drifted from `stripMode`, one tap would
    /// re-issue the state it was already in and the alternation would break —
    /// which on device reads as "TONO stopped responding".
    @MainActor
    func testRepeatedCoachTogglesAlternateStrictlyAndAlwaysRespondOnTheFirstTap() throws {
        let controller = Self.makeController()
        let coach = try XCTUnwrap(Self.control(Const.coachButton, in: controller.view) as? UIButton)

        for tap in 1...24 {
            coach.sendActions(for: .touchUpInside)
            controller.view.layoutIfNeeded()

            let expected: TonoStripMode = tap.isMultiple(of: 2) ? .suggestions : .toneChips
            XCTAssertEqual(
                controller.stripModeForTesting, expected,
                "tap \(tap): every TONO tap must flip the role — a stale mirror would stall it here"
            )

            if expected == .toneChips {
                XCTAssertEqual(
                    controller.selectedToneAxesForTesting.count, 3,
                    "tap \(tap): Safer + exactly two configured tones"
                )
                XCTAssertEqual(
                    Self.toneChipButtons(in: controller.view).filter { !($0.currentTitle ?? "").isEmpty }.count,
                    3, "tap \(tap): all three chips must be painted when Coach is on"
                )
            } else {
                XCTAssertTrue(
                    controller.selectedToneAxesForTesting.isEmpty,
                    "tap \(tap): Coach off must clear the axis model"
                )
                XCTAssertTrue(
                    Self.toneChipButtons(in: controller.view).allSatisfy { ($0.currentTitle ?? "").isEmpty },
                    "tap \(tap): Coach off must leave no stale chip title"
                )
            }
        }
        XCTAssertEqual(controller.coachRequestsStarted, 0, "toggling alone must never spend a rewrite")
    }

    /// ROLLBACK-RED (structural). The strip role must have exactly one
    /// authority. A stored `toneChipsEnabled` is a second source of truth that
    /// can disagree with what the strip is showing — the shape of the original
    /// Build-105 defect — so the source must derive it, never assign it.
    ///
    /// Labelled structural, not behavioural: no path in this tree currently
    /// desynchronises the two. This pins that no future path can.
    func testRollbackRed_stripRoleHasNoStoredMirror() throws {
        let source = Self.strippingComments(try Self.keyboardControllerSource())

        XCTAssertFalse(
            source.contains("toneChipsEnabled = enabled"),
            "the role must not be mirrored into a stored flag by the toggle"
        )
        XCTAssertFalse(
            source.contains("private var toneChipsEnabled = false"),
            "the role must not be stored at all"
        )
        XCTAssertTrue(
            source.contains("private var toneChipsEnabled: Bool { stripMode == .toneChips }"),
            "the role must be derived from stripMode, the single authority"
        )
    }

    /// The Build-106 structure this tree already has must not be walked back in
    /// the name of porting the incompatible lineage's fix: no strip target may
    /// ever be removed or rebound after construction.
    func testStripTargetsAreStillNeverMutatedAfterConstruction() throws {
        let source = Self.strippingComments(try Self.keyboardControllerSource())
        XCTAssertFalse(
            source.contains("removeTarget"),
            "roles are fixed at construction; a rebinding funnel would reintroduce the shared-strip defect"
        )
    }

    // MARK: - Founder finding #2 — a suggestion tap accepts the word, locally

    /// THE positive half, newly expressible. A candidate tap must replace the
    /// misspelled token with the chosen word, perform exactly ONE bounded
    /// replacement, and spend zero Coach.
    @MainActor
    func testCandidateTapReplacesTheWordExactlyOnceAndSpendsZeroCoach() throws {
        let controller = Self.makeController()
        let document = RecordingDocumentProxy(before: "I recieve")
        controller.documentProxyOverride = document

        primeSpellingToken(on: controller)

        // Paint the strip and dispatch in the same runloop turn, so the async
        // spelling completion cannot interleave and repaint underneath us.
        controller.updateCandidateStrip(values: ["recieve", "receive"])
        let suggestions = Self.suggestionButtons(in: controller.view)
        suggestions[1].sendActions(for: .touchUpInside)

        XCTAssertEqual(document.text, "I receive", "the tap must actually accept the word")
        XCTAssertEqual(
            document.deleteBackwardCount, 7,
            "exactly the seven characters of 'recieve' are removed — one bounded replacement"
        )
        XCTAssertEqual(document.insertions, ["receive"], "exactly one insertion, of the chosen candidate")
        XCTAssertEqual(controller.coachRequestsStarted, 0, "accepting a suggestion must spend zero Coach")
        XCTAssertEqual(
            controller.stripRefusals[.roleMismatch, default: 0], 0,
            "no dispatch may arrive at the wrong handler"
        )

        // EXACTLY once: the token is consumed, so a second tap on the same
        // button must not mutate the document again.
        let mutationsAfterFirstTap = document.textMutationCount
        suggestions[1].sendActions(for: .touchUpInside)
        XCTAssertEqual(
            document.textMutationCount, mutationsAfterFirstTap,
            "a repeated tap on a spent candidate must not replace the word twice"
        )
        XCTAssertEqual(document.text, "I receive")
    }

    /// The same tap, driven after a full Coach on→off cycle — the exact
    /// sequence of the original device report. It must still be a local
    /// replacement and still spend zero Coach.
    @MainActor
    func testCandidateTapStaysLocalAfterAFullCoachCycle() throws {
        let controller = Self.makeController()
        let document = RecordingDocumentProxy(before: "I recieve")
        controller.documentProxyOverride = document
        let coach = try XCTUnwrap(Self.control(Const.coachButton, in: controller.view) as? UIButton)

        for _ in 0..<5 {
            coach.sendActions(for: .touchUpInside)   // on
            controller.view.layoutIfNeeded()
            coach.sendActions(for: .touchUpInside)   // off
            controller.view.layoutIfNeeded()
        }
        let coachAfterToggling = controller.coachRequestsStarted

        primeSpellingToken(on: controller)
        controller.updateCandidateStrip(values: ["recieve", "receive"])
        Self.suggestionButtons(in: controller.view)[1].sendActions(for: .touchUpInside)

        XCTAssertEqual(document.text, "I receive", "the word is corrected, not rewritten")
        XCTAssertEqual(document.insertions, ["receive"])
        XCTAssertEqual(
            controller.coachRequestsStarted, coachAfterToggling,
            "the whole draft must not be sent for a rewrite by a spelling tap"
        )
    }

    // MARK: - Founder finding #2, non-vacuity control

    /// NON-VACUITY. With a real document present, a tone-chip tap DOES start
    /// exactly one rewrite and DOES install the skeleton. Without this control,
    /// every "zero requests" assertion above could be satisfied by a harness in
    /// which Coach was simply unreachable.
    @MainActor
    func testControl_aToneChipTapDoesStartExactlyOneRewriteInThisHarness() throws {
        let controller = Self.makeController()
        controller.documentProxyOverride = RecordingDocumentProxy(before: "please send me the file")
        let coach = try XCTUnwrap(Self.control(Const.coachButton, in: controller.view) as? UIButton)

        coach.sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()
        XCTAssertEqual(controller.stripModeForTesting, .toneChips, "precondition: chips are live")

        Self.toneChipButtons(in: controller.view)[0].sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()

        XCTAssertEqual(
            controller.coachRequestsStarted, 1,
            "the harness must be able to reach Coach, or the zero-request assertions prove nothing"
        )
        XCTAssertNotNil(Self.view(Const.coachLoading, in: controller.view))
    }

    // MARK: - Founder finding #3 — one live row, no stacked targets

    /// Across twelve toggles: exactly one row is hit-testable, every strip
    /// button carries exactly one action, and no two touch targets overlap once
    /// expanded to the 44pt minimum.
    @MainActor
    func testExactlyOneRowIsLiveAndTargetsNeverStack() throws {
        let controller = Self.makeController()
        let coach = try XCTUnwrap(Self.control(Const.coachButton, in: controller.view) as? UIButton)

        for cycle in 0..<12 {
            coach.sendActions(for: .touchUpInside)
            controller.updateCandidateStrip(values: ["one", "two", "three"])
            controller.view.layoutIfNeeded()

            let suggestionsLive = controller.stripModeForTesting == .suggestions
            let candidateRow = try XCTUnwrap(Self.view(Const.candidates, in: controller.view))
            let chipRow = try XCTUnwrap(Self.view(Const.toneChips, in: controller.view))

            XCTAssertEqual(candidateRow.isHidden, !suggestionsLive, "cycle \(cycle)")
            XCTAssertEqual(candidateRow.isUserInteractionEnabled, suggestionsLive, "cycle \(cycle)")
            XCTAssertEqual(chipRow.isHidden, suggestionsLive, "cycle \(cycle)")
            XCTAssertEqual(chipRow.isUserInteractionEnabled, !suggestionsLive, "cycle \(cycle)")

            for button in Self.suggestionButtons(in: controller.view) {
                XCTAssertEqual(
                    button.actions(forTarget: controller, forControlEvent: .touchUpInside) ?? [],
                    ["candidateTapped:"],
                    "cycle \(cycle): suggestion targets must never stack or drift"
                )
            }
            for chip in Self.toneChipButtons(in: controller.view) {
                XCTAssertEqual(
                    chip.actions(forTarget: controller, forControlEvent: .touchUpInside) ?? [],
                    ["toneChipTapped:"],
                    "cycle \(cycle): chip targets must never stack or drift"
                )
            }

            // The live row's touch targets, plus TONO, must be mutually disjoint.
            let liveButtons: [UIButton] = suggestionsLive
                ? Self.suggestionButtons(in: controller.view)
                : Self.toneChipButtons(in: controller.view)
            let frames = ([coach] + liveButtons.filter { !$0.isHidden })
                .map { $0.convert($0.bounds, to: controller.view) }
            XCTAssertTrue(
                TonoStripGeometry.hitRectsAreDisjoint(
                    frames,
                    minimumTouchTarget: TonoKeyboardMetrics.ControlGeometry.minimumTouchTarget
                ),
                "cycle \(cycle): expanded hit rects must not overlap"
            )
        }
    }

    // MARK: - Founder finding #3 — skeleton precedes completion, tears down safely

    /// The result-shaped skeleton must be on screen BEFORE any completion, be
    /// atomically replaced by results, and be fully torn down by Back — with no
    /// orphaned skeleton or stacked surface left parented.
    @MainActor
    func testSkeletonPrecedesCompletionAndTearsDownSafely() throws {
        let controller = Self.makeController()
        controller.documentProxyOverride = RecordingDocumentProxy(before: "please send me the file")

        controller.runCoach(draft: "please send me the file", axis: "safer")
        controller.view.layoutIfNeeded()

        let request = try XCTUnwrap(controller.activeCoachRequestIDForTesting)
        XCTAssertNotNil(
            Self.view(TonoCoachSkeletonView.identifier, in: controller.view),
            "the skeleton must be visible before the completion arrives"
        )
        XCTAssertNil(Self.view(Const.coachResults, in: controller.view), "results must not precede the skeleton")
        XCTAssertEqual(Self.surfaceCount(in: controller), 1, "exactly one coach surface while loading")

        XCTAssertTrue(
            controller.presentCoachResults(Self.response(text: "Could you send me the file?"),
                                           replacingLoadingFor: request),
            "the owning request's completion must be accepted"
        )
        controller.view.layoutIfNeeded()

        XCTAssertNil(
            Self.view(TonoCoachSkeletonView.identifier, in: controller.view),
            "the skeleton must be gone once results replace it — no orphan behind the panel"
        )
        XCTAssertEqual(Self.surfaceCount(in: controller), 1, "exactly one coach surface after completion")

        // Back is the user-facing teardown.
        let back = try XCTUnwrap(Self.control(Const.coachBack, in: controller.view) as? UIButton)
        back.sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()

        XCTAssertEqual(Self.surfaceCount(in: controller), 0, "Back must leave no coach surface parented")
        XCTAssertNil(Self.view(TonoCoachSkeletonView.identifier, in: controller.view))
        XCTAssertFalse(controller.coachIsBusyForTesting, "teardown must not strand the busy gate")
    }

    /// A stale completion arriving after teardown must not resurrect a surface.
    ///
    /// Teardown is driven through the results panel because the loading
    /// skeleton renders a Back *placeholder*, not a live control — during
    /// loading there is deliberately nothing to tap.
    @MainActor
    func testCompletionAfterTeardownCannotResurrectASurface() throws {
        let controller = Self.makeController()
        controller.documentProxyOverride = RecordingDocumentProxy(before: "please send me the file")
        controller.runCoach(draft: "please send me the file", axis: "safer")
        controller.view.layoutIfNeeded()
        let request = try XCTUnwrap(controller.activeCoachRequestIDForTesting)

        XCTAssertNil(
            Self.control(Const.coachBack, in: controller.view),
            "the loading skeleton must expose a placeholder, not a live Back control"
        )
        XCTAssertTrue(
            controller.presentCoachResults(Self.response(text: "first"), replacingLoadingFor: request),
            "precondition: the owning completion lands"
        )
        controller.view.layoutIfNeeded()

        let back = try XCTUnwrap(Self.control(Const.coachBack, in: controller.view) as? UIButton)
        back.sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()
        XCTAssertEqual(Self.surfaceCount(in: controller), 0, "Back must leave no coach surface parented")

        // The already-delivered request must not be able to land a second time.
        XCTAssertFalse(
            controller.presentCoachResults(Self.response(text: "late"), replacingLoadingFor: request),
            "a completion for a torn-down surface must be refused"
        )
        controller.view.layoutIfNeeded()
        XCTAssertEqual(Self.surfaceCount(in: controller), 0, "no surface may be resurrected")
    }

    /// ROLLBACK-RED (behavioural). Backing out of Coach while a rewrite is
    /// still in flight must cancel that work and clear the busy gate.
    ///
    /// Before Build 109 `backToKeysTapped` removed the surfaces without
    /// invalidating the request, so `coachBusy` stayed latched true. Since
    /// `coachTapped` guards on `!coachBusy`, TONO was dead for the rest of the
    /// session: every subsequent tap on it was silently refused, and the
    /// abandoned request's ~10s deadline stayed armed against a surface that no
    /// longer existed.
    @MainActor
    func testRollbackRed_backingOutMidFlightDoesNotLatchCoachDead() throws {
        let controller = Self.makeController()
        controller.documentProxyOverride = RecordingDocumentProxy(before: "please send me the file")
        let coach = try XCTUnwrap(Self.control(Const.coachButton, in: controller.view) as? UIButton)

        coach.sendActions(for: .touchUpInside)                      // chips on
        controller.view.layoutIfNeeded()
        Self.toneChipButtons(in: controller.view)[0].sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()
        XCTAssertTrue(controller.coachIsBusyForTesting, "precondition: a rewrite is in flight")

        // Deliver results for the in-flight request, then back out. The request
        // is still the active one until something invalidates it.
        let request = try XCTUnwrap(controller.activeCoachRequestIDForTesting)
        XCTAssertTrue(
            controller.presentCoachResults(Self.response(text: "Could you send the file?"),
                                           replacingLoadingFor: request)
        )
        controller.view.layoutIfNeeded()
        let back = try XCTUnwrap(Self.control(Const.coachBack, in: controller.view) as? UIButton)
        back.sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()

        XCTAssertFalse(
            controller.coachIsBusyForTesting,
            "Back must clear the busy gate, or TONO is dead for the rest of the session"
        )
        XCTAssertNil(
            controller.activeCoachRequestIDForTesting,
            "Back must not leave a request active against a torn-down surface"
        )
        XCTAssertEqual(coach.isEnabled, true, "the Coach control must be re-enabled")

        // The whole point: Coach still works afterwards. Backing out returns to
        // the keys with the chip row still live, so another tone is one tap away.
        XCTAssertEqual(
            controller.stripModeForTesting, .toneChips,
            "backing out returns to the keys with the chip row still live"
        )
        Self.toneChipButtons(in: controller.view)[0].sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()
        XCTAssertEqual(
            controller.coachRequestsStarted, 2,
            "a second rewrite must be startable after backing out of the first"
        )
    }

    // MARK: - Founder finding #4 — local mode performs zero requests

    /// Typing and accepting suggestions is entirely on-device: with the URL
    /// loading system instrumented, the whole local lane must issue zero
    /// requests and start zero Coach rewrites.
    @MainActor
    func testLocalLanePerformsZeroRequests() throws {
        URLProtocol.registerClass(CountingDeniedNetwork.self)
        defer { URLProtocol.unregisterClass(CountingDeniedNetwork.self) }
        CountingDeniedNetwork.requestCount = 0
        CountingDeniedNetwork.requestedURLs = []

        let controller = Self.makeController()
        let document = RecordingDocumentProxy(before: "I recieve")
        controller.documentProxyOverride = document

        primeSpellingToken(on: controller)
        controller.updateCandidateStrip(values: ["recieve", "receive"])
        Self.suggestionButtons(in: controller.view)[1].sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()

        XCTAssertEqual(document.text, "I receive", "precondition: the local lane really did work")
        XCTAssertEqual(
            CountingDeniedNetwork.requestCount, 0,
            """
            the local lane must reach the URL loading system zero times; \
            observed: \(CountingDeniedNetwork.requestedURLs)
            """
        )
        XCTAssertEqual(controller.coachRequestsStarted, 0, "the local lane must start zero rewrites")
        XCTAssertNil(controller.activeCoachRequestIDForTesting, "no request may be left in flight")
    }

    /// The on-device badge is a statement about where computation happened. It
    /// must be shown for locally-produced candidates and hidden the moment the
    /// suggestion row stops being the live row.
    @MainActor
    func testLocalBadgeTracksTheLiveLocalRow() throws {
        let controller = Self.makeController()
        let coach = try XCTUnwrap(Self.control(Const.coachButton, in: controller.view) as? UIButton)
        let badge = try XCTUnwrap(Self.view(Const.localBadge, in: controller.view))

        controller.updateCandidateStrip(values: ["teh", "the"])
        controller.view.layoutIfNeeded()
        XCTAssertFalse(badge.isHidden, "local candidates must carry the on-device signal")

        coach.sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()
        XCTAssertTrue(badge.isHidden, "the badge must not claim local work while Coach chips are live")

        coach.sendActions(for: .touchUpInside)
        controller.updateCandidateStrip(values: ["teh", "the"])
        controller.view.layoutIfNeeded()
        XCTAssertFalse(badge.isHidden, "returning to the local row restores the signal")
    }

    // MARK: - Founder finding #4 — wrapped caret movement never changes text

    /// The device report: "in two-line text it still will not move upward like
    /// Apple Keyboard." Both directions must move the caret through the REAL
    /// production adapter, and neither may touch a single character.
    @MainActor
    func testWrappedCaretMovementMovesTheCaretAndNeverChangesText() throws {
        let sentence =
            "hey are we still on for dinner tomorrow night or should we push it to the weekend instead"
        let splitIndex = 70
        let controller = Self.makeController()
        let document = RecordingDocumentProxy(
            before: String(sentence.prefix(splitIndex)),
            after: String(sentence.dropFirst(splitIndex))
        )
        controller.documentProxyOverride = document
        let adapter = SpaceCursorProxyAdapter(owner: controller)

        // The adapter must read the injected document, not an empty host.
        XCTAssertEqual(adapter.documentContextBeforeInput, String(sentence.prefix(splitIndex)))

        for (label, translationY) in [("upward", CGFloat(-40)), ("downward", CGFloat(40))] {
            let doc = SpaceCursorDocument(
                before: document.before,
                after: document.after,
                wrapWidth: 46
            )
            XCTAssertTrue(
                doc.supportsVerticalNavigation,
                "\(label): a visually wrapped sentence must support vertical travel"
            )

            var engine = SpaceCursorEngine()
            let start = Date(timeIntervalSince1970: 1_000)
            engine.press(at: start)
            XCTAssertEqual(engine.tick(at: start.addingTimeInterval(0.35), document: doc), .enteredCursorMode)
            let effect = engine.drag(
                translationX: 0,
                translationY: translationY,
                at: start.addingTimeInterval(0.5)
            )
            guard case .moveCaret(let graphemes, let utf16) = effect else {
                return XCTFail("\(label): a wrapped drag must move the caret, not return \(effect)")
            }
            if translationY < 0 {
                XCTAssertLessThan(graphemes, 0, "upward must travel backward through the text")
            } else {
                XCTAssertGreaterThan(graphemes, 0, "downward must travel forward through the text")
            }

            let textBefore = document.text
            adapter.adjustTextPosition(byCharacterOffset: utf16)

            XCTAssertEqual(
                document.text, textBefore,
                "\(label): moving the caret must not change one character of the document"
            )
            XCTAssertEqual(document.textMutationCount, 0, "\(label): cursor mode must never insert or delete")
        }

        XCTAssertEqual(document.text, sentence, "the document is byte-identical after both traversals")
        XCTAssertEqual(document.insertions, [], "cursor mode inserted nothing")
        XCTAssertEqual(document.deleteBackwardCount, 0, "cursor mode deleted nothing")
        XCTAssertEqual(document.caretAdjustments.count, 2, "exactly two caret moves were applied")
    }

    /// Structural twin of the behavioural test above: the production adapter
    /// exposes no mutating call other than `adjustTextPosition`, so "cursor mode
    /// never deletes" cannot regress into a convention.
    func testSpaceCursorAdapterExposesNoTextMutation() throws {
        let source = Self.strippingComments(try Self.keyboardControllerSource())
        let adapter = try XCTUnwrap(
            source.range(of: "final class SpaceCursorProxyAdapter").map { String(source[$0.lowerBound...]) }
        )
        XCTAssertFalse(adapter.contains("insertText"), "the cursor adapter must have no insertion path")
        XCTAssertFalse(adapter.contains("deleteBackward"), "the cursor adapter must have no deletion path")
    }

    // MARK: - Helpers

    private enum Const {
        static let coachButton = "TonoKB.coachButton"
        static let coachLoading = "TonoKB.coachLoading"
        static let coachResults = "TonoKB.coachResults"
        static let coachError = "TonoKB.coachError"
        static let coachBack = "TonoKB.coachBack"
        static let candidates = "TonoKB.candidates"
        static let toneChips = "TonoKB.toneChips"
        static let localBadge = "TonoKB.localBadge"
        static let surfaces: Set<String> = [coachLoading, coachResults, coachError]
    }

    @MainActor
    private static func makeController(width: CGFloat = 390) -> KeyboardViewController {
        let controller = KeyboardViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 320)
        controller.view.layoutIfNeeded()
        return controller
    }

    /// Drive the real typing notification and let the controller's deferred
    /// spelling refresh run, so `spellingToken` is bound to the live document
    /// exactly as it is in production.
    @MainActor
    private func primeSpellingToken(on controller: KeyboardViewController) {
        controller.textDidChange(nil)
        // `textDidChange` defers the spelling refresh onto the main queue; a
        // block enqueued now runs after it.
        let pumped = expectation(description: "deferred spelling refresh")
        DispatchQueue.main.async { pumped.fulfill() }
        wait(for: [pumped], timeout: 5)
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
    private static func surfaceCount(in controller: KeyboardViewController) -> Int {
        descendants(of: controller.view)
            .compactMap { $0.accessibilityIdentifier }
            .filter { Const.surfaces.contains($0) }
            .count
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

    /// Strip comments so a source-level control tests the CODE, not the prose
    /// describing it — this file's own header quotes the very strings it asserts
    /// are absent.
    private static func strippingComments(_ source: String) -> String {
        var out = source.replacingOccurrences(
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
