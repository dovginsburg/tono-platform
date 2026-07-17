// SharedUserDefaults.swift
// Cross-process preferences via App Group. The host app and the keyboard
// extension both read and write this; the keyboard cannot present a UI
// to ask the user to enter their API key, so the host app is the source
// of truth.

import Foundation

public enum SharedKeys {
    public static let provider = "tc.provider"
    public static let apiKey = "tc.apiKey"
    public static let preferredVoice = "tc.preferredVoice"
    public static let axes = "tc.axes"
    public static let freeTierUsed = "tc.freeTierUsed"
    public static let freeTierDay = "tc.freeTierDay"
    public static let freeTierLimit = "tc.freeTierLimit"
    public static let proUnlocked = "tc.proUnlocked"
    public static let lastRewriteVoice = "tc.lastRewriteVoice"
    // Apple-managed 7-day free trial state (set by StoreKit 2 from
    // currentEntitlements; read by both host app and keyboard extension).
    public static let inFreeTrial = "tc.inFreeTrial"
    // Tri-state entitlement (build 91): the last backend verdict —
    // "entitled" | "notEntitled" | "unknown". `proUnlocked` above is a mirror;
    // entitlement authorization is freshness-aware and reads THIS (see
    // TonePreferences.isProAuthoritative), so a stale cached Bool is never
    // presented as authoritative when the backend can't be reached.
    public static let entitlementState = "tc.entitlementState"
    public static let entitlementCheckedAt = "tc.entitlementCheckedAt"

    // Backend-proxy auth (v0.2). The server holds the LLM keys; the
    // client just carries a bearer token + the device id it registered
    // with. `backendURL` lets the host app point at staging/prod without
    // rebuilding.
    //
    // apiToken and deviceID are now stored in the Keychain (SharedKeychain)
    // and migrated out of UserDefaults on first launch. These keys are kept
    // as legacy constants so the migration path can wipe them.
    public static let backendURL   = "tc.backendURL"
    public static let deviceID     = "tc.deviceID"     // legacy — Keychain now
    public static let apiToken     = "tc.apiToken"     // legacy — Keychain now
    public static let registeredAt = "tc.registeredAt"

    // Written by the keyboard extension on first load so the host app can
    // detect that the user successfully enabled the keyboard in Settings.
    public static let keyboardLoaded = "tc.keyboardLoaded"

    // Cumulative Coach taps — drives the in-app review prompt.
    public static let coachUseCount = "tc.coachUseCount"

    // JSON-encoded [HistoryEntry] — last 5 coach results.
    public static let draftHistory = "tc.draftHistory"

    // JSON-encoded [Recipient] — user-defined recipient context hints.
    public static let recipients = "tc.recipients"

    // Widget-facing usage snapshot (written after each /v1/me response).
    public static let widgetUsedToday = "tc.widgetUsedToday"
    public static let widgetDailyLimit = "tc.widgetDailyLimit"

    // Axis tap weights for StyleMemory. Keys are "tc.axisWeights" (global)
    // and "tc.axisWeights.<UUID>" (per-recipient).
    public static let axisWeights = "tc.axisWeights"

    // ISO "yyyy-MM-dd" of the last day the user ran Coach successfully.
    // Used by NotificationManager to skip the nudge on days they've already coached.
    public static let lastCoachDate = "tc.lastCoachDate"

    // On-device memory store (UserMemory.swift).
    // memoryFacts:    JSON-encoded [MemoryFact] — inferred + manual facts.
    // recentSessions: JSON-encoded [RecentSession] — sliding window for inference.
    public static let memoryFacts    = "tc.memoryFacts"
    public static let recentSessions = "tc.recentSessions"

    // Perception + risk of the most recent coach result — written by keyboard/app
    // after each analysis so the widget can show it without decoding the full history.
    public static let lastPerception = "tc.lastPerception"
    public static let lastRiskLevel  = "tc.lastRiskLevel"

    // Feature flags cache (FeatureFlags.swift).
    // JSON-encoded [String: Bool] resolved dict fetched from /v1/features on launch.
    public static let featureFlags     = "tc.featureFlags"

    // Onboarding state (OnboardingCalibrationView.swift).
    public static let onboardingDone   = "tc.onboardingDone"

    // v1.0 entry-points onboarding (OnboardingEntryPointsView.swift).
    // Tracks whether the user has seen/dismissed the three-tile
    // "Set as keyboard / Use from any app / Quick setup" flow.
    // Distinct from `onboardingDone` because the calibration flow
    // (data seeding) and the entry-points flow (UX) are independent.
    public static let entryPointsOnboardingDone = "tc.entryPointsOnboardingDone"

    // ISO date of last weekly digest notification sent ("yyyy-MM-dd").
    public static let lastWeeklyDigest = "tc.lastWeeklyDigest"

    // Set true once the user has dismissed the keyboard's first-launch Full
    // Access onboarding card. Avoids nagging them on every keyboard open.
    public static let fullAccessExplained = "tc.fullAccessExplained"

    // Ring buffer of the user's last few rewrite texts, used by
    // SuggestionEngine to bias the inline suggestion strip toward phrases
    // the user has actually used. Distinct from `lastRewriteVoice` which
    // stores a single string for the widget snapshot.
    public static let recentRewrites = "tc.recentRewrites"

    // Emoji picker "Recent" ring buffer (last ~28 picked emojis).
    // JSON-encoded [String] of Unicode glyphs; read lazily by the
    // keyboard extension when the emoji panel mounts (never on startup).
    public static let emojiRecents = "tc.emojiRecents"

    // Live Tone (build-90 experiment) control keys — opt-in, user kill switch,
    // remote-disable directive, and the user-declared host allowlist — are
    // defined separately in LiveTonePrivacy.swift (`LiveTonePrivacyKeys`) so
    // that self-contained control surface and its standalone verifier need no
    // UIKit/networking imports. They share this `tc.` namespace and the
    // `group.com.tonoit.shared` App Group suite.
}

public enum SharedStore {
    public static let suiteName = "group.com.tonoit.shared"
    public static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }
}

/// Tri-state entitlement (build 91 §7). Fail-closed: only `.entitled` presents
/// Pro as authoritative. `.unknown` (backend unreachable/invalid) must never let
/// a cached Bool stand in as authority — there is no offline Pro allowance.
public enum EntitlementState: String {
    case entitled
    case notEntitled
    case unknown
}

public struct TonePreferences {
    public var provider: LLMProvider
    public var apiKey: String?
    public var preferredVoice: String?
    public var axes: [RewriteAxis]
    public var proUnlocked: Bool
    /// True when the user is currently in Apple's introductory 7-day free
    /// trial (configured in App Store Connect). Mirrored from StoreKit
    /// transactions so the keyboard extension can show "X days left".
    public var inFreeTrial: Bool
    /// Last backend entitlement verdict. `nil` = never recorded (legacy install
    /// before build 91) — in that case `isProAuthoritative` trusts the
    /// `proUnlocked` mirror so upgrades don't spuriously drop Pro.
    public var entitlementState: EntitlementState?

    public init() {
        let d = SharedStore.defaults
        self.provider = LLMProvider(rawValue: d.string(forKey: SharedKeys.provider) ?? "mock") ?? .mock
        // API key lives in the Keychain; fall back to UserDefaults only during the
        // one-time migration window (wiped in registerIfNeeded after first use).
        self.apiKey = SharedKeychain.get(KeychainKeys.apiKey)
            ?? d.string(forKey: SharedKeys.apiKey)
        self.preferredVoice = d.string(forKey: SharedKeys.lastRewriteVoice)
        let stored = d.array(forKey: SharedKeys.axes) as? [String] ?? RewriteAxis.allCases.map(\.rawValue)
        self.axes = stored.compactMap(RewriteAxis.init(rawValue:))
        self.proUnlocked = d.bool(forKey: SharedKeys.proUnlocked)
        self.inFreeTrial = d.bool(forKey: SharedKeys.inFreeTrial)
        self.entitlementState = d.string(forKey: SharedKeys.entitlementState).flatMap(EntitlementState.init(rawValue:))
    }

    /// Freshness-aware Pro authorization for extensions and gated features.
    /// `.entitled` -> true; `.notEntitled`/`.unknown` -> false (fail closed);
    /// `nil` (legacy, not yet reconciled) -> the last-known `proUnlocked` mirror.
    public var isProAuthoritative: Bool {
        switch entitlementState {
        case .entitled: return true
        case .notEntitled, .unknown: return false
        case nil: return proUnlocked
        }
    }

    public func save() {
        let d = SharedStore.defaults
        d.set(provider.rawValue, forKey: SharedKeys.provider)
        // Write API key to Keychain; wipe any legacy plaintext copy.
        if let key = apiKey, !key.isEmpty {
            SharedKeychain.set(key, forKey: KeychainKeys.apiKey)
        } else {
            SharedKeychain.delete(KeychainKeys.apiKey)
        }
        d.removeObject(forKey: SharedKeys.apiKey)
        d.set(preferredVoice, forKey: SharedKeys.preferredVoice)
        d.set(axes.map(\.rawValue), forKey: SharedKeys.axes)
        d.set(proUnlocked, forKey: SharedKeys.proUnlocked)
        if let entitlementState {
            d.set(entitlementState.rawValue, forKey: SharedKeys.entitlementState)
            d.set(Date().timeIntervalSince1970, forKey: SharedKeys.entitlementCheckedAt)
        }
    }

    /// Record a fresh backend verdict from any surface (host app or keyboard
    /// extension). `.notEntitled` immediately clears the shared Pro mirror;
    /// `.unknown` leaves the mirror untouched but flips authorization closed via
    /// `isProAuthoritative` (build 91 §7).
    public static func recordEntitlement(_ state: EntitlementState, isPro: Bool) {
        let d = SharedStore.defaults
        d.set(state.rawValue, forKey: SharedKeys.entitlementState)
        d.set(Date().timeIntervalSince1970, forKey: SharedKeys.entitlementCheckedAt)
        switch state {
        case .entitled:
            d.set(true, forKey: SharedKeys.proUnlocked)
        case .notEntitled:
            d.set(false, forKey: SharedKeys.proUnlocked)
            d.set(false, forKey: SharedKeys.inFreeTrial)
        case .unknown:
            break  // keep the last-known mirror; authorization already fails closed
        }
    }
}

public struct FreeTierGate {
    public let dailyLimit: Int

    public init(dailyLimit: Int = 10) {
        self.dailyLimit = dailyLimit
    }

    public var usedToday: Int {
        SharedStore.defaults.integer(forKey: SharedKeys.freeTierUsed)
    }

    public var dayStamp: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.string(from: Date())
    }

    /// Returns true if the user can perform another rewrite today.
    public func canAnalyze() -> Bool {
        // Freshness-aware: an unknown/notEntitled backend state fails closed to
        // the free tier instead of trusting a stale cached Bool (build 91 §7).
        if TonePreferences().isProAuthoritative { return true }
        let stored = SharedStore.defaults.string(forKey: SharedKeys.freeTierDay)
        if stored != dayStamp {
            SharedStore.defaults.set(0, forKey: SharedKeys.freeTierUsed)
            SharedStore.defaults.set(dayStamp, forKey: SharedKeys.freeTierDay)
            return true
        }
        return usedToday < dailyLimit
    }

    public func recordUse() {
        if TonePreferences().isProAuthoritative { return }
        SharedStore.defaults.set(usedToday + 1, forKey: SharedKeys.freeTierUsed)
    }
}
