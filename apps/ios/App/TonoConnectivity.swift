// TonoConnectivity.swift
// Build 116 — what the host app knows about having a route to the internet,
// and how it comes to know it.
//
// ── The defect this exists for ──────────────────────────────────────────────
//
// Coach a draft in the app, get a rewrite, leave it on screen, then turn on
// Airplane Mode. Nothing changed. The Coach control stayed fully enabled and
// looked exactly as available as it had a second earlier; tapping it fired a
// request that could not leave the device, and only when that request came
// back did the app admit there was no connection — and admitting it destroyed
// the rewrite that was on screen, because `runCoach()` cleared the result
// before every attempt.
//
// The cause was not a bug in any one line. The host app had NO connectivity
// input at all. Its entire notion of "are we online" was the outcome of the
// last request it happened to make, so a surface with a delivered result and
// no request in flight had, structurally, no way to learn anything. Detecting
// the change needed another request, a new view, or a relaunch — which is the
// definition of not detecting it.
//
// ── What replaces it ────────────────────────────────────────────────────────
//
// One process-lifetime observer of the system's own path state, started once
// at launch and published as ordinary observable state. Requests are no longer
// the app's connectivity sensor; they are just requests.
//
// ── Why this file is in App/ and not Shared/ ────────────────────────────────
//
// Deliberately host-app only. The keyboard extension must NOT grow one of
// these: Build 111 removed the last reachability object from it, and both
// `Build111CoachReconnectTests` and `Build115LocalCoachTests` pin its absence,
// because a keyboard is a memory-capped extension that is created and
// destroyed constantly and a free-running observer there is a leak with a
// schedule. The extensions keep the answer they already have, and it is a good
// one: `waitsForConnectivity: true` on the transport, which reports "no route"
// from inside the request that needs it, bounded by a resource budget. Share
// and Messages are single-shot sheets whose only online control lives on the
// failure screen, reached only when there is no result to protect.
//
// So: this type is compiled into the app and nothing else, and `Shared/` is
// untouched.

import Foundation
import Network

/// What the app currently knows about reaching the internet.
///
/// `checking` is a real state, not a placeholder for offline: it is the window
/// between the observer starting and its first report. Treating it as offline
/// would put a false "no connection" claim on screen at launch and gate a
/// control that works — so nothing is claimed until something is known.
public enum TonoConnectivityStatus: Equatable {
    /// Started, no report yet.
    case checking
    /// The system reports a satisfied path.
    case online
    /// The system reports no usable path — airplane mode, no Wi-Fi, no cellular.
    case offline
}

/// The stream of path facts a `TonoConnectivity` consumes.
///
/// A protocol so the observer's behaviour — ordering, flapping, lifetime,
/// foreground re-assertion — can be driven exactly rather than waited for. The
/// alternative is a suite that toggles a real radio, which is neither
/// deterministic nor possible in a simulator.
public protocol TonoConnectivityPathSource: AnyObject {
    /// The most recent fact the source holds, or nil before it has one.
    /// Read when the app returns to the foreground.
    var currentlySatisfied: Bool? { get }

    /// Begin reporting. `onReport` may be called on any queue, and is called
    /// once per path update — including the first one, immediately after
    /// starting. Calling `start` more than once must report through the newest
    /// handler only, and must not create a second observer.
    func start(onReport: @escaping (Bool) -> Void)

    /// Stop reporting. Must be safe to call when never started, and more than
    /// once.
    func cancel()
}

/// The shipping source: the system's own path monitor.
public final class NWPathConnectivitySource: TonoConnectivityPathSource {
    private let monitor = NWPathMonitor()
    /// A dedicated serial queue, so path updates arrive in order and never on
    /// the main thread.
    private let queue = DispatchQueue(label: "com.tonoit.app.connectivity")
    private let lock = NSLock()
    private var started = false
    private var cancelled = false

    public init() {}

    public var currentlySatisfied: Bool? {
        guard lock.withLock({ started && !cancelled }) else { return nil }
        return monitor.currentPath.status == .satisfied
    }

    public func start(onReport: @escaping (Bool) -> Void) {
        // The handler is installed inside the same critical section that
        // decides whether to start, so a concurrent `cancel()` cannot be
        // followed by a handler that outlives it.
        let shouldStart: Bool = lock.withLock {
            guard !cancelled else { return false }
            monitor.pathUpdateHandler = { path in onReport(path.status == .satisfied) }
            let was = started
            started = true
            return !was
        }
        guard shouldStart else { return }
        monitor.start(queue: queue)
    }

    public func cancel() {
        let shouldCancel: Bool = lock.withLock {
            guard started, !cancelled else { return false }
            cancelled = true
            return true
        }
        guard shouldCancel else { return }
        monitor.pathUpdateHandler = nil
        monitor.cancel()
    }

    deinit { cancel() }
}

/// The app's connectivity state, observable by SwiftUI.
///
/// `ObservableObject` rather than `@Observable` to match `StoreKitManager`,
/// the other process-lifetime shared model in this app.
public final class TonoConnectivity: ObservableObject {

    /// The process-lifetime instance. Started once, in `TonoApp.init`.
    public static let shared = TonoConnectivity()

    @Published public private(set) var status: TonoConnectivityStatus = .checking

    /// The one question every caller actually asks. Note that `checking` is
    /// NOT offline: an unknown state must never gate a control or make a
    /// claim, so this is false until the system says otherwise.
    public var isOffline: Bool { status == .offline }

    private let source: TonoConnectivityPathSource

    // ── Ordering ────────────────────────────────────────────────────────────
    //
    // Reports are stamped with a monotonic sequence the instant they arrive,
    // BEFORE any queue hop, and applied in sequence order. Two facts make this
    // necessary rather than decorative:
    //
    //   * a report arriving on the main thread is applied synchronously while
    //     an earlier one may still be sitting in the main queue, so without a
    //     stamp the older fact would land last and win;
    //   * the last report of a rapid offline↔online↔offline flap is the true
    //     one, and it is the only one that may survive.
    //
    // The stamp is taken under a lock because reports arrive on the source's
    // queue and `refresh()` is called from the main thread.
    private let lock = NSLock()
    private var issuedSequence: UInt64 = 0
    private var appliedSequence: UInt64 = 0
    private var hasStarted = false

    public init(source: TonoConnectivityPathSource = NWPathConnectivitySource()) {
        self.source = source
    }

    deinit { source.cancel() }

    /// Begin observing. Idempotent: a second call starts nothing new, so a
    /// foreground/background cycle cannot accumulate observers.
    public func start() {
        let alreadyStarted: Bool = lock.withLock {
            let was = hasStarted
            hasStarted = true
            return was
        }
        guard !alreadyStarted else { return }
        // `weak` on purpose: the source outlives nothing, and a strong capture
        // here would make every instance immortal and keep a torn-down
        // observer publishing into a dead object.
        source.start { [weak self] satisfied in
            self?.report(satisfied)
        }
    }

    /// Re-publish the source's current fact.
    ///
    /// Called when the app returns to the foreground. The observer keeps
    /// running while backgrounded, so this is a belt-and-braces re-assertion
    /// rather than the primary path — but it makes the transition deterministic
    /// instead of dependent on whether an update happened to be delivered while
    /// the app was not on screen.
    public func refresh() {
        guard lock.withLock({ hasStarted }) else { return }
        guard let satisfied = source.currentlySatisfied else { return }
        report(satisfied)
    }

    /// Stop observing. The shared instance never needs this; tests and any
    /// future scoped owner do.
    public func stop() {
        lock.withLock { hasStarted = false }
        source.cancel()
    }

    // MARK: - Applying a report

    private func report(_ satisfied: Bool) {
        let sequence: UInt64 = lock.withLock {
            issuedSequence += 1
            return issuedSequence
        }
        if Thread.isMainThread {
            apply(satisfied, sequence: sequence)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.apply(satisfied, sequence: sequence)
            }
        }
    }

    private func apply(_ satisfied: Bool, sequence: UInt64) {
        // A report that was overtaken on its way here is dropped whole. It
        // describes a world that has already been superseded.
        let accepted: Bool = lock.withLock {
            guard sequence > appliedSequence else { return false }
            appliedSequence = sequence
            return true
        }
        guard accepted else { return }
        let resolved: TonoConnectivityStatus = satisfied ? .online : .offline
        // Publishing an unchanged value would wake every observer for nothing;
        // a path monitor reports far more often than the answer changes.
        guard resolved != status else { return }
        status = resolved
    }
}
