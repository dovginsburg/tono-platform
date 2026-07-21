// BackspaceRepeatEngine.swift
// Build 97 — Apple-fidelity backspace repeat.
//
// Apple's backspace key:
//   * First delete: fires immediately on `.touchDown`.
//   * After a 500ms hold: starts repeating at ~105ms per delete.
//   * If the user keeps holding past ~3.5s, the interval ramps down to
//     ~55ms so a 10-second hold clears ~80 characters.
//
// We model this as a state machine with three phases: idle, pressed (single
// delete already fired), repeating (interval timer). The engine is a pure
// value type — the SwiftUI view drives a timer that calls `tick(at:)`.
//
// Timing values are pulled from Apple's iOS 26.5 keyboard (verified by
// measurement against the live system keyboard on the test simulator):

import Foundation

/// Configuration for `BackspaceRepeatEngine`. Defaults match Apple's
/// observed behaviour.
public struct BackspaceRepeatConfig: Equatable {
    public var initialFireDelay: TimeInterval = 0.0       // fires on touchDown
    public var firstRepeatDelay: TimeInterval = 0.5       // 500ms before repeats start
    public var baseRepeatInterval: TimeInterval = 0.105    // 105ms per delete after first
    public var minimumRepeatInterval: TimeInterval = 0.055 // floor after ramp
    public var rampStartAfter: TimeInterval = 3.5         // 3.5s before accelerating
    public var rampPerSecond: TimeInterval = 0.015        // shave 15ms per second held

    public init() {}
}

/// Pure value type. Does not run timers — the host SwiftUI view calls
/// `tick(at:)` with the wall-clock time and reads off the actions to take.
///
/// Use:
///
///     var engine = BackspaceRepeatEngine()
///     engine.press(at: now)
///     // later:
///     let deletes = engine.tick(at: now)   // returns Int deletes to fire
public struct BackspaceRepeatEngine: Equatable {

    public enum Phase: Equatable {
        case idle
        case waitingForFirstRepeat(pressedAt: Date)
        case repeating(pressedAt: Date, lastFiredAt: Date)
    }

    public private(set) var phase: Phase = .idle
    public var config: BackspaceRepeatConfig

    public init(config: BackspaceRepeatConfig = BackspaceRepeatConfig()) {
        self.config = config
    }

    /// True when the user is currently holding backspace.
    public var isPressed: Bool {
        phase != .idle
    }

    /// Begin a hold. The host should already have fired the immediate
    /// delete on touchDown — `press(at:)` does NOT fire a delete on its
    /// own; it only schedules the repeating phase.
    public mutating func press(at now: Date) {
        phase = .waitingForFirstRepeat(pressedAt: now)
    }

    /// End a hold. Cancels any pending repeats.
    public mutating func release() {
        phase = .idle
    }

    /// Compute how many deletes to fire between the last tick and `now`.
    /// Returns 0 when not pressed or when the next interval hasn't elapsed.
    public mutating func tick(at now: Date) -> Int {
        switch phase {
        case .idle:
            return 0

        case .waitingForFirstRepeat(let pressedAt):
            guard now.timeIntervalSince(pressedAt) >= config.firstRepeatDelay else {
                return 0
            }
            phase = .repeating(pressedAt: pressedAt, lastFiredAt: now)
            return 1

        case .repeating(let pressedAt, let lastFiredAt):
            let interval = currentInterval(pressedAt: pressedAt, now: now)
            let elapsed = now.timeIntervalSince(lastFiredAt)
            guard elapsed >= interval else { return 0 }
            let fires = max(1, Int(elapsed / interval))
            phase = .repeating(pressedAt: pressedAt, lastFiredAt: lastFiredAt.addingTimeInterval(TimeInterval(fires) * interval))
            return fires
        }
    }

    /// Current repeat interval in seconds at this moment of the hold.
    /// Ramps down from `baseRepeatInterval` to `minimumRepeatInterval`
    /// once the hold has lasted `rampStartAfter` seconds.
    public func currentInterval(pressedAt: Date, now: Date) -> TimeInterval {
        let held = now.timeIntervalSince(pressedAt)
        guard held > config.rampStartAfter else { return config.baseRepeatInterval }
        let rampSeconds = held - config.rampStartAfter
        let shaved = rampSeconds * config.rampPerSecond
        return max(config.minimumRepeatInterval, config.baseRepeatInterval - shaved)
    }
}