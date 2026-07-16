// LiveToneSession.swift
// Tono Live Tone v1.1 — build 90 experiment, Opus 4.8 core lane.
//
// Two pure, local pieces that sit between the keyboard and the classifier:
//
//   1. `LiveToneBoundary` — the boundary-trigger contract. It decides
//      whether a given text commit is a *sentence / spelling commit
//      boundary* worth evaluating. The integration lane calls this only
//      from the host's existing commit hooks (space / punctuation /
//      newline), never from raw per-keystroke `textDidChange`.
//
//   2. `LiveToneSession` — an explicit five-state machine
//      (Disabled, Idle, Evaluating, Hinted, Suppressed). It fails closed on
//      nil / unknown / error input, holds no persistence across sessions or
//      fields, and its only observable effect is whether the passive Coach
//      decoration is currently shown.
//
// Pure Foundation. No UIKit, no timers, no persistence, no networking — the
// static source guards in LiveToneCoreTests enforce this.

import Foundation

// MARK: - Boundary-trigger contract

/// Decides whether a committed edit is a boundary at which Live Tone should
/// evaluate the draft. This is intentionally *not* a per-keystroke signal:
/// it recognizes the same commit points the on-device spelling pass already
/// uses — a sentence terminator, or whitespace/newline that closes a word.
public enum LiveToneBoundary {
    /// Characters that terminate a sentence. Matches the spelling pass's
    /// `.!?\n` boundary set plus the ellipsis.
    static let sentenceTerminators: Set<Character> = [".", "!", "?", "…", "\n"]

    /// The kind of committed edit the host just performed. The integration
    /// lane maps its existing commit hook to one of these; it must never
    /// synthesize `.character` for every keystroke — only for the character
    /// that the host treats as a commit (space, return, punctuation).
    public enum Commit: Equatable {
        /// A single committed character (e.g. the space or "." the user
        /// typed to close a word or sentence).
        case character(Character)
        /// The host reported an explicit word/sentence commit with no single
        /// character (e.g. an autocorrect acceptance).
        case wordCommit
    }

    /// Whether `commit`, applied after `precedingText`, is an evaluation
    /// boundary. Fails closed: an empty preceding draft is never a boundary
    /// (nothing has been written yet).
    public static func isEvaluationBoundary(
        precedingText: String?,
        commit: Commit
    ) -> Bool {
        guard let precedingText, let lastWritten = lastNonSpace(of: precedingText) else {
            // No committed word yet — nothing to evaluate.
            return false
        }
        switch commit {
        case .wordCommit:
            return true
        case .character(let character):
            if sentenceTerminators.contains(character) { return true }
            // Whitespace commits only count when they actually close a word,
            // i.e. the last non-space character written is part of a word.
            if character == " " || character.isWhitespace {
                return lastWritten.isLetter || lastWritten.isNumber
            }
            return false
        }
    }

    private static func lastNonSpace(of text: String) -> Character? {
        for character in text.reversed() where !character.isWhitespace {
            return character
        }
        return nil
    }
}

// MARK: - Session state machine

/// The explicit Live Tone session state. `Evaluating` is transient: the
/// machine enters and leaves it within a single `handle` call. There is no
/// persistence — a fresh field or a disabled toggle resets everything.
public enum LiveToneState: Equatable {
    /// The feature is off. No evaluation, no decoration. The only escape is
    /// an explicit `enable` event.
    case disabled
    /// Enabled and waiting for the next evaluation boundary.
    case idle
    /// Transiently classifying the current draft.
    case evaluating
    /// A hint is shown as a passive decoration; carries the matched rule.
    case hinted(LiveToneRule)
    /// A hint was shown and dismissed (or the same draft re-evaluated with no
    /// change): suppressed until the field resets, so the decoration never
    /// nags. Fresh boundaries do not re-hint while suppressed.
    case suppressed

    /// Whether the passive Coach decoration should currently be visible.
    public var isDecorationVisible: Bool {
        if case .hinted = self { return true }
        return false
    }
}

/// Events that drive the session. The integration lane emits these; the core
/// never observes the host on its own.
public enum LiveToneEvent: Equatable {
    /// Turn the feature on (from Disabled). No-op if already enabled.
    case enable
    /// Turn the feature off from any state.
    case disable
    /// A new text field / editing session began. Clears all per-field state
    /// (including suppression) but preserves enabled/disabled.
    case fieldReset
    /// An evaluation boundary was reached; carries the isolated draft. A nil
    /// draft is a fail-closed no-op.
    case boundaryReached(draft: String?)
    /// The user dismissed the current hint. Moves to Suppressed.
    case hintDismissed
}

/// Pure, value-type session machine. Feed it events; read `state`.
public struct LiveToneSession: Equatable {
    public private(set) var state: LiveToneState
    private let classifier: LiveToneClassifier

    /// Starts Disabled by default (opt-in): nothing happens until `enable`.
    public init(state: LiveToneState = .disabled, classifier: LiveToneClassifier = LiveToneClassifier()) {
        self.state = state
        self.classifier = classifier
    }

    public static func == (lhs: LiveToneSession, rhs: LiveToneSession) -> Bool {
        lhs.state == rhs.state
    }

    /// Apply one event and return the resulting state. Total over every
    /// (state, event) pair; unknown or nil input fails closed to a
    /// non-hinting state.
    @discardableResult
    public mutating func handle(_ event: LiveToneEvent) -> LiveToneState {
        switch event {
        case .disable:
            state = .disabled

        case .enable:
            // Only Disabled reacts to enable; enabling lands in Idle.
            if state == .disabled { state = .idle }

        case .fieldReset:
            // Preserve the enabled/disabled axis; clear per-field state.
            if state != .disabled { state = .idle }

        case .hintDismissed:
            // Dismissal only means something while a hint is up. From any
            // other enabled state it collapses to Idle (fail closed, never
            // leaves a stale hint); from Disabled it stays Disabled.
            switch state {
            case .disabled: break
            case .hinted: state = .suppressed
            default: state = .idle
            }

        case .boundaryReached(let draft):
            state = evaluate(draft: draft, from: state)
        }
        return state
    }

    /// The evaluation transition. Only Idle (or a re-fired Hinted) evaluates;
    /// Disabled and Suppressed swallow boundaries so the decoration neither
    /// wakes up when off nor nags after dismissal.
    private func evaluate(draft: String?, from current: LiveToneState) -> LiveToneState {
        switch current {
        case .disabled, .suppressed:
            return current
        case .idle, .evaluating, .hinted:
            // Fail closed: a nil draft yields no hint.
            guard draft != nil else { return .idle }
            let verdict = classifier.classify(draft)
            return verdict.shouldHint ? .hinted(verdict.rule) : .idle
        }
    }
}
