// Build116SelectedFirstTests.swift
// Build 116 — the selected tone arrives first, and `Try another` is offered on
// every first result.
//
// WHAT THIS SUITE IS FOR
//
// Build 115 made the on-device route real: one tap produced Warmer, Clearer and
// Funnier from a single Foundation Models generation, offline, with nothing sent
// anywhere. It was correct and it was still the wrong answer to the question the
// person asked. Two things about it:
//
//   1. The tone they TAPPED was not first. The cards were sorted into a fixed
//      palette order (Safer, Warmer, Clearer, Funnier, …), so tapping Funnier
//      meant waiting for all three tones and then finding the one they chose in
//      third place. The whole set was also gated on the slowest tone in it.
//   2. `Try another` — the approved contract for "give me a different wording of
//      this" — existed only on the connected route. A local answer set
//      `coachSequence = nil`, so the control was correctly hidden, and someone
//      whose device could answer offline simply lost the feature.
//
// Build 116 answers both structurally rather than by sorting: the plan itself
// has a primary and a tail, Stage 1 asks only for the primary and renders it,
// and Stage 2 fills in the rest behind it. And a local version 1 is a real
// version 1, so the same `Try another` applies.
//
// HOW REDNESS WAS ESTABLISHED
//
// The tests in "PART A" use only API that existed at Build 115 (`beginCoachRewrite`,
// the card identifiers, `LocalCoachSetRequest.axes`, the view tree, the provider
// counters). They were run against the Build 115 production sources with this
// file in place, and each one FAILED there for the stated reason. Those failures
// are recorded in the Build 116 handoff.
//
// The tests in "PART B" exercise contracts that did not exist at Build 115 at
// all — the explicit on-device-only choice, the staged plan, the stage clocks.
// They cannot be compiled against the baseline, so no red RUN is claimed for
// them; what is claimed is that the behaviour they pin is new.
//
// Nothing in here reaches the network on the on-device paths, and every
// assertion about that is measured twice: an injected spy transport that counts
// what reaches the URL loading system, and the controller's own seam for whether
// a URLSession-backed client was ever constructed at all.

import XCTest
import UIKit
@testable import Tono

final class Build116SelectedFirstTests: XCTestCase {

    // ═══════════════════════════════════════════════════════════════════
    // Harness
    // ═══════════════════════════════════════════════════════════════════

    /// A deterministic stand-in for Apple's model that can be INTERROGATED
    /// about how it was used, not merely about what it returned.
    ///
    /// Three things it measures that a plain stub cannot:
    ///
    ///   * the ORDER and SHAPE of the requests, so "one tone at a time, the
    ///     selected one first" is a measurement;
    ///   * the peak number of generations in flight together, so "never
    ///     simultaneous" is a measurement rather than a claim about a lock
    ///     somewhere else;
    ///   * an optional gate that holds Stage 2 open, so a test can look at the
    ///     screen at the exact instant Stage 1 has rendered and Stage 2 has not
    ///     yet delivered.
    final class ProbeEngine: LocalCoachRewriteEngine, @unchecked Sendable {
        struct Observation {
            let axes: [LocalCoachAxis]
            let rejectedVersions: [String]
        }

        let availabilityResult: LocalRewriteAvailability
        /// Text per axis. A missing axis makes that generation fail with
        /// `.noValidRewrite`, which is what the real engine does when nothing
        /// survives validation.
        var texts: [LocalCoachAxis: String]
        /// Axes that should fail outright, and with which reason.
        var failures: [LocalCoachAxis: LocalCoachUnavailableReason] = [:]
        /// Text returned when a request carries rejected versions — the
        /// on-device `Try another`. Nil means "repeat the original", which is
        /// the honest default for greedy decoding.
        var alternativeText: String?
        /// Hold every request that is not the first one, so the screen can be
        /// inspected mid-flight. Released by `releaseSecondaries()`.
        var holdsSecondaries = false

        private let lock = NSLock()
        private var _observations: [Observation] = []
        private var _inFlight = 0
        private var _peakInFlight = 0
        private var _released = false

        var observations: [Observation] { lock.withLock { _observations } }
        var requestedAxes: [[LocalCoachAxis]] { observations.map(\.axes) }
        var peakConcurrentGenerations: Int { lock.withLock { _peakInFlight } }

        init(
            availability: LocalRewriteAvailability = .available,
            texts: [LocalCoachAxis: String] = [
                .warmer: "Would you mind sending the report over today?",
                .clearer: "Please send the report today.",
                .funnier: "The report and I are ready whenever you are — today?",
                .safer: "When you get a moment today, could you share the report?",
            ]
        ) {
            self.availabilityResult = availability
            self.texts = texts
        }

        func releaseSecondaries() { lock.withLock { _released = true } }

        func availability(locale: Locale) async -> LocalRewriteAvailability {
            availabilityResult
        }

        func rewriteSet(_ request: LocalCoachSetRequest) async throws -> LocalCoachSetResult {
            let index: Int = lock.withLock {
                _observations.append(Observation(
                    axes: request.axes, rejectedVersions: request.rejectedVersions
                ))
                _inFlight += 1
                _peakInFlight = max(_peakInFlight, _inFlight)
                return _observations.count - 1
            }
            defer { lock.withLock { _inFlight -= 1 } }

            if holdsSecondaries && index > 0 {
                while !(lock.withLock { _released }) {
                    if Task.isCancelled { throw LocalCoachFailure(.cancelled) }
                    await Task.yield()
                }
            }
            if Task.isCancelled { throw LocalCoachFailure(.cancelled) }

            guard let axis = request.axes.first else { throw LocalCoachFailure(.noValidRewrite) }
            if let reason = failures[axis] { throw LocalCoachFailure(reason) }

            let candidate: String?
            if !request.rejectedVersions.isEmpty {
                candidate = alternativeText ?? texts[axis]
            } else {
                candidate = texts[axis]
            }
            guard let text = candidate else { throw LocalCoachFailure(.noValidRewrite) }
            guard let validated = LocalCoachValidator.validateSet(
                [(axis: axis, text: text)],
                draft: request.draft,
                rejecting: request.rejectedVersions
            ) else { throw LocalCoachFailure(.noValidRewrite) }

            return LocalCoachSetResult(
                options: validated,
                metrics: LocalCoachMetrics(
                    availabilityReason: "available",
                    requestedAxisCount: request.axes.count,
                    validatedOptionCount: validated.count,
                    bytesIn: request.draft.utf8.count,
                    bytesOut: validated.reduce(0) { $0 + $1.text.utf8.count },
                    completionMilliseconds: 1,
                    peakFootprintBytes: nil
                )
            )
        }
    }

    /// Counts everything that reaches the URL loading system on the session it
    /// is installed in. Session-scoped deliberately: a process-wide registration
    /// would also count the host application's own traffic and would prove
    /// nothing about this keyboard.
    final class SpyProtocol: URLProtocol {
        nonisolated(unsafe) static var requestCount = 0
        override class func canInit(with request: URLRequest) -> Bool {
            requestCount += 1
            return true
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        /// Never answers, which models the parked state the real transport
        /// reports with no route.
        override func startLoading() {}
        override func stopLoading() {}
    }

    /// A document the test owns, so a rewrite's effect on it is observable.
    final class TestDocumentProxy: NSObject, UITextDocumentProxy {
        private(set) var before: String
        private(set) var after: String
        private(set) var insertions: [String] = []

        init(before: String, after: String = "") {
            self.before = before
            self.after = after
        }

        var text: String { before + after }

        var keyboardType: UIKeyboardType = .default
        var returnKeyType: UIReturnKeyType = .default
        var keyboardAppearance: UIKeyboardAppearance = .light
        var autocapitalizationType: UITextAutocapitalizationType = .sentences
        var autocorrectionType: UITextAutocorrectionType = .default
        var spellCheckingType: UITextSpellCheckingType = .default

        var documentContextBeforeInput: String? { before }
        var documentContextAfterInput: String? { after }
        var selectedText: String? { nil }
        var documentInputMode: UITextInputMode? { nil }
        let documentIdentifier = UUID()

        /// Replace the whole document, as a real edit under a live request
        /// would. Used to drive the stale-draft boundary.
        func replaceAll(with newValue: String) {
            before = newValue
            after = ""
        }

        func adjustTextPosition(byCharacterOffset offset: Int) {
            if offset < 0 {
                let count = min(-offset, before.count)
                let moved = String(before.suffix(count))
                before.removeLast(count)
                after = moved + after
            } else if offset > 0 {
                let count = min(offset, after.count)
                let moved = String(after.prefix(count))
                after.removeFirst(count)
                before += moved
            }
        }

        func setMarkedText(_ markedText: String, selectedRange: NSRange) {}
        func unmarkText() {}
        var hasText: Bool { !(before.isEmpty && after.isEmpty) }

        func insertText(_ text: String) {
            insertions.append(text)
            before += text
        }

        func deleteBackward() {
            if !before.isEmpty { before.removeLast() }
        }
    }

    static let draft = "hey I really need that report today"

    @MainActor
    private func makeController(
        engine: LocalCoachRewriteEngine,
        before: String = Build116SelectedFirstTests.draft,
        installSpyClient: Bool = true
    ) -> (KeyboardViewController, TestDocumentProxy) {
        let controller = KeyboardViewController()
        controller.localCoachEngine = engine
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 320)
        controller.view.layoutIfNeeded()
        let proxy = TestDocumentProxy(before: before)
        controller.documentProxyOverride = proxy
        if installSpyClient {
            SpyProtocol.requestCount = 0
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SpyProtocol.self]
            controller.installCoachClientForTesting(TonoCoachClient(
                endpoint: "https://api.tonoit.com/api/analyze/variant",
                timeout: 1,
                session: URLSession(configuration: configuration),
                tokenProvider: { "build116-test-bearer" }
            ))
        }
        addTeardownBlock { MainActor.assumeIsolated { controller.invalidateCoachWorkForTesting() } }
        return (controller, proxy)
    }

    /// The on-device-only choice, written to the store the controller actually
    /// reads, and restored afterwards so it cannot leak into another test.
    private func useOnDeviceOnlyPreference() {
        let store = LocalRewritePreferenceStore()
        let previous = store.load()
        addTeardownBlock { LocalRewritePreferenceStore().save(previous) }
        store.setOnDeviceOnly(true)
    }

    /// Spin the main run loop until `condition` holds or the budget runs out.
    /// The staged path hops to a `Task` and back to the main queue per tone, so
    /// a synchronous assertion would race it.
    @MainActor
    private func waitUntil(
        _ condition: () -> Bool,
        _ message: String = "condition never became true",
        timeout: TimeInterval = 5,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    /// Let the run loop turn for a bounded moment without requiring anything to
    /// become true. Used where the assertion is that something did NOT happen.
    @MainActor
    private func settle(_ seconds: TimeInterval = 0.4) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private static func findView(_ root: UIView, identifier: String) -> UIView? {
        if root.accessibilityIdentifier == identifier { return root }
        for child in root.subviews {
            if let hit = findView(child, identifier: identifier) { return hit }
        }
        return nil
    }

    private static func findViews(_ root: UIView, prefix: String) -> [UIView] {
        var out: [UIView] = []
        if (root.accessibilityIdentifier ?? "").hasPrefix(prefix) { out.append(root) }
        for child in root.subviews { out += findViews(child, prefix: prefix) }
        return out
    }

    @MainActor
    private static func cardIdentifiers(_ controller: KeyboardViewController) -> [String] {
        findViews(controller.view, prefix: "TonoKB.rewrite.")
            .compactMap(\.accessibilityIdentifier)
    }

    private static func sourceRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func source(_ relative: String) throws -> String {
        try String(contentsOf: sourceRoot().appendingPathComponent(relative), encoding: .utf8)
    }

    /// Every string literal on a line that is NOT a comment, with its 1-based
    /// line number.
    ///
    /// Deliberately crude and deliberately over-inclusive: it will also catch
    /// accessibility identifiers and `Section("…")` titles, which is correct —
    /// a section title is read by the person too. Comment lines are skipped
    /// because several of them have to name the iPad report to explain why the
    /// copy is what it is, and a comment is not a sentence anybody reads in the
    /// app.
    private static func userVisibleLiterals(in source: String) -> [(Int, String)] {
        var out: [(Int, String)] = []
        for (index, rawLine) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("//") else { continue }
            var inside = false
            var current = ""
            var previous: Character = " "
            for character in line {
                if character == "\"" && previous != "\\" {
                    if inside {
                        out.append((index + 1, current))
                        current = ""
                    }
                    inside.toggle()
                } else if inside {
                    current.append(character)
                }
                previous = character
            }
        }
        return out
    }

    /// A connected variant response, for the routes that legitimately have one.
    private static func variantResponse(
        axis: String, text: String
    ) -> TonoCoachClient.VariantResponse {
        TonoCoachClient.VariantResponse(
            axis: axis, text: text, rationale: nil, riskAfter: "low",
            // The server envelope is genuinely absent here; the decoder never
            // fabricates clocks, so neither does this fixture.
            clocks: nil, providerMs: 12
        )
    }

    // ═══════════════════════════════════════════════════════════════════
    // PART A — contracts that were RED against Build 115's production code
    // ═══════════════════════════════════════════════════════════════════

    // ── A1 · the tapped tone is the first card, for every selectable tone ──

    /// RED on Build 115: the cards were sorted into `TonoCoachPalette.orderedAxes`,
    /// so a Funnier tap rendered `warmer.0`, `clearer.1`, `funnier.2` and the
    /// tone the person chose was last.
    @MainActor
    func testTheTappedToneIsTheFirstCardForEverySelectableLocalTone() {
        for tapped in ["clearer", "funnier"] {
            let engine = ProbeEngine()
            let (controller, _) = makeController(engine: engine)
            controller.beginCoachRewrite(before: Self.draft, after: "", axis: tapped)
            waitUntil({ controller.coachSecondaryAxesForTesting.count == 2 },
                      "\(tapped): the secondary tones never arrived")
            controller.view.layoutIfNeeded()

            let cards = Self.cardIdentifiers(controller)
            XCTAssertEqual(
                cards.first, "TonoKB.rewrite.\(tapped).0",
                "\(tapped) was tapped, so \(tapped) must be the first card — got \(cards)"
            )
            // …and the tail is the existing local set with the tapped tone
            // removed, in the order it has always had. No new ranking.
            let expectedTail = LocalCoachAxis.base
                .map(\.rawValue)
                .filter { $0 != tapped }
            XCTAssertEqual(
                Array(cards.dropFirst()).map { $0.split(separator: ".")[2] }.map(String.init),
                expectedTail,
                "\(tapped): the secondary tones must keep the existing order"
            )
            MainActor.assumeIsolated { controller.invalidateCoachWorkForTesting() }
        }
    }

    /// RED on Build 115: one request carrying all three axes. Build 116 asks for
    /// the selected tone ALONE first — which is what makes it arrive first, as
    /// opposed to arriving first because something sorted it there.
    @MainActor
    func testStageOneAsksForTheSelectedToneAloneAndStageTwoFollows() {
        let engine = ProbeEngine()
        let (controller, _) = makeController(engine: engine)
        controller.beginCoachRewrite(before: Self.draft, after: "", axis: "funnier")
        waitUntil({ controller.coachSecondaryAxesForTesting.count == 2 })

        XCTAssertEqual(
            engine.requestedAxes, [[.funnier], [.warmer], [.clearer]],
            "one tone per request, the tapped one first, the rest in the existing order"
        )
        XCTAssertTrue(
            engine.observations.allSatisfy { $0.rejectedVersions.isEmpty },
            "an initial request carries no rejected wording — its wire shape is unchanged"
        )
    }

    // ── A2 · Stage 1 renders BEFORE Stage 2 starts ──────────────────────

    /// The ordering contract, measured at the instant it matters.
    ///
    /// The engine holds every request after the first, so the run loop reaches a
    /// state where Stage 1 has rendered and Stage 2 has delivered nothing. The
    /// selected card must already be on screen there — that is the entire
    /// promise, and it is the state Build 115 could not reach at all, because
    /// its single request could not return until every tone was written.
    ///
    /// RED on Build 115: with `holdsSecondaries` set, the ONE request Build 115
    /// issues is the first one and is never held, so it renders three cards at
    /// once — `secondaryAxes` has no meaning and the "exactly one card is up"
    /// assertion fails.
    @MainActor
    func testTheSelectedCardIsOnScreenBeforeStageTwoDelivers() throws {
        let engine = ProbeEngine()
        engine.holdsSecondaries = true
        let (controller, _) = makeController(engine: engine)
        controller.beginCoachRewrite(before: Self.draft, after: "", axis: "clearer")

        waitUntil({ controller.coachDeliveredRouteForTesting == "onDevice" },
                  "the selected tone never rendered")
        controller.view.layoutIfNeeded()

        // Stage 1 is on screen…
        XCTAssertEqual(Self.cardIdentifiers(controller), ["TonoKB.rewrite.clearer.0"])
        let card = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.rewrite.clearer.0")
        )
        XCTAssertFalse(card.isHidden)
        // …and Coach is already free, so the person is not blocked by the tail.
        XCTAssertFalse(controller.coachIsBusyForTesting)
        // …while Stage 2 has delivered nothing.
        XCTAssertEqual(controller.coachSecondaryAxesForTesting, [])
        XCTAssertTrue(controller.coachSecondaryInFlightForTesting)

        // The clocks agree with the screen: the skeleton preceded the selected
        // result, which preceded Stage 2 starting.
        let clocks = controller.coachStageClockMilliseconds
        let skeleton = try XCTUnwrap(clocks[KeyboardViewController.CoachStageClock.skeleton])
        let selected = try XCTUnwrap(clocks[KeyboardViewController.CoachStageClock.selectedResult])
        let started = try XCTUnwrap(clocks[KeyboardViewController.CoachStageClock.secondaryStarted])
        XCTAssertLessThanOrEqual(skeleton, selected, "the skeleton must precede the result")
        XCTAssertLessThanOrEqual(selected, started, "Stage 2 must not start before Stage 1 renders")

        engine.releaseSecondaries()
        waitUntil({ controller.coachSecondaryAxesForTesting.count == 2 })
        controller.view.layoutIfNeeded()
        XCTAssertEqual(
            Self.cardIdentifiers(controller),
            ["TonoKB.rewrite.clearer.0", "TonoKB.rewrite.warmer.1", "TonoKB.rewrite.funnier.2"],
            "the selected card must stay first while the rest append behind it"
        )
    }

    /// The selected card is not merely first — it is the SAME view object after
    /// the secondaries arrive. Appending must not rebuild it, because a rebuild
    /// would drop the `Try another` the person may be reaching for and reset
    /// their scroll position mid-gesture.
    @MainActor
    func testAppendingSecondariesNeverRebuildsTheSelectedCard() throws {
        let engine = ProbeEngine()
        engine.holdsSecondaries = true
        let (controller, _) = makeController(engine: engine)
        controller.beginCoachRewrite(before: Self.draft, after: "", axis: "clearer")
        waitUntil({ controller.coachDeliveredRouteForTesting == "onDevice" })
        controller.view.layoutIfNeeded()

        let selectedBefore = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.rewrite.clearer.0")
        )
        let tryAnotherBefore = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.tryAnother")
        )

        engine.releaseSecondaries()
        waitUntil({ controller.coachSecondaryAxesForTesting.count == 2 })
        controller.view.layoutIfNeeded()

        XCTAssertTrue(
            selectedBefore === Self.findView(controller.view, identifier: "TonoKB.rewrite.clearer.0"),
            "the selected card must be the same view, not a rebuilt one"
        )
        XCTAssertTrue(
            tryAnotherBefore === Self.findView(controller.view, identifier: "TonoKB.tryAnother"),
            "the selected card's Try another must survive the appends"
        )
        XCTAssertNotNil(selectedBefore.superview, "the selected card must still be parented")
    }

    // ── A3 · Try another on the on-device first result ──────────────────

    /// RED on Build 115: a local delivery set `coachSequence = nil`, so
    /// `TonoKB.tryAnother` did not exist on any on-device result.
    @MainActor
    func testAnOnDeviceFirstResultOffersAnActionableTryAnother() throws {
        let engine = ProbeEngine()
        let (controller, _) = makeController(engine: engine)
        controller.beginCoachRewrite(before: Self.draft, after: "", axis: "clearer")
        waitUntil({ controller.coachSecondaryAxesForTesting.count == 2 })
        controller.view.layoutIfNeeded()

        let another = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.tryAnother") as? UIControl,
            "an on-device first result must offer Try another"
        )
        XCTAssertTrue(another.isEnabled)
        XCTAssertFalse(another.isHidden)
        XCTAssertEqual(controller.coachSequenceStateForTesting?.displayed, 1)
        XCTAssertEqual(controller.coachSequenceStateForTesting?.limit, 2)
        XCTAssertEqual(controller.coachSequenceStateForTesting?.canRequestAnother, true)
        // It is bound to the tone that was tapped, not to a secondary that
        // happened to arrive later.
        XCTAssertEqual(controller.coachDisplayedVersionForTesting, "Please send the report today.")
    }

    /// The full local-v1 → online-v2 journey, end to end.
    ///
    /// RED on Build 115 at the first step: there was no `Try another` to tap.
    @MainActor
    func testLocalVersionOneThenOnlineVersionTwoPreservesBothAndCapsAtOne() throws {
        let engine = ProbeEngine()
        let (controller, _) = makeController(engine: engine)
        controller.beginCoachRewrite(before: Self.draft, after: "", axis: "clearer")
        waitUntil({ controller.coachSecondaryAxesForTesting.count == 2 })
        controller.view.layoutIfNeeded()

        let versionOne = try XCTUnwrap(controller.coachDisplayedVersionForTesting)
        XCTAssertEqual(controller.coachDisplayedVersionRouteForTesting, "onDevice")

        // The explicit tap. It goes to the connected variant route by default.
        let another = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.tryAnother") as? UIControl
        )
        another.sendActions(for: .touchUpInside)
        let alternativeID = try XCTUnwrap(
            controller.alternativeRequestIDForTesting,
            "the explicit tap must issue exactly one alternative request"
        )
        // `task.resume()` hands the request to the loading system asynchronously,
        // so the spy is polled rather than read synchronously.
        waitUntil({ SpyProtocol.requestCount >= 1 }, "the explicit tap issued no request")
        XCTAssertEqual(SpyProtocol.requestCount, 1, "one tap, one request")

        controller.completeCoachAlternative(
            requestID: alternativeID,
            liveBefore: Self.draft, liveAfter: "",
            result: .success(Self.variantResponse(
                axis: "clearer", text: "Could you get the report over to me today?"
            ))
        )
        controller.view.layoutIfNeeded()

        // Version 2 is on screen, labelled Online, and version 1 is preserved.
        XCTAssertEqual(
            controller.coachDisplayedVersionForTesting,
            "Could you get the report over to me today?"
        )
        XCTAssertEqual(controller.coachDisplayedVersionRouteForTesting, "connected")
        let badge = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.coachRoute") as? UILabel
        )
        XCTAssertEqual(
            badge.text, LocalCoachCopy.cloudRouteLabel,
            "an online version 2 must not inherit the on-device badge"
        )
        XCTAssertEqual(controller.coachVersionCursorForTesting?.displayed, 2)
        XCTAssertEqual(controller.coachVersionCursorForTesting?.canGoBack, true)

        // Capped: exactly one additional successful generation.
        XCTAssertEqual(controller.coachSequenceStateForTesting?.canRequestAnother, false)
        let disabled = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.tryAnother") as? UIControl
        )
        XCTAssertFalse(disabled.isEnabled, "the second generation is the last one")

        // Stepping back restores version 1, its on-device badge, AND the
        // secondary tones that belong beside it.
        let back = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.versionBack") as? UIControl
        )
        back.sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()

        XCTAssertEqual(controller.coachDisplayedVersionForTesting, versionOne)
        let restoredBadge = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.coachRoute") as? UILabel
        )
        XCTAssertEqual(
            restoredBadge.text, LocalCoachCopy.onDeviceRouteLabel,
            "stepping back to the on-device version must restore its own label"
        )
        XCTAssertEqual(
            Self.cardIdentifiers(controller),
            ["TonoKB.rewrite.clearer.0", "TonoKB.rewrite.warmer.1", "TonoKB.rewrite.funnier.2"],
            "the secondary choices must be preserved, not discarded by the detour"
        )
    }

    /// A failed `Try another` costs the person nothing — on this route exactly
    /// as on the connected one it inherits from.
    @MainActor
    func testAFailedTryAnotherAfterALocalFirstResultConsumesNoAllowance() throws {
        let engine = ProbeEngine()
        let (controller, _) = makeController(engine: engine)
        controller.beginCoachRewrite(before: Self.draft, after: "", axis: "clearer")
        waitUntil({ controller.coachSecondaryAxesForTesting.count == 2 })
        controller.view.layoutIfNeeded()
        let versionOne = try XCTUnwrap(controller.coachDisplayedVersionForTesting)

        for failure in [
            TonoCoachClient.CoachError.timeout,
            .offline,
            .http(status: 500, body: ""),
        ] {
            let another = try XCTUnwrap(
                Self.findView(controller.view, identifier: "TonoKB.tryAnother") as? UIControl
            )
            XCTAssertTrue(another.isEnabled, "\(failure): the allowance must still be there")
            another.sendActions(for: .touchUpInside)
            let id = try XCTUnwrap(controller.alternativeRequestIDForTesting)
            controller.completeCoachAlternative(
                requestID: id, liveBefore: Self.draft, liveAfter: "", result: .failure(failure)
            )
            controller.view.layoutIfNeeded()

            XCTAssertEqual(
                controller.coachDisplayedVersionForTesting, versionOne,
                "\(failure): the rewrite on screen must be untouched"
            )
            XCTAssertEqual(
                controller.coachSequenceStateForTesting?.canRequestAnother, true,
                "\(failure): a failure must not consume the one additional generation"
            )
        }
    }

    /// A duplicate answer is not a new version: no slot is consumed and the
    /// person is told plainly rather than shown the same sentence twice.
    @MainActor
    func testADuplicateAlternativeIsRefusedAndCostsNothing() throws {
        let engine = ProbeEngine()
        let (controller, _) = makeController(engine: engine)
        controller.beginCoachRewrite(before: Self.draft, after: "", axis: "clearer")
        waitUntil({ controller.coachSecondaryAxesForTesting.count == 2 })
        controller.view.layoutIfNeeded()
        let versionOne = try XCTUnwrap(controller.coachDisplayedVersionForTesting)

        let another = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.tryAnother") as? UIControl
        )
        another.sendActions(for: .touchUpInside)
        let id = try XCTUnwrap(controller.alternativeRequestIDForTesting)
        controller.completeCoachAlternative(
            requestID: id, liveBefore: Self.draft, liveAfter: "",
            result: .success(Self.variantResponse(axis: "clearer", text: versionOne))
        )
        controller.view.layoutIfNeeded()

        XCTAssertEqual(controller.coachVersionCursorForTesting?.generated, 1,
                       "a repeat is not a version")
        XCTAssertEqual(controller.coachSequenceStateForTesting?.canRequestAnother, true)
        let notice = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.alternativeNotice") as? UILabel
        )
        XCTAssertFalse(notice.isHidden)
        XCTAssertTrue(try XCTUnwrap(notice.text).lowercased().contains("same wording"))
    }

    // ── A4 · one generation at a time ──────────────────────────────────

    /// RED on Build 115 for the request count: it issued one request, so
    /// "three sequential generations, never overlapping" had nothing to measure.
    @MainActor
    func testGenerationsAreStrictlySequential() {
        let engine = ProbeEngine()
        let (controller, _) = makeController(engine: engine)
        controller.beginCoachRewrite(before: Self.draft, after: "", axis: "clearer")
        waitUntil({ controller.coachSecondaryAxesForTesting.count == 2 })

        XCTAssertEqual(engine.observations.count, 3, "one generation per tone")
        XCTAssertEqual(
            engine.peakConcurrentGenerations, 1,
            "two Foundation Models generations must never be in flight together"
        )
    }

    // ── A5 · the connected first result keeps its Try another ───────────

    /// Unchanged from Build 114, and asserted here so the Build 116 rework of
    /// the shared render path cannot quietly take it away.
    @MainActor
    func testTheConnectedFirstResultStillOffersTryAnother() throws {
        let engine = ProbeEngine(availability: .deviceNotEligible)
        let (controller, _) = makeController(engine: engine)
        controller.beginCoachRewrite(before: Self.draft, after: "", axis: "clearer")
        waitUntil({ controller.activeCoachRequestIDForTesting != nil })
        let id = try XCTUnwrap(controller.activeCoachRequestIDForTesting)
        controller.completeCoach(
            requestID: id, liveBefore: Self.draft, liveAfter: "",
            result: .success(Self.variantResponse(
                axis: "clearer", text: "Please send the report today."
            ))
        )
        controller.view.layoutIfNeeded()

        let another = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.tryAnother") as? UIControl
        )
        XCTAssertTrue(another.isEnabled)
        XCTAssertEqual(controller.coachDisplayedVersionRouteForTesting, "connected")
        let badge = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.coachRoute") as? UILabel
        )
        XCTAssertEqual(badge.text, LocalCoachCopy.cloudRouteLabel)
        XCTAssertEqual(engine.observations.count, 0, "an ineligible device generates nothing")
    }

    // ═══════════════════════════════════════════════════════════════════
    // PART B — contracts with no Build 115 counterpart to be red against
    // ═══════════════════════════════════════════════════════════════════

    // ── B1 · Stage 2 is cancelled at every boundary ─────────────────────

    /// Every boundary the contract names, driven through the real controller.
    ///
    /// Each case holds Stage 2 open, performs the boundary action, and then
    /// asserts two things: Stage 2 is no longer running, and releasing the held
    /// generation afterwards appends nothing. The second half is what makes this
    /// about STALE COMPLETIONS rather than merely about a cancelled task.
    @MainActor
    func testStageTwoIsCancelledAtEveryBoundaryAndStaleAnswersRenderNothing() throws {
        /// `startsFreshWork` marks the one boundary that legitimately begins a
        /// NEW request: tapping a different tone. There, work after the
        /// boundary is expected — it just has to belong to the new selection,
        /// which is asserted separately. Everywhere else, nothing may render.
        struct Boundary {
            let label: String
            let startsFreshWork: Bool
            let act: @MainActor (KeyboardViewController, TestDocumentProxy) -> Void
        }
        let boundaries: [Boundary] = [
            Boundary(label: "use rewrite", startsFreshWork: false) { controller, _ in
                let use = Self.findView(controller.view, identifier: "TonoKB.useRewrite") as? UIControl
                use?.sendActions(for: .touchUpInside)
            },
            Boundary(label: "dismiss", startsFreshWork: false) { controller, _ in
                let dismiss = Self.findView(
                    controller.view, identifier: "TonoKB.dismissRewrite"
                ) as? UIControl
                dismiss?.sendActions(for: .touchUpInside)
            },
            Boundary(label: "new tone tap", startsFreshWork: true) { controller, _ in
                controller.beginCoachRewrite(before: Self.draft, after: "", axis: "funnier")
            },
            Boundary(label: "keyboard teardown", startsFreshWork: false) { controller, _ in
                controller.invalidateCoachWorkForTesting()
            },
            Boundary(label: "try another supersedes", startsFreshWork: false) { controller, _ in
                let another = Self.findView(
                    controller.view, identifier: "TonoKB.tryAnother"
                ) as? UIControl
                another?.sendActions(for: .touchUpInside)
            },
        ]

        for boundary in boundaries {
            let label = boundary.label
            let engine = ProbeEngine()
            engine.holdsSecondaries = true
            let (controller, proxy) = makeController(engine: engine)
            controller.beginCoachRewrite(before: Self.draft, after: "", axis: "clearer")
            waitUntil({ controller.coachDeliveredRouteForTesting == "onDevice" },
                      "\(label): the selected tone never rendered")
            controller.view.layoutIfNeeded()
            XCTAssertTrue(
                controller.coachSecondaryInFlightForTesting,
                "\(label): precondition — Stage 2 must be running before the boundary"
            )
            let generationsBefore = engine.observations.count

            boundary.act(controller, proxy)
            settle(0.2)

            XCTAssertFalse(
                controller.coachSecondaryInFlightForTesting,
                "\(label): the Stage 2 that was running must not survive this boundary"
            )
            let deliveredBefore = controller.coachSecondaryAxesForTesting

            // The generation that was held is released AFTER the boundary.
            engine.releaseSecondaries()
            settle(0.35)
            controller.view.layoutIfNeeded()

            if boundary.startsFreshWork {
                // The old tail is gone and only the NEW selection is on screen.
                XCTAssertEqual(
                    Self.cardIdentifiers(controller).first, "TonoKB.rewrite.funnier.0",
                    "\(label): the new tone must own the surface"
                )
                XCTAssertFalse(
                    controller.coachSecondaryAxesForTesting.contains("funnier"),
                    "\(label): the new selection must not appear as its own secondary"
                )
                XCTAssertGreaterThan(
                    engine.observations.count, generationsBefore,
                    "\(label): a new tone tap is new work, not a resumption of the old"
                )
            } else {
                XCTAssertEqual(
                    controller.coachSecondaryAxesForTesting, deliveredBefore,
                    "\(label): a stale Stage 2 answer must not append to the surface"
                )
            }
            MainActor.assumeIsolated { controller.invalidateCoachWorkForTesting() }
        }
    }

    /// The draft moving under a running Stage 2 is its own boundary: the
    /// remaining tones are answers for text the person no longer has.
    @MainActor
    func testAStageTwoAnswerForAChangedDraftIsDroppedAndTheRestAbandoned() {
        let engine = ProbeEngine()
        engine.holdsSecondaries = true
        let (controller, proxy) = makeController(engine: engine)
        controller.beginCoachRewrite(before: Self.draft, after: "", axis: "clearer")
        waitUntil({ controller.coachDeliveredRouteForTesting == "onDevice" })

        proxy.replaceAll(with: "something else entirely, and rather longer than before")
        engine.releaseSecondaries()
        settle(0.4)

        XCTAssertEqual(
            controller.coachSecondaryAxesForTesting, [],
            "a tone written for a draft that no longer exists must not be shown"
        )
        XCTAssertFalse(controller.coachSecondaryInFlightForTesting)
    }

    /// A Stage 2 tone that cannot be written changes nothing: the selected
    /// answer stays, no error is shown over it, and — critically — nothing is
    /// handed to the connected route to fill the gap.
    @MainActor
    func testAStageTwoFailureIsSilentAndNeverReachesTheNetwork() throws {
        let engine = ProbeEngine()
        engine.failures = [.warmer: .generationFailed, .funnier: .guardrail]
        let (controller, _) = makeController(engine: engine)
        controller.beginCoachRewrite(before: Self.draft, after: "", axis: "clearer")
        waitUntil({ controller.coachDeliveredRouteForTesting == "onDevice" })
        waitUntil({ !controller.coachSecondaryInFlightForTesting })
        controller.view.layoutIfNeeded()

        XCTAssertEqual(Self.cardIdentifiers(controller), ["TonoKB.rewrite.clearer.0"])
        XCTAssertNil(
            Self.findView(controller.view, identifier: "TonoKB.coachError"),
            "a missing extra is not a failure of what the person asked for"
        )
        XCTAssertEqual(
            SpyProtocol.requestCount, 0,
            "a Stage 2 failure must not buy a provider call for a tone nobody requested"
        )
        XCTAssertEqual(controller.coachProviderCallCountForTesting, 0)
    }

    // ── B2 · every refusal routes correctly, exhaustively ───────────────

    /// The whole refusal vocabulary, one case at a time, with no default arm —
    /// so a reason added later cannot inherit somebody else's disposition by
    /// accident.
    ///
    /// Three dispositions, and the switch below is the specification:
    ///
    ///   * SILENT — `.cancelled`. Something newer already owns the surface.
    ///   * TERMINAL — Apple declined this specific text, or the device was
    ///     demonstrably writing the answer. Posting it onward would route around
    ///     a safety decision, or blame the network for something that was not
    ///     the network.
    ///   * HAND OFF — everything else. Exactly once, to the connected route.
    @MainActor
    func testEveryLocalRefusalReachesItsOwnDisposition() throws {
        enum Disposition { case silent, terminal, handOff }

        for reason in LocalCoachUnavailableReason.allCases {
            let expected: Disposition
            switch reason {
            case .cancelled:
                expected = .silent
            case .guardrail, .refusal, .rewriteDidNotFinish:
                expected = .terminal
            case .remoteKillSwitch, .userTurnedOff, .unsupportedOS, .deviceNotEligible,
                 .appleIntelligenceNotEnabled, .modelNotReady, .unsupportedLocale,
                 .unspecifiedUnavailable, .emptyDraft, .draftTooLong, .draftTooShort,
                 .memoryPressure, .busy, .generationFailed, .noValidRewrite,
                 .noLocalAlternative, .saferNeedsReview, .toneNeedsConnection,
                 .customStyleNeedsConnection:
                expected = .handOff
            }

            let engine = ProbeEngine()
            engine.failures = [.clearer: reason]
            let (controller, _) = makeController(engine: engine)
            let requestID = try XCTUnwrap(
                controller.beginCoachRewrite(before: Self.draft, after: "", axis: "clearer")
            )
            settle(0.25)
            controller.view.layoutIfNeeded()

            switch expected {
            case .silent:
                XCTAssertNil(
                    Self.findView(controller.view, identifier: "TonoKB.coachError"),
                    "\(reason) must be silent — something newer owns the surface"
                )
                XCTAssertEqual(SpyProtocol.requestCount, 0, "\(reason) must send nothing")
            case .terminal:
                let detail = try XCTUnwrap(
                    Self.findView(controller.view, identifier: "TonoKB.coachErrorDetail") as? UILabel,
                    "\(reason) must show a truthful terminal sentence"
                )
                XCTAssertEqual(detail.text, LocalCoachCopy.sentence(for: reason))
                XCTAssertEqual(
                    SpyProtocol.requestCount, 0,
                    "\(reason) is terminal and must not be posted onward"
                )
                XCTAssertNil(controller.coachHandoffRequestIDForTesting)
            case .handOff:
                XCTAssertEqual(
                    controller.coachLocalRefusalForTesting, reason.rawValue,
                    "\(reason) must reach the connected route carrying its own reason"
                )
                XCTAssertEqual(
                    controller.coachHandoffRequestIDForTesting, requestID,
                    "\(reason) must hand off exactly once, for this request"
                )
                XCTAssertEqual(
                    SpyProtocol.requestCount, 1,
                    "\(reason) must produce exactly one provider call, never two"
                )
            }
            MainActor.assumeIsolated { controller.invalidateCoachWorkForTesting() }
        }
    }

    /// A second hand-off for one request is refused structurally, so no
    /// arrangement of the routing branches can bill one tap twice.
    @MainActor
    func testASecondHandOffForOneRequestIssuesNoSecondCall() throws {
        let engine = ProbeEngine()
        engine.failures = [.clearer: .generationFailed]
        let (controller, _) = makeController(engine: engine)
        let requestID = try XCTUnwrap(
            controller.beginCoachRewrite(before: Self.draft, after: "", axis: "clearer")
        )
        waitUntil({ SpyProtocol.requestCount == 1 }, "the hand-off never happened")

        // A duplicate delivery of the same local failure — the shape a retried
        // or re-entered branch would have.
        controller.completeLocalCoach(
            requestID: requestID, draft: Self.draft, axis: "clearer", tapTime: .now(),
            liveBefore: Self.draft, liveAfter: "",
            outcome: .failure(LocalCoachFailure(.generationFailed))
        )
        settle(0.25)

        XCTAssertEqual(
            SpyProtocol.requestCount, 1,
            "one tap must never produce two provider calls"
        )
    }

    // ── B3 · the explicit on-device-only choice ─────────────────────────

    /// The routing half: with on-device-only chosen, every state that would have
    /// gone to the connected route becomes terminal instead. Exhaustive over
    /// availability, and asserted as "never `.cloud`" rather than case by case,
    /// because the thing that must be impossible is a network request.
    func testOnDeviceOnlyNeverProducesACloudRoute() {
        for availability in LocalRewriteAvailability.allCases {
            for axis in ["clearer", "funnier", "safer", "custom", "professional"] {
                for killSwitch in [true, false] {
                    let route = LocalCoachRoutePolicy.decide(
                        requestedAxis: axis,
                        draft: Self.draft,
                        remoteKillSwitchAllows: killSwitch,
                        preference: .onlyOnDevice,
                        availability: availability,
                        saferCorpusGateOpen: false,
                        connectivityKnownAbsent: false
                    )
                    if case .cloud(let reason) = route {
                        XCTFail(
                            "on-device-only produced a cloud route for "
                                + "\(axis)/\(availability)/killSwitch=\(killSwitch): \(reason)"
                        )
                    }
                }
            }
        }
        // And a draft that is out of bounds is terminal too, not merely routed.
        let long = String(repeating: "a", count: LocalCoachRoutePolicy.maximumDraftCharacters + 1)
        XCTAssertEqual(
            LocalCoachRoutePolicy.decide(
                requestedAxis: "clearer", draft: long, remoteKillSwitchAllows: true,
                preference: .onlyOnDevice, availability: .available,
                saferCorpusGateOpen: false, connectivityKnownAbsent: false
            ),
            .terminal(.draftTooLong)
        )
    }

    /// Safer and Custom are still not written here — the corpus gate and the
    /// backend's own validation are not repealed by a privacy choice. What
    /// changes is that the person gets the tones that CAN be written plus the
    /// note naming the one that cannot, immediately, instead of a wait for a
    /// request that must never be sent.
    func testOnDeviceOnlySubstitutesRatherThanWaitingForARouteItMayNotUse() throws {
        for axis in ["safer", "custom"] {
            let route = LocalCoachRoutePolicy.decide(
                requestedAxis: axis, draft: Self.draft, remoteKillSwitchAllows: true,
                preference: .onlyOnDevice, availability: .available,
                saferCorpusGateOpen: false, connectivityKnownAbsent: false
            )
            guard case .local(let plan) = route else {
                return XCTFail("\(axis) must still be answered with the tones that exist here")
            }
            XCTAssertEqual(plan.primaryAxis, .warmer)
            XCTAssertEqual(plan.axes, LocalCoachAxis.base)
            XCTAssertFalse(plan.axes.contains(.safer))
            let note = try XCTUnwrap(plan.substitutionNote)
            XCTAssertTrue(note.lowercased().contains(axis))
        }
    }

    /// The controller half of fail-closed: an ineligible device with
    /// on-device-only chosen shows one truthful terminal sentence, sends
    /// nothing, and leaves the draft exactly as typed.
    @MainActor
    func testOnDeviceOnlyFailsClosedWithoutTouchingTheNetworkOrTheDraft() throws {
        useOnDeviceOnlyPreference()
        let engine = ProbeEngine(availability: .deviceNotEligible)
        let (controller, proxy) = makeController(engine: engine)
        let documentBefore = proxy.text

        controller.beginCoachRewrite(before: Self.draft, after: "", axis: "clearer")
        waitUntil({
            Self.findView(controller.view, identifier: "TonoKB.coachErrorDetail") != nil
        }, "no terminal surface for an ineligible device under on-device-only")
        controller.view.layoutIfNeeded()

        let detail = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.coachErrorDetail") as? UILabel
        )
        XCTAssertEqual(
            detail.text,
            LocalCoachCopy.onDeviceOnlySentence(for: .deviceNotEligible),
            "the sentence must say what went wrong AND why nothing was sent"
        )
        XCTAssertEqual(SpyProtocol.requestCount, 0, "on-device-only must send nothing")
        XCTAssertEqual(controller.coachProviderCallCountForTesting, 0)
        XCTAssertEqual(proxy.text, documentBefore, "the draft must be left as typed")
        XCTAssertEqual(proxy.insertions, [])
        XCTAssertFalse(controller.coachIsBusyForTesting)
        XCTAssertNil(controller.coachDeliveredRouteForTesting, "nothing was delivered")
    }

    /// The `Try another` half, which is the one that could have leaked: it is
    /// the only control on the on-device route that reaches the network at all.
    @MainActor
    func testOnDeviceOnlyTryAnotherIsAnsweredHereAndSendsNothing() throws {
        useOnDeviceOnlyPreference()
        let engine = ProbeEngine()
        engine.alternativeText = "Could you get the report over to me today?"
        let (controller, _) = makeController(engine: engine)
        controller.beginCoachRewrite(before: Self.draft, after: "", axis: "clearer")
        waitUntil({ controller.coachSecondaryAxesForTesting.count == 2 })
        controller.view.layoutIfNeeded()

        let versionOne = try XCTUnwrap(controller.coachDisplayedVersionForTesting)
        let another = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.tryAnother") as? UIControl
        )
        another.sendActions(for: .touchUpInside)
        waitUntil({ controller.coachVersionCursorForTesting?.generated == 2 },
                  "the on-device alternative never landed")
        controller.view.layoutIfNeeded()

        // Answered here, and labelled here.
        XCTAssertEqual(
            controller.coachDisplayedVersionForTesting,
            "Could you get the report over to me today?"
        )
        XCTAssertEqual(controller.coachDisplayedVersionRouteForTesting, "onDevice")
        let badge = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.coachRoute") as? UILabel
        )
        XCTAssertEqual(badge.text, LocalCoachCopy.onDeviceRouteLabel)

        // Nothing was sent, by both available measurements.
        XCTAssertEqual(SpyProtocol.requestCount, 0, "on-device-only Try another must send nothing")
        XCTAssertEqual(controller.coachProviderCallCountForTesting, 0)

        // The rejected wording travelled with the request, and only with it.
        let alternativeRequest = try XCTUnwrap(engine.observations.last)
        XCTAssertEqual(alternativeRequest.axes, [.clearer], "same tone, not a different one")
        XCTAssertEqual(alternativeRequest.rejectedVersions, [versionOne])

        // Version 1 is still reachable.
        XCTAssertEqual(controller.coachVersionCursorForTesting?.canGoBack, true)
    }

    /// And when the device writes the same sentence again — which greedy
    /// decoding makes the likely outcome — the person is told plainly, version 1
    /// is preserved, and the allowance is not spent.
    @MainActor
    func testOnDeviceOnlyTryAnotherThatRepeatsItselfPreservesVersionOne() throws {
        useOnDeviceOnlyPreference()
        let engine = ProbeEngine()   // alternativeText nil → returns the same text
        let (controller, _) = makeController(engine: engine)
        controller.beginCoachRewrite(before: Self.draft, after: "", axis: "clearer")
        waitUntil({ controller.coachSecondaryAxesForTesting.count == 2 })
        controller.view.layoutIfNeeded()
        let versionOne = try XCTUnwrap(controller.coachDisplayedVersionForTesting)

        let another = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.tryAnother") as? UIControl
        )
        another.sendActions(for: .touchUpInside)
        waitUntil({ !controller.coachAlternativeInFlightForTesting },
                  "the alternative never completed")
        controller.view.layoutIfNeeded()

        XCTAssertEqual(controller.coachDisplayedVersionForTesting, versionOne)
        XCTAssertEqual(controller.coachVersionCursorForTesting?.generated, 1,
                       "a repeat is not a version")
        XCTAssertEqual(controller.coachSequenceStateForTesting?.canRequestAnother, true,
                       "a repeat consumes no allowance")
        let notice = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.alternativeNotice") as? UILabel
        )
        XCTAssertFalse(notice.isHidden)
        XCTAssertEqual(notice.text, LocalCoachCopy.sentence(for: .noLocalAlternative))
        XCTAssertEqual(SpyProtocol.requestCount, 0)
    }

    /// The preference is a real durable tri-plus-one state, and turning the
    /// outer switch off and on again does not silently widen it.
    func testTheOnDeviceOnlyChoiceIsDurableAndNeverWidenedByAccident() {
        let suite = "build116.preference.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let store = LocalRewritePreferenceStore(defaults: defaults)

        XCTAssertEqual(store.load(), .unset)
        XCTAssertFalse(LocalRewritePreference.unset.prohibitsNetwork)
        XCTAssertFalse(LocalRewritePreference.on.prohibitsNetwork)
        XCTAssertFalse(LocalRewritePreference.off.prohibitsNetwork)
        XCTAssertTrue(LocalRewritePreference.onlyOnDevice.prohibitsNetwork)

        store.setOnDeviceOnly(true)
        XCTAssertEqual(store.load(), .onlyOnDevice)
        // The outer switch reports it as ON, because it is.
        XCTAssertTrue(store.load().resolved(availability: .available))
        // Re-affirming the outer switch must not downgrade the promise.
        store.setEnabled(true)
        XCTAssertEqual(store.load(), .onlyOnDevice, "re-affirming ON must not widen the choice")
        // Turning it off, then on, is a fresh explicit ON.
        store.setEnabled(false)
        XCTAssertEqual(store.load(), .off)
        store.setEnabled(true)
        XCTAssertEqual(store.load(), .on)
        // And a feature-flag refresh cannot touch it.
        store.setOnDeviceOnly(true)
        FeatureFlags.update(from: ["thread_context": true, "risk_delta": false])
        XCTAssertEqual(store.load(), .onlyOnDevice)
    }

    /// Settings offers the choice, in the person's words, wired to the durable
    /// store — and states the cost, because finding it out from a refusal
    /// afterwards is finding it out the wrong way.
    func testSettingsOffersTheOnDeviceOnlyChoiceAndNamesItsCost() throws {
        let settings = try Self.source("App/SettingsView.swift")
        XCTAssertTrue(settings.contains("Only rewrite on this device"))
        XCTAssertTrue(settings.contains("LocalRewritePreferenceStore().setOnDeviceOnly("),
                      "the toggle must write the durable preference, not a feature flag")
        XCTAssertTrue(
            settings.contains("declined rather than sent"),
            "the caption must state what is given up, not only what is gained"
        )
    }

    // ── B3b · Dov's physical-iPad report ────────────────────────────────
    //
    // Two defects, found on real hardware, both RED against the Build 115
    // sources (and against this build before the correction):
    //
    //   1. Every sentence in this contract said "iPhone". On an iPad that is
    //      false, in the one place a person looks to find out what their
    //      hardware can do.
    //   2. The Apple-rewriting section declared the device incompatible while
    //      the check immediately below it passed. Two different systems —
    //      Foundation Models versus `UITextChecker` + lexicon + Tono's ranker —
    //      presented as if the second corroborated the first.

    /// Every user-visible sentence in this contract is true on every device
    /// Tono runs on.
    ///
    /// Scans the actual string literals rather than a curated list, so a
    /// sentence added later cannot quietly reintroduce the defect. Comments and
    /// documentation are exempt: they are not read by anyone using the app, and
    /// several of them have to name the iPad report to explain themselves.
    func testNoUserVisibleCopyNamesASpecificDeviceFamily() throws {
        let forbidden = ["iPhone", "iPad", "phone", "tablet"]
        for relative in [
            "Shared/LocalCoachRewrite.swift",
            "App/SettingsView.swift",
            "KeyboardExtension/LocalIntelligence.swift",
        ] {
            for (index, literal) in Self.userVisibleLiterals(in: try Self.source(relative)) {
                for word in forbidden {
                    XCTAssertFalse(
                        literal.contains(word),
                        "\(relative):\(index) says “\(word)” to the person: \(literal)"
                    )
                }
            }
        }
        // …and the phrase that replaced it is actually in use, so this cannot
        // pass by the copy having been deleted.
        XCTAssertTrue(LocalCoachCopy.onDeviceRouteLabel.contains("this device"))
        XCTAssertTrue(
            LocalCoachCopy.sentence(for: .deviceNotEligible).contains("This device")
        )
    }

    /// The same contract renders identically on an iPad and on an iPhone,
    /// because there is no device branch to render differently.
    ///
    /// Asserted structurally: a build that solved this by branching on the
    /// idiom would pass a "no iPhone strings on iPad" test while still carrying
    /// two copies of every sentence to keep correct. One phrase, no branch.
    func testTheDeviceWordingIsOnePhraseWithNoIdiomBranch() throws {
        for relative in ["App/SettingsView.swift", "Shared/LocalCoachRewrite.swift"] {
            let source = try Self.source(relative)
            for branch in [
                "userInterfaceIdiom", "UIDevice.current.model", "horizontalSizeClass == .regular ? \"",
            ] {
                XCTAssertFalse(
                    source.contains(branch),
                    "\(relative) branches copy on the device: \(branch)"
                )
            }
        }
        // The availability sentences are the ones a person reads on the
        // hardware that cannot run the model, so they carry the contract.
        for availability in LocalRewriteAvailability.allCases where availability != .available {
            let sentence = LocalCoachCopy.sentence(
                for: LocalCoachUnavailableReason(availability: availability)
            )
            XCTAssertFalse(sentence.contains("iPhone"), "\(availability): \(sentence)")
            XCTAssertFalse(sentence.contains("iPad"), "\(availability): \(sentence)")
        }
    }

    /// An unresolved probe may not render a verdict.
    ///
    /// THE iPad DEFECT, at its root. `localRewriteAvailability` was
    /// `= .modelNotReady` — a real terminal reason with a real sentence — so the
    /// section stated something definite about the person's hardware before the
    /// cross-process probe had answered. It is now optional, and nil renders the
    /// neutral checking caption.
    func testUnresolvedAvailabilityCannotDisplayATerminalVerdict() throws {
        let settings = try Self.source("App/SettingsView.swift")
        XCTAssertTrue(
            settings.contains("@State private var localRewriteAvailability: LocalRewriteAvailability?"),
            "the unresolved state must be unrepresentable as a verdict"
        )
        XCTAssertFalse(
            settings.contains("localRewriteAvailability: LocalRewriteAvailability = ."),
            "a placeholder availability is a verdict about hardware nobody has asked about"
        )
        // The neutral caption exists, claims nothing, and names no reason.
        let checking = SettingsView.localRewriteCheckingCaption
        XCTAssertFalse(checking.isEmpty)
        for availability in LocalRewriteAvailability.allCases where availability != .available {
            let terminal = LocalCoachCopy.sentence(
                for: LocalCoachUnavailableReason(availability: availability)
            )
            XCTAssertNotEqual(
                checking, terminal,
                "the checking state must not reuse \(availability)'s terminal sentence"
            )
        }
        for word in ["doesn't support", "not supported", "can't", "unavailable", "incompatible"] {
            XCTAssertFalse(
                checking.lowercased().contains(word),
                "the checking caption reads as a verdict: \(checking)"
            )
        }
        // …and the controls stay disabled while it is unknown, so a tap cannot
        // start work the device may not be able to do.
        XCTAssertTrue(
            settings.contains("localRewriteAvailability?.isAvailable == true"),
            "unresolved must not count as available"
        )
        XCTAssertTrue(settings.contains(".disabled(!localRewriteIsAvailable)"))
    }

    /// The two capabilities are named as two capabilities.
    ///
    /// Apple rewriting is driven ONLY by `AppleRewriteBridge`; typing assistance
    /// is `UITextChecker` + the person's lexicon + Tono's ranker. Neither name
    /// may be used for the other, and the typing-assistance result may not claim
    /// the words "Apple Intelligence" or "on-device intelligence" — which is what
    /// made a passing check read as a rebuttal of the notice above it.
    func testAppleRewritingAndTypingAssistanceAreNamedAsDifferentSystems() throws {
        let settings = try Self.source("App/SettingsView.swift")
        XCTAssertTrue(settings.contains("Section(\"On-device rewriting\")"))
        XCTAssertTrue(settings.contains("Section(\"On-device typing assistance\")"))
        XCTAssertFalse(
            settings.contains("Section(\"On-device intelligence\")"),
            "the deterministic pipeline must not be presented as on-device intelligence"
        )
        XCTAssertFalse(
            settings.contains("Check on-device intelligence"),
            "the button must name what it actually checks"
        )
        XCTAssertTrue(settings.contains("Check typing assistance"))

        // The self-test's own words, which is where the contradiction was read.
        for result in [
            LocalIntelligenceSelfTest.Result.pass(checks: []),
            .fail(checks: [LocalIntelligenceSelfTest.Check(name: "x", passed: false, detail: "d")]),
            .disabled(reason: "no dictionary"),
        ] {
            let summary = result.summary
            XCTAssertTrue(
                summary.lowercased().contains("typing assistance"),
                "the result must name what ran: \(summary)"
            )
            XCTAssertFalse(
                summary.lowercased().contains("apple intelligence"),
                "typing assistance must never claim Apple Intelligence: \(summary)"
            )
            XCTAssertFalse(
                summary.lowercased().contains("on-device intelligence"),
                "the phrase that read as a rebuttal must be gone: \(summary)"
            )
        }

        // Apple rewriting status comes from the Foundation Models probe and
        // nothing else — in particular, never from the self-test.
        XCTAssertTrue(
            settings.contains("await AppleRewriteBridge.shared.availability(locale: Locale.current)"),
            "Apple rewrite availability must come from the Foundation Models probe"
        )
        let rewriteCaption = try XCTUnwrap(
            Build115LocalCoachTests.functionBody(
                named: "private var localRewriteCaption: String", in: settings
            )
        )
        XCTAssertFalse(
            rewriteCaption.contains("localSelfTestResult"),
            "the Apple rewriting caption must not read the typing-assistance result"
        )
    }

    /// A typing-assistance pass changes nothing about Apple rewriting — not the
    /// availability, not the preference, not the enabled state.
    ///
    /// Driven through the REAL self-test rather than a stub, so "these are
    /// independent" is measured on the shipping pipeline.
    func testATypingAssistancePassDoesNotEnableOrAlterAppleRewriting() throws {
        let suite = "build116.independence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let store = LocalRewritePreferenceStore(defaults: defaults)
        let before = store.load()

        let result = LocalIntelligenceSelfTest.run(
            language: "en_US",
            availableLanguages: ["en_US"],
            checker: AlwaysAnsweringChecker(),
            lexicon: .empty
        )
        XCTAssertTrue(result.isPass, "precondition: the self-test must pass — \(result.summary)")

        // Nothing about the Apple rewrite contract moved.
        XCTAssertEqual(store.load(), before, "a self-test must not write the rewrite preference")
        for availability in LocalRewriteAvailability.allCases where availability != .available {
            XCTAssertEqual(
                LocalCoachRoutePolicy.decide(
                    requestedAxis: "clearer", draft: Self.draft, remoteKillSwitchAllows: true,
                    preference: .unset, availability: availability,
                    saferCorpusGateOpen: false, connectivityKnownAbsent: false
                ),
                .cloud(LocalCoachUnavailableReason(availability: availability)),
                "a passing self-test cannot make \(availability) run locally"
            )
        }
        // And the copy says so out loud, so the person does not have to infer it.
        let independence = LocalIntelligenceCopy.independenceFromAppleRewriting.lowercased()
        XCTAssertTrue(independence.contains("separate"))
        XCTAssertTrue(independence.contains("rewriting"))
        for jargon in ["backend", "endpoint", "api", "foundationmodels", "systemlanguagemodel"] {
            XCTAssertFalse(independence.contains(jargon), "no implementation jargon: \(jargon)")
        }
    }

    /// A spelling checker that answers, so the REAL self-test can reach a pass
    /// on a machine whose installed dictionaries this test does not control.
    /// Everything else in the pipeline — the resolver, the ranker, the lexicon
    /// reporting and the continuation table — is the shipping code.
    private final class AlwaysAnsweringChecker: SpellingChecking {
        func lookup(word: String, language: String) -> SpellingLookup {
            word.lowercased() == "recieve"
                ? SpellingLookup(isMisspelled: true, corrections: ["receive"], completions: [])
                : SpellingLookup(isMisspelled: false, corrections: [], completions: [])
        }
    }

    // ── B4 · route labels derive from delivery ──────────────────────────

    /// The label is a fact about what is on screen, never a memory of what
    /// happened last. Both directions of a mixed sequence.
    @MainActor
    func testRouteLabelsFollowTheVersionOnScreenInBothDirections() throws {
        let engine = ProbeEngine()
        let (controller, _) = makeController(engine: engine)
        controller.beginCoachRewrite(before: Self.draft, after: "", axis: "clearer")
        waitUntil({ controller.coachSecondaryAxesForTesting.count == 2 })
        controller.view.layoutIfNeeded()

        func badgeText() throws -> String? {
            controller.view.layoutIfNeeded()
            let label = try XCTUnwrap(
                Self.findView(controller.view, identifier: "TonoKB.coachRoute") as? UILabel
            )
            return label.isHidden ? nil : label.text
        }

        XCTAssertEqual(try badgeText(), LocalCoachCopy.onDeviceRouteLabel)

        let another = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.tryAnother") as? UIControl
        )
        another.sendActions(for: .touchUpInside)
        let id = try XCTUnwrap(controller.alternativeRequestIDForTesting)
        controller.completeCoachAlternative(
            requestID: id, liveBefore: Self.draft, liveAfter: "",
            result: .success(Self.variantResponse(
                axis: "clearer", text: "Could you get the report over to me today?"
            ))
        )
        XCTAssertEqual(try badgeText(), LocalCoachCopy.cloudRouteLabel)

        // Back to the on-device version…
        let back = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.versionBack") as? UIControl
        )
        back.sendActions(for: .touchUpInside)
        XCTAssertEqual(try badgeText(), LocalCoachCopy.onDeviceRouteLabel)

        // …and forward to the online one again.
        let forward = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.versionForward") as? UIControl
        )
        forward.sendActions(for: .touchUpInside)
        XCTAssertEqual(try badgeText(), LocalCoachCopy.cloudRouteLabel)
    }

    /// The secondary cards are on-device text, so they are shown only beside the
    /// on-device version. Under an Online badge they would make it false for two
    /// of the three cards.
    @MainActor
    func testSecondaryCardsAreNotShownUnderAnOnlineBadge() throws {
        let engine = ProbeEngine()
        let (controller, _) = makeController(engine: engine)
        controller.beginCoachRewrite(before: Self.draft, after: "", axis: "clearer")
        waitUntil({ controller.coachSecondaryAxesForTesting.count == 2 })
        controller.view.layoutIfNeeded()
        XCTAssertEqual(Self.cardIdentifiers(controller).count, 3)

        let another = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.tryAnother") as? UIControl
        )
        another.sendActions(for: .touchUpInside)
        let id = try XCTUnwrap(controller.alternativeRequestIDForTesting)
        controller.completeCoachAlternative(
            requestID: id, liveBefore: Self.draft, liveAfter: "",
            result: .success(Self.variantResponse(
                axis: "clearer", text: "Could you get the report over to me today?"
            ))
        )
        controller.view.layoutIfNeeded()

        XCTAssertEqual(
            Self.cardIdentifiers(controller), ["TonoKB.rewrite.clearer.0"],
            "an online version must not sit above on-device cards under one badge"
        )
        // Preserved, not discarded: they come straight back on the way back.
        XCTAssertEqual(controller.coachSecondaryAxesForTesting, ["warmer", "funnier"])
    }

    // ── B5 · what the model is told ─────────────────────────────────────

    /// A single-tone generation has no field name to carry the tone, so the tone
    /// has to be in the instructions — and it has to be the SAME words the
    /// multi-tone schema uses, or a tone would come out differently depending on
    /// which stage produced it.
    ///
    /// Module note: `Tono.`-qualified throughout. The shared policy files are
    /// compiled into the host app AND into this test bundle, so an unqualified
    /// name is ambiguous here; qualifying pins the assertions to the copy the
    /// shipping app actually links.
    func testASingleToneRequestNamesItsToneInTheInstructions() throws {
        for axis in Tono.LocalCoachAxis.allCases {
            let instructions = Tono.OnDeviceAppleRewriteService.instructions(
                for: Tono.LocalCoachSetRequest(draft: Self.draft, axes: [axis])
            )
            XCTAssertTrue(
                instructions.contains(axis.instructionClause),
                "\(axis) must be named in the instructions of a single-tone request"
            )
        }
        // The wording is shared with the multi-tone schema descriptions rather
        // than written twice.
        let engineSource = try Self.source("Shared/OnDeviceAppleRewrite.swift")
        for axis in Tono.LocalCoachAxis.allCases {
            XCTAssertTrue(
                engineSource.contains(axis.instructionClause),
                "\(axis)'s clause must be the one the @Guide descriptions use"
            )
        }
    }

    /// The person's own text lives in the prompt, never in the developer
    /// instructions — including the wording they rejected.
    func testUserTextNeverEntersTheDeveloperInstructions() {
        let request = Tono.LocalCoachSetRequest(
            draft: Self.draft, axes: [.clearer],
            rejectedVersions: ["Please send the report today."]
        )
        let instructions = Tono.OnDeviceAppleRewriteService.instructions(for: request)
        XCTAssertFalse(instructions.contains(Self.draft), "the draft must not be in instructions")
        XCTAssertFalse(
            instructions.contains("Please send the report today."),
            "a rejected wording must not be in instructions"
        )
        let prompt = Tono.OnDeviceAppleRewriteService.promptText(for: request)
        XCTAssertTrue(prompt.contains(Self.draft))
        XCTAssertTrue(prompt.contains("Please send the report today."))
        // …and an ordinary request's prompt is unchanged from Build 115's.
        XCTAssertEqual(
            Tono.OnDeviceAppleRewriteService.promptText(
                for: Tono.LocalCoachSetRequest(draft: Self.draft, axes: [.clearer])
            ),
            "Message to rewrite: \(Self.draft)"
        )
    }

    /// The validator refuses a "different wording" that is not different, so a
    /// model that ignores the instruction cannot produce a version 2 that reads
    /// identically to version 1.
    func testAnAlternativeThatRepeatsARejectedWordingIsDropped() {
        let draft = Self.draft
        let rejected = "Please send the report today."
        XCTAssertNil(
            LocalCoachValidator.validate(
                rejected, axis: .clearer, draft: draft, rejecting: [rejected]
            ),
            "a repeat of a rejected wording is not a new version"
        )
        XCTAssertNil(
            LocalCoachValidator.validate(
                "  “please send the report today.”  ", axis: .clearer, draft: draft,
                rejecting: [rejected]
            ),
            "the comparison must survive the quote/whitespace stripping"
        )
        XCTAssertNotNil(
            LocalCoachValidator.validate(
                "Could you get the report over to me today?", axis: .clearer, draft: draft,
                rejecting: [rejected]
            ),
            "a genuinely different wording must still pass"
        )
        // And an ordinary request is unaffected by the new parameter.
        XCTAssertNotNil(
            LocalCoachValidator.validate(rejected, axis: .clearer, draft: draft)
        )
    }

    // ── B6 · the architecture, pinned at the source ─────────────────────

    /// The skeleton is installed synchronously, before any model or network
    /// work, and the ordering is a property of the code rather than of a timing
    /// measurement that could pass on a fast machine.
    ///
    /// Both halves: the source order in `runCoach`, and the runtime fact that a
    /// controller whose engine never answers still has a result-shaped surface.
    @MainActor
    func testTheSkeletonIsInstalledBeforeAnyModelOrNetworkWork() throws {
        let code = try Self.source("KeyboardExtension/KeyboardViewController.swift")
        let runCoach = try XCTUnwrap(
            code.range(of: "func runCoach(draft: String, axis: String) {")
        )
        // Wide enough to contain the whole function, which carries a long
        // explanatory block between the two calls this test compares.
        let body = String(code[runCoach.upperBound...].prefix(6_000))
        let skeleton = try XCTUnwrap(
            body.range(of: "presentCoachLoading(requestID:"),
            "runCoach must install the loading surface"
        )
        let probe = try XCTUnwrap(
            body.range(of: "resolveLocalAvailability(requestID:"),
            "runCoach must resolve availability"
        )
        XCTAssertTrue(
            skeleton.lowerBound < probe.lowerBound,
            "the skeleton must be installed before the model is even asked what it can do"
        )

        // Runtime half: an engine that never answers, and a surface that is up.
        final class SilentEngine: LocalCoachRewriteEngine, @unchecked Sendable {
            func availability(locale: Locale) async -> LocalRewriteAvailability {
                while !Task.isCancelled { await Task.yield() }
                return .unsupportedOS
            }
            func rewriteSet(_ request: LocalCoachSetRequest) async throws -> LocalCoachSetResult {
                throw LocalCoachFailure(.cancelled)
            }
        }
        let (controller, _) = makeController(engine: SilentEngine())
        controller.beginCoachRewrite(before: Self.draft, after: "", axis: "clearer")
        controller.view.layoutIfNeeded()
        XCTAssertNotNil(
            Self.findView(controller.view, identifier: "TonoKB.coachLoading"),
            "the result-shaped skeleton must be up before anything has answered"
        )
        XCTAssertNotNil(controller.coachSkeletonForTesting)
        XCTAssertNotNil(
            controller.coachStageClockMilliseconds[KeyboardViewController.CoachStageClock.skeleton],
            "the skeleton clock must be recorded at the tap, not at the answer"
        )
    }

    /// The stage clocks are durations and nothing else. A timing instrument that
    /// carried message text would be the same defect Build 115 removed from the
    /// delivery path, in a new place.
    @MainActor
    func testTheStageClocksCarryOnlyDurations() {
        let engine = ProbeEngine()
        let (controller, _) = makeController(engine: engine)
        controller.beginCoachRewrite(before: Self.draft, after: "", axis: "clearer")
        waitUntil({ controller.coachSecondaryAxesForTesting.count == 2 })

        let clocks = controller.coachStageClockMilliseconds
        XCTAssertFalse(clocks.isEmpty, "the instrument must actually record something")
        for (key, value) in clocks {
            XCTAssertFalse(
                key.contains(Self.draft), "a clock key carried the draft: \(key)"
            )
            XCTAssertGreaterThanOrEqual(value, 0, "\(key) is not a duration")
            XCTAssertLessThan(value, 60_000, "\(key) is not a plausible duration")
        }
        // Every phase the contract asks to be measured is present.
        XCTAssertNotNil(clocks[KeyboardViewController.CoachStageClock.skeleton])
        XCTAssertNotNil(clocks[KeyboardViewController.CoachStageClock.selectedResult])
        XCTAssertNotNil(clocks[KeyboardViewController.CoachStageClock.secondaryStarted])
        XCTAssertEqual(
            clocks.keys.filter {
                $0.hasPrefix(KeyboardViewController.CoachStageClock.secondaryResult)
            }.count,
            2,
            "each secondary tone that landed must have its own measurement"
        )
    }

    /// The on-device route still constructs no network stack at all — the
    /// strongest form of the zero-network claim, restated for the staged path
    /// and for the appended tones.
    @MainActor
    func testTheStagedOnDeviceRouteNeverBuildsTheNetworkStack() {
        let engine = ProbeEngine()
        let (controller, _) = makeController(engine: engine, installSpyClient: false)
        XCTAssertFalse(controller.coachNetworkClientWasConstructedForTesting)

        controller.beginCoachRewrite(before: Self.draft, after: "", axis: "clearer")
        waitUntil({ controller.coachSecondaryAxesForTesting.count == 2 })

        XCTAssertFalse(
            controller.coachNetworkClientWasConstructedForTesting,
            "neither Stage 1 nor Stage 2 may construct a URLSession-backed client"
        )
    }

    /// A warmed `LanguageModelSession` is NOT reused between tones. It carries a
    /// transcript, so reusing one would feed each tone the previous tone's
    /// answer, and nothing has measured what that does to the result. This pins
    /// the cheaper claim: one fresh session per generation.
    func testNoWarmedSessionIsReusedAcrossGenerations() throws {
        let engine = try Self.source("Shared/OnDeviceAppleRewrite.swift")
        let constructions = engine.components(separatedBy: "LanguageModelSession(").count - 1
        XCTAssertGreaterThan(constructions, 0, "the engine must construct a session")
        XCTAssertFalse(
            engine.contains("private var session") || engine.contains("var warmedSession"),
            "no session may be held across requests without a verified lifecycle"
        )
    }

    // ═══════════════════════════════════════════════════════════════════
    // PART C — the real Foundation Models engine, where it is available
    // ═══════════════════════════════════════════════════════════════════

    /// The SHIPPED single-tone path, against the real model.
    ///
    /// This exists because Build 116 changed WHICH engine shape the keyboard
    /// uses. Build 115's real-model tests all exercise the three- and four-tone
    /// generations, and the live keyboard no longer issues either: every
    /// generation it makes is now one tone with the tone in both the guided
    /// field description and the instructions. Leaving those tests as the only
    /// real-model coverage would leave the shipped path proved by a stub —
    /// which is the exact shape of the Build 114 defect, where a complete
    /// on-device service had no reachable call site and the suite could not
    /// tell.
    ///
    /// Skips honestly — never passes silently — where no usable model exists.
    func testTheRealModelServesEachSelectedToneOnItsOwn() async throws {
        let bridge = AppleRewriteBridge.shared
        let availability = await bridge.availability(locale: Locale(identifier: "en_US"))
        try XCTSkipUnless(
            availability.isAvailable,
            "SystemLanguageModel reports \(availability.rawValue) on this machine — "
                + "the real-model path cannot be exercised here"
        )
        let flagsBefore = Build115LocalCoachTests.captureFeatureFlagCache()
        addTeardownBlock { Build115LocalCoachTests.restoreFeatureFlagCache(flagsBefore) }
        FeatureFlags.update(from: ["apple_intelligence_rewrite_enabled": true])

        // Two ordinary drafts, measured on iOS 26.5 to be served by the
        // single-tone path for every base tone. The draft that is NOT here —
        // and why — is the subject of the next test.
        for draft in [
            "can you please get me the numbers before the meeting tomorrow",
            "i am not happy about how that call went yesterday",
        ] {
            for axis in Tono.LocalCoachAxis.base {
                let result = try await bridge.rewriteSet(Tono.LocalCoachSetRequest(
                    draft: draft, axes: [axis], locale: Locale(identifier: "en_US")
                ))
                XCTAssertEqual(
                    result.options.count, 1, "\(axis) asked alone must come back alone"
                )
                let option = try XCTUnwrap(result.options.first)
                XCTAssertEqual(
                    option.axis, axis, "the answer must be labelled with the tone asked for"
                )
                XCTAssertFalse(option.text.isEmpty)
                XCTAssertNotEqual(
                    Tono.LocalCoachValidator.normalizedForNoOp(option.text),
                    Tono.LocalCoachValidator.normalizedForNoOp(draft),
                    "\(axis) returned the draft rather than a rewrite"
                )
                XCTAssertFalse(option.text.contains("```"), "validation must strip fences")
                XCTAssertLessThanOrEqual(
                    option.text.count, Tono.LocalCoachRoutePolicy.maximumOptionCharacters
                )
                XCTAssertEqual(result.metrics.availabilityReason, "available")
                // Privacy-safe timing instrumentation: a duration and a byte
                // count. Reported in the handoff as the measured per-tone cost
                // of staging, which is what the selected tone arriving first
                // actually buys.
                print(
                    "BUILD116 real-model single-tone \(axis.rawValue): "
                        + "\(Int(result.metrics.completionMilliseconds))ms, "
                        + "\(result.metrics.bytesOut) bytes out, "
                        + "peak \((result.metrics.peakFootprintBytes ?? 0) / 1_048_576)MB"
                )
            }
        }
    }

    /// HONEST LIMIT, measured and named rather than worked around.
    ///
    /// For some drafts the on-device model considers the message already in the
    /// requested tone and returns it back, changing only punctuation. Measured
    /// on iOS 26.5 with "hey I really need that report today, you keep pushing
    /// it back" asked for Clearer alone: the reply is the draft with a full stop
    /// added, three times out of three, and it is STILL the draft when the
    /// echoed wording is fed back as a rejected version and the instructions
    /// explicitly forbid repeating it. Greedy decoding is locked on it.
    ///
    /// Build 115 did not see this because it asked for three tones at once: an
    /// echoed Clearer was dropped and Warmer and Funnier carried the set — so
    /// the person got cards, just never the tone they tapped. Build 116 asks for
    /// the tapped tone, so an echo has nothing to hide behind, and this test
    /// pins what happens instead: the validator drops the no-op, the request
    /// fails `.noValidRewrite`, and that reason is in the HAND-OFF disposition —
    /// the connected route produces the Clearer rewrite the person asked for.
    ///
    /// That is the correct outcome and it is not free: with no connection and
    /// this particular draft, Clearer cannot be served. It is bounded — the test
    /// above shows ordinary drafts are served for every tone — and it is stated
    /// in the handoff rather than discovered later.
    func testAnEchoedToneIsDroppedRatherThanShownAsARewrite() async throws {
        let bridge = AppleRewriteBridge.shared
        let availability = await bridge.availability(locale: Locale(identifier: "en_US"))
        try XCTSkipUnless(
            availability.isAvailable,
            "SystemLanguageModel reports \(availability.rawValue) on this machine — "
                + "the real-model path cannot be exercised here"
        )
        let flagsBefore = Build115LocalCoachTests.captureFeatureFlagCache()
        addTeardownBlock { Build115LocalCoachTests.restoreFeatureFlagCache(flagsBefore) }
        FeatureFlags.update(from: ["apple_intelligence_rewrite_enabled": true])

        let draft = "hey I really need that report today, you keep pushing it back"
        do {
            let result = try await bridge.rewriteSet(Tono.LocalCoachSetRequest(
                draft: draft, axes: [.clearer], locale: Locale(identifier: "en_US")
            ))
            // If the model DOES rewrite it, that is a fine outcome too — but it
            // must be a real rewrite, never the draft wearing new punctuation.
            let option = try XCTUnwrap(result.options.first)
            XCTAssertNotEqual(
                Tono.LocalCoachValidator.normalizedForNoOp(option.text),
                Tono.LocalCoachValidator.normalizedForNoOp(draft),
                "a validated option can never be the draft"
            )
            print("BUILD116 real-model echo probe: the model rewrote it this time")
        } catch let failure as Tono.LocalCoachFailure {
            XCTAssertEqual(
                failure.reason, .noValidRewrite,
                "an echoed tone must be dropped as an invalid rewrite, not surfaced as "
                    + "some other failure"
            )
            // …and that reason hands off, so the person still gets the tone they
            // tapped wherever there is a connection.
            XCTAssertEqual(
                LocalCoachRoutePolicy.decide(
                    requestedAxis: "clearer", draft: Self.draft, remoteKillSwitchAllows: true,
                    preference: .unset, availability: .deviceNotEligible,
                    saferCorpusGateOpen: false, connectivityKnownAbsent: false
                ),
                .cloud(.deviceNotEligible),
                "sanity: an unservable local request reaches the connected route"
            )
            print("BUILD116 real-model echo probe: echoed and was correctly dropped")
        }
    }

    /// The on-device `Try another`, against the real model.
    ///
    /// Reported rather than asserted, deliberately. Greedy decoding on a prompt
    /// that now carries the rejected wording MAY produce a materially different
    /// sentence and may not — that is a property of the model, not of this code,
    /// and asserting it would be claiming something no measurement supports.
    /// What IS asserted is the part that is ours: whatever comes back, it is
    /// never the wording the person already turned down, because the validator
    /// drops that. Either outcome is a pass; which one occurred is printed.
    func testTheRealModelAlternativeIsNeverTheRejectedWording() async throws {
        let bridge = AppleRewriteBridge.shared
        let availability = await bridge.availability(locale: Locale(identifier: "en_US"))
        try XCTSkipUnless(
            availability.isAvailable,
            "SystemLanguageModel reports \(availability.rawValue) on this machine — "
                + "the real-model path cannot be exercised here"
        )
        let flagsBefore = Build115LocalCoachTests.captureFeatureFlagCache()
        addTeardownBlock { Build115LocalCoachTests.restoreFeatureFlagCache(flagsBefore) }
        FeatureFlags.update(from: ["apple_intelligence_rewrite_enabled": true])

        // A draft the single-tone path is measured to serve — see
        // `testAnEchoedToneIsDroppedRatherThanShownAsARewrite` for the one it
        // does not, and why this test must not use it: there would be no
        // version 1 to ask for an alternative to.
        let draft = "can you please get me the numbers before the meeting tomorrow"
        let first = try await bridge.rewriteSet(Tono.LocalCoachSetRequest(
            draft: draft, axes: [.clearer], locale: Locale(identifier: "en_US")
        ))
        let versionOne = try XCTUnwrap(first.options.first).text

        do {
            let second = try await bridge.rewriteSet(Tono.LocalCoachSetRequest(
                draft: draft, axes: [.clearer], locale: Locale(identifier: "en_US"),
                rejectedVersions: [versionOne]
            ))
            let versionTwo = try XCTUnwrap(second.options.first).text
            XCTAssertNotEqual(
                Tono.LocalCoachValidator.normalizedForNoOp(versionTwo),
                Tono.LocalCoachValidator.normalizedForNoOp(versionOne),
                "an alternative that survived validation cannot be the rejected wording"
            )
            print("BUILD116 real-model alternative: produced a materially different wording")
        } catch let declined as Tono.LocalCoachFailure {
            // The honest other outcome: the model wrote the same thing again
            // and the validator dropped it. The controller turns exactly this
            // into "this iPhone writes this one the same way every time".
            XCTAssertEqual(
                declined.reason, .noValidRewrite,
                "a repeat must be dropped as an invalid rewrite, not surfaced as some other failure"
            )
            print("BUILD116 real-model alternative: repeated version 1 and was dropped")
        }
    }
}
