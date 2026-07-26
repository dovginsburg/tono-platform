// Build111CoachReconnectTests.swift
// Build 111 — Coach recovers by itself when connectivity returns.
//
// PHYSICAL FINDING (signed TestFlight Build 110, 110f5dff, on device):
//
//     "Also, I turned off internet connection and then turned it back on and
//      I think the Tono coach didn't reconnect automatically to server."
//
// ROOT CAUSE. Build 110 issued Coach requests on `URLSession.shared`. That
// session's configuration has `waitsForConnectivity == false`, which makes an
// absent route a TERMINAL outcome: the task fails immediately with
// `URLError.notConnectedToInternet`, the keyboard installs its error surface,
// and the only way back is the user tapping Retry. Restoring Wi-Fi cannot
// recover anything, because after the failure there is nothing in flight left
// to recover. The first assertion below pins that property of
// `URLSession.shared` directly, so the diagnosis is evidence and not a story.
//
// FIX. A dedicated `URLSessionConfiguration` with `waitsForConnectivity = true`
// and bounded `timeoutIntervalForRequest` / `timeoutIntervalForResource`. The
// ONE task the tap created parks inside URLSession until connectivity returns,
// then proceeds and completes normally. Nothing is re-sent, so the
// 1 tap → 1 `URLSessionDataTask` → 1 server request contract is untouched.
//
// WHAT IS DELIBERATELY *NOT* FIXED. A connection lost MIDFLIGHT, after request
// bytes have gone out, stays a terminal, bounded, actionable error. That POST
// may already have reached the provider; replaying it could bill twice and
// generate a second rewrite. There is no application-level replay anywhere in
// this change, and `testNoApplicationLevelReplayAfterATransportFailure` holds
// that line.
//
// ── HONEST LIMITS OF THESE TESTS ────────────────────────────────────────────
// A `URLProtocol` stub intercepts ABOVE the connectivity machinery, so it
// cannot make URLSession emit a real `taskIsWaitingForConnectivity`, and no
// unit test on this machine can toggle a radio. These tests therefore split
// the claim into parts that are each genuinely provable:
//
//   1. the CONFIGURATION really does wait, within a bounded budget
//      (asserted directly on the policy and its `URLSessionConfiguration`);
//   2. the CLIENT delivers exactly one completion for one task when the
//      transport stalls and later releases the request — the observable shape
//      of "offline, then restored" (asserted through a stalling URLProtocol);
//   3. the WAITING NOTIFICATION plumbing routes, de-duplicates, detaches and
//      re-labels the terminal error correctly (asserted at its own seams);
//   4. the CONTROLLER keeps the surface truthful, extends its deadline, stays
//      bounded, and fails closed for superseded requests.
//
// Nothing here claims physical verification. On-device confirmation is a
// separate, explicitly-listed step.
//
// The URLProtocol stubs are installed ONLY on a configuration this file
// builds — never via `URLProtocol.registerClass`, which is process-global and
// would intercept the XCTest host application's own traffic and measure the
// host rather than this client.

import XCTest
import UIKit
@testable import Tono

// ───────────────────────────────────────────────────────────────────────────
// Deterministic transport doubles
// ───────────────────────────────────────────────────────────────────────────

/// A transport that can park a request indefinitely and release it later —
/// the observable shape of "the device had no route, then it did".
final class CoachStallingURLProtocol: URLProtocol {

    final class Transport {
        private let lock = NSLock()
        private var parked: [ObjectIdentifier: () -> Void] = [:]
        private var startedURLs: [URL] = []
        private var deliveries = 0
        private var online = false
        private var body = Data()

        var startCount: Int { lock.lock(); defer { lock.unlock() }; return startedURLs.count }
        var deliveryCount: Int { lock.lock(); defer { lock.unlock() }; return deliveries }
        var parkedCount: Int { lock.lock(); defer { lock.unlock() }; return parked.count }

        /// Begin a scenario. `online: false` parks every request that arrives.
        func reset(online: Bool, body: Data) {
            lock.lock()
            parked.removeAll()
            startedURLs = []
            deliveries = 0
            self.online = online
            self.body = body
            lock.unlock()
        }

        fileprivate func start(_ proto: URLProtocol, deliver: @escaping (Data) -> Void) {
            lock.lock()
            if let url = proto.request.url { startedURLs.append(url) }
            if !online {
                let payload = body
                parked[ObjectIdentifier(proto)] = { deliver(payload) }
                lock.unlock()
                return
            }
            deliveries += 1
            let payload = body
            lock.unlock()
            deliver(payload)
        }

        /// Cancellation. A request removed here can never be delivered by a
        /// later `restoreConnectivity()`.
        fileprivate func stop(_ proto: URLProtocol) {
            lock.lock()
            parked.removeValue(forKey: ObjectIdentifier(proto))
            lock.unlock()
        }

        /// The moment the user turns Wi-Fi back on.
        func restoreConnectivity() {
            lock.lock()
            online = true
            let waiting = Array(parked.values)
            parked.removeAll()
            deliveries += waiting.count
            lock.unlock()
            waiting.forEach { $0() }
        }
    }

    static let transport = Transport()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.transport.start(self) { [weak self] body in
            guard let self, let url = self.request.url else { return }
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() { Self.transport.stop(self) }
}

/// A transport that fails every request the way an unreachable network does.
/// Models Build 110's terminal behaviour, and the midflight-loss case that
/// Build 111 deliberately still treats as terminal.
final class CoachUnreachableURLProtocol: URLProtocol {
    static let lock = NSLock()
    private static var _attempts = 0
    static var attempts: Int { lock.lock(); defer { lock.unlock() }; return _attempts }
    static func reset() { lock.lock(); _attempts = 0; lock.unlock() }
    /// Which URLError to raise. `.networkConnectionLost` models a connection
    /// dropped after the request went out; `.notConnectedToInternet` models a
    /// tap with the radio already off.
    static var code: URLError.Code = .notConnectedToInternet

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self._attempts += 1; let code = Self.code; Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(code))
    }
    override func stopLoading() {}
}

// ───────────────────────────────────────────────────────────────────────────

final class Build111CoachReconnectTests: XCTestCase {

    private static let endpoint = "https://tono.invalid/api/analyze/variant"

    private static func variantBody(axis: String = "safer", text: String = "a kinder way to say it") -> Data {
        let payload: [String: Any] = ["status": "ok", "axis": axis, "text": text]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    /// A session wired to a stub protocol on ITS OWN configuration, built from
    /// the real shipping transport policy so the timeouts under test are the
    /// shipping ones.
    private func stubSession(
        _ protocolClass: AnyClass,
        policy: CoachTransportPolicy = CoachTransportPolicy()
    ) -> URLSession {
        URLSession(configuration: policy.makeConfiguration(protocolClasses: [protocolClass]))
    }

    /// Wait until the stalling transport has actually parked `count` requests.
    ///
    /// `task.resume()` hands the request to the URL loading system
    /// asynchronously, so asserting on the transport immediately after it
    /// races `startLoading`. Without this the park→release path could be
    /// skipped entirely (restore lands first, the request is delivered
    /// straight away) and the test would still pass — proving nothing.
    private func waitForParkedRequests(_ count: Int, timeout: TimeInterval = 5) {
        let parked = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                CoachStallingURLProtocol.transport.parkedCount == count
            },
            object: nil
        )
        wait(for: [parked], timeout: timeout)
    }

    private func client(session: URLSession) -> TonoCoachClient {
        TonoCoachClient(
            endpoint: Self.endpoint,
            timeout: 15,
            session: session,
            tokenProvider: { "test-token" }
        )
    }

    // MARK: - 1. Root cause and the transport policy that fixes it

    /// The Build-110 defect, stated as a fact about the session it used.
    /// `URLSession.shared` cannot wait for connectivity, so an outage is
    /// terminal and only a manual Retry can recover.
    func testSharedSessionUsedByBuild110CannotWaitForConnectivity() {
        XCTAssertFalse(
            URLSession.shared.configuration.waitsForConnectivity,
            "URLSession.shared cannot wait for connectivity — this is why Build 110 could not recover"
        )
    }

    /// The fix: waiting is on, and it is BOUNDED. An unbounded wait would be
    /// its own defect — a keyboard extension must not hold a task open forever.
    func testCoachTransportPolicyWaitsForConnectivityWithinABoundedBudget() {
        let policy = CoachTransportPolicy()
        XCTAssertTrue(policy.waitsForConnectivity)
        XCTAssertEqual(policy.requestTimeout, 15)
        XCTAssertEqual(policy.resourceTimeout, 30)
        XCTAssertGreaterThan(policy.resourceTimeout, policy.requestTimeout,
                             "the resource budget must be able to outlast one idle request")

        let configuration = policy.makeConfiguration()
        XCTAssertTrue(configuration.waitsForConnectivity)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 15)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 30)
        XCTAssertTrue(configuration.timeoutIntervalForResource.isFinite,
                      "a prolonged outage must still reach a bounded error")
        // Nothing about a draft may be written to the extension's container.
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
    }

    /// A client built the way the keyboard builds one — no injected session —
    /// gets the connectivity-aware transport, not `URLSession.shared`.
    func testClientWithoutAnInjectedSessionUsesTheConnectivityAwareTransport() {
        let subject = TonoCoachClient(endpoint: Self.endpoint, timeout: 15)
        XCTAssertTrue(subject.transport.waitsForConnectivity)
        XCTAssertEqual(subject.transport.requestTimeout, 15)
        XCTAssertTrue(subject.transport.resourceTimeout.isFinite)
        XCTAssertEqual(subject.inFlightConnectivityRegistrations, 0,
                       "a client at rest holds no connectivity registrations")
    }

    /// Test-injected protocol classes must ride on the configuration, never on
    /// the process-global registry — otherwise these tests measure the XCTest
    /// host app's traffic instead of this client's.
    func testStubProtocolsAreScopedToTheirOwnConfiguration() {
        let configuration = CoachTransportPolicy()
            .makeConfiguration(protocolClasses: [CoachStallingURLProtocol.self])
        XCTAssertTrue(
            configuration.protocolClasses?.contains { $0 == CoachStallingURLProtocol.self } == true,
            "the stub must be installed on this configuration"
        )
        XCTAssertFalse(
            URLSessionConfiguration.default.protocolClasses?
                .contains { $0 == CoachStallingURLProtocol.self } == true,
            "the stub must NOT leak into the default configuration"
        )
    }

    // MARK: - 2. Offline → restored, through the real client

    /// The headline behaviour: a request that cannot go out yet is parked, and
    /// when connectivity returns it completes BY ITSELF — no second tap, no
    /// keyboard reload — exactly once.
    func testParkedRequestCompletesExactlyOnceWhenConnectivityReturns() {
        CoachStallingURLProtocol.transport.reset(online: false, body: Self.variantBody())
        let session = stubSession(CoachStallingURLProtocol.self)
        defer { session.invalidateAndCancel() }
        let subject = client(session: session)

        let completed = expectation(description: "the parked request completes on its own")
        let completionCount = Counter()
        var received: TonoCoachClient.VariantResponse?

        let task = subject.variant(draft: "please be kind", axis: "safer") { result in
            completionCount.increment()
            if case .success(let response) = result { received = response }
            completed.fulfill()
        }
        XCTAssertNotNil(task, "an authenticated tap must create exactly one task")

        // Nothing has been delivered: the request is parked in the transport.
        waitForParkedRequests(1)
        XCTAssertEqual(CoachStallingURLProtocol.transport.deliveryCount, 0)
        XCTAssertEqual(completionCount.value, 0, "a parked request must not complete early")

        // The user turns the network back on.
        CoachStallingURLProtocol.transport.restoreConnectivity()
        wait(for: [completed], timeout: 5)

        XCTAssertEqual(received?.text, "a kinder way to say it",
                       "the recovered request must deliver the real answer")
        XCTAssertEqual(completionCount.value, 1, "exactly one completion")

        // And it stays one: no late duplicate arrives afterwards.
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settle.fulfill() }
        wait(for: [settle], timeout: 2)
        XCTAssertEqual(completionCount.value, 1, "recovery must not deliver twice")
    }

    /// The 1 tap → 1 task → 1 request contract survives the wait. Waiting
    /// happens INSIDE the one task; it never creates a second one.
    func testParkedThenRestoredRequestIssuesExactlyOneTaskAndOneRequest() {
        CoachStallingURLProtocol.transport.reset(online: false, body: Self.variantBody())
        let session = stubSession(CoachStallingURLProtocol.self)
        defer { session.invalidateAndCancel() }
        let subject = client(session: session)
        subject.resetProviderCallCount()

        let completed = expectation(description: "completes once")
        _ = subject.variant(draft: "please be kind", axis: "safer") { _ in completed.fulfill() }
        waitForParkedRequests(1)
        XCTAssertEqual(CoachStallingURLProtocol.transport.startCount, 1,
                       "the tap must reach the transport exactly once")

        CoachStallingURLProtocol.transport.restoreConnectivity()
        wait(for: [completed], timeout: 5)

        XCTAssertEqual(CoachStallingURLProtocol.transport.startCount, 1,
                       "recovery must not issue a second request")
        XCTAssertEqual(CoachStallingURLProtocol.transport.deliveryCount, 1)
        XCTAssertEqual(subject.providerCallCount, 1, "exactly one provider call per tap")
        XCTAssertEqual(subject.dispatchedAxes, ["safer"])
    }

    /// Back / cancel / host-session invalidation must be final: the parked
    /// request is torn down and a later restore can never deliver its result.
    func testCancellationPreventsAnyLaterCompletionFromDelivering() {
        CoachStallingURLProtocol.transport.reset(online: false, body: Self.variantBody())
        let session = stubSession(CoachStallingURLProtocol.self)
        defer { session.invalidateAndCancel() }
        let subject = client(session: session)

        let terminated = expectation(description: "the cancelled task reports a terminal outcome")
        let successes = Counter()
        let completions = Counter()

        let task = subject.variant(draft: "cancel me", axis: "safer") { result in
            completions.increment()
            if case .success = result { successes.increment() }
            terminated.fulfill()
        }
        XCTAssertNotNil(task)
        waitForParkedRequests(1)

        task?.cancel()
        wait(for: [terminated], timeout: 5)

        XCTAssertEqual(CoachStallingURLProtocol.transport.parkedCount, 0,
                       "cancellation must remove the parked request from the transport")

        // Connectivity returns AFTER the cancel. Nothing may be delivered.
        CoachStallingURLProtocol.transport.restoreConnectivity()
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        wait(for: [settle], timeout: 2)

        XCTAssertEqual(successes.value, 0, "a cancelled request must never deliver a result")
        XCTAssertEqual(completions.value, 1, "cancellation is one terminal outcome, not two")
        XCTAssertEqual(CoachStallingURLProtocol.transport.deliveryCount, 0,
                       "a cancelled request must not be released by a later restore")
        XCTAssertEqual(subject.inFlightConnectivityRegistrations, 0,
                       "cancellation must drop the connectivity registration")
    }

    /// Terminal failure clears every in-flight gate — nothing is left holding
    /// state that a later request could inherit.
    func testTerminalOfflineFailureIsTruthfulAndClearsInFlightState() {
        CoachUnreachableURLProtocol.reset()
        CoachUnreachableURLProtocol.code = .notConnectedToInternet
        let session = stubSession(CoachUnreachableURLProtocol.self)
        defer { session.invalidateAndCancel() }
        let subject = client(session: session)

        let failed = expectation(description: "terminal offline failure")
        var error: TonoCoachClient.CoachError?
        _ = subject.variant(draft: "no route", axis: "safer") { result in
            if case .failure(let e) = result { error = e }
            failed.fulfill()
        }
        wait(for: [failed], timeout: 5)

        XCTAssertEqual(error, .offline, "a routeless request must say so, not emit a raw URLError string")
        XCTAssertEqual(error?.userFacingMessage, LocalIntelligenceCopy.coachRequiresInternet)
        XCTAssertEqual(subject.inFlightConnectivityRegistrations, 0,
                       "a terminal failure must drop its connectivity registration")
    }

    /// The line this change must not cross. A connection lost midflight is
    /// ambiguous — the POST may already have reached the provider — so it
    /// fails once, truthfully, and is NOT replayed.
    func testNoApplicationLevelReplayAfterATransportFailure() {
        CoachUnreachableURLProtocol.reset()
        CoachUnreachableURLProtocol.code = .networkConnectionLost
        let session = stubSession(CoachUnreachableURLProtocol.self)
        defer { session.invalidateAndCancel() }
        let subject = client(session: session)
        subject.resetProviderCallCount()

        let failed = expectation(description: "midflight loss fails once")
        var error: TonoCoachClient.CoachError?
        _ = subject.variant(draft: "half sent", axis: "safer") { result in
            if case .failure(let e) = result { error = e }
            failed.fulfill()
        }
        wait(for: [failed], timeout: 5)

        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        wait(for: [settle], timeout: 2)

        XCTAssertEqual(error, .offline, "a lost connection is an honest offline state")
        XCTAssertEqual(CoachUnreachableURLProtocol.attempts, 1,
                       "an ambiguous midflight failure must NEVER be replayed — that could bill twice")
        XCTAssertEqual(subject.providerCallCount, 1, "one tap, one provider call, no retry")
    }

    /// A successful request when the network is already up is unchanged — the
    /// new transport must not alter the ordinary path.
    func testConnectedRequestStillCompletesNormally() {
        CoachStallingURLProtocol.transport.reset(online: true, body: Self.variantBody(axis: "clearer", text: "clearer wording"))
        let session = stubSession(CoachStallingURLProtocol.self)
        defer { session.invalidateAndCancel() }
        let subject = client(session: session)

        let done = expectation(description: "completes")
        var response: TonoCoachClient.VariantResponse?
        _ = subject.variant(draft: "make it clear", axis: "clearer") { result in
            if case .success(let r) = result { response = r }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(response?.axis, "clearer")
        XCTAssertEqual(response?.text, "clearer wording")
        XCTAssertEqual(subject.inFlightConnectivityRegistrations, 0)
    }

    // MARK: - 3. The waiting-notification plumbing, at its own seams

    /// URLSession may report waiting repeatedly for one task. The caller is
    /// notified at most once, and on the main queue, so a UI update is safe.
    func testTransportStateNotifiesAtMostOnceOnTheMainQueue() {
        let notified = expectation(description: "notified once")
        let count = Counter()
        let onMain = Counter()
        let state = CoachRequestTransportState(notify: {
            count.increment()
            if Thread.isMainThread { onMain.increment() }
            notified.fulfill()
        })

        XCTAssertFalse(state.didWaitForConnectivity)
        DispatchQueue.global().async {
            state.markWaitingForConnectivity()
            state.markWaitingForConnectivity()
            state.markWaitingForConnectivity()
        }
        wait(for: [notified], timeout: 3)

        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settle.fulfill() }
        wait(for: [settle], timeout: 2)

        XCTAssertEqual(count.value, 1, "repeated transport reports must notify once")
        XCTAssertEqual(onMain.value, 1, "the notification must arrive on the main queue")
        XCTAssertTrue(state.didWaitForConnectivity, "the fact is still recorded for error mapping")
    }

    /// Once a request is over, a late waiting report must not reach the caller.
    func testTransportStateStopsNotifyingAfterFinish() {
        let count = Counter()
        let state = CoachRequestTransportState(notify: { count.increment() })
        state.finish()
        state.markWaitingForConnectivity()

        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settle.fulfill() }
        wait(for: [settle], timeout: 2)

        XCTAssertEqual(count.value, 0, "a finished request must never be notified")
        XCTAssertTrue(state.didWaitForConnectivity)
    }

    /// The session delegate routes a waiting report to the request that owns
    /// that task, and to no other — and its table empties on detach, which is
    /// what keeps this from being an unbounded observer.
    func testSessionDelegateRoutesWaitingOnlyToItsOwnTaskAndDetachesCleanly() {
        let session = stubSession(CoachStallingURLProtocol.self)
        defer { session.invalidateAndCancel() }
        let delegate = CoachConnectivitySessionDelegate()
        XCTAssertEqual(delegate.registrationCount, 0)

        // Two distinct tasks, never resumed: `taskIdentifier` is assigned at
        // creation, which is all the routing depends on.
        let taskA = session.dataTask(with: URL(string: Self.endpoint)!)
        let taskB = session.dataTask(with: URL(string: Self.endpoint)!)
        XCTAssertNotEqual(taskA.taskIdentifier, taskB.taskIdentifier)

        let hitA = Counter(), hitB = Counter()
        let stateA = CoachRequestTransportState(notify: { hitA.increment() })
        let stateB = CoachRequestTransportState(notify: { hitB.increment() })
        delegate.attach(stateA, to: taskA)
        delegate.attach(stateB, to: taskB)
        XCTAssertEqual(delegate.registrationCount, 2)

        delegate.urlSession(session, taskIsWaitingForConnectivity: taskA)

        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settle.fulfill() }
        wait(for: [settle], timeout: 2)

        XCTAssertEqual(hitA.value, 1, "task A's owner is notified")
        XCTAssertEqual(hitB.value, 0, "task B's owner is not")
        XCTAssertTrue(stateA.didWaitForConnectivity)
        XCTAssertFalse(stateB.didWaitForConnectivity)

        delegate.detach(stateA)
        delegate.detach(stateB)
        XCTAssertEqual(delegate.registrationCount, 0,
                       "every registration is dropped — nothing accumulates over the extension's life")

        // A report after detach reaches nobody.
        delegate.urlSession(session, taskIsWaitingForConnectivity: taskA)
        let settle2 = expectation(description: "settle 2")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settle2.fulfill() }
        wait(for: [settle2], timeout: 2)
        XCTAssertEqual(hitA.value, 1)
    }

    /// The bounded-error mapping. When a task spends its whole life parked
    /// waiting for a connection that never comes, URLSession reports
    /// `.timedOut` — but "the request timed out" would be false, because no
    /// request was ever sent. The waiting fact is what makes the error honest.
    func testTimedOutAfterWaitingIsReportedAsOfflineNotTimeout() {
        XCTAssertEqual(
            TonoCoachClient.mapped(URLError(.timedOut), didWaitForConnectivity: true), .offline,
            "a request that never got a connection is offline, not timed out"
        )
        XCTAssertEqual(
            TonoCoachClient.mapped(URLError(.timedOut), didWaitForConnectivity: false), .timeout,
            "a connected request that ran out of time really did time out"
        )
        XCTAssertEqual(
            TonoCoachClient.mapped(URLError(.notConnectedToInternet), didWaitForConnectivity: false), .offline
        )
        XCTAssertEqual(
            TonoCoachClient.mapped(URLError(.networkConnectionLost), didWaitForConnectivity: false), .offline
        )
        // Both terminal states are bounded and actionable.
        XCTAssertFalse(TonoCoachClient.CoachError.offline.userFacingMessage.isEmpty)
        XCTAssertTrue(TonoCoachClient.CoachError.timeout.userFacingMessage.contains("Retry"))
    }

    // MARK: - 4. Controller: truthful surface, extended but bounded deadline

    /// While the transport waits, the surface must stay result-shaped (the
    /// request really is still coming) AND stop implying progress. Busy stays
    /// latched, because the one request is still in flight.
    @MainActor
    func testWaitingKeepsTheResultShapedSurfaceAndStatesTheTruth() throws {
        let controller = Self.makeController()
        controller.runCoach(draft: "waiting for the network", axis: "safer")
        controller.view.layoutIfNeeded()
        let request = try XCTUnwrap(controller.activeCoachRequestIDForTesting)

        let skeleton = try XCTUnwrap(Self.skeleton(in: controller))
        XCTAssertFalse(skeleton.isShowingWaitingForConnection)

        controller.handleCoachWaitingForConnectivity(
            requestID: request, tapTime: .now(), axis: "safer"
        )
        controller.view.layoutIfNeeded()

        XCTAssertTrue(controller.coachIsWaitingForConnectivityForTesting)
        XCTAssertEqual(Self.surfaceIdentifiers(in: controller), ["TonoKB.coachLoading"],
                       "waiting must NOT replace the loading surface with an error")
        XCTAssertTrue(skeleton.isShowingWaitingForConnection)
        let caption = try XCTUnwrap(
            Self.view(TonoCoachSkeletonView.waitingIdentifier, in: controller.view) as? UILabel
        )
        XCTAssertFalse(caption.isHidden)
        XCTAssertEqual(caption.text, LocalIntelligenceCopy.coachWaitingForConnection)
        XCTAssertTrue(controller.coachIsBusyForTesting,
                      "the one request is still in flight, so Coach stays busy")
        // Still result-shaped: the rewrite card placeholder survives.
        XCTAssertNotNil(skeleton.card.superview)
    }

    /// Repeated waiting reports for the same request change nothing.
    @MainActor
    func testWaitingIsIdempotent() throws {
        let controller = Self.makeController()
        controller.runCoach(draft: "idempotent", axis: "safer")
        controller.view.layoutIfNeeded()
        let request = try XCTUnwrap(controller.activeCoachRequestIDForTesting)

        for _ in 0..<5 {
            controller.handleCoachWaitingForConnectivity(
                requestID: request, tapTime: .now(), axis: "safer"
            )
        }
        controller.view.layoutIfNeeded()
        XCTAssertEqual(Self.surfaceIdentifiers(in: controller), ["TonoKB.coachLoading"])
        XCTAssertTrue(controller.coachIsWaitingForConnectivityForTesting)
        XCTAssertEqual(
            Self.descendants(of: controller.view).compactMap { $0 as? TonoCoachSkeletonView }.count, 1,
            "waiting must not install a second surface"
        )
    }

    /// A waiting report for a SUPERSEDED request must not touch the newer
    /// request's surface — the same fail-closed gate a completion passes.
    @MainActor
    func testWaitingForASupersededRequestIsIgnored() throws {
        let controller = Self.makeController()
        controller.runCoach(draft: "first", axis: "safer")
        controller.view.layoutIfNeeded()
        let stale = try XCTUnwrap(controller.activeCoachRequestIDForTesting)

        controller.runCoach(draft: "second", axis: "clearer")
        controller.view.layoutIfNeeded()
        let live = try XCTUnwrap(controller.activeCoachRequestIDForTesting)
        XCTAssertNotEqual(stale, live)

        controller.handleCoachWaitingForConnectivity(
            requestID: stale, tapTime: .now(), axis: "safer"
        )
        controller.view.layoutIfNeeded()

        XCTAssertFalse(
            controller.coachIsWaitingForConnectivityForTesting,
            "a superseded request must not mark the live request as waiting"
        )
        let skeleton = try XCTUnwrap(Self.skeleton(in: controller))
        XCTAssertFalse(skeleton.isShowingWaitingForConnection,
                       "a stale notification must not caption the live surface")
    }

    /// A prolonged outage still reaches a bounded, actionable error — and it
    /// says the true thing, because the request never got a connection.
    @MainActor
    func testDeadlineAfterWaitingSurfacesOfflineAndClearsEveryGate() throws {
        let controller = Self.makeController()
        controller.runCoach(draft: "prolonged outage", axis: "safer")
        controller.view.layoutIfNeeded()
        let request = try XCTUnwrap(controller.activeCoachRequestIDForTesting)

        controller.handleCoachWaitingForConnectivity(
            requestID: request, tapTime: .now(), axis: "safer"
        )
        controller.handleCoachDeadlineFired(requestID: request, tapTime: .now(), axis: "safer")
        controller.view.layoutIfNeeded()

        XCTAssertEqual(Self.surfaceIdentifiers(in: controller), ["TonoKB.coachError"])
        let detail = try XCTUnwrap(
            Self.view("TonoKB.coachErrorDetail", in: controller.view) as? UILabel
        )
        XCTAssertEqual(detail.text, LocalIntelligenceCopy.coachRequiresInternet,
                       "a request that never got a connection must not claim it timed out")
        XCTAssertNotNil(Self.view("TonoKB.coachRetry", in: controller.view),
                        "a bounded failure must stay actionable")
        XCTAssertFalse(controller.coachIsBusyForTesting, "the busy gate must clear")
        XCTAssertNil(controller.activeCoachRequestIDForTesting)
        XCTAssertFalse(controller.coachIsWaitingForConnectivityForTesting,
                       "the waiting flag must not leak into the next request")
    }

    /// Regression guard for the other half of the mapping: a request that
    /// never waited still surfaces the truthful TIMEOUT on deadline.
    @MainActor
    func testDeadlineWithoutWaitingStillSurfacesTimeout() throws {
        let controller = Self.makeController()
        controller.runCoach(draft: "slow server", axis: "safer")
        controller.view.layoutIfNeeded()
        let request = try XCTUnwrap(controller.activeCoachRequestIDForTesting)

        controller.handleCoachDeadlineFired(requestID: request, tapTime: .now(), axis: "safer")
        controller.view.layoutIfNeeded()

        let detail = try XCTUnwrap(
            Self.view("TonoKB.coachErrorDetail", in: controller.view) as? UILabel
        )
        XCTAssertTrue(detail.text?.lowercased().contains("timed out") == true,
                      "a connected request that ran out of time really did time out")
        XCTAssertFalse(controller.coachIsBusyForTesting)
    }

    /// Back / host-session invalidation cancels immediately and clears the
    /// waiting state, so nothing can reconnect or retry afterwards.
    @MainActor
    func testInvalidatingTheSessionClearsWaitingAndCannotRecoverAfterwards() throws {
        let controller = Self.makeController()
        controller.runCoach(draft: "then go back", axis: "safer")
        controller.view.layoutIfNeeded()
        let request = try XCTUnwrap(controller.activeCoachRequestIDForTesting)
        controller.handleCoachWaitingForConnectivity(
            requestID: request, tapTime: .now(), axis: "safer"
        )
        XCTAssertTrue(controller.coachIsWaitingForConnectivityForTesting)

        // The user taps Back: the same teardown a host-session change performs.
        controller.viewWillDisappear(false)

        XCTAssertFalse(controller.coachIsWaitingForConnectivityForTesting,
                       "teardown must clear the waiting state")
        XCTAssertNil(controller.activeCoachRequestIDForTesting)
        XCTAssertFalse(controller.coachIsBusyForTesting)

        // A late notification for the torn-down request reaches nothing.
        controller.handleCoachWaitingForConnectivity(
            requestID: request, tapTime: .now(), axis: "safer"
        )
        XCTAssertFalse(controller.coachIsWaitingForConnectivityForTesting,
                       "a cancelled request must never reconnect or retry")
    }

    // MARK: - 5. Source contract — no singleton, no unbounded observer, no replay

    /// The keyboard extension must not grow a global reachability object or a
    /// free-running timer/observer. `Const` is private, so the bounded-deadline
    /// relationship is pinned at the source level, the same way this repo
    /// already pins the deleted Coach spinner.
    func testKeyboardHasNoReachabilitySingletonAndKeepsTheWaitBounded() throws {
        let source = try Self.keyboardControllerSource()
        let code = Self.strippingComments(source)

        for forbidden in ["NWPathMonitor", "SCNetworkReachability", "Reachability(",
                          "Timer.scheduledTimer", "CFRunLoopTimer"] {
            XCTAssertFalse(
                code.contains(forbidden),
                "\(forbidden) would be a global/unbounded observer in a keyboard extension"
            )
        }
        XCTAssertTrue(code.contains("waitsForConnectivity: true"),
                      "the keyboard must wire the connectivity-aware transport")
        XCTAssertTrue(code.contains("resourceTimeout: Const.coachResourceTimeout"),
                      "the connectivity wait must be bounded by a resource budget")
        // The bounded relationship: visible deadline < resource budget <
        // offline visible deadline, so the transport's truthful error lands
        // first and the watchdog remains a backstop.
        let visible = try Self.constant("coachVisibleDeadline", in: source)
        let resource = try Self.constant("coachResourceTimeout", in: source)
        let offline = try Self.constant("coachOfflineVisibleDeadline", in: source)
        XCTAssertLessThan(visible, resource, "the connected deadline must be the shortest")
        XCTAssertLessThan(resource, offline, "the transport must fail before the watchdog fires")
        XCTAssertLessThanOrEqual(offline, 60, "a keyboard must not wait a minute for a rewrite")
    }

    /// The client must contain no application-level replay: waiting happens in
    /// the transport, and one call to `variant` resumes exactly one task.
    func testCoachClientContainsNoApplicationLevelReplay() throws {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("KeyboardExtension/TonoCoachClient.swift"),
            encoding: .utf8
        )
        let code = Self.strippingComments(source)
        XCTAssertEqual(
            code.components(separatedBy: "task.resume()").count - 1, 2,
            "exactly two resume sites — one in coach(), one in variant() — and no retry loop"
        )
        for forbidden in ["for attempt in", "while retries", "retryCount", "recursiveRetry"] {
            XCTAssertFalse(code.contains(forbidden), "no replay construct may exist: \(forbidden)")
        }
    }

    // MARK: - Helpers

    /// A tiny thread-safe counter — the completion handlers under test run on
    /// a background delegate queue.
    final class Counter {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func increment() { lock.lock(); count += 1; lock.unlock() }
    }

    @MainActor
    private static func makeController(width: CGFloat = 390) -> KeyboardViewController {
        let controller = KeyboardViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 320)
        controller.view.layoutIfNeeded()
        return controller
    }

    private static func descendants(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private static func view(_ identifier: String, in root: UIView) -> UIView? {
        descendants(of: root).first { $0.accessibilityIdentifier == identifier }
    }

    @MainActor
    private static func skeleton(in controller: KeyboardViewController) -> TonoCoachSkeletonView? {
        controller.coachSkeletonForTesting
    }

    @MainActor
    private static func surfaceIdentifiers(in controller: KeyboardViewController) -> [String] {
        let surfaces: Set<String> = ["TonoKB.coachLoading", "TonoKB.coachResults", "TonoKB.coachError"]
        return descendants(of: controller.view)
            .compactMap { $0.accessibilityIdentifier }
            .filter { surfaces.contains($0) }
    }

    private static func keyboardControllerSource() throws -> String {
        let here = URL(fileURLWithPath: #filePath)          // apps/ios/Tests/…
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("KeyboardExtension/KeyboardViewController.swift"),
            encoding: .utf8
        )
    }

    /// Strip line comments so a doc comment that DESCRIBES a forbidden symbol
    /// is not mistaken for the symbol being used.
    private static func strippingComments(_ source: String) -> String {
        source
            .components(separatedBy: .newlines)
            .map { line -> String in
                guard let range = line.range(of: "//") else { return line }
                return String(line[..<range.lowerBound])
            }
            .joined(separator: "\n")
    }

    /// Read `static let <name>: TimeInterval = <value>` out of the source.
    private static func constant(_ name: String, in source: String) throws -> Double {
        for line in source.components(separatedBy: .newlines) where line.contains("let \(name)") {
            guard let equals = line.range(of: "=") else { continue }
            let raw = line[equals.upperBound...].trimmingCharacters(in: .whitespaces)
            if let value = Double(raw) { return value }
        }
        throw XCTSkip("constant \(name) not found")
    }
}
