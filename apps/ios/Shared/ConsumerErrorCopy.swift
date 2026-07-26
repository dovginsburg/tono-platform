// ConsumerErrorCopy.swift
// Tono build 112 — the single place a failure becomes something a user reads.
//
// The founder's contract: no consumer-visible surface may render a raw
// `Error`, a `localizedDescription`, a status code, a response body, or any
// other implementation detail. Before build 112 five surfaces did exactly
// that — This Week, the paywall, the keyboard strip, Share, and Messages all
// assigned `error.localizedDescription` straight into rendered state, so
// whatever text the transport happened to carry landed on screen.
//
// This mapper closes that path structurally rather than by editing five
// sentences. It looks ONLY at the SHAPE of a failure — which case, which
// status class — and never at the message payload a failure carries. That
// payload is where transports write status codes, response bodies, and host
// names; consulting it at all is how the leak came back last time.
//
// Two axes, deliberately:
//
//   * `Action` — what the user was doing. This is the part that must stay
//     distinct: "Purchase couldn't be completed" and "Couldn't load your
//     weekly summary" are different facts about the user's world.
//   * `Recovery` — what they can do next. Offline, expired sign-in, and
//     "subscription required" lead to genuinely different next steps, so
//     collapsing every failure into one sentence would be its own kind of
//     dishonesty.
//
// Transport behaviour is untouched. The error types keep their full internal
// descriptions for logs and tests; they simply never reach a screen.

import Foundation

public enum ConsumerErrorCopy {

    /// What the user was doing when the failure happened. One case per
    /// consumer surface that can fail, so the leading sentence stays true.
    public enum Action {
        /// Coaching a draft — host app, keyboard strip, Share sheet, Messages.
        case coachDraft
        /// Reading a message someone else sent (keyboard Read mode).
        case readMessage
        /// The This Week summary.
        case weeklySummary
        /// A StoreKit purchase.
        case purchase
        /// A StoreKit restore.
        case restore
        /// Handing a finished rewrite back to the host app's compose field.
        case insertRewrite
    }

    /// What the user can do next. Derived from the failure's case alone.
    private enum Recovery {
        case retry
        case checkConnection
        case signIn
        case finishSetup
        case subscriptionRequired
        case waitAndRetry
        case signInBeforeSubscribing
        case contactSupport
        case tooManyDevices(current: Int, max: Int)
    }

    // MARK: - Public API

    /// The one sentence pair a consumer surface may show for a failure.
    ///
    /// Never inspects the error's message payload — only its case.
    public static func message(for error: Error, action: Action) -> String {
        let recovery = classify(error)
        if case .tooManyDevices(let current, let max) = recovery {
            return "This email is already on \(current) devices (max \(max)). Contact support if you need more."
        }
        return headline(action) + " " + nextStep(recovery)
    }

    // MARK: - What the user was doing

    private static func headline(_ action: Action) -> String {
        switch action {
        case .coachDraft:     return "Couldn't coach this draft."
        case .readMessage:    return "Couldn't read this message."
        case .weeklySummary:  return "Couldn't load your weekly summary."
        case .purchase:       return "Purchase couldn't be completed."
        case .restore:        return "Restore couldn't be completed."
        case .insertRewrite:  return "Couldn't add the rewrite to your message."
        }
    }

    // MARK: - What the user can do next

    private static func nextStep(_ recovery: Recovery) -> String {
        switch recovery {
        case .retry:
            return "Try again."
        case .checkConnection:
            return "Check your connection and try again."
        case .signIn:
            return "Open Tono and sign in again."
        case .finishSetup:
            return "Open Tono once to finish setting up, then try again."
        case .subscriptionRequired:
            return "An active trial or subscription is required. Open Tono to continue."
        case .waitAndRetry:
            return "Wait a minute and try again."
        case .signInBeforeSubscribing:
            return "Sign in with your email first so your subscription follows you if you reinstall."
        case .contactSupport:
            return "Try again, and contact support@tonoit.com if it keeps happening."
        case .tooManyDevices:
            // Handled ahead of composition — this branch exists so the switch
            // stays exhaustive without a default that could swallow a new case.
            return "Try again."
        }
    }

    // MARK: - Classification (case shape only — never the payload)

    private static func classify(_ error: Error) -> Recovery {
        if let backend = error as? TonoBackendError {
            switch backend {
            case .offline, .network:
                return .checkConnection
            case .notRegistered:
                return .finishSetup
            case .decoding:
                return .retry
            case .tooManyDevices(let current, let max):
                return .tooManyDevices(current: current, max: max)
            case .http(let code, _):
                return forStatus(code)
            }
        }

        // Build 113: the streaming path's failure. Same status classes as a
        // `TonoBackendError.http`, minus the body it never carried.
        if let streamed = error as? StreamedFailure {
            switch streamed {
            case .http(let status):
                return forStatus(status)
            }
        }

        if let engine = error as? ToneEngineError {
            switch engine {
            case .network:
                return .checkConnection
            case .noAPIKey:
                return .finishSetup
            case .decoding, .backend:
                return .retry
            }
        }

        if let store = error as? StoreKitManager.StoreError {
            switch store {
            case .failedVerification:
                return .contactSupport
            case .missingAccountToken:
                return .finishSetup
            case .needsIdentifiedAccount:
                return .signInBeforeSubscribing
            }
        }

        if let transport = error as? URLError {
            return isOffline(transport) ? .checkConnection : .retry
        }

        return .retry
    }

    /// Status classes that change what the user should do. Everything else is
    /// the same fact to a user: it didn't work, try again.
    private static func forStatus(_ code: Int) -> Recovery {
        switch code {
        case 401:      return .signIn
        case 402:      return .subscriptionRequired
        case 429:      return .waitAndRetry
        default:       return .retry
        }
    }

    /// The transport codes that mean "no usable connection" rather than "the
    /// request was answered badly". Mirrors the keyboard client's own set so
    /// the two surfaces agree about when to say "check your connection".
    private static func isOffline(_ error: URLError) -> Bool {
        switch error.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .cannotConnectToHost,
             .cannotFindHost,
             .dataNotAllowed,
             .internationalRoamingOff,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
    }
}
