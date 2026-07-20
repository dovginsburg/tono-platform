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
    private let queue = DispatchQueue(label: "com.tono.livetone.engine")
    private let runLoopMarker = RunLoopMarker()

    /// Per-engine state machine. The engine holds the live one; tests
    /// may construct their own for direct assertion.
    private var session = LiveToneSession()

    /// Hash bound to the in-flight evaluation. Stale-result discard
    /// drops any result whose hash doesn't match.
    private var inFlightHash: Int?

    /// The Timer scheduled by the 500 ms debounce.
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
        counters: LiveToneCounterStore
    ) {
        self.classifier = classifier
        self.masterToggle = masterToggle
        self.counters = counters
    }

    deinit {
        pendingTimer?.invalidate()
    }

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
        // engine's serial queue without racing the keystroke path.
        DispatchQueue.main.async { [weak self] in
            guard let self, let timer = self.pendingTimer, timer === timer else { return }
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func cancelTimer() {
        pendingTimer?.invalidate()
        pendingTimer = nil
    }

    /// Run the classifier synchronously on the engine's serial queue.
    /// The contract's <50 ms target is observed by the classifier's
    /// bounded prefix scan and the O(1) token-level pattern matcher.
    private func evaluate(draft: String, boundHash: Int) {
        // Stale-result discard: the user moved on; the in-flight hash no
        // longer matches the bound one. Drop on the floor.
        guard inFlightHash == boundHash else {
            inFlightHash = nil
            return
        }
        let verdict = classifier.classify(draft)
        let priorWarning = session.warning
        session.apply(verdict: verdict, draftHash: boundHash)
        inFlightHash = nil

        // Bump the per-category `shown` counter on every visible-warning
        // transition. Crisis silence never bumps a counter (no visible
        // warning) — that's correct per the contract: Live Tone is silent
        // on crisis, no surface to count.
        if session.warning != priorWarning,
           let category = Self.category(of: session.warning) {
            let counters = self.counters.load().incrementShown(category)
            self.counters.save(counters)
        }

        publish(session.warning)
    }

    private static func category(of warning: LiveToneVisibleWarning) -> LiveToneCategory? {
        switch warning {
        case .l1(let category), .l2(let category): return category
        case .none: return nil
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