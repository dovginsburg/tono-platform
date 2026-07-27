// Build116AirplaneModeTests.swift
// Build 116 — the host app notices the connection leaving.
//
// ── THE REPORTED BLOCKER ────────────────────────────────────────────────────
//
// In the Tono app: coach a draft, get a rewrite, leave it on screen, turn on
// Airplane Mode. Nothing changed. The Coach control stayed exactly as available
// as it had looked a second earlier, and the app went on believing it was
// online until something made it try — at which point the attempt failed AND
// took the rewrite with it, because `runCoach()` cleared the result before
// every attempt.
//
// ── ROOT CAUSE (proved, not inferred) ───────────────────────────────────────
//
// The host app had no connectivity input of any kind. Its entire notion of
// "are we online" was the outcome of the last request it happened to make, so
// a surface holding a delivered result with no request in flight had — by
// construction, not by oversight — nothing that could change. The rendered
// state of `CoachView` was a function of `loading`, `analysis` and
// `errorMessage` alone, and none of the three can move without a new request.
// That is why "another request, a new view, or a relaunch" was the only way to
// find out: those are the only three things that recreate the inputs.
//
// ── HOW REDNESS WAS ESTABLISHED ─────────────────────────────────────────────
//
// PART A runs against the EXACT Build 116 baseline (d1226365 / tree 092fb01a)
// with only this file and its project membership added — every production
// source byte-identical to the commit. It uses only API that exists there:
// `CoachView()`, the rendered view tree, the URL loading system. Both of its
// tests FAIL on that baseline, for the reason each one states. The failures are
// recorded verbatim in the Build 116 airplane-mode handoff.
//
// PART B pins the contract that did not exist at the baseline at all — a
// process-lifetime connectivity observer with an injectable source. It cannot
// be compiled against the baseline, so no red RUN is claimed for it; what is
// claimed is that the behaviour it pins is new. This is the same two-tier
// convention `Build116SelectedFirstTests` already uses, and for the same
// reason: a contract whose whole point is a seam that did not exist cannot be
// expressed in the vocabulary of the build that lacked it.
//
// Nothing here toggles a real radio — a simulator has none — so every
// connectivity transition is driven through the source the app observes, and
// every claim about what did or did not leave the device is MEASURED at the URL
// loading system rather than asserted.

import XCTest
import SwiftUI
import UIKit
@testable import Tono

final class Build116AirplaneModeTests: XCTestCase {

    // ───────────────────────────────────────────────────────────────────
    // The world the app talks to
    // ───────────────────────────────────────────────────────────────────

    /// Answers the three backend paths `CoachView` needs, and can be switched
    /// to "there is no route" — which is what a device in Airplane Mode
    /// actually reports to the URL loading system.
    ///
    /// Registered process-wide because `TonoBackend` builds its requests on
    /// `URLSession.shared`, which no test can hand a configuration to. The
    /// well-known hazard of that (Build 109) is charging the host app's own
    /// launch traffic to the code under test, so this narrows twice: it claims
    /// only the exact paths below, and the egress tally counts only
    /// `/api/analyze`, which nothing else in this process issues.
    final class CoachBackendStub: URLProtocol {
        private static let lock = NSLock()
        private nonisolated(unsafe) static var _analyzeCount = 0
        private nonisolated(unsafe) static var _hasRoute = true

        /// Requests to `/api/analyze` — the one path `CoachView` originates.
        static var analyzeCount: Int { lock.withLock { _analyzeCount } }

        /// Flip to `false` to model a device with no route at all.
        static var hasRoute: Bool {
            get { lock.withLock { _hasRoute } }
            set { lock.withLock { _hasRoute = newValue } }
        }

        /// A failure that has nothing to do with connectivity, so a sentence
        /// about one cannot be confused with a sentence about the other.
        private nonisolated(unsafe) static var _analyzeStatus = 200
        static var analyzeStatus: Int {
            get { lock.withLock { _analyzeStatus } }
            set { lock.withLock { _analyzeStatus = newValue } }
        }

        static func reset() {
            lock.withLock { _analyzeCount = 0; _hasRoute = true; _analyzeStatus = 200 }
        }

        private static let claimed: Set<String> = ["/v1/register", "/v1/me", "/api/analyze"]

        override class func canInit(with request: URLRequest) -> Bool {
            guard let path = request.url?.path, claimed.contains(path) else { return false }
            if path == "/api/analyze" { lock.withLock { _analyzeCount += 1 } }
            return true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url else { return }
            guard Self.hasRoute else {
                // Exactly what a device with no route reports.
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            let body: String
            var status = 200
            switch url.path {
            case "/v1/register":
                body = #"{"device_id":"b116-air","api_token":"b116-air-token","#
                    + #""device_credential":"b116-air-credential","plan":"pro","is_pro":true,"#
                    + #""account_id":"6E7E0A64-1B2C-4D3E-8F90-A1B2C3D4E5F6"}"#
            case "/v1/me":
                body = #"{"device_id":"b116-air","plan":"pro","is_pro":true,"#
                    + #""subscription_status":"active","subscription_renews_at":null,"#
                    + #""account_id":"6E7E0A64-1B2C-4D3E-8F90-A1B2C3D4E5F6","email":null,"#
                    + #""email_verified_at":null,"device_count_for_email":1,"max_devices_per_email":3}"#
            default:
                status = Self.analyzeStatus
                body = status == 200 ? Self.analysisJSON : #"{"detail":"unavailable"}"#
            }
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        /// All four axes in `RewriteAxis.allCases` order — `analyze(mode:.coach)`
        /// rejects an incomplete set, so an abbreviated fixture would fail as a
        /// decode rather than deliver.
        static let analysisJSON = #"""
        {"risk_level":"medium","perception":"Reads as rushed.","subtext":"","risk_reason":null,
         "flags":[],"plan":"pro",
         "suggestions":[
           {"axis":"warmer","text":"WARMER-DELIVERED-WHILE-CONNECTED","rationale":null,"risk_after":"low"},
           {"axis":"clearer","text":"CLEARER-DELIVERED-WHILE-CONNECTED","rationale":null,"risk_after":"low"},
           {"axis":"funnier","text":"FUNNIER-DELIVERED-WHILE-CONNECTED","rationale":null,"risk_after":"low"},
           {"axis":"safer","text":"SAFER-DELIVERED-WHILE-CONNECTED","rationale":null,"risk_after":"low"}
         ]}
        """#
    }

    /// The draft the person typed. Distinctive so "the draft is still there" is
    /// a real search rather than a match on incidental chrome.
    static let draft = "hey can u send me the file tmrw thanks"
    /// The rewrite that was delivered while connected.
    static let deliveredRewrite = "WARMER-DELIVERED-WHILE-CONNECTED"

    override func setUp() {
        super.setUp()
        CoachBackendStub.reset()
        URLProtocol.registerClass(CoachBackendStub.self)
        addTeardownBlock {
            URLProtocol.unregisterClass(CoachBackendStub.self)
            CoachBackendStub.reset()
        }
    }

    // ───────────────────────────────────────────────────────────────────
    // Hosting machinery
    // ───────────────────────────────────────────────────────────────────

    /// A laid-out `CoachView` in a real window, because the assertions are
    /// about what a person sees and about a control they can reach.
    @MainActor
    private func host<V: View>(_ view: V) -> UIHostingController<AnyView> {
        let controller = UIHostingController(rootView: AnyView(view))
        controller.overrideUserInterfaceStyle = .dark
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let window = UIWindow(frame: controller.view.frame)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = controller
        window.isHidden = false
        window.makeKeyAndVisible()
        addTeardownBlock { MainActor.assumeIsolated { window.isHidden = true } }
        settle(controller)
        return controller
    }

    /// Lay out and let SwiftUI's own work drain. SwiftUI applies state changes
    /// on the next render pass, so an assertion taken immediately after a state
    /// change reads the previous frame.
    @MainActor
    private func settle(_ controller: UIViewController, seconds: TimeInterval = 0.35) {
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
    }

    /// Spin until `condition` holds or the budget runs out, laying out as we go.
    @MainActor
    @discardableResult
    private func settle(
        _ controller: UIViewController, until condition: () -> Bool, seconds: TimeInterval = 6
    ) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        return condition()
    }

    /// Every accessibility element in the laid-out tree, in traversal order.
    ///
    /// `accessibilityElementCount()` rather than the `accessibilityElements`
    /// property because SwiftUI materialises its tree lazily and the property
    /// is nil until something asks.
    @MainActor
    private func elements(of view: UIView) -> [NSObject] {
        var found: [NSObject] = []
        var seen = 0
        func walk(_ node: Any) {
            seen += 1
            guard seen < 6000 else { return }
            guard let object = node as? NSObject else { return }
            if object.isAccessibilityElement { found.append(object); return }
            let count = object.accessibilityElementCount()
            if count != NSNotFound && count > 0 {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) { walk(child) }
                }
                return
            }
            if let children = object.accessibilityElements { children.forEach(walk); return }
            (object as? UIView)?.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    /// Everything the surface currently says, as one searchable string.
    @MainActor
    private func rendered(_ controller: UIViewController) -> String {
        elements(of: controller.view)
            .map { ($0.accessibilityLabel ?? "") + " " + ($0.accessibilityValue ?? "") }
            .joined(separator: "\n")
    }

    /// The control named `name`, if the surface has one.
    ///
    /// Matched as the whole name, or the name followed by a qualifying clause
    /// (`"Coach, unavailable…"`). A bare prefix would also match the navigation
    /// title "Coach this", which is not a control.
    @MainActor
    private func element(labelled name: String, in controller: UIViewController) -> NSObject? {
        elements(of: controller.view).first {
            let label = $0.accessibilityLabel ?? ""
            return label == name || label.hasPrefix(name + ",")
        }
    }

    /// Whether the surface presents `name` as something that can act.
    @MainActor
    private func isAvailable(_ name: String, in controller: UIViewController) -> Bool {
        guard let control = element(labelled: name, in: controller) else { return false }
        return !control.accessibilityTraits.contains(.notEnabled)
    }

    /// The first `UITextView` in the tree — SwiftUI's `TextEditor` is one.
    @MainActor
    private func textView(in view: UIView) -> UITextView? {
        if let editor = view as? UITextView { return editor }
        for child in view.subviews {
            if let found = textView(in: child) { return found }
        }
        return nil
    }

    /// Type a draft the way a person does: through the text view's own input
    /// path, so SwiftUI's binding updates. Assigning `.text` would change the
    /// pixels and leave `CoachView.draft` empty.
    @MainActor
    private func type(_ text: String, into controller: UIViewController) throws {
        let editor = try XCTUnwrap(
            textView(in: controller.view), "CoachView must render a draft editor"
        )
        editor.becomeFirstResponder()
        editor.insertText(text)
        settle(controller)
    }

    /// Tap a control the way assistive technology does. Returns false when the
    /// control refused to act.
    @MainActor
    @discardableResult
    private func activate(_ prefix: String, in controller: UIViewController) throws -> Bool {
        let control = try XCTUnwrap(
            element(labelled: prefix, in: controller),
            "the surface must offer a control labelled “\(prefix)”"
        )
        let acted = control.accessibilityActivate()
        settle(controller)
        return acted
    }

    /// Drive the app to a delivered, on-screen Online rewrite — the exact state
    /// the founder's device was in before Airplane Mode went on.
    @MainActor
    private func coachOnce(_ controller: UIHostingController<AnyView>) throws {
        try type(Self.draft, into: controller)
        try activate("Coach", in: controller)
        let delivered = settle(controller, until: {
            self.rendered(controller).contains(Self.deliveredRewrite)
        })
        XCTAssertTrue(
            delivered,
            """
            precondition failed: the connected rewrite never reached the screen, so nothing \
            below is measuring the reported blocker. Rendered: \(rendered(controller).prefix(600))
            """
        )
    }

    // ═══════════════════════════════════════════════════════════════════
    // PART A — RED on the exact baseline d1226365
    // ═══════════════════════════════════════════════════════════════════

    /// A1 — the rewrite survives the connection going away.
    ///
    /// The founder's sequence, with the only step a unit test can take instead
    /// of flipping a radio: the route disappears, and the person does the one
    /// thing the surface still invites them to do.
    ///
    /// BASELINE FAILURE: `runCoach()` opened with `analysis = nil`, so the
    /// rewrite on screen was destroyed before the doomed attempt was even
    /// built. The person lost the answer they were reading in order to be told
    /// there was no connection.
    @MainActor
    func testTheDeliveredRewriteAndTheDraftSurviveTheConnectionGoingAway() throws {
        let controller = host(CoachView())
        try coachOnce(controller)

        // Airplane Mode: the device has no route.
        CoachBackendStub.hasRoute = false
        settle(controller)

        // The one thing the surface invites: the Coach control.
        try activate("Coach", in: controller)
        settle(controller, until: { false }, seconds: 2)

        let surface = rendered(controller)
        XCTAssertTrue(
            surface.contains(Self.deliveredRewrite),
            """
            the rewrite that was already delivered and on screen was destroyed by losing \
            the connection. Rendered: \(surface.prefix(800))
            """
        )
        XCTAssertTrue(
            surface.contains(Self.draft),
            "the person's own draft must survive too. Rendered: \(surface.prefix(800))"
        )
    }

    /// A2 — the delivered rewrite stays USABLE, not merely visible.
    ///
    /// A rewrite you can read but not copy is not a preserved result; the whole
    /// point of the card is that the text can be taken to wherever it is going.
    ///
    /// BASELINE FAILURE: the results card is rendered from `analysis`, so
    /// clearing it took the Copy action with it — the person was left with a
    /// failure sentence and no way to recover the wording they had.
    @MainActor
    func testTheDeliveredRewriteStaysUsableAfterTheConnectionGoesAway() throws {
        let controller = host(CoachView())
        try coachOnce(controller)
        XCTAssertNotNil(
            element(labelled: "Copy", in: controller),
            "precondition failed: a delivered rewrite must offer Copy while connected"
        )

        CoachBackendStub.hasRoute = false
        settle(controller)
        try activate("Coach", in: controller)
        settle(controller, until: { false }, seconds: 2)

        XCTAssertNotNil(
            element(labelled: "Copy", in: controller),
            """
            losing the connection removed the delivered rewrite's Copy action, so the wording \
            the person already had could not be recovered. Rendered: \(rendered(controller).prefix(800))
            """
        )
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// PART B — the contract that did not exist at the baseline
//
// Everything below drives `TonoConnectivity` through an injected source. None
// of it compiles against d1226365, where there was no connectivity observer to
// inject into — which is the defect, stated as a compile error.
// ═══════════════════════════════════════════════════════════════════════════

extension Build116AirplaneModeTests {

    /// A path source the test owns, so every transition is exact.
    ///
    /// The alternative is a real radio, and a simulator has none — which is
    /// precisely why the shipped app could carry this defect through fifteen
    /// builds of otherwise thorough testing.
    final class FakePathSource: TonoConnectivityPathSource {
        private let lock = NSLock()
        private var handler: ((Bool) -> Void)?
        private var _currentlySatisfied: Bool?
        private var _startCount = 0
        private var _cancelCount = 0

        var startCount: Int { lock.withLock { _startCount } }
        var cancelCount: Int { lock.withLock { _cancelCount } }

        var currentlySatisfied: Bool? {
            get { lock.withLock { _currentlySatisfied } }
            set { lock.withLock { _currentlySatisfied = newValue } }
        }

        func start(onReport: @escaping (Bool) -> Void) {
            lock.withLock { _startCount += 1; handler = onReport }
        }

        func cancel() {
            lock.withLock { _cancelCount += 1; handler = nil }
        }

        /// Deliver one path update, exactly as the system would.
        func report(_ satisfied: Bool) {
            currentlySatisfied = satisfied
            lock.withLock { handler }?(satisfied)
        }

        /// Change the world WITHOUT delivering an update — what a transition
        /// that happened while the app was off screen looks like.
        func changeSilently(to satisfied: Bool) {
            currentlySatisfied = satisfied
        }

        /// True while something is still wired to receive reports.
        var isObserving: Bool { lock.withLock { handler != nil } }
    }

    /// A started observer with the test holding the wire.
    private func makeConnectivity() -> (TonoConnectivity, FakePathSource) {
        let source = FakePathSource()
        let connectivity = TonoConnectivity(source: source)
        connectivity.start()
        return (connectivity, source)
    }

    /// The founder's device, one step before Airplane Mode: connected, coached,
    /// rewrite on screen.
    @MainActor
    private func coachedAndConnected() throws
        -> (UIHostingController<AnyView>, TonoConnectivity, FakePathSource) {
        let (connectivity, source) = makeConnectivity()
        source.report(true)
        let controller = host(CoachView(connectivity: connectivity))
        try coachOnce(controller)
        return (controller, connectivity, source)
    }

    // ── B1 · the reported blocker, end to end ───────────────────────────────

    /// The exact sequence from the device report: connected rewrite on screen,
    /// then the path goes away. No tap, no new request, no view recreation, no
    /// relaunch — and the surface tells the truth anyway.
    @MainActor
    func testTurningOffTheRadioUpdatesTheSurfaceWithNoRequestAndNoRecreation() throws {
        let (controller, _, source) = try coachedAndConnected()
        let requestsBefore = CoachBackendStub.analyzeCount
        let identity = ObjectIdentifier(controller)

        // Airplane Mode. Nothing else happens: no gesture, no navigation.
        CoachBackendStub.hasRoute = false
        source.report(false)
        settle(controller)

        let surface = rendered(controller)
        XCTAssertTrue(
            surface.contains("No internet connection"),
            "the surface must say what changed, unprompted. Rendered: \(surface.prefix(800))"
        )
        XCTAssertTrue(
            surface.contains(Self.deliveredRewrite),
            "the delivered rewrite must still be there"
        )
        XCTAssertTrue(surface.contains(Self.draft), "the person's draft must still be there")
        XCTAssertFalse(
            isAvailable("Coach", in: controller),
            "the online-only action must stop presenting itself as available"
        )
        XCTAssertEqual(
            CoachBackendStub.analyzeCount, requestsBefore,
            "learning that the connection went away must cost no request"
        )
        XCTAssertEqual(
            ObjectIdentifier(controller), identity,
            "the surface must update in place — no recreation, no relaunch"
        )
    }

    /// The gated control sends nothing. Measured at the URL loading system,
    /// because "it looks disabled" is not the same claim as "no text left the
    /// device".
    @MainActor
    func testTheGatedCoachControlAttemptsNoEgressWhileOffline() throws {
        let (controller, _, source) = try coachedAndConnected()
        CoachBackendStub.hasRoute = false
        source.report(false)
        settle(controller)

        let requestsBefore = CoachBackendStub.analyzeCount
        let acted = try activate("Coach", in: controller)
        settle(controller, until: { false }, seconds: 1.5)

        XCTAssertFalse(acted, "a gated control must refuse to act rather than act uselessly")
        XCTAssertEqual(
            CoachBackendStub.analyzeCount, requestsBefore,
            "the offline Coach control attempted egress"
        )
        XCTAssertTrue(
            rendered(controller).contains(Self.deliveredRewrite),
            "and version 1 is still on screen afterwards"
        )
    }

    /// Gated is not inert: refusing to act is only honest if the surface says
    /// why, and says it once.
    @MainActor
    func testTheOfflineSurfaceStatesOneTruthfulReasonRatherThanNothingOrSeveral() throws {
        let (controller, _, source) = try coachedAndConnected()
        CoachBackendStub.hasRoute = false
        source.report(false)
        settle(controller)

        let surface = rendered(controller)
        XCTAssertEqual(
            surface.components(separatedBy: "No internet connection").count - 1, 1,
            "exactly one statement of the condition — not a stack of them. Rendered: \(surface.prefix(800))"
        )
        XCTAssertTrue(
            surface.contains("Your rewrite is still here"),
            "with a result on screen the notice must say the result is safe"
        )
        XCTAssertTrue(
            (element(labelled: "Coach", in: controller)?.accessibilityLabel ?? "")
                .contains("unavailable"),
            "assistive technology must get the reason too, not just a dimmed capsule"
        )
    }

    /// With nothing to protect, the notice must not claim there is.
    @MainActor
    func testTheOfflineNoticeDoesNotPromiseARewriteThatDoesNotExist() throws {
        let (connectivity, source) = makeConnectivity()
        source.report(false)
        let controller = host(CoachView(connectivity: connectivity))
        try type(Self.draft, into: controller)
        settle(controller)

        let surface = rendered(controller)
        XCTAssertTrue(surface.contains("No internet connection"))
        XCTAssertFalse(
            surface.contains("Your rewrite is still here"),
            "there is no rewrite — saying otherwise is the reassuring kind of lie"
        )
        XCTAssertFalse(isAvailable("Coach", in: controller))
    }

    // ── B2 · coming back ────────────────────────────────────────────────────

    /// Reconnection restores exactly what is available again, promptly, with no
    /// relaunch — and does not silently re-run anything on the person's behalf.
    @MainActor
    func testReconnectingRestoresTheOnlineActionWithoutRelaunchOrAnUnaskedRequest() throws {
        let (controller, _, source) = try coachedAndConnected()
        CoachBackendStub.hasRoute = false
        source.report(false)
        settle(controller)
        XCTAssertFalse(isAvailable("Coach", in: controller))

        let requestsWhileOffline = CoachBackendStub.analyzeCount
        CoachBackendStub.hasRoute = true
        source.report(true)
        settle(controller)

        XCTAssertFalse(
            rendered(controller).contains("No internet connection"),
            "the notice must go when the condition does"
        )
        XCTAssertTrue(
            isAvailable("Coach", in: controller),
            "the online action must come back without a relaunch"
        )
        XCTAssertEqual(
            CoachBackendStub.analyzeCount, requestsWhileOffline,
            "reconnecting must not fire a request nobody asked for"
        )

        // And the restored capability is real, not just re-enabled.
        try activate("Coach", in: controller)
        XCTAssertTrue(
            settle(controller, until: { CoachBackendStub.analyzeCount == requestsWhileOffline + 1 }),
            "the restored control must actually be able to coach again"
        )
    }

    // ── B3 · the transitions that used to be luck ───────────────────────────

    /// Flapping resolves to the last fact, every time, in both directions.
    @MainActor
    func testRapidFlappingResolvesToTheLastReportedFact() throws {
        let (controller, connectivity, source) = try coachedAndConnected()

        for finalState in [false, true, false, false, true] {
            for _ in 0..<12 {
                source.report(true)
                source.report(false)
            }
            source.report(finalState)
            settle(controller, seconds: 0.15)
            XCTAssertEqual(
                connectivity.status, finalState ? .online : .offline,
                "a flap must resolve to its last report, not to whichever arrived loudest"
            )
            XCTAssertEqual(
                rendered(controller).contains("No internet connection"), !finalState,
                "and the surface must agree with it"
            )
            XCTAssertTrue(
                rendered(controller).contains(Self.deliveredRewrite),
                "no amount of flapping may disturb the delivered rewrite"
            )
        }
    }

    /// A report overtaken on its way to the main thread describes a world that
    /// has already been superseded, and is dropped whole.
    ///
    /// Driven by holding the main thread: the background report is stamped and
    /// queued but cannot land, the main-thread report is stamped later and
    /// applied immediately, and only then is the queue allowed to drain.
    ///
    /// The background hop must be a REAL one. The first version of this test
    /// used `DispatchQueue.sync`, which runs the block on the calling thread as
    /// an optimisation — so the "background" report was applied synchronously
    /// on main, no overtaking ever happened, and the test passed with the
    /// ordering guard deleted. A semaphore hand-off replaces it: the report is
    /// stamped on a genuinely different thread, and main is held until it has
    /// been, so the queued application provably cannot have landed yet.
    @MainActor
    func testAStaleReportCannotOverwriteANewerOne() throws {
        let (connectivity, source) = makeConnectivity()
        source.report(true)
        XCTAssertEqual(connectivity.status, .online)

        let stamped = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            XCTAssertFalse(Thread.isMainThread, "the overtaking must be across threads to be real")
            source.report(false)   // stamped first; its application is now queued on main
            stamped.signal()
        }
        stamped.wait()             // main is held, so that queued application cannot run

        source.report(true)        // stamped second, applied synchronously right now
        XCTAssertEqual(connectivity.status, .online)

        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(
            connectivity.status, .online,
            "the overtaken report was applied out of order and rewrote a newer fact"
        )
    }

    /// A failure sentence describes one attempt under one set of conditions.
    /// When the conditions change it stops being current, so it must not
    /// reappear intact on the other side of the transition.
    ///
    /// Deliberately driven by a failure that is NOT about connectivity, so
    /// "the old sentence went" cannot be confused with "the offline sentence
    /// replaced it".
    @MainActor
    func testAFailureSentenceDoesNotSurviveTheConditionsThatProducedIt() throws {
        let (controller, _, source) = try coachedAndConnected()
        let stale = "Something went wrong. Try again in a moment."

        CoachBackendStub.analyzeStatus = 500
        try activate("Coach", in: controller)
        XCTAssertTrue(
            settle(controller, until: { self.rendered(controller).contains(stale) }),
            "precondition: a failed attempt must say so. Rendered: \(rendered(controller).prefix(600))"
        )
        XCTAssertTrue(
            rendered(controller).contains(Self.deliveredRewrite),
            "and even a failed attempt leaves the delivered rewrite alone"
        )

        // The connection goes: the current condition outranks the stale report.
        CoachBackendStub.hasRoute = false
        source.report(false)
        settle(controller)
        XCTAssertFalse(
            rendered(controller).contains(stale),
            "a failure from a moment ago must not sit under a notice that contradicts it"
        )
        XCTAssertEqual(
            rendered(controller).components(separatedBy: "No internet connection").count - 1, 1
        )

        // And back — the sentence from the previous network world stays gone.
        CoachBackendStub.hasRoute = true
        CoachBackendStub.analyzeStatus = 200
        source.report(true)
        settle(controller)
        let surface = rendered(controller)
        XCTAssertFalse(
            surface.contains(stale),
            "a failure from the previous network world must not reappear when it ends"
        )
        XCTAssertFalse(surface.contains("No internet connection"))
        XCTAssertTrue(surface.contains(Self.deliveredRewrite), "and the rewrite is still there")
        XCTAssertTrue(isAvailable("Coach", in: controller))
    }

    /// The trip to Airplane Mode leaves the app. A change that happened while
    /// it was off screen must be true on the surface the moment it is back.
    @MainActor
    func testReturningToTheForegroundReAssertsTheCurrentFact() throws {
        let (controller, connectivity, source) = try coachedAndConnected()

        // Backgrounded: the world changed and no update was delivered.
        source.changeSilently(to: false)
        settle(controller, seconds: 0.1)
        XCTAssertEqual(
            connectivity.status, .online, "precondition: nothing was delivered, so nothing changed"
        )

        connectivity.refresh()   // what didBecomeActive calls
        settle(controller)

        XCTAssertEqual(connectivity.status, .offline)
        XCTAssertTrue(rendered(controller).contains("No internet connection"))
        XCTAssertTrue(
            rendered(controller).contains(Self.deliveredRewrite),
            "and the rewrite survived the round trip"
        )
    }

    /// The wiring for the above. Driven structurally rather than by hosting the
    /// whole `RootView`, because `RootView` reaches the shared observer that no
    /// test may inject into — pinning the call site is the honest half.
    func testTheAppStartsOneObserverAtLaunchAndReAssertsItOnForeground() throws {
        let source = try Self.source("App/TonoApp.swift")
        XCTAssertTrue(
            source.contains("TonoConnectivity.shared.start()"),
            "the observer must be started once, by the app, for the life of the process"
        )
        let foreground = try XCTUnwrap(
            Self.body(after: "UIApplication.didBecomeActiveNotification", in: source),
            "RootView must handle didBecomeActive"
        )
        XCTAssertTrue(
            foreground.contains("TonoConnectivity.shared.refresh()"),
            "returning to the foreground must re-assert the current fact"
        )
    }

    // ── B4 · the observer's own lifetime ────────────────────────────────────

    /// Starting twice is one observer. A foreground/background cycle that
    /// called `start()` again would otherwise accumulate them for the life of
    /// the process.
    func testStartingTwiceStartsOneObserver() {
        let source = FakePathSource()
        let connectivity = TonoConnectivity(source: source)
        connectivity.start()
        connectivity.start()
        connectivity.start()
        XCTAssertEqual(source.startCount, 1)
    }

    /// Nothing is claimed before something is known — `checking` is not
    /// `offline`. A started-but-silent observer must not gate a control that
    /// works or put a false statement on screen.
    @MainActor
    func testAnObserverWithNoReportYetClaimsNothingAndGatesNothing() throws {
        let source = FakePathSource()
        let connectivity = TonoConnectivity(source: source)
        connectivity.start()
        XCTAssertEqual(connectivity.status, .checking)
        XCTAssertFalse(connectivity.isOffline, "unknown is not offline")

        let controller = host(CoachView(connectivity: connectivity))
        try type(Self.draft, into: controller)
        settle(controller)
        XCTAssertFalse(rendered(controller).contains("No internet connection"))
        XCTAssertTrue(
            isAvailable("Coach", in: controller),
            "an unknown state must never gate a control that may well work"
        )
    }

    /// A released observer stops observing and cannot be published into.
    func testAReleasedObserverCancelsItsSourceAndStopsReceiving() {
        let source = FakePathSource()
        weak var released: TonoConnectivity?
        autoreleasepool {
            let connectivity = TonoConnectivity(source: source)
            connectivity.start()
            source.report(false)
            released = connectivity
            XCTAssertTrue(source.isObserving)
        }
        XCTAssertNil(released, "the observer must not outlive its owner")
        XCTAssertEqual(source.cancelCount, 1, "releasing it must cancel the underlying observer")
        XCTAssertFalse(source.isObserving)
        // A report arriving after teardown reaches nothing at all.
        source.report(true)
        XCTAssertNil(released)
    }

    /// `stop()` is the explicit form of the same thing, and `refresh()` after
    /// it does not quietly restart anything.
    func testStoppingCancelsAndRefreshAfterwardsDoesNothing() {
        let (connectivity, source) = makeConnectivity()
        source.report(true)
        XCTAssertEqual(connectivity.status, .online)
        connectivity.stop()
        XCTAssertEqual(source.cancelCount, 1)
        source.changeSilently(to: false)
        connectivity.refresh()
        XCTAssertEqual(
            connectivity.status, .online,
            "a stopped observer must not answer questions it is no longer entitled to answer"
        )
    }

    /// `refresh()` before `start()` reports nothing — there is no observer to
    /// re-assert.
    func testRefreshBeforeStartIsANoOp() {
        let source = FakePathSource()
        let connectivity = TonoConnectivity(source: source)
        source.changeSilently(to: false)
        connectivity.refresh()
        XCTAssertEqual(connectivity.status, .checking)
    }

    // ── B5 · what must NOT have changed ─────────────────────────────────────

    /// The delivered result keeps its own name. A rewrite that came from the
    /// connected route is a connected rewrite forever; the network dropping
    /// afterwards changes what Tono can do NEXT, not where the words came from.
    @MainActor
    func testLosingTheConnectionDoesNotRelabelTheAlreadyDeliveredResult() throws {
        let (controller, _, source) = try coachedAndConnected()
        let labelWhileConnected = rendered(controller).contains("Warmer rewrite")
        XCTAssertTrue(labelWhileConnected, "precondition: the card names the tone it delivered")

        source.report(false)
        settle(controller)

        let surface = rendered(controller).lowercased()
        XCTAssertTrue(
            rendered(controller).contains("Warmer rewrite"),
            "the delivered result must keep the label it earned"
        )
        for claim in ["on device", "on-device", "this device", "offline rewrite"] {
            XCTAssertFalse(
                surface.contains(claim),
                "an Online result must never be relabelled “\(claim)” because the network later dropped"
            )
        }
    }

    /// The gate is decided BEFORE anything connected is reachable.
    ///
    /// The disabled control is the gate a person sees, and four tests above
    /// measure it. This pins the second half, which no rendered assertion can
    /// reach: the window between tapping an enabled control and the async body
    /// actually running. Connectivity can leave inside that window, and the
    /// body must refuse rather than send. Same shape as Build 115's
    /// `testRouteIsChosenBeforeAnyConnectedWork`.
    func testTheOnlineActionResolvesConnectivityBeforeItReachesTheNetwork() throws {
        let code = try Self.source("App/CoachView.swift")
        let run = try XCTUnwrap(
            Self.body(after: "private func runCoach() async", in: code),
            "CoachView must declare runCoach()"
        )
        let gate = try XCTUnwrap(
            run.range(of: "connectivity.isOffline"),
            "runCoach must consult the observed connectivity"
        )
        let transport = try XCTUnwrap(
            run.range(of: "TonoBackend.shared"),
            "runCoach must be the surface that reaches the network"
        )
        XCTAssertTrue(
            gate.lowerBound < transport.lowerBound,
            "the connectivity gate must precede every reachable request, not follow one"
        )
    }

    /// Strict on-device-only is a privacy choice, not a connectivity fallback.
    /// Losing the network must not disable it, and it must still send nothing.
    func testOnDeviceOnlyIsNeitherDisabledNorLoosenedByLosingTheNetwork() {
        for offline in [false, true] {
            let route = LocalCoachRoutePolicy.decide(
                requestedAxis: "clearer",
                draft: "hey I really need that report today",
                remoteKillSwitchAllows: true,
                preference: .onlyOnDevice,
                availability: .available,
                saferCorpusGateOpen: false,
                connectivityKnownAbsent: offline
            )
            guard case .local = route else {
                return XCTFail(
                    "on-device-only must stay on device with connectivity absent=\(offline); got \(route)"
                )
            }
        }
    }

    /// The observer is the host app's and nothing else's.
    ///
    /// A keyboard is a memory-capped extension that is created and destroyed
    /// constantly; Build 111 removed the last reachability object from it and
    /// both `Build111CoachReconnectTests` and `Build115LocalCoachTests` pin its
    /// absence. This proves the repair did not smuggle one back in through
    /// `Shared/`, which every extension compiles.
    func testNoExtensionTargetCompilesAConnectivityObserver() throws {
        for directory in ["Shared", "KeyboardExtension", "ShareExtension", "TonoMessagesExtension"] {
            for file in try Self.swiftFiles(under: directory) {
                let text = try String(contentsOf: file, encoding: .utf8)
                for token in ["NWPathMonitor", "SCNetworkReachability", "import Network"] {
                    XCTAssertFalse(
                        text.contains(token),
                        "\(file.lastPathComponent) would put \(token) in every extension binary"
                    )
                }
            }
        }
    }

    /// …and the project agrees: exactly one target compiles it.
    func testTheObserverIsCompiledIntoTheHostAppAlone() throws {
        let project = try Self.source("Tono.xcodeproj/project.pbxproj")
        XCTAssertEqual(
            project.components(separatedBy: "/* TonoConnectivity.swift in Sources */").count - 1,
            2,   // one PBXBuildFile declaration + one membership in one Sources phase
            "TonoConnectivity.swift must belong to exactly one target"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: Self.root().appendingPathComponent("App/TonoConnectivity.swift").path
            ),
            "and that target is the host app, whose sources are App/"
        )
    }

    // MARK: - Source helpers

    private static func root(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
    }

    static func source(_ relative: String) throws -> String {
        try String(contentsOf: root().appendingPathComponent(relative), encoding: .utf8)
    }

    static func swiftFiles(under directory: String) throws -> [URL] {
        let base = root().appendingPathComponent(directory)
        let all = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        return (all?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    /// The brace-balanced block that follows the first occurrence of `needle`.
    static func body(after needle: String, in source: String) -> String? {
        guard let start = source.range(of: needle) else { return nil }
        guard let open = source[start.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { return String(source[open...index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }
}
