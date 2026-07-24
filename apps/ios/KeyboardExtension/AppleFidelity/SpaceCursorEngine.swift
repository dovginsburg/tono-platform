// SpaceCursorEngine.swift
// Apple-fidelity space-key hold/drag cursor mode.
//
// Apple's space bar doubles as a trackpad:
//   * A quick tap inserts exactly one space.
//   * Holding the space bar past a short delay turns the whole keyboard
//     into a caret trackpad; the tap that would have been a space is
//     swallowed (zero spaces inserted).
//   * While in trackpad mode, horizontal finger travel moves the insertion
//     point left/right. Vertical travel is ignored. The caret snaps one
//     character at a time, so a partial-character drag accumulates until it
//     crosses the per-character threshold. The caret can never scrub past
//     the text available on either side of the starting position.
//
// This is a pure value type — exactly like `BackspaceRepeatEngine`, it runs
// no timers and touches no UIKit. The host view controller feeds it touch
// phases plus the wall-clock time (`press`/`tick`/`drag`/`end`/`cancel`) and
// applies the returned `Effect`s to the `UITextDocumentProxy`. Because the
// whole session is modelled here, every behaviour (tap vs. hold, left/right,
// sub-character accumulation, context bounds, vertical-jitter tolerance,
// no post-takeover space, clean teardown) is deterministically unit-testable
// with a fixed base `Date` advanced by `addingTimeInterval` — no sleeps.

import Foundation

/// Tunable geometry / timing for `SpaceCursorEngine`. Defaults approximate
/// Apple's iOS space-cursor feel.
public struct SpaceCursorConfig: Equatable {
    /// How long the space bar must be held before it becomes a trackpad.
    /// Shorter than this and the release is treated as a plain space tap.
    public var activationDelay: TimeInterval = 0.30

    /// Horizontal points the finger must travel to advance the caret by one
    /// character. Larger values require a longer drag per character (calmer);
    /// smaller values move the caret sooner. Must be > 0.
    public var pointsPerCharacter: Double = 10.0

    /// Pre-activation movement (points, either axis) beyond which a release is
    /// no longer considered a tap. Keeps an aborted swipe from typing a space
    /// while still tolerating the small wobble of a genuine tap.
    public var tapCancelSlop: Double = 12.0

    public init() {}
}

/// Pure, timer-free state machine for one space-key touch session.
///
///     var engine = SpaceCursorEngine()
///     engine.press(at: now, availableLeft: before.count, availableRight: after.count)
///     // ...activation timer fires:
///     engine.tick(at: now)                 // -> .enteredCursorMode
///     engine.drag(translationX: dx, translationY: dy, at: now)  // -> .moveCaret(±n)
///     engine.end(at: now)                  // -> .endedCursorMode (no space)
public struct SpaceCursorEngine: Equatable {

    public enum Phase: Equatable {
        case idle
        /// Finger down, not yet a recognized hold. `movedBeyondSlop` latches
        /// once the finger has travelled far enough that a release should no
        /// longer type a space.
        case pressed(
            pressedAt: Date,
            movedBeyondSlop: Bool,
            availableLeft: Int,
            availableRight: Int
        )
        /// Trackpad mode. `appliedOffset` is the signed number of characters
        /// the caret has already been moved from the start position; the
        /// bounds are captured from the document at press time.
        case cursor(
            appliedOffset: Int,
            availableLeft: Int,
            availableRight: Int
        )
    }

    /// Side effects the host must apply. Every mutation returns exactly one.
    public enum Effect: Equatable {
        /// Nothing to do this event.
        case none
        /// A plain tap: insert exactly one space.
        case insertSpace
        /// The hold was recognized: enter trackpad mode, insert zero spaces.
        case enteredCursorMode
        /// Move the caret by this signed character offset (<0 left, >0 right).
        /// Already clamped to the captured context bounds; never zero.
        case moveCaret(offset: Int)
        /// Trackpad mode finished (release or cancel). The host should
        /// resynchronize context and invalidate any caret-dependent async work.
        case endedCursorMode
    }

    public private(set) var phase: Phase = .idle
    public var config: SpaceCursorConfig

    public init(config: SpaceCursorConfig = SpaceCursorConfig()) {
        self.config = config
    }

    // MARK: - Queries

    /// True once the hold has been recognized and the trackpad is live.
    public var isCursorActive: Bool {
        if case .cursor = phase { return true }
        return false
    }

    /// True for any live touch session (pressed or cursor).
    public var isTracking: Bool { phase != .idle }

    /// Characters the caret has moved from its start position, or nil when not
    /// in trackpad mode. Exposed for tests / debug assertions.
    public var appliedOffset: Int? {
        if case .cursor(let applied, _, _) = phase { return applied }
        return nil
    }

    // MARK: - Transitions

    /// Begin a touch on the space key. `availableLeft` / `availableRight` are
    /// the number of characters currently before / after the caret; they bound
    /// how far the trackpad may later scrub in each direction. Negative inputs
    /// are floored at zero.
    public mutating func press(at now: Date, availableLeft: Int, availableRight: Int) {
        phase = .pressed(
            pressedAt: now,
            movedBeyondSlop: false,
            availableLeft: max(0, availableLeft),
            availableRight: max(0, availableRight)
        )
    }

    /// Drive the activation clock. Returns `.enteredCursorMode` exactly once,
    /// on the first tick at or after `activationDelay` while still pressed.
    /// A no-op in every other phase.
    public mutating func tick(at now: Date) -> Effect {
        guard case .pressed(let pressedAt, _, let left, let right) = phase else {
            return .none
        }
        guard now.timeIntervalSince(pressedAt) >= config.activationDelay else {
            return .none
        }
        phase = .cursor(appliedOffset: 0, availableLeft: left, availableRight: right)
        return .enteredCursorMode
    }

    /// Report cumulative finger translation from the drag origin. Before
    /// activation this only latches the tap-cancel slop. In trackpad mode it
    /// maps horizontal travel to a bounded, whole-character caret delta;
    /// vertical travel is ignored so a shaky drag never nudges the caret.
    public mutating func drag(translationX: Double, translationY: Double, at now: Date) -> Effect {
        switch phase {
        case .idle:
            return .none

        case .pressed(let pressedAt, let moved, let left, let right):
            let beyond = moved
                || abs(translationX) > config.tapCancelSlop
                || abs(translationY) > config.tapCancelSlop
            if beyond != moved {
                phase = .pressed(
                    pressedAt: pressedAt,
                    movedBeyondSlop: beyond,
                    availableLeft: left,
                    availableRight: right
                )
            }
            return .none

        case .cursor(let applied, let left, let right):
            // Horizontal only. Truncating toward zero gives sub-character
            // accumulation: the caret does not step until a full
            // `pointsPerCharacter` of travel has built up in one direction.
            let step = config.pointsPerCharacter
            let raw = step > 0 ? translationX / step : 0
            let requested = Int(raw.rounded(.towardZero))
            let desired = min(max(requested, -left), right)
            let delta = desired - applied
            guard delta != 0 else { return .none }
            phase = .cursor(appliedOffset: desired, availableLeft: left, availableRight: right)
            return .moveCaret(offset: delta)
        }
    }

    /// End the touch (finger lifted). From a pre-activation press this is a tap
    /// — `.insertSpace` unless the finger had wandered or the hold somehow
    /// already crossed the activation delay. From trackpad mode it is
    /// `.endedCursorMode` and never inserts a space (no delayed-tap leakage).
    public mutating func end(at now: Date) -> Effect {
        let current = phase
        phase = .idle
        switch current {
        case .idle:
            return .none
        case .pressed(let pressedAt, let moved, _, _):
            let heldToActivation = now.timeIntervalSince(pressedAt) >= config.activationDelay
            return (moved || heldToActivation) ? .none : .insertSpace
        case .cursor:
            return .endedCursorMode
        }
    }

    /// Abort the touch (system cancellation, touch-outside, lifecycle
    /// teardown). Never inserts a space. Reports `.endedCursorMode` when a live
    /// trackpad is torn down so the host can still resynchronize context.
    public mutating func cancel() -> Effect {
        let wasCursor = isCursorActive
        phase = .idle
        return wasCursor ? .endedCursorMode : .none
    }
}
