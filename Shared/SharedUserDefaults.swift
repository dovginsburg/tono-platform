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

    // ISO date of last weekly digest notification sent ("yyyy-MM-dd").
    public static let lastWeeklyDigest = "tc.lastWeeklyDigest"
}

public enum SharedStore {
    public static let suiteName = "group.com.tonocoach.shared"
    public static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }
}

public struct TonePreferences {
    public var provider: LLMProvider
    public var apiKey: String?
    public var preferredVoice: String?
    public var axes: [RewriteAxis]
    public var proUnlocked: Bool

    public init() {
        let d = SharedStore.defaults
        self.provider = LLMProvider(rawValue: d.string(forKey: SharedKeys.provider) ?? "mock") ?? .mock
        // API key lives in the Keychain; fall back to UserDefaults only during the
        // one-time migration window (wiped in registerIfNeeded after first use).
        self.apiKey = SharedKeychain.get(KeychainKeys.apiKey)
            ?? d.string(forKey: SharedKeys.apiKey)
        self.preferredVoice = d.string(forKey: SharedKeys.preferredVoice)
        let stored = d.array(forKey: SharedKeys.axes) as? [String] ?? RewriteAxis.allCases.map(\.rawValue)
        self.axes = stored.compactMap(RewriteAxis.init(rawValue:))
        self.proUnlocked = d.bool(forKey: SharedKeys.proUnlocked)
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
        if TonePreferences().proUnlocked { return true }
        let stored = SharedStore.defaults.string(forKey: SharedKeys.freeTierDay)
        if stored != dayStamp {
            SharedStore.defaults.set(0, forKey: SharedKeys.freeTierUsed)
            SharedStore.defaults.set(dayStamp, forKey: SharedKeys.freeTierDay)
            return true
        }
        return usedToday < dailyLimit
    }

    public func recordUse() {
        if TonePreferences().proUnlocked { return }
        SharedStore.defaults.set(usedToday + 1, forKey: SharedKeys.freeTierUsed)
    }
}
