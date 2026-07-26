// LiveToneEngine.swift
// Tono Live Tone v1 — shipping release engine.
//
// Owns the wiring between the master toggle, the classifier, the
// counter store, and the session machine. The engine drives the
// keyboard integration:
//
//   * 500 ms typing-idle debounce OR sentence-ending punctuation
//     immediate flush (whichever fires first).
//   * Master toggle gate — OFF means zero evaluation, classifier not
//     invoked.
//   * Stale-result discard — every result is bound to the draft hash
//     recorded at submission; if the draft changes during evaluation,
//     the result is dropped on the floor.
//   * Clear within one second — when the offending span is gone, the
//     next evaluation clears the warning on the main queue.
//
// The keystroke path is untouched — this engine is a pure observer
// running on its own dispatch queue and observing the engine's own
// state, never the host document. UIKit / Timer are required for the
// debounce mechanism the contract specifies; the static source guards
// in `LiveToneV1AcceptanceTests` forbid networking / pasteboard /
// document mutation.

import UIKit
import Foundation

public final class LiveToneEngine {

    // MARK: - Configuration

    /// Spec-exact per the binding contract. 500 ms typing-idle window.
    public static let debounceInterval: TimeInterval = 0.500

    /// Sentence terminators that flush the debounce immediately.
    private static let sentenceTerminators: Set<Character> = [
        ".", "!", "?", "\n", "\u{2026}"
    ]

    // MARK: - Owned state

    public let masterToggle: LiveToneMasterToggle
    private let classifier: LiveToneClassifier
    private let counters: LiveToneCounterStore

    /// Optional opportunity classifier. When present and the red lane is
    /// silent (no L1/L2 warning), the engine consults this classifier and
    /// surfaces the verdict through the same warning pipeline. When
    /// `nil`, the engine behaves exactly as it did before — the
    /// opportunity lane is wired but inert, never consulted.
    private let opportunityClassifier: LiveToneOpportunityClassifier?

    /// Optional session store for the opportunity lane's one-fire /
    /// dismissal discipline. When `nil`, opportunity verdicts still
    /// surface but per-family dismissal / same-sentence-refire logic
    /// is bypassed (used only by tests). Marked `var` so the engine's
    /// serial queue can mutate the canonical session machine when the
    /// user dismisses an amber chip — a `let` here is the build-97
    /// "dismiss(_:) compile error" the recovery body calls out.
    private var opportunitySession: LiveToneOpportunitySession?

    /// Optional counter store for the opportunity lane. Bumps the
    /// per-family `shown` counter on every visible transition. When
    /// `nil`, counter bumps are silently dropped.
    private let opportunityCounters: LiveToneOpportunityCounterStore?

    private let queue = DispatchQueue(label: "com.tono.livetone.engine")
    private let runLoopMarker = RunLoopMarker()

    /// Per-engine state machine. The engine holds the live one; tests
    /// may construct their own for direct assertion.
    private var session = LiveToneSession()

    /// Hash bound to the in-flight evaluation. Stale-result discard
    /// drops any result whose hash doesn't match.
    private var inFlightHash: Int?

    /// The Timer scheduled by the 500 ms debounce.
    ///
    /// Confined to `queue`: it is only ever read or written from the engine's
    /// serial queue. The timer *instance* is installed on the main run loop,
    /// so every `add`/`invalidate` is handed to the main queue with the
    /// instance captured directly — reading this property from the main queue
    /// races the serial queue's writes and over-releases the underlying
    /// `CFRunLoopTimer` (build 112 `Test crashed with signal trap`).
    private var pendingTimer: Timer?

    // MARK: - Public observers

    /// Invoked on the main queue whenever the visible warning changes.
    /// The integration lane surfaces the result on the keyboard's
    /// passive indicator.
    public var onWarningChange: ((LiveToneVisibleWarning) -> Void)?

    /// Visible warning accessor — primarily for tests and debug.
    public var currentWarning: LiveToneVisibleWarning {
        queue.sync { session.warning }
    }

    // MARK: - Init

    public init(
        classifier: LiveToneClassifier,
        masterToggle: LiveToneMasterToggle,
        counters: LiveToneCounterStore,
        opportunityClassifier: LiveToneOpportunityClassifier? = nil,
        opportunitySession: LiveToneOpportunitySession? = nil,
        opportunityCounters: LiveToneOpportunityCounterStore? = nil
    ) {
        self.classifier = classifier
        self.masterToggle = masterToggle
        self.counters = counters
        self.opportunityClassifier = opportunityClassifier
        self.opportunitySession = opportunitySession
        self.opportunityCounters = opportunityCounters
    }

    // No `deinit` teardown: `pendingTimer` is serial-queue state and its timer
    // is installed on the main run loop, so neither may be touched from the
    // arbitrary thread that drops the last reference. The debounce body holds
    // the engine weakly, so a still-pending timer fires once into nothing and
    // the non-repeating timer then removes itself from the run loop.

    // MARK: - Public API

    /// Observe a text commit. The engine schedules a debounced evaluation
    /// (500 ms typing idle) or flushes immediately if `committedCharacter`
    /// is a sentence terminator. When the master toggle is OFF, the
    /// classifier is never invoked — zero evaluation runs.
    public func textDidCommit(draft: String, committedCharacter: Character?) {
        queue.async { [weak self] in
            guard let self else { return }
            // OFF means zero evaluation runs. The classifier is not invoked.
            guard self.masterToggle.evaluateNow() else { return }

            let hash = Self.draftHash(draft)
            self.inFlightHash = hash

            if let character = committedCharacter,
               Self.sentenceTerminators.contains(character) {
                self.cancelTimer()
                self.evaluate(draft: draft, boundHash: hash)
            } else {
                self.scheduleTimer(draft: draft, boundHash: hash)
            }
        }
    }

    /// The user dismissed the current indicator. Drives the session
    /// machine's per-category suppression and records the local counter.
    public func userTappedDismiss() {
        queue.async { [weak self] in
            guard let self else { return }
            let category = Self.category(of: self.session.warning)
            self.session.dismissCurrent()
            if let category = category {
                let counters = self.counters.load().incrementDismissed(category)
                self.counters.save(counters)
            }
            self.publish(self.session.warning)
        }
    }

    /// The user dismissed the currently-shown opportunity nudge.
    /// Suppresses that family for the remainder of the host-app
    /// session and clears the visible chip. The dismissal must run on
    /// the engine's serial queue because `opportunitySession` is
    /// mutated inside `evaluate(draft:)` — managers that mutate their
    /// own copy would diverge silently (see the build-97 shipping-path
    /// session-discipline regression).
    public func userDismissedOpportunity(_ family: LiveToneOpportunityFamily) {
        queue.async { [weak self] in
            guard let self else { return }
            self.opportunitySession?.dismiss(family)
            // Only clear the visible chip if the chip was actually
            // showing the dismissed family — a stale dismissal
            // (race against a draft change) must not blank a fresh chip.
            if case .opportunity(let visible) = self.session.warning,
               visible == family {
                self.session.dismissCurrent()
                self.publish(.none)
            }
        }
    }

    /// New text field / editing session began. Clears per-draft
    /// suppression and any pending evaluation.
    public func fieldDidReset() {
        queue.async { [weak self] in
            guard let self else { return }
            self.cancelTimer()
            self.session.fieldReset()
            self.inFlightHash = nil
            self.publish(.none)
        }
    }

    // MARK: - Stale-result discard hash

    /// Stable hash of the visible draft used to bind each evaluation
    /// result. Bounded to `LiveToneClassifier.maxScannedCharacters` so
    /// the hash is cheap to compute.
    public static func draftHash(_ draft: String) -> Int {
        var hasher = Hasher()
        hasher.combine(draft)
        return hasher.finalize()
    }

    // MARK: - Internals

    private func scheduleTimer(draft: String, boundHash: Int) {
        cancelTimer()
        let timer = Timer(timeInterval: Self.debounceInterval, repeats: false) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self else { return }
                // Drop the result if the user moved on during the timer.
                guard self.inFlightHash == boundHash else { return }
                self.evaluate(draft: draft, boundHash: boundHash)
            }
        }
        pendingTimer = timer
        // Schedule on the main run loop so the timer survives the
        // engine's serial queue without racing the keystroke path. The
        // instance is captured, never re-read from `pendingTimer`: the main
        // queue reading that serial-queue property raced `cancelTimer()` and
        // over-released the CFRunLoopTimer, and the re-read could hand the
        // run loop the *successor* timer twice.
        DispatchQueue.main.async {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func cancelTimer() {
        guard let timer = pendingTimer else { return }
        pendingTimer = nil
        // A Timer must be invalidated on the run loop it was added to. Both
        // hops are enqueued from this serial queue, and the main queue is
        // FIFO, so a timer is always added before it is invalidated.
        DispatchQueue.main.async {
            timer.invalidate()
        }
    }

    /// Run the classifier synchronously on the engine's serial queue.
    /// The contract's <50 ms target is observed by the classifier's
    /// bounded prefix scan and the O(1) token-level pattern matcher.
    ///
    /// When the red lane is silent (no L1/L2 warning and not a
    /// crisis-silence verdict), the engine consults the opportunity
    /// classifier on the same draft and lets the session machine
    /// decide whether to surface an amber chip. The opportunity lane
    /// is a pure observer: never mutates the keystroke path, never
    /// opens the rewrite flow, never blocks the user.
    private func evaluate(draft: String, boundHash: Int) {
        // Stale-result discard: the user moved on; the in-flight hash no
        // longer matches the bound one. Drop on the floor.
        guard inFlightHash == boundHash else {
            inFlightHash = nil
            return
        }
        let verdict = classifier.classify(draft)
        let priorWarning = session.warning

        // Opportunity verdict: consulted only when the red lane is
        // silent. The session machine enforces strict precedence
        // (crisis > red > opportunity > silent), so a passing red
        // verdict here will discard the opportunity verdict entirely.
        // The per-host-app-session discipline (one fire per family,
        // dismissal suppresses, same-sentence re-fire only on a new
        // distinct signal) is enforced by the session machine, NOT by
        // the classifier — the engine just forwards the verdict.
        let opportunityVerdict: LiveToneOpportunityVerdict? = {
            guard let opportunityClassifier else { return nil }
            // Skip opportunity under crisis-silence (Mira GO) and
            // under any visible red warning (red lane wins).
            if verdict.category == .crisis { return nil }
            if verdict.isVisible { return nil }
            return opportunityClassifier.classify(draft)
        }()

        // Gate the verdict through the per-family session machine so the
        // opportunity lane's one-fire / dismissal / same-sentence-refire
        // discipline is observed before any visible surface is published.
        let gatedOpportunityVerdict: LiveToneOpportunityVerdict? = {
            guard let opportunityVerdict else { return nil }
            guard var opportunitySession else { return opportunityVerdict }
            // The session machine records the fire on accept; a returned
            // `nil` means "stay silent" (dismissed, already fired, or no
            // new distinct signal on a same-sentence retry).
            guard let surfaced = opportunitySession.consider(opportunityVerdict) else {
                return nil
            }
            return LiveToneOpportunityVerdict(
                family: surfaced,
                signals: opportunityVerdict.signals,
                sentenceSignature: opportunityVerdict.sentenceSignature
            )
        }()

        session.apply(
            verdict: verdict,
            opportunity: gatedOpportunityVerdict,
            draftHash: boundHash
        )
        inFlightHash = nil

        // Bump the per-category `shown` counter on every visible-warning
        // transition. Crisis silence never bumps a counter (no visible
        // warning) — that's correct per the contract: Live Tone is silent
        // on crisis, no surface to count.
        if session.warning != priorWarning {
            if let category = Self.category(of: session.warning) {
                let counters = self.counters.load().incrementShown(category)
                self.counters.save(counters)
            }
            if case .opportunity(let family) = session.warning,
               let opportunityCounters {
                let store = opportunityCounters.load().incrementShown(family: family)
                opportunityCounters.save(store)
            }
        }

        publish(session.warning)
    }

    private static func category(of warning: LiveToneVisibleWarning) -> LiveToneCategory? {
        switch warning {
        case .l1(let category), .l2(let category): return category
        case .none, .opportunity: return nil
        }
    }

    private func publish(_ warning: LiveToneVisibleWarning) {
        let snapshot = warning
        DispatchQueue.main.async { [weak self] in
            self?.onWarningChange?(snapshot)
        }
    }
}

/// A no-op run loop marker so the file compiles when no timer is
/// pending. `Timer` itself is the timer; this keeps the file's public
/// surface predictable without leaking internals.
private final class RunLoopMarker {}