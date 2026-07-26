// FeatureFlags.swift
// On-device feature flag cache. The app fetches /v1/features on each launch
// and caches the resolved dict in App Group UserDefaults. Every flag has a
// hardcoded fallback so the app works before the first network call.

import Foundation

// MARK: - Flag definitions

public enum FeatureFlag: String, CaseIterable {
    // ── Default ON (v1 lean core) ──────────────────────────────────────────
    case onboardingCalibration = "onboarding_calibration"
    case threadContext         = "thread_context"
    case riskDelta             = "risk_delta"
    case memoryInference       = "memory_inference"    // global StyleMemory only
    case memoryContextHints    = "memory_context_hints"

    // ── Default ON (Pro gate) ──────────────────────────────────────────────
    case weeklyDigest          = "weekly_digest"       // earns on-switch: delivered to ≥20% of Pro users

    // ── Default OFF (staged — built but not surfaced yet) ─────────────────
    // B2: each flag here gates BOTH the UI and the underlying allocation.
    // Turn each on when the core loop earns it at real-device scale.
    case customAxes        = "custom_axes"       // earns on-switch: user has ≥15 coach sessions
    case recipientMemory   = "recipient_memory"  // earns on-switch: core usage ≥ 10 sessions/week
    case widgetEnabled     = "widget_enabled"    // earns on-switch: keyboard is daily-active for user
    case siriEnabled       = "siri_enabled"      // earns on-switch: after widget adoption ≥ 30%
    case emailSignIn       = "email_sign_in"     // enable only after OTP delivery is deployed

    // ── Default OFF (not a consumer product line) ─────────────────────────
    case slackEnabled      = "slack_enabled"     // B2B/Slack stays off in consumer builds

    // ── On-device Apple Intelligence rewrite ─────────────────────────────
    // `appleIntelligenceRewriteEnabled` is a REMOTE KILL SWITCH and, since
    // Build 115, defaults ON. It is not the person's switch and is no longer
    // user-controllable: the Build 115 contract is that on-device rewriting
    // defaults ON wherever runtime availability is `.available`, with an
    // explicit opt-out, and a flag living in this cache could not carry that
    // opt-out — `update(from:)` REPLACES the whole dictionary on every
    // `/v1/features` fetch, so any user-set value here survives only until the
    // next launch. The opt-out therefore lives in `LocalRewritePreferenceStore`
    // (its own App Group key, never written by the refresh path) and this flag
    // remains what it can actually be: a way to force the route off for
    // everyone if the on-device model ever misbehaves in the field.
    //
    // `appleIntelligenceAllowsSaferRoute` stays DEFAULT OFF and stays the
    // corpus quality gate for the Safer axis (do not assume on-device output is
    // safety-equivalent to the reviewed Safer route). Fail-closed is the
    // correct direction for this one, so a refresh that drops it is harmless.
    case appleIntelligenceRewriteEnabled  = "apple_intelligence_rewrite_enabled"
    case appleIntelligenceAllowsSaferRoute = "apple_intelligence_allows_safer_route"

    // ── Collective improvement (default ON, user-controllable opt-out) ────
    case improveTono       = "improve_tono"

    /// Default value used before the first network fetch.
    public var defaultValue: Bool {
        switch self {
        case .customAxes, .recipientMemory, .widgetEnabled, .siriEnabled, .slackEnabled,
             .emailSignIn, .appleIntelligenceAllowsSaferRoute:
            return false
        default:
            return true
        }
    }

    /// Whether this flag requires a Pro subscription to be active.
    /// Even if the backend enables the flag, it won't fire for free users.
    public var requiresPro: Bool {
        switch self {
        case .memoryInference, .memoryContextHints, .weeklyDigest,
             .customAxes, .recipientMemory:
            return true
        default:
            return false
        }
    }

    /// Whether the user can toggle this in Settings.
    public var isUserControllable: Bool {
        switch self {
        case .threadContext, .weeklyDigest, .riskDelta,
             .memoryInference, .memoryContextHints, .improveTono,
             .appleIntelligenceAllowsSaferRoute:
            return true
        default:
            return false
        }
    }

    public var displayName: String {
        switch self {
        case .onboardingCalibration: return "First-run calibration"
        case .threadContext:         return "Thread context"
        case .weeklyDigest:          return "Weekly tone report"
        case .customAxes:            return "Custom rewrite axes"
        case .riskDelta:             return "Risk change indicator"
        case .memoryInference:       return "Learn from my sessions"
        case .memoryContextHints:    return "Use memory in rewrites"
        case .recipientMemory:       return "Per-recipient style memory"
        case .widgetEnabled:         return "Home screen widget"
        case .siriEnabled:         return "Siri Shortcuts"
        case .emailSignIn:         return "Email sign-in"
        case .slackEnabled:        return "Slack integration"
        case .improveTono:           return "Help improve Tono"
        case .appleIntelligenceRewriteEnabled:  return "On-device Apple Intelligence rewriting"
        case .appleIntelligenceAllowsSaferRoute: return "Allow on-device Safer rewrites"
        }
    }

    public var description: String {
        switch self {
        case .threadContext:
            return "Paste a prior message so Tono understands the thread before rewriting your reply."
        case .weeklyDigest:
            return "Sunday notification with your week's tone patterns and rewrite stats."
        case .riskDelta:
            return "Show how much each rewrite changes the risk level."
        case .memoryInference:
            return "Automatically learn your communication tendencies from rewrite choices."
        case .memoryContextHints:
            return "Send stored facts as context hints with each rewrite request."
        case .recipientMemory:
            return "Remember preferred styles per recipient in the keyboard."
        case .improveTono:
            return "Share anonymous outcome signals (which style worked, not your messages) to help improve Tono for everyone. Your messages never leave your device."
        case .appleIntelligenceRewriteEnabled:
            return "Master switch for on-device rewriting. Not shown in Settings — the person's own choice lives beside the Apple Intelligence row."
        case .appleIntelligenceAllowsSaferRoute:
            return "Permit the on-device model to attempt the Safer rewrite axis. Off by default — Tono's Safer rewrite has been tuned against a sensitive-corpus evaluation; on-device output has not."
        default:
            return ""
        }
    }
}

// MARK: - FeatureFlags store

public enum FeatureFlags {

    public static func isEnabled(_ flag: FeatureFlag) -> Bool {
        // Pro gating reads the canonical tri-state authority, not the cached
        // `proUnlocked` Bool: a missing/unknown backend state fails closed
        // (build 91 §7).
        if flag.requiresPro && !TonePreferences().isProAuthoritative {
            return false
        }
        return cached()[flag.rawValue] ?? flag.defaultValue
    }

    /// Replace the cache with a fresh dict from the backend.
    public static func update(from dict: [String: Bool]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        SharedStore.defaults.set(data, forKey: SharedKeys.featureFlags)
    }

    /// Optimistically update one flag locally and sync to backend in the background.
    public static func setUserPreference(_ flag: FeatureFlag, enabled: Bool) {
        var dict = cached()
        dict[flag.rawValue] = enabled
        guard let data = try? JSONEncoder().encode(dict) else { return }
        SharedStore.defaults.set(data, forKey: SharedKeys.featureFlags)
        Task {
            try? await TonoBackend.shared.setFeaturePreference(flag: flag.rawValue, enabled: enabled)
        }
    }

    // MARK: Private

    private static func cached() -> [String: Bool] {
        guard let data = SharedStore.defaults.data(forKey: SharedKeys.featureFlags),
              let dict = try? JSONDecoder().decode([String: Bool].self, from: data)
        else { return [:] }
        return dict
    }
}
